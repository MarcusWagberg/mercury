const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;

const storage = @import("storage.zig");

const Group = @import("Group.zig");
const File = @import("File.zig");

const State = @This();

pub const GroupStore = storage.JsonFileStore(Group, true);
pub const FileStore = storage.JsonFileStore(File, true);

alloc: Allocator,
data_path: []const u8,
group_store: GroupStore,
file_store: FileStore,

pub fn init(alloc: Allocator, data: []const u8) !State {
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

    return State{
        .alloc = alloc,
        .data_path = data_path,
        .group_store = group_store,
        .file_store = file_store,
    };
}

pub fn deinit(self: *State) void {
    self.group_store.deinit();
    self.file_store.deinit();
    self.alloc.free(self.data_path);
}
