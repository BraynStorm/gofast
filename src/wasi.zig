const std = @import("std");
const Gofast = @import("gofast.zig").Gofast;

export fn add(a: f64, b: f64) f64 {
    return a + b;
}

export fn u32_to_f32(i: i32) f32 {
    return @bitCast(i);
}

// pub fn main() u8 {
//     std.debug.print("Hello WASM64!", .{});
//     return 0;
// }
