//! Camera-directed block targeting against the optimistic world cache.
const std = @import("std");
const engine = @import("engine");
const world_module = @import("world.zig");
const World = world_module.World;
const Position = engine.world_math.Position;
const Cell = @Vector(3, i64);

pub const reach: f64 = 4;

pub const Target = struct {
    block: [3]u32,
    /// Empty cell sharing the face through which the ray entered the hit block.
    /// Null when the ray starts inside a block or the face has no valid empty cell.
    placement: ?[3]u32,
    distance: f64,
};

fn storageBlock(layout: *const engine.WorldLayout, cell: Cell) ?[3]u32 {
    var stored = cell;
    stored[0] = @mod(stored[0], layout.size_in_blocks[0]);
    if (stored[1] < 0 or stored[1] >= layout.size_in_blocks[1] or
        stored[2] < 0 or stored[2] >= layout.size_in_blocks[2]) return null;
    return @as(@Vector(3, u32), @intCast(stored));
}

/// Traverse voxel boundaries in distance order. Unknown chunks stop targeting;
/// edits cannot pass through unloaded terrain. Reach is measured to the hit face.
pub fn cast(world: *const World, position: Position, direction: Position) world_module.ChunkNotReceivedError!?Target {
    const length = @sqrt(@reduce(.Add, direction * direction));
    if (length == 0) return null;
    const ray = direction / @as(Position, @splat(length));
    var origin = position + @as(Position, @floatFromInt(world.layout.origin_chunk)) *
        @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
    // Keep repeated trips around the periodic axis within integer storage range.
    origin[0] = @mod(origin[0], @as(f64, @floatFromInt(world.layout.size_in_blocks[0])));
    var cell: Cell = @intFromFloat(@floor(origin));
    var step: Cell = @splat(0);
    var next: Position = @splat(std.math.inf(f64));
    var delta: Position = @splat(std.math.inf(f64));
    inline for (0..3) |axis| {
        if (ray[axis] != 0) {
            step[axis] = if (ray[axis] > 0) 1 else -1;
            // At a boundary, the cell in the ray's direction owns the start.
            if (ray[axis] < 0 and origin[axis] == @floor(origin[axis])) cell[axis] -= 1;
            const boundary: f64 = @floatFromInt(cell[axis] + @as(i64, if (ray[axis] > 0) 1 else 0));
            next[axis] = (boundary - origin[axis]) / ray[axis];
            delta[axis] = 1 / @abs(ray[axis]);
        }
    }

    var distance: f64 = 0;
    var entry_axis: ?usize = null;
    while (distance <= reach) {
        if (storageBlock(world.layout, cell)) |block| {
            if (try world.isBlockSolid(block)) {
                var placement: ?[3]u32 = null;
                if (entry_axis) |axis| {
                    var adjacent = cell;
                    inline for (0..3) |i| {
                        if (axis == i) adjacent[i] -= step[i];
                    }
                    if (storageBlock(world.layout, adjacent)) |candidate| {
                        if (!(world.isBlockSolid(candidate) catch true)) placement = candidate;
                    }
                }
                return .{ .block = block, .placement = placement, .distance = distance };
            }
        }

        distance = @reduce(.Min, next);
        if (distance > reach) return null;
        entry_axis = null;
        // Cross all tied axes together: edge/corner-only contacts have no volume.
        // For an exact tie, choose the face in x/y/z order for placement.
        inline for (0..3) |axis| {
            if (next[axis] == distance) {
                entry_axis = entry_axis orelse axis;
                cell[axis] += step[axis];
                next[axis] += delta[axis];
            }
        }
    }
    return null;
}

fn testBlock(world: *const World, cell: Cell) [3]u32 {
    const origin: Cell = @as(Cell, world.layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
    return storageBlock(world.layout, cell + origin).?;
}

test "target the first occupied block and its entry face in all six directions" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    for ([_]Cell{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } }) |step| {
        const cell = step * @as(Cell, @splat(3));
        fixture.set(cell, .stone);
        fixture.set(step * @as(Cell, @splat(4)), .snow);
        const hit = (try cast(&fixture.world, .{ 0.5, 0.5, 0.5 }, @floatFromInt(step))).?;
        try std.testing.expectEqual(testBlock(&fixture.world, cell), hit.block);
        try std.testing.expectEqual(testBlock(&fixture.world, cell - step), hit.placement.?);
        try std.testing.expect(hit.distance <= reach);
    }
}

test "four metre reach uses ray distance and includes the exact limit" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 5, 0, 0 }, .stone);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.999, 0.5, 0.5 }, .{ 1, 0, 0 }));
    try std.testing.expectEqual(@as(f64, 4), (try cast(&fixture.world, .{ 1, 0.5, 0.5 }, .{ 2, 0, 0 })).?.distance);
    // A diagonal block can be fewer than four cells away but farther than four metres.
    fixture.set(.{ 3, 3, 0 }, .stone);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0, 0, 0.5 }, .{ 1, 1, 0 }));
    fixture.set(.{ 3, 3, 0 }, .none);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 0, 1, 0 }));
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 }));
}

test "diagonal corner crossings choose an adjacent empty face without targeting grazed cells" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 1, 0, 0 }, .stone);
    fixture.set(.{ 2, 2, 0 }, .grass);
    const hit = (try cast(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 1, 0 })).?;
    try std.testing.expectEqual(testBlock(&fixture.world, .{ 2, 2, 0 }), hit.block);
    try std.testing.expectEqual(testBlock(&fixture.world, .{ 1, 2, 0 }), hit.placement.?);
    fixture.set(.{ 1, 2, 0 }, .stone);
    try std.testing.expectEqual(null, (try cast(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 1, 0 })).?.placement);
}

test "negative boundary starts and starting inside terrain have no placement face" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -1, 0, 0 }, .stone);
    const hit = (try cast(&fixture.world, .{ 0, 0.5, 0.5 }, .{ -1, 0, 0 })).?;
    try std.testing.expectEqual(testBlock(&fixture.world, .{ -1, 0, 0 }), hit.block);
    try std.testing.expectEqual(@as(f64, 0), hit.distance);
    try std.testing.expectEqual(null, hit.placement);
    try std.testing.expectEqual(null, (try cast(&fixture.world, .{ -0.5, 0.5, 0.5 }, .{ 1, 0, 0 })).?.placement);
}

test "rays and placement cross periodic x seams and finite world boundaries" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -64, 0, 0 }, .stone);
    for ([_]f64{ 63.5, 191.5, -64.5 }) |x| {
        const hit = (try cast(&fixture.world, .{ x, 0.5, 0.5 }, .{ 1, 0, 0 })).?;
        try std.testing.expectEqual(testBlock(&fixture.world, .{ -64, 0, 0 }), hit.block);
        try std.testing.expectEqual(testBlock(&fixture.world, .{ 63, 0, 0 }), hit.placement.?);
    }
    fixture.set(.{ 63, 1, 0 }, .stone);
    const reverse = (try cast(&fixture.world, .{ -63.5, 1.5, 0.5 }, .{ -1, 0, 0 })).?;
    try std.testing.expectEqual(testBlock(&fixture.world, .{ 63, 1, 0 }), reverse.block);
    try std.testing.expectEqual(testBlock(&fixture.world, .{ -64, 1, 0 }), reverse.placement.?);
    fixture.set(.{ 0, 0, 63 }, .stone);
    const above = (try cast(&fixture.world, .{ 0.5, 0.5, 64.5 }, .{ 0, 0, -1 })).?;
    try std.testing.expectEqual(null, above.placement);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.5, 64.5, 0.5 }, .{ 0, 1, 0 }));
}

test "missing chunks stop a ray before a target and block placement through a missing face" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 1, 0, 0 }, .stone);
    const missing = fixture.world.layout.getChunkCoords(.{ -0.5, 0.5, 0.5 });
    fixture.world.removeChunk(missing);
    try std.testing.expectError(error.ChunkNotReceived, cast(&fixture.world, .{ -0.5, 0.5, 0.5 }, .{ 1, 0, 0 }));
    fixture.set(.{ 0, 0, 0 }, .stone);
    const hit = (try cast(&fixture.world, .{ -0.5, -0.5, 0.5 }, .{ 1, 1, 0 })).?;
    try std.testing.expectEqual(testBlock(&fixture.world, .{ 0, 0, 0 }), hit.block);
    try std.testing.expectEqual(null, hit.placement);
}
