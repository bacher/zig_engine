const std = @import("std");
const engine = @import("engine");

const BlockType = engine.voxel_chunk.BlockType;
const Side = engine.voxel_chunk.Side;
const VoxelChunk = engine.voxel_chunk.VoxelChunk;

const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;

pub fn updateVoxelChunk(allocator: std.mem.Allocator, world_chunk_data: *const WorldChunkData, voxel_chunk: *VoxelChunk) void {
    const b = &world_chunk_data.blocks;

    for (b, 0..) |slice, z| {
        for (slice, 0..) |row, y| {
            for (row, 0..) |block, x| {
                if (block == BlockType.none) {
                    continue;
                }

                const voxel_block = engine.voxel_chunk.BlockInfo{
                    .coords = engine.voxel_chunk.makeInteriorBlockCoords(x, y, z),
                    .block_type = block,
                };

                if (y == CHUNK_SIZE - 1 or b[z][y + 1][x] == BlockType.none) {
                    voxel_chunk.blocks_grouped_by_side[@intFromEnum(Side.back)].append(allocator, voxel_block) catch @panic("OOM");
                }

                if (y == 0 or b[z][y - 1][x] == BlockType.none) {
                    voxel_chunk.blocks_grouped_by_side[@intFromEnum(Side.front)].append(allocator, voxel_block) catch @panic("OOM");
                }

                if (x == CHUNK_SIZE - 1 or b[z][y][x + 1] == BlockType.none) {
                    voxel_chunk.blocks_grouped_by_side[@intFromEnum(Side.right)].append(allocator, voxel_block) catch @panic("OOM");
                }

                if (x == 0 or b[z][y][x - 1] == BlockType.none) {
                    voxel_chunk.blocks_grouped_by_side[@intFromEnum(Side.left)].append(allocator, voxel_block) catch @panic("OOM");
                }

                if (z == CHUNK_SIZE - 1 or b[z + 1][y][x] == BlockType.none) {
                    voxel_chunk.blocks_grouped_by_side[@intFromEnum(Side.top)].append(allocator, voxel_block) catch @panic("OOM");
                }

                if (z == 0 or b[z - 1][y][x] == BlockType.none) {
                    voxel_chunk.blocks_grouped_by_side[@intFromEnum(Side.bottom)].append(allocator, voxel_block) catch @panic("OOM");
                }
            }
        }
    }
}
