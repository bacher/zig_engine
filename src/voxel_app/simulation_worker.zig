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
    paused: std.atomic.Value(bool) = .init(false),
    // Serialize the admission boundary, never response waits or simulation sleeps.
    dispatch_mutex: Io.Mutex = .init,
    test_before_dispatch: if (@import("builtin").is_test) ?DispatchHook else void = if (@import("builtin").is_test) null else {},

    const DispatchHook = struct {
        context: *anyopaque,
        call: *const fn (*anyopaque) void,
    };

    pub fn create(service: *WorldDataService) !*SimulationWorker {
        const self = try service.allocator.create(SimulationWorker);
        errdefer service.allocator.destroy(self);
        self.* = .{ .client = try service.createClient(), .worker = undefined };
        self.client.simulation = true;
        self.worker = try service.io.concurrent(run, .{self});
        return self;
    }

    pub fn pauseDispatch(self: *SimulationWorker) void {
        const io = self.client.service.io;
        self.dispatch_mutex.lockUncancelable(io);
        defer self.dispatch_mutex.unlock(io);
        self.paused.store(true, .release);
        // Any producer that won the mutex has already enqueued its command.
        // Later producers recheck paused while holding this same mutex.
    }
    pub fn resumeDispatch(self: *SimulationWorker) void {
        const io = self.client.service.io;
        self.dispatch_mutex.lockUncancelable(io);
        defer self.dispatch_mutex.unlock(io);
        self.paused.store(false, .release);
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
            while (self.paused.load(.acquire) or service.simulationPaused()) try Io.sleep(service.io, .fromMilliseconds(10), .awake);
            const id = self.tryDispatch(.{ .block = block, .action = action }) catch |err| switch (err) {
                error.DispatchPaused => continue,
                error.Busy, error.OutOfMemory => {
                    try Io.sleep(service.io, .fromMilliseconds(100), .awake);
                    continue;
                },
                error.ServiceStopped => return,
            };
            const status = try self.waitForOperation(&responses, id);
            action = nextAction(action, status);
            try Io.sleep(service.io, .fromSeconds(2), .awake);
        }
    }

    fn tryDispatch(self: *SimulationWorker, operation: world.BlockOperation) (Client.SubmitError || error{DispatchPaused})!u64 {
        // Test the preemption point after the outer pause check but before admission.
        if (@import("builtin").is_test) if (self.test_before_dispatch) |hook| hook.call(hook.context);
        const io = self.client.service.io;
        self.dispatch_mutex.lockUncancelable(io);
        defer self.dispatch_mutex.unlock(io);
        if (self.paused.load(.acquire) or self.client.service.simulationPaused()) return error.DispatchPaused;
        return self.client.trySubmitOperation(operation);
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
    defer chunk.deinit(std.testing.allocator);
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
    responses.items[0].data.blocks.chunk.deinit(allocator);
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

test "exit pause fences a simulation dispatch preempted before submission and resume admits it later" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const storage = @import("persistence/storage.zig");
    const format = @import("persistence/format.zig");
    const persistence = @import("persistence/coordinator.zig");
    const Helpers = struct {
        fn save(service: *WorldDataService) !void {
            const intent = service.requestSave(true);
            const deadline = persistence.now(std.testing.io) + 10 * std.time.ns_per_s;
            while (persistence.now(std.testing.io) < deadline) {
                const status = service.persistenceStatus();
                if (status.intent_id == intent and !status.active and (status.phase == .complete or status.phase == .failed)) {
                    try std.testing.expectEqual(persistence.Phase.complete, status.phase);
                    try std.testing.expectEqual(status.target_sequence, status.durable_sequence);
                    return;
                }
                try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            return error.TestSaveTimeout;
        }
    };
    const Gate = struct {
        mutex: Io.Mutex = .init,
        changed: Io.Condition = .init,
        entered: bool = false,
        released: bool = false,
        fn stop(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(std.testing.io);
            defer self.mutex.unlock(std.testing.io);
            self.entered = true;
            self.changed.broadcast(std.testing.io);
            while (!self.released) self.changed.waitUncancelable(std.testing.io, &self.mutex);
        }
        fn wait(self: *@This()) void {
            self.mutex.lockUncancelable(std.testing.io);
            defer self.mutex.unlock(std.testing.io);
            while (!self.entered) self.changed.waitUncancelable(std.testing.io, &self.mutex);
        }
        fn release(self: *@This()) void {
            self.mutex.lockUncancelable(std.testing.io);
            defer self.mutex.unlock(std.testing.io);
            self.released = true;
            self.changed.broadcast(std.testing.io);
        }
    };

    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(allocator, "/private/tmp/simulation-exit-fence-{x}", .{uuid}, 0);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const layout = try @import("engine").WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const descriptor = try format.encodeDescriptor(allocator, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 0, .seed = 0, .settings = &.{} });
    defer allocator.free(descriptor);
    const global = format.encodeGlobal(0);
    var store = try storage.Store.create(allocator, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
    defer store.deinit();
    const service = try WorldDataService.createPersistent(io, allocator, &layout, .flat, &store, .{});
    defer service.destroy();
    // Drive the actual dispatch helper without the NPC's startup and two-second cadence.
    var simulation: SimulationWorker = .{ .client = try service.createClient(), .worker = undefined };
    simulation.client.simulation = true;
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer {
        for (responses.items) |response| response.deinit(allocator);
        responses.deinit(allocator);
    }
    const prior = try simulation.tryDispatch(.{ .block = .{ 10, 10, 48 }, .action = .{ .put = .snow } });
    try std.testing.expectEqual(world.OperationStatus.success, try simulation.waitForOperation(&responses, prior));

    // The worker has passed the optimistic pause check, then is preempted immediately
    // before the synchronized admission check. UI pause must not wait on this hook.
    var gate: Gate = .{};
    simulation.test_before_dispatch = .{ .context = &gate, .call = Gate.stop };
    var dispatch = try io.concurrent(SimulationWorker.tryDispatch, .{ &simulation, world.BlockOperation{ .block = .{ 12, 10, 48 }, .action = .{ .put = .snow } } });
    var joined = false;
    defer {
        gate.release();
        if (!joined) _ = dispatch.await(io) catch {};
    }
    gate.wait();
    simulation.pauseDispatch();
    // Complete the real final save while the producer remains preempted. It includes
    // the prior admitted command and cannot acquire a later command after its boundary.
    try Helpers.save(service);
    gate.release();
    const result = dispatch.await(io);
    joined = true;
    try std.testing.expectError(error.DispatchPaused, result);
    const id = layout.encodeChunkCoords(.{ 0, 0, 1 });
    const saved = (try store.readChunk(allocator, id)).?;
    defer allocator.free(saved);
    var decoded = try format.decodeChunk(allocator, store.world_uuid, saved, store.dimensions);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), decoded.revision);
    try std.testing.expectEqual(@as(u8, @intFromEnum(@import("engine").voxel_chunk.BlockType.snow)), decoded.blocks[16 * 1024 + 10 * 32 + 10]);
    try std.testing.expectEqual(@as(u8, 0), decoded.blocks[16 * 1024 + 10 * 32 + 12]);

    // Cancel-exit behavior reopens the gate; the held intent can be admitted normally.
    simulation.resumeDispatch();
    const resumed = try simulation.tryDispatch(.{ .block = .{ 12, 10, 48 }, .action = .{ .put = .snow } });
    try std.testing.expectEqual(world.OperationStatus.success, try simulation.waitForOperation(&responses, resumed));
    try Helpers.save(service);
    const after_resume = (try store.readChunk(allocator, id)).?;
    defer allocator.free(after_resume);
    var latest = try format.decodeChunk(allocator, store.world_uuid, after_resume, store.dimensions);
    defer latest.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), latest.revision);
    try std.testing.expectEqual(@as(u8, @intFromEnum(@import("engine").voxel_chunk.BlockType.snow)), latest.blocks[16 * 1024 + 10 * 32 + 12]);
}
