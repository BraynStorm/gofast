const std = @import("std");
const assert = std.debug.assert;

/// An array that uses @Vector as an underlying storage,
/// and uses a sentinel value for length.
///
/// Basically, a convenience wrapper around @Vector(cap, T) and std.simd.
///
/// If maybeCapacity is null, it uses std.simd.suggestVectorLength(T) to get
/// a good capacity.
pub fn SIMDSentinelArray(comptime T: type, maybeCapacity: ?usize, sentinel: T) type {
    return struct {
        items: Vector,

        pub const capacity = if (maybeCapacity) |c| c else ( //
            std.simd.suggestVectorLength(T) orelse {
            @compileError( //
                "std.simd.suggestVectorLength is not implemented for your platform." ++ //
                "Provide a `cap` for SIMDSentinelArray."
            //
            );
        });
        pub const Vector = @Vector(capacity, T);
        const Index = std.simd.VectorIndex(Vector);
        const Count = std.simd.VectorCount(Vector);
        const Self = @This();

        /// Initialize the whole array to sentinels.
        pub inline fn init() Self {
            // Require the capcity to be an even number.
            // TODO: Also require to be a power of two, but that's beside the point.
            comptime assert(((@sizeOf(T) * capacity) % 2 == 0));
            return Self{ .items = @splat(sentinel) };
        }

        /// Get an array from this vector.
        pub inline fn array(self: *const Self) [capacity]T {
            return self.items;
        }

        /// Compute the length of the array
        /// O(n) technically, but can be SIMDd
        pub inline fn len(self: *const Self) usize {
            return std.simd.firstIndexOfValue(self.items, sentinel) orelse capacity;
        }
        /// Find the index where this
        pub inline fn indexOf(self: *const Self, item: T) ?Index {
            assert(item != sentinel);
            return std.simd.firstIndexOfValue(self.items, item);
        }

        pub inline fn clear(self: *Self) void {
            if (sentinel == 0) {
                self.items = self.items ^ self.items;
            } else {
                // PERF: Experiment with the following instead
                // self.items = Vector{[_]T{sentinel} ++ [_]T{undefined} ** capacity - 1};
                self.items[0] = sentinel;
            }
        }

        pub inline fn maybeAddOne(self: *Self, item: T) bool {
            assert(item != sentinel);
            if (std.simd.firstIndexOfValue(self.items, sentinel)) |idx| {
                self.items[idx] = item;
                return true;
            } else {
                return false;
            }
        }

        pub inline fn maybeRemoveOne(self: *Self, item: T) bool {
            // Find the item, or fail.
            const index = self.indexOf(item) orelse return false;
            const simd = std.simd;
            const v: Vector = self.items;

            const vindex: @Vector(capacity, i32) = @splat(@as(i32, @intCast(index)));
            const iota = simd.iota(i32, capacity);
            self.items = @select(T, iota < vindex, v, std.simd.shiftElementsLeft(v, 1, sentinel));
            return true;
        }
    };
}

test SIMDSentinelArray {
    const TEST = std.testing;

    const Arr = SIMDSentinelArray(u32, null, 0);
    // No padding
    try TEST.expectEqual(@sizeOf(Arr), Arr.capacity * 4);
    // Excatly one cache-line
    try TEST.expectEqual(@sizeOf(Arr), 64);

    var arr = Arr.init();

    // Cap for u32 @ 64b cacheline = 16
    try TEST.expectEqual(Arr.capacity, 16);

    try TEST.expectEqual(arr.len(), 0);

    // Failed removes don't change anything.
    try TEST.expect(!arr.maybeRemoveOne(3));
    try TEST.expect(!arr.maybeRemoveOne(2));
    try TEST.expect(!arr.maybeRemoveOne(1));
    try TEST.expectEqual(0, arr.len());

    try TEST.expect(arr.maybeAddOne(1));
    try TEST.expectEqual(1, arr.len());
    try TEST.expect(arr.maybeAddOne(2));
    try TEST.expect(arr.maybeAddOne(3));
    try TEST.expect(arr.maybeAddOne(4));
    try TEST.expect(arr.maybeAddOne(5));
    try TEST.expect(arr.maybeAddOne(6));
    try TEST.expect(arr.maybeAddOne(7));
    try TEST.expect(arr.maybeAddOne(8));
    try TEST.expect(arr.maybeAddOne(9));
    try TEST.expect(arr.maybeAddOne(10));
    try TEST.expect(arr.maybeAddOne(11));
    try TEST.expect(arr.maybeAddOne(12));
    try TEST.expect(arr.maybeAddOne(13));
    try TEST.expect(arr.maybeAddOne(14));
    try TEST.expect(arr.maybeAddOne(15));
    try TEST.expect(arr.maybeAddOne(16));
    try TEST.expectEqual(16, arr.len());
    try TEST.expect(!arr.maybeAddOne(17));
    try TEST.expectEqual(16, arr.len());

    try TEST.expect(arr.maybeRemoveOne(3));
    try TEST.expectEqual(15, arr.len());
    try TEST.expect(arr.maybeRemoveOne(1));
    try TEST.expectEqual(14, arr.len());
    try TEST.expect(arr.maybeRemoveOne(2));
    try TEST.expectEqual(13, arr.len());
    try TEST.expect(arr.maybeRemoveOne(4));
    try TEST.expectEqual(12, arr.len());

    try TEST.expectEqual(5, arr.items[0]);
    try TEST.expectEqual(6, arr.items[1]);

    // In General.
    for (0..arr.len()) |i| {
        try TEST.expectEqual(i + 5, arr.items[i]);
    }
}
