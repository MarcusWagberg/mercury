const std = @import("std");
const log = std.log;

const Allocator = std.mem.Allocator;

pub fn JsonFileStore(comptime T: type, comptime debug: bool) type {
    return struct {
        const Self = @This();
        const stringify_options = std.json.StringifyOptions{ .whitespace = .{} };
        const parse_options = std.json.ParseOptions{};

        const Latest = T.Latest;

        const Meta = struct {
            version: u64,
            created: i128,
        };

        fn Entry(comptime DataT: type) type {
            return struct {
                const EntrySelf = @This();

                id: [36]u8,
                created: i128,
                modified: i128,
                data: DataT,

                pub fn free(self: *const EntrySelf, alloc: Allocator) void {
                    self.data.free(alloc);
                }

                pub fn copy(self: *const EntrySelf, alloc: Allocator) ?EntrySelf {
                    return EntrySelf{
                        .id = self.id,
                        .created = self.created,
                        .modified = self.modified,
                        .data = self.data.copy(alloc) orelse return null,
                    };
                }
            };
        }

        fn JsonFile(comptime EntryT: type) type {
            return struct {
                meta: Meta,
                entries: []EntryT,
            };
        }

        fn List(comptime EntryT: type) type {
            return struct {
                const ListSelf = @This();

                arena: std.heap.ArenaAllocator,
                entries: []EntryT,

                pub fn free(self: *ListSelf) void {
                    self.arena.deinit();
                }
            };
        }

        pub const LatestEntry = Entry(Latest);

        const LatestJsonFile = JsonFile(LatestEntry);
        const LatestList = List(LatestEntry);
        const LatestMap = std.AutoArrayHashMap([36]u8, LatestEntry);

        alloc: Allocator,
        mutex: std.Thread.Mutex,
        file_path: []const u8,
        meta: Meta,
        map: LatestMap,

        pub fn init(alloc: Allocator, data_dir: *std.fs.Dir, data_path: []const u8, file_name: []const u8) !Self {
            const file_path = std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
                data_path,
                std.fs.path.sep,
                file_name,
            }) catch |err| {
                if (debug) log.err("allocation failed!", .{});
                return err;
            };
            errdefer alloc.free(file_path);

            data_dir.access(file_name, .{ .lock = .exclusive }) catch |err| switch (err) {
                error.FileNotFound => {
                    var created = data_dir.createFile(file_name, .{ .read = true, .lock = .exclusive }) catch |inner_err| {
                        if (debug) log.err("failed to create file '{s}' with: '{any}'", .{ file_path, inner_err });
                        return inner_err;
                    };
                    defer created.close();

                    const json_file = LatestJsonFile{
                        .meta = .{ .version = Latest.version, .created = std.time.nanoTimestamp() },
                        .entries = &[_]LatestEntry{},
                    };
                    std.json.stringify(json_file, stringify_options, created.writer()) catch |inner_err| {
                        if (debug) log.err("failed to write to file '{s}' with: '{any}'", .{ file_path, inner_err });
                        return inner_err;
                    };
                },
                else => {
                    if (debug) log.err("failed to access file '{s}' with: '{any}'", .{ file_path, err });
                    return err;
                },
            };

            var map = LatestMap.init(alloc);
            errdefer {
                for (map.values()) |value| {
                    value.free(alloc);
                }
                map.deinit();
            }

            const meta = try migrateLoad(alloc, file_path, &map);

            return Self{
                .alloc = alloc,
                .mutex = std.Thread.Mutex{},
                .file_path = file_path,
                .meta = meta,
                .map = map,
            };
        }

        pub fn list(self: *Self, alloc: Allocator) !LatestList {
            var arena = std.heap.ArenaAllocator.init(alloc);
            errdefer arena.deinit();

            self.mutex.lock();
            defer self.mutex.unlock();

            var return_list = LatestList{
                .arena = arena,
                .entries = arena.allocator().alloc(LatestEntry, self.map.count()) catch {
                    if (debug) log.err("allocation failed!", .{});
                    return error.OutOfMemory;
                },
            };

            for (self.map.values(), 0..) |entry, i| {
                return_list.entries[i] = entry.copy(return_list.arena.allocator()) orelse {
                    if (debug) log.err("allocation failed!", .{});
                    return error.OutOfMemory;
                };
            }

            return return_list;
        }

        pub fn create(self: *Self, data: Latest) !void {
            var prng = std.rand.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                std.os.getrandom(std.mem.asBytes(&seed)) catch |err| {
                    if (debug) log.err("failed to get os random with: '{any}'", .{err});
                    return error.OsRandomFailed;
                };
                break :blk seed;
            });
            var rand = prng.random();

            const chars: []const u8 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
            var new_id: [36]u8 = undefined;

            for (&new_id) |*c| c.* = chars[rand.uintAtMost(u8, chars.len - 1)];

            var new_entry = LatestEntry{
                .id = new_id,
                .created = std.time.nanoTimestamp(),
                .modified = std.time.nanoTimestamp(),
                .data = data.copy(self.alloc) orelse {
                    if (debug) log.err("allocation failed!", .{});
                    return error.OutOfMemory;
                },
            };
            errdefer new_entry.free(self.alloc);

            self.mutex.lock();
            defer self.mutex.unlock();

            self.map.put(new_entry.id, new_entry) catch |err| {
                if (debug) log.err("put failed with: '{any}'", .{err});
                return error.PutFailed;
            };

            save(self.file_path, &self.map, self.meta) catch return error.SaveFailed;
        }

        pub fn read(self: *Self, alloc: Allocator, id: [36]u8) !LatestEntry {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.map.get(id) orelse {
                if (debug) log.err("no entry with id: '{s}'", .{id});
                return error.EntryNotFound;
            };

            return entry.copy(alloc) orelse {
                if (debug) log.err("allocation failed!", .{});
                return error.OutOfMemory;
            };
        }

        pub fn update(self: *Self, id: [36]u8, data: Latest) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var entry = self.map.getPtr(id) orelse {
                if (debug) log.err("no entry with id: '{s}'", .{id});
                return error.EntryNotFound;
            };

            const old_data = entry.*.data;
            const new_data = data.copy(self.alloc) orelse {
                if (debug) log.err("allocation failed!", .{});
                return error.OutOfMemory;
            };
            errdefer new_data.free(self.alloc);

            old_data.free(self.alloc);
            entry.*.data = new_data;
            entry.*.modified = std.time.nanoTimestamp();

            save(self.file_path, &self.map, self.meta) catch return error.SaveFailed;
        }

        pub fn moveAbove(self: *Self, move_id: [36]u8, above_id: [36]u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const move_index = self.map.getIndex(move_id) orelse {
                if (debug) log.err("no entry with id: '{s}'", .{move_id});
                return error.EntryNotFound;
            };
            const above_index = self.map.getIndex(above_id) orelse {
                if (debug) log.err("no entry with id: '{s}'", .{above_id});
                return error.EntryNotFound;
            };

            if (move_index <= above_index) {
                if (debug) log.err("entry with id: '{s}' already above: '{s}'", .{ move_id, above_id });
                return error.AlreadyAbove;
            }

            var it = self.map.iterator();
            it.index = @intCast(u32, above_index);

            var carry_value: ?LatestEntry = null;
            var carry_key: ?[36]u8 = null;

            while (it.next()) |entry| {
                const index = @intCast(usize, it.index) - 1;

                const next_value = entry.value_ptr.*;
                const next_key = entry.key_ptr.*;

                if (carry_value != null and carry_key != null) {
                    entry.value_ptr.* = carry_value.?;
                    entry.key_ptr.* = carry_key.?;
                } else {
                    entry.value_ptr.* = undefined;
                    entry.key_ptr.* = undefined;
                }

                carry_value = next_value;
                carry_key = next_key;

                if (index == move_index) {
                    it.index = @intCast(u32, above_index);
                    var top_entry = it.next() orelse unreachable;

                    top_entry.value_ptr.* = carry_value.?;
                    top_entry.key_ptr.* = carry_key.?;

                    break;
                }
            }

            save(self.file_path, &self.map, self.meta) catch return error.SaveFailed;
        }

        pub fn moveBelow(self: *Self, move_id: [36]u8, below_id: [36]u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const move_index = self.map.getIndex(move_id) orelse {
                if (debug) log.err("no entry with id: '{s}'", .{move_id});
                return error.EntryNotFound;
            };
            const below_index = self.map.getIndex(below_id) orelse {
                if (debug) log.err("no entry with id: '{s}'", .{below_id});
                return error.EntryNotFound;
            };

            if (move_index >= below_index) {
                if (debug) log.err("entry with id: '{s}' already below: '{s}'", .{ move_id, below_id });
                return error.AlreadyBelow;
            }

            var it = self.map.iterator();
            it.index = @intCast(u32, move_index);

            while (it.next()) |entry| {
                const index = @intCast(usize, it.index) - 1;

                const next_value = entry.value_ptr.*;
                const next_key = entry.key_ptr.*;

                entry.value_ptr.* = it.values[index + 1];
                entry.key_ptr.* = it.keys[index + 1];

                it.values[index + 1] = next_value;
                it.keys[index + 1] = next_key;

                if (index == below_index - 1) break;
            }

            save(self.file_path, &self.map, self.meta) catch return error.SaveFailed;
        }

        pub fn delete(self: *Self, id: [36]u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.map.orderedRemove(id)) {
                if (debug) log.err("no entry with id: '{s}'", .{id});
                return error.EntryNotFound;
            }

            save(self.file_path, &self.map, self.meta) catch return error.SaveFailed;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.map.values()) |value| value.free(self.alloc);

            self.map.deinit();
            self.alloc.free(self.file_path);
        }

        fn save(file_path: []const u8, map: *LatestMap, meta: Meta) !void {
            var file = std.fs.createFileAbsolute(file_path, .{ .lock = .exclusive }) catch |err| {
                if (debug) log.err("failed to open file '{s}' with: '{any}'", .{ file_path, err });
                return err;
            };
            defer file.close();

            file.seekTo(0) catch |err| {
                if (debug) log.err("failed to seek in file '{s}' with: '{any}'", .{ file_path, err });
                return err;
            };

            std.json.stringify(LatestJsonFile{ .meta = meta, .entries = map.values() }, stringify_options, file.writer()) catch |err| {
                if (debug) log.err("failed to output json to file '{s}' with: '{any}'", .{ file_path, err });
                return err;
            };
        }

        fn migrateLoad(alloc: Allocator, file_path: []const u8, map: *LatestMap) !Meta {
            var content: ?[]const u8 = try readFile(alloc, file_path);
            defer if (content) |cont| alloc.free(cont);

            var scanner = std.json.Scanner.initCompleteInput(alloc, content.?);
            defer scanner.deinit();

            const optional_ver: ?u64 = optional_ver: {
                const token1 = scanner.next() catch break :optional_ver null;
                if (token1 != .object_begin) break :optional_ver null;

                const token2 = scanner.next() catch break :optional_ver null;
                if (token2 != .string or !std.mem.eql(u8, token2.string, "meta")) break :optional_ver null;

                const token3 = scanner.next() catch break :optional_ver null;
                if (token3 != .object_begin) break :optional_ver null;

                const token4 = scanner.next() catch break :optional_ver null;
                if (token4 != .string or !std.mem.eql(u8, token4.string, "version")) break :optional_ver null;

                const token5 = scanner.next() catch break :optional_ver null;
                if (token5 != .number) break :optional_ver null;

                const break_value = std.fmt.parseInt(u64, token5.number, 10) catch break :optional_ver null;
                break :optional_ver break_value;
            };
            const ver = optional_ver orelse {
                if (debug) log.err("failed to parse version from file '{s}'", .{file_path});
                return error.VersionParseFailed;
            };

            if (Latest.version > 1) {
                comptime var i = 2;
                inline while (i <= Latest.version) : (i += 1) {
                    const current_name = std.fmt.comptimePrint("V{d}", .{i});
                    const Current = @field(T, current_name);

                    const last_name = std.fmt.comptimePrint("V{d}", .{i - 1});
                    const Last = @field(T, last_name);

                    if (ver < i) {
                        if (content == null) content = try readFile(alloc, file_path);

                        const old_json_file = try parseContent(JsonFile(Entry(Last)), alloc, content.?);
                        defer old_json_file.deinit();

                        var entries = std.ArrayList(Entry(Current)).init(alloc);
                        defer {
                            for (entries.items) |entry| {
                                entry.free(alloc);
                            }
                            entries.deinit();
                        }

                        for (old_json_file.value.entries) |entry| {
                            entries.append(Entry(Current){
                                .id = entry.id,
                                .created = entry.created,
                                .modified = entry.modified,
                                .data = Current.migrate(entry.data, alloc) orelse {
                                    if (debug) log.err("allocation failed!", .{});
                                    return error.OutOfMemory;
                                },
                            }) catch {
                                if (debug) log.err("allocation failed!", .{});
                                return error.OutOfMemory;
                            };
                        }

                        var new_json_file = JsonFile(Entry(Current)){
                            .meta = old_json_file.value.meta,
                            .entries = entries.items,
                        };
                        new_json_file.meta.version += 1;

                        var file = std.fs.openFileAbsolute(file_path, .{ .mode = .write_only, .lock = .exclusive }) catch |err| {
                            if (debug) log.err("failed to open file '{s}' with: '{any}'", .{ file_path, err });
                            return err;
                        };
                        defer file.close();

                        std.json.stringify(new_json_file, stringify_options, file.writer()) catch |inner_err| {
                            if (debug) log.err("failed to write to file '{s}' with: '{any}'", .{ file_path, inner_err });
                            return inner_err;
                        };

                        alloc.free(content.?);
                        content = null;
                    }
                }
            }

            if (content == null) content = try readFile(alloc, file_path);

            const parsed_file = try parseContent(LatestJsonFile, alloc, content.?);
            defer parsed_file.deinit();

            for (parsed_file.value.entries) |entry| {
                map.put(
                    entry.id,
                    entry.copy(alloc) orelse {
                        if (debug) log.err("allocation failed!", .{});
                        return error.OutOfMemory;
                    },
                ) catch |err| {
                    if (debug) log.err("failed to add entry from file '{s} with: '{any}'", .{ file_path, err });
                    return err;
                };
            }

            return parsed_file.value.meta;
        }

        fn parseContent(comptime JsonFileT: type, alloc: Allocator, content: []const u8) !std.json.Parsed(JsonFileT) {
            return std.json.parseFromSlice(JsonFileT, alloc, content, parse_options) catch |err| {
                if (debug) log.err("failed to parse json from content with: '{any}'", .{err});
                return err;
            };
        }

        fn readFile(alloc: Allocator, file_path: []const u8) ![]const u8 {
            var file = std.fs.openFileAbsolute(file_path, .{ .lock = .exclusive }) catch |err| {
                if (debug) log.err("failed to open file '{s}' with: '{any}'", .{ file_path, err });
                return err;
            };
            defer file.close();

            file.seekTo(0) catch |err| {
                if (debug) log.err("failed to seek in file '{s}' with: '{any}'", .{ file_path, err });
                return err;
            };

            return file.readToEndAlloc(alloc, std.math.maxInt(usize)) catch |err| switch (err) {
                error.OutOfMemory => {
                    if (debug) log.err("allocation failed!", .{});
                    return err;
                },
                else => {
                    if (debug) log.err("failed to read from file '{s}' with: '{any}'", .{ file_path, err });
                    return err;
                },
            };
        }
    };
}
