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

fn clearPending(fixture: *Fixture) void {
    for (fixture.world.pending_operations.items) |*pending| {
        pending.road_undo.deinit(std.testing.allocator);
        pending.road_formations.deinit(std.testing.allocator);
    }
    fixture.world.pending_operations.clearRetainingCapacity();
}

fn sectionSnapshots(client: *Fixture, authority: *Fixture, high: Cell, n: u32) !void {
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(std.testing.allocator);
    for (1..n + 1) |i| {
        const coords, _ = world.splitBlockCoords(storage(authority, high + Cell{ @intCast(i), 0, 0 }));
        const id = authority.world.layout.encodeChunkCoords(coords);
        if (std.mem.indexOfScalar(u32, ids.items, id) != null) continue;
        try ids.append(std.testing.allocator, id);
        var snapshot = authority.world.getChunk(coords).?.clone(std.testing.allocator);
        snapshot.chunk_revision = 1;
        try client.world.insertChunk(coords, snapshot);
    }
}

test "ordered replay keeps formation undo with the endpoint command after an earlier snow response" {
    var client = try Fixture.init();
    defer client.deinit();
    var authority = try Fixture.init();
    defer authority.deinit();
    const high: Cell = .{ -4, 0, 0 };
    const low: Cell = .{ 9, 0, -1 };
    const p: Cell = .{ -3, 1, 0 };
    const a: Cell = .{ 8, 1, -1 };
    for ([_]*Fixture{ &client, &authority }) |fixture| {
        row(fixture, high, .positive_x, 12);
        fixture.set(low, .none);
        fixture.set(p - Cell{ 0, 0, 1 }, .stone);
        fixture.set(a - Cell{ 0, 0, 1 }, .stone);
        clearPending(fixture);
    }
    try std.testing.expectEqual(world.OperationStatus.success, client.world.setBlock(storage(&client, p), .snow).status);
    client.world.pending_operations.items[0].request_id = 1;
    authority.set(p, .snow);
    const p_coords, _ = world.splitBlockCoords(storage(&authority, p));
    var p_snapshot = authority.world.getChunk(p_coords).?.clone(std.testing.allocator);
    p_snapshot.chunk_revision = 1;
    try std.testing.expectEqual(world.OperationStatus.success, client.world.setBlock(storage(&client, a), .snow).status);
    client.world.pending_operations.items[1].request_id = 2;
    try std.testing.expectEqual(@as(usize, 0), client.world.pending_operations.items[1].road_undo.items.len);
    try std.testing.expectEqual(world.OperationStatus.success, client.world.setBlock(storage(&client, low), .country_road_solid).status);
    client.world.pending_operations.items[2].request_id = 3;
    client.world.acknowledgeOperation(1);
    try client.world.insertChunk(p_coords, p_snapshot);
    try std.testing.expectEqual(@as(usize, 0), client.world.pending_operations.items[0].road_undo.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.world.pending_operations.items[0].road_formations.items.len);
    try std.testing.expectEqual(@as(usize, 12), client.world.pending_operations.items[1].road_undo.items.len);
    try std.testing.expectEqual(@as(usize, 1), client.world.pending_operations.items[1].road_formations.items.len);

    // Both results retire before snapshots, as in Game.applyPackage(). Only B
    // formed the road, so accepting A must never discard B's undo records.
    authority.set(a, .snow);
    authority.set(low, .snow); // Another client won the endpoint cell.
    client.world.acknowledgeOperation(2);
    client.world.acknowledgeOperationResult(3, .already_exists);
    const low_coords, const low_local = world.splitBlockCoords(storage(&authority, low));
    var snapshot = authority.world.getChunk(low_coords).?.clone(std.testing.allocator);
    snapshot.chunk_revision = 2;
    try client.world.insertChunk(low_coords, snapshot);
    try std.testing.expectEqual(@as(usize, 0), client.world.pending_operations.items.len);
    try std.testing.expectEqual(engine.voxel_chunk.BlockType.snow, client.world.getChunk(low_coords).?.content.getBlock(low_local));
    for (1..13) |i| try std.testing.expect(shape(&client, high + Cell{ @intCast(i), 0, 0 }).? == .adaptive);
}

test "accepted formation stays in the baseline when a later member removal is rejected" {
    var client = try Fixture.init();
    defer client.deinit();
    const high: Cell = .{ -4, 0, 0 };
    row(&client, high, .positive_x, 12);
    const low = high + Cell{ 13, 0, -1 };
    client.set(low, .none);
    clearPending(&client);
    client.set(low, .country_road_solid);
    client.world.pending_operations.items[0].request_id = 1;
    client.set(high + Cell{ 6, 0, 0 }, .none);
    client.world.pending_operations.items[1].request_id = 2;
    client.world.acknowledgeOperation(1);
    client.world.acknowledgeOperationResult(2, .constraint_violation);
    try std.testing.expectEqual(@as(usize, 0), client.world.pending_operations.items.len);
    for (1..13) |i| try std.testing.expect(shape(&client, high + Cell{ @intCast(i), 0, 0 }).? == .slope);
}

test "ordered replay revokes saved crossing ownership before replacing its removed member" {
    var client = try Fixture.init();
    defer client.deinit();
    const high: Cell = .{ 0, 0, 0 };
    const low: Cell = .{ 5, 0, -1 };
    const center: Cell = .{ 2, 0, 0 };
    row(&client, high, .positive_x, 4);
    client.set(low, .none);
    clearPending(&client);
    const coords, _ = world.splitBlockCoords(storage(&client, center));
    const snapshot = client.world.getChunk(coords).?.clone(std.testing.allocator);
    client.set(low, .country_road_solid); // A owns the x run.
    client.set(center, .none); // B revokes A's ownership.
    for (0..5) |i| {
        const at: Cell = .{ 2, @as(i64, @intCast(i)) - 2, 0 };
        if (i == 2) continue;
        client.set(at - Cell{ 0, 0, 1 }, .stone);
        client.set(at, if (i == 0) .country_road_solid else .country_road_adaptive);
    }
    client.set(.{ 2, 3, -2 }, .stone);
    client.set(.{ 2, 3, -1 }, .country_road_solid);
    client.set(center, .country_road_adaptive); // C completes an ambiguous crossing.
    try std.testing.expect(shape(&client, center).? == .adaptive);
    try client.world.insertChunk(coords, snapshot);
    for (1..5) |i| try std.testing.expect(shape(&client, high + Cell{ @intCast(i), 0, 0 }).? == .adaptive);
    try std.testing.expect(shape(&client, .{ 2, 1, 0 }).? == .adaptive);
}

test "duplicate road placement rejection preserves newer authoritative slopes" {
    var client = try Fixture.init();
    defer client.deinit();
    var authority = try Fixture.init();
    defer authority.deinit();
    const high: Cell = .{ -4, 0, 0 };
    const low: Cell = high + Cell{ 13, 0, -1 };
    row(&client, high, .positive_x, 12);
    client.set(low, .none);
    clearPending(&client);
    row(&authority, high, .positive_x, 12);
    clearPending(&authority);

    client.set(low, .country_road_solid);
    client.world.pending_operations.items[0].request_id = 42;
    try sectionSnapshots(&client, &authority, high, 12);
    client.world.acknowledgeOperationResult(42, .already_exists);
    const coords, _ = world.splitBlockCoords(storage(&authority, low));
    var snapshot = authority.world.getChunk(coords).?.clone(std.testing.allocator);
    snapshot.chunk_revision = 1;
    try client.world.insertChunk(coords, snapshot);
    try std.testing.expectEqual(@as(usize, 0), client.world.pending_operations.items.len);
    for (1..13) |i| try std.testing.expect(shape(&client, high + Cell{ @intCast(i), 0, 0 }).? == .slope);
}

test "duplicate road removal rejection preserves newer authoritative reversion" {
    var client = try Fixture.init();
    defer client.deinit();
    var authority = try Fixture.init();
    defer authority.deinit();
    const high: Cell = .{ -4, 0, 0 };
    const low: Cell = high + Cell{ 13, 0, -1 };
    row(&client, high, .positive_x, 12);
    clearPending(&client);
    row(&authority, high, .positive_x, 12);
    authority.set(low, .none);
    clearPending(&authority);

    client.set(low, .none);
    client.world.pending_operations.items[0].request_id = 42;
    try sectionSnapshots(&client, &authority, high, 12);
    client.world.acknowledgeOperationResult(42, .already_removed);
    const coords, _ = world.splitBlockCoords(storage(&authority, low));
    var snapshot = authority.world.getChunk(coords).?.clone(std.testing.allocator);
    snapshot.chunk_revision = 1;
    try client.world.insertChunk(coords, snapshot);
    try std.testing.expectEqual(@as(usize, 0), client.world.pending_operations.items.len);
    try std.testing.expect(!try client.world.isBlockSolid(storage(&client, low)));
    for (1..13) |i| try std.testing.expect(shape(&client, high + Cell{ @intCast(i), 0, 0 }).? == .adaptive);
}

test "older section snapshots replay pending formation coherently across chunks and the seam" {
    for ([_]i64{ -4, 62 }) |x| {
        var client = try Fixture.init();
        defer client.deinit();
        var authority = try Fixture.init();
        defer authority.deinit();
        const high: Cell = .{ x, 0, 0 };
        const low = high + Cell{ 13, 0, -1 };
        row(&client, high, .positive_x, 12);
        client.set(low, .none);
        clearPending(&client);
        row(&authority, high, .positive_x, 12);
        authority.set(low, .none);
        clearPending(&authority);
        client.set(low, .country_road_solid);

        for ([_]i64{ 1, 12, 1 }) |section| {
            const coords, _ = world.splitBlockCoords(storage(&authority, high + Cell{ section, 0, 0 }));
            try client.world.insertChunk(coords, authority.world.getChunk(coords).?.clone(std.testing.allocator));
            try std.testing.expectEqual(@as(usize, 1), client.world.pending_operations.items.len);
            for (1..13) |i| try std.testing.expect(shape(&client, high + Cell{ @intCast(i), 0, 0 }).? == .slope);
        }
    }
}

test "rebasing a rejected endpoint preserves later pending road removal and its undo" {
    var client = try Fixture.init();
    defer client.deinit();
    var authority = try Fixture.init();
    defer authority.deinit();
    const high: Cell = .{ -4, 0, 0 };
    const low = high + Cell{ 13, 0, -1 };
    row(&client, high, .positive_x, 12);
    client.set(low, .none);
    clearPending(&client);
    row(&authority, high, .positive_x, 12);
    clearPending(&authority);
    client.set(low, .country_road_solid);
    client.world.pending_operations.items[0].request_id = 41;
    client.set(high, .none);
    client.world.pending_operations.items[1].request_id = 42;
    try sectionSnapshots(&client, &authority, high, 12);
    client.world.acknowledgeOperationResult(41, .already_exists);
    try std.testing.expectEqual(@as(usize, 1), client.world.pending_operations.items.len);
    for (1..13) |i| try std.testing.expect(shape(&client, high + Cell{ @intCast(i), 0, 0 }).? == .adaptive);
    client.world.acknowledgeOperationResult(42, .constraint_violation);
    const coords, _ = world.splitBlockCoords(storage(&authority, high));
    var snapshot = authority.world.getChunk(coords).?.clone(std.testing.allocator);
    snapshot.chunk_revision = 1;
    try client.world.insertChunk(coords, snapshot);
    try std.testing.expectEqual(@as(usize, 0), client.world.pending_operations.items.len);
    for (1..13) |i| try std.testing.expect(shape(&client, high + Cell{ @intCast(i), 0, 0 }).? == .slope);
}

test "a pending slope keeps its chosen orientation when a later crossing is rebased" {
    var client = try Fixture.init();
    defer client.deinit();
    row(&client, .{ 0, 0, 0 }, .positive_x, 4);
    client.set(.{ 5, 0, -1 }, .none);
    clearPending(&client);
    client.set(.{ 5, 0, -1 }, .country_road_solid);
    for (0..5) |i| {
        const at: Cell = .{ 2, @as(i64, @intCast(i)) - 2, 0 };
        client.set(at - Cell{ 0, 0, 1 }, .stone);
        if (i == 0) client.set(at, .country_road_solid) else if (i != 2) client.set(at, .country_road_adaptive);
    }
    client.set(.{ 2, 3, -2 }, .stone);
    client.set(.{ 2, 3, -1 }, .country_road_solid);
    try client.world.insertChunk(.{ 0, 0, 0 }, world.WorldChunk.initEmpty());
    const center = shape(&client, .{ 2, 0, 0 }).?;
    try std.testing.expect(center == .slope);
    try std.testing.expectEqual(custom.Direction.positive_x, center.slope.downhill);
    try std.testing.expect(shape(&client, .{ 2, 1, 0 }).? == .adaptive);
}

test "rebasing a pending formation honors a newer authoritative crossing owner" {
    var client = try Fixture.init();
    defer client.deinit();
    var authority = try Fixture.init();
    defer authority.deinit();
    row(&client, .{ 0, 0, 0 }, .positive_x, 4);
    client.set(.{ 5, 0, -1 }, .none);
    clearPending(&client);
    client.set(.{ 5, 0, -1 }, .country_road_solid);
    client.world.pending_operations.items[0].request_id = 42;
    // The other client completed the perpendicular road first, then the same
    // endpoint placement. Its chosen crossing owner must win on this client.
    row(&authority, .{ 2, -2, 0 }, .positive_y, 4);
    row(&authority, .{ 0, 0, 0 }, .positive_x, 4);
    clearPending(&authority);
    try sectionSnapshots(&client, &authority, .{ 0, 0, 0 }, 4);
    client.world.acknowledgeOperationResult(42, .already_exists);
    const center = shape(&client, .{ 2, 0, 0 }).?;
    try std.testing.expect(center == .slope);
    try std.testing.expectEqual(custom.Direction.positive_y, center.slope.downhill);
    for ([_]i64{ 1, 3, 4 }) |x| try std.testing.expect(shape(&client, .{ x, 0, 0 }).? == .adaptive);
}

test "uphill walking keeps a clipped lift when leaving a clear ceiling" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    row(&fixture, .{ 0, 0, 0 }, .positive_x, 8);
    fixture.set(.{ 8, 0, 2 }, .stone);
    var player = player_module.PlayerController.init(std.testing.allocator, .{ 9.5, 0.5, 0 });
    defer player.deinit();
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    // The trailing edge leaves the ceiling exactly when the head reaches its floor.
    for (0..501) |i| {
        const x = 9.5 - @as(f64, @floatFromInt(i)) / 100;
        const z = std.math.clamp((9 - (x - player.body.half_width)) / 8, 0, 1);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(.{ x, 0.5, z }, true));
    }
    for (0..120) |i| {
        _ = try player.update(&fixture.world, .{ .right = -1 }, 1.0 / 120.0, @as(f64, @floatFromInt(i + 1)) / 120.0);
        try std.testing.expect(player.grounded and player.climb == null);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, true));
    }
    try std.testing.expect(player.position[0] < 5);
    try std.testing.expect(player.position[2] > 0.5);
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

test "adaptive road formation rejects cube-colliding sand and foliage foundations" {
    for ([_]engine.voxel_chunk.BlockType{ .sand, .leaves }) |support| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const high: Cell = .{ 0, 0, 0 };
        const low: Cell = .{ 5, 0, -1 };
        row(&fixture, high, .positive_x, 4);
        fixture.set(low, .none);
        fixture.set(.{ 2, 0, -1 }, .none);
        fixture.set(.{ 2, 0, -1 }, support);
        fixture.set(low, .country_road_solid);
        for (1..5) |section|
            try std.testing.expect(shape(&fixture, .{ @intCast(section), 0, 0 }).? == .adaptive);
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
    clearPending(&fixture);
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
    clearPending(&fixture);
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
    // The lowered visual surface does not change full-cube player collision.
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(.{ 0.5, 0.5, 1.01 }, true));
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
