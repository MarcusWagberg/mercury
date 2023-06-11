const std = @import("std");
const zap = @import("zap");
const clap = @import("clap");

const log = std.log;

const DEFAULT_INTERFACE: []const u8 = "127.0.0.1";
const DEFAULT_PORT: usize = 3000;

pub fn main() u8 {
    const stderr = std.io.getStdErr().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-i, --interface <str>    Interface to listen on.
        \\-p, --port <usize>       Port to listen on.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag }) catch |err| {
        diag.report(stderr, err) catch {};
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        stderr.print("Usage: mercury\n", .{}) catch return 1;
        clap.help(stderr, clap.Help, &params, .{}) catch {
            log.err("failed to output help message!", .{});
            return 1;
        };
        return 0;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) {
        log.err("general memory leak detected!", .{});
    };
    const alloc = gpa.allocator();

    const interface: [:0]const u8 = alloc.dupeZ(u8, if (res.args.interface) |int| int else DEFAULT_INTERFACE) catch {
        log.err("allocation failed!", .{});
        return 1;
    };
    defer alloc.free(interface);

    const port: usize = res.args.port orelse DEFAULT_PORT;

    log.info("starting mercury", .{});

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

    r.sendBody("<html><body><h1>Hello from MERCURY!!!</h1></body></html>") catch return;
}
