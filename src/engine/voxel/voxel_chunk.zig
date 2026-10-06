const ChunkCoords = @import("../world_math.zig").ChunkCoords;
const std = @import("std");

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

pub const BlockType = enum(u8) {
    none = 0,
    stone,
    dirt,
    grass,
    water,
    sand,
    snow,
};

/// Structs starting with GPU_ prefix are uploaded to the GPU, memory layout is important
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

/// Structs starting with GPU_ prefix are uploaded to the GPU, memory layout is important
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

    pub fn clone(self: Self, allocator: std.mem.Allocator) Self {
        var copy: Self = .{};
        for (self.blocks_grouped_by_side, &copy.blocks_grouped_by_side) |source, *dest| {
            dest.appendSlice(allocator, source.items) catch @panic("OOM");
        }
        return copy;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
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
