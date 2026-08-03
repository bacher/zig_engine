const std = @import("std");

pub const CHUNK_SIZE = 32;

pub const Side = enum(u8) {
    top = 0,
    bottom = 1,
    front = 2,
    back = 3,
    left = 4,
    right = 5,

    pub fn getOpposite(self: Side) Side {
        switch (self) {
            .top => return .bottom,
            .bottom => return .top,
            .front => return .back,
            .back => return .front,
            .left => return .right,
            .right => return .left,
        }
    }

    pub fn getOppositeIndex(self: Side) u8 {
        return @intFromEnum(self.getOpposite());
    }
};

pub const BlockType = enum(u8) {
    none = 0,
    stone,
    dirt,
    grass,
    water,
    sand,
    snow,
};

pub const BlockInfo = extern struct {
    coords: [3]u8,
    block_type: BlockType,
};

pub fn makeInteriorBlockCoords(x: anytype, y: anytype, z: anytype) [3]u8 {
    return .{
        @intCast(x),
        @intCast(y),
        @intCast(z),
    };
}

comptime {
    std.debug.assert(@sizeOf(BlockInfo) == 4);
}

pub const BlockCoordList = std.ArrayList(BlockInfo);

pub const ChunkInfo = extern struct {
    side_data_indices: [6]u16,
    _padding: u32 = 0,
    chunk_origin: [3]u32,
    data_slot_index: u32,
};

comptime {
    std.debug.assert(@sizeOf(ChunkInfo) == 32);
}

pub const VoxelChunk = struct {
    pub const Self = @This();

    chunk_origin: [3]u32,

    blocks_grouped_by_side: [6]BlockCoordList = .{BlockCoordList.empty} ** 6,

    chunk_index: u32 = 0,
    data_slot_index: u32 = 0,
    data_slot_size_level: u8 = 0,

    pub fn init(chunk_origin: [3]u32) Self {
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
