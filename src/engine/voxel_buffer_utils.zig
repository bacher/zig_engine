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

pub const BufferSpanMap = struct {
    availability_map: u64, // 64 bits for 64 blocks
};

fn lowNBits(n: u32) u64 {
    if (n >= 64) {
        return std.math.maxInt(u64); // all 64 bits set
    }
    if (n == 0) {
        return 0;
    }
    return (@as(u64, 1) << @intCast(n)) - 1;
}

pub const GpuBufferManager = struct {
    const Self = @This();

    pub const SPAN_COUNT = @divExact(VOXEL_GRID_SLOT_COUNT, SLOTS_PER_SPAN);

    span_maps: [SPAN_COUNT]BufferSpanMap = @splat(.{ .availability_map = 0 }),
    span_sizes: [SPAN_COUNT]u8 = @splat(0),
    span_count: u32 = 0,

    pub fn occupyBlock(self: *Self, size_exponent: u8) !u32 {
        std.debug.assert(size_exponent <= MAX_SPAN_SIZE_EXPONENT);

        const slot_size: u32 = @as(u32, 1) << @intCast(size_exponent);
        const bits_to_check = @divExact(64, slot_size);
        const all_occupied = lowNBits(bits_to_check);

        for (0..self.span_count) |i| {
            if (self.span_sizes[i] == size_exponent) {
                if (self.span_maps[i].availability_map != all_occupied) {
                    for (0..bits_to_check) |j| {
                        const mask: u64 = @as(u64, 1) << @intCast(j);
                        if ((self.span_maps[i].availability_map & mask) == 0) {
                            self.span_maps[i].availability_map |= mask;
                            return @as(u32, @intCast(i)) * SLOTS_PER_SPAN + @as(u32, @intCast(j)) * slot_size;
                        }
                    }
                }
            }
        }

        if (self.span_count == SPAN_COUNT) {
            return error.NoSpaceLeft;
        }

        const new_span_index = self.span_count;
        self.span_maps[new_span_index] = .{ .availability_map = 1 };
        self.span_sizes[new_span_index] = size_exponent;
        self.span_count += 1;
        return new_span_index * SLOTS_PER_SPAN;
    }

    pub fn freeBlock(self: *Self, block_index: u32) void {
        const span_index, const slot_index = divmod(block_index, SLOTS_PER_SPAN);
        const slot_size: u32 = @as(u32, 1) << @intCast(self.span_sizes[span_index]);
        const mask: u64 = @as(u64, 1) << @intCast(@divExact(slot_index, slot_size));

        self.span_maps[span_index].availability_map &= ~mask;
    }
};

fn divmod(a: u32, b: u32) struct { u32, u32 } {
    return .{ @divFloor(a, b), @mod(a, b) };
}

test "GpuBufferManager can hold blocks of different sizes" {
    var manager: GpuBufferManager = .{};
    _ = try manager.occupyBlock(0);
    _ = try manager.occupyBlock(1);
    _ = try manager.occupyBlock(2);
    _ = try manager.occupyBlock(3);
    _ = try manager.occupyBlock(4);
    _ = try manager.occupyBlock(5);
    _ = try manager.occupyBlock(6);

    try std.testing.expectEqual(manager.span_count, 7);
}

test "GpuBufferManager the same slot can be occupied multiple times" {
    var manager: GpuBufferManager = .{};
    _ = try manager.occupyBlock(0);
    _ = try manager.occupyBlock(0);
    _ = try manager.occupyBlock(0);
    const block_index_3 = try manager.occupyBlock(0);
    _ = try manager.occupyBlock(0);
    _ = try manager.occupyBlock(0);
    _ = try manager.occupyBlock(0);

    manager.freeBlock(block_index_3);
    const block_index_3_again = try manager.occupyBlock(0);

    try std.testing.expectEqual(block_index_3, block_index_3_again);
}
