const std = @import("std");
const Allocator = std.mem.Allocator;

/// TODO Actually make it a small string :D.
s: []u8,

const ShortString = @This();

pub inline fn fromSlice(alloc: Allocator, sl: []const u8) !ShortString {
    const ss = ShortString{ .s = try alloc.alloc(u8, sl.len) };
    @memcpy(ss.s, sl);
    return ss;
}
/// Take ownership of the slice.
pub inline fn fromOwnedSlice(sl: []u8) !ShortString {
    return .{ .s = sl };
}
pub inline fn deinit(self: *ShortString, alloc: Allocator) void {
    alloc.free(self.s);
}
