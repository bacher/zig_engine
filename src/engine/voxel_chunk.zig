const std = @import("std");

pub const CHUNK_SIZE = 32;

pub const Side = enum(u8) {
    top = 0,
    bottom = 1,
    front = 2,
    back = 3,
    left = 4,
    right = 5,
};

pub const BlockType = enum(u8) {
    air = 0,
    stone,
    dirt,
    grass,
    water,
    sand,
    snow,
};

pub const BlockInfo = struct {
    coords: [3]u8,
    block_type: BlockType,
};

comptime {
    std.debug.assert(@sizeOf(BlockInfo) == 4);
}

pub const BlockCoordList = std.ArrayList(BlockInfo);

pub const ChunkInfo = struct {
    side_data_indices: [6]u32,
    chunk_origin: [3]u16,
    _padding: u16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(ChunkInfo) == 32);
}

pub const VoxelChunk = struct {
    pub const Self = @This();

    chunk_origin: [3]u16,

    blocks_grouped_by_side: [6]BlockCoordList = .{BlockCoordList.empty} ** 6,

    chunk_index: u32 = 0,
    data_slot_index: u32 = 0,
    data_slot_size_level: u8 = 0,

    pub fn init(chunk_origin: [3]u16) Self {
        return .{
            .chunk_origin = chunk_origin,
        };
    }

    pub fn loadTestData(self: *Self, allocator: std.mem.Allocator) void {
        self.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        self.blocks_grouped_by_side[1].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        self.blocks_grouped_by_side[2].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        self.blocks_grouped_by_side[3].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        self.blocks_grouped_by_side[4].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        self.blocks_grouped_by_side[5].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;

        self.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 1, 1, 0 }, .block_type = .stone }) catch unreachable;
        self.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 0, 3, 0 }, .block_type = .dirt }) catch unreachable;
        self.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 1, 1, 1 }, .block_type = .dirt }) catch unreachable;
        self.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 0, 0, CHUNK_SIZE - 1 }, .block_type = .stone }) catch unreachable;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (&self.blocks_grouped_by_side) |*block| {
            block.deinit(allocator);
        }
    }
};
