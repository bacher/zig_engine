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
const Side = @import("engine").voxel_chunk.Side;

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

pub const Representation = enum { blocks, mesh };
const ChunkSideData = @import("engine").voxel_chunk.ChunkSideData;
const mesher = @import("./world_engine_glue.zig");

pub const ChunkResponse = struct {
    subscription_id: ?u64,
    coords: [3]u30,
    operation: ?OperationResult = null,
    chunk_revision: u32 = 0,
    mesh_revision: u64 = 0,
    /// Owned by the receiver. A zero-face mesh does not imply empty block contents.
    data: union(enum) { blocks: WorldChunk, mesh: ChunkSideData, acknowledgement },

    pub fn deinit(self: ChunkResponse, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .blocks => |chunk| chunk.content.deinit(allocator),
            .mesh => |mesh| {
                var owned = mesh;
                owned.deinit(allocator);
            },
            .acknowledgement => {},
        }
    }
};

/// One mailbox item is an indivisible update. The renderer applies every response before
/// rebuilding/uploading, so an edit and its neighboring meshes cannot straddle frames.
pub const ResponsePackage = struct {
    responses: std.ArrayList(ChunkResponse) = .empty,

    pub fn deinit(self: *ResponsePackage, allocator: std.mem.Allocator) void {
        for (self.responses.items) |response| response.deinit(allocator);
        self.responses.deinit(allocator);
    }
};

const Subscription = struct {
    id: u64,
    mode: Representation,
    mesh_pending: bool = false,
};

const Request = union(enum) {
    register: *Client,
    load_chunks: struct {
        client: *Client,
        request_id: u64,
        column: [2]u30,
        z_start: u30,
        z_end: u30,
        mode: Representation,
    },
    evict_chunk: struct { client: *Client, position: ChunkPosition, subscription_id: u64 },
    operation: struct { client: *Client, request_id: u64, operation: BlockOperation },
};

/// One endpoint per producer/consumer thread. Endpoints and their queued replies are owned
/// by the service and remain alive until it is destroyed. Stop all clients' tasks first.
pub const Client = struct {
    service: *WorldDataService,
    responses: Mailbox(ResponsePackage) = .{},
    /// Worker-owned package under construction.
    pending: ResponsePackage = .{},
    next_request_id: u64 = 1,
    /// Only accessed by the service worker. Values identify subscription generations.
    subscriptions: std.AutoHashMapUnmanaged(ChunkPosition, Subscription) = .empty,

    fn nextRequestId(self: *Client) u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    /// Loading subscribes to changes until eviction. A new load replaces the old token.
    pub fn requestChunks(self: *Client, column: [2]u30, z_start: u30, z_end: u30) u64 {
        return self.requestChunksInMode(column, z_start, z_end, .blocks);
    }

    pub fn requestChunksInMode(self: *Client, column: [2]u30, z_start: u30, z_end: u30, mode: Representation) u64 {
        std.debug.assert(column[0] < WORLD_SIZE[0] and column[1] < WORLD_SIZE[1]);
        std.debug.assert(z_start < z_end and z_end <= WORLD_SIZE[2]);
        const id = self.nextRequestId();
        self.service.requests.push(self.service.io, self.service.allocator, .{ .load_chunks = .{
            .client = self,
            .request_id = id,
            .column = column,
            .z_start = z_start,
            .z_end = z_end,
            .mode = mode,
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

    /// Sends only intent. Every command gets a result; block-mode replies also carry
    /// a snapshot, including failures. Mesh-mode results share packages with mesh changes.
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

    pub fn takePackages(self: *Client, out: *std.ArrayList(ResponsePackage)) void {
        self.responses.takeAll(self.service.io, out);
    }

    pub fn waitPackages(self: *Client, out: *std.ArrayList(ResponsePackage)) Io.Cancelable!bool {
        return self.responses.waitAndTakeAllCancelable(self.service.io, out);
    }

    /// Block-only consumers can flatten packages; renderers must use takePackages.
    pub fn takeResponses(self: *Client, out: *std.ArrayList(ChunkResponse)) void {
        var packages: std.ArrayList(ResponsePackage) = .empty;
        self.takePackages(&packages);
        self.flattenPackages(&packages, out);
    }

    pub fn waitResponses(self: *Client, out: *std.ArrayList(ChunkResponse)) Io.Cancelable!bool {
        var packages: std.ArrayList(ResponsePackage) = .empty;
        const available = try self.waitPackages(&packages);
        self.flattenPackages(&packages, out);
        return available;
    }

    fn flattenPackages(self: *Client, packages: *std.ArrayList(ResponsePackage), out: *std.ArrayList(ChunkResponse)) void {
        for (packages.items) |*package| {
            out.appendSlice(self.service.allocator, package.responses.items) catch @panic("OOM");
            package.responses.deinit(self.service.allocator);
        }
        packages.deinit(self.service.allocator);
    }

    fn append(self: *Client, response: ChunkResponse) void {
        self.pending.responses.append(self.service.allocator, response) catch @panic("OOM");
    }
};

/// Sole authority for generation, block preconditions and revisions. A single worker orders
/// requests from all clients. Successful operations broadcast the subscribed representation;
/// related snapshots, neighbor meshes, and command results share one update package.
pub const WorldDataService = struct {
    const MeshLoad = struct { client: *Client, coords: [3]u30, token: u64 };
    io: Io,
    allocator: std.mem.Allocator,
    requests: Mailbox(Request) = .{},
    is_shutting_down: std.atomic.Value(bool) = .init(false),
    worker: Io.Future(void),
    /// Accessed only by the worker while running.
    clients: std.ArrayList(*Client) = .empty,
    worker_state: WorkerState,
    mesh_loads: std.ArrayList(MeshLoad) = .empty,
    next_mesh_load: usize = 0,
    dirty_meshes: std.AutoHashMapUnmanaged(ChunkPosition, void) = .empty,

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
            for (client.responses.items.items) |*package| package.deinit(self.allocator);
            client.pending.deinit(self.allocator);
            client.responses.deinit(self.allocator);
            client.subscriptions.deinit(self.allocator);
            self.allocator.destroy(client);
        }
        self.mesh_loads.deinit(self.allocator);
        self.dirty_meshes.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.worker_state.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn runWorker(self: *WorldDataService) void {
        var batch: std.ArrayList(Request) = .empty;
        defer batch.deinit(self.allocator);
        while (true) {
            if (self.next_mesh_load < self.mesh_loads.items.len and !self.is_shutting_down.load(.monotonic)) {
                self.requests.takeAll(self.io, &batch);
            } else if (!self.requests.waitAndTakeAll(self.io, &batch)) break;
            for (batch.items) |request| self.processRequest(request);
            batch.clearRetainingCapacity();
            if (self.is_shutting_down.load(.monotonic)) continue;

            // Coalesce every edited mesh in this batch, including face dependencies, then
            // publish it together with all corresponding block snapshots/acknowledgments.
            var dirty = self.dirty_meshes.keyIterator();
            while (dirty.next()) |position| self.publishMesh(world_module.decodeChunkPosition(position.*));
            self.dirty_meshes.clearRetainingCapacity();
            self.flushPackages();

            // At most one distant load before checking for new edits and block requests.
            if (self.next_mesh_load < self.mesh_loads.items.len) {
                const load = self.mesh_loads.items[self.next_mesh_load];
                self.next_mesh_load += 1;
                if (load.client.subscriptions.get(encodeChunkPositionArray(load.coords))) |sub| {
                    if (sub.id == load.token and sub.mode == .mesh and sub.mesh_pending) self.publishMesh(load.coords);
                }
                if (self.next_mesh_load == self.mesh_loads.items.len) {
                    self.mesh_loads.clearRetainingCapacity();
                    self.next_mesh_load = 0;
                }
                self.flushPackages();
            }
        }
    }

    fn flushPackages(self: *WorldDataService) void {
        // Publish observers before command originators, preserving the useful property
        // that an operation reply follows its observer notifications.
        for ([_]bool{ false, true }) |with_acknowledgment| {
            for (self.clients.items) |client| {
                if (client.pending.responses.items.len == 0) continue;
                var has_acknowledgment = false;
                for (client.pending.responses.items) |response| {
                    has_acknowledgment = has_acknowledgment or response.operation != null;
                }
                if (has_acknowledgment != with_acknowledgment) continue;
                // Certify final block snapshots against the final neighboring inputs too.
                for (client.pending.responses.items) |*response| {
                    if (response.data != .blocks) continue;
                    const current = self.worker_state.modified_chunks.get(encodeChunkPositionArray(response.coords));
                    const revision = if (current) |chunk| chunk.chunk_revision else 0;
                    if (response.chunk_revision == revision) response.mesh_revision = self.worker_state.meshRevision(response.coords);
                }
                client.responses.push(self.io, self.allocator, client.pending);
                client.pending = .{};
            }
        }
    }

    fn blockResponse(self: *WorldDataService, coords: [3]u30, token: ?u64, chunk: WorldChunk) ChunkResponse {
        return .{ .coords = coords, .subscription_id = token, .chunk_revision = chunk.chunk_revision, .mesh_revision = self.worker_state.meshRevision(coords), .data = .{ .blocks = chunk } };
    }

    /// Builds once and fans out owned copies only to mesh subscribers awaiting this state.
    /// Neighbor blocks are temporary dependencies, independent of player subscriptions.
    fn publishMesh(self: *WorldDataService, coords: [3]u30) void {
        const position = encodeChunkPositionArray(coords);
        var needed = false;
        for (self.clients.items) |client| {
            if (client.subscriptions.get(position)) |sub| {
                if (sub.mode == .mesh and sub.mesh_pending) {
                    needed = true;
                    break;
                }
            }
        }
        if (!needed) return;
        const chunk = self.worker_state.loadAt(self.allocator, coords);
        defer chunk.content.deinit(self.allocator);
        var mesh: ChunkSideData = .{};
        if (chunk.content == .blocks and !chunk.flags.is_unreachable) {
            var owned: [6]?WorldChunk = @splat(null);
            defer for (owned) |neighbor| {
                if (neighbor) |value| value.content.deinit(self.allocator);
            };
            var neighbors: [6]mesher.Neighbor = @splat(.exposed);
            for (std.enums.values(Side)) |side| {
                const adjacent = world_module.adjacentChunk(coords, side) orelse continue;
                const i = @intFromEnum(side);
                owned[i] = self.worker_state.loadAt(self.allocator, adjacent);
                neighbors[i] = .{ .content = owned[i].?.content };
            }
            mesh = mesher.extractChunkSideData(self.allocator, chunk.content, neighbors);
        }
        defer mesh.deinit(self.allocator);
        for (self.clients.items) |client| {
            const sub = client.subscriptions.getPtr(position) orelse continue;
            if (sub.mode != .mesh or !sub.mesh_pending) continue;
            client.append(.{ .coords = coords, .subscription_id = sub.id, .chunk_revision = chunk.chunk_revision, .mesh_revision = self.worker_state.meshRevision(coords), .data = .{ .mesh = mesh.clone(self.allocator) } });
            sub.mesh_pending = false;
        }
    }

    fn processRequest(self: *WorldDataService, request: Request) void {
        switch (request) {
            .register => |client| self.clients.append(self.allocator, client) catch @panic("OOM"),
            .evict_chunk => |evict| {
                if (evict.client.subscriptions.get(evict.position)) |sub| {
                    if (sub.id == evict.subscription_id) _ = evict.client.subscriptions.remove(evict.position);
                }
            },
            .load_chunks => |load| {
                if (self.is_shutting_down.load(.monotonic)) return;
                const generator = if (load.mode == .blocks) ColumnGenerator.init(self.worker_state.generator, load.column) else null;
                var z = load.z_start;
                while (z < load.z_end) : (z += 1) {
                    const coords = [3]u30{ load.column[0], load.column[1], z };
                    load.client.subscriptions.put(self.allocator, encodeChunkPositionArray(coords), .{
                        .id = load.request_id,
                        .mode = load.mode,
                        .mesh_pending = load.mode == .mesh,
                    }) catch @panic("OOM");
                    if (generator) |*column| {
                        load.client.append(self.blockResponse(coords, load.request_id, self.worker_state.loadChunk(self.allocator, column, coords)));
                    } else {
                        self.mesh_loads.append(self.allocator, .{ .client = load.client, .coords = coords, .token = load.request_id }) catch @panic("OOM");
                    }
                }
            },
            .operation => |edit| {
                const coords, const local = world_module.splitBlockCoords(edit.operation.block);
                const position = encodeChunkPositionArray(coords);
                const result = self.worker_state.applyOperation(self.allocator, edit.operation);
                defer result.chunk.content.deinit(self.allocator);
                if (self.is_shutting_down.load(.monotonic)) return;
                if (result.status == .success) {
                    var affected: [7]?[3]u30 = @splat(null);
                    affected[6] = coords;
                    for (std.enums.values(Side)) |side| {
                        const i = @intFromEnum(side);
                        if (local[i / 2] == (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1))
                            affected[i] = world_module.adjacentChunk(coords, side);
                    }
                    for (affected, 0..) |entry, i| {
                        const changed = entry orelse continue;
                        const changed_id = encodeChunkPositionArray(changed);
                        self.dirty_meshes.put(self.allocator, changed_id, {}) catch @panic("OOM");
                        for (self.clients.items) |client| {
                            const sub = client.subscriptions.getPtr(changed_id) orelse continue;
                            if (sub.mode == .mesh) {
                                sub.mesh_pending = true;
                            } else if (i < 6 and result.revealed_neighbors[i] != null) {
                                client.append(self.blockResponse(changed, sub.id, self.worker_state.modified_chunks.get(changed_id).?.clone(self.allocator)));
                            } else if (i == 6 and client != edit.client) {
                                client.append(self.blockResponse(changed, sub.id, result.chunk.clone(self.allocator)));
                            }
                        }
                    }
                }
                const sub = edit.client.subscriptions.get(position);
                var response = if (sub != null and sub.?.mode == .mesh)
                    ChunkResponse{ .coords = coords, .subscription_id = sub.?.id, .chunk_revision = result.chunk.chunk_revision, .mesh_revision = self.worker_state.meshRevision(coords), .data = .acknowledgement }
                else
                    self.blockResponse(coords, if (sub) |value| value.id else null, result.chunk.clone(self.allocator));
                response.operation = .{ .request_id = edit.request_id, .status = result.status };
                edit.client.append(response);
            },
        }
    }
};

const WorkerState = struct {
    generator: WorldGenerator,
    /// Committed edits survive cache eviction. Untouched chunks are regenerated on demand.
    modified_chunks: std.AutoHashMapUnmanaged(ChunkPosition, WorldChunk) = .empty,
    /// Retained independently of mesh allocation/subscription lifetime. Untouched inputs
    /// have revision zero; a neighboring edit may advance it without a chunk revision change.
    mesh_revisions: std.AutoHashMapUnmanaged(ChunkPosition, u64) = .empty,
    next_mesh_revision: u64 = 0,
    /// Bounded terrain-height cache, not block or mesh storage. Neighbor meshing otherwise
    /// repeats the same noise calculations for every z coordinate in a column.
    columns: std.AutoHashMapUnmanaged(u64, ColumnGenerator) = .empty,

    fn meshRevision(self: *const WorkerState, coords: [3]u30) u64 {
        return self.mesh_revisions.get(encodeChunkPositionArray(coords)) orelse 0;
    }

    fn loadAt(self: *WorkerState, allocator: std.mem.Allocator, coords: [3]u30) WorldChunk {
        if (self.modified_chunks.get(encodeChunkPositionArray(coords))) |chunk| return chunk.clone(allocator);
        const key = @as(u64, coords[0]) << 32 | coords[1];
        if (!self.columns.contains(key)) {
            if (self.columns.count() >= 64) self.columns.clearRetainingCapacity();
            self.columns.put(allocator, key, ColumnGenerator.init(self.generator, .{ coords[0], coords[1] })) catch @panic("OOM");
        }
        return self.columns.getPtr(key).?.generateChunk(allocator, coords[2]);
    }

    fn deinit(self: *WorkerState, allocator: std.mem.Allocator) void {
        var iterator = self.modified_chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.content.deinit(allocator);
        self.modified_chunks.deinit(allocator);
        self.mesh_revisions.deinit(allocator);
        self.columns.deinit(allocator);
    }

    fn loadChunk(self: *const WorkerState, allocator: std.mem.Allocator, generator: *const ColumnGenerator, coords: [3]u30) WorldChunk {
        if (self.modified_chunks.get(encodeChunkPositionArray(coords))) |chunk| return chunk.clone(allocator);
        return generator.generateChunk(allocator, coords[2]);
    }

    fn applyOperation(self: *WorkerState, allocator: std.mem.Allocator, operation: BlockOperation) struct {
        status: OperationStatus,
        chunk: WorldChunk,
        revealed_neighbors: [6]?[3]u30,
    } {
        const coords, const local = world_module.splitBlockCoords(operation.block);
        const position = encodeChunkPositionArray(coords);
        var chunk = if (self.modified_chunks.get(position)) |stored| stored.clone(allocator) else blk: {
            const generator = ColumnGenerator.init(self.generator, .{ coords[0], coords[1] });
            break :blk generator.generateChunk(allocator, coords[2]);
        };
        const previous_flags = chunk.flags;
        const status = chunk.apply(allocator, local, operation.action);
        var revealed_neighbors: [6]?[3]u30 = @splat(null);
        if (status == .success) {
            chunk.chunk_revision += 1;
            self.next_mesh_revision += 1;
            self.mesh_revisions.put(allocator, position, self.next_mesh_revision) catch @panic("OOM");
            for (std.enums.values(Side)) |side| {
                const i = @intFromEnum(side);
                if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1)) continue;
                const neighbor = world_module.adjacentChunk(coords, side) orelse continue;
                self.mesh_revisions.put(allocator, encodeChunkPositionArray(neighbor), self.next_mesh_revision) catch @panic("OOM");
            }
            const entry = self.modified_chunks.getOrPut(allocator, position) catch @panic("OOM");
            if (entry.found_existing) entry.value_ptr.content.deinit(allocator);
            entry.value_ptr.* = chunk.clone(allocator);
            for (std.enums.values(Side)) |side| {
                if (!previous_flags.getSideSolidness(side) or chunk.flags.getSideSolidness(side)) continue;
                const neighbor = world_module.adjacentChunk(coords, side) orelse continue;
                if (self.revealChunk(allocator, neighbor)) revealed_neighbors[@intFromEnum(side)] = neighbor;
            }
        }
        return .{ .status = status, .chunk = chunk, .revealed_neighbors = revealed_neighbors };
    }

    /// Reveals even an unsubscribed chunk. Its revision makes it dirty, so later loads
    /// use this retained state instead of regenerating the original unreachable flag.
    fn revealChunk(self: *WorkerState, allocator: std.mem.Allocator, coords: [3]u30) bool {
        const position = encodeChunkPositionArray(coords);
        if (self.modified_chunks.getPtr(position)) |chunk| {
            if (!chunk.flags.is_unreachable) return false;
            chunk.flags.is_unreachable = false;
            chunk.chunk_revision += 1;
            return true;
        }
        const generator = ColumnGenerator.init(self.generator, .{ coords[0], coords[1] });
        var chunk = generator.generateChunk(allocator, coords[2]);
        if (!chunk.flags.is_unreachable) {
            chunk.content.deinit(allocator);
            return false;
        }
        chunk.flags.is_unreachable = false;
        chunk.chunk_revision += 1;
        self.modified_chunks.put(allocator, position, chunk) catch @panic("OOM");
        return true;
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
    for (responses.items) |response| response.deinit(std.testing.allocator);
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
        try std.testing.expectEqual(expected.flags, response.data.blocks.flags);
        try std.testing.expectEqual(expected.solid_block_count, response.data.blocks.solid_block_count);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.content.toData()), std.mem.asBytes(&response.data.blocks.content.toData()));
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
        try std.testing.expectEqual(revision, response.data.blocks.chunk_revision);
    }
    try std.testing.expectEqual(.dirt, responses.items[0].data.blocks.content.getBlock(.{ 1, 2, 31 }));
    try std.testing.expectEqual(.dirt, responses.items[1].data.blocks.content.getBlock(.{ 1, 2, 31 }));
    try std.testing.expectEqual(1, responses.items[1].data.blocks.solid_block_count);
    try std.testing.expect(responses.items[2].data.blocks.content == .empty);
    try std.testing.expectEqual(WorldChunk.initEmpty().flags, responses.items[2].data.blocks.flags);
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
    try std.testing.expectEqual(.dirt, observed.items[1].data.blocks.content.getBlock(.{ 0, 0, 0 }));
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
    try std.testing.expectEqual(2, responses.items[2].data.blocks.chunk_revision);
    try std.testing.expect(responses.items[2].data.blocks.content == .empty);
    try std.testing.expectEqual(new_token, responses.items[3].subscription_id);
    try std.testing.expectEqual(3, responses.items[3].data.blocks.chunk_revision);
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
    try std.testing.expectEqual(1, a_responses.items[0].data.blocks.chunk_revision);
    try std.testing.expectEqual(1, b_responses.items[0].data.blocks.chunk_revision);
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
    try std.testing.expectEqual(1, service.worker_state.modified_chunks.get(0).?.chunk_revision);
}

test "losing solid faces retains previously unloaded neighbors as dirty revisions" {
    var state = WorkerState{ .generator = .{ .terrain = .{ .seed = 1, .params = .{ .base_height = 200, .height_amplitude = 0 } } } };
    defer state.deinit(std.testing.allocator);
    const coords = [3]u30{ 0, 2, 3 };
    for (std.enums.values(Side), 0..) |side, index| {
        var local = [3]u32{ 8, 8, 8 };
        local[index / 2] = if (index % 2 == 0) 0 else CHUNK_SIZE - 1;
        const result = state.applyOperation(std.testing.allocator, .{
            .block = .{ coords[0] * CHUNK_SIZE + local[0], coords[1] * CHUNK_SIZE + local[1], coords[2] * CHUNK_SIZE + local[2] },
            .action = .remove,
        });
        defer result.chunk.content.deinit(std.testing.allocator);
        try std.testing.expectEqual(OperationStatus.success, result.status);
        try std.testing.expectEqual(index + 1, result.chunk.chunk_revision);
        for (result.revealed_neighbors, 0..) |neighbor_opt, neighbor_index| {
            if (neighbor_index == index) {
                const neighbor_coords = world_module.adjacentChunk(coords, side).?;
                try std.testing.expectEqual(neighbor_coords, neighbor_opt.?);
                const retained = state.modified_chunks.get(encodeChunkPositionArray(neighbor_coords)).?;
                try std.testing.expect(!retained.flags.is_unreachable);
                try std.testing.expect(retained.isDirty());
                try std.testing.expectEqual(1, retained.chunk_revision);
                try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, retained.solid_block_count);
                const generator = ColumnGenerator.init(state.generator, .{ neighbor_coords[0], neighbor_coords[1] });
                const reloaded = state.loadChunk(std.testing.allocator, &generator, neighbor_coords);
                defer reloaded.content.deinit(std.testing.allocator);
                try std.testing.expectEqual(retained.flags, reloaded.flags);
                try std.testing.expectEqual(retained.chunk_revision, reloaded.chunk_revision);
            } else {
                try std.testing.expectEqual(null, neighbor_opt);
            }
        }
    }
    try std.testing.expectEqual(7, state.modified_chunks.count());

    // Resealing and reopening a wall never hides or revises the revealed neighbor again.
    for ([_]world_module.BlockAction{ .{ .put = .stone }, .remove, .remove }) |action| {
        const result = state.applyOperation(std.testing.allocator, .{
            .block = .{ 0, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 },
            .action = action,
        });
        defer result.chunk.content.deinit(std.testing.allocator);
        for (result.revealed_neighbors) |neighbor| try std.testing.expectEqual(null, neighbor);
    }
    const wrapped_neighbor = state.modified_chunks.get(world_module.encodeChunkPosition(WORLD_SIZE[0] - 1, 2, 3)).?;
    try std.testing.expectEqual(1, wrapped_neighbor.chunk_revision);
    try std.testing.expect(!wrapped_neighbor.flags.is_unreachable);
}

test "interior edits expose no neighbors and a corner reveals three face neighbors" {
    var state = WorkerState{ .generator = .flat };
    defer state.deinit(std.testing.allocator);
    const interior = state.applyOperation(std.testing.allocator, .{
        .block = .{ 8, 2 * CHUNK_SIZE + 8, 2 * CHUNK_SIZE + 8 },
        .action = .remove,
    });
    defer interior.chunk.content.deinit(std.testing.allocator);
    try std.testing.expect(interior.chunk.flags.is_unreachable);
    for (interior.revealed_neighbors) |neighbor| try std.testing.expectEqual(null, neighbor);
    try std.testing.expectEqual(1, state.modified_chunks.count());

    const corner = state.applyOperation(std.testing.allocator, .{
        .block = .{ 0, 2 * CHUNK_SIZE, 2 * CHUNK_SIZE },
        .action = .remove,
    });
    defer corner.chunk.content.deinit(std.testing.allocator);
    for (corner.revealed_neighbors, 0..) |neighbor, side| {
        try std.testing.expectEqual(side % 2 == 0, neighbor != null);
    }
    try std.testing.expectEqual(4, state.modified_chunks.count());
    try std.testing.expect(!state.modified_chunks.contains(world_module.encodeChunkPosition(WORLD_SIZE[0] - 1, 1, 1)));

    // Revealing a previously edited chunk must preserve its blocks and advance its own
    // revision, independently of the operation that opened the neighboring wall.
    const opening = state.applyOperation(std.testing.allocator, .{
        .block = .{ CHUNK_SIZE, 2 * CHUNK_SIZE + 8, 2 * CHUNK_SIZE + 8 },
        .action = .remove,
    });
    defer opening.chunk.content.deinit(std.testing.allocator);
    try std.testing.expectEqual([3]u30{ 0, 2, 2 }, opening.revealed_neighbors[@intFromEnum(Side.left)].?);
    const revealed = state.modified_chunks.get(world_module.encodeChunkPosition(0, 2, 2)).?;
    try std.testing.expectEqual(3, revealed.chunk_revision);
    try std.testing.expect(!revealed.flags.is_unreachable);
    try std.testing.expectEqual(.none, revealed.content.getBlock(.{ 8, 8, 8 }));
    try std.testing.expectEqual(.none, revealed.content.getBlock(.{ 0, 0, 0 }));
    try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE - 2, revealed.solid_block_count);
}

test "reveals notify all neighbor subscribers and survive eviction and reload" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, .flat);
    defer service.destroy();
    const origin = try service.createClient();
    const observer = try service.createClient();
    const other = try service.createClient();
    const coords = [3]u30{ 1, 1, 2 };
    const position = encodeChunkPositionArray(coords);
    const origin_token = origin.requestChunks(.{ 1, 1 }, 2, 3);
    const observer_token = observer.requestChunks(.{ 1, 1 }, 2, 3);
    _ = other.requestChunks(.{ 5, 5 }, 2, 3);
    const edit = origin.submitOperation(.{ .block = .{ CHUNK_SIZE + 8, CHUNK_SIZE + 8, 3 * CHUNK_SIZE }, .action = .remove });
    var origin_responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&origin_responses);
    try waitForResponses(origin, &origin_responses, 3);
    try std.testing.expect(origin_responses.items[0].data.blocks.flags.is_unreachable);
    const reveal = origin_responses.items[1];
    try std.testing.expectEqual(coords, reveal.coords);
    try std.testing.expectEqual(origin_token, reveal.subscription_id);
    try std.testing.expectEqual(null, reveal.operation);
    try std.testing.expect(!reveal.data.blocks.flags.is_unreachable);
    try std.testing.expectEqual(1, reveal.data.blocks.chunk_revision);
    try std.testing.expectEqual(edit, origin_responses.items[2].operation.?.request_id);

    var observed: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&observed);
    observer.takeResponses(&observed);
    try std.testing.expectEqual(2, observed.items.len);
    try std.testing.expectEqual(observer_token, observed.items[1].subscription_id);
    try std.testing.expectEqual(coords, observed.items[1].coords);
    try std.testing.expectEqual(null, observed.items[1].operation);
    try std.testing.expectEqual(1, observed.items[1].data.blocks.chunk_revision);
    try std.testing.expect(!observed.items[1].data.blocks.flags.is_unreachable);
    var unrelated: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&unrelated);
    other.takeResponses(&unrelated);
    try std.testing.expectEqual(1, unrelated.items.len);

    origin.evictChunk(position, origin_token);
    const reload_token = origin.requestChunks(.{ 1, 1 }, 2, 3);
    try waitForResponses(origin, &origin_responses, 4);
    const reload = origin_responses.items[3];
    try std.testing.expectEqual(reload_token, reload.subscription_id);
    try std.testing.expectEqual(1, reload.data.blocks.chunk_revision);
    try std.testing.expect(!reload.data.blocks.flags.is_unreachable);
    try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, reload.data.blocks.solid_block_count);
}

fn takeTestPackages(client: *Client) !std.ArrayList(ResponsePackage) {
    var packages: std.ArrayList(ResponsePackage) = .empty;
    try std.testing.expect(try client.responses.waitAndTakeAllCancelable(client.service.io, &packages));
    return packages;
}

fn deinitTestPackages(packages: *std.ArrayList(ResponsePackage)) void {
    for (packages.items) |*package| package.deinit(std.testing.allocator);
    packages.deinit(std.testing.allocator);
}

test "boundary edits bundle blocks and neighbor meshes with independent revisions across x wrap" {
    const allocator = std.testing.allocator;
    const service = try WorldDataService.create(std.testing.io, allocator, .flat);
    defer service.destroy();
    const client = try service.createClient();
    _ = client.requestChunks(.{ 0, 2 }, 3, 4);
    const neighbor = [3]u30{ WORLD_SIZE[0] - 1, 2, 3 };
    const mesh_token = client.requestChunksInMode(.{ neighbor[0], neighbor[1] }, 3, 4, .mesh);
    var initial: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&initial);
    try waitForResponses(client, &initial, 2);
    const mesh = initial.items[1];
    try std.testing.expect(mesh.data == .mesh);
    try std.testing.expectEqual(0, mesh.data.mesh.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    try std.testing.expectEqual(0, mesh.chunk_revision);
    const edit = client.submitOperation(.{ .block = .{ 0, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 }, .action = .remove });
    var packages = try takeTestPackages(client);
    defer deinitTestPackages(&packages);
    try std.testing.expectEqual(1, packages.items.len);
    const updates = packages.items[0].responses.items;
    try std.testing.expectEqual(2, updates.len);
    try std.testing.expectEqual(edit, updates[0].operation.?.request_id);
    try std.testing.expectEqual(1, updates[0].chunk_revision);
    try std.testing.expectEqual(neighbor, updates[1].coords);
    try std.testing.expectEqual(mesh_token, updates[1].subscription_id);
    try std.testing.expectEqual(0, updates[1].chunk_revision);
    try std.testing.expect(updates[1].mesh_revision > mesh.mesh_revision);
    try std.testing.expectEqual(1, updates[1].data.mesh.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
    try std.testing.expectEqual([3]u8{ 31, 8, 8 }, updates[1].data.mesh.blocks_grouped_by_side[@intFromEnum(Side.right)].items[0].coords);

    const block_token = client.requestChunks(.{ neighbor[0], neighbor[1] }, 3, 4);
    client.evictChunk(encodeChunkPositionArray(neighbor), mesh_token);
    var promoted: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&promoted);
    try waitForResponses(client, &promoted, 1);
    try std.testing.expectEqual(block_token, promoted.items[0].subscription_id);
    try std.testing.expectEqual(updates[1].mesh_revision, promoted.items[0].mesh_revision);
    try std.testing.expectEqual(updates[1].chunk_revision, promoted.items[0].chunk_revision);

    client.evictChunk(encodeChunkPositionArray(neighbor), block_token);
    _ = client.submitOperation(.{ .block = .{ 0, 2 * CHUNK_SIZE + 9, 3 * CHUNK_SIZE + 8 }, .action = .remove });
    var acknowledgments: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&acknowledgments);
    try waitForResponses(client, &acknowledgments, 1);
    _ = client.requestChunksInMode(.{ neighbor[0], neighbor[1] }, 3, 4, .mesh);
    var reloaded: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&reloaded);
    try waitForResponses(client, &reloaded, 1);
    try std.testing.expectEqual(0, reloaded.items[0].chunk_revision);
    try std.testing.expect(reloaded.items[0].mesh_revision > updates[1].mesh_revision);
    try std.testing.expectEqual(2, reloaded.items[0].data.mesh.blocks_grouped_by_side[@intFromEnum(Side.right)].items.len);
}

test "worker coalesces boundary meshes while preserving all operation acknowledgments" {
    const allocator = std.testing.allocator;
    const service = try WorldDataService.create(std.testing.io, allocator, .flat);
    defer service.destroy();
    const client = try service.createClient();
    _ = client.requestChunks(.{ 2, 2 }, 3, 4);
    _ = client.requestChunksInMode(.{ 3, 2 }, 3, 4, .mesh);
    var initial: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&initial);
    try waitForResponses(client, &initial, 2);
    // Submit under one queue lock to make this test's worker batch deterministic.
    service.requests.mutex.lockUncancelable(service.io);
    const operations = [_]BlockOperation{
        .{ .block = .{ 3 * CHUNK_SIZE - 1, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 }, .action = .remove },
        .{ .block = .{ 3 * CHUNK_SIZE - 1, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 }, .action = .{ .put = .dirt } },
        .{ .block = .{ 2 * CHUNK_SIZE + 8, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 }, .action = .remove },
    };
    for (operations) |operation| service.requests.items.append(allocator, .{
        .operation = .{ .client = client, .request_id = client.nextRequestId(), .operation = operation },
    }) catch @panic("OOM");
    service.requests.not_empty.signal(service.io);
    service.requests.mutex.unlock(service.io);
    var packages = try takeTestPackages(client);
    defer deinitTestPackages(&packages);
    try std.testing.expectEqual(1, packages.items.len);
    const updates = packages.items[0].responses.items;
    try std.testing.expectEqual(4, updates.len);
    for (updates[0..3]) |response| try std.testing.expectEqual(OperationStatus.success, response.operation.?.status);
    try std.testing.expectEqual(3, updates[2].chunk_revision);
    try std.testing.expectEqual(0, updates[3].chunk_revision);
    // The interior edit does not invalidate the neighbor; only the two boundary edits do.
    try std.testing.expectEqual(2, updates[3].mesh_revision);
    try std.testing.expectEqual(0, updates[3].data.mesh.blocks_grouped_by_side[@intFromEnum(Side.left)].items.len);
}

test "zero face mesh remains a subscribed solid chunk and updates on reveal" {
    const allocator = std.testing.allocator;
    const service = try WorldDataService.create(std.testing.io, allocator, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const token = client.requestChunksInMode(.{ 2, 2 }, 2, 3, .mesh);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(client, &responses, 1);
    for (responses.items[0].data.mesh.blocks_grouped_by_side) |side| try std.testing.expectEqual(0, side.items.len);
    _ = client.submitOperation(.{ .block = .{ 2 * CHUNK_SIZE + 8, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE }, .action = .remove });
    var packages = try takeTestPackages(client);
    defer deinitTestPackages(&packages);
    var revealed = false;
    for (packages.items[0].responses.items) |response| {
        if (response.subscription_id != token) continue;
        try std.testing.expectEqual(1, response.chunk_revision);
        try std.testing.expectEqual(1, response.data.mesh.blocks_grouped_by_side[@intFromEnum(Side.top)].items.len);
        revealed = true;
    }
    try std.testing.expect(revealed);
    _ = client.requestChunks(.{ 2, 2 }, 2, 3);
    try waitForResponses(client, &responses, 2);
    try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, responses.items[1].data.blocks.solid_block_count);
}

test "default terrain 7x7x7 meshes fit the unchanged GPU allocator including fragmentation" {
    const allocator = std.testing.allocator;
    const service = try WorldDataService.create(std.testing.io, allocator, .{ .terrain = .{ .seed = 12345 } });
    defer service.destroy();
    const client = try service.createClient();
    const origin = @import("./consts.zig").WORLD_ORIGIN;
    for (origin[0] - 3..origin[0] + 4) |x| {
        for (origin[1] - 3..origin[1] + 4) |y| _ = client.requestChunksInMode(.{ @intCast(x), @intCast(y) }, 1, 8, .mesh);
    }
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(client, &responses, 343);
    var grid: @import("engine").VoxelGrid = .{ .allocator = allocator, .gpu_chunk_info_buffer = undefined, .gpu_block_buffer = undefined };
    defer {
        grid.clearChunks();
        grid.chunks.deinit(allocator);
        grid.chunks_to_upload.deinit(allocator);
    }
    var bytes: usize = 0;
    for (responses.items) |response| {
        for (response.data.mesh.blocks_grouped_by_side) |side| bytes += 4 * side.items.len;
        grid.appendChunk(.{ .chunk_coords = response.coords, .chunk_side_data = response.data.mesh.clone(allocator) });
    }
    try std.testing.expect(bytes > 0);
    try std.testing.expect(grid.hasUploadCapacity());
    std.debug.print("7x7x7 terrain: {d} KiB of mesh payload; fits 4 MiB slot allocator\n", .{bytes / 1024});
}
