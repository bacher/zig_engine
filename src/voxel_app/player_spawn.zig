//! Spawn on the current block surface, independent of how the world was generated.
const std = @import("std");
const engine = @import("engine");
const collision = @import("terrain_collision.zig");
const coordinates = @import("block_coordinates.zig");
const World = @import("world.zig").World;
const service_module = @import("world_data_service.zig");
const Position = collision.Position;
const Cell = collision.Cell;

pub const SpawnError = error{ InvalidSpawnPosition, MissingChunk, NoSpawnSurface, NoSpawnSpace };

const Footprint = struct { first: Cell, last: Cell };

fn footprint(layout: *const engine.WorldLayout, body: collision.Body, xy: [2]f64) SpawnError!Footprint {
    if (!std.math.isFinite(xy[0]) or !std.math.isFinite(xy[1]) or
        !std.math.isFinite(body.half_width) or body.half_width <= collision.epsilon or
        !std.math.isFinite(body.height) or body.height <= collision.epsilon) return error.InvalidSpawnPosition;
    const bounds = body.bounds(.{ xy[0], xy[1], 0 });
    // Keep conversions and origin translation within the signed cell range.
    inline for (0..2) |axis| {
        if (bounds.min[axis] < -0x1p62 or bounds.max[axis] >= 0x1p62) return error.InvalidSpawnPosition;
    }
    const first: Cell = @intFromFloat(@floor(bounds.min + @as(Position, @splat(collision.epsilon))));
    const last: Cell = @intFromFloat(@ceil(bounds.max - @as(Position, @splat(collision.epsilon))) - @as(Position, @splat(1)));
    const origin_y: i64 = @as(i64, layout.origin_chunk[1]) * engine.chunk_utils.CHUNK_SIZE;
    if (first[1] < -origin_y or last[1] >= @as(i64, layout.size_in_blocks[1]) - origin_y) return error.InvalidSpawnPosition;
    return .{ .first = first, .last = last };
}

/// Highest collidable block under any part of the body is the support surface.
/// Every cell above it must be known; missing chunks are never treated as air.
/// Finite world boundaries are not a substitute for an actual supporting block.
pub fn findPosition(world: *const World, body: collision.Body, xy: [2]f64) SpawnError!Position {
    const area = try footprint(world.layout, body, xy);
    const origin_z: i64 = @as(i64, world.layout.origin_chunk[2]) * engine.chunk_utils.CHUNK_SIZE;
    var z: i64 = @as(i64, world.layout.size_in_blocks[2]) - origin_z;
    while (z > -origin_z) {
        z -= 1;
        var supported = false;
        var y = area.first[1];
        while (y <= area.last[1]) : (y += 1) {
            var x = area.first[0];
            while (x <= area.last[0]) : (x += 1) {
                const block = coordinates.fromWorld(world.layout, .{ x, y, z }).?;
                const chunk_coords, const local = @import("world.zig").splitBlockCoords(block);
                const chunk = world.getChunk(chunk_coords) orelse return error.MissingChunk;
                supported = supported or collision.movementCollision(chunk.content.getBlock(local)) == .full_cube;
            }
        }
        if (!supported) continue;
        const feet = Position{ xy[0], xy[1], @floatFromInt(z + 1) };
        var query: collision.Query = .{ .world = world, .body = body };
        switch (query.overlap(feet, false)) {
            .clear => return feet,
            .missing => return error.MissingChunk,
            .solid => return error.NoSpawnSpace,
        }
    }
    return error.NoSpawnSurface;
}

/// Bootstrap through ordinary authoritative block subscriptions. Only columns
/// touched by the body's footprint are loaded, including across chunk/x seams.
/// Temporary subscriptions and blocks are released on success, error or cancellation.
pub fn loadPosition(service: *service_module.WorldDataService, body: collision.Body, xy: [2]f64) !Position {
    const area = try footprint(service.layout, body, xy);
    var world = try World.init(service.allocator, service.layout);
    defer world.deinit();
    const client = try service.createClient();
    var columns: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer columns.deinit(service.allocator);
    defer {
        var iterator = columns.iterator();
        while (iterator.next()) |entry| {
            var coords = service.layout.decodeChunkId(entry.key_ptr.*);
            while (coords[2] < service.layout.size_in_chunks[2]) : (coords[2] += 1)
                client.evictChunk(service.layout.encodeChunkCoords(coords), entry.value_ptr.*);
        }
    }
    var y = @divFloor(area.first[1], engine.chunk_utils.CHUNK_SIZE);
    while (y <= @divFloor(area.last[1], engine.chunk_utils.CHUNK_SIZE)) : (y += 1) {
        var x = @divFloor(area.first[0], engine.chunk_utils.CHUNK_SIZE);
        while (x <= @divFloor(area.last[0], engine.chunk_utils.CHUNK_SIZE)) : (x += 1) {
            const coords = engine.ChunkCoords{
                @intCast(@mod(x + service.layout.origin_chunk[0], service.layout.size_in_chunks[0])),
                @intCast(y + service.layout.origin_chunk[1]),
                0,
            };
            const id = service.layout.encodeChunkCoords(coords);
            const entry = try columns.getOrPut(service.allocator, id);
            if (entry.found_existing) continue;
            entry.value_ptr.* = client.requestChunks(.{ coords[0], coords[1] }, 0, service.layout.size_in_chunks[2]);
        }
    }
    var responses: std.ArrayList(service_module.ChunkResponse) = .empty;
    defer {
        for (responses.items) |response| response.deinit(service.allocator);
        responses.deinit(service.allocator);
    }
    const expected = @as(usize, columns.count()) * @as(usize, @intCast(service.layout.size_in_chunks[2]));
    while (world.chunks.count() < expected) {
        if (!try client.waitResponses(&responses)) return error.MissingChunk;
        for (responses.items) |*response| {
            if (response.data != .blocks) continue;
            world.insertChunk(response.coords, response.data.blocks.chunk) catch {
                response.deinit(service.allocator);
            };
            // The cache takes ownership; leave only a non-owning response for cleanup.
            response.data = .acknowledgement;
        }
        for (responses.items) |response| response.deinit(service.allocator);
        responses.clearRetainingCapacity();
    }
    return findPosition(&world, body, xy);
}

test "spawn follows added and removed blocks and starts standing without a fall" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    const xy = [2]f64{ 0.5, 0.5 };
    try std.testing.expectEqual(Position{ 0.5, 0.5, 0 }, try findPosition(&fixture.world, .{}, xy));
    fixture.set(.{ 0, 0, 12 }, .planks);
    const spawn = try findPosition(&fixture.world, .{}, xy);
    try std.testing.expectEqual(Position{ 0.5, 0.5, 13 }, spawn);
    var player = @import("player_controller.zig").PlayerController.init(std.testing.allocator, spawn);
    defer player.deinit();
    _ = try player.update(&fixture.world, .{}, 1, 1);
    try std.testing.expectEqual(spawn, player.position);
    try std.testing.expect(player.grounded);
    try std.testing.expectEqual(@as(f64, 0), player.vertical_velocity);
    fixture.set(.{ 0, 0, 12 }, .none);
    fixture.set(.{ 0, 0, -1 }, .none);
    fixture.set(.{ 0, 0, -8 }, .stone);
    try std.testing.expectEqual(Position{ 0.5, 0.5, -7 }, try findPosition(&fixture.world, .{}, xy));
}

test "spawn checks the whole footprint across horizontal and vertical chunk boundaries" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 31, 31, 3 }, .stone);
    // The centre cell is lower; the corner touched by the body is the support.
    fixture.set(.{ 32, 32, 31 }, .reinforced_concrete);
    const spawn = try findPosition(&fixture.world, .{}, .{ 31.95, 31.95 });
    try std.testing.expectEqual(Position{ 31.95, 31.95, 32 }, spawn);
    var query: collision.Query = .{ .world = &fixture.world, .body = .{} };
    try std.testing.expectEqual(.clear, query.overlap(spawn, true));
    try std.testing.expect(query.moveAxis(spawn, 2, -collision.ground_probe).collided);
}

test "spawn handles the wrapped x seam and preserves the requested world coordinates" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -65, 0, 8 }, .stone);
    fixture.set(.{ -64, 0, -1 }, .stone);
    try std.testing.expectEqual(Position{ -63.95, 0.5, 9 }, try findPosition(&fixture.world, .{}, .{ -63.95, 0.5 }));
    try std.testing.expectEqual(Position{ 64.05, 0.5, 9 }, try findPosition(&fixture.world, .{}, .{ 64.05, 0.5 }));
}

test "spawn requires known terrain, a real surface and room within the world" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    try std.testing.expectError(error.NoSpawnSurface, findPosition(&fixture.world, .{}, .{ 0.5, 0.5 }));
    fixture.set(.{ 0, 0, 63 }, .stone);
    try std.testing.expectError(error.NoSpawnSpace, findPosition(&fixture.world, .{}, .{ 0.5, 0.5 }));
    fixture.set(.{ 0, 0, 63 }, .none);
    fixture.set(.{ 0, 0, -1 }, .stone);
    fixture.world.removeChunk(.{ 2, 2, 3 });
    try std.testing.expectError(error.MissingChunk, findPosition(&fixture.world, .{}, .{ 0.5, 0.5 }));
    try std.testing.expectError(error.InvalidSpawnPosition, findPosition(&fixture.world, .{}, .{ 0.5, 63.95 }));
    try std.testing.expectError(error.InvalidSpawnPosition, findPosition(&fixture.world, .{}, .{ std.math.nan(f64), 0.5 }));
}

fn editAndWait(client: *service_module.Client, operation: @import("world.zig").BlockOperation) !void {
    const id = client.submitOperation(operation);
    var responses: std.ArrayList(service_module.ChunkResponse) = .empty;
    defer {
        for (responses.items) |response| response.deinit(client.service.allocator);
        responses.deinit(client.service.allocator);
    }
    try std.testing.expect(try client.waitResponses(&responses));
    var acknowledged = false;
    for (responses.items) |response| if (response.operation) |result| {
        if (result.request_id != id) continue;
        try std.testing.expectEqual(.success, result.status);
        acknowledged = true;
    };
    try std.testing.expect(acknowledged);
}

test "new spawn subscriptions see committed edits after the editing client evicts terrain" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try service_module.WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    const editor = try service.createClient();
    const token = editor.requestChunks(.{ 0, 0 }, 0, 1);
    var responses: std.ArrayList(service_module.ChunkResponse) = .empty;
    try std.testing.expect(try editor.waitResponses(&responses));
    for (responses.items) |response| response.deinit(service.allocator);
    responses.deinit(service.allocator);
    editor.evictChunk(layout.encodeChunkId(0, 0, 0), token);

    const xy = [2]f64{ -21.5, -21.5 };
    try std.testing.expectEqual(Position{ xy[0], xy[1], -16 }, try loadPosition(service, .{}, xy));
    try editAndWait(editor, .{ .block = .{ 10, 10, 16 }, .action = .{ .put = .dirt } });
    try std.testing.expectEqual(Position{ xy[0], xy[1], -15 }, try loadPosition(service, .{}, xy));
    try editAndWait(editor, .{ .block = .{ 10, 10, 16 }, .action = .remove });
    try editAndWait(editor, .{ .block = .{ 10, 10, 15 }, .action = .remove });
    try std.testing.expectEqual(Position{ xy[0], xy[1], -17 }, try loadPosition(service, .{}, xy));
}

test "spawn bootstrap loads all touched columns across chunk boundaries and the x seam" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try service_module.WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    for ([_][2]f64{ .{ -0.05, -0.05 }, .{ -31.95, -0.05 }, .{ 32.05, -0.05 } }) |xy|
        try std.testing.expectEqual(Position{ xy[0], xy[1], -16 }, try loadPosition(service, .{}, xy));
}

test "spawn scans terrain higher than the old fixed starting height" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 8 } });
    const service = try service_module.WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .{
        .terrain = .{ .seed = 12345, .params = .{ .base_height = 220, .height_amplitude = 0 } },
    });
    defer service.destroy();
    try std.testing.expectEqual(Position{ -2.06, -2.96, 92 }, try loadPosition(service, .{}, .{ -2.06, -2.96 }));
}
