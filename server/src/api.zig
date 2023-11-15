const std = @import("std");
const log = std.log;
const eql = std.mem.eql;

const State = @import("State.zig");

const groups = @import("api/groups.zig");
const files = @import("api/files.zig");

pub const HttpMethod = common.HttpMethod;
pub const HttpRequest = common.HttpRequest;
pub const HttpResult = common.HttpResult;

const common = @import("api/common.zig");

const Route = struct {
    const Handeler = fn (HttpRequest, *State) HttpResult;

    method: HttpMethod,
    path: []const u8,
    handeler: Handeler,
};

const routes = [_]Route{
    .{ .method = .GET, .path = "groups/list", .handeler = groups.list },
    .{ .method = .POST, .path = "groups/create", .handeler = groups.create },
    .{ .method = .GET, .path = "groups/read", .handeler = groups.read },
    .{ .method = .POST, .path = "groups/update", .handeler = groups.update },
    .{ .method = .POST, .path = "groups/delete", .handeler = groups.delete },
    //
    .{ .method = .GET, .path = "files/list", .handeler = files.list },
    .{ .method = .POST, .path = "files/create", .handeler = files.create },
    .{ .method = .GET, .path = "files/read", .handeler = files.read },
    .{ .method = .POST, .path = "files/update", .handeler = files.update },
    .{ .method = .POST, .path = "files/delete", .handeler = files.delete },
};

pub fn handel(request: HttpRequest, state: *State) HttpResult {
    inline for (routes) |route| {
        if (eql(u8, request.path, route.path)) {
            if (request.method != route.method) {
                log.err("Method Not Allowed", .{});
                return HttpResult{ .code = 405, .body = "error: method not allowed" };
            } else {
                return route.handeler(request, state);
            }
        }
    }

    log.err("Not Found", .{});
    return HttpResult{ .code = 404, .body = "error: not found" };
}
