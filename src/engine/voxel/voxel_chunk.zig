const ChunkCoords = @import("../world_math.zig").ChunkCoords;
const std = @import("std");
pub const custom_block = @import("custom_block.zig");

pub const CHUNK_SIZE = @import("../chunk_utils.zig").CHUNK_SIZE;

pub const Side = enum(u8) {
    left = 0, //   -x
    right = 1, //  +x
    front = 2, //  -y
    back = 3, //   +y
    bottom = 4, // -z
    top = 5, //    +z

    pub fn getOffset(self: Side) ChunkCoords {
        return switch (self) {
            .left => .{ -1, 0, 0 },
            .right => .{ 1, 0, 0 },
            .front => .{ 0, -1, 0 },
            .back => .{ 0, 1, 0 },
            .bottom => .{ 0, 0, -1 },
            .top => .{ 0, 0, 1 },
        };
    }

    pub fn getOpposite(self: Side) Side {
        switch (self) {
            .left => return .right,
            .right => return .left,
            .front => return .back,
            .back => return .front,
            .bottom => return .top,
            .top => return .bottom,
        }
    }

    pub fn getOppositeIndex(self: Side) u8 {
        return @intFromEnum(self.getOpposite());
    }
};

comptime {
    if (@sizeOf(BlockType) != 1 or @sizeOf([32][32][32]BlockType) != 32768)
        @compileError("persistence v1 requires byte-sized block storage");
}

pub const BlockType = enum(u8) {
    none = 0,
    /// Natural rock. Mining yields crushed stone; players cannot place this type.
    stone = 1,
    /// Loose soil. Generated soil uses packed_dirt instead.
    dirt = 2,
    /// Packed soil with a grass surface; not a separately placeable material.
    grass = 3,
    water = 4,
    sand = 5,
    snow = 6,
    packed_dirt = 7,
    crushed_stone = 8,
    tree_trunk = 9,
    planks = 10,
    rebar = 11,
    reinforced_concrete = 12,
    country_road_solid = 13,
    /// Selection/validation material; stored cells use custom plus sparse metadata.
    country_road_adaptive = 14,
    custom = 255,

    pub fn occludesFaces(self: BlockType) bool {
        return self != .none and self != .custom and self != .country_road_adaptive;
    }

    pub fn isRoad(self: BlockType) bool {
        return self == .country_road_solid or self == .country_road_adaptive or self == .custom;
    }

    pub fn isEarth(self: BlockType) bool {
        return self == .dirt or self == .packed_dirt or self == .grass;
    }

    pub fn isWood(self: BlockType) bool {
        return self == .tree_trunk or self == .planks;
    }

    pub fn isReinforced(self: BlockType) bool {
        return self == .rebar or self == .reinforced_concrete;
    }

    pub fn isMineralConstruction(self: BlockType) bool {
        return self == .crushed_stone or self.isReinforced();
    }

    pub fn isStablePlatformMaterial(self: BlockType) bool {
        return self.isEarth() or self == .stone or self.isMineralConstruction();
    }

    pub fn isStructural(self: BlockType) bool {
        return self.isStablePlatformMaterial() or self.isWood();
    }

    pub fn isPlaceable(self: BlockType) bool {
        return self != .none and self != .stone and self != .packed_dirt and self != .grass and self != .custom;
    }

    pub fn minedType(self: BlockType) BlockType {
        if (self == .custom) return .country_road_adaptive;
        if (self == .stone) return .crushed_stone;
        if (self.isEarth()) return .dirt;
        return self;
    }
};

/// Four-byte face record decoded from a u32 by WGSL. See docs/rendering.md for GPU_ naming.
pub const GPU_BlockInfo = extern struct {
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
    std.debug.assert(@sizeOf(GPU_BlockInfo) == 4);
}

pub const BlockCoordList = std.ArrayList(GPU_BlockInfo);

/// Chunk metadata matching GPU_ChunkInfo in shaders/voxel/geometry.wgsl.
pub const GPU_ChunkInfo = extern struct {
    // TODO: can we hold all needed info in [8]u32 -> [8][u10,u10,u10,u2], 10 bits per coord
    // [2]u16 = {count, index}
    view_side_data_indices: [8][3][2]u16, // 96 bytes
    chunk_origin: [3]i32, // 12 bytes; explicit layout, not a padded CPU vector
    data_slot_index: u32, // 4 bytes
    // total: 112 bytes
};

comptime {
    // @compileLog("GPU_ChunkInfo size", @sizeOf(GPU_ChunkInfo));
    std.debug.assert(@sizeOf(GPU_ChunkInfo) == 112);
    std.debug.assert(@offsetOf(GPU_ChunkInfo, "chunk_origin") == 96);
    std.debug.assert(@offsetOf(GPU_ChunkInfo, "data_slot_index") == 108);
}

pub const VoxelChunk = struct {
    pub const Self = @This();

    // TODO: should we add chunk_id here?
    chunk_origin: ChunkCoords,

    // if null, then it means that the chunk is not resident on the GPU most likely because does not have visible faces
    gpu_residence_info: ?GpuResidenceInfo = null,
    custom_blocks: std.ArrayList(custom_block.Draw) = .empty,

    pub fn init(chunk_origin: ChunkCoords) Self {
        return .{
            .chunk_origin = chunk_origin,
        };
    }
};

pub const GpuResidenceInfo = struct {
    faces_count_per_view: [8]u16,
    chunk_index: u32,
    data_slot_index: u32,
    data_slot_size_level: u8,
};

pub const ChunkSideData = struct {
    const Self = @This();

    blocks_grouped_by_side: [6]BlockCoordList = @splat(BlockCoordList.empty),
    custom_blocks: std.ArrayList(custom_block.Draw) = .empty,

    pub fn clone(self: Self, allocator: std.mem.Allocator) Self {
        return self.tryClone(allocator) catch @panic("OOM");
    }

    pub fn tryClone(self: Self, allocator: std.mem.Allocator) !Self {
        var copy: Self = .{};
        errdefer copy.deinit(allocator);
        try copy.custom_blocks.appendSlice(allocator, self.custom_blocks.items);
        for (self.blocks_grouped_by_side, &copy.blocks_grouped_by_side) |source, *dest| {
            try dest.appendSlice(allocator, source.items);
        }
        return copy;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.custom_blocks.deinit(allocator);
        for (&self.blocks_grouped_by_side) |*block| {
            block.deinit(allocator);
        }
    }

    pub fn initWithTestData(allocator: std.mem.Allocator) void {
        var chunk_side_data: Self = .{};

        chunk_side_data.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        chunk_side_data.blocks_grouped_by_side[1].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        chunk_side_data.blocks_grouped_by_side[2].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        chunk_side_data.blocks_grouped_by_side[3].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        chunk_side_data.blocks_grouped_by_side[4].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;
        chunk_side_data.blocks_grouped_by_side[5].append(allocator, .{ .coords = .{ 0, 0, 0 }, .block_type = .stone }) catch unreachable;

        chunk_side_data.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 1, 1, 0 }, .block_type = .stone }) catch unreachable;
        chunk_side_data.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 0, 3, 0 }, .block_type = .dirt }) catch unreachable;
        chunk_side_data.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 1, 1, 1 }, .block_type = .dirt }) catch unreachable;
        chunk_side_data.blocks_grouped_by_side[0].append(allocator, .{ .coords = .{ 0, 0, CHUNK_SIZE - 1 }, .block_type = .stone }) catch unreachable;

        return chunk_side_data;
    }
};

pub const VoxelChunkUpload = struct {
    chunk_coords: ChunkCoords,
    chunk_side_data: ChunkSideData,
};
