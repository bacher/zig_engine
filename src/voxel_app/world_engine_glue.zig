const std = @import("std");
const voxel = @import("engine").voxel_chunk;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const ChunkContent = @import("./world.zig").ChunkContent;
const environment = @import("./world_environment.zig");
pub const ClimateMap = environment.ClimateMap;

pub const BoundaryMasks = @import("./boundary_mask.zig").BoundaryMasks;

pub fn extractChunkSideData(
    allocator: std.mem.Allocator,
    content: ChunkContent,
    neighbors: BoundaryMasks,
) voxel.ChunkSideData {
    return tryExtractChunkSideData(allocator, content, neighbors) catch @panic("OOM");
}

pub fn tryExtractChunkSideData(allocator: std.mem.Allocator, content: ChunkContent, neighbors: BoundaryMasks) !voxel.ChunkSideData {
    const climate: ClimateMap = @splat(@splat(.temperate));
    return tryExtractChunkSideDataWithClimate(allocator, content, neighbors, &climate);
}

pub fn tryExtractChunkSideDataWithClimate(allocator: std.mem.Allocator, content: ChunkContent, neighbors: BoundaryMasks, climate: *const ClimateMap) !voxel.ChunkSideData {
    var result: voxel.ChunkSideData = .{};
    errdefer result.deinit(allocator);
    if (content == .empty) return result;
    for (content.blocks.blocks, 0..) |slice, z| {
        for (slice, 0..) |row, y| {
            for (row, 0..) |block, x| {
                if (!block.occludesFaces()) continue;
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
                        break :blk content.getBlock(adjacent).occludesFaces();
                    };
                    if (!occluded) try result.blocks_grouped_by_side[index].append(allocator, .{
                        .coords = .{ local[0], local[1], local[2] },
                        .block_type = renderMaterial(block, climate[y][x]),
                    });
                }
            }
        }
    }
    return result;
}

pub fn extractChunkGeometry(allocator: std.mem.Allocator, chunk: @import("world.zig").WorldChunk, neighbors: BoundaryMasks) voxel.ChunkSideData {
    return tryExtractChunkGeometry(allocator, chunk, neighbors) catch @panic("OOM");
}

pub fn tryExtractChunkGeometry(allocator: std.mem.Allocator, chunk: @import("world.zig").WorldChunk, neighbors: BoundaryMasks) !voxel.ChunkSideData {
    const climate: ClimateMap = @splat(@splat(.temperate));
    return tryExtractChunkGeometryWithClimate(allocator, chunk, neighbors, &climate);
}

pub fn extractChunkGeometryWithClimate(allocator: std.mem.Allocator, chunk: @import("world.zig").WorldChunk, neighbors: BoundaryMasks, climate: *const ClimateMap) voxel.ChunkSideData {
    return tryExtractChunkGeometryWithClimate(allocator, chunk, neighbors, climate) catch @panic("OOM");
}

pub fn tryExtractChunkGeometryWithClimate(allocator: std.mem.Allocator, chunk: @import("world.zig").WorldChunk, neighbors: BoundaryMasks, climate: *const ClimateMap) !voxel.ChunkSideData {
    var result = try tryExtractChunkSideDataWithClimate(allocator, chunk.content, neighbors, climate);
    errdefer result.deinit(allocator);
    for (chunk.metadata.roads.items) |road| {
        const local = @import("block_transformations.zig").coordinates(road.index);
        try result.custom_blocks.append(allocator, .{ .coords = .{ local[0], local[1], local[2] }, .shape = road.shape() });
    }
    return result;
}

fn renderMaterial(block: voxel.BlockType, climate: environment.ClimateId) voxel.RenderMaterial {
    if (block == .grass) return switch (climate) {
        .frozen => .grass_frozen,
        .steppe => .grass_steppe,
        .temperate, .desert => .grass,
    };
    return voxel.RenderMaterial.fromBlock(block);
}

test "column climate changes covered soil appearance without changing saved materials" {
    const allocator = std.testing.allocator;
    var data = @import("./world_chunk_data.zig").WorldChunkData.initEmpty();
    var climate: ClimateMap = @splat(@splat(.temperate));
    const climates = [_]environment.ClimateId{ .frozen, .steppe, .temperate, .desert };
    const appearances = [_]voxel.RenderMaterial{ .grass_frozen, .grass_steppe, .grass, .grass };
    for (climates, 0..) |column_climate, i| {
        data.blocks[2][3][i * 2] = .grass;
        climate[3][i * 2] = column_climate;
    }
    data.blocks[2][5][0] = .sand;
    data.blocks[2][5][2] = .dirt;
    data.blocks[2][5][4] = .packed_dirt;
    climate[5] = @splat(.frozen);
    var mesh = try tryExtractChunkSideDataWithClimate(allocator, .{ .blocks = &data }, @splat(.{}), &climate);
    defer mesh.deinit(allocator);
    const tops = mesh.blocks_grouped_by_side[@intFromEnum(voxel.Side.top)].items;
    for (appearances, 0..) |appearance, i| {
        try std.testing.expectEqual(appearance, tops[i].block_type);
        try std.testing.expectEqual(voxel.BlockType.grass, data.blocks[2][3][i * 2]);
    }
    try std.testing.expectEqual(voxel.RenderMaterial.sand, tops[4].block_type);
    try std.testing.expectEqual(voxel.RenderMaterial.dirt, tops[5].block_type);
    try std.testing.expectEqual(voxel.RenderMaterial.packed_dirt, tops[6].block_type);
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

fn exerciseFallibleMesh(allocator: std.mem.Allocator) !void {
    var solid = @import("world_chunk_data.zig").WorldChunkData.initSolid();
    var mesh = try tryExtractChunkSideData(allocator, .{ .blocks = &solid }, @splat(.{}));
    defer mesh.deinit(allocator);
    var copy = try mesh.tryClone(allocator);
    defer copy.deinit(allocator);
    for (copy.blocks_grouped_by_side) |faces| try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE, faces.items.len);
}

test "mesh preparation and transfer cloning clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFallibleMesh, .{});
}
