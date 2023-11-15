const std = @import("std");
const clap = @import("clap");

const DEFAULT_INTERFACE: []const u8 = "127.0.0.1";
const DEFAULT_PORT: usize = 3000;
const DEFAULT_DATA_DIR: []const u8 = "data";

const Args = @This();

interface: [:0]const u8,
port: usize,
data_dir: []const u8,

pub fn parse(alloc: std.mem.Allocator) error{ Stderr, Alloc, Parse, Help }!Args {
    const stderr = std.io.getStdErr().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-i, --interface <str>    Interface to listen on.
        \\-p, --port <usize>       Port to listen on.
        \\-d, --data <str>         Path to data directory.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag }) catch |err| {
        diag.report(stderr, err) catch return error.Stderr;
        return error.Parse;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        stderr.print("Usage: mercury\n", .{}) catch return error.Stderr;
        clap.help(stderr, clap.Help, &params, .{}) catch return error.Stderr;
        return error.Help;
    } else {
        return Args{
            .interface = alloc.dupeZ(u8, if (res.args.interface) |int| int else DEFAULT_INTERFACE) catch return error.Alloc,
            .port = res.args.port orelse DEFAULT_PORT,
            .data_dir = res.args.data orelse DEFAULT_DATA_DIR,
        };
    }
}

pub fn free(self: *const Args, alloc: std.mem.Allocator) void {
    alloc.free(self.interface);
}
