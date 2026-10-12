//! Spawn on the current block surface, independent of how the world was generated.
const std = @import("std");
const engine = @import("engine");
const collision = @import("terrain_collision.zig");
const coordinates = @import("block_coordinates.zig");
const World = @import("world.zig").World;
const service_module = @import("world_data_service.zig");
const Position = collision.Position;

pub const SpawnError = error{ InvalidSpawnPosition, MissingChunk, NoSpawnSurface, NoSpawnSpace };

fn footprint(layout: *const engine.WorldLayout, body: collision.Body, xy: [2]f64) SpawnError!collision.HorizontalCells {
    if (!std.math.isFinite(xy[0]) or !std.math.isFinite(xy[1]) or
        !std.math.isFinite(body.half_width) or body.half_width <= collision.epsilon or
        !std.math.isFinite(body.height) or body.height <= collision.epsilon) return error.InvalidSpawnPosition;
    const bounds = body.bounds(.{ xy[0], xy[1], 0 });
    // Keep conversions and origin translation within the signed cell range.
    inline for (0..2) |axis| {
        if (bounds.min[axis] < -0x1p62 or bounds.max[axis] >= 0x1p62) return error.InvalidSpawnPosition;
    }
    const area = bounds.horizontalCells();
    const origin_y: i64 = @as(i64, layout.origin_chunk[1]) * engine.chunk_utils.CHUNK_SIZE;
    if (area.first[1] < -origin_y or area.last[1] >= @as(i64, layout.size_in_blocks[1]) - origin_y) return error.InvalidSpawnPosition;
    return area;
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
/// The caller supplies an idle client with no unrelated subscriptions or replies.
/// Its endpoint remains service-owned until service destruction and can be reused.
/// On every exit, local blocks are freed and subscription evictions are queued.
/// Replies arriving after cancellation remain queued until the next consumer or
/// service destruction; subsequent spawns discard obsolete subscription tokens.
pub fn loadPosition(client: *service_module.Client, body: collision.Body, xy: [2]f64) !Position {
    var bootstrap = try Bootstrap.start(client, body, xy);
    return bootstrap.finish();
}

const Bootstrap = struct {
    client: *service_module.Client,
    world: World,
    body: collision.Body,
    xy: [2]f64,
    columns: std.AutoHashMapUnmanaged(u32, u64) = .empty,

    fn deinit(self: *Bootstrap) void {
        const service = self.client.service;
        var iterator = self.columns.iterator();
        while (iterator.next()) |entry| {
            var coords = service.layout.decodeChunkId(entry.key_ptr.*);
            while (coords[2] < service.layout.size_in_chunks[2]) : (coords[2] += 1)
                self.client.evictChunk(service.layout.encodeChunkCoords(coords), entry.value_ptr.*);
        }
        self.columns.deinit(service.allocator);
        self.world.deinit();
    }

    fn start(client: *service_module.Client, body: collision.Body, xy: [2]f64) !Bootstrap {
        const service = client.service;
        const area = try footprint(service.layout, body, xy);
        var self: Bootstrap = .{
            .client = client,
            .world = try World.init(service.allocator, service.layout),
            .body = body,
            .xy = xy,
        };
        errdefer self.deinit();
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
                const entry = try self.columns.getOrPut(service.allocator, id);
                if (entry.found_existing) continue;
                entry.value_ptr.* = client.requestChunks(.{ coords[0], coords[1] }, 0, service.layout.size_in_chunks[2]);
            }
        }
        return self;
    }

    fn finish(self: *Bootstrap) !Position {
        defer self.deinit();
        const service = self.client.service;
        var responses: std.ArrayList(service_module.ChunkResponse) = .empty;
        defer {
            for (responses.items) |response| response.deinit(service.allocator);
            responses.deinit(service.allocator);
        }
        const expected = @as(usize, self.columns.count()) * @as(usize, @intCast(service.layout.size_in_chunks[2]));
        while (self.world.chunks.count() < expected) {
            if (!try self.client.waitResponses(&responses)) return error.MissingChunk;
            for (responses.items) |*response| {
                if (response.data != .blocks) continue;
                var column = response.coords;
                column[2] = 0;
                const token = self.columns.get(service.layout.encodeChunkCoords(column)) orelse continue;
                if (response.subscription_id != token) continue;
                self.world.insertChunk(response.coords, response.data.blocks.chunk) catch {
                    response.deinit(service.allocator);
                };
                // The cache takes ownership; leave only a non-owning response for cleanup.
                response.data = .acknowledgement;
            }
            for (responses.items) |response| response.deinit(service.allocator);
            responses.clearRetainingCapacity();
        }
        return findPosition(&self.world, self.body, self.xy);
    }
};

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

test "spawn and collision agree when the body only touches a taller neighboring block" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, 0 }, .stone);
    fixture.set(.{ 1, 0, 1 }, .stone);
    var query: collision.Query = .{ .world = &fixture.world, .body = .{} };
    for ([_]f64{ 0.7, 0.7 + collision.epsilon / 2 }) |x| {
        const spawn = try findPosition(&fixture.world, .{}, .{ x, 0.5 });
        try std.testing.expectEqual(Position{ x, 0.5, 1 }, spawn);
        try std.testing.expectEqual(.clear, query.overlap(spawn, true));
        try std.testing.expect(query.moveAxis(spawn, 2, -collision.ground_probe).collided);
    }
    const x = 0.7 + 2 * collision.epsilon;
    try std.testing.expectEqual(.solid, query.overlap(.{ x, 0.5, 1 }, true));
    try std.testing.expectEqual(Position{ x, 0.5, 2 }, try findPosition(&fixture.world, .{}, .{ x, 0.5 }));
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
    const client = try service.createClient();
    const token = editor.requestChunks(.{ 0, 0 }, 0, 1);
    var responses: std.ArrayList(service_module.ChunkResponse) = .empty;
    try std.testing.expect(try editor.waitResponses(&responses));
    for (responses.items) |response| response.deinit(service.allocator);
    responses.deinit(service.allocator);
    editor.evictChunk(layout.encodeChunkId(0, 0, 0), token);

    const xy = [2]f64{ -21.5, -21.5 };
    try std.testing.expectEqual(Position{ xy[0], xy[1], -16 }, try loadPosition(client, .{}, xy));
    try editAndWait(editor, .{ .block = .{ 10, 10, 16 }, .action = .{ .put = .dirt } });
    try std.testing.expectEqual(Position{ xy[0], xy[1], -15 }, try loadPosition(client, .{}, xy));
    try editAndWait(editor, .{ .block = .{ 10, 10, 16 }, .action = .remove });
    try editAndWait(editor, .{ .block = .{ 10, 10, 15 }, .action = .remove });
    try std.testing.expectEqual(Position{ xy[0], xy[1], -17 }, try loadPosition(client, .{}, xy));
}

test "spawn bootstrap loads all touched columns across chunk boundaries and the x seam" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try service_module.WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    for ([_][2]f64{ .{ -0.05, -0.05 }, .{ -31.95, -0.05 }, .{ 32.05, -0.05 } }) |xy|
        try std.testing.expectEqual(Position{ xy[0], xy[1], -16 }, try loadPosition(client, .{}, xy));
}

test "spawn scans terrain higher than the old fixed starting height" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 8 } });
    const service = try service_module.WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .{
        .terrain = .{ .seed = 12345, .params = .{ .base_height = 220, .height_amplitude = 0 } },
    });
    defer service.destroy();
    const client = try service.createClient();
    try std.testing.expectEqual(Position{ -2.06, -2.96, 92 }, try loadPosition(client, .{}, .{ -2.06, -2.96 }));
}

/// The worker processes this load after all previously queued spawn evictions.
/// Once its reply arrives, no further requests can mutate the spawn subscriptions.
fn expectEvicted(observer: *service_module.Client, client: *service_module.Client) !void {
    const token = observer.requestChunks(.{ 0, 0 }, 0, 1);
    defer observer.evictChunk(observer.service.layout.encodeChunkId(0, 0, 0), token);
    var responses: std.ArrayList(service_module.ChunkResponse) = .empty;
    defer {
        for (responses.items) |response| response.deinit(observer.service.allocator);
        responses.deinit(observer.service.allocator);
    }
    try std.testing.expect(try observer.waitResponses(&responses));
    try std.testing.expectEqual(1, responses.items.len);
    try std.testing.expectEqual(token, responses.items[0].subscription_id);
    try std.testing.expectEqual(0, client.subscriptions.count());
}

test "bootstrap evicts every temporary subscription after insufficient headroom" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try service_module.WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .{
        .terrain = .{ .seed = 12345, .params = .{ .base_height = 64, .height_amplitude = 0 } },
    });
    defer service.destroy();
    const client = try service.createClient();
    const observer = try service.createClient();
    // Four horizontal columns are touched, so cleanup must evict all eight chunks.
    try std.testing.expectError(error.NoSpawnSpace, loadPosition(client, .{}, .{ -0.05, -0.05 }));
    try expectEvicted(observer, client);
    try std.testing.expectEqual(2, service.clients.items.len);
    try std.testing.expectError(error.NoSpawnSpace, loadPosition(client, .{}, .{ -0.05, -0.05 }));
    try expectEvicted(observer, client);
    try std.testing.expectEqual(2, service.clients.items.len);
}

test "canceled bootstrap evicts in-flight subscriptions and reuses the endpoint with late replies" {
    const io = std.testing.io;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try service_module.WorldDataService.create(io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const observer = try service.createClient();

    // Prevent the receiver from consuming snapshots. Requests are already submitted
    // before starting finish(), so cancellation always interrupts an active bootstrap.
    client.responses.mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) client.responses.mutex.unlock(io);
    var bootstrap = try Bootstrap.start(client, .{}, .{ -0.05, -0.05 });
    var task = io.concurrent(Bootstrap.finish, .{&bootstrap}) catch |err| {
        bootstrap.deinit();
        return err;
    };
    const result = task.cancel(io);
    client.responses.mutex.unlock(io);
    locked = false;
    try std.testing.expectError(error.Canceled, result);
    try expectEvicted(observer, client);

    // The service may have published snapshots while handling the cancellation.
    // A second spawn must consume them without accepting their obsolete tokens.
    client.responses.mutex.lockUncancelable(io);
    const queued = client.responses.items.items.len;
    client.responses.mutex.unlock(io);
    try std.testing.expect(queued > 0);
    try std.testing.expectEqual(Position{ 10.5, 10.5, -16 }, try loadPosition(client, .{}, .{ 10.5, 10.5 }));
    try expectEvicted(observer, client);
    try std.testing.expectEqual(2, service.clients.items.len);
    var leftovers: std.ArrayList(service_module.ChunkResponse) = .empty;
    defer {
        for (leftovers.items) |response| response.deinit(service.allocator);
        leftovers.deinit(service.allocator);
    }
    client.takeResponses(&leftovers);
    try std.testing.expectEqual(0, leftovers.items.len);
}
