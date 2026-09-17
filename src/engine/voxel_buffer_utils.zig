const std = @import("std");

const VOXEL_GRID_SLOT_COUNT = @import("./voxel_consts.zig").VOXEL_GRID_SLOT_COUNT;

const MAX_SPAN_SIZE_EXPONENT = 6;

const SLOTS_PER_SPAN: u32 = 1 << MAX_SPAN_SIZE_EXPONENT; // 64

// 4096 blocks
// block = 1024 bytes
// 64 spans
// 1 span = 64 regular blocks
// 1 span = 32 2x blocks
// 1 span = 16 4x blocks
// 1 span = 8 8x blocks
// 1 span = 4 16x blocks
// 1 span = 2 32x blocks -- do we need 32x blocks?

fn lowNBits(n: u32) u64 {
    if (n >= 64) {
        return std.math.maxInt(u64); // all 64 bits set
    }
    if (n == 0) {
        return 0;
    }
    return (@as(u64, 1) << @intCast(n)) - 1;
}

pub const BufferSpan = struct {
    // occupancy bitmask: 0 = free, 1 = occupied
    map: u64 = 0,
    // size exponent this span is currently allocated for
    size: u8 = 0,
};

const SpanList = std.MultiArrayList(BufferSpan);

pub const GpuBufferManager = struct {
    const Self = @This();

    // pub const SPAN_COUNT = @divExact(VOXEL_GRID_SLOT_COUNT, SLOTS_PER_SPAN);
    pub const SPAN_COUNT = 64;

    // meta map holds a bit mask for each span size, 1 means the span is not full, 0 means the span can't be used for
    // this size (it's either already full or it's used for a different size)
    // initially all 0 because there are no spans yet
    span_meta_maps: [MAX_SPAN_SIZE_EXPONENT + 1]u64 = @splat(0),
    // SoA backing store for BufferSpan { map, size }; accessed via spanList().get/set
    span_storage: [SpanList.capacityInBytes(SPAN_COUNT)]u8 align(@alignOf(BufferSpan)) = @splat(0),
    span_count: u32 = 0,

    fn spanList(self: *Self) SpanList {
        return .{
            .bytes = &self.span_storage,
            .len = SPAN_COUNT,
            .capacity = SPAN_COUNT,
        };
    }

    fn findFirstNonFullSpan(self: *const Self, size_exponent: u8) error{NotFound}!u32 {
        const meta_map = self.span_meta_maps[size_exponent];

        if (meta_map == 0) {
            return error.NotFound;
        }

        var interval_start: u32 = 0;
        for (0..6) |iteration| {
            // bit width of the current interval, basically 2^(5 - iteration)
            const width = @as(u32, 1) << @intCast(5 - iteration);
            // creating a bit mask for the current interval, starting from the least significant bit
            var bit_mask = (@as(u64, 1) << @intCast(width)) - 1;
            // shift the bit mask to the left by the interval start
            bit_mask <<= @intCast(interval_start);

            // if the current interval does not have free slots, move to the next interval
            if ((meta_map & bit_mask) == 0) {
                interval_start += width;
            }
        }

        return interval_start;
    }

    pub fn occupyBlock(self: *Self, params: struct { size_exponent: u8 }) !u32 {
        const size_exponent = params.size_exponent;
        std.debug.assert(size_exponent <= MAX_SPAN_SIZE_EXPONENT);

        const slot_size: u32 = @as(u32, 1) << @intCast(size_exponent);
        const bits_to_check = @divExact(64, slot_size);
        const all_occupied = lowNBits(bits_to_check);

        var spans = self.spanList();

        if (self.findFirstNonFullSpan(size_exponent)) |span_index| {
            const i = span_index;
            var span = spans.get(i);

            // meaning that the span is empty
            if (span.map == 0) {
                // occupy the first slot in the span
                spans.set(i, .{
                    .map = 1,
                    .size = size_exponent,
                });
                const meta_mask = ~(@as(u64, 1) << @intCast(i));
                // mark the span as unavailable for all other sizes, and for the max-size block
                // since it fills the span immediately
                for (0..MAX_SPAN_SIZE_EXPONENT + 1) |size_iterator| {
                    if (size_iterator != size_exponent or size_iterator == MAX_SPAN_SIZE_EXPONENT) {
                        self.span_meta_maps[size_iterator] &= meta_mask;
                    }
                }
                return @as(u32, @intCast(i)) * SLOTS_PER_SPAN;
            }

            if (span.map != all_occupied) {
                for (0..bits_to_check) |j| {
                    const mask: u64 = @as(u64, 1) << @intCast(j);
                    if ((span.map & mask) == 0) {
                        span.map |= mask;
                        spans.set(i, span);

                        // if the span is full, remove it from the meta map
                        if (span.map == all_occupied) {
                            self.span_meta_maps[size_exponent] &= ~(@as(u64, 1) << @intCast(i));
                        }

                        return @as(u32, @intCast(i)) * SLOTS_PER_SPAN + @as(u32, @intCast(j)) * slot_size;
                    }
                }
            }
        } else |err| {
            switch (err) {
                error.NotFound => {
                    // Do nothing
                },
            }
        }

        if (self.span_count == SPAN_COUNT) {
            return error.NoSpaceLeft;
        }

        const new_span_index = self.span_count;
        spans.set(new_span_index, .{
            .map = 1,
            .size = size_exponent,
        });
        // update the meta map for the new span
        // special case for span with maximum size, it can't be used because right after initialization it's already
        // full (the block occupies the whole span)
        if (size_exponent < MAX_SPAN_SIZE_EXPONENT) {
            self.span_meta_maps[size_exponent] |= (@as(u64, 1) << @intCast(new_span_index));
        }

        self.span_count += 1;
        return new_span_index * SLOTS_PER_SPAN;
    }

    pub fn freeBlock(self: *Self, block_index: u32) void {
        const span_index, const slot_index = divmod(block_index, SLOTS_PER_SPAN);
        var spans = self.spanList();
        var span = spans.get(span_index);

        const span_slot_size: u32 = @as(u32, 1) << @intCast(span.size);
        const mask: u64 = @as(u64, 1) << @intCast(@divExact(slot_index, span_slot_size));

        const previous_availability_map_value = span.map;
        span.map &= ~mask;
        spans.set(span_index, span);

        const meta_mask = (@as(u64, 1) << @intCast(span_index));
        // if the span is empty, we should mark it as available for all sizes
        if (span.map == 0) {
            for (0..MAX_SPAN_SIZE_EXPONENT + 1) |i| {
                self.span_meta_maps[i] |= meta_mask;
            }
        } else {
            const bits_to_check = @divExact(64, span_slot_size);
            const all_occupied = lowNBits(bits_to_check);

            if (previous_availability_map_value == all_occupied) {
                // a previously full span has a free slot again
                self.span_meta_maps[span.size] |= meta_mask;
            }
        }
    }
};

fn divmod(a: u32, b: u32) struct { u32, u32 } {
    return .{ @divFloor(a, b), @mod(a, b) };
}

test "GpuBufferManager can hold blocks of different sizes" {
    var manager: GpuBufferManager = .{};
    _ = try manager.occupyBlock(.{ .size_exponent = 0 });
    _ = try manager.occupyBlock(.{ .size_exponent = 1 });
    _ = try manager.occupyBlock(.{ .size_exponent = 2 });
    _ = try manager.occupyBlock(.{ .size_exponent = 3 });
    _ = try manager.occupyBlock(.{ .size_exponent = 4 });
    _ = try manager.occupyBlock(.{ .size_exponent = 5 });
    _ = try manager.occupyBlock(.{ .size_exponent = 6 });

    try std.testing.expectEqual(manager.span_count, 7);
}

test "the same slot can be occupied multiple times" {
    var manager: GpuBufferManager = .{};
    _ = try manager.occupyBlock(.{ .size_exponent = 0 });
    _ = try manager.occupyBlock(.{ .size_exponent = 0 });
    _ = try manager.occupyBlock(.{ .size_exponent = 0 });
    const block_index_3 = try manager.occupyBlock(.{ .size_exponent = 0 });
    _ = try manager.occupyBlock(.{ .size_exponent = 0 });
    _ = try manager.occupyBlock(.{ .size_exponent = 0 });
    _ = try manager.occupyBlock(.{ .size_exponent = 0 });

    manager.freeBlock(block_index_3);
    const block_index_3_again = try manager.occupyBlock(.{ .size_exponent = 0 });

    try std.testing.expectEqual(block_index_3, block_index_3_again);
}

test "the same span can be used for different sizes after being freed" {
    var manager: GpuBufferManager = .{};

    const first_span_index = try manager.occupyBlock(.{ .size_exponent = 6 });
    try std.testing.expectEqual(first_span_index, 0);

    const first_time_occupied_span = try manager.occupyBlock(.{ .size_exponent = 0 });
    try std.testing.expectEqual(first_time_occupied_span, SLOTS_PER_SPAN);

    manager.freeBlock(first_time_occupied_span);

    const reoccupied_span = try manager.occupyBlock(.{ .size_exponent = 5 });
    try std.testing.expectEqual(reoccupied_span, first_time_occupied_span);
}

test "block indices within a span stride by slot size" {
    var manager: GpuBufferManager = .{};

    const first = try manager.occupyBlock(.{ .size_exponent = 2 });
    const second = try manager.occupyBlock(.{ .size_exponent = 2 });
    const third = try manager.occupyBlock(.{ .size_exponent = 2 });

    try std.testing.expectEqual(0, first);
    try std.testing.expectEqual(4, second);
    try std.testing.expectEqual(8, third);
    try std.testing.expectEqual(1, manager.span_count);
}

test "occupying past a full span uses the next span" {
    var manager: GpuBufferManager = .{};
    const slots_in_span = @as(u32, 1) << (6 - 1); // exponent 1: 32 slots of size 2

    var last_in_first_span: u32 = 0;
    for (0..slots_in_span) |_| {
        last_in_first_span = try manager.occupyBlock(.{ .size_exponent = 1 });
    }
    try std.testing.expectEqual(SLOTS_PER_SPAN - 2, last_in_first_span);

    const first_in_second_span = try manager.occupyBlock(.{ .size_exponent = 1 });
    try std.testing.expectEqual(SLOTS_PER_SPAN, first_in_second_span);
    try std.testing.expectEqual(2, manager.span_count);
}

test "freeing a slot in a full span reuses that hole" {
    var manager: GpuBufferManager = .{};
    const slots_in_span = @as(u32, SLOTS_PER_SPAN);

    var hole: u32 = 0;
    for (0..slots_in_span) |i| {
        const block_index = try manager.occupyBlock(.{ .size_exponent = 0 });
        if (i == 17) {
            hole = block_index;
        }
    }
    try std.testing.expectEqual(1, manager.span_count);

    manager.freeBlock(hole);
    const reused = try manager.occupyBlock(.{ .size_exponent = 0 });
    try std.testing.expectEqual(hole, reused);
    try std.testing.expectEqual(1, manager.span_count);
}

test "an emptied span packs correctly after changing size" {
    var manager: GpuBufferManager = .{};

    const first = try manager.occupyBlock(.{ .size_exponent = 0 });
    try std.testing.expectEqual(0, first);
    manager.freeBlock(first);

    const larger_first = try manager.occupyBlock(.{ .size_exponent = 3 });
    const larger_second = try manager.occupyBlock(.{ .size_exponent = 3 });
    try std.testing.expectEqual(0, larger_first);
    try std.testing.expectEqual(8, larger_second);
    try std.testing.expectEqual(1, manager.span_count);

    manager.freeBlock(larger_second);
    const larger_second_again = try manager.occupyBlock(.{ .size_exponent = 3 });
    try std.testing.expectEqual(larger_second, larger_second_again);
    try std.testing.expectEqual(1, manager.span_count);
}

test "occupying every span then fails with NoSpaceLeft" {
    var manager: GpuBufferManager = .{};

    for (0..GpuBufferManager.SPAN_COUNT) |i| {
        const block_index = try manager.occupyBlock(.{ .size_exponent = 6 });
        try std.testing.expectEqual(i * SLOTS_PER_SPAN, block_index);
    }
    try std.testing.expectEqual(GpuBufferManager.SPAN_COUNT, manager.span_count);
    try std.testing.expectError(error.NoSpaceLeft, manager.occupyBlock(.{ .size_exponent = 6 }));
    try std.testing.expectError(error.NoSpaceLeft, manager.occupyBlock(.{ .size_exponent = 0 }));
}

test "an emptied span can be reused as a max-size block" {
    var manager: GpuBufferManager = .{};

    const first = try manager.occupyBlock(.{ .size_exponent = 0 });
    try std.testing.expectEqual(0, first);
    manager.freeBlock(first);

    const max_size = try manager.occupyBlock(.{ .size_exponent = 6 });
    try std.testing.expectEqual(0, max_size);
    try std.testing.expectEqual(1, manager.span_count);
    try std.testing.expectEqual(0, manager.span_meta_maps[6]);

    const next_span = try manager.occupyBlock(.{ .size_exponent = 6 });
    try std.testing.expectEqual(SLOTS_PER_SPAN, next_span);
    try std.testing.expectEqual(2, manager.span_count);
}

test "a hole in the last span is found and reused" {
    var manager: GpuBufferManager = .{};
    const last_span_index = GpuBufferManager.SPAN_COUNT - 1;

    var last_block: u32 = 0;
    for (0..GpuBufferManager.SPAN_COUNT) |_| {
        last_block = try manager.occupyBlock(.{ .size_exponent = 6 });
    }
    try std.testing.expectEqual(last_span_index * SLOTS_PER_SPAN, last_block);

    manager.freeBlock(last_block);
    const reused = try manager.occupyBlock(.{ .size_exponent = 6 });
    try std.testing.expectEqual(last_block, reused);
    try std.testing.expectEqual(GpuBufferManager.SPAN_COUNT, manager.span_count);
    try std.testing.expectError(error.NoSpaceLeft, manager.occupyBlock(.{ .size_exponent = 6 }));
}
