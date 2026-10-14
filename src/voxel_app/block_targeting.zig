//! Camera-ray targeting against the optimistic block cache. One unit is one metre.
const std = @import("std");
const engine = @import("engine");
const World = @import("world.zig").World;
const Position = engine.world_math.Position;
const coordinates = @import("block_coordinates.zig");
const Cell = coordinates.Cell;

pub const reach: f64 = 4;
pub const Mode = enum { putting, removing };
pub const ReachMode = enum { center, nearest_vertex };

// A hit on either the occupied cube or its face-adjacent placement cube cannot
// be farther than one cube diagonal from a reachable vertex. This bounds the
// traversal without rejecting a candidate by its hit-face distance.
const ray_limit = reach + @sqrt(@as(f64, 3));

fn storagePosition(layout: *const engine.WorldLayout, position: Position) Position {
    var start = position + @as(Position, @floatFromInt(layout.origin_chunk)) * @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
    start[0] = @mod(start[0], @as(f64, @floatFromInt(layout.size_in_blocks[0])));
    return start;
}

/// Measure the candidate cube, independently of which face the ray hit.
/// Wrapped x uses the nearest copy of the cube, even after repeated world trips.
pub fn withinReach(layout: *const engine.WorldLayout, position: Position, block: [3]u32, mode: ReachMode) bool {
    inline for (0..3) |axis| if (!std.math.isFinite(position[axis])) return false;
    const start = storagePosition(layout, position);
    var delta = @as(Position, @floatFromInt(@as(@Vector(3, u32), block))) - start;
    const width: f64 = @floatFromInt(layout.size_in_blocks[0]);
    delta[0] = @mod(delta[0] + 0.5 + width / 2, width) - width / 2 - 0.5;
    var distance_squared = std.math.inf(f64);
    switch (mode) {
        .center => {
            const center = delta + @as(Position, @splat(0.5));
            distance_squared = @reduce(.Add, center * center);
        },
        .nearest_vertex => {
            inline for (0..8) |vertex| {
                const offset: Position = .{ vertex & 1, (vertex >> 1) & 1, (vertex >> 2) & 1 };
                const corner = delta + offset;
                distance_squared = @min(distance_squared, @reduce(.Add, corner * corner));
            }
        },
    }
    // Allow only floating-point rounding at the storage-coordinate scale.
    const tolerance = 8 * std.math.floatEps(f64) * @max(reach, @reduce(.Max, @abs(start)));
    return std.math.isFinite(distance_squared) and distance_squared <= (reach + tolerance) * (reach + tolerance);
}

/// Shared by highlighting and actual actions: find the first occupied cell,
/// select the edited cube, then apply the active four-metre distance rule.
pub fn findTarget(world: *const World, position: Position, direction: Position, mode: Mode, reach_mode: ReachMode) @import("world.zig").ChunkNotReceivedError!?[3]u32 {
    const hit = (try cast(world, position, direction)) orelse return null;
    const block = switch (mode) {
        .removing => hit.block,
        .putting => hit.placement orelse return null,
    };
    return if (withinReach(world.layout, position, block, reach_mode)) block else null;
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
                if (try world.isBlockSolid(block)) {
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

test "center and every nearest vertex include four metres and exclude points just beyond" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const layout = fixture.world.layout;
    const block = coordinates.fromWorld(layout, .{ 0, 0, 0 }).?;
    inline for (0..8) |vertex| {
        const corner: Position = .{ vertex & 1, (vertex >> 1) & 1, (vertex >> 2) & 1 };
        const outward = (corner * @as(Position, @splat(2)) - @as(Position, @splat(1))) / @as(Position, @splat(@sqrt(@as(f64, 3))));
        try std.testing.expect(withinReach(layout, corner + outward * @as(Position, @splat(4)), block, .nearest_vertex));
        try std.testing.expect(!withinReach(layout, corner + outward * @as(Position, @splat(4.000001)), block, .nearest_vertex));
        const center: Position = @splat(0.5);
        try std.testing.expect(withinReach(layout, center + outward * @as(Position, @splat(4)), block, .center));
        try std.testing.expect(!withinReach(layout, center + outward * @as(Position, @splat(4.000001)), block, .center));
    }
    inline for (0..3) |axis| {
        var position: Position = @splat(0.5);
        position[axis] += 4;
        try std.testing.expect(withinReach(layout, position, block, .center));
        position[axis] += 0.000001;
        try std.testing.expect(!withinReach(layout, position, block, .center));
    }
    try std.testing.expect(!withinReach(layout, .{ std.math.nan(f64), 0, 0 }, block, .center));
    try std.testing.expect(!withinReach(layout, .{ 0, std.math.inf(f64), 0 }, block, .nearest_vertex));
    try std.testing.expect(!withinReach(layout, .{ 0, std.math.floatMax(f64), 0 }, block, .center));
}

test "removal reach measures the cube regardless of its aimed face" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 3, 2, 0 }, .stone);
    const block = coordinates.fromWorld(fixture.world.layout, .{ 3, 2, 0 }).?;
    // Both visible faces belong to the same cube, but the second hit is beyond 4 m.
    for ([_]Position{ .{ 3, 2.1, 0.5 }, .{ 3.9, 2, 0.9 } }) |direction| {
        try std.testing.expectEqual(block, (try findTarget(&fixture.world, .{ 0, 0, 0 }, direction, .removing, .nearest_vertex)).?);
        try std.testing.expectEqual(null, try findTarget(&fixture.world, .{ 0, 0, 0 }, direction, .removing, .center));
    }
    try std.testing.expect((try cast(&fixture.world, .{ 0, 0, 0 }, .{ 3.9, 2, 0.9 })).?.distance > reach);
}

test "placement checks its adjacent cube even when the backing cube is out of reach" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 5, 0, 0 }, .stone);
    const placement = coordinates.fromWorld(fixture.world.layout, .{ 4, 0, 0 }).?;
    for ([_]ReachMode{ .center, .nearest_vertex }) |mode| {
        try std.testing.expectEqual(placement, (try findTarget(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 10, 0, 0 }, .putting, mode)).?);
        try std.testing.expectEqual(null, try findTarget(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing, mode));
        fixture.set(.{ 4, 0, 0 }, .stone);
        try std.testing.expectEqual(placement, (try findTarget(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing, mode)).?);
        fixture.set(.{ 4, 0, 0 }, .none);
        try std.testing.expectEqual(placement, (try findTarget(&fixture.world, .{ 0.5, 0.5, 0.5 }, .{ 1, 0, 0 }, .putting, mode)).?);
    }
}

test "both reach modes wrap cube distances across x after repeated world trips" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -64, 0, 0 }, .stone);
    const block = coordinates.fromWorld(fixture.world.layout, .{ -64, 0, 0 }).?;
    for ([_]f64{ 0, 128, -256, 128 * 10000000000.0 }) |trip| {
        for ([_]ReachMode{ .center, .nearest_vertex }) |mode| {
            try std.testing.expectEqual(block, (try findTarget(&fixture.world, .{ 60.5 + trip, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing, mode)).?);
            try std.testing.expectEqual(null, try findTarget(&fixture.world, .{ 59.5 + trip, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing, mode));
        }
    }
    // The upper x vertices of the last stored cube wrap too.
    const reverse = coordinates.fromWorld(fixture.world.layout, .{ 63, 0, 0 }).?;
    try std.testing.expect(withinReach(fixture.world.layout, .{ -63.5, 0.5, 0.5 }, reverse, .nearest_vertex));
    try std.testing.expect(withinReach(fixture.world.layout, .{ -63.5, 0.5, 0.5 }, reverse, .center));
}

test "an occupied out-of-reach cube occludes further targets and unknown data still stops targeting" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 4, 0, 0 }, .stone);
    fixture.set(.{ 5, 0, 0 }, .stone);
    for ([_]ReachMode{ .center, .nearest_vertex }) |mode| {
        try std.testing.expectEqual(null, try findTarget(&fixture.world, .{ 0, 0.5, 0.5 }, .{ 1, 0, 0 }, .removing, mode));
        fixture.world.removeChunk(fixture.world.layout.getChunkCoords(.{ 0.5, 0.5, 0.5 }));
        try std.testing.expectError(error.ChunkNotReceived, findTarget(&fixture.world, .{ 0, 0.5, 0.5 }, .{ 1, 0, 0 }, .putting, mode));
        try fixture.world.insertChunk(fixture.world.layout.getChunkCoords(.{ 0.5, 0.5, 0.5 }), @import("world.zig").WorldChunk.initEmpty());
        fixture.set(.{ 4, 0, 0 }, .stone);
        fixture.set(.{ 5, 0, 0 }, .stone);
    }
}
