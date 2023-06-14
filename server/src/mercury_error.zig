const std = @import("std");
const log = std.log;

pub fn Result(comptime okT: type, comptime errT: type) type {
    return union(enum) {
        const Self = @This();

        const ERR = struct {
            msg_buf: [128]u8,
            msg: []const u8,
            err_type: errT,
        };

        ok: okT,
        err: ERR,
        buf_err: void,

        pub fn asOk(result: okT) Self {
            return Self{
                .ok = result,
            };
        }

        pub fn asError(comptime msg: []const u8, err_type: errT, err: anytype) Self {
            return asErrorExtraArgs(msg, .{}, err_type, err);
        }

        pub fn asErrorExtraArgs(comptime msg: []const u8, args: anytype, err_type: errT, err: anytype) Self {
            var ret = Self{ .err = .{
                .msg_buf = undefined,
                .msg = undefined,
                .err_type = err_type,
            } };
            if (@TypeOf(err) == void) {
                ret.err.msg = std.fmt.bufPrint(ret.err.msg_buf[0..], msg, args) catch return Self{ .buf_err = {} };
            } else {
                ret.err.msg = std.fmt.bufPrint(ret.err.msg_buf[0..], msg ++ " with: {any}", args ++ .{err}) catch return Self{ .buf_err = {} };
            }
            return ret;
        }

        pub fn isError(self: *const Self) bool {
            switch (self.*) {
                .ok => return false,
                .err => return true,
                .buf_err => return true,
            }
        }

        pub fn getErrorMsg(self: *const Self) []const u8 {
            switch (self.*) {
                .ok => return "getErrorMsg called on a Result.ok",
                .err => |e| return e.msg,
                .buf_err => return "Result.err.msg buffer overflowed!!!",
            }
        }
    };
}

pub fn stderr_error() u8 {
    log.err("failed to output to stderr!", .{});
    return 1;
}

pub fn alloc_error() u8 {
    log.err("allocation failed!", .{});
    return 1;
}
