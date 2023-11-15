const std = @import("std");
const log = std.log;
const eql = std.mem.eql;

pub const HttpMethod = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,

    pub fn fromSlice(slice: []const u8) error{InvalidMethod}!HttpMethod {
        if (eql(u8, slice, "GET") or eql(u8, slice, "get")) {
            return HttpMethod.GET;
        } else if (eql(u8, slice, "HEAD") or eql(u8, slice, "head")) {
            return HttpMethod.HEAD;
        } else if (eql(u8, slice, "POST") or eql(u8, slice, "post")) {
            return HttpMethod.POST;
        } else if (eql(u8, slice, "PUT") or eql(u8, slice, "put")) {
            return HttpMethod.PUT;
        } else if (eql(u8, slice, "DELETE") or eql(u8, slice, "delete")) {
            return HttpMethod.DELETE;
        } else if (eql(u8, slice, "CONNECT") or eql(u8, slice, "connect")) {
            return HttpMethod.CONNECT;
        } else if (eql(u8, slice, "OPTIONS") or eql(u8, slice, "options")) {
            return HttpMethod.OPTIONS;
        } else if (eql(u8, slice, "TRACE") or eql(u8, slice, "trace")) {
            return HttpMethod.TRACE;
        } else if (eql(u8, slice, "PATCH") or eql(u8, slice, "patch")) {
            return HttpMethod.PATCH;
        } else {
            return error.InvalidMethod;
        }
    }
};

pub const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    query: []const u8,
    body: []const u8 = "",
};

pub const HttpResult = struct {
    code: usize = 200,
    body: []const u8 = "",
    free_body: bool = false,
    content_type: ?[]const u8 = null,
};

pub const InternalErrorResult = HttpResult{ .code = 500 };
pub const InvalidQueryResult = HttpResult{ .code = 400, .body = "error: invalid Query" };

pub fn parseQuery(alloc: std.mem.Allocator, query: []const u8) !std.StringHashMap([]const u8) {
    const valied_chars: []const u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

    var hash_map = std.StringHashMap([]const u8).init(alloc);
    errdefer hash_map.deinit();

    var inside_key = false;
    var key_start: usize = 0;
    var key_len: usize = 0;
    var inside_value = false;
    var value_start: usize = 0;
    var value_len: usize = 0;

    main: for (query, 0..query.len) |c, i| {
        if (!inside_key and !inside_value) {
            inside_key = true;
            key_start = i;
            key_len = 1;
        } else if (inside_key) {
            if (c == '=') {
                inside_key = false;
                inside_value = true;
                value_start = i + 1;
                value_len = 0;
                continue :main;
            }

            for (valied_chars) |vc| if (c == vc) {
                key_len += 1;
                continue :main;
            };
            log.err("invalid Query: '{s}'", .{query});
            return error.InvalidQuery;
        } else if (inside_value) {
            if ((value_len > 0 and c == '&') or i == query.len - 1) {
                blk: {
                    if (c != '&') {
                        for (valied_chars) |vc| if (c == vc) {
                            value_len += 1;
                            break :blk;
                        };
                        log.err("invalid Query: '{s}'", .{query});
                        return error.InvalidQuery;
                    }
                }

                hash_map.put(query[key_start .. key_start + key_len], query[value_start .. value_start + value_len]) catch {
                    log.err("allocation failed!", .{});
                    return error.OutOfMemory;
                };

                inside_key = false;
                inside_value = false;
                continue :main;
            }

            for (valied_chars) |vc| if (c == vc) {
                value_len += 1;
                continue :main;
            };
            log.err("invalid Query: '{s}'", .{query});
            return error.InvalidQuery;
        } else unreachable;
    }

    if (inside_key or inside_value) {
        log.err("invalid Query: '{s}'", .{query});
        return error.InvalidQuery;
    }

    return hash_map;
}

pub fn getIdFromSlice(slice: []const u8) ![36]u8 {
    const valied_chars: []const u8 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

    if (slice.len != 36) {
        log.err("id slice of invalid length: '{d}' should be: '36'", .{slice.len});
        return error.InvalidLength;
    }

    main: for (slice) |c| {
        for (valied_chars) |vc| {
            if (c == vc) continue :main;
        }

        log.err("id slice contains invalid char: '{c}'", .{c});
        return error.InvalidChar;
    }

    var id: [36]u8 = undefined;
    for (&id, 0..id.len) |*c, i| c.* = slice[i];

    return id;
}

pub fn getIdFromQuery(alloc: std.mem.Allocator, query: []const u8, id_out: *[36]u8) ?HttpResult {
    var query_map = parseQuery(alloc, query) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
        error.InvalidQuery => return InvalidQueryResult,
    };
    defer query_map.deinit();

    const id_slice = query_map.get("id") orelse {
        log.err("missing query param 'id'", .{});
        return HttpResult{ .code = 400, .body = "error: missing query param 'id'" };
    };

    const id = getIdFromSlice(id_slice) catch |err| switch (err) {
        error.InvalidLength => return HttpResult{ .code = 400, .body = "error: query param 'id' of invalid length" },
        error.InvalidChar => return HttpResult{ .code = 400, .body = "error: query param 'id' contains one or more invalid characters" },
    };

    id_out.* = id;
    return null;
}
