const std = @import("std");
const voxel = @import("engine").voxel_chunk;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const ChunkContent = @import("./world.zig").ChunkContent;

/// Missing data inside the local core is exposed temporarily. Its outside faces are
/// suppressed explicitly; service meshes always supply actual neighboring contents.
pub const Neighbor = union(enum) {
    exposed,
    suppressed,
    content: ChunkContent,
};

pub fn extractChunkSideData(
    allocator: std.mem.Allocator,
    content: ChunkContent,
    neighbors: [6]Neighbor,
) voxel.ChunkSideData {
    var result: voxel.ChunkSideData = .{};
    if (content == .empty) return result;
    for (content.blocks.blocks, 0..) |slice, z| {
        for (slice, 0..) |row, y| {
            for (row, 0..) |block, x| {
                if (block == .none) continue;
                const local = [3]u5{ @intCast(x), @intCast(y), @intCast(z) };
                for (std.enums.values(voxel.Side)) |side| {
                    const index = @intFromEnum(side);
                    const axis = index / 2;
                    const positive = index % 2 == 1;
                    var adjacent = local;
                    const at_boundary = local[axis] == (if (positive) CHUNK_SIZE - 1 else @as(u5, 0));
                    const occluded = if (at_boundary) blk: {
                        adjacent[axis] = if (positive) 0 else CHUNK_SIZE - 1;
                        break :blk switch (neighbors[index]) {
                            .exposed => false,
                            .suppressed => true,
                            .content => |neighbor| neighbor.getBlock(adjacent) != .none,
                        };
                    } else blk: {
                        if (positive) adjacent[axis] += 1 else adjacent[axis] -= 1;
                        break :blk content.getBlock(adjacent) != .none;
                    };
                    if (!occluded) result.blocks_grouped_by_side[index].append(allocator, .{
                        .coords = .{ local[0], local[1], local[2] },
                        .block_type = block,
                    }) catch @panic("OOM");
                }
            }
        }
    }
    return result;
}

test "neighbor contents cull matching faces, suppression differs from missing data" {
    const allocator = std.testing.allocator;
    const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
    var solid = WorldChunkData.initSolid();
    var neighbors: [6]Neighbor = @splat(.exposed);
    neighbors[@intFromEnum(voxel.Side.left)] = .{ .content = .{ .blocks = &solid } };
    neighbors[@intFromEnum(voxel.Side.top)] = .suppressed;
    var mesh = extractChunkSideData(allocator, .{ .blocks = &solid }, neighbors);
    defer mesh.deinit(allocator);
    for (mesh.blocks_grouped_by_side, 0..) |faces, i| {
        const expected: usize = if (i == @intFromEnum(voxel.Side.left) or i == @intFromEnum(voxel.Side.top)) 0 else CHUNK_SIZE * CHUNK_SIZE;
        try std.testing.expectEqual(expected, faces.items.len);
    }
    var neighbor = WorldChunkData.initSolid();
    neighbor.blocks[7][8][CHUNK_SIZE - 1] = .none;
    neighbors[0] = .{ .content = .{ .blocks = &neighbor } };
    var opened = extractChunkSideData(allocator, .{ .blocks = &solid }, neighbors);
    defer opened.deinit(allocator);
    try std.testing.expectEqual(1, opened.blocks_grouped_by_side[0].items.len);
    try std.testing.expectEqual([3]u8{ 0, 8, 7 }, opened.blocks_grouped_by_side[0].items[0].coords);
}
