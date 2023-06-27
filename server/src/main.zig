const std = @import("std");
const zap = @import("zap");
const clap = @import("clap");
const log = std.log;

const State = @import("State.zig");

const DEFAULT_INTERFACE: []const u8 = "127.0.0.1";
const DEFAULT_PORT: usize = 3000;
const DEFAULT_DATA_DIR: []const u8 = "data";

var mercury_state: State = undefined;

pub fn main() u8 {
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
        diag.report(stderr, err) catch return stderr_error();
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        stderr.print("Usage: mercury\n", .{}) catch return stderr_error();
        clap.help(stderr, clap.Help, &params, .{}) catch return stderr_error();
        return 0;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) {
        log.err("general memory leak detected!", .{});
    };
    const alloc = gpa.allocator();

    const interface: [:0]const u8 = alloc.dupeZ(u8, if (res.args.interface) |int| int else DEFAULT_INTERFACE) catch return alloc_error();
    defer alloc.free(interface);

    const port = res.args.port orelse DEFAULT_PORT;

    mercury_state = State.init(alloc, res.args.data orelse DEFAULT_DATA_DIR) catch return 1;
    defer mercury_state.deinit();

    log.info("starting mercury with data path: {s}", .{mercury_state.data_path});

    var listener = zap.SimpleHttpListener.init(.{
        .port = port,
        .on_request = on_request,
        .log = false,
        .max_clients = 100000,
    });

    listener.listen() catch {
        log.err("failed to listen on {s}:{d}", .{ interface, port });
    };

    log.info("listening on http://{s}:{d}", .{ interface, port });

    zap.start(.{
        .threads = 2,
        .workers = 2,
    });

    return 0;
}

pub fn stderr_error() u8 {
    log.err("failed to output to stderr!", .{});
    return 1;
}

pub fn alloc_error() u8 {
    log.err("allocation failed!", .{});
    return 1;
}

fn on_request(r: zap.SimpleRequest) void {
    log.info("{s}{s}{s}{s}{s}", .{
        r.method orelse "",
        if (r.method != null) " " else "",
        r.path orelse "",
        if (r.query != null) "?" else "",
        r.query orelse "",
    });
    defer log.info("RESP {d}", .{r.h.*.status});

    //r.sendBody("<html><body><h1>Hello from MERCURY!!!</h1></body></html>") catch return;s

    var groups = mercury_state.group_store.list(mercury_state.alloc) catch return;
    defer groups.free();

    var files = mercury_state.file_store.list(mercury_state.alloc) catch return;
    defer files.free();

    const ReturnJson = struct {
        groups: []State.GroupStore.LatestEntry,
        files: []State.FileStore.LatestEntry,
    };
    const ret_json = ReturnJson{
        .groups = groups.entries,
        .files = files.entries,
    };

    const json = std.json.stringifyAlloc(mercury_state.alloc, ret_json, .{}) catch return;
    defer mercury_state.alloc.free(json);

    r.sendJson(json) catch return;
}
