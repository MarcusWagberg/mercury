const Allocator = @import("std").mem.Allocator;

pub const V1 = struct {
    pub const version = 1;
    const Self = @This();

    name: []const u8,
    ftype: []const u8,
    group: [36]u8,
    uploaded: i128,

    pub fn free(self: *const Self, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.ftype);
    }

    pub fn copy(self: *const Self, alloc: Allocator) ?Self {
        return Self{
            .name = alloc.dupe(u8, self.name) catch return null,
            .ftype = alloc.dupe(u8, self.ftype) catch return null,
            .group = self.group,
            .uploaded = self.uploaded,
        };
    }
};

pub const Latest = V1;
