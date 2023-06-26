const Allocator = @import("std").mem.Allocator;

pub const V1 = struct {
    pub const version = 1;
    const Self = @This();

    name: []const u8,

    pub fn free(self: *const Self, alloc: Allocator) void {
        alloc.free(self.name);
    }

    pub fn copy(self: *const Self, alloc: Allocator) ?Self {
        return Self{
            .name = alloc.dupe(u8, self.name) catch return null,
        };
    }
};

pub const Latest = V1;
