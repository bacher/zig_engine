//! Culled, client-owned geometry for fulfilled construction portions. The
//! definition/progress source is retained until the matching terrain is drawn.
const std = @import("std");
const engine = @import("engine");
const voxel = engine.voxel_chunk;
const runtime = @import("blueprint_runtime.zig");
const blueprint = @import("blueprint.zig");
const World = @import("world.zig").World;
const ChunkId = @import("consts.zig").ChunkId;
const chunk_size = @import("consts.zig").CHUNK_SIZE;
const coordinates = @import("block_coordinates.zig");

pub const Selection = struct {
    context: *const anyopaque,
    include: *const fn (*const anyopaque, ChunkId, runtime.Instance) bool,
};

const Prediction = struct { instance_id: u64, cell_index: u32, cell: runtime.Cell };
const Predictions = std.AutoHashMapUnmanaged(Prediction, void);

fn fulfilled(instance: runtime.Instance, index: u32, cell: runtime.Cell, predictions: *const Predictions) bool {
    return instance.isFulfilled(index) or predictions.contains(.{ .instance_id = instance.id, .cell_index = index, .cell = cell });
}

fn constructionMaterial(world: *const World, cell: runtime.Cell, selection: Selection, predictions: *const Predictions) !?voxel.BlockType {
    const coords, _ = @import("world.zig").splitBlockCoords(cell);
    const id = world.layout.encodeChunkCoords(coords);
    for (world.blueprints.chunkInstances(id)) |instance_id| {
        const instance = world.blueprints.instances.get(instance_id) orelse return error.MissingConstructionData;
        if (!selection.include(selection.context, id, instance)) continue;
        const saved = world.blueprints.definitions.get(instance.definition_id) orelse return error.MissingConstructionData;
        const index = runtime.definitionIndex(world.layout, instance.origin, saved.definition.size, instance.rotation, cell) orelse continue;
        const material = saved.definition.cells[index];
        if (material != .none and fulfilled(instance, index, cell, predictions)) return material;
    }
    return null;
}

fn occludes(world: *const World, cell: runtime.Cell, selection: Selection, predictions: *const Predictions) !bool {
    if (try constructionMaterial(world, cell, selection, predictions)) |material| return material.occludesFaces();
    const coords, const local = @import("world.zig").splitBlockCoords(cell);
    // A mesh-only subscription has no interior terrain array. Retaining a face
    // hidden inside static terrain is the approved conservative rendering path;
    // collision and actions continue to require complete composed world data.
    const terrain = world.getChunk(coords) orelse return false;
    return terrain.content.getBlock(local).occludesFaces();
}

pub fn buildChunk(allocator: std.mem.Allocator, world: *const World, id: ChunkId, selection: Selection) !voxel.ChunkSideData {
    var result: voxel.ChunkSideData = .{};
    errdefer result.deinit(allocator);
    var predictions: Predictions = .empty;
    defer predictions.deinit(allocator);
    for (world.pending_operations.items) |pending| {
        if (pending.resolved_status != null) continue;
        const target = pending.operation.blueprint orelse continue;
        try predictions.put(allocator, .{ .instance_id = target.instance_id, .cell_index = target.cell_index, .cell = pending.operation.block }, {});
    }
    for (world.blueprints.chunkInstances(id)) |instance_id| {
        const instance = world.blueprints.instances.get(instance_id) orelse return error.MissingConstructionData;
        if (!selection.include(selection.context, id, instance)) continue;
        const group_slot = instance.groupIndex(id) orelse continue;
        const group = instance.target_groups[group_slot];
        const saved = world.blueprints.definitions.get(instance.definition_id) orelse return error.MissingConstructionData;
        for (instance.targetsOfGroup(group)) |index| {
            const cell = runtime.worldCell(world.layout, instance.origin, saved.definition.size, instance.rotation, blueprint.cellAtIndex(saved.definition.size, index)) orelse return error.MissingConstructionData;
            if (!fulfilled(instance, index, cell, &predictions)) continue;
            const material = saved.definition.cells[index];
            if (material == .none) return error.MissingConstructionData;
            const local: [3]u8 = .{ @intCast(cell[0] % chunk_size), @intCast(cell[1] % chunk_size), @intCast(cell[2] % chunk_size) };
            for (std.enums.values(voxel.Side)) |side| {
                const offset = side.getOffset();
                const adjacent = coordinates.fromStorage(world.layout, @as(coordinates.Cell, .{ cell[0], cell[1], cell[2] }) + @as(coordinates.Cell, @intCast(offset)));
                if (adjacent) |neighbor| if (try occludes(world, neighbor, selection, &predictions)) continue;
                try result.blocks_grouped_by_side[@intFromEnum(side)].append(allocator, .{ .coords = local, .block_type = voxel.RenderMaterial.fromBlock(material) });
            }
        }
    }
    return result;
}

fn includeAll(_: *const anyopaque, _: ChunkId, _: runtime.Instance) bool {
    return true;
}

fn faceCount(mesh: voxel.ChunkSideData) usize {
    var total: usize = 0;
    for (mesh.blocks_grouped_by_side) |side| total += side.items.len;
    return total;
}

fn testWorld(allocator: std.mem.Allocator, origin: runtime.Cell, size: [3]u32) !World {
    const layout = &@import("test_world.zig").layout;
    var world = try World.init(allocator, layout);
    errdefer world.deinit();
    const volume = @as(usize, size[0]) * size[1] * size[2];
    var saved: runtime.SavedDefinition = blk: {
        const cells = try allocator.alloc(voxel.BlockType, volume);
        errdefer allocator.free(cells);
        @memset(cells, .stone);
        break :blk .{ .id = 1, .owner = 1, .name = try allocator.dupe(u8, "Geometry"), .definition = .{ .size = size, .cells = cells, .target_count = @intCast(volume) } };
    };
    defer saved.deinit(allocator);
    try world.applyBlueprintChanges(&.{.{ .definition = saved }});
    var instance = try world.blueprints.prepareInstance(allocator, layout, 1, 1, 1, origin, 0);
    defer instance.deinit(allocator);
    try world.applyBlueprintChanges(&.{.{ .instance = instance }});
    const installed = world.blueprints.instances.getPtr(1).?;
    @memset(installed.fulfilled, 255);
    installed.remaining = 0;
    installed.phase = .materializing;
    return world;
}

test "construction faces cull across chunk seams and preserve the exterior" {
    const allocator = std.testing.allocator;
    var world = try testWorld(allocator, .{ 31, 12, 12 }, .{ 2, 1, 1 });
    defer world.deinit();
    const selection: Selection = .{ .context = &world, .include = includeAll };
    var total: usize = 0;
    for (world.blueprints.instances.get(1).?.target_groups) |group| {
        var mesh = try buildChunk(allocator, &world, group.chunk_id, selection);
        defer mesh.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 5), faceCount(mesh));
        total += faceCount(mesh);
    }
    try std.testing.expectEqual(@as(usize, 10), total);
}

test "dense construction geometry scales with exposed faces" {
    const allocator = std.testing.allocator;
    var world = try testWorld(allocator, .{ 10, 10, 10 }, .{ 8, 8, 8 });
    defer world.deinit();
    const selection: Selection = .{ .context = &world, .include = includeAll };
    var mesh = try buildChunk(allocator, &world, world.blueprints.instances.get(1).?.target_groups[0].chunk_id, selection);
    defer mesh.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 6 * 8 * 8), faceCount(mesh));
}

test "supported checkerboard rebar columns exceed the former single allocation limit" {
    const allocator = std.testing.allocator;
    const rules = @import("block_rules.zig");
    const world_module = @import("world.zig");
    const layout = &@import("test_world.zig").layout;
    var world = try World.init(allocator, layout);
    defer world.deinit();
    const size: [3]u32 = .{ 32, 32, rules.Limits.mineral_height };
    const cells = try allocator.alloc(voxel.BlockType, @as(usize, size[0]) * size[1] * size[2]);
    @memset(cells, .none);
    for (0..size[2]) |z| for (0..size[1]) |y| for (0..size[0]) |x| {
        if ((x + y) % 2 == 0) cells[(z * size[1] + y) * size[0] + x] = .rebar;
    };
    var saved: runtime.SavedDefinition = .{ .id = 1, .owner = 1, .name = try allocator.dupe(u8, "Supported columns"), .definition = .{ .size = size, .cells = cells, .target_count = 512 * rules.Limits.mineral_height } };
    defer saved.deinit(allocator);
    try world.applyBlueprintChanges(&.{.{ .definition = saved }});
    const data = try allocator.create(@import("world_chunk_data.zig").WorldChunkData);
    data.* = .initEmpty();
    for (&data.blocks[0]) |*row| @memset(row, .limestone);
    try world.insertChunk(.{ 1, 1, 1 }, world_module.WorldChunk.initBlocks(data));
    var instance = try world.blueprints.prepareInstance(allocator, layout, 1, 1, 1, .{ 32, 32, 33 }, 0);
    defer instance.deinit(allocator);
    try world.applyBlueprintChanges(&.{.{ .instance = instance }});
    const installed = world.blueprints.instances.getPtr(1).?;
    @memset(installed.fulfilled, 255);
    installed.remaining = 0;
    installed.phase = .materializing;
    try std.testing.expectEqual(@as(usize, 1), installed.target_groups.len);
    var validator: rules.Validator = .{ .allocator = allocator, .reader = world.reader() };
    defer validator.deinit();
    for (0..32) |y| for (0..32) |x| {
        if ((x + y) % 2 == 0) try std.testing.expect(validator.checkExisting(.{ @intCast(32 + x), @intCast(32 + y), 32 + rules.Limits.mineral_height }) == null);
    };
    var mesh = try buildChunk(allocator, &world, installed.target_groups[0].chunk_id, .{ .context = &world, .include = includeAll });
    defer mesh.deinit(allocator);
    // 512 independently supported columns, each with four exposed sides per
    // level and one top; the raw limestone foundation occludes each bottom.
    try std.testing.expectEqual(@as(usize, 512 * (4 * rules.Limits.mineral_height + 1)), faceCount(mesh));
    try std.testing.expect(faceCount(mesh) > 16_384);
}

test "construction faces cull between separate sites and across the wrapped seam" {
    const allocator = std.testing.allocator;
    const layout = &@import("test_world.zig").layout;
    for ([_]u32{ 31, layout.size_in_blocks[0] - 1 }) |x| {
        var world = try testWorld(allocator, .{ x, 12, 12 }, .{ 1, 1, 1 });
        defer world.deinit();
        var second = try world.blueprints.prepareInstance(allocator, layout, 2, 1, 1, .{ (x + 1) % layout.size_in_blocks[0], 12, 12 }, 0);
        defer second.deinit(allocator);
        try world.applyBlueprintChanges(&.{.{ .instance = second }});
        const installed = world.blueprints.instances.getPtr(2).?;
        @memset(installed.fulfilled, 255);
        installed.remaining = 0;
        installed.phase = .materializing;
        const selection: Selection = .{ .context = &world, .include = includeAll };
        var total: usize = 0;
        for ([_]u64{ 1, 2 }) |id| {
            const group = world.blueprints.instances.get(id).?.target_groups[0];
            var mesh = try buildChunk(allocator, &world, group.chunk_id, selection);
            defer mesh.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 5), faceCount(mesh));
            total += faceCount(mesh);
        }
        try std.testing.expectEqual(@as(usize, 10), total);
    }
}

test "construction geometry preserves enclosed unfulfilled cavities" {
    const allocator = std.testing.allocator;
    var world = try testWorld(allocator, .{ 10, 10, 10 }, .{ 8, 8, 8 });
    defer world.deinit();
    const instance = world.blueprints.instances.getPtr(1).?;
    const center: usize = (3 * 8 + 3) * 8 + 3;
    instance.fulfilled[center / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(center % 8)));
    instance.remaining = 1;
    instance.phase = .building;
    var mesh = try buildChunk(allocator, &world, instance.target_groups[0].chunk_id, .{ .context = &world, .include = includeAll });
    defer mesh.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 6 * 8 * 8 + 6), faceCount(mesh));
}

test "construction geometry indexes optimistic fulfillment by exact target and cell" {
    const allocator = std.testing.allocator;
    var world = try testWorld(allocator, .{ 31, 12, 12 }, .{ 2, 1, 1 });
    defer world.deinit();
    const instance = world.blueprints.instances.getPtr(1).?;
    @memset(instance.fulfilled, 0);
    instance.remaining = 2;
    instance.phase = .building;
    const PendingOperation = @import("world.zig").PendingOperation;
    try world.pending_operations.appendSlice(allocator, &.{
        PendingOperation{ .operation = .{ .block = .{ 31, 12, 12 }, .action = .{ .put = .stone }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } } },
        PendingOperation{ .operation = .{ .block = .{ 33, 12, 12 }, .action = .{ .put = .stone }, .blueprint = .{ .instance_id = 1, .cell_index = 1 } } },
    });
    const selection: Selection = .{ .context = &world, .include = includeAll };
    var first = try buildChunk(allocator, &world, instance.target_groups[0].chunk_id, selection);
    defer first.deinit(allocator);
    var second = try buildChunk(allocator, &world, instance.target_groups[1].chunk_id, selection);
    defer second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 6), faceCount(first));
    try std.testing.expectEqual(@as(usize, 0), faceCount(second));
    world.pending_operations.items[1].operation.block = .{ 32, 12, 12 };
    var adjacent = try buildChunk(allocator, &world, instance.target_groups[0].chunk_id, selection);
    defer adjacent.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), faceCount(adjacent));
}

test "construction reference geometry has 32800 faces for 320000 filled targets" {
    const allocator = std.testing.allocator;
    var world = try testWorld(allocator, .{ 31, 31, 12 }, .{ 100, 100, 32 });
    defer world.deinit();
    const groups = world.blueprints.instances.get(1).?.target_groups;
    try std.testing.expectEqual(@as(usize, 50), groups.len);
    const selection: Selection = .{ .context = &world, .include = includeAll };
    var samples: [5]u64 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.awake.now(std.testing.io);
        var total: usize = 0;
        for (groups) |group| {
            var mesh = try buildChunk(allocator, &world, group.chunk_id, selection);
            total += faceCount(mesh);
            mesh.deinit(allocator);
        }
        sample.* = @intCast(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).nanoseconds);
        try std.testing.expectEqual(@as(usize, 32_800), total);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("construction geometry: 320000 targets, 50 chunks, 32800 quads, 196800 vertices; CPU build median {d:.3} ms, min {d:.3} ms ({s}, 5 samples; excludes GPU upload/draw)\n", .{
        @as(f64, @floatFromInt(samples[samples.len / 2])) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(samples[0])) / std.time.ns_per_ms,
        @tagName(@import("builtin").mode),
    });
}
