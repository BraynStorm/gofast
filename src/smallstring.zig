const std = @import("std");
const Allocator = std.mem.Allocator;

/// TODO Actually make it a small string :D.
///
pub const ShortString = struct {
    s: []u8,

    const Self = @This();

    pub inline fn fromSlice(sl: []const u8, alloc: Allocator) !ShortString {
        const ss = ShortString{ .s = try alloc.alloc(u8, sl.len) };
        @memcpy(ss.s, sl);
        return ss;
    }
    /// Take ownership of the slice.
    pub inline fn fromOwnedSlice(sl: []u8) !ShortString {
        return .{ .s = sl };
    }
    pub inline fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.s);
    }
};
