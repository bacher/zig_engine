const std = @import("std");

pub fn calculateDataSlotSizeLevel(slots: f32) u8 {
    return @intFromFloat(@ceil(std.math.log2(@ceil(slots))));
}

// 0 = 1 block
// 1 = 2 blocks
// 2 = 4 blocks
// 3 = 8 blocks
// 4 = 16 blocks
// 5 = 32 blocks
// 6 = 64 blocks (6 is actually maximum allowed at this point)
// 7 = 128 blocks
// 8 = 256 blocks
// 9 = 512 blocks
// 10 = 1024 blocks
// 11 = 2048 blocks
// 12 = 4096 blocks
// 13 = 8192 blocks

test "calculateDataSlotSizeLevel works correctly" {
    try std.testing.expectEqual(calculateDataSlotSizeLevel(0.1), 0);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(0.99), 0);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(1.0), 0);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(1.0001), 1);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(1.99), 1);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(2.0), 1);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(2.0001), 2);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(3.0), 2);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(3.99), 2);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(4.0), 2);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(4.0001), 3);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(5.0), 3);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(8.0), 3);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(8.1), 4);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(16), 4);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(16.001), 5);
    try std.testing.expectEqual(calculateDataSlotSizeLevel(64), 6);
}
