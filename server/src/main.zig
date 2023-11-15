const std = @import("std");
const zap = @import("zap");
const clap = @import("clap");
const log = std.log;
const startsWith = std.mem.startsWith;

const api = @import("api.zig");

const Args = @import("Args.zig");
const State = @import("State.zig");

var mercury_state: State = undefined;

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) {
        log.err("general memory leak detected!", .{});
    };
    const alloc = gpa.allocator();

    const args = Args.parse(alloc) catch |err| switch (err) {
        error.Stderr => {
            log.err("failed to output to stderr!", .{});
            return 1;
        },
        error.Alloc => {
            log.err("allocation failed!", .{});
            return 1;
        },
        error.Parse => {
            log.err("arg parse failed!", .{});
            return 1;
        },
        error.Help => return 0,
    };
    defer args.free(alloc);

    mercury_state = State.init(alloc, args.data_dir) catch return 1;
    defer mercury_state.deinit();

    log.info("starting mercury with data path: {s}", .{mercury_state.data_path});

    var listener = zap.SimpleHttpListener.init(.{
        .port = args.port,
        .on_request = onRequest,
        .log = false,
        .max_clients = 100000,
    });

    listener.listen() catch {
        log.err("failed to listen on {s}:{d}", .{ args.interface, args.port });
    };

    log.info("listening on http://{s}:{d}", .{ args.interface, args.port });

    zap.start(.{
        .threads = 2,
        .workers = 2,
    });

    return 0;
}

pub fn internalError(r: *const zap.SimpleRequest) void {
    r.h.*.status = 500;
    r.sendBody("") catch return;
}

fn onRequest(r: zap.SimpleRequest) void {
    var timer: ?std.time.Timer = std.time.Timer.start() catch blk: {
        log.err("timer is unavailable", .{});
        break :blk null;
    };

    const method_slice = r.method orelse "";
    const path = r.path orelse "";
    const query = r.query orelse "";

    log.info("{s}{s}{s}{s}{s}", .{
        method_slice,
        if (method_slice.len > 0) " " else "",
        path,
        if (query.len > 0) "?" else "",
        query,
    });

    var status: usize = 200;
    defer {
        if (timer != null) {
            log.info("RESP {d} after {any}", .{ status, std.fmt.fmtDuration(timer.?.read()) });
        } else {
            log.info("RESP {d} ", .{status});
        }
    }

    const method = api.HttpMethod.fromSlice(method_slice) catch {
        log.err("invalid http method: '{s}'", .{method_slice});

        status = 400;
        r.h.*.status = status;

        const body = std.fmt.allocPrint(
            mercury_state.alloc,
            "error: invalid http method: '{s}'",
            .{method_slice},
        ) catch blk: {
            log.err("allocation failed!", .{});
            break :blk null;
        };
        defer if (body) |b| mercury_state.alloc.free(b);

        r.sendBody(body orelse "") catch return;
        return;
    };

    const result: api.HttpResult = result: {
        const api_path: []const u8 = "/api/";
        if (startsWith(u8, path, api_path)) break :result api.handel(
            api.HttpRequest{
                .method = method,
                .path = path[api_path.len..],
                .query = query,
                .body = r.body orelse "",
            },
            &mercury_state,
        );

        break :result api.HttpResult{ .code = 404, .body = "error: not found" };
    };
    defer if (result.free_body) mercury_state.alloc.free(result.body);

    status = result.code;
    r.h.*.status = status;

    if (result.content_type) |content_type| r.setHeader("content-type", content_type) catch internalError(&r);
    r.sendBody(result.body) catch internalError(&r);
}
