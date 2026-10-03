const std = @import("std");
const Io = std.Io;
const world_module = @import("./world.zig");
const WorldChunk = world_module.WorldChunk;
const BlockOperation = world_module.BlockOperation;
const OperationStatus = world_module.OperationStatus;
const encodeChunkPositionArray = world_module.encodeChunkPositionArray;
const world_generator = @import("./world_generator.zig");
const WorldGenerator = world_generator.WorldGenerator;
const ColumnGenerator = world_generator.ColumnGenerator;
const ChunkPosition = @import("./consts.zig").ChunkPosition;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WORLD_SIZE = @import("./consts.zig").WORLD_SIZE;

/// Unbounded multi-producer queue. Pushing never waits for the consumer (only for the short
/// critical section), the consumer takes all queued items at once.
fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: Io.Mutex = .init,
        not_empty: Io.Condition = .init,
        items: std.ArrayList(T) = .empty,
        is_closed: bool = false,

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }

        fn push(self: *Self, io: Io, allocator: std.mem.Allocator, item: T) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            std.debug.assert(!self.is_closed);
            self.items.append(allocator, item) catch @panic("OOM");
            self.not_empty.signal(io);
        }

        /// Moves all queued items into `out`, which must be empty. Doesn't wait for new items.
        fn takeAll(self: *Self, io: Io, out: *std.ArrayList(T)) void {
            std.debug.assert(out.items.len == 0);
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            std.mem.swap(std.ArrayList(T), &self.items, out);
        }

        /// Same as `takeAll`, but waits until there is at least one item.
        /// Returns false once the mailbox is closed and drained.
        fn waitAndTakeAll(self: *Self, io: Io, out: *std.ArrayList(T)) bool {
            std.debug.assert(out.items.len == 0);
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            while (self.items.items.len == 0) {
                if (self.is_closed) {
                    return false;
                }
                self.not_empty.waitUncancelable(io, &self.mutex);
            }

            std.mem.swap(std.ArrayList(T), &self.items, out);
            return true;
        }

        fn waitAndTakeAllCancelable(self: *Self, io: Io, out: *std.ArrayList(T)) Io.Cancelable!bool {
            std.debug.assert(out.items.len == 0);
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            while (self.items.items.len == 0) {
                if (self.is_closed) return false;
                try self.not_empty.wait(io, &self.mutex);
            }
            std.mem.swap(std.ArrayList(T), &self.items, out);
            return true;
        }

        fn close(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            self.is_closed = true;
            self.not_empty.broadcast(io);
        }
    };
}

pub const OperationResult = struct {
    request_id: u64,
    status: OperationStatus,
};

/// Loads, operation replies and unsolicited changes all carry the authoritative snapshot.
/// A command reply is sent even after eviction; the optional subscription token lets the
/// receiver retire its pending command without resurrecting the evicted chunk.
pub const ChunkResponse = struct {
    subscription_id: ?u64,
    coords: [3]u30,
    operation: ?OperationResult = null,
    /// Owned by the receiver.
    chunk: WorldChunk,
};

const Request = union(enum) {
    register: *Client,
    load_chunks: struct {
        client: *Client,
        request_id: u64,
        column: [2]u30,
        z_start: u30,
        z_end: u30,
    },
    evict_chunk: struct { client: *Client, position: ChunkPosition, subscription_id: u64 },
    operation: struct { client: *Client, request_id: u64, operation: BlockOperation },
};

/// One endpoint per producer/consumer thread. Endpoints and their queued replies are owned
/// by the service and remain alive until it is destroyed. Stop all clients' tasks first.
pub const Client = struct {
    service: *WorldDataService,
    responses: Mailbox(ChunkResponse) = .{},
    next_request_id: u64 = 1,
    /// Only accessed by the service worker. Values identify subscription generations.
    subscriptions: std.AutoHashMapUnmanaged(ChunkPosition, u64) = .empty,

    fn nextRequestId(self: *Client) u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    /// Loading subscribes to changes until eviction. A new load replaces the old token.
    pub fn requestChunks(self: *Client, column: [2]u30, z_start: u30, z_end: u30) u64 {
        std.debug.assert(column[0] < WORLD_SIZE[0] and column[1] < WORLD_SIZE[1]);
        std.debug.assert(z_start < z_end and z_end <= WORLD_SIZE[2]);
        const id = self.nextRequestId();
        self.service.requests.push(self.service.io, self.service.allocator, .{ .load_chunks = .{
            .client = self,
            .request_id = id,
            .column = column,
            .z_start = z_start,
            .z_end = z_end,
        } });
        return id;
    }

    pub fn evictChunk(self: *Client, position: ChunkPosition, subscription_id: u64) void {
        self.service.requests.push(self.service.io, self.service.allocator, .{ .evict_chunk = .{
            .client = self,
            .position = position,
            .subscription_id = subscription_id,
        } });
    }

    /// Sends only intent. Every command gets its own result and snapshot, including failures.
    /// Commands from this endpoint are processed in submission order.
    pub fn submitOperation(self: *Client, operation: BlockOperation) u64 {
        operation.validate();
        const id = self.nextRequestId();
        self.service.requests.push(self.service.io, self.service.allocator, .{ .operation = .{
            .client = self,
            .request_id = id,
            .operation = operation,
        } });
        return id;
    }

    pub fn takeResponses(self: *Client, out: *std.ArrayList(ChunkResponse)) void {
        self.responses.takeAll(self.service.io, out);
    }

    /// For background clients. Cancelable so shutdown doesn't wait for a response or timer.
    pub fn waitResponses(self: *Client, out: *std.ArrayList(ChunkResponse)) Io.Cancelable!bool {
        return self.responses.waitAndTakeAllCancelable(self.service.io, out);
    }
};

/// Sole authority for generation, block preconditions and revisions. A single worker orders
/// requests from all clients. Successful operations broadcast owned chunk snapshots to current
/// subscribers; the initiating client receives one combined status + snapshot reply.
pub const WorldDataService = struct {
    io: Io,
    allocator: std.mem.Allocator,
    requests: Mailbox(Request) = .{},
    is_shutting_down: std.atomic.Value(bool) = .init(false),
    worker: Io.Future(void),
    /// Accessed only by the worker while running.
    clients: std.ArrayList(*Client) = .empty,
    worker_state: WorkerState,

    /// The allocator must be thread-safe; messages transfer ownership between tasks.
    pub fn create(io: Io, allocator: std.mem.Allocator, generator: WorldGenerator) !*WorldDataService {
        generator.validate();
        const self = try allocator.create(WorldDataService);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .worker = undefined,
            .worker_state = .{ .generator = generator },
        };
        self.worker = try io.concurrent(runWorker, .{self});
        return self;
    }

    pub fn createClient(self: *WorldDataService) !*Client {
        const client = try self.allocator.create(Client);
        client.* = .{ .service = self };
        self.requests.push(self.io, self.allocator, .{ .register = client });
        return client;
    }

    /// Call after all producers have stopped. Drains submitted edits, skips pending loads,
    /// and frees replies that nobody consumed.
    pub fn destroy(self: *WorldDataService) void {
        self.is_shutting_down.store(true, .monotonic);
        self.requests.close(self.io);
        self.worker.await(self.io);
        for (self.clients.items) |client| {
            for (client.responses.items.items) |response| response.chunk.content.deinit(self.allocator);
            client.responses.deinit(self.allocator);
            client.subscriptions.deinit(self.allocator);
            self.allocator.destroy(client);
        }
        self.clients.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.worker_state.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn runWorker(self: *WorldDataService) void {
        var batch: std.ArrayList(Request) = .empty;
        defer batch.deinit(self.allocator);
        while (self.requests.waitAndTakeAll(self.io, &batch)) {
            for (batch.items) |request| self.processRequest(request);
            batch.clearRetainingCapacity();
        }
    }

    fn processRequest(self: *WorldDataService, request: Request) void {
        switch (request) {
            .register => |client| self.clients.append(self.allocator, client) catch @panic("OOM"),
            .evict_chunk => |evict| {
                if (evict.client.subscriptions.get(evict.position) == evict.subscription_id) {
                    _ = evict.client.subscriptions.remove(evict.position);
                }
            },
            .load_chunks => |load| {
                if (self.is_shutting_down.load(.monotonic)) return;
                const generator = ColumnGenerator.init(self.worker_state.generator, load.column);
                var z = load.z_start;
                while (z < load.z_end and !self.is_shutting_down.load(.monotonic)) : (z += 1) {
                    const coords = [3]u30{ load.column[0], load.column[1], z };
                    load.client.subscriptions.put(self.allocator, encodeChunkPositionArray(coords), load.request_id) catch @panic("OOM");
                    load.client.responses.push(self.io, self.allocator, .{
                        .subscription_id = load.request_id,
                        .coords = coords,
                        .chunk = self.worker_state.loadChunk(self.allocator, &generator, coords),
                    });
                }
            },
            .operation => |edit| {
                const coords, _ = world_module.splitBlockCoords(edit.operation.block);
                const position = encodeChunkPositionArray(coords);
                const result = self.worker_state.applyOperation(self.allocator, edit.operation);
                if (self.is_shutting_down.load(.monotonic)) {
                    result.chunk.content.deinit(self.allocator);
                    return;
                }
                if (result.status == .success) {
                    for (self.clients.items) |client| {
                        if (client == edit.client) continue;
                        const token = client.subscriptions.get(position) orelse continue;
                        client.responses.push(self.io, self.allocator, .{
                            .subscription_id = token,
                            .coords = coords,
                            .chunk = result.chunk.clone(self.allocator),
                        });
                    }
                }
                edit.client.responses.push(self.io, self.allocator, .{
                    .subscription_id = edit.client.subscriptions.get(position),
                    .coords = coords,
                    .operation = .{ .request_id = edit.request_id, .status = result.status },
                    .chunk = result.chunk,
                });
            },
        }
    }
};

const WorkerState = struct {
    generator: WorldGenerator,
    /// Committed edits survive cache eviction. Untouched chunks are regenerated on demand.
    modified_chunks: std.AutoHashMapUnmanaged(ChunkPosition, WorldChunk) = .empty,

    fn deinit(self: *WorkerState, allocator: std.mem.Allocator) void {
        var iterator = self.modified_chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.content.deinit(allocator);
        self.modified_chunks.deinit(allocator);
    }

    fn loadChunk(self: *const WorkerState, allocator: std.mem.Allocator, generator: *const ColumnGenerator, coords: [3]u30) WorldChunk {
        if (self.modified_chunks.get(encodeChunkPositionArray(coords))) |chunk| return chunk.clone(allocator);
        return generator.generateChunk(allocator, coords[2]);
    }

    fn applyOperation(self: *WorkerState, allocator: std.mem.Allocator, operation: BlockOperation) struct { status: OperationStatus, chunk: WorldChunk } {
        const coords, const local = world_module.splitBlockCoords(operation.block);
        const position = encodeChunkPositionArray(coords);
        var chunk = if (self.modified_chunks.get(position)) |stored| stored.clone(allocator) else blk: {
            const generator = ColumnGenerator.init(self.generator, .{ coords[0], coords[1] });
            break :blk generator.generateChunk(allocator, coords[2]);
        };
        const status = chunk.apply(allocator, local, operation.action);
        if (status == .success) {
            chunk.revision += 1;
            const entry = self.modified_chunks.getOrPut(allocator, position) catch @panic("OOM");
            if (entry.found_existing) entry.value_ptr.content.deinit(allocator);
            entry.value_ptr.* = chunk.clone(allocator);
        }
        return .{ .status = status, .chunk = chunk };
    }
};

fn waitForResponses(client: *Client, out: *std.ArrayList(ChunkResponse), count: usize) !void {
    var batch: std.ArrayList(ChunkResponse) = .empty;
    defer batch.deinit(std.testing.allocator);
    while (out.items.len < count) {
        try std.testing.expect(try client.waitResponses(&batch));
        try out.appendSlice(std.testing.allocator, batch.items);
        batch.clearRetainingCapacity();
    }
    try std.testing.expectEqual(count, out.items.len);
}

fn deinitResponses(responses: *std.ArrayList(ChunkResponse)) void {
    for (responses.items) |response| response.chunk.content.deinit(std.testing.allocator);
    responses.deinit(std.testing.allocator);
}

fn pushNumbers(mailbox: *Mailbox(u32), io: Io, first: u32, count: u32) void {
    for (first..first + count) |number| {
        mailbox.push(io, std.testing.allocator, @intCast(number));
    }
}

fn waitUntilClosed(mailbox: *Mailbox(u32), io: Io) bool {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);
    return mailbox.waitAndTakeAll(io, &out);
}

test "mailbox gives out items in push order without waiting" {
    const io = std.testing.io;
    var mailbox: Mailbox(u32) = .{};
    defer mailbox.deinit(std.testing.allocator);

    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);

    mailbox.takeAll(io, &out);
    try std.testing.expectEqual(0, out.items.len);

    mailbox.push(io, std.testing.allocator, 1);
    mailbox.push(io, std.testing.allocator, 2);
    mailbox.push(io, std.testing.allocator, 3);
    mailbox.takeAll(io, &out);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, out.items);

    out.clearRetainingCapacity();
    mailbox.takeAll(io, &out);
    try std.testing.expectEqual(0, out.items.len);
}

test "closed mailbox gives out the remaining items before reporting that it's closed" {
    const io = std.testing.io;
    var mailbox: Mailbox(u32) = .{};
    defer mailbox.deinit(std.testing.allocator);

    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);

    mailbox.push(io, std.testing.allocator, 1);
    mailbox.push(io, std.testing.allocator, 2);
    mailbox.close(io);

    try std.testing.expect(mailbox.waitAndTakeAll(io, &out));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, out.items);

    out.clearRetainingCapacity();
    try std.testing.expect(!mailbox.waitAndTakeAll(io, &out));
    try std.testing.expectEqual(0, out.items.len);
}

test "closing an empty mailbox releases the waiting consumer" {
    const io = std.testing.io;
    var mailbox: Mailbox(u32) = .{};
    defer mailbox.deinit(std.testing.allocator);

    var consumer = try io.concurrent(waitUntilClosed, .{ &mailbox, io });
    mailbox.close(io);
    try std.testing.expect(!consumer.await(io));
}

test "items pushed by concurrent producers are received exactly once and in order per producer" {
    const io = std.testing.io;
    const producer_count = 4;
    const items_per_producer = 1000;

    var mailbox: Mailbox(u32) = .{};
    defer mailbox.deinit(std.testing.allocator);

    var producers: Io.Group = .init;
    defer producers.cancel(io);
    for (0..producer_count) |producer| {
        try producers.concurrent(io, pushNumbers, .{ &mailbox, io, @intCast(producer * items_per_producer), items_per_producer });
    }

    var next_numbers: [producer_count]u32 = undefined;
    for (&next_numbers, 0..) |*next_number, producer| {
        next_number.* = @intCast(producer * items_per_producer);
    }

    var batch: std.ArrayList(u32) = .empty;
    defer batch.deinit(std.testing.allocator);

    var received_count: usize = 0;
    while (received_count < producer_count * items_per_producer) {
        try std.testing.expect(mailbox.waitAndTakeAll(io, &batch));
        for (batch.items) |number| {
            try std.testing.expect(number < producer_count * items_per_producer);
            const producer = number / items_per_producer;
            try std.testing.expectEqual(next_numbers[producer], number);
            next_numbers[producer] += 1;
        }
        received_count += batch.items.len;
        batch.clearRetainingCapacity();
    }
    try producers.await(io);

    mailbox.close(io);
    try std.testing.expect(!mailbox.waitAndTakeAll(io, &batch));
}

test "loaded chunks match generation and subscribe with the load token" {
    const generator = WorldGenerator{ .terrain = .{ .seed = 12345 } };
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, generator);
    defer service.destroy();
    const client = try service.createClient();
    const token = client.requestChunks(.{ 10, 20 }, 2, 6);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(client, &responses, 4);
    const column = ColumnGenerator.init(generator, .{ 10, 20 });
    for (responses.items, 2..) |response, z| {
        const expected = column.generateChunk(std.testing.allocator, @intCast(z));
        defer expected.content.deinit(std.testing.allocator);
        try std.testing.expectEqual(token, response.subscription_id);
        try std.testing.expectEqual(null, response.operation);
        try std.testing.expectEqual([3]u30{ 10, 20, @intCast(z) }, response.coords);
        try std.testing.expectEqual(expected.flags, response.chunk.flags);
        try std.testing.expectEqual(expected.solid_block_count, response.chunk.solid_block_count);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.content.toData()), std.mem.asBytes(&response.chunk.content.toData()));
    }
}

test "commands validate against authority and return status plus independent snapshots" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const block = [3]u32{ 1, 2, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    const put = client.submitOperation(.{ .block = block, .action = .{ .put = .dirt } });
    const duplicate = client.submitOperation(.{ .block = block, .action = .{ .put = .stone } });
    const remove = client.submitOperation(.{ .block = block, .action = .remove });
    const missing = client.submitOperation(.{ .block = block, .action = .remove });
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(client, &responses, 4);
    const ids = [_]u64{ put, duplicate, remove, missing };
    const statuses = [_]OperationStatus{ .success, .already_exists, .success, .already_removed };
    const revisions = [_]u32{ 1, 1, 2, 2 };
    for (responses.items, ids, statuses, revisions) |response, id, status, revision| {
        try std.testing.expectEqual(null, response.subscription_id);
        try std.testing.expectEqual(id, response.operation.?.request_id);
        try std.testing.expectEqual(status, response.operation.?.status);
        try std.testing.expectEqual(revision, response.chunk.revision);
    }
    try std.testing.expectEqual(.dirt, responses.items[0].chunk.content.getBlock(.{ 1, 2, 31 }));
    try std.testing.expectEqual(.dirt, responses.items[1].chunk.content.getBlock(.{ 1, 2, 31 }));
    try std.testing.expectEqual(1, responses.items[1].chunk.solid_block_count);
    try std.testing.expect(responses.items[2].chunk.content == .empty);
    try std.testing.expectEqual(WorldChunk.initEmpty().flags, responses.items[2].chunk.flags);
}

test "successful edits push data only to subscribers and combine the origin reply" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();
    const origin = try service.createClient();
    const observer = try service.createClient();
    const other = try service.createClient();
    const z = WORLD_SIZE[2] - 1;
    const origin_token = origin.requestChunks(.{ 0, 0 }, z, z + 1);
    const observer_token = observer.requestChunks(.{ 0, 0 }, z, z + 1);
    _ = other.requestChunks(.{ 1, 0 }, z, z + 1);
    const block = [3]u32{ 0, 0, z * CHUNK_SIZE };
    const id = origin.submitOperation(.{ .block = block, .action = .{ .put = .dirt } });
    _ = origin.submitOperation(.{ .block = block, .action = .{ .put = .stone } });
    var origin_responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&origin_responses);
    // Last reply is also a barrier: all prior broadcasts have been enqueued.
    try waitForResponses(origin, &origin_responses, 3);
    var observed: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&observed);
    observer.takeResponses(&observed);
    try std.testing.expectEqual(2, observed.items.len);
    try std.testing.expectEqual(observer_token, observed.items[1].subscription_id);
    try std.testing.expectEqual(null, observed.items[1].operation);
    try std.testing.expectEqual(.dirt, observed.items[1].chunk.content.getBlock(.{ 0, 0, 0 }));
    try std.testing.expectEqual(origin_token, origin_responses.items[1].subscription_id);
    try std.testing.expectEqual(id, origin_responses.items[1].operation.?.request_id);
    var unrelated: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&unrelated);
    other.takeResponses(&unrelated);
    try std.testing.expectEqual(1, unrelated.items.len);
}

test "eviction stops pushes and a fresh load returns committed edits with a new token" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();
    const main = try service.createClient();
    const npc = try service.createClient();
    const z = WORLD_SIZE[2] - 1;
    const position = world_module.encodeChunkPosition(0, 0, z);
    const old_token = main.requestChunks(.{ 0, 0 }, z, z + 1);
    const block = [3]u32{ 16, 16, z * CHUNK_SIZE };
    _ = npc.submitOperation(.{ .block = block, .action = .{ .put = .dirt } });
    main.evictChunk(position, old_token);
    _ = npc.submitOperation(.{ .block = block, .action = .remove });
    const new_token = main.requestChunks(.{ 0, 0 }, z, z + 1);
    // A delayed eviction for the old generation must not remove the new subscription.
    main.evictChunk(position, old_token);
    _ = npc.submitOperation(.{ .block = block, .action = .{ .put = .stone } });
    var npc_responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&npc_responses);
    try waitForResponses(npc, &npc_responses, 3);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    main.takeResponses(&responses);
    try std.testing.expectEqual(4, responses.items.len);
    try std.testing.expectEqual(old_token, responses.items[0].subscription_id);
    try std.testing.expectEqual(old_token, responses.items[1].subscription_id);
    try std.testing.expectEqual(new_token, responses.items[2].subscription_id);
    try std.testing.expectEqual(2, responses.items[2].chunk.revision);
    try std.testing.expect(responses.items[2].chunk.content == .empty);
    try std.testing.expectEqual(new_token, responses.items[3].subscription_id);
    try std.testing.expectEqual(3, responses.items[3].chunk.revision);
}

fn putFromClient(client: *Client, block: [3]u32) void {
    _ = client.submitOperation(.{ .block = block, .action = .{ .put = .dirt } });
}

test "concurrent clients cannot both put into the same empty block" {
    const io = std.testing.io;
    const service = try WorldDataService.create(io, std.testing.allocator, .flat);
    defer service.destroy();
    const a = try service.createClient();
    const b = try service.createClient();
    const block = [3]u32{ 0, 0, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    var first = try io.concurrent(putFromClient, .{ a, block });
    defer first.await(io);
    var second = try io.concurrent(putFromClient, .{ b, block });
    defer second.await(io);
    var a_responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&a_responses);
    var b_responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&b_responses);
    try waitForResponses(a, &a_responses, 1);
    try waitForResponses(b, &b_responses, 1);
    const a_status = a_responses.items[0].operation.?.status;
    const b_status = b_responses.items[0].operation.?.status;
    try std.testing.expect((a_status == .success and b_status == .already_exists) or
        (a_status == .already_exists and b_status == .success));
    try std.testing.expectEqual(1, a_responses.items[0].chunk.revision);
    try std.testing.expectEqual(1, b_responses.items[0].chunk.revision);
}

test "service shutdown drains edits and frees unconsumed replies" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    const client = try service.createClient();
    for (0..4) |x| _ = client.requestChunks(.{ @intCast(x), 0 }, 0, WORLD_SIZE[2]);
    _ = client.submitOperation(.{ .block = .{ 0, 0, 0 }, .action = .remove });
    service.destroy();
}

test "shutdown skips generation requests but still commits commands" {
    var service = WorldDataService{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .worker = undefined,
        .worker_state = .{ .generator = .flat },
    };
    var client = Client{ .service = &service };
    defer service.requests.deinit(std.testing.allocator);
    defer service.worker_state.deinit(std.testing.allocator);
    defer client.responses.deinit(std.testing.allocator);
    defer client.subscriptions.deinit(std.testing.allocator);
    _ = client.requestChunks(.{ 0, 0 }, 0, WORLD_SIZE[2]);
    _ = client.submitOperation(.{ .block = .{ 0, 0, 0 }, .action = .remove });
    service.is_shutting_down.store(true, .monotonic);
    service.requests.close(service.io);
    service.runWorker();
    try std.testing.expectEqual(0, client.responses.items.items.len);
    try std.testing.expectEqual(0, client.subscriptions.count());
    try std.testing.expectEqual(1, service.worker_state.modified_chunks.get(0).?.revision);
}
