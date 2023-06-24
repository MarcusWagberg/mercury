const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;

const me = @import("mercury_error.zig");

const Data = @This();

const Group = struct {
    name: []const u8,

    pub fn free(self: *const Group, alloc: Allocator) void {
        alloc.free(self.name);
    }

    pub fn copy(self: *const Group, alloc: Allocator) ?Group {
        return Group{
            .name = alloc.dupe(u8, self.name) catch return null,
        };
    }
};

const File = struct {
    name: []const u8,
    group: [36]u8,

    pub fn free(self: *const File, alloc: Allocator) void {
        alloc.free(self.name);
    }

    pub fn copy(self: *const File, alloc: Allocator) ?File {
        return File{
            .name = alloc.dupe(u8, self.name) catch return null,
            .group = self.group,
        };
    }
};

pub const GroupStore = Store(Group);
pub const FileStore = Store(File);

alloc: Allocator,
data_path: []const u8,
group_store: GroupStore,
file_store: FileStore,

pub fn init(alloc: Allocator, data: []const u8) !Data {
    var data_dir = std.fs.cwd().makeOpenPath(data, .{}) catch |err| {
        log.err("failed to make path '{s}' with: '{any}'", .{ data, err });
        return err;
    };
    defer data_dir.close();

    const data_path = std.fs.cwd().realpathAlloc(alloc, data) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("allocation failed!", .{});
            return err;
        },
        else => {
            log.err("failed to get the absolute path of '{s}' with: '{any}'", .{ data, err });
            return err;
        },
    };
    errdefer alloc.free(data_path);

    var group_store = try GroupStore.init(alloc, &data_dir, data_path, "groups.json");
    errdefer group_store.deinit();

    var file_store = try FileStore.init(alloc, &data_dir, data_path, "files.json");
    errdefer file_store.deinit();

    return Data{
        .alloc = alloc,
        .data_path = data_path,
        .group_store = group_store,
        .file_store = file_store,
    };
}

pub fn deinit(self: *Data) void {
    self.group_store.deinit();
    self.file_store.deinit();
    self.alloc.free(self.data_path);
}

fn Store(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            uuid: [36]u8,
            created: i128,
            modified: i128,
            data: T,

            pub fn free(self: *const Entry, alloc: Allocator) void {
                self.data.free(alloc);
            }
        };

        pub const List = struct {
            slice: []Entry,

            pub fn free(self: *const List, alloc: Allocator) void {
                for (self.slice) |entry| {
                    entry.free(alloc);
                }
                alloc.free(self.slice);
            }
        };

        const Map = std.AutoArrayHashMap([36]u8, Entry);

        alloc: Allocator,
        mutex: std.Thread.Mutex,
        file_path: []const u8,
        map: Map,

        pub fn init(alloc: Allocator, data_dir: *std.fs.Dir, data_path: []const u8, file_name: []const u8) !Self {
            const file_path = std.fmt.allocPrint(
                alloc,
                "{s}{c}{s}",
                .{
                    data_path,
                    std.fs.path.sep,
                    file_name,
                },
            ) catch |err| {
                log.err("allocation failed!", .{});
                return err;
            };
            errdefer alloc.free(file_path);

            data_dir.access(file_name, .{ .lock = .exclusive }) catch |err| switch (err) {
                error.FileNotFound => {
                    var created = data_dir.createFile(
                        file_name,
                        .{ .read = true, .lock = .exclusive },
                    ) catch |inner_err| {
                        log.err("failed to create file '{s}' with: '{any}'", .{ file_path, inner_err });
                        return inner_err;
                    };
                    defer created.close();
                    created.writeAll("[]") catch |inner_err| {
                        log.err("failed to write to file '{s}' with: '{any}'", .{ file_path, inner_err });
                        return inner_err;
                    };
                },
                else => {
                    log.err("failed to access file '{s}' with: '{any}'", .{ file_path, err });
                    return err;
                },
            };

            var map = Map.init(alloc);
            errdefer deinitMap(alloc, &map);

            try loadFromFile(alloc, file_path, &map);

            return Self{
                .alloc = alloc,
                .mutex = std.Thread.Mutex{},
                .file_path = file_path,
                .map = map,
            };
        }

        pub const ListResult = me.Result(List, enum {
            alloc,
        });
        pub fn list(self: *Self) ListResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            var slice = self.alloc.alloc(Entry, self.map.count()) catch |err| return ListResult.asError(
                "allocation failed!",
                .alloc,
                err,
            );

            var it = self.map.iterator();

            while (it.next()) |entry| {
                slice[it.index - 1] = Entry{
                    .uuid = entry.value_ptr.*.uuid,
                    .created = entry.value_ptr.*.created,
                    .modified = entry.value_ptr.*.modified,
                    .data = entry.value_ptr.*.data.copy(self.alloc) orelse {
                        for (slice) |item| item.free(self.alloc);
                        self.alloc.free(slice);
                        return ListResult.asError(
                            "allocation failed!",
                            .alloc,
                            error.OutOfMemory,
                        );
                    },
                };
            }

            return ListResult.asOk(List{
                .slice = slice,
            });
        }

        pub const CreateResult = me.Result(void, enum {
            random,
            alloc,
            put_failed,
            fs,
        });
        pub fn create(self: *Self, data: T) CreateResult {
            const hex: []const u8 = "0123456789ABCDEF";
            var uuid: [36]u8 = undefined;
            var prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                std.os.getrandom(std.mem.asBytes(&seed)) catch |err| return CreateResult.asError(
                    "failed to get random",
                    .random,
                    err,
                );
                break :blk seed;
            });
            var rand = prng.random();

            uuid[8] = '-';
            uuid[13] = '-';
            uuid[18] = '-';
            uuid[23] = '-';

            var i: usize = 0;
            while (i < 36) : (i += 1) {
                if (i != 8 and i != 13 and i != 18 and i != 23) {
                    const ru8 = rand.uintAtMost(u8, 15);
                    uuid[i] = hex[ru8];
                }
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            const new_data = data.copy(self.alloc) orelse return CreateResult.asError(
                "allocation failed!",
                .alloc,
                error.OutOfMemory,
            );

            self.map.put(uuid, Entry{
                .uuid = uuid,
                .created = std.time.nanoTimestamp(),
                .modified = std.time.nanoTimestamp(),
                .data = new_data,
            }) catch |err| {
                new_data.free(self.alloc);
                return CreateResult.asError("failed to add entry", .put_failed, err);
            };

            if (!self.saveLoad()) {
                return CreateResult.asErrorExtraArgs(
                    "failed to load and/or save from/to file: '{s}'",
                    .{self.file_path},
                    .fs,
                    {},
                );
            } else {
                return CreateResult.asOk({});
            }
        }

        pub const GetResult = me.Result(Entry, enum {
            alloc,
            no_entry,
        });
        pub fn get(self: *Self, uuid: [36]u8) GetResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.contains(uuid)) {
                const entry = self.map.getEntry(uuid).?;
                return GetResult.asOk(Entry{
                    .uuid = entry.value_ptr.*.uuid,
                    .created = entry.value_ptr.*.created,
                    .modified = entry.value_ptr.*.modified,
                    .data = entry.value_ptr.*.data.copy(self.alloc) orelse return GetResult.asError(
                        "allocation failed!",
                        .alloc,
                        error.OutOfMemory,
                    ),
                });
            } else {
                return GetResult.asErrorExtraArgs(
                    "no entry with uuid: '{s}'",
                    .{uuid},
                    .no_entry,
                    void,
                );
            }
        }

        pub const UpdateResult = me.Result(void, enum {
            alloc,
            no_entry,
            fs,
        });
        pub fn update(self: *Self, uuid: [36]u8, data: T) UpdateResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.contains(uuid)) {
                const new_data = data.copy(self.alloc) orelse return UpdateResult.asError(
                    "allocation failed!",
                    .alloc,
                    error.OutOfMemory,
                );

                const entry = self.map.getEntry(uuid).?;
                entry.value_ptr.*.free(self.alloc);
                entry.value_ptr.*.data = new_data;
                entry.value_ptr.*.modified = std.time.nanoTimestamp();

                if (!self.saveLoad()) {
                    return UpdateResult.asErrorExtraArgs(
                        "failed to load and/or save from/to file: '{s}'",
                        .{self.file_path},
                        .fs,
                        {},
                    );
                } else {
                    return UpdateResult.asOk({});
                }
            } else {
                return UpdateResult.asErrorExtraArgs(
                    "no entry with uuid: '{s}'",
                    .{uuid},
                    .no_entry,
                    void,
                );
            }
        }

        pub const MoveUpResult = me.Result(void, enum {
            no_entry,
            already_top,
            fs,
        });
        pub fn moveUp(self: *Self, uuid: [36]u8) MoveUpResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.getIndex(uuid)) |index| {
                if (index == 0) {
                    return MoveUpResult.asErrorExtraArgs(
                        "entry with uuid: '{s}' is already at the top",
                        .{uuid},
                        .already_top,
                        void,
                    );
                }

                const keys = self.map.keys();
                const values = self.map.values();

                const higher_key = keys[index - 1];
                const higher_value = values[index - 1];

                keys[index - 1] = keys[index];
                values[index - 1] = values[index];

                keys[index] = higher_key;
                values[index] = higher_value;

                if (!self.saveLoad()) {
                    return MoveUpResult.asErrorExtraArgs(
                        "failed to load and/or save from/to file: '{s}'",
                        .{self.file_path},
                        .fs,
                        {},
                    );
                } else {
                    return MoveUpResult.asOk({});
                }
            } else {
                return MoveUpResult.asErrorExtraArgs(
                    "no entry with uuid: '{s}'",
                    .{uuid},
                    .no_entry,
                    void,
                );
            }
        }

        pub const MoveDownResult = me.Result(void, enum {
            no_entry,
            already_bottom,
            fs,
        });
        pub fn moveDown(self: *Self, uuid: [36]u8) MoveDownResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.getIndex(uuid)) |index| {
                if (index == self.map.count() - 1) {
                    return MoveDownResult.asErrorExtraArgs(
                        "entry with uuid: '{s}' is already at the top",
                        .{uuid},
                        .already_bottom,
                        void,
                    );
                }

                const keys = self.map.keys();
                const values = self.map.values();

                const lower_key = keys[index + 1];
                const lower_value = values[index + 1];

                keys[index + 1] = keys[index];
                values[index + 1] = values[index];

                keys[index] = lower_key;
                values[index] = lower_value;

                if (!self.saveLoad()) {
                    return MoveDownResult.asErrorExtraArgs(
                        "failed to load and/or save from/to file: '{s}'",
                        .{self.file_path},
                        .fs,
                        {},
                    );
                } else {
                    return MoveDownResult.asOk({});
                }
            } else {
                return MoveDownResult.asErrorExtraArgs(
                    "no entry with uuid: '{s}'",
                    .{uuid},
                    .no_entry,
                    void,
                );
            }
        }

        pub const DeleteResult = me.Result(void, enum {
            no_entry,
            fs,
        });
        pub fn delete(self: *Self, uuid: [36]u8) DeleteResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.contains(uuid)) {
                self.map.getEntry(uuid).?.value_ptr.free(self.alloc);
                if (!self.map.orderedRemove(uuid)) unreachable;

                if (!self.saveLoad()) {
                    return DeleteResult.asErrorExtraArgs(
                        "failed to load and/or save from/to file: '{s}'",
                        .{self.file_path},
                        .fs,
                        {},
                    );
                } else {
                    return DeleteResult.asOk({});
                }
            } else {
                return DeleteResult.asErrorExtraArgs(
                    "no entry with uuid: '{s}'",
                    .{uuid},
                    .no_entry,
                    void,
                );
            }
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            deinitMap(self.alloc, &self.map);
            self.alloc.free(self.file_path);
        }

        fn saveLoad(self: *Self) bool {
            var save_failed = false;
            var load_failed = false;

            saveToFile(self.alloc, self.file_path, &self.map) catch {
                save_failed = true;
            };

            deinitMap(self.alloc, &self.map);
            self.map = Map.init(self.alloc);

            loadFromFile(self.alloc, self.file_path, &self.map) catch {
                load_failed = true;
            };

            if (save_failed or load_failed) return false else return true;
        }

        fn loadFromFile(alloc: Allocator, file_path: []const u8, map: *Map) !void {
            var file = std.fs.openFileAbsolute(file_path, .{ .lock = .exclusive }) catch |err| {
                log.err("failed to open file '{s}' with: '{any}'", .{ file_path, err });
                return err;
            };
            defer file.close();

            file.seekTo(0) catch |err| {
                log.err("failed to seek in file '{s}' with: '{any}'", .{ file_path, err });
                return err;
            };

            const json = file.readToEndAlloc(alloc, std.math.maxInt(usize)) catch |err| switch (err) {
                error.OutOfMemory => {
                    log.err("allocation failed!", .{});
                    return err;
                },
                else => {
                    log.err("failed to read from file '{s}' with: '{any}'", .{ file_path, err });
                    return err;
                },
            };
            defer alloc.free(json);

            const entries = std.json.parseFromSlice([]Entry, alloc, json, .{ .ignore_unknown_fields = false }) catch |err| {
                log.err("failed to parse json from file '{s}' with: '{any}'", .{ file_path, err });
                return err;
            };
            defer entries.deinit();

            for (entries.value) |entry| {
                const new_data = entry.data.copy(alloc) orelse {
                    log.err("allocation failed!", .{});
                    return error.OutOfMemory;
                };
                errdefer new_data.free(alloc);

                map.put(entry.uuid, Entry{
                    .uuid = entry.uuid,
                    .created = entry.created,
                    .modified = entry.modified,
                    .data = new_data,
                }) catch |err| {
                    log.err("failed to add entry from file '{s} with: '{any}'", .{ file_path, err });
                    return err;
                };
            }
        }

        fn saveToFile(alloc: Allocator, file_path: []const u8, map: *Map) !void {
            const new_file_path = std.fmt.allocPrint(alloc, "{s}.new", .{file_path}) catch |err| {
                log.err("allocation failed!", .{});
                return err;
            };
            defer alloc.free(new_file_path);

            var file = std.fs.createFileAbsolute(new_file_path, .{ .lock = .exclusive }) catch |err| {
                log.err("failed to open file '{s}' with: '{any}'", .{ new_file_path, err });
                return err;
            };
            defer file.close();

            file.seekTo(0) catch |err| {
                log.err("failed to seek in file '{s}' with: '{any}'", .{ new_file_path, err });
                return err;
            };

            const writer = file.writer();

            std.json.stringify(map.values(), .{ .whitespace = .{} }, writer) catch |err| {
                log.err("failed to stringify in memory Store to file '{s}' with: '{any}'", .{ new_file_path, err });
                return err;
            };

            std.fs.renameAbsolute(new_file_path, file_path) catch |err| {
                log.err("failed to rename file '{s}' to '{s}' with: '{any}'", .{ new_file_path, file_path, err });
                return err;
            };
        }

        fn deinitMap(alloc: Allocator, map: *Map) void {
            for (map.values()) |value| {
                value.free(alloc);
            }
            map.deinit();
        }
    };
}
