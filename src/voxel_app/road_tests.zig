const std = @import("std");
const engine = @import("engine");
const world = @import("world.zig");
const Fixture = @import("terrain_test_fixture.zig").Fixture;
const coordinates = @import("block_coordinates.zig");
const Cell = coordinates.Cell;
const custom = engine.voxel_chunk.custom_block;
const collision = @import("terrain_collision.zig");
const player_module = @import("player_controller.zig");

fn storage(fixture: *const Fixture, cell: Cell) [3]u32 {
    return coordinates.fromWorld(fixture.world.layout, cell).?;
}
fn shape(fixture: *const Fixture, cell: Cell) ?custom.Shape {
    return fixture.world.customShape(storage(fixture, cell));
}

fn row(fixture: *Fixture, high: Cell, direction: custom.Direction, n: u32) void {
    const step = direction.offset();
    for (0..n + 1) |i| fixture.set(high + step * @as(Cell, @splat(@intCast(i))) - Cell{ 0, 0, 1 }, .stone);
    const low = high + step * @as(Cell, @splat(n + 1)) - Cell{ 0, 0, 1 };
    fixture.set(low - Cell{ 0, 0, 1 }, .stone);
    fixture.set(high, .country_road_solid);
    for (0..n) |i| fixture.set(high + step * @as(Cell, @splat(@intCast(i + 1))), .country_road_adaptive);
    fixture.set(low, .country_road_solid);
}

test "country roads form only 4 through 12 sections with saved orientation in every direction" {
    for (std.enums.values(custom.Direction)) |direction| {
        for ([_]u32{ 3, 4, 7, 12, 13 }) |n| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            const high: Cell = .{ 0, 0, 0 };
            row(&fixture, high, direction, n);
            for (0..n) |i| {
                const member = high + direction.offset() * @as(Cell, @splat(@intCast(i + 1)));
                const current = shape(&fixture, member).?;
                if (n < 4 or n > 12) {
                    try std.testing.expect(current == .adaptive);
                    continue;
                }
                try std.testing.expect(current == .slope);
                try std.testing.expectEqual(direction, current.slope.downhill);
                try std.testing.expectApproxEqAbs(1 - @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)), current.slope.high, 1e-10);
                const coords, const local = world.splitBlockCoords(storage(&fixture, member));
                try std.testing.expectEqual(@as(u8, 255), @intFromEnum(fixture.world.getChunk(coords).?.content.getBlock(local)));
            }
        }
    }
}

test "breaking either endpoint or any section reverts the whole run across chunk boundaries" {
    for ([_]i64{ 0, 1, 6, 12, 13 }) |removed| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const high: Cell = .{ -4, 0, 0 };
        row(&fixture, high, .positive_x, 12);
        const target = high + Cell{ removed, 0, if (removed == 13) @as(i64, -1) else 0 };
        const result = fixture.world.setBlock(storage(&fixture, target), .none);
        try std.testing.expectEqual(world.OperationStatus.success, result.status);
        try std.testing.expect(!try fixture.world.isBlockSolid(storage(&fixture, target)));
        for (1..13) |i| {
            if (i == removed) continue;
            try std.testing.expect(shape(&fixture, high + Cell{ @intCast(i), 0, 0 }).? == .adaptive);
        }
    }
}

test "a formed crossing retains its snapshotted ownership and an ambiguous fresh crossing stays unformed" {
    for ([_]bool{ false, true }) |ambiguous| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const center: Cell = .{ 2, 0, 0 };
        if (!ambiguous) row(&fixture, .{ 0, 0, 0 }, .positive_x, 4);
        for (0..5) |i| {
            const at: Cell = .{ 2, @as(i64, @intCast(i)) - 2, 0 };
            fixture.set(at - Cell{ 0, 0, 1 }, .stone);
            if (i == 0) fixture.set(at, .country_road_solid) else if (i != 2) fixture.set(at, .country_road_adaptive);
        }
        fixture.set(.{ 2, 3, -2 }, .stone);
        fixture.set(.{ 2, 3, -1 }, .country_road_solid);
        if (ambiguous) {
            for (0..5) |i| {
                fixture.set(.{ @intCast(i), 0, -1 }, .stone);
                if (i == 0) fixture.set(.{ 0, 0, 0 }, .country_road_solid) else if (i != 2) fixture.set(.{ @intCast(i), 0, 0 }, .country_road_adaptive);
            }
            fixture.set(.{ 5, 0, -2 }, .stone);
            fixture.set(.{ 5, 0, -1 }, .country_road_solid);
            fixture.set(center, .country_road_adaptive);
            try std.testing.expect(shape(&fixture, center).? == .adaptive);
            try std.testing.expect(shape(&fixture, .{ 1, 0, 0 }).? == .adaptive);
            try std.testing.expect(shape(&fixture, .{ 2, 1, 0 }).? == .adaptive);
        } else {
            try std.testing.expectEqual(custom.Direction.positive_x, shape(&fixture, center).?.slope.downhill);
            try std.testing.expect(shape(&fixture, .{ 2, 1, 0 }).? == .adaptive);
            // Removing an unrelated perpendicular endpoint does not break the owned row.
            fixture.set(.{ 2, -2, 0 }, .none);
            try std.testing.expect(shape(&fixture, center).? == .slope);
        }
    }
}

test "road placement needs direct support and cannot remove that support" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for ([_]engine.voxel_chunk.BlockType{ .country_road_solid, .country_road_adaptive }) |material| {
        const target = storage(&fixture, .{ 0, 0, 0 });
        const rejected = fixture.world.setBlock(target, material);
        try std.testing.expectEqual(world.OperationStatus.constraint_violation, rejected.status);
        try std.testing.expectEqual(@import("block_rules.zig").Reason.road_support, rejected.failure.?.reason);
        fixture.set(.{ 0, 0, -1 }, .stone);
        try std.testing.expectEqual(world.OperationStatus.success, fixture.world.setBlock(target, material).status);
        try std.testing.expectEqual(world.OperationStatus.constraint_violation, fixture.world.setBlock(storage(&fixture, .{ 0, 0, -1 }), .none).status);
        try std.testing.expectEqual(world.OperationStatus.success, fixture.world.setBlock(target, .none).status);
        fixture.set(.{ 0, 0, -1 }, .none);
    }
}

test "custom cells keep neighboring ordinary faces and produce separate draw records" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -1, 0, 0 }, .stone);
    fixture.set(.{ 0, 0, 0 }, .country_road_adaptive);
    const coords, const local = world.splitBlockCoords(storage(&fixture, .{ 0, 0, 0 }));
    const chunk = fixture.world.getChunk(coords).?;
    const side = engine.voxel_chunk.Side;
    try std.testing.expect(!chunk.boundaries[@intFromEnum(side.left)].contains(.left, local));
    var mesh = @import("world_engine_glue.zig").extractChunkGeometry(std.testing.allocator, chunk, @splat(.{}));
    defer mesh.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mesh.custom_blocks.items.len);
    for (mesh.blocks_grouped_by_side) |faces| try std.testing.expectEqual(@as(usize, 0), faces.items.len);
    // The ordinary block is in the adjacent chunk and must expose its right face.
    const other_coords, _ = world.splitBlockCoords(storage(&fixture, .{ -1, 0, 0 }));
    var neighbors: @import("boundary_mask.zig").BoundaryMasks = @splat(.{});
    neighbors[@intFromEnum(side.right)] = chunk.boundaries[@intFromEnum(side.left)];
    var ordinary = @import("world_engine_glue.zig").extractChunkGeometry(std.testing.allocator, fixture.world.getChunk(other_coords).?, neighbors);
    defer ordinary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ordinary.blocks_grouped_by_side[@intFromEnum(side.right)].items.len);
}

test "grounded walking follows road surfaces uphill and downhill without climbing" {
    for (std.enums.values(custom.Direction)) |direction| {
        for ([_]u32{ 4, 12 }) |n| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            row(&fixture, .{ 0, 0, 0 }, direction, n);
            const delta = direction.offset();
            for (n + 2..n + 5) |i| {
                const at = delta * @as(Cell, @splat(@intCast(i))) - Cell{ 0, 0, 1 };
                fixture.set(at - Cell{ 0, 0, 1 }, .stone);
                fixture.set(at, .country_road_solid);
            }
            var player = player_module.PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 1 });
            defer player.deinit();
            var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
            const frames = (n + 2) * 24;
            var time: f64 = 0;
            for (0..2) |trip| {
                const sign: f64 = if (trip == 0) 1 else -1;
                const input: player_module.Input = .{ .right = @as(f64, @floatFromInt(delta[0])) * sign, .forward = @as(f64, @floatFromInt(delta[1])) * sign };
                for (0..frames) |_| {
                    const old_z = player.position[2];
                    time += 1.0 / 120.0;
                    _ = try player.update(&fixture.world, input, 1.0 / 120.0, time);
                    try std.testing.expect(player.grounded);
                    try std.testing.expect(player.climb == null);
                    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, true));
                    try std.testing.expect(@abs(player.position[2] - old_z) <= 5.0 / 120.0 / 4.0 + 1e-6);
                }
                try std.testing.expectApproxEqAbs(if (trip == 0) @as(f64, 0) else 1, player.position[2], 1e-8);
            }
        }
    }
}

test "slope collision clips fast falls, leaves empty cell space clear and targeting hits the surface" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    row(&fixture, .{ 0, 0, 0 }, .positive_x, 4);
    var query: collision.Query = .{ .world = &fixture.world, .body = .{} };
    const landing = query.moveAxis(.{ 2.5, 0.5, 20 }, 2, -25);
    try std.testing.expect(landing.collided);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), landing.position[2], 1e-8);
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(landing.position, true));
    const hit = (try @import("block_targeting.zig").cast(&fixture.world, .{ 2.5, 0.5, 2 }, .{ 0, 0, -1 })).?;
    try std.testing.expectEqual(storage(&fixture, .{ 2, 0, 0 }), hit.block);
    try std.testing.expectApproxEqAbs(@as(f64, 1.375), hit.distance, 1e-8);
    try std.testing.expectEqual(storage(&fixture, .{ 2, 0, 1 }), hit.placement.?);
    // Above the downhill sections, the ray continues to an ordinary cube beyond them.
    fixture.set(.{ 6, 0, 0 }, .stone);
    const through = (try @import("block_targeting.zig").cast(&fixture.world, .{ 3.5, 0.5, 0.9 }, .{ 1, 0, 0 })).?;
    try std.testing.expectEqual(storage(&fixture, .{ 6, 0, 0 }), through.block);
}

test "road ownership survives wrapped seam snapshots and pending removal replay" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    row(&fixture, .{ 62, 0, 0 }, .positive_x, 12);
    try std.testing.expect(shape(&fixture, .{ 66, 0, 0 }).? == .slope);
    for (fixture.world.pending_operations.items) |*pending| pending.road_undo.deinit(std.testing.allocator);
    fixture.world.pending_operations.clearRetainingCapacity();
    const coords, _ = world.splitBlockCoords(storage(&fixture, .{ 66, 0, 0 }));
    const snapshot = fixture.world.getChunk(coords).?.clone(std.testing.allocator);
    fixture.set(.{ 66, 0, 0 }, .none);
    try fixture.world.insertChunk(coords, snapshot);
    for (1..13) |i| if (i != 4) try std.testing.expect(shape(&fixture, .{ 62 + @as(i64, @intCast(i)), 0, 0 }).? == .adaptive);
    try std.testing.expect(!try fixture.world.isBlockSolid(storage(&fixture, .{ 66, 0, 0 })));
}

test "a rejected optimistic endpoint restores metadata in other chunks" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const high: Cell = .{ -4, 0, 0 };
    const n: u32 = 12;
    // Build an incomplete row and save the authoritative low-endpoint chunk.
    row(&fixture, high, .positive_x, n);
    fixture.set(high + Cell{ n + 1, 0, -1 }, .none);
    for (fixture.world.pending_operations.items) |*pending| pending.road_undo.deinit(std.testing.allocator);
    fixture.world.pending_operations.clearRetainingCapacity();
    const low = storage(&fixture, high + Cell{ n + 1, 0, -1 });
    const low_coords, _ = world.splitBlockCoords(low);
    const snapshot = fixture.world.getChunk(low_coords).?.clone(std.testing.allocator);
    try std.testing.expectEqual(world.OperationStatus.success, fixture.world.setBlock(low, .country_road_solid).status);
    fixture.world.pending_operations.items[0].request_id = 42;
    try std.testing.expect(shape(&fixture, high + Cell{ 1, 0, 0 }).? == .slope);
    fixture.world.acknowledgeOperationResult(42, .constraint_violation);
    try fixture.world.insertChunk(low_coords, snapshot);
    for (1..n + 1) |i| try std.testing.expect(shape(&fixture, high + Cell{ @intCast(i), 0, 0 }).? == .adaptive);
}

test "unformed adaptive roads collide as cubes and missing support is unknown" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, -1 }, .stone);
    fixture.set(.{ 0, 0, 0 }, .country_road_adaptive);
    var query: collision.Query = .{ .world = &fixture.world, .body = .{} };
    try std.testing.expectEqual(collision.Overlap.solid, query.overlap(.{ 0.5, 0.5, 0.9 }, true));
    try std.testing.expectApproxEqAbs(@as(f64, 1), query.moveAxis(.{ 0.5, 0.5, 4 }, 2, -5).position[2], 1e-10);
    const support_coords, _ = world.splitBlockCoords(storage(&fixture, .{ 2, 0, -1 }));
    fixture.world.removeChunk(support_coords);
    try std.testing.expectEqual(world.OperationStatus.missing_data, fixture.world.setBlock(storage(&fixture, .{ 2, 0, 0 }), .country_road_adaptive).status);
}

test "diagonal walking across parallel road lanes and jumping retains proper contact" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    for (0..6) |lane| row(&fixture, .{ 0, @intCast(lane), 0 }, .positive_x, 12);
    var player = player_module.PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 1 });
    defer player.deinit();
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    for (0..140) |i| {
        _ = try player.update(&fixture.world, .{ .right = 1, .forward = 1 }, 1.0 / 120.0, @as(f64, @floatFromInt(i + 1)) / 120.0);
        try std.testing.expect(player.grounded and player.climb == null);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, true));
    }
    const ground = player.position[2];
    _ = try player.update(&fixture.world, .{ .jump_pressed = true }, 1.0 / 120.0, 2);
    try std.testing.expect(!player.grounded and player.position[2] > ground);
    for (0..150) |i| _ = try player.update(&fixture.world, .{}, 1.0 / 120.0, 2 + @as(f64, @floatFromInt(i + 1)) / 120.0);
    try std.testing.expect(player.grounded and player.climb == null);
    try std.testing.expectApproxEqAbs(ground, player.position[2], 1e-8);
}

test "standing-space uses the real slope surface and slope walking respects ceilings" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    row(&fixture, .{ 0, 0, 0 }, .positive_x, 4);
    const standing = try @import("standing_space.zig").find(fixture.world.reader(), .{ .preferred_xy = .{ 2.5, 0.5 }, .clearance_size = .{ 0.6, 0.6, 1.8 }, .support_size = .{ 0.6, 0.6 } });
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), standing[2], 1e-8);
    fixture.set(.{ 2, 0, 2 }, .stone);
    var player = player_module.PlayerController.init(std.testing.allocator, .{ 3.5, 0.5, 0.45 });
    defer player.deinit();
    for (0..100) |i| _ = try player.update(&fixture.world, .{ .right = -1 }, 1.0 / 120.0, @as(f64, @floatFromInt(i + 1)) / 120.0);
    try std.testing.expect(player.position[0] >= 3.3 - 1e-8);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, true));
}
