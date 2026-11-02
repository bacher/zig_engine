//! Camera-ray targeting against the optimistic block cache. One unit is one metre.
const std = @import("std");
const engine = @import("engine");
const World = @import("world.zig").World;
const Position = engine.world_math.Position;
const coordinates = @import("block_coordinates.zig");
const Cell = coordinates.Cell;

pub const reach: f64 = 4;
pub const Mode = enum { putting, removing };

fn storagePosition(layout: *const engine.WorldLayout, position: Position) Position {
    var start = position + @as(Position, @floatFromInt(layout.origin_chunk)) * @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
    start[0] = @mod(start[0], @as(f64, @floatFromInt(layout.size_in_blocks[0])));
    return start;
}

/// Measure the candidate cube's nearest vertex, independently of the aimed face.
/// Wrapped x uses the nearest copy of the cube, even after repeated world trips.
pub fn withinReach(layout: *const engine.WorldLayout, position: Position, block: [3]u32) bool {
    return withinReachWithLimit(layout, position, block, reach);
}

/// Apply the same nearest-vertex rule with an explicit finite, nonnegative limit.
pub fn withinReachWithLimit(layout: *const engine.WorldLayout, position: Position, block: [3]u32, max_reach: f64) bool {
    if (!std.math.isFinite(max_reach) or max_reach < 0) return false;
    inline for (0..3) |axis| if (!std.math.isFinite(position[axis])) return false;
    const start = storagePosition(layout, position);
    var delta = @as(Position, @floatFromInt(@as(@Vector(3, u32), block))) - start;
    const width: f64 = @floatFromInt(layout.size_in_blocks[0]);
    delta[0] = @mod(delta[0] + 0.5 + width / 2, width) - width / 2 - 0.5;
    // Each axis can independently choose its nearer cube endpoint.
    const corner = @min(@abs(delta), @abs(delta + @as(Position, @splat(1))));
    const distance_squared = @reduce(.Add, corner * corner);
    // Allow only floating-point rounding at the storage-coordinate scale.
    const tolerance = 8 * std.math.floatEps(f64) * @max(max_reach, @reduce(.Max, @abs(start)));
    return std.math.isFinite(distance_squared) and distance_squared <= (max_reach + tolerance) * (max_reach + tolerance);
}

/// Shared by highlighting and actual actions: find the first occupied cell,
/// select the edited cube, then apply its four-metre nearest-vertex reach check.
pub fn findTarget(world: *const World, position: Position, direction: Position, mode: Mode) @import("world.zig").ChunkNotReceivedError!?[3]u32 {
    return findTargetWithReach(world, position, direction, mode, reach);
}

/// Select the same edited cube as ordinary targeting with a caller-supplied reach.
/// Invalid reach limits produce no target and do not traverse the world.
pub fn findTargetWithReach(world: *const World, position: Position, direction: Position, mode: Mode, max_reach: f64) @import("world.zig").ChunkNotReceivedError!?[3]u32 {
    const hit = (try castInternal(world, position, direction, mode == .putting, max_reach)) orelse return null;
    const block = switch (mode) {
        .removing => hit.block,
        .putting => hit.placement orelse return null,
    };
    return if (withinReachWithLimit(world.layout, position, block, max_reach)) block else null;
}

pub const Hit = struct {
    block: [3]u32,
    /// The face-adjacent cell, absent for strictly interior starts or outside storage.
    placement: ?[3]u32,
    distance: f64,
};

/// Walk voxel boundaries in distance order within the conservative ray limit,
/// stopping at the first occupied cell. Hit distance does not decide tool reach.
/// Unknown chunks stop the ray rather than allowing edits through unloaded terrain.
pub fn cast(world: *const World, position: Position, direction: Position) @import("world.zig").ChunkNotReceivedError!?Hit {
    return castWithReach(world, position, direction, reach);
}

/// Cast against physical blocks with an explicit reach and no planned targets.
/// The returned hit still needs the edited cube's nearest-vertex reach check.
pub fn castWithReach(world: *const World, position: Position, direction: Position, max_reach: f64) @import("world.zig").ChunkNotReceivedError!?Hit {
    return castInternal(world, position, direction, false, max_reach);
}

fn castInternal(world: *const World, position: Position, direction: Position, planned_targets: bool, max_reach: f64) @import("world.zig").ChunkNotReceivedError!?Hit {
    if (!std.math.isFinite(max_reach) or max_reach < 0) return null;
    // A hit on the occupied or face-adjacent placement cube is at most one cube
    // diagonal beyond a reachable vertex, regardless of the aimed face.
    const ray_limit = max_reach + @sqrt(@as(f64, 3));
    const length = @sqrt(@reduce(.Add, direction * direction));
    if (!std.math.isFinite(length) or length == 0) return null;
    inline for (0..3) |axis| if (!std.math.isFinite(position[axis])) return null;
    const forward = direction / @as(Position, @splat(length));
    const start = storagePosition(world.layout, position);
    // Allow eight f64 epsilon units at the storage-coordinate scale for origin
    // conversion, normalization and DDA accumulation. Use the same allowance for
    // the inclusive traversal limit and mathematically tied boundary crossings.
    const distance_tolerance = 8 * std.math.floatEps(f64) * @max(ray_limit, @reduce(.Max, @abs(start)));
    const traversal_limit = ray_limit + distance_tolerance;
    // Even a spectator far outside the finite world cannot reach it from here.
    inline for (1..3) |axis| {
        if (start[axis] < -traversal_limit or start[axis] > @as(f64, @floatFromInt(world.layout.size_in_blocks[axis])) + traversal_limit) return null;
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
    while (distance <= traversal_limit) {
        const exit = @reduce(.Min, next);
        // At an exact boundary, ignore the cell behind a negative-pointing ray.
        if (exit > distance) {
            if (coordinates.fromStorage(world.layout, cell)) |block| {
                // Pending targets use their full logical cube while remaining physically air.
                const physical_solid = try world.isBlockSolid(block);
                if (planned_targets and !physical_solid and world.blueprints.targetAt(block) != null) {
                    return .{ .block = block, .placement = block, .distance = distance };
                }
                if (physical_solid) {
                    var hit_distance = distance;
                    var hit_step = entry_step;
                    if (world.customShape(block)) |shape| if (shape == .slope) {
                        const origin: Position = @floatFromInt(cell);
                        const fraction = shape.sweep(start - origin, forward * @as(Position, @splat(traversal_limit)), @splat(0), @splat(0));
                        if (fraction) |t| {
                            hit_distance = t * traversal_limit;
                            const local_hit = start + forward * @as(Position, @splat(hit_distance)) - origin;
                            if (hit_distance > 0 and @abs(local_hit[2] - shape.height(local_hit[0], local_hit[1])) < 1e-7)
                                hit_step = Cell{ 0, 0, -1 };
                        } else {
                            hit_distance = std.math.inf(f64);
                        }
                    };
                    if (hit_distance <= @min(exit, traversal_limit) + distance_tolerance) {
                        var placement: ?[3]u32 = null;
                        if (hit_step) |normal| {
                            placement = coordinates.fromStorage(world.layout, cell - normal);
                        }
                        return .{ .block = block, .placement = placement, .distance = hit_distance };
                    }
                }
            }
        }
        if (exit > traversal_limit) return null;
        distance = exit;
        entry_step = null;
        // Skip cells touched only at an edge/corner. Choose a deterministic face at ties.
        inline for (0..3) |axis| {
            if (next[axis] - exit <= distance_tolerance) {
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

const Fixture = @import("terrain_test_fixture.zig").Fixture;

fn expectHit(world: *const World, position: Position, direction: Position, block: Cell, placement: ?Cell, distance: f64) !void {
    const result = try cast(world, position, direction);
    try std.testing.expect(result != null);
    const hit = result.?;
    try std.testing.expectEqual(coordinates.fromWorld(world.layout, block).?, hit.block);
    try std.testing.expectEqual(if (placement) |cell| coordinates.fromWorld(world.layout, cell) else null, hit.placement);
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

test "ray intersections beyond four metres remain available for candidate reach checks" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 4, 0, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0, 0.5, 0.5 }, .{ 10, 0, 0 }, .{ 4, 0, 0 }, .{ 3, 0, 0 }, 4);
    try expectHit(&fixture.world, .{ -0.0001, 0.5, 0.5 }, .{ 1, 0, 0 }, .{ 4, 0, 0 }, .{ 3, 0, 0 }, 4.0001);
    fixture.set(.{ 4, 0, 0 }, .none);
    fixture.set(.{ 4, 4, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 1, 0 }, .{ 4, 4, 0 }, .{ 3, 4, 0 }, 3.5 * @sqrt(@as(f64, 2)));
    fixture.set(.{ 4, 4, 0 }, .none);
    fixture.set(.{ 5, 5, 0 }, .stone);
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

test "unequal diagonals skip corner-only cells for either sign and every axis ordering" {
    const cases = [_]struct { direction: Position, graze: Cell, target: Cell, placement: Cell }{
        .{ .direction = .{ 1, 3, 0 }, .graze = .{ 1, 1, 0 }, .target = .{ 1, 2, 0 }, .placement = .{ 0, 2, 0 } },
        .{ .direction = .{ 3, 1, 0 }, .graze = .{ 1, 1, 0 }, .target = .{ 2, 1, 0 }, .placement = .{ 1, 1, 0 } },
        .{ .direction = .{ 1, 0, 3 }, .graze = .{ 1, 0, 1 }, .target = .{ 1, 0, 2 }, .placement = .{ 0, 0, 2 } },
        .{ .direction = .{ 3, 0, 1 }, .graze = .{ 1, 0, 1 }, .target = .{ 2, 0, 1 }, .placement = .{ 1, 0, 1 } },
        .{ .direction = .{ 0, 1, 3 }, .graze = .{ 0, 1, 1 }, .target = .{ 0, 1, 2 }, .placement = .{ 0, 0, 2 } },
        .{ .direction = .{ 0, 3, 1 }, .graze = .{ 0, 1, 1 }, .target = .{ 0, 2, 1 }, .placement = .{ 0, 1, 1 } },
        .{ .direction = .{ 1, 1, 3 }, .graze = .{ 1, 1, 1 }, .target = .{ 1, 1, 2 }, .placement = .{ 0, 1, 2 } },
    };
    for (cases) |case| {
        for ([_]i64{ -1, 1 }) |sign| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            var graze = case.graze;
            var target = case.target;
            var placement = case.placement;
            inline for (0..3) |axis| {
                graze[axis] *= sign;
                target[axis] *= sign;
                placement[axis] *= sign;
            }
            const direction = case.direction * @as(Position, @splat(@floatFromInt(sign)));
            fixture.set(graze, .stone);
            fixture.set(target, .stone);
            const distance = 0.5 * @sqrt(@reduce(.Add, direction * direction));
            try expectHit(&fixture.world, .{ 0.5, 0.5, 0.5 }, direction, target, placement, distance);
        }
    }
}

test "nearby distinct diagonal crossings still target a briefly entered cell" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 1, 1, 0 }, .stone);
    fixture.set(.{ 1, 2, 0 }, .stone);
    const direction: Position = .{ 1, 3 - 0.000001, 0 };
    try expectHit(&fixture.world, .{ 0.5, 0.5, 0.5 }, direction, .{ 1, 1, 0 }, .{ 0, 1, 0 }, 0.5 * @sqrt(@reduce(.Add, direction * direction)));
}

test "tied crossings skip unloaded grazed chunks but stop at unloaded entered chunks" {
    const cases = [_]struct { start: Position, direction: Position, graze: Position, target: Cell, placement: Cell }{
        .{ .start = .{ 31.5, 30.5, 0.5 }, .direction = .{ 1, 3, 0 }, .graze = .{ 32.5, 31.5, 0.5 }, .target = .{ 32, 32, 0 }, .placement = .{ 31, 32, 0 } },
        .{ .start = .{ 0.5, 1.5, 0.5 }, .direction = .{ -1, -3, 0 }, .graze = .{ -0.5, 0.5, 0.5 }, .target = .{ -1, -1, 0 }, .placement = .{ 0, -1, 0 } },
    };
    for (cases) |case| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.set(case.target, .stone);
        fixture.world.removeChunk(fixture.world.layout.getChunkCoords(case.graze));
        try expectHit(&fixture.world, case.start, case.direction, case.target, case.placement, 0.5 * @sqrt(@as(f64, 10)));
        const target_position = @as(Position, @floatFromInt(case.target)) + @as(Position, @splat(0.5));
        fixture.world.removeChunk(fixture.world.layout.getChunkCoords(target_position));
        try std.testing.expectError(error.ChunkNotReceived, cast(&fixture.world, case.start, case.direction));
    }
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

test "diagonal ray hits retain their face when crossing the former four-metre cutoff" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 3, 3, 0 }, .stone);
    try expectHit(&fixture.world, .{ 0.6, 0.1, 0.5 }, .{ 3, 4, 0 }, .{ 3, 3, 0 }, .{ 2, 3, 0 }, 4);
    try expectHit(&fixture.world, .{ 0.6 - 0.000001, 0.1, 0.5 }, .{ 3, 4, 0 }, .{ 3, 3, 0 }, .{ 2, 3, 0 }, 4 + 0.000001 / 0.6);
}

test "every nearest vertex includes four metres and excludes points just beyond" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const layout = fixture.world.layout;
    const block = coordinates.fromWorld(layout, .{ 0, 0, 0 }).?;
    inline for (0..8) |vertex| {
        const corner: Position = .{ vertex & 1, (vertex >> 1) & 1, (vertex >> 2) & 1 };
        const outward = (corner * @as(Position, @splat(2)) - @as(Position, @splat(1))) / @as(Position, @splat(@sqrt(@as(f64, 3))));
        try std.testing.expect(withinReach(layout, corner + outward * @as(Position, @splat(4)), block));
        try std.testing.expect(!withinReach(layout, corner + outward * @as(Position, @splat(4.000001)), block));
    }
    inline for (0..3) |axis| {
        for ([_]f64{ -1, 1 }) |sign| {
            var position: Position = @splat(0);
            position[axis] = if (sign < 0) -4 else 5;
            try std.testing.expect(withinReach(layout, position, block));
            position[axis] += sign * 0.000001;
            try std.testing.expect(!withinReach(layout, position, block));
        }
    }
    try std.testing.expect(!withinReach(layout, .{ std.math.nan(f64), 0, 0 }, block));
    try std.testing.expect(!withinReach(layout, .{ 0, std.math.inf(f64), 0 }, block));
    try std.testing.expect(!withinReach(layout, .{ 0, std.math.floatMax(f64), 0 }, block));
}

test "removal reach measures the cube regardless of its aimed face" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 3, 2, 0 }, .stone);
    const block = coordinates.fromWorld(fixture.world.layout, .{ 3, 2, 0 }).?;
    // Both visible faces belong to the same cube, but the second hit is beyond 4 m.
    for ([_]Position{ .{ 3, 2.1, 0.5 }, .{ 3.9, 2, 0.9 } }) |direction| {
        try std.testing.expectEqual(block, (try findTarget(&fixture.world, .{ 0, 0, 0 }, direction, .removing)).?);
    }
    try std.testing.expect((try cast(&fixture.world, .{ 0, 0, 0 }, .{ 3.9, 2, 0.9 })).?.distance > reach);
}

test "placement checks its adjacent cube even when the backing cube is out of reach" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 5, 0, 0 }, .stone);
    const placement = coordinates.fromWorld(fixture.world.layout, .{ 4, 0, 0 }).?;
    try std.testing.expectEqual(placement, (try findTarget(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 10, 0, 0 }, .putting)).?);
    try std.testing.expectEqual(null, try findTarget(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing));
    fixture.set(.{ 4, 0, 0 }, .stone);
    try std.testing.expectEqual(placement, (try findTarget(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing)).?);
    fixture.set(.{ 4, 0, 0 }, .none);
    try std.testing.expectEqual(placement, (try findTarget(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 0, 0 }, .putting)).?);
}

test "placement reaches a backing face near the full four-metres-plus-diagonal traversal bound" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 1, 0, 0 }, .stone);
    const position: Position = @splat(-reach / @sqrt(@as(f64, 3)));
    const aim: Position = .{ 1, 1 - 0.000001, 1 - 0.000001 };
    const direction = aim - position;
    const placement = coordinates.fromWorld(fixture.world.layout, .{ 0, 0, 0 }).?;
    const hit = (try cast(&fixture.world, position, direction)).?;
    try std.testing.expectEqual(coordinates.fromWorld(fixture.world.layout, .{ 1, 0, 0 }).?, hit.block);
    try std.testing.expectEqual(placement, hit.placement.?);
    try std.testing.expectApproxEqAbs(reach + @sqrt(@as(f64, 3)), hit.distance, 0.000002);
    // The candidate's nearest vertex is exactly 4 m away, although the backing
    // face is almost 5.732 m away and its cube is unreachable.
    try std.testing.expectEqual(placement, (try findTarget(&fixture.world, position, direction, .putting)).?);
    try std.testing.expectEqual(null, try findTarget(&fixture.world, position, direction, .removing));
}

test "nearest-vertex reach wraps cube distances across x after repeated world trips" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -64, 0, 0 }, .stone);
    const block = coordinates.fromWorld(fixture.world.layout, .{ -64, 0, 0 }).?;
    for ([_]f64{ 0, 128, -256, 128 * 10000000000.0 }) |trip| {
        try std.testing.expectEqual(block, (try findTarget(&fixture.world, .{ 60.5 + trip, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing)).?);
        try std.testing.expectEqual(null, try findTarget(&fixture.world, .{ 59.5 + trip, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing));
    }
    // The upper x vertices of the last stored cube wrap too.
    const reverse = coordinates.fromWorld(fixture.world.layout, .{ 63, 0, 0 }).?;
    try std.testing.expect(withinReach(fixture.world.layout, .{ -63.5, 0.5, 0.5 }, reverse));
}

test "an occupied out-of-reach cube occludes further targets and unknown data still stops targeting" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 4, 0, 0 }, .stone);
    fixture.set(.{ 5, 0, 0 }, .stone);
    try std.testing.expectEqual(null, try findTarget(&fixture.world, .{ 0, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing));
    fixture.world.removeChunk(fixture.world.layout.getChunkCoords(.{ 0.5, 0.5, 0.5 }));
    try std.testing.expectError(error.ChunkNotReceived, findTarget(&fixture.world, .{ 0, 0.5, 0.5 }, .{ 1, 0, 0 }, .putting));
}

test "extended placement reaches thirty metres while ordinary targeting stays at four" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 31, 0, 0 }, .stone);
    const placement = coordinates.fromWorld(fixture.world.layout, .{ 30, 0, 0 }).?;
    const position: Position = .{ 0, 0, 0 };
    const direction: Position = .{ 1, 0, 0 };
    try std.testing.expectEqual(null, try findTarget(&fixture.world, position, direction, .putting));
    try std.testing.expectEqual(null, try cast(&fixture.world, position, direction));
    const hit = (try castWithReach(&fixture.world, position, direction, 30)).?;
    try std.testing.expectEqual(coordinates.fromWorld(fixture.world.layout, .{ 31, 0, 0 }).?, hit.block);
    try std.testing.expectEqual(placement, hit.placement.?);
    try std.testing.expectApproxEqAbs(@as(f64, 31), hit.distance, 0.00000001);
    try std.testing.expectEqual(placement, (try findTargetWithReach(&fixture.world, position, direction, .putting, 30)).?);
    try std.testing.expectEqual(null, try findTargetWithReach(&fixture.world, .{ -0.000001, 0, 0 }, direction, .putting, 30));
    // Reach belongs to the edited cube: its backing cube is beyond thirty metres.
    try std.testing.expectEqual(null, try findTargetWithReach(&fixture.world, position, direction, .removing, 30));
    fixture.set(.{ 20, 0, 0 }, .stone);
    const nearer = coordinates.fromWorld(fixture.world.layout, .{ 20, 0, 0 }).?;
    try std.testing.expectEqual(nearer, (try findTargetWithReach(&fixture.world, position, direction, .removing, 30)).?);
    try std.testing.expectEqual(coordinates.fromWorld(fixture.world.layout, .{ 19, 0, 0 }).?, (try findTargetWithReach(&fixture.world, position, direction, .putting, 30)).?);
}

test "extended nearest-vertex reach includes thirty metres at every cube vertex" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const layout = fixture.world.layout;
    const block = coordinates.fromWorld(layout, .{ 0, 0, 0 }).?;
    inline for (0..8) |vertex| {
        const corner: Position = .{ vertex & 1, (vertex >> 1) & 1, (vertex >> 2) & 1 };
        const outward = (corner * @as(Position, @splat(2)) - @as(Position, @splat(1))) / @as(Position, @splat(@sqrt(@as(f64, 3))));
        try std.testing.expect(withinReachWithLimit(layout, corner + outward * @as(Position, @splat(30)), block, 30));
        try std.testing.expect(!withinReachWithLimit(layout, corner + outward * @as(Position, @splat(30.000001)), block, 30));
    }
    try std.testing.expect(withinReachWithLimit(layout, .{ 0, 0, 0 }, block, 0));
    try std.testing.expect(!withinReachWithLimit(layout, .{ 0.5, 0.5, 0.5 }, block, 0));
}

test "extended placement keeps the full reach-plus-diagonal traversal allowance" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 1, 0, 0 }, .stone);
    const position: Position = @splat(-30 / @sqrt(@as(f64, 3)));
    const direction = @as(Position, .{ 1, 1 - 0.000001, 1 - 0.000001 }) - position;
    const placement = coordinates.fromWorld(fixture.world.layout, .{ 0, 0, 0 }).?;
    try std.testing.expectEqual(placement, (try findTargetWithReach(&fixture.world, position, direction, .putting, 30)).?);
    try std.testing.expectEqual(null, try findTargetWithReach(&fixture.world, position, direction, .removing, 30));
}

test "extended targeting respects nearer occluders and unloaded chunks" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 33, 0, 0 }, .stone);
    const position: Position = .{ 4, 0.5, 0.5 };
    const direction: Position = .{ 1, 0, 0 };
    const placement = coordinates.fromWorld(fixture.world.layout, .{ 32, 0, 0 }).?;
    try std.testing.expectEqual(placement, (try findTargetWithReach(&fixture.world, position, direction, .putting, 30)).?);
    fixture.set(.{ 15, 0, 0 }, .stone);
    const occluder_placement = coordinates.fromWorld(fixture.world.layout, .{ 14, 0, 0 }).?;
    try std.testing.expectEqual(occluder_placement, (try findTargetWithReach(&fixture.world, position, direction, .putting, 30)).?);
    fixture.set(.{ 15, 0, 0 }, .none);
    fixture.world.removeChunk(fixture.world.layout.getChunkCoords(.{ 32.5, 0.5, 0.5 }));
    try std.testing.expectError(error.ChunkNotReceived, findTargetWithReach(&fixture.world, position, direction, .putting, 30));
}

test "extended targeting wraps x after repeated world trips" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -50, 0, 0 }, .stone);
    const placement = coordinates.fromWorld(fixture.world.layout, .{ -51, 0, 0 }).?;
    for ([_]f64{ 0, 128, -256, 128 * 10000000000.0 }) |trip| {
        const position: Position = .{ 60.5 + trip, 0.5, 0.5 };
        try std.testing.expectEqual(placement, (try findTargetWithReach(&fixture.world, position, .{ 1, 0, 0 }, .putting, 30)).?);
        try std.testing.expectEqual(null, try findTarget(&fixture.world, position, .{ 1, 0, 0 }, .putting));
    }
}

test "invalid reach limits reject targeting before entering an unloaded chunk" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const position: Position = .{ 0.5, 0.5, 0.5 };
    const block = coordinates.fromWorld(fixture.world.layout, .{ 0, 0, 0 }).?;
    fixture.world.removeChunk(fixture.world.layout.getChunkCoords(position));
    for ([_]f64{ -1, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |max_reach| {
        try std.testing.expectEqual(null, try findTargetWithReach(&fixture.world, position, .{ 1, 0, 0 }, .putting, max_reach));
        try std.testing.expectEqual(null, try castWithReach(&fixture.world, position, .{ 1, 0, 0 }, max_reach));
        try std.testing.expect(!withinReachWithLimit(fixture.world.layout, position, block, max_reach));
    }
}

test "physical casts skip planned targets while placement retains them at either reach" {
    for ([_]i64{ 2, 20 }) |distance| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const world = &fixture.world;
        const allocator = world.allocator;
        const planned = coordinates.fromWorld(world.layout, .{ distance, 0, 0 }).?;
        const runtime = @import("blueprint_runtime.zig");
        var saved: runtime.SavedDefinition = .{
            .id = 1,
            .owner = 1,
            .name = try allocator.dupe(u8, "Target"),
            .definition = .{ .size = .{ 1, 1, 1 }, .cells = try allocator.dupe(engine.voxel_chunk.BlockType, &.{.stone}), .target_count = 1 },
        };
        world.blueprints.insertDefinition(allocator, saved) catch |err| {
            saved.deinit(allocator);
            return err;
        };
        var instance = try world.blueprints.prepareInstance(allocator, world.layout, 1, 1, 1, planned, 0);
        world.blueprints.insertInstance(allocator, world.layout, instance) catch |err| {
            instance.deinit(allocator);
            return err;
        };
        const backing: Cell = .{ distance + 5, 0, 0 };
        fixture.set(backing, .stone);
        const position: Position = .{ 0.5, 0.5, 0.5 };
        const direction: Position = .{ 1, 0, 0 };
        const max_reach: f64 = if (distance < 4) reach else 30;
        try std.testing.expectEqual(planned, (try findTargetWithReach(world, position, direction, .putting, max_reach)).?);
        if (max_reach == reach) try std.testing.expectEqual(planned, (try findTarget(world, position, direction, .putting)).?);
        const hit = (try castWithReach(world, position, direction, 30)).?;
        try std.testing.expectEqual(coordinates.fromWorld(world.layout, backing).?, hit.block);
        try std.testing.expectEqual(coordinates.fromWorld(world.layout, .{ distance + 4, 0, 0 }).?, hit.placement.?);
    }
}
