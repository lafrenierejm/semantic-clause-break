const std = @import("std");

pub fn main() void {
    std.debug.print("Hello, world!\n", .{});
}

test "basic" {
    try std.testing.expect(1 + 1 == 2);
}
