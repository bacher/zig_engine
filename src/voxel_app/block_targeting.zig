//! Camera-ray targeting against the optimistic block cache. One unit is one metre.
const std = @import("std");
const engine = @import("engine");
const World = @import("world.zig").World;
const Position = engine.world_math.Position;
const Cell = @Vector(3, i64);

pub const reach: f64 = 4;

pub const Hit = struct {
    block: [3]u32,
    /// The face-adjacent cell, absent for strictly interior starts or outside storage.
    placement: ?[3]u32,
    distance: f64,
};

/// Walk voxel boundaries in distance order, stopping at the first occupied cell.
/// Unknown chunks stop the ray rather than allowing edits through unloaded terrain.
pub fn cast(world: *const World, position: Position, direction: Position) @import("world.zig").ChunkNotReceivedError!?Hit {
    const length = @sqrt(@reduce(.Add, direction * direction));
    if (!std.math.isFinite(length) or length == 0) return null;
    inline for (0..3) |axis| if (!std.math.isFinite(position[axis])) return null;
    const forward = direction / @as(Position, @splat(length));
    var start = position + @as(Position, @floatFromInt(world.layout.origin_chunk)) * @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
    // Keep periodic positions small before converting to integer cell coordinates.
    start[0] = @mod(start[0], @as(f64, @floatFromInt(world.layout.size_in_blocks[0])));
    // Allow eight f64 epsilon units at the storage-coordinate scale for origin
    // conversion and DDA rounding. This only widens the cutoff by rounding noise.
    const reach_limit = reach + 8 * std.math.floatEps(f64) * @max(reach, @reduce(.Max, @abs(start)));
    // Even a spectator far outside the finite world cannot reach it from here.
    inline for (1..3) |axis| {
        if (start[axis] < -reach_limit or start[axis] > @as(f64, @floatFromInt(world.layout.size_in_blocks[axis])) + reach_limit) return null;
    }
    var cell: Cell = @intFromFloat(@floor(start));
    var step: Cell = @splat(0);
    var next: Position = @splat(std.math.inf(f64));
    var interval: Position = @splat(std.math.inf(f64));
    var entry_step: ?Cell = null;
    inline for (0..3) |axis| {
        if (forward[axis] != 0) {
            step[axis] = if (forward[axis] > 0) 1 else -1;
            // Positive rays start in the entered cell; negative rays step into it
            // at distance zero below. Preserve a face for either boundary start.
            if (step[axis] > 0 and start[axis] == @floor(start[axis]) and entry_step == null) {
                var normal: Cell = @splat(0);
                normal[axis] = step[axis];
                entry_step = normal;
            }
            const boundary: f64 = @floatFromInt(cell[axis] + @as(i64, @intFromBool(step[axis] > 0)));
            next[axis] = (boundary - start[axis]) / forward[axis];
            interval[axis] = 1 / @abs(forward[axis]);
        }
    }

    var distance: f64 = 0;
    while (distance <= reach_limit) {
        const exit = @reduce(.Min, next);
        // At an exact boundary, ignore the cell behind a negative-pointing ray.
        if (exit > distance) {
            if (storedCell(world.layout, cell)) |block| {
                if (try world.isBlockSolid(block)) {
                    var placement: ?[3]u32 = null;
                    if (entry_step) |normal| {
                        placement = storedCell(world.layout, cell - normal);
                    }
                    return .{ .block = block, .placement = placement, .distance = distance };
                }
            }
        }
        if (exit > reach_limit) return null;
        distance = exit;
        entry_step = null;
        // Skip cells touched only at an edge/corner. Choose a deterministic face at ties.
        inline for (0..3) |axis| {
            if (next[axis] == exit) {
                if (entry_step == null) {
                    var normal: Cell = @splat(0);
                    normal[axis] = step[axis];
                    entry_step = normal;
                }
                cell[axis] += step[axis];
                next[axis] += interval[axis];
            }
        }
    }
    return null;
}

fn storedCell(layout: *const engine.WorldLayout, cell: Cell) ?[3]u32 {
    if (cell[1] < 0 or cell[1] >= layout.size_in_blocks[1] or
        cell[2] < 0 or cell[2] >= layout.size_in_blocks[2]) return null;
    return .{ @intCast(@mod(cell[0], layout.size_in_blocks[0])), @intCast(cell[1]), @intCast(cell[2]) };
}

const Fixture = @import("terrain_test_fixture.zig").Fixture;

fn expectHit(world: *const World, position: Position, direction: Position, block: Cell, placement: ?Cell, distance: f64) !void {
    const result = try cast(world, position, direction);
    try std.testing.expect(result != null);
    const hit = result.?;
    const origin: Cell = @as(Cell, world.layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
    try std.testing.expectEqual(storedCell(world.layout, block + origin).?, hit.block);
    try std.testing.expectEqual(if (placement) |cell| storedCell(world.layout, cell + origin) else null, hit.placement);
    try std.testing.expectApproxEqAbs(distance, hit.distance, 0.00000001);
}

test "rays target the nearest block and its adjacent face in all six directions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    inline for (0..3) |axis| {
        for ([_]i64{ -1, 1 }) |sign| {
            var direction: Position = @splat(0);
            direction[axis] = @floatFromInt(sign);
            var target: Cell = @splat(0);
            target[axis] = if (sign > 0) 3 else -3;
            var placement = target;
            placement[axis] -= sign;
            fixture.set(target, .stone);
            var behind = target;
            behind[axis] += sign;
            fixture.set(behind, .stone);
            try expectHit(&fixture.world, .{ 0.5, 0.5, 0.5 }, direction, target, placement, 2.5);
            fixture.set(target, .none);
            fixture.set(behind, .none);
        }
    }
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 0, 1, 0 }));
}

test "reach is four metres to the hit face, inclusive, regardless of direction length" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 4, 0, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0, 0.5, 0.5 }, .{ 10, 0, 0 }, .{ 4, 0, 0 }, .{ 3, 0, 0 }, 4);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ -0.0001, 0.5, 0.5 }, .{ 1, 0, 0 }));
    fixture.set(.{ 4, 0, 0 }, .none);
    fixture.set(.{ 4, 4, 0 }, .stone);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 1, 0 }));
    fixture.set(.{ 3, 3, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 1, 0 }, .{ 3, 3, 0 }, .{ 2, 3, 0 }, 2.5 * @sqrt(@as(f64, 2)));
}

test "exact boundaries and diagonal edge crossings ignore cells behind or beside the ray" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, 0 }, .stone);
    fixture.set(.{ -2, 0, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0, 0.5, 0.5 }, .{ -1, 0, 0 }, .{ -2, 0, 0 }, .{ -1, 0, 0 }, 1);
    fixture.set(.{ 0, 0, 0 }, .none);
    fixture.set(.{ 1, 0, 0 }, .stone);
    fixture.set(.{ 2, 2, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 1, 0 }, .{ 2, 2, 0 }, .{ 1, 2, 0 }, 1.5 * @sqrt(@as(f64, 2)));
}

test "unknown chunks stop targeting before a block across a chunk boundary" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 33, 0, 0 }, .stone);
    try expectHit(&fixture.world, .{ 31.5, 0.5, 0.5 }, .{ 1, 0, 0 }, .{ 33, 0, 0 }, .{ 32, 0, 0 }, 1.5);
    fixture.world.removeChunk(fixture.world.layout.getChunkCoords(.{ 32.5, 0.5, 0.5 }));
    try std.testing.expectError(error.ChunkNotReceived, cast(&fixture.world, .{ 31.5, 0.5, 0.5 }, .{ 1, 0, 0 }));
}

test "targeting and placement wrap x across the seam after repeated world trips" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -64, 0, 0 }, .stone);
    for ([_]f64{ 0, 128, -256, 128 * 10000000000.0 }) |trip| {
        try expectHit(&fixture.world, .{ 63.5 + trip, 0.5, 0.5 }, .{ 1, 0, 0 }, .{ -64, 0, 0 }, .{ 63, 0, 0 }, 0.5);
    }
    fixture.set(.{ -64, 0, 0 }, .none);
    fixture.set(.{ 63, 0, 0 }, .stone);
    try expectHit(&fixture.world, .{ -63.5, 0.5, 0.5 }, .{ -1, 0, 0 }, .{ 63, 0, 0 }, .{ -64, 0, 0 }, 0.5);
}

test "finite bounds and starts inside occupied cells never invent a placement face" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 63, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0.5, 64.5, 0.5 }, .{ 0, -1, 0 }, .{ 0, 63, 0 }, null, 0.5);
    fixture.set(.{ 0, 0, 63 }, .stone);
    try expectHit(&fixture.world, .{ 0.5, 0.5, 64.5 }, .{ 0, 0, -1 }, .{ 0, 0, 63 }, null, 0.5);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.5, 0.5, 1000000 }, .{ 0, 0, -1 }));
    fixture.set(.{ 0, 0, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 0, 1, 0 }, .{ 0, 0, 0 }, null, 0);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 0, 0, 0 }));
}

test "zero-distance boundary hits retain placement faces for both signs on every axis" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, 0 }, .stone);
    inline for (0..3) |axis| {
        for ([_]i64{ -1, 1 }) |sign| {
            var position: Position = @splat(0.5);
            position[axis] = if (sign > 0) 0 else 1;
            var direction: Position = @splat(0);
            direction[axis] = @floatFromInt(sign);
            var placement: Cell = @splat(0);
            placement[axis] = -sign;
            try expectHit(&fixture.world, position, direction, .{ 0, 0, 0 }, placement, 0);
        }
    }
}

test "diagonal hits at exactly four metres tolerate rounding but reject blocks beyond reach" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 3, 3, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0.6, 0.1, 0.5 }, .{ 3, 4, 0 }, .{ 3, 3, 0 }, .{ 2, 3, 0 }, 4);
    try std.testing.expectEqual(null, try cast(&fixture.world, .{ 0.6 - 0.000001, 0.1, 0.5 }, .{ 3, 4, 0 }));
}
