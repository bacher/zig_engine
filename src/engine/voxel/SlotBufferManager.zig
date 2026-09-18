const std = @import("std");

const VOXEL_GRID_SLOT_COUNT = @import("./voxel_consts.zig").VOXEL_GRID_SLOT_COUNT;

/// Tracks occupancy of a fixed-size GPU buffer where each slot is one abstract unit
/// (one `ChunkInfo`). Allocation and free are O(capacity / SIMD width).
pub const SlotBufferManager = struct {
    const Self = @This();

    pub const SLOT_COUNT: u32 = VOXEL_GRID_SLOT_COUNT;
    pub const BITS_PER_WORD: u32 = 64;
    pub const WORD_COUNT: u32 = SLOT_COUNT / BITS_PER_WORD;
    const VECTOR_WIDTH: u32 = 8;
    const Vec = @Vector(VECTOR_WIDTH, u64);
    const LaneMask = std.meta.Int(.unsigned, VECTOR_WIDTH);

    const FULL_WORD: u64 = std.math.maxInt(u64);
    const FULL_VEC: Vec = @splat(FULL_WORD);

    occupancy: [WORD_COUNT]u64 align(@alignOf(Vec)) = @splat(0),

    comptime {
        std.debug.assert(SLOT_COUNT >= 4 * 1024);
        std.debug.assert(SLOT_COUNT % BITS_PER_WORD == 0);
        std.debug.assert(WORD_COUNT % VECTOR_WIDTH == 0);
    }

    pub fn occupyBlock(self: *Self) error{NoSpaceLeft}!u32 {
        var word_index: u32 = 0;
        while (word_index < WORD_COUNT) : (word_index += VECTOR_WIDTH) {
            const vec: Vec = self.occupancy[word_index..][0..VECTOR_WIDTH].*;
            const has_free: @Vector(VECTOR_WIDTH, bool) = vec != FULL_VEC;
            if (!@reduce(.Or, has_free)) continue;

            const lane: u32 = @ctz(@as(LaneMask, @bitCast(has_free)));
            const words: [VECTOR_WIDTH]u64 = vec;
            const word = words[lane];
            const bit: u32 = @ctz(~word);
            const global_word = word_index + lane;
            self.occupancy[global_word] = word | (@as(u64, 1) << @intCast(bit));
            return global_word * BITS_PER_WORD + bit;
        }

        return error.NoSpaceLeft;
    }

    pub fn freeBlock(self: *Self, slot_index: u32) void {
        std.debug.assert(slot_index < SLOT_COUNT);
        const word_index = slot_index / BITS_PER_WORD;
        const bit: u6 = @intCast(slot_index % BITS_PER_WORD);
        self.occupancy[word_index] &= ~(@as(u64, 1) << bit);
    }
};

test "occupyBlock returns consecutive slot indices" {
    var manager: SlotBufferManager = .{};

    try std.testing.expectEqual(0, try manager.occupyBlock());
    try std.testing.expectEqual(1, try manager.occupyBlock());
    try std.testing.expectEqual(2, try manager.occupyBlock());
}

test "freeBlock reuses the lowest freed slot" {
    var manager: SlotBufferManager = .{};

    const first = try manager.occupyBlock();
    const second = try manager.occupyBlock();
    const third = try manager.occupyBlock();
    try std.testing.expectEqual(0, first);
    try std.testing.expectEqual(1, second);
    try std.testing.expectEqual(2, third);

    manager.freeBlock(second);
    try std.testing.expectEqual(second, try manager.occupyBlock());
}

test "a hole in a later SIMD group is found" {
    var manager: SlotBufferManager = .{};
    const hole_index: u32 = SlotBufferManager.BITS_PER_WORD * SlotBufferManager.VECTOR_WIDTH + 3;

    for (0..hole_index + 1) |_| {
        _ = try manager.occupyBlock();
    }

    manager.freeBlock(hole_index);
    try std.testing.expectEqual(hole_index, try manager.occupyBlock());
}

test "filling every slot then fails with NoSpaceLeft" {
    var manager: SlotBufferManager = .{};

    for (0..SlotBufferManager.SLOT_COUNT) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), try manager.occupyBlock());
    }

    try std.testing.expectError(error.NoSpaceLeft, manager.occupyBlock());

    manager.freeBlock(SlotBufferManager.SLOT_COUNT - 1);
    try std.testing.expectEqual(SlotBufferManager.SLOT_COUNT - 1, try manager.occupyBlock());
    try std.testing.expectError(error.NoSpaceLeft, manager.occupyBlock());
}

test "freeing the first slot after filling reuses index 0" {
    var manager: SlotBufferManager = .{};

    for (0..SlotBufferManager.SLOT_COUNT) |_| {
        _ = try manager.occupyBlock();
    }

    manager.freeBlock(0);
    manager.freeBlock(17);
    try std.testing.expectEqual(0, try manager.occupyBlock());
    try std.testing.expectEqual(17, try manager.occupyBlock());
}
