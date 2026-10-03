const std = @import("std");
const Io = std.Io;

const world_module = @import("./world.zig");
const World = world_module.World;
const WorldChunk = world_module.WorldChunk;
const encodeChunkPositionArray = world_module.encodeChunkPositionArray;
const world_generator = @import("./world_generator.zig");
const WorldGenerator = world_generator.WorldGenerator;
const ColumnGenerator = world_generator.ColumnGenerator;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
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

        fn close(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            self.is_closed = true;
            self.not_empty.broadcast(io);
        }
    };
}

const ChunkUpdate = struct {
    position: ChunkPosition,
    revision: u32,
    /// Snapshot of the whole chunk, owned by the message.
    data: *WorldChunkData,
};

const Request = union(enum) {
    /// Vertical range of chunks of a single column, z in [z_start, z_end).
    load_chunks: struct {
        request_id: u64,
        column: [2]u30,
        z_start: u30,
        z_end: u30,
    },
    update_chunk: ChunkUpdate,
};

pub const ChunkResponse = struct {
    request_id: u64,
    coords: [3]u30,
    /// Owned by the receiver.
    chunk: WorldChunk,
};

/// Owns everything world-data related: generation, copies of the modified chunks and (later)
/// persistence. The work is done by a separate task, the main thread talks to it through
/// messages and never waits for it.
///
/// Consistency rules:
/// * The main thread is the source of truth for block modifications. It applies them to its
///   own copy of the chunks immediately and is the only one producing chunk revisions. Edits
///   are possible only for the chunks the main thread has received.
/// * Requests are processed in the order they were sent. So a chunk requested after its update
///   was submitted always contains that update.
/// * Updates carry whole chunk snapshots. The worker keeps the snapshot with the highest
///   revision and ignores older ones, so snapshots can be coalesced or re-sent safely.
/// * Every chunk has its own response carrying the id of the request. The main thread drops
///   responses it doesn't wait for anymore (e.g. the chunk was evicted and requested again
///   while in flight).
pub const WorldDataService = struct {
    io: Io,
    allocator: std.mem.Allocator,
    requests: Mailbox(Request) = .{},
    responses: Mailbox(ChunkResponse) = .{},
    next_request_id: u64 = 1,
    worker: Io.Future(void),
    /// Accessed only by the worker while it's running.
    worker_state: WorkerState,

    /// `allocator` must be thread-safe, data allocated by the worker is freed by the main thread.
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

    /// Waits until the worker processes all requests sent so far, then stops it.
    pub fn destroy(self: *WorldDataService) void {
        self.requests.close(self.io);
        self.worker.await(self.io);

        for (self.responses.items.items) |response| {
            response.chunk.content.deinit(self.allocator);
        }
        self.responses.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.worker_state.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Asks for the chunks of the column with z in [z_start, z_end). Returns the id of the
    /// request, the responses of all these chunks will carry the same id.
    pub fn requestChunks(self: *WorldDataService, column: [2]u30, z_start: u30, z_end: u30) u64 {
        std.debug.assert(z_start < z_end and z_end <= WORLD_SIZE[2]);

        const request_id = self.next_request_id;
        self.next_request_id += 1;

        self.requests.push(self.io, self.allocator, .{ .load_chunks = .{
            .request_id = request_id,
            .column = column,
            .z_start = z_start,
            .z_end = z_end,
        } });

        return request_id;
    }

    /// Sends a copy of the modified chunk.
    pub fn submitChunkUpdate(self: *WorldDataService, position: ChunkPosition, revision: u32, data: *const WorldChunkData) void {
        const snapshot = self.allocator.create(WorldChunkData) catch @panic("OOM");
        snapshot.* = data.*;

        self.requests.push(self.io, self.allocator, .{ .update_chunk = .{
            .position = position,
            .revision = revision,
            .data = snapshot,
        } });
    }

    /// Moves the responses received so far into `out`, which must be empty. Doesn't wait.
    /// The caller owns the data of the responses.
    pub fn takeResponses(self: *WorldDataService, out: *std.ArrayList(ChunkResponse)) void {
        self.responses.takeAll(self.io, out);
    }

    fn runWorker(self: *WorldDataService) void {
        var batch: std.ArrayList(Request) = .empty;
        defer batch.deinit(self.allocator);

        while (self.requests.waitAndTakeAll(self.io, &batch)) {
            for (batch.items) |request| {
                switch (request) {
                    .update_chunk => |update| self.worker_state.applyUpdate(self.allocator, update),
                    .load_chunks => |load| {
                        const column_generator = ColumnGenerator.init(self.worker_state.generator, load.column);

                        var z = load.z_start;
                        while (z < load.z_end) : (z += 1) {
                            const coords = [3]u30{ load.column[0], load.column[1], z };
                            self.responses.push(self.io, self.allocator, .{
                                .request_id = load.request_id,
                                .coords = coords,
                                .chunk = self.worker_state.loadChunk(self.allocator, &column_generator, coords),
                            });
                        }
                    },
                }
            }
            batch.clearRetainingCapacity();
        }
    }
};

const StoredChunk = struct {
    revision: u32,
    data: *WorldChunkData,
};

const WorkerState = struct {
    generator: WorldGenerator,
    /// The latest snapshots of the chunks modified on the main thread. Everything else is
    /// re-generated on demand. Persistence (not implemented yet) is going to save these.
    modified_chunks: std.AutoHashMapUnmanaged(ChunkPosition, StoredChunk) = .empty,

    fn deinit(self: *WorkerState, allocator: std.mem.Allocator) void {
        var iterator = self.modified_chunks.valueIterator();
        while (iterator.next()) |stored| {
            allocator.destroy(stored.data);
        }
        self.modified_chunks.deinit(allocator);
    }

    fn applyUpdate(self: *WorkerState, allocator: std.mem.Allocator, update: ChunkUpdate) void {
        const entry = self.modified_chunks.getOrPut(allocator, update.position) catch @panic("OOM");
        if (entry.found_existing) {
            if (update.revision <= entry.value_ptr.revision) {
                allocator.destroy(update.data);
                return;
            }
            allocator.destroy(entry.value_ptr.data);
        }

        entry.value_ptr.* = .{
            .revision = update.revision,
            .data = update.data,
        };
    }

    fn loadChunk(
        self: *const WorkerState,
        allocator: std.mem.Allocator,
        column_generator: *const ColumnGenerator,
        coords: [3]u30,
    ) WorldChunk {
        const stored = self.modified_chunks.get(encodeChunkPositionArray(coords)) orelse
            return column_generator.generateChunk(allocator, coords[2]);

        const world_chunk_data = allocator.create(WorldChunkData) catch @panic("OOM");
        world_chunk_data.* = stored.data.*;

        var chunk = WorldChunk.initBlocks(world_chunk_data);
        chunk.revision = stored.revision;
        return chunk;
    }
};

fn waitForResponses(service: *WorldDataService, out: *std.ArrayList(ChunkResponse), count: usize) !void {
    var batch: std.ArrayList(ChunkResponse) = .empty;
    defer batch.deinit(service.allocator);

    while (out.items.len < count) {
        try std.testing.expect(service.responses.waitAndTakeAll(service.io, &batch));
        try out.appendSlice(service.allocator, batch.items);
        batch.clearRetainingCapacity();
    }
    try std.testing.expectEqual(count, out.items.len);
}

fn insertResponses(world: *World, responses: *std.ArrayList(ChunkResponse)) !void {
    for (responses.items) |response| {
        try world.insertChunk(response.coords, response.chunk);
    }
    responses.clearRetainingCapacity();
}

fn deinitResponses(responses: *std.ArrayList(ChunkResponse)) void {
    for (responses.items) |response| {
        response.chunk.content.deinit(std.testing.allocator);
    }
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

test "loaded chunks match the generator" {
    const generator = WorldGenerator{ .terrain = .{ .seed = 12345 } };
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, generator);
    defer service.destroy();

    const request_id = service.requestChunks(.{ 10, 20 }, 2, 6);

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer responses.deinit(std.testing.allocator);
    try waitForResponses(service, &responses, 4);

    const column_generator = ColumnGenerator.init(generator, .{ 10, 20 });
    for (responses.items, 2..) |response, z| {
        defer response.chunk.content.deinit(std.testing.allocator);
        const expected = column_generator.generateChunk(std.testing.allocator, @intCast(z));
        defer expected.content.deinit(std.testing.allocator);

        try std.testing.expectEqual(request_id, response.request_id);
        try std.testing.expectEqual([3]u30{ 10, 20, @intCast(z) }, response.coords);
        try std.testing.expectEqual(std.meta.activeTag(expected.content), std.meta.activeTag(response.chunk.content));
        try std.testing.expectEqual(expected.flags, response.chunk.flags);
        try std.testing.expectEqual(0, response.chunk.revision);
    }
}

test "chunk requested after an update contains it" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .{ .terrain = .{ .seed = 12345 } });
    defer service.destroy();

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer responses.deinit(std.testing.allocator);

    _ = service.requestChunks(.{ 0, 0 }, 0, WORLD_SIZE[2]);
    try waitForResponses(service, &responses, WORLD_SIZE[2]);
    try insertResponses(&world, &responses);

    const top = [3]u32{ 5, 5, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    const removed = (try world.removeTopBlockInColumn(top)).?;
    const chunk_coords, _ = world_module.splitBlockCoords(removed);

    // Same order as the main thread uses: sync, evict and request again without waiting.
    for (world.unsyncedChunks()) |position| {
        const chunk = world.chunks.get(position).?;
        service.submitChunkUpdate(position, chunk.revision, chunk.content.blocks);
    }
    world.markChunksSynced();
    world.removeChunk(chunk_coords);
    _ = service.requestChunks(.{ chunk_coords[0], chunk_coords[1] }, chunk_coords[2], chunk_coords[2] + 1);

    try waitForResponses(service, &responses, 1);
    try insertResponses(&world, &responses);
    try std.testing.expect(!try world.isBlockSolid(removed));
    try std.testing.expectEqual(1, world.getChunk(chunk_coords).?.revision);
}

test "outdated chunk updates are ignored" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();

    const position = encodeChunkPositionArray([3]u30{ 0, 0, 0 });
    var newer = WorldChunkData.initEmpty();
    newer.blocks[0][0][0] = .dirt;
    const older = WorldChunkData.initEmpty();

    service.submitChunkUpdate(position, 2, &newer);
    service.submitChunkUpdate(position, 1, &older);
    _ = service.requestChunks(.{ 0, 0 }, 0, 1);

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer responses.deinit(std.testing.allocator);
    try waitForResponses(service, &responses, 1);

    const chunk = responses.items[0].chunk;
    defer chunk.content.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, chunk.revision);
    try std.testing.expectEqual(.dirt, chunk.content.blocks.blocks[0][0][0]);
}

test "every chunk of a range gets a response and requests are answered in order" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();

    const first_id = service.requestChunks(.{ 1, 2 }, 0, WORLD_SIZE[2]);
    const second_id = service.requestChunks(.{ WORLD_SIZE[0] - 1, WORLD_SIZE[1] - 1 }, WORLD_SIZE[2] - 1, WORLD_SIZE[2]);
    const third_id = service.requestChunks(.{ 1, 2 }, 1, 3);
    try std.testing.expect(first_id < second_id and second_id < third_id);

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(service, &responses, WORLD_SIZE[2] + 1 + 2);

    const requests = [_]struct { u64, [2]u30, u30, u30 }{
        .{ first_id, .{ 1, 2 }, 0, WORLD_SIZE[2] },
        .{ second_id, .{ WORLD_SIZE[0] - 1, WORLD_SIZE[1] - 1 }, WORLD_SIZE[2] - 1, WORLD_SIZE[2] },
        .{ third_id, .{ 1, 2 }, 1, 3 },
    };
    var index: usize = 0;
    for (requests) |request| {
        const request_id, const column, const z_start, const z_end = request;
        for (z_start..z_end) |z| {
            const response = responses.items[index];
            try std.testing.expectEqual(request_id, response.request_id);
            try std.testing.expectEqual([3]u30{ column[0], column[1], @intCast(z) }, response.coords);
            index += 1;
        }
    }
}

test "modified chunks of a range come from their snapshots, the rest is generated" {
    const generator = WorldGenerator{ .terrain = .{ .seed = 12345 } };
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, generator);
    defer service.destroy();

    const column = [2]u30{ 4, 5 };
    const modified_z = WORLD_SIZE[2] / 2;
    var modified = WorldChunkData.initEmpty();
    modified.blocks[1][2][3] = .dirt;
    service.submitChunkUpdate(encodeChunkPositionArray([3]u30{ column[0], column[1], modified_z }), 3, &modified);
    const neighbor = WorldChunkData.initSolid();
    service.submitChunkUpdate(encodeChunkPositionArray([3]u30{ column[0] + 1, column[1], modified_z }), 5, &neighbor);

    _ = service.requestChunks(column, 0, WORLD_SIZE[2]);

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(service, &responses, WORLD_SIZE[2]);

    const column_generator = ColumnGenerator.init(generator, column);
    for (responses.items, 0..) |response, z| {
        const chunk = response.chunk;
        if (z == modified_z) {
            try std.testing.expectEqual(3, chunk.revision);
            try std.testing.expect(chunk.content == .blocks);
            try std.testing.expectEqual(modified.getMetaFlags(), chunk.flags);
            try std.testing.expectEqualSlices(u8, std.mem.asBytes(&modified.blocks), std.mem.asBytes(&chunk.content.blocks.blocks));
        } else {
            const expected = column_generator.generateChunk(std.testing.allocator, @intCast(z));
            defer expected.content.deinit(std.testing.allocator);

            try std.testing.expectEqual(0, chunk.revision);
            try std.testing.expectEqual(std.meta.activeTag(expected.content), std.meta.activeTag(chunk.content));
            try std.testing.expectEqual(expected.flags, chunk.flags);
            try std.testing.expectEqualSlices(
                u8,
                std.mem.asBytes(&expected.content.toData().blocks),
                std.mem.asBytes(&chunk.content.toData().blocks),
            );
        }
    }
}

test "update submitted between two requests of a chunk is contained only in the second response" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();

    const coords = [3]u30{ 7, 8, WORLD_SIZE[2] / 2 - 1 };
    const column = [2]u30{ coords[0], coords[1] };
    const first_id = service.requestChunks(column, coords[2], coords[2] + 1);
    const update = WorldChunkData.initSolid();
    service.submitChunkUpdate(encodeChunkPositionArray(coords), 1, &update);
    const second_id = service.requestChunks(column, coords[2], coords[2] + 1);

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(service, &responses, 2);

    const generated = responses.items[0];
    try std.testing.expectEqual(first_id, generated.request_id);
    try std.testing.expectEqual(0, generated.chunk.revision);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&WorldChunkData.initFlat().blocks),
        std.mem.asBytes(&generated.chunk.content.toData().blocks),
    );

    const updated = responses.items[1];
    try std.testing.expectEqual(second_id, updated.request_id);
    try std.testing.expectEqual(1, updated.chunk.revision);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&update.blocks),
        std.mem.asBytes(&updated.chunk.content.toData().blocks),
    );
}

test "update with the stored revision is ignored, a newer one replaces the snapshot" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();

    const position = encodeChunkPositionArray([3]u30{ 0, 0, 0 });
    var stored = WorldChunkData.initEmpty();
    stored.blocks[0][0][0] = .dirt;
    var same_revision = WorldChunkData.initEmpty();
    same_revision.blocks[0][0][0] = .stone;
    var newer = WorldChunkData.initEmpty();
    newer.blocks[0][0][0] = .grass;

    service.submitChunkUpdate(position, 2, &stored);
    service.submitChunkUpdate(position, 2, &same_revision);
    _ = service.requestChunks(.{ 0, 0 }, 0, 1);
    service.submitChunkUpdate(position, 3, &newer);
    _ = service.requestChunks(.{ 0, 0 }, 0, 1);

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(service, &responses, 2);

    try std.testing.expectEqual(2, responses.items[0].chunk.revision);
    try std.testing.expectEqual(.dirt, responses.items[0].chunk.content.blocks.blocks[0][0][0]);
    try std.testing.expectEqual(3, responses.items[1].chunk.revision);
    try std.testing.expectEqual(.grass, responses.items[1].chunk.content.blocks.blocks[0][0][0]);
}

test "submitted update is a copy of the chunk" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();

    var data = WorldChunkData.initEmpty();
    data.blocks[0][0][0] = .dirt;
    service.submitChunkUpdate(encodeChunkPositionArray([3]u30{ 0, 0, 0 }), 1, &data);
    data.blocks[0][0][0] = .stone;
    _ = service.requestChunks(.{ 0, 0 }, 0, 1);

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(service, &responses, 1);

    try std.testing.expectEqual(.dirt, responses.items[0].chunk.content.blocks.blocks[0][0][0]);
}

test "destroying the service frees the queued requests and the responses nobody took" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .{ .terrain = .{ .seed = 12345 } });

    const update = WorldChunkData.initSolid();
    service.submitChunkUpdate(encodeChunkPositionArray([3]u30{ 0, 0, 0 }), 1, &update);
    for (0..4) |x| {
        _ = service.requestChunks(.{ @intCast(x), 0 }, 0, WORLD_SIZE[2]);
    }
    service.submitChunkUpdate(encodeChunkPositionArray([3]u30{ 0, 0, 0 }), 2, &update);

    service.destroy();
}
