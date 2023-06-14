const std = @import("std");
const zap = @import("zap");
const clap = @import("clap");
const log = std.log;

const me = @import("mercury_error.zig");

const Data = @import("Data.zig");

const DEFAULT_INTERFACE: []const u8 = "127.0.0.1";
const DEFAULT_PORT: usize = 3000;
const DEFAULT_DATA_DIR: []const u8 = "data";

var mercury_data: Data = undefined;

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
        diag.report(stderr, err) catch return me.stderr_error();
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        stderr.print("Usage: mercury\n", .{}) catch return me.stderr_error();
        clap.help(stderr, clap.Help, &params, .{}) catch return me.stderr_error();
        return 0;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) {
        log.err("general memory leak detected!", .{});
    };
    const alloc = gpa.allocator();

    const interface: [:0]const u8 = alloc.dupeZ(u8, if (res.args.interface) |int| int else DEFAULT_INTERFACE) catch return me.alloc_error();
    defer alloc.free(interface);

    const port = res.args.port orelse DEFAULT_PORT;

    mercury_data = Data.init(alloc, res.args.data orelse DEFAULT_DATA_DIR) catch return 1;
    defer mercury_data.deinit();

    log.info("starting mercury with data path: {s}", .{mercury_data.data_path});

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

fn on_request(r: zap.SimpleRequest) void {
    log.info("{s}{s}{s}{s}{s}", .{
        r.method orelse "",
        if (r.method != null) " " else "",
        r.path orelse "",
        if (r.query != null) "?" else "",
        r.query orelse "",
    });
    defer log.info("RESP {d}", .{r.h.*.status});

    //r.sendBody("<html><body><h1>Hello from MERCURY!!!</h1></body></html>") catch return;

    const l_groups = mercury_data.group_store.list();
    if (l_groups.isError()) {
        const html = std.fmt.allocPrint(mercury_data.alloc, "<html><body><h1>ERROR: {s}</h1></body></html>", .{l_groups.getErrorMsg()}) catch return;
        defer mercury_data.alloc.free(html);
        r.sendBody(html) catch return;
        log.err("{s}", .{l_groups.getErrorMsg()});
        return;
    }
    defer l_groups.ok.free(mercury_data.alloc);

    const l_files = mercury_data.file_store.list();
    if (l_files.isError()) {
        const html = std.fmt.allocPrint(mercury_data.alloc, "<html><body><h1>ERROR: {s}</h1></body></html>", .{l_files.getErrorMsg()}) catch return;
        defer mercury_data.alloc.free(html);
        r.sendBody(html) catch return;
        log.err("{s}", .{l_files.getErrorMsg()});
        return;
    }
    defer l_files.ok.free(mercury_data.alloc);

    const ReturnJson = struct {
        groups: []Data.GroupStore.Entry,
        files: []Data.FileStore.Entry,
    };
    const ret_json = ReturnJson{
        .groups = l_groups.ok.slice,
        .files = l_files.ok.slice,
    };

    r.sendJson(std.json.stringifyAlloc(mercury_data.alloc, ret_json, .{}) catch return) catch return;
}
