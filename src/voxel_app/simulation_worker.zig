const test_layout = @import("test_world.zig").layout;
const std = @import("std");
const Io = std.Io;
const service_module = @import("./world_data_service.zig");
const WorldDataService = service_module.WorldDataService;
const Client = service_module.Client;
const ChunkResponse = service_module.ChunkResponse;
const world = @import("./world.zig");
const consts = @import("./consts.zig");

/// A minimal NPC simulation. Its only world access is through its own service endpoint.
/// It finds the surface at the central chunk's midpoint, then puts/removes one dirt block
/// every two seconds. A failed put is retried without removing somebody else's block.
pub const SimulationWorker = struct {
    client: *Client,
    worker: Io.Future(void),

    pub fn create(service: *WorldDataService) !*SimulationWorker {
        const self = try service.allocator.create(SimulationWorker);
        errdefer service.allocator.destroy(self);
        self.* = .{ .client = try service.createClient(), .worker = undefined };
        self.worker = try service.io.concurrent(run, .{self});
        return self;
    }

    /// Stop before destroying the service, which owns this worker's endpoint.
    pub fn destroy(self: *SimulationWorker) void {
        const service = self.client.service;
        self.worker.cancel(service.io);
        service.allocator.destroy(self);
    }

    fn run(self: *SimulationWorker) void {
        self.simulate() catch |err| switch (err) {
            error.Canceled => {},
        };
    }

    fn simulate(self: *SimulationWorker) Io.Cancelable!void {
        const client = self.client;
        const service = client.service;
        const layout = service.layout;
        const column = @Vector(2, i32){ layout.origin_chunk[0], layout.origin_chunk[1] };
        const token = client.requestChunks(column, 0, layout.size_in_chunks[2]);
        var responses: std.ArrayList(ChunkResponse) = .empty;
        defer {
            for (responses.items) |response| response.deinit(service.allocator);
            responses.deinit(service.allocator);
        }
        // Eviction also happens on cancellation during startup. The service drains it later.
        defer for (0..@as(usize, @intCast(layout.size_in_chunks[2]))) |z| {
            client.evictChunk(layout.encodeChunkId(column[0], column[1], z), token);
        };

        const received = service.allocator.alloc(bool, @intCast(layout.size_in_chunks[2])) catch @panic("OOM");
        defer service.allocator.free(received);
        @memset(received, false);
        var count: usize = 0;
        var surface_z: u32 = 0;
        while (count < received.len) {
            if (!try client.waitResponses(&responses)) return;
            for (responses.items) |response| {
                defer response.deinit(service.allocator);
                if (response.subscription_id != token) continue;
                if (response.data != .blocks) continue;
                const z = response.coords[2];
                if (!received[@intCast(z)]) {
                    received[@intCast(z)] = true;
                    count += 1;
                }
                surface_z = @max(surface_z, surfaceAboveChunk(response.data.blocks.chunk, z));
            }
            responses.clearRetainingCapacity();
        }
        // Subsequent traffic consists only of operation replies, with no standing subscription.
        for (0..@as(usize, @intCast(layout.size_in_chunks[2]))) |z| {
            client.evictChunk(layout.encodeChunkId(column[0], column[1], z), token);
        }
        if (surface_z >= layout.size_in_blocks[2]) return;
        const block = [3]u32{
            @as(u32, @intCast(column[0])) * consts.CHUNK_SIZE + consts.CHUNK_SIZE / 2,
            @as(u32, @intCast(column[1])) * consts.CHUNK_SIZE + consts.CHUNK_SIZE / 2,
            surface_z,
        };
        var action: world.BlockAction = .{ .put = .dirt };
        while (true) {
            const id = client.submitOperation(.{ .block = block, .action = action });
            const status = try self.waitForOperation(&responses, id);
            action = nextAction(action, status);
            try Io.sleep(service.io, .fromSeconds(2), .awake);
        }
    }

    fn waitForOperation(self: *SimulationWorker, responses: *std.ArrayList(ChunkResponse), id: u64) Io.Cancelable!world.OperationStatus {
        while (try self.client.waitResponses(responses)) {
            var status: ?world.OperationStatus = null;
            for (responses.items) |response| {
                response.deinit(self.client.service.allocator);
                if (response.operation) |result| {
                    if (result.request_id == id) status = result.status;
                }
            }
            responses.clearRetainingCapacity();
            if (status) |result| return result;
        }
        unreachable; // The service outlives this task.
    }
};

fn surfaceAboveChunk(chunk: world.WorldChunk, chunk_z: i32) u32 {
    var z: u32 = consts.CHUNK_SIZE;
    while (z > 0) {
        z -= 1;
        if (chunk.content.getBlock(.{ consts.CHUNK_SIZE / 2, consts.CHUNK_SIZE / 2, @intCast(z) }) != .none) {
            return @as(u32, @intCast(chunk_z)) * consts.CHUNK_SIZE + z + 1;
        }
    }
    return 0;
}

fn nextAction(action: world.BlockAction, status: world.OperationStatus) world.BlockAction {
    return if (action == .put and status == .success) .remove else .{ .put = .dirt };
}

test "simulation alternates on success and retries conflicting puts" {
    try std.testing.expect(nextAction(.{ .put = .dirt }, .success) == .remove);
    try std.testing.expect(nextAction(.remove, .success) == .put);
    try std.testing.expect(nextAction(.{ .put = .dirt }, .already_exists) == .put);
    try std.testing.expect(nextAction(.remove, .already_removed) == .put);
}

test "simulation surface is above the center block, including at chunk boundaries" {
    var chunk = world.WorldChunk.initEmpty();
    defer chunk.content.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, surfaceAboveChunk(chunk, 3));
    _ = chunk.apply(std.testing.allocator, .{ 0, 0, 31 }, .{ .put = .stone });
    try std.testing.expectEqual(0, surfaceAboveChunk(chunk, 3));
    _ = chunk.apply(std.testing.allocator, .{ 16, 16, 31 }, .{ .put = .stone });
    try std.testing.expectEqual(4 * consts.CHUNK_SIZE, surfaceAboveChunk(chunk, 3));
}

test "simulation can be canceled during startup" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const simulation = try SimulationWorker.create(service);
    simulation.destroy();
}

test "simulation repeatedly pushes put remove put to a subscribed client" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const service = try WorldDataService.create(io, allocator, &test_layout, .flat);
    defer service.destroy();
    const observer = try service.createClient();
    const surface_chunk_z = test_layout.size_in_chunks[2] / 2 - 1;
    const token = observer.requestChunks(
        .{ test_layout.origin_chunk[0], test_layout.origin_chunk[1] },
        surface_chunk_z,
        surface_chunk_z + 1,
    );
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer {
        for (responses.items) |response| response.deinit(allocator);
        responses.deinit(allocator);
    }
    try std.testing.expect(try observer.waitResponses(&responses));
    try std.testing.expectEqual(1, responses.items.len);
    responses.items[0].data.blocks.chunk.content.deinit(allocator);
    responses.clearRetainingCapacity();

    const started = Io.Clock.awake.now(io);
    const simulation = try SimulationWorker.create(service);
    defer simulation.destroy();
    var changes: usize = 0;
    while (changes < 3) {
        try std.testing.expect(try observer.waitResponses(&responses));
        for (responses.items) |response| {
            try std.testing.expectEqual(token, response.subscription_id);
            try std.testing.expectEqual(null, response.operation);
            try std.testing.expectEqual(changes + 1, response.data.blocks.chunk.chunk_revision);
            const expected: @import("engine").voxel_chunk.BlockType = if (changes % 2 == 0) .dirt else .none;
            try std.testing.expectEqual(expected, response.data.blocks.chunk.content.getBlock(.{ 16, 16, 16 }));
            changes += 1;
        }
        for (responses.items) |response| response.deinit(allocator);
        responses.clearRetainingCapacity();
    }
    try std.testing.expect(started.durationTo(Io.Clock.awake.now(io)).nanoseconds >= 4 * std.time.ns_per_s);
}
