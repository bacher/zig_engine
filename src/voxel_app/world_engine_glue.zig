const std = @import("std");
const voxel = @import("engine").voxel_chunk;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const ChunkContent = @import("./world.zig").ChunkContent;

pub const BoundaryMasks = @import("./boundary_mask.zig").BoundaryMasks;

pub fn extractChunkSideData(
    allocator: std.mem.Allocator,
    content: ChunkContent,
    neighbors: BoundaryMasks,
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
                        break :blk neighbors[index].contains(side, local);
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

test "neighbor masks cull matching faces and retain real exterior surfaces" {
    const allocator = std.testing.allocator;
    const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
    var solid = WorldChunkData.initSolid();
    var neighbors: BoundaryMasks = @splat(.{});
    neighbors[@intFromEnum(voxel.Side.left)] = .{ .rows = @splat(std.math.maxInt(u32)) };
    neighbors[@intFromEnum(voxel.Side.top)] = .{ .rows = @splat(std.math.maxInt(u32)) };
    var mesh = extractChunkSideData(allocator, .{ .blocks = &solid }, neighbors);
    defer mesh.deinit(allocator);
    for (mesh.blocks_grouped_by_side, 0..) |faces, i| {
        const expected: usize = if (i == @intFromEnum(voxel.Side.left) or i == @intFromEnum(voxel.Side.top)) 0 else CHUNK_SIZE * CHUNK_SIZE;
        try std.testing.expectEqual(expected, faces.items.len);
    }
    var neighbor = WorldChunkData.initSolid();
    neighbor.blocks[7][8][CHUNK_SIZE - 1] = .none;
    neighbors[0] = @import("./boundary_mask.zig").extract(&neighbor)[@intFromEnum(voxel.Side.right)];
    var opened = extractChunkSideData(allocator, .{ .blocks = &solid }, neighbors);
    defer opened.deinit(allocator);
    try std.testing.expectEqual(1, opened.blocks_grouped_by_side[0].items.len);
    try std.testing.expectEqual([3]u8{ 0, 8, 7 }, opened.blocks_grouped_by_side[0].items[0].coords);
}
