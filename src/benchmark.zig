const std = @import("std");
const benchmark = @import("benchmark");
const B = *benchmark.B;

pub const main = benchmark.main(.{}, struct {
    pub fn bench_zero(b: B) !void {
        while (b.step()) {
            for (0..100) |i| {
                _ = i;
            }
        }
    }
});
