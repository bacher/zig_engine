pub const persistence = @import("persistence/coordinator.zig");
const format = @import("persistence/format.zig");
const storage = @import("persistence/storage.zig");
const CompactionTask = @import("persistence/compaction.zig").Task;
const save_lifecycle = @import("persistence/save_lifecycle.zig");
const ChunkCoords = @import("engine").ChunkCoords;
const std = @import("std");
const Io = std.Io;
const world_module = @import("./world.zig");
const WorldChunk = world_module.WorldChunk;
const BlockOperation = world_module.BlockOperation;
const OperationStatus = world_module.OperationStatus;
const WorldLayout = @import("engine").WorldLayout;
const test_layout = @import("test_world.zig").layout;
const world_generator = @import("./world_generator.zig");
const WorldGenerator = world_generator.WorldGenerator;
const PreparedWorldGenerator = world_generator.PreparedWorldGenerator;
const ColumnGenerator = world_generator.ColumnGenerator;
const ChunkId = @import("./consts.zig").ChunkId;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WORLD_SIZE = test_layout.size_in_chunks;
const Side = @import("engine").voxel_chunk.Side;
const transformations = @import("block_transformations.zig");
const rules = @import("block_rules.zig");
const standing_space = @import("standing_space.zig");
pub const StandingSpaceRequest = standing_space.Request;
pub const StandingSpaceError = standing_space.Error || error{ServiceStopped};
pub const StandingSpaceResponse = struct {
    request_id: u64,
    result: StandingSpaceError!standing_space.Position,
};

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

        fn tryPush(self: *Self, io: Io, allocator: std.mem.Allocator, item: T) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.is_closed) return error.ServiceStopped;
            try self.items.append(allocator, item);
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
    failure: ?rules.Failure = null,
    mined_type: ?@import("engine").voxel_chunk.BlockType = null,
    counted: bool = false,
    player_inventory: ?struct { player_id: u64, material: ?rules.BlockType } = null,
};

pub const Representation = enum { blocks, mesh };
const ChunkSideData = @import("engine").voxel_chunk.ChunkSideData;
const mesher = @import("./world_engine_glue.zig");
pub const BoundaryMasks = @import("./boundary_mask.zig").BoundaryMasks;

pub const BlockSnapshot = struct {
    chunk: WorldChunk,
    /// Final authoritative neighbor planes, attached when the package is published.
    /// Absent for unsubscribed operation replies and superseded snapshots in a batch.
    neighbors: ?BoundaryMasks = null,
};

pub const ChunkResponse = struct {
    subscription_id: ?u64,
    coords: ChunkCoords,
    operation: ?OperationResult = null,
    chunk_revision: u64 = 0,
    mesh_revision: u64 = 0,
    /// Owned by the receiver. A zero-face mesh does not imply empty block contents.
    data: union(enum) {
        blocks: BlockSnapshot,
        boundaries: BoundaryMasks,
        mesh: ChunkSideData,
        /// Mesh subscription is current, but enclosure makes geometry unnecessary.
        unreachable_chunk,
        acknowledgement,
    },

    pub fn deinit(self: ChunkResponse, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .blocks => |snapshot| snapshot.chunk.deinit(allocator),
            .mesh => |mesh| {
                var owned = mesh;
                owned.deinit(allocator);
            },
            .boundaries, .unreachable_chunk, .acknowledgement => {},
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
    boundaries_pending: bool = false,
    blocks_pending: bool = false,
};

const LoadedChunk = struct { id: u32, revision: u64, result: anyerror!WorldChunk };

const Request = union(enum) {
    register: *Client,
    register_player: format.Player,
    load_chunks: struct {
        client: *Client,
        request_id: u64,
        column: @Vector(2, i32),
        z_start: i32,
        z_end: i32,
        mode: Representation,
        counted: bool = false,
    },
    evict_chunk: struct { client: *Client, position: ChunkId, subscription_id: u64 },
    operation: struct { client: *Client, request_id: u64, operation: BlockOperation, counted: bool = false },
    standing_space: struct { client: *Client, request_id: u64, query: StandingSpaceRequest },
    restore_position: struct { client: *Client, request_id: u64, feet: [3]f64, body: @import("terrain_collision.zig").Body },
    advance_time: transformations.Tick,
    checkpoint: *Client,
    save: struct { id: u64, final: bool },
    cancel_save: u64,
    persistence_event: persistence.Event,
    watchdog,
    compact,
    compaction_done: *CompactionTask,
    chunk_loaded: LoadedChunk,
};

/// One endpoint per producer/consumer thread. Endpoints and their queued replies are owned
/// by the service and remain alive until it is destroyed. Stop all clients' tasks first.
pub const Client = struct {
    service: *WorldDataService,
    responses: Mailbox(ResponsePackage) = .{},
    /// Value-only query replies never consume chunk packages or create subscriptions.
    space_responses: Mailbox(StandingSpaceResponse) = .{},
    /// Worker-owned package under construction.
    pending: ResponsePackage = .{},
    next_request_id: u64 = 1,
    simulation: bool = false,
    resolved_request: u64 = 0,
    last_operation_id: u64 = 0,
    checkpoint_mutex: Io.Mutex = .init,
    checkpoint_queued: bool = false,
    registered_player_id: ?u64 = null,
    latest_checkpoint: ?PlayerCheckpoint = null,
    eligible_checkpoint: ?PlayerCheckpoint = null,

    /// Only accessed by the service worker. Values identify subscription generations.
    subscriptions: std.AutoHashMapUnmanaged(ChunkId, Subscription) = .empty,

    const PlayerCheckpoint = struct { player: format.Player, after_request: u64 };

    fn nextRequestId(self: *Client) u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    /// Ordered with edits from all clients; searches current authoritative blocks.
    /// Only a position/error crosses the endpoint. No chunks or subscriptions escape.
    pub fn requestStandingSpace(self: *Client, query: StandingSpaceRequest) u64 {
        const id = self.nextRequestId();
        self.service.requests.push(self.service.io, self.service.allocator, .{ .standing_space = .{
            .client = self,
            .request_id = id,
            .query = query,
        } });
        return id;
    }

    /// One outstanding search per endpoint. Cancellation stops waiting; an in-flight
    /// worker search can finish, and a later wait discards its small value-only reply.
    /// Existing terrain subscriptions and their queued packages remain untouched.
    pub fn waitStandingSpace(self: *Client, request_id: u64) (Io.Cancelable || StandingSpaceError)!standing_space.Position {
        var replies: std.ArrayList(StandingSpaceResponse) = .empty;
        defer replies.deinit(self.service.allocator);
        while (try self.space_responses.waitAndTakeAllCancelable(self.service.io, &replies)) {
            for (replies.items) |reply|
                if (reply.request_id == request_id) return reply.result;
            replies.clearRetainingCapacity();
        }
        return error.ServiceStopped;
    }

    pub fn findStandingSpace(self: *Client, query: StandingSpaceRequest) (Io.Cancelable || StandingSpaceError)!standing_space.Position {
        return self.waitStandingSpace(self.requestStandingSpace(query));
    }

    /// Ordered after this endpoint's earlier edits, including capture-pending edits.
    pub fn publishCheckpoint(self: *Client, player: format.Player) void {
        self.checkpoint_mutex.lockUncancelable(self.service.io);
        defer self.checkpoint_mutex.unlock(self.service.io);
        if (self.registered_player_id != player.id) {
            // Unlike movement checkpoints, initialization cannot be coalesced
            // behind the first transfer that needs this player's empty slot.
            self.service.requests.tryPush(self.service.io, self.service.allocator, .{ .register_player = player }) catch return;
            self.registered_player_id = player.id;
        }
        self.latest_checkpoint = .{ .player = player, .after_request = self.last_operation_id };
        if (!self.checkpoint_queued) {
            self.service.requests.tryPush(self.service.io, self.service.allocator, .{ .checkpoint = self }) catch return;
            self.checkpoint_queued = true;
        }
    }

    pub fn resolveRestoredPosition(self: *Client, feet: [3]f64, body: @import("terrain_collision.zig").Body) (Io.Cancelable || StandingSpaceError)!standing_space.Position {
        const id = self.nextRequestId();
        self.service.requests.push(self.service.io, self.service.allocator, .{ .restore_position = .{ .client = self, .request_id = id, .feet = feet, .body = body } });
        return self.waitStandingSpace(id);
    }

    /// Loading subscribes to changes until eviction. A new load replaces the old token.
    pub fn requestChunks(self: *Client, column: @Vector(2, i32), z_start: i32, z_end: i32) u64 {
        return self.requestChunksInMode(column, z_start, z_end, .blocks);
    }

    pub fn requestChunksInMode(self: *Client, column: @Vector(2, i32), z_start: i32, z_end: i32, mode: Representation) u64 {
        return self.tryRequestChunksInMode(column, z_start, z_end, mode) catch @panic("terrain load admission exhausted");
    }

    pub fn tryRequestChunksInMode(self: *Client, column: @Vector(2, i32), z_start: i32, z_end: i32, mode: Representation) SubmitError!u64 {
        std.debug.assert(column[0] >= 0 and column[0] < self.service.layout.size_in_chunks[0] and column[1] >= 0 and column[1] < self.service.layout.size_in_chunks[1]);
        std.debug.assert(z_start >= 0 and z_start < z_end and z_end <= self.service.layout.size_in_chunks[2]);
        if (self.service.is_shutting_down.load(.acquire)) return error.ServiceStopped;
        const previous = self.service.outstanding_loads.fetchAdd(1, .acq_rel);
        if (previous >= self.service.limits.pending_commands) {
            _ = self.service.outstanding_loads.fetchSub(1, .release);
            return error.Busy;
        }
        errdefer _ = self.service.outstanding_loads.fetchSub(1, .release);
        const id = self.nextRequestId();
        try self.service.requests.tryPush(self.service.io, self.service.allocator, .{ .load_chunks = .{
            .client = self,
            .request_id = id,
            .column = column,
            .z_start = z_start,
            .z_end = z_end,
            .mode = mode,
            .counted = true,
        } });
        return id;
    }

    pub fn evictChunk(self: *Client, position: ChunkId, subscription_id: u64) void {
        self.service.requests.push(self.service.io, self.service.allocator, .{ .evict_chunk = .{
            .client = self,
            .position = position,
            .subscription_id = subscription_id,
        } });
    }

    /// Sends only intent. Every command gets a result; block-mode replies also carry
    /// a snapshot, including failures. Mesh-mode results share packages with mesh changes.
    /// Commands from this endpoint are processed in submission order.
    pub const SubmitError = error{ Busy, OutOfMemory, ServiceStopped };
    pub fn trySubmitOperation(self: *Client, operation: BlockOperation) SubmitError!u64 {
        operation.validate(self.service.layout);
        if (self.service.is_shutting_down.load(.acquire)) return error.ServiceStopped;
        const previous = self.service.outstanding_operations.fetchAdd(1, .acq_rel);
        if (previous >= self.service.limits.pending_commands) {
            _ = self.service.outstanding_operations.fetchSub(1, .release);
            return error.Busy;
        }
        errdefer _ = self.service.outstanding_operations.fetchSub(1, .release);
        const id = self.next_request_id;
        try self.service.requests.tryPush(self.service.io, self.service.allocator, .{ .operation = .{
            .client = self,
            .request_id = id,
            .operation = operation,
            .counted = true,
        } });
        self.next_request_id += 1;
        self.last_operation_id = id;
        return id;
    }
    pub fn submitOperation(self: *Client, operation: BlockOperation) u64 {
        return self.trySubmitOperation(operation) catch @panic("operation submission requires available endpoint capacity");
    }

    fn consumeSlots(self: *Client, packages: []const ResponsePackage) void {
        for (packages) |package| for (package.responses.items) |response| if (response.operation) |operation| {
            if (operation.counted) _ = self.service.outstanding_operations.fetchSub(1, .release);
        };
    }
    pub fn takePackages(self: *Client, out: *std.ArrayList(ResponsePackage)) void {
        self.responses.takeAll(self.service.io, out);
        self.consumeSlots(out.items);
    }

    pub fn waitPackages(self: *Client, out: *std.ArrayList(ResponsePackage)) Io.Cancelable!bool {
        const available = try self.responses.waitAndTakeAllCancelable(self.service.io, out);
        self.consumeSlots(out.items);
        return available;
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
    const MeshLoad = struct { client: *Client, coords: ChunkCoords, token: u64 };
    layout: *const WorldLayout,
    io: Io,
    allocator: std.mem.Allocator,
    requests: Mailbox(Request) = .{},
    is_shutting_down: std.atomic.Value(bool) = .init(false),
    destroy_requested: std.atomic.Value(bool) = .init(false),
    shutdown_started: bool = false,
    worker: Io.Future(void),
    /// Accessed only by the worker while running.
    clients: std.ArrayList(*Client) = .empty,
    worker_state: WorkerState,
    mesh_loads: std.ArrayList(MeshLoad) = .empty,
    next_mesh_load: usize = 0,
    dirty_meshes: std.AutoHashMapUnmanaged(ChunkId, void) = .empty,
    store: ?*storage.Store = null,
    catalog: ?storage.BaseCatalog = null,
    read_requests: Mailbox(storage.BaseRead) = .{},
    reader: ?Io.Future(void) = null,
    read_pending: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    read_failed: std.AutoHashMapUnmanaged(u32, anyerror) = .empty,
    loaded_ring: std.ArrayList(LoadedChunk) = .empty,
    loaded_head: usize = 0,
    loaded_count: usize = 0,
    async_progress: bool = false,
    completed_compactor: ?*CompactionTask = null,
    pending_tick: std.atomic.Value(u64) = .init(0),
    tick_wakeup: bool = false,

    waiting_reads: std.ArrayList(Request) = .empty,
    retry_reads: std.ArrayList(Request) = .empty,
    read_discovered: bool = false,
    terminal_read_failure: bool = false,
    blocked_dependency_error: ?anyerror = null,
    operation_deferred: bool = false,
    run_write_ids: std.ArrayList(u32) = .empty,
    run_gate_failure: ?anyerror = null,
    processing_since: ?i96 = null,

    store_mutex: Io.Mutex = .init,
    limits: persistence.Limits = .{},
    budget: ?*@import("persistence/budget.zig").Budget = null,
    status_mutex: Io.Mutex = .init,
    status: persistence.Status = .{},
    published_status: persistence.Status = .{},
    job: ?*persistence.Job = null,
    compactor: ?*CompactionTask = null,
    compaction_requested: bool = false,
    completion_ring: std.ArrayList(persistence.Event) = .empty,
    completion_head: usize = 0,
    completion_count: usize = 0,
    capture_epoch: u64 = 0,
    timer_cursor: u32 = 0,
    source_holds: std.AutoHashMapUnmanaged(ChunkId, u64) = .empty,
    wal_revisions: std.AutoHashMapUnmanaged(ChunkId, u64) = .empty,
    base_revisions: std.AutoHashMapUnmanaged(ChunkId, u64) = .empty,
    players: std.AutoHashMapUnmanaged(u64, format.Player) = .empty,
    restored_players: std.AutoHashMapUnmanaged(u64, format.Player) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    next_intent: std.atomic.Value(u64) = .init(1),
    outstanding_operations: std.atomic.Value(usize) = .init(0),
    outstanding_loads: std.atomic.Value(usize) = .init(0),
    simulation_paused: std.atomic.Value(bool) = .init(false),
    watchdog_worker: ?Io.Future(void) = null,
    watchdog_queued: std.atomic.Value(bool) = .init(false),
    watchdog_mutex: Io.Mutex = .init,
    watchdog_wake: Io.Event = .unset,
    watchdog_deadline: ?i96 = null,
    lifecycle: save_lifecycle.Lifecycle = .{},
    player_generation: u64 = 0,
    captured_player_generation: u64 = 0,
    initial_tick: u64 = 0,
    const Pending = struct { request: Request, since: i96 };

    /// Validate/prepare generation before starting the worker. The allocator must
    /// be thread-safe; messages transfer ownership between tasks.
    pub fn create(io: Io, allocator: std.mem.Allocator, layout: *const WorldLayout, generator: WorldGenerator) !*WorldDataService {
        return createConfigured(io, allocator, layout, generator, null, .{});
    }

    pub fn createPersistent(io: Io, allocator: std.mem.Allocator, layout: *const WorldLayout, generator: WorldGenerator, store: *storage.Store, limits: persistence.Limits) !*WorldDataService {
        return createConfigured(io, allocator, layout, generator, store, limits);
    }

    fn createConfigured(io: Io, allocator: std.mem.Allocator, layout: *const WorldLayout, generator: WorldGenerator, store: ?*storage.Store, limits: persistence.Limits) !*WorldDataService {
        const owned_layout = try allocator.create(WorldLayout);
        errdefer allocator.destroy(owned_layout);
        owned_layout.* = layout.*;
        var prepared = try generator.prepare(allocator, owned_layout);
        errdefer prepared.deinit(allocator);
        const self = try allocator.create(WorldDataService);
        errdefer allocator.destroy(self);
        const budget: ?*@import("persistence/budget.zig").Budget = if (store != null) try allocator.create(@import("persistence/budget.zig").Budget) else null;
        errdefer if (budget) |owned| allocator.destroy(owned);
        if (budget) |owned| owned.* = .init(allocator, limits.live_bytes);
        self.* = .{
            .layout = owned_layout,
            .io = io,
            .allocator = allocator,
            .worker = undefined,
            .worker_state = .{ .layout = owned_layout, .generator = prepared, .live_allocator = if (budget) |owned| owned.allocator() else null },
            .budget = budget,
        };
        // No asynchronous task owns self until initialization is complete.
        errdefer if (self.catalog) |*catalog| catalog.deinit();
        errdefer self.players.deinit(allocator);
        errdefer self.restored_players.deinit(allocator);
        self.store = store;
        self.worker_state.persistence_service = self;
        self.limits = limits;
        errdefer self.pending.deinit(allocator);
        errdefer self.waiting_reads.deinit(allocator);
        errdefer self.retry_reads.deinit(allocator);
        try self.pending.ensureTotalCapacityPrecise(allocator, limits.pending_commands);
        const read_capacity = try std.math.mul(usize, limits.pending_commands, 2);
        try self.waiting_reads.ensureTotalCapacityPrecise(allocator, read_capacity);
        try self.retry_reads.ensureTotalCapacityPrecise(allocator, read_capacity);
        self.lifecycle.last_success_ns = persistence.now(io);
        if (store) |saved| {
            self.catalog = try saved.snapshotCatalog();
            self.initial_tick = try format.decodeGlobal(saved.global);
            self.worker_state.tick = self.initial_tick;
            self.worker_state.persistence_service = self;
            self.status.sequence = saved.sequence;
            self.status.durable_sequence = saved.sequence;
            var player_reader: format.Reader = .{ .bytes = saved.players };
            for (0..@intCast(saved.player_count)) |_| {
                const player = try format.readPlayer(&player_reader);
                try self.players.put(allocator, player.id, player);
                try self.restored_players.put(allocator, player.id, player);
            }
        }
        // Start idle background consumers first. If worker startup fails, join
        // every started task before errdefer frees the service and saved catalog.
        if (store != null) self.reader = try io.concurrent(runReader, .{self});
        errdefer if (self.reader) |*reader| {
            self.read_requests.close(io);
            reader.await(io);
        };
        if (store != null) self.watchdog_worker = try io.concurrent(runWatchdog, .{self});
        errdefer if (self.watchdog_worker) |*watchdog| watchdog.cancel(io);
        self.published_status = self.status;
        self.worker = try io.concurrent(runWorker, .{self});
        return self;
    }

    pub fn restoredTick(self: *const WorldDataService) u64 {
        return self.initial_tick;
    }
    pub fn restoredPlayer(self: *const WorldDataService, id: u64) ?format.Player {
        return self.restored_players.get(id);
    }
    pub fn persistenceStatus(self: *WorldDataService) persistence.Status {
        self.status_mutex.lockUncancelable(self.io);
        defer self.status_mutex.unlock(self.io);
        return self.published_status;
    }
    pub fn requestSave(self: *WorldDataService, final: bool) u64 {
        const id = self.next_intent.fetchAdd(1, .monotonic);
        self.requests.push(self.io, self.allocator, .{ .save = .{ .id = id, .final = final } });
        return id;
    }
    pub fn requestCompaction(self: *WorldDataService) void {
        self.requests.push(self.io, self.allocator, .compact);
    }
    pub fn cancelSaveIntent(self: *WorldDataService, id: u64) void {
        self.requests.push(self.io, self.allocator, .{ .cancel_save = id });
    }
    pub fn simulationPaused(self: *const WorldDataService) bool {
        return self.simulation_paused.load(.acquire);
    }
    fn runWatchdog(self: *WorldDataService) void {
        while (true) {
            self.watchdog_mutex.lockUncancelable(self.io);
            const deadline = self.watchdog_deadline;
            self.watchdog_wake.reset();
            self.watchdog_mutex.unlock(self.io);
            const timeout: Io.Timeout = if (deadline) |at| .{ .duration = .{ .raw = .{ .nanoseconds = @max(0, at - persistence.now(self.io)) }, .clock = .awake } } else .none;
            self.watchdog_wake.waitTimeout(self.io, timeout) catch |err| switch (err) {
                error.Canceled => return,
                error.Timeout => {
                    self.watchdog_mutex.lockUncancelable(self.io);
                    const selected = self.watchdog_deadline == deadline;
                    if (selected) self.watchdog_deadline = null;
                    self.watchdog_mutex.unlock(self.io);
                    if (selected and deadline != null) self.requests.push(self.io, self.allocator, .watchdog);
                },
            };
        }
    }
    fn scheduleWatchdog(self: *WorldDataService) void {
        if (self.store == null) return;
        const next = self.lifecycle.nextDeadline(self.lifecycleDeadlines(), self.lifecycleDeadlineObservations());
        self.watchdog_mutex.lockUncancelable(self.io);
        if (self.watchdog_deadline != next) {
            self.watchdog_deadline = next;
            self.watchdog_wake.set(self.io);
        }
        self.watchdog_mutex.unlock(self.io);
    }

    fn lifecycleDeadlines(self: *const WorldDataService) save_lifecycle.Deadlines {
        return .{ .capture_wait_ns = self.limits.capture_wait_ns, .player_wait_ns = self.limits.player_wait_ns, .overdue_ns = self.limits.overdue_ns };
    }

    fn lifecycleObservations(self: *WorldDataService) save_lifecycle.Observations {
        return .{
            .source_holds = self.source_holds.count(),
            .pending_commands = self.pending.items.len,
            .pending_reads = self.read_pending.count(),
            .waiting_queries = self.waiting_reads.items.len,
            .compactor_active = self.compactor != null,
        };
    }

    fn lifecycleDeadlineObservations(self: *WorldDataService) save_lifecycle.Observations {
        var observed = self.lifecycleObservations();
        if (observed.source_holds != 0) observed.oldest_player_wait = self.oldestPlayerWait();
        return observed;
    }

    pub fn createClient(self: *WorldDataService) !*Client {
        const client = try self.allocator.create(Client);
        client.* = .{ .service = self };
        self.requests.push(self.io, self.allocator, .{ .register = client });
        return client;
    }

    /// The game owns simulation time. Pausing or stopping frames does not advance it;
    /// subscriptions and mesh/block eviction have no effect on transformation deadlines.
    pub fn advanceTo(self: *WorldDataService, tick: transformations.Tick) void {
        _ = self.pending_tick.fetchMax(tick, .release);
        self.requests.mutex.lockUncancelable(self.io);
        self.tick_wakeup = true;
        self.requests.not_empty.signal(self.io);
        self.requests.mutex.unlock(self.io);
    }

    /// Call after all producers have stopped. Drains submitted edits, skips pending loads,
    /// and frees replies that nobody consumed.
    pub fn destroy(self: *WorldDataService) void {
        if (self.watchdog_worker) |*watchdog| watchdog.cancel(self.io);
        // This signal needs no allocation and never touches worker-owned pointers.
        // The authority cancels/joins background jobs while continuing to receive
        // their source releases and reads; only then may queues/storage be freed.
        self.requests.mutex.lockUncancelable(self.io);
        self.destroy_requested.store(true, .release);
        self.requests.not_empty.signal(self.io);
        self.requests.mutex.unlock(self.io);
        self.worker.await(self.io);
        self.read_requests.close(self.io);
        if (self.reader) |*reader| reader.await(self.io);
        self.requests.close(self.io);
        for (self.clients.items) |client| {
            for (client.responses.items.items) |*package| package.deinit(self.allocator);
            client.pending.deinit(self.allocator);
            client.responses.deinit(self.allocator);
            client.space_responses.deinit(self.allocator);
            client.subscriptions.deinit(self.allocator);
            self.allocator.destroy(client);
        }
        if (self.job) |job| job.deinit();
        self.completion_ring.deinit(self.allocator);
        self.source_holds.deinit(self.allocator);
        self.wal_revisions.deinit(self.allocator);
        self.base_revisions.deinit(self.allocator);
        self.players.deinit(self.allocator);
        self.restored_players.deinit(self.allocator);
        self.run_write_ids.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.waiting_reads.deinit(self.allocator);
        self.retry_reads.deinit(self.allocator);
        self.read_pending.deinit(self.allocator);
        self.read_failed.deinit(self.allocator);
        self.loaded_ring.deinit(self.allocator);
        self.read_requests.deinit(self.allocator);
        if (self.catalog) |*catalog| catalog.deinit();
        self.mesh_loads.deinit(self.allocator);
        self.dirty_meshes.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.worker_state.deinit(self.allocator);
        if (self.budget) |budget| {
            std.debug.assert(budget.stats().used == 0);
            self.allocator.destroy(budget);
        }
        self.allocator.destroy(@constCast(self.layout));
        self.allocator.destroy(self);
    }

    fn runWorker(self: *WorldDataService) void {
        defer for (self.clients.items) |client| client.space_responses.close(self.io);
        var batch: std.ArrayList(Request) = .empty;
        defer batch.deinit(self.allocator);
        while (true) {
            if (self.destroy_requested.load(.acquire) and !self.shutdown_started) {
                self.shutdown_started = true;
                self.is_shutting_down.store(true, .release);
                self.lifecycle.queued = null;
                self.compaction_requested = false;
                if (self.job) |job| job.cancel();
                if (self.compactor) |compactor| compactor.cancel();
            }
            self.async_progress = false;
            self.drainPersistenceEvents();
            if (self.shutdown_started and self.job == null and self.compactor == null and self.read_pending.count() == 0) {
                // Producers have stopped. Process the last accepted queue before
                // ending, including registration and terminal read completions.
                self.requests.takeAll(self.io, &batch);
                if (batch.items.len == 0) break;
            } else if (self.async_progress or (self.next_mesh_load < self.mesh_loads.items.len and !self.is_shutting_down.load(.monotonic))) {
                self.requests.takeAll(self.io, &batch);
            } else if (!self.waitForWork(&batch)) break;
            self.drainPersistenceEvents();
            for (batch.items) |request| {
                self.processRequest(request);
                self.publishPersistenceStatus();
            }
            batch.clearRetainingCapacity();
            if (self.is_shutting_down.load(.monotonic)) continue;
            self.processTransformations();

            // Coalesce every edited mesh in this batch, including face dependencies, then
            // publish it together with all corresponding block snapshots/acknowledgments.
            var dirty = self.dirty_meshes.keyIterator();
            while (dirty.next()) |position| self.publishMesh(self.layout.decodeChunkId(position.*));
            self.dirty_meshes.clearRetainingCapacity();
            for (self.clients.items) |client| {
                var subscriptions = client.subscriptions.iterator();
                while (subscriptions.next()) |entry| if (entry.value_ptr.mode == .mesh and entry.value_ptr.mesh_pending)
                    self.dirty_meshes.put(self.allocator, entry.key_ptr.*, {}) catch self.failPersistence(error.OutOfMemory);
            }
            self.flushPackages();
            self.publishPersistenceStatus();

            // At most one distant load before checking for new edits and block requests.
            if (self.next_mesh_load < self.mesh_loads.items.len) {
                const load = self.mesh_loads.items[self.next_mesh_load];
                self.next_mesh_load += 1;
                if (load.client.subscriptions.get(self.layout.encodeChunkCoords(load.coords))) |sub| {
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
            clients: for (self.clients.items) |client| {
                var has_acknowledgment = false;
                for (client.pending.responses.items) |response| {
                    has_acknowledgment = has_acknowledgment or response.operation != null;
                }
                if (has_acknowledgment != with_acknowledgment) continue;
                // Observer snapshots coalesce to the final authoritative state in this
                // batch. Retain the subscription intent until owned delivery is secured.
                var blocks = client.subscriptions.iterator();
                while (blocks.next()) |entry| {
                    const sub = entry.value_ptr;
                    if (sub.mode != .blocks or !sub.blocks_pending) continue;
                    const coords = self.layout.decodeChunkId(entry.key_ptr.*);
                    client.pending.responses.ensureUnusedCapacity(self.allocator, 1) catch continue :clients;
                    const chunk = self.worker_state.tryLoadAt(self.allocator, coords) catch continue :clients;
                    client.pending.responses.appendAssumeCapacity(self.blockResponse(coords, sub.id, chunk));
                    sub.blocks_pending = false;
                }
                // Certify final block snapshots against the final neighboring inputs too.
                for (client.pending.responses.items) |*response| {
                    if (response.data != .blocks) continue;
                    const current = self.worker_state.modified_chunks.get(self.layout.encodeChunkCoords(response.coords));
                    const revision = if (current) |chunk| chunk.chunk_revision else 0;
                    if (response.chunk_revision != revision) continue;
                    response.mesh_revision = self.worker_state.meshRevision(response.coords);
                    const sub = client.subscriptions.getPtr(self.layout.encodeChunkCoords(response.coords)) orelse continue;
                    if (sub.mode != .blocks or sub.id != response.subscription_id) continue;
                    response.data.blocks.neighbors = self.worker_state.tryNeighborBoundaries(self.allocator, response.coords) catch continue :clients;
                    sub.boundaries_pending = false;
                }
                // Coalesce neighbor-only edits, including changes outside this client's
                // block subscriptions, without copying the unchanged block array again.
                var subscriptions = client.subscriptions.iterator();
                while (subscriptions.next()) |entry| {
                    const sub = entry.value_ptr;
                    if (sub.mode != .blocks or !sub.boundaries_pending) continue;
                    const coords = self.layout.decodeChunkId(entry.key_ptr.*);
                    const boundaries = self.worker_state.tryNeighborBoundaries(self.allocator, coords) catch continue :clients;
                    client.pending.responses.append(self.allocator, .{
                        .coords = coords,
                        .subscription_id = sub.id,
                        .mesh_revision = self.worker_state.meshRevision(coords),
                        .data = .{ .boundaries = boundaries },
                    }) catch continue :clients;
                    sub.boundaries_pending = false;
                }
                if (client.pending.responses.items.len == 0) continue;
                client.responses.tryPush(self.io, self.allocator, client.pending) catch continue :clients;
                client.pending = .{};
            }
        }
    }

    fn blockResponse(self: *WorldDataService, coords: ChunkCoords, token: ?u64, chunk: WorldChunk) ChunkResponse {
        return .{ .coords = coords, .subscription_id = token, .chunk_revision = chunk.chunk_revision, .mesh_revision = self.worker_state.meshRevision(coords), .data = .{ .blocks = .{ .chunk = chunk } } };
    }

    /// Builds once and fans out owned copies only to mesh subscribers awaiting this state.
    /// Neighbor blocks are temporary dependencies, independent of player subscriptions.
    fn publishMesh(self: *WorldDataService, coords: ChunkCoords) void {
        const position = self.layout.encodeChunkCoords(coords);
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
        const chunk = self.worker_state.tryLoadAt(self.allocator, coords) catch return;
        defer chunk.deinit(self.allocator);
        var mesh: ChunkSideData = .{};
        if (chunk.content == .blocks and !chunk.flags.is_unreachable) {
            const neighbors = self.worker_state.tryNeighborBoundaries(self.allocator, coords) catch return;
            mesh = mesher.tryExtractChunkGeometry(self.allocator, chunk, neighbors) catch return;
        }
        defer mesh.deinit(self.allocator);
        for (self.clients.items) |client| {
            const sub = client.subscriptions.getPtr(position) orelse continue;
            if (sub.mode != .mesh or !sub.mesh_pending) continue;
            // Secure the response slot before cloning so failure retains mesh_pending.
            client.pending.responses.ensureUnusedCapacity(self.allocator, 1) catch continue;
            const copy: ChunkSideData = if (chunk.flags.is_unreachable) .{} else mesh.tryClone(self.allocator) catch continue;
            client.pending.responses.appendAssumeCapacity(.{
                .coords = coords,
                .subscription_id = sub.id,
                .chunk_revision = chunk.chunk_revision,
                .mesh_revision = self.worker_state.meshRevision(coords),
                .data = if (chunk.flags.is_unreachable) .unreachable_chunk else .{ .mesh = copy },
            });
            sub.mesh_pending = false;
        }
    }

    fn deferRead(self: *WorldDataService, request: Request) void {
        var queries: usize = 0;
        for (self.waiting_reads.items) |read| if (read != .load_chunks) {
            queries += 1;
        };
        if (request == .load_chunks or queries < self.limits.pending_commands) {
            self.waiting_reads.append(self.allocator, request) catch {
                self.rejectRead(request);
            };
        } else self.rejectRead(request);
    }
    fn rejectRead(self: *WorldDataService, request: Request) void {
        self.failPersistence(error.OutOfMemory);
        switch (request) {
            .restore_position => |read| read.client.space_responses.tryPush(self.io, self.allocator, .{ .request_id = read.request_id, .result = error.MissingData }) catch {},
            .standing_space => |read| read.client.space_responses.tryPush(self.io, self.allocator, .{ .request_id = read.request_id, .result = error.MissingData }) catch {},
            else => {},
        }
    }
    fn retryWaitingReads(self: *WorldDataService) void {
        std.debug.assert(self.retry_reads.items.len == 0);
        std.mem.swap(std.ArrayList(Request), &self.waiting_reads, &self.retry_reads);
        defer self.retry_reads.clearRetainingCapacity();
        for (self.retry_reads.items) |read| self.processRequest(read);
    }

    fn isRetryableReadFailure(err: anyerror) bool {
        return save_lifecycle.Lifecycle.isRetryableReadFailure(err);
    }

    /// Select the command prefix before restarting reads: progress may resolve an
    /// operation immediately, so the fence must already belong to this attempt.
    fn requestSaveTransition(self: *WorldDataService, id: u64, final: bool) void {
        if (self.lifecycle.request(.{ .id = id, .final = final }, self.pending.items.len) == .none) return;
        self.selectSaveDrain();
        self.retrySaveDrain();
    }

    /// Every explicit/automatic retry must wake both read queries and mutation
    /// dependency discovery; neither queue can rely on another completion arriving.
    fn retrySaveDrain(self: *WorldDataService) void {
        self.retryReadFailures();
        self.retryWaitingReads();
        self.retryPending();
    }

    fn selectSaveDrain(self: *WorldDataService) void {
        const save = self.lifecycle.selectDrain() orelse return;
        self.status.intent_id = save.id;
        self.status.target_sequence = 0;
        self.status.phase = .capturing;
        self.status.active = true;
        self.status.error_name = null;
    }

    fn reportAttemptPhase(self: *WorldDataService) void {
        const attempt = self.lifecycle.active.?;
        self.status.phase = switch (attempt.stage) {
            .capturing => .capturing,
            .writing => .writing,
            .finalizing => if (attempt.intent.final) .compacting else .writing,
        };
    }

    fn noteDrainFailure(self: *WorldDataService, err: anyerror) void {
        self.selectSaveDrain();
        self.failPersistence(err);
        if (self.lifecycle.dependencyFailed(err, persistence.now(self.io))) self.status.active = true;
    }

    fn retryReadFailures(self: *WorldDataService) void {
        while (true) {
            var failures = self.read_failed.iterator();
            var retry: ?u32 = null;
            while (failures.next()) |entry| {
                if (isRetryableReadFailure(entry.value_ptr.*)) {
                    retry = entry.key_ptr.*;
                    break;
                }
            }
            _ = self.read_failed.remove(retry orelse break);
        }
    }

    fn processRequest(self: *WorldDataService, request: Request) void {
        // Only mutations/checkpoints join the retained FIFO. Reads and completions always progress.
        const ordered = request == .operation;
        if (request == .load_chunks and self.is_shutting_down.load(.acquire)) {
            if (request.load_chunks.counted) _ = self.outstanding_loads.fetchSub(1, .release);
            return;
        }
        if (request == .load_chunks or request == .standing_space or request == .restore_position) {
            self.blocked_dependency_error = null;
            if (!self.dependenciesReady(request)) {
                self.deferRead(request);
                if (self.blocked_dependency_error) |err| self.noteDrainFailure(err);
                return;
            }
        }
        // Discover and prioritize the player's dependencies even behind a FIFO head.
        const dependencies_ready = if (ordered) self.dependenciesReady(request) else true;
        const admission_ready = if (ordered) self.admissible(request) else true;
        if (ordered and (self.pending.items.len != 0 or !dependencies_ready or !admission_ready)) {
            if (!request.operation.client.simulation) {
                if (self.source_holds.count() != 0) self.status.capture_waited_operations +%= 1 else if (self.read_pending.count() != 0) self.status.dependency_waited_operations +%= 1;
            }
            self.pending.append(self.allocator, .{ .request = request, .since = persistence.now(self.io) }) catch @panic("OOM");
            return;
        }
        self.processAdmitted(request);
    }

    fn processAdmitted(self: *WorldDataService, request: Request) void {
        switch (request) {
            .register_player => |initial| {
                if (!self.players.contains(initial.id)) {
                    var player = initial;
                    player.inventory = null;
                    self.players.put(self.allocator, player.id, player) catch {
                        self.failPersistence(error.OutOfMemory);
                        return;
                    };
                    self.player_generation +%= 1;
                    self.lifecycle.unsaved_work = true;
                }
            },
            .chunk_loaded => |loaded| {
                _ = self.read_pending.remove(loaded.id);
                if (loaded.result) |chunk| {
                    const current_revision = self.worker_state.modified_chunks.get(loaded.id);
                    if (current_revision != null or (self.catalog.?.revision(loaded.id) orelse 0) != loaded.revision) {
                        chunk.deinit(self.worker_state.liveAllocator(self.allocator));
                    } else {
                        self.installLoaded(loaded.id, loaded.revision, chunk) catch |err| {
                            chunk.deinit(self.worker_state.liveAllocator(self.allocator));
                            self.read_failed.put(self.allocator, loaded.id, err) catch {};
                            self.noteDrainFailure(err);
                        };
                    }
                } else |err| {
                    self.read_failed.put(self.allocator, loaded.id, err) catch {};
                    self.noteDrainFailure(err);
                }
                const loaded_coords = self.layout.decodeChunkId(loaded.id);
                self.dirty_meshes.put(self.allocator, loaded.id, {}) catch self.failPersistence(error.OutOfMemory);
                for (std.enums.values(Side)) |side| if (world_module.adjacentChunk(self.layout, loaded_coords, side)) |neighbor| {
                    self.dirty_meshes.put(self.allocator, self.layout.encodeChunkCoords(neighbor), {}) catch self.failPersistence(error.OutOfMemory);
                };
                self.retryPending();
                self.retryWaitingReads();
            },
            .checkpoint => |client| {
                client.checkpoint_mutex.lockUncancelable(self.io);
                client.eligible_checkpoint = client.latest_checkpoint;
                client.latest_checkpoint = null;
                client.checkpoint_queued = false;
                client.checkpoint_mutex.unlock(self.io);
                self.applyEligibleCheckpoint(client);
            },
            .save => |save| self.requestSaveTransition(save.id, save.final),
            .cancel_save => |id| {
                if (self.lifecycle.cancel(id)) if (self.job) |job| job.cancel();
            },
            .compact => {
                self.compaction_requested = true;
                self.beginCompaction() catch |err| self.failPersistence(err);
            },
            .compaction_done => |task| self.finishCompaction(task),
            .watchdog => {
                self.watchdog_queued.store(false, .release);
                self.checkWatchdog();
            },
            .persistence_event => |event| self.persistenceEvent(event),
            .restore_position => |restore| {
                self.read_discovered = false;
                self.terminal_read_failure = false;
                const result = self.worker_state.resolveRestoredPosition(self.allocator, restore.feet, restore.body);
                if (self.terminal_read_failure) {
                    restore.client.space_responses.push(self.io, self.allocator, .{ .request_id = restore.request_id, .result = error.MissingData });
                    return;
                }
                if (self.read_discovered) {
                    self.deferRead(request);
                    return;
                }
                restore.client.space_responses.push(self.io, self.allocator, .{ .request_id = restore.request_id, .result = result });
            },
            .standing_space => |search| {
                self.read_discovered = false;
                self.terminal_read_failure = false;
                const result: StandingSpaceError!standing_space.Position = if (self.is_shutting_down.load(.monotonic))
                    error.ServiceStopped
                else
                    self.worker_state.findStandingSpace(self.allocator, search.query);
                if (self.terminal_read_failure) {
                    search.client.space_responses.push(self.io, self.allocator, .{ .request_id = search.request_id, .result = error.MissingData });
                    return;
                }
                if (self.read_discovered) {
                    self.deferRead(request);
                    return;
                }
                search.client.space_responses.push(self.io, self.allocator, .{ .request_id = search.request_id, .result = result });
            },
            .advance_time => |tick| self.worker_state.tick = @max(self.worker_state.tick, tick),
            .register => |client| self.clients.append(self.allocator, client) catch @panic("OOM"),
            .evict_chunk => |evict| {
                if (evict.client.subscriptions.get(evict.position)) |sub| {
                    if (sub.id == evict.subscription_id) _ = evict.client.subscriptions.remove(evict.position);
                    self.evictEligible();
                }
            },
            .load_chunks => |load| {
                if (load.counted) _ = self.outstanding_loads.fetchSub(1, .release);
                if (self.is_shutting_down.load(.monotonic)) return;
                var z = load.z_start;
                while (z < load.z_end) : (z += 1) {
                    const coords = ChunkCoords{ load.column[0], load.column[1], z };
                    load.client.subscriptions.put(self.allocator, self.layout.encodeChunkCoords(coords), .{
                        .id = load.request_id,
                        .mode = load.mode,
                        .mesh_pending = load.mode == .mesh,
                    }) catch {
                        self.failPersistence(error.OutOfMemory);
                        continue;
                    };
                    if (load.mode == .blocks) {
                        load.client.pending.responses.ensureUnusedCapacity(self.allocator, 1) catch {
                            load.client.subscriptions.getPtr(self.layout.encodeChunkCoords(coords)).?.blocks_pending = true;
                            continue;
                        };
                        const chunk = self.worker_state.tryLoadAt(self.allocator, coords) catch {
                            load.client.subscriptions.getPtr(self.layout.encodeChunkCoords(coords)).?.blocks_pending = true;
                            continue;
                        };
                        load.client.pending.responses.appendAssumeCapacity(self.blockResponse(coords, load.request_id, chunk));
                    } else {
                        self.mesh_loads.append(self.allocator, .{ .client = load.client, .coords = coords, .token = load.request_id }) catch {
                            self.failPersistence(error.OutOfMemory);
                        };
                    }
                }
            },
            .operation => |edit| {
                const coords, const local = world_module.splitBlockCoords(edit.operation.block);
                const position = self.layout.encodeChunkCoords(coords);
                self.read_discovered = false;
                self.operation_deferred = false;
                edit.client.pending.responses.ensureUnusedCapacity(self.allocator, 1) catch {
                    self.pending.insert(self.allocator, 0, .{ .request = request, .since = self.processing_since orelse persistence.now(self.io) }) catch @panic("OOM");
                    self.operation_deferred = true;
                    self.failPersistence(error.OutOfMemory);
                    return;
                };
                const result = self.worker_state.applyOperation(self.allocator, edit.operation);
                var reply_moved = false;
                defer if (!reply_moved) result.chunk.deinit(self.allocator);
                if (self.read_discovered or self.operation_deferred) {
                    self.pending.insert(self.allocator, 0, .{ .request = request, .since = self.processing_since orelse persistence.now(self.io) }) catch @panic("OOM");
                    return;
                }
                if (result.status == .success) {
                    if (edit.operation.player) |transfer| {
                        // The player record exists and was checked before the terrain
                        // commit. This part of the same service turn cannot allocate.
                        const player = self.players.getPtr(transfer.id).?;
                        player.inventory = if (edit.operation.action == .remove) @intFromEnum(result.diagnostics.mined_type.?) else null;
                        self.player_generation +%= 1;
                    }
                    self.lifecycle.unsaved_work = true;
                }
                if (self.is_shutting_down.load(.monotonic)) {
                    if (edit.counted) _ = self.outstanding_operations.fetchSub(1, .release);
                    edit.client.resolved_request = edit.request_id;
                    return;
                }
                if (result.status == .success) {
                    for (self.worker_state.road_changes.items) |id| {
                        if (id != position) self.publishMaterialChange(self.layout.decodeChunkId(id));
                    }
                    var affected: [7]?ChunkCoords = @splat(null);
                    affected[6] = coords;
                    for (std.enums.values(Side)) |side| {
                        const i = @intFromEnum(side);
                        if (local[i / 2] == (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1))
                            affected[i] = world_module.adjacentChunk(self.layout, coords, side);
                    }
                    if (result.changed_below) |below| {
                        if (!@reduce(.And, below == coords)) self.publishMaterialChange(below);
                    }
                    for (affected, 0..) |entry, i| {
                        const changed = entry orelse continue;
                        const changed_id = self.layout.encodeChunkCoords(changed);
                        self.dirty_meshes.put(self.allocator, changed_id, {}) catch @panic("OOM");
                        for (self.clients.items) |client| {
                            const sub = client.subscriptions.getPtr(changed_id) orelse continue;
                            if (sub.mode == .blocks and i < 6) sub.boundaries_pending = true;
                            if (sub.mode == .mesh) {
                                sub.mesh_pending = true;
                            } else if ((i < 6 and result.revealed_neighbors[i] != null) or (i == 6 and client != edit.client)) {
                                sub.blocks_pending = true;
                            }
                        }
                    }
                }
                const sub = edit.client.subscriptions.get(position);
                var response = if (result.status == .resource_exhausted or (sub != null and sub.?.mode == .mesh))
                    ChunkResponse{ .coords = coords, .subscription_id = if (sub) |value| value.id else null, .chunk_revision = result.chunk.chunk_revision, .mesh_revision = self.worker_state.meshRevision(coords), .data = .acknowledgement }
                else
                    self.blockResponse(coords, if (sub) |value| value.id else null, result.chunk);
                if (response.data == .blocks) reply_moved = true;
                response.operation = .{ .request_id = edit.request_id, .status = result.status, .failure = result.diagnostics.failure, .mined_type = result.diagnostics.mined_type, .counted = edit.counted };
                if (edit.operation.player) |transfer| {
                    const player = self.players.get(transfer.id);
                    const material = if (player) |p| p.inventory else null;
                    response.operation.?.player_inventory = .{ .player_id = transfer.id, .material = if (material) |raw| @enumFromInt(raw) else null };
                }
                edit.client.pending.responses.appendAssumeCapacity(response);
                edit.client.resolved_request = edit.request_id;
                self.status.confirmed_operations +%= 1;
                if (!edit.client.simulation) if (self.processing_since) |since| {
                    const waited: u64 = @intCast(@min(std.math.maxInt(u64), @max(0, persistence.now(self.io) - since)));
                    self.status.max_player_wait_ns = @max(self.status.max_player_wait_ns, waited);
                    self.status.total_player_wait_ns +|= waited;
                };
                self.applyEligibleCheckpoint(edit.client);
            },
        }
    }

    fn publishMaterialChange(self: *WorldDataService, coords: ChunkCoords) void {
        const id = self.layout.encodeChunkCoords(coords);
        self.dirty_meshes.put(self.allocator, id, {}) catch @panic("OOM");
        for (self.clients.items) |client| {
            const sub = client.subscriptions.getPtr(id) orelse continue;
            if (sub.mode == .mesh) {
                sub.mesh_pending = true;
            } else sub.blocks_pending = true;
        }
    }

    fn applyEligibleCheckpoint(self: *WorldDataService, client: *Client) void {
        const checkpoint = client.eligible_checkpoint orelse return;
        if (client.resolved_request < checkpoint.after_request) return;
        const old = self.players.get(checkpoint.player.id);
        var player = checkpoint.player;
        // Checkpoints publish movement only. A delayed optimistic client checkpoint
        // must never overwrite inventory owned by accepted world operations.
        player.inventory = if (old) |saved| saved.inventory else null;
        if (old == null or !std.meta.eql(old.?, player)) {
            self.players.put(self.allocator, player.id, player) catch {
                self.failPersistence(error.OutOfMemory);
                return;
            };
            self.player_generation +%= 1;
            self.lifecycle.unsaved_work = true;
        }
        client.eligible_checkpoint = null;
    }

    fn notifyCompaction(context: *anyopaque, task: *CompactionTask) void {
        const self: *WorldDataService = @ptrCast(@alignCast(context));
        self.requests.mutex.lockUncancelable(self.io);
        defer self.requests.mutex.unlock(self.io);
        std.debug.assert(self.completed_compactor == null);
        self.completed_compactor = task;
        self.requests.not_empty.signal(self.io);
    }
    fn beginCompaction(self: *WorldDataService) !void {
        const store = self.store orelse return;
        if (!self.compaction_requested or self.compactor != null or self.lifecycle.finalPolicy()) return;
        const task = try self.allocator.create(CompactionTask);
        errdefer self.allocator.destroy(task);
        task.* = .{ .allocator = self.allocator, .io = self.io, .store = store, .store_mutex = &self.store_mutex, .notify = .{ .context = self, .send = notifyCompaction } };
        try task.start();
        self.compactor = task;
        self.compaction_requested = false;
    }
    fn finishCompaction(self: *WorldDataService, task: *CompactionTask) void {
        if (self.compactor != task) return;
        task.await();
        self.compactor = null;
        if (task.failure) |err| self.failPersistence(err) else if (task.catalog) |catalog| {
            if (self.catalog) |*old| old.deinit();
            self.catalog = catalog;
            task.catalog = null;
            var chunks = self.worker_state.modified_chunks.iterator();
            while (chunks.next()) |entry| {
                if (catalog.revision(entry.key_ptr.*)) |revision| self.base_revisions.put(self.allocator, entry.key_ptr.*, revision) catch {
                    self.failPersistence(error.OutOfMemory);
                    break;
                };
            }
            self.status.base_installed_ns = persistence.now(self.io);
            self.status.progress_generation +%= 1;
            self.evictEligible();
        }
        task.deinit();
        self.retryPending();
        if (self.compaction_requested) self.beginCompaction() catch |err| self.failPersistence(err);
    }

    fn publishPersistenceStatus(self: *WorldDataService) void {
        if (self.budget) |budget| {
            const stats = budget.stats();
            self.status.live_used_bytes = stats.used;
            self.status.live_peak_bytes = stats.peak;
            self.status.live_allocation_count = stats.allocations;
            self.status.live_rejections = stats.rejections;
        }
        self.scheduleWatchdog();
        self.status.overdue = self.lifecycle.overdue;
        self.status.pending_commands = self.pending.items.len;
        self.status.resident_chunks = self.worker_state.modified_chunks.count();
        self.status.source_count = self.source_holds.count();
        self.status_mutex.lockUncancelable(self.io);
        self.published_status = self.status;
        self.status_mutex.unlock(self.io);
    }

    /// Conservative bounded superset of every write performed by afterEdit: road runs
    /// are at most twelve cells, their candidate seeds add one, and revelation reaches
    /// one face neighbor. Include all z planes touched by covering/uncovering soil.
    fn admissible(self: *WorldDataService, request: Request) bool {
        if (request != .operation) return true;
        const edit = request.operation;
        if (self.source_holds.count() == 0) return true;
        if (edit.client.simulation) return false;
        const ids = self.operationDependencies(edit.operation);
        for (self.run_write_ids.items) |id| if (self.source_holds.contains(id)) {
            if (self.job) |job| job.prioritize(self.run_write_ids.items);
            return false;
        };
        for (ids.ids[0..ids.count]) |id| if (self.source_holds.contains(id)) {
            if (self.job) |job| job.prioritize(ids.ids[0..ids.count]);
            return false;
        };
        return !self.lifecycle.overdue;
    }

    const Dependencies = struct { ids: [27]u32, count: usize };
    fn operationDependencies(self: *WorldDataService, operation: BlockOperation) Dependencies {
        const center, _ = world_module.splitBlockCoords(operation.block);
        var result: Dependencies = .{ .ids = undefined, .count = 0 };
        for (0..3) |z| for (0..3) |y| for (0..3) |x| {
            const coords = self.layout.normalizeChunkCoords(center + ChunkCoords{ @as(i32, @intCast(x)) - 1, @as(i32, @intCast(y)) - 1, @as(i32, @intCast(z)) - 1 }) orelse continue;
            const id = self.layout.encodeChunkCoords(coords);
            if (std.mem.indexOfScalar(u32, result.ids[0..result.count], id) != null) continue;
            result.ids[result.count] = id;
            result.count += 1;
        };
        return result;
    }

    fn retryPending(self: *WorldDataService) void {
        while (true) {
            self.selectSaveDrain();
            // A preceding writer may have been the last source of wakes.
            // Revisit retained query failures when this drain takes over.
            if (self.lifecycle.needsQueryRecheck(self.lifecycleObservations())) self.retryWaitingReads();
            if (self.lifecycle.takeReady(self.lifecycleObservations())) |save| self.beginCapture(save.id, save.final) catch |err| self.failPersistence(err);
            if (self.pending.items.len == 0) break;
            self.blocked_dependency_error = null;
            if (!self.dependenciesReady(self.pending.items[0].request)) {
                if (self.blocked_dependency_error) |err| self.noteDrainFailure(err);
                break;
            }
            if (!self.admissible(self.pending.items[0].request)) break;
            const pending = self.pending.orderedRemove(0);
            self.processing_since = pending.since;
            self.processAdmitted(pending.request);
            self.processing_since = null;
            if (self.operation_deferred or self.read_discovered) break;
            self.lifecycle.commandResolved();
        }
    }

    fn failPersistence(self: *WorldDataService, err: anyerror) void {
        self.status.phase = .failed;
        self.status.error_name = @errorName(err);
        if (self.job == null) self.status.active = false;
        self.status.progress_generation +%= 1;
    }

    fn notifyPersistence(context: *anyopaque, event: persistence.Event) void {
        const self: *WorldDataService = @ptrCast(@alignCast(context));
        self.requests.mutex.lockUncancelable(self.io);
        defer self.requests.mutex.unlock(self.io);
        std.debug.assert(self.completion_count < self.completion_ring.items.len);
        const tail = (self.completion_head + self.completion_count) % self.completion_ring.items.len;
        self.completion_ring.items[tail] = event;
        self.completion_count += 1;
        self.requests.not_empty.signal(self.io);
    }
    fn waitForWork(self: *WorldDataService, batch: *std.ArrayList(Request)) bool {
        self.requests.mutex.lockUncancelable(self.io);
        defer self.requests.mutex.unlock(self.io);
        while (self.requests.items.items.len == 0 and self.completion_count == 0 and self.loaded_count == 0 and self.completed_compactor == null and !self.tick_wakeup) {
            if (self.destroy_requested.load(.acquire) and !self.shutdown_started) return true;
            if (self.requests.is_closed) return false;
            self.requests.not_empty.waitUncancelable(self.io, &self.requests.mutex);
        }
        std.mem.swap(std.ArrayList(Request), &self.requests.items, batch);
        return true;
    }
    fn drainPersistenceEvents(self: *WorldDataService) void {
        while (true) {
            self.requests.mutex.lockUncancelable(self.io);
            if (self.tick_wakeup) {
                self.tick_wakeup = false;
                self.async_progress = true;
                self.worker_state.tick = @max(self.worker_state.tick, self.pending_tick.load(.acquire));
            }
            if (self.completed_compactor) |task| {
                self.completed_compactor = null;
                self.async_progress = true;
                self.requests.mutex.unlock(self.io);
                self.finishCompaction(task);
            } else if (self.loaded_count != 0) {
                const loaded = self.loaded_ring.items[self.loaded_head];
                self.loaded_head = (self.loaded_head + 1) % self.loaded_ring.items.len;
                self.loaded_count -= 1;
                self.async_progress = true;
                self.requests.mutex.unlock(self.io);
                self.processAdmitted(.{ .chunk_loaded = loaded });
            } else if (self.completion_count != 0) {
                const event = self.completion_ring.items[self.completion_head];
                self.completion_head = (self.completion_head + 1) % self.completion_ring.items.len;
                self.completion_count -= 1;
                self.async_progress = true;
                self.requests.mutex.unlock(self.io);
                self.persistenceEvent(event);
            } else {
                self.requests.mutex.unlock(self.io);
                break;
            }
            self.publishPersistenceStatus();
        }
    }
    fn notifyLoaded(self: *WorldDataService, loaded: LoadedChunk) void {
        self.requests.mutex.lockUncancelable(self.io);
        defer self.requests.mutex.unlock(self.io);
        std.debug.assert(self.loaded_count < self.loaded_ring.items.len);
        self.loaded_ring.items[(self.loaded_head + self.loaded_count) % self.loaded_ring.items.len] = loaded;
        self.loaded_count += 1;
        self.requests.not_empty.signal(self.io);
    }

    fn beginCapture(self: *WorldDataService, intent: u64, final: bool) !void {
        self.status.intent_id = intent;
        self.status.target_sequence = 0;
        self.status.active = false;
        const store = self.store orelse return;
        if (self.is_shutting_down.load(.acquire)) return error.ServiceStopped;
        std.debug.assert(self.job == null and self.source_holds.count() == 0);
        for (self.clients.items) |client| {
            client.checkpoint_mutex.lockUncancelable(self.io);
            if (client.latest_checkpoint) |latest| {
                client.eligible_checkpoint = latest;
                client.latest_checkpoint = null;
            }
            client.checkpoint_mutex.unlock(self.io);
            self.applyEligibleCheckpoint(client);
            if (client.eligible_checkpoint) |checkpoint| {
                if (client.resolved_request >= checkpoint.after_request) return error.OutOfMemory;
            }
        }
        var source_count: usize = 0;
        var scratch_peak: usize = 0;
        var preflight_chunks = self.worker_state.modified_chunks.iterator();
        while (preflight_chunks.next()) |entry| {
            if (entry.value_ptr.chunk_revision == 0 or self.wal_revisions.get(entry.key_ptr.*) == entry.value_ptr.chunk_revision) continue;
            source_count = try std.math.add(usize, source_count, 1);
            if (source_count > self.limits.manifest_entries) return error.ManifestCapacityExceeded;
            const source = persistence.Source.freeze(entry.key_ptr.*, 0, entry.value_ptr);
            scratch_peak = @max(scratch_peak, try persistence.scratchBound(source));
            if (try persistence.outputBound(source) > self.limits.output_bytes) return error.OutputCapacityTooSmall;
        }
        // Before allocating any capture manifest or growing bookkeeping, reserve
        // a conservative peak including old/new hash-table and ring overlap.
        var preflight_bytes = try std.math.add(usize, self.limits.output_bytes, @sizeOf(persistence.Job));
        preflight_bytes = try std.math.add(usize, preflight_bytes, scratch_peak);
        preflight_bytes = try std.math.add(usize, preflight_bytes, try std.math.mul(usize, self.players.count(), format.player_record_size + @sizeOf(u64)));
        preflight_bytes = try std.math.add(usize, preflight_bytes, try std.math.mul(usize, source_count, 2 * @sizeOf(persistence.Source) + 2 + @sizeOf([]u8)));
        const ring_target = try std.math.add(usize, source_count, 4);
        const ring_peak = try std.math.add(usize, self.completion_ring.capacity, @max(self.completion_ring.capacity, ring_target));
        preflight_bytes = try std.math.add(usize, preflight_bytes, try std.math.mul(usize, ring_peak, @sizeOf(persistence.Event)));
        const hold_target = @max(@as(usize, self.source_holds.capacity()), try std.math.mul(usize, source_count, 4));
        const wal_target = @max(@as(usize, self.wal_revisions.capacity()), try std.math.mul(usize, try std.math.add(usize, self.wal_revisions.count(), source_count), 4));
        const hash_peak = try std.math.add(usize, try std.math.add(usize, hold_target, self.source_holds.capacity()), try std.math.add(usize, wal_target, self.wal_revisions.capacity()));
        preflight_bytes = try std.math.add(usize, preflight_bytes, try std.math.add(usize, try std.math.mul(usize, hash_peak, @sizeOf(u32) + @sizeOf(u64) + 16), 512));
        if (preflight_bytes > self.limits.working_bytes) return error.WorkingCapacityExceeded;
        var sources: std.ArrayList(persistence.Source) = .empty;
        errdefer sources.deinit(self.allocator);
        try sources.ensureTotalCapacityPrecise(self.allocator, source_count);
        self.capture_epoch = try std.math.add(u64, self.capture_epoch, 1);
        var chunks = self.worker_state.modified_chunks.iterator();
        while (chunks.next()) |entry| {
            if (entry.value_ptr.chunk_revision == 0 or self.wal_revisions.get(entry.key_ptr.*) == entry.value_ptr.chunk_revision) continue;
            if (sources.items.len == self.limits.manifest_entries) return error.ManifestCapacityExceeded;
            try sources.append(self.allocator, persistence.Source.freeze(entry.key_ptr.*, self.capture_epoch, entry.value_ptr));
        }
        try self.completion_ring.ensureTotalCapacityPrecise(self.allocator, sources.items.len + 4);
        self.completion_ring.items.len = sources.items.len + 4;
        self.completion_head = 0;
        try self.wal_revisions.ensureUnusedCapacity(self.allocator, @intCast(sources.items.len));
        try self.source_holds.ensureUnusedCapacity(self.allocator, @intCast(sources.items.len));
        const players = try self.allocator.alloc(u8, try std.math.mul(usize, self.players.count(), format.player_record_size));
        errdefer self.allocator.free(players);
        const player_ids = try self.allocator.alloc(u64, self.players.count());
        defer self.allocator.free(player_ids);
        var player_iterator = self.players.keyIterator();
        var player_index: usize = 0;
        while (player_iterator.next()) |id| {
            player_ids[player_index] = id.*;
            player_index += 1;
        }
        std.mem.sort(u64, player_ids, {}, std.sort.asc(u64));
        var offset: usize = 0;
        for (player_ids) |id| {
            const encoded = try format.encodePlayer(self.players.get(id).?);
            @memcpy(players[offset..][0..format.player_record_size], &encoded);
            offset += format.player_record_size;
        }
        const job = try self.allocator.create(persistence.Job);
        errdefer self.allocator.destroy(job);
        // Include retained service capture indexes plus temporary descriptor and
        // player-id overlap. Hash bucket allowance includes alignment/metadata.
        const bookkeeping = try std.math.add(usize, try std.math.mul(usize, self.completion_ring.capacity, @sizeOf(persistence.Event)), try std.math.add(usize, try std.math.mul(usize, self.source_holds.capacity(), @sizeOf(u32) + @sizeOf(u64) + 16), try std.math.add(usize, try std.math.mul(usize, sources.capacity, @sizeOf(persistence.Source)), try std.math.add(usize, player_ids.len * @sizeOf(u64), 256))));
        const frozen = try sources.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(frozen);
        job.* = .{ .allocator = self.allocator, .io = self.io, .store = store, .store_mutex = &self.store_mutex, .limits = self.limits, .notify = .{ .context = self, .send = notifyPersistence }, .epoch = self.capture_epoch, .sequence = try std.math.add(u64, self.status.durable_sequence, 1), .tick = self.worker_state.tick, .final = final, .sources = frozen, .players = players, .player_count = self.players.count() };
        const job_manifest = try std.math.mul(usize, source_count, @sizeOf(persistence.Source) + 2 + @sizeOf([]u8));
        const job_baseline = try std.math.add(usize, self.limits.output_bytes, try std.math.add(usize, job_manifest, try std.math.add(usize, players.len, try std.math.add(usize, scratch_peak, @sizeOf(persistence.Job)))));
        job.extra_working_bytes = @max(bookkeeping, preflight_bytes - job_baseline);
        for (frozen) |source| self.source_holds.putAssumeCapacity(source.id, source.revision);
        errdefer self.source_holds.clearRetainingCapacity();
        try job.start();
        self.job = job;
        const started = persistence.now(self.io);
        self.lifecycle.started(.{ .id = intent, .final = final }, job.epoch, started);
        self.captured_player_generation = self.player_generation;
        self.simulation_paused.store(frozen.len != 0, .release);
        self.status.intent_id = intent;
        self.reportAttemptPhase();
        self.status.active = true;
        self.status.target_sequence = job.sequence;
        self.status.tick = job.tick;
        self.status.error_name = null;
        self.status.capture_started_ns = started;
        self.status.sources_released_ns = 0;
        self.status.source_bytes = 0;
        for (frozen) |source| self.status.source_bytes += source.pinnedBytes();
        self.status.progress_generation +%= 1;
    }

    fn persistenceEvent(self: *WorldDataService, event: persistence.Event) void {
        const job = self.job orelse return;
        switch (event) {
            .released => |released| {
                if (released.epoch != job.epoch or self.source_holds.get(released.id) != released.revision) return;
                _ = self.source_holds.remove(released.id);
                self.status.progress_generation +%= 1;
                if (self.source_holds.count() == 0) {
                    self.simulation_paused.store(false, .release);
                    self.status.sources_released_ns = persistence.now(self.io);
                }
                self.retryPending();
            },
            .encoded => |epoch| {
                if (!self.lifecycle.encoded(epoch)) return;
                self.reportAttemptPhase();
                self.status.progress_generation +%= 1;
            },
            .committed => |epoch| {
                const committed_at = persistence.now(self.io);
                if (!self.lifecycle.committed(epoch, committed_at)) return;
                self.status.durable_sequence = job.sequence;
                self.status.sequence = job.sequence;
                self.status.wal_committed_ns = committed_at;
                for (job.sources) |source| self.wal_revisions.putAssumeCapacity(source.id, source.revision);
                self.lifecycle.unsaved_work = self.player_generation != self.captured_player_generation;
                var live = self.worker_state.modified_chunks.iterator();
                while (live.next()) |entry| if (self.wal_revisions.get(entry.key_ptr.*) != entry.value_ptr.chunk_revision) {
                    self.lifecycle.unsaved_work = true;
                    break;
                };
                if (job.final) self.reportAttemptPhase();
                self.status.progress_generation +%= 1;
            },
            .compacted => |epoch| {
                if (epoch != job.epoch) return;
                var revisions = self.wal_revisions.iterator();
                while (revisions.next()) |entry| self.base_revisions.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*) catch {
                    self.failPersistence(error.OutOfMemory);
                    break;
                };
                if (job.installed_catalog) |catalog| {
                    if (self.catalog) |*old| old.deinit();
                    self.catalog = catalog;
                    job.installed_catalog = null;
                }
                self.status.base_installed_ns = persistence.now(self.io);
                self.status.progress_generation +%= 1;
                self.evictEligible();
            },
            .finished => |finished| {
                if (finished.epoch != job.epoch) return;
                // Writer has posted its last message; await closes the tiny completion tail.
                job.writer.await(self.io);
                self.status.output_peak_bytes = job.peak_bytes;
                self.status.output_bytes = 0;
                self.job = null;
                const completion = self.lifecycle.finished(finished.epoch, finished.failure).?;
                job.deinit();
                self.status.active = false;
                self.status.retained_base_mismatch_chunks = 0;
                var retained = self.worker_state.modified_chunks.iterator();
                while (retained.next()) |entry| {
                    if (entry.value_ptr.chunk_revision != 0 and self.base_revisions.get(entry.key_ptr.*) != entry.value_ptr.chunk_revision) self.status.retained_base_mismatch_chunks += 1;
                }
                if (self.compaction_requested) self.beginCompaction() catch |err| self.failPersistence(err);
                switch (completion.outcome) {
                    .complete => self.status.phase = .complete,
                    .canceled => |err| self.failPersistence(err),
                    .failed => |err| self.failPersistence(err),
                }
                self.status.progress_generation +%= 1;
                self.retryPending();
            },
        }
    }

    fn oldestPlayerWait(self: *WorldDataService) ?i96 {
        for (self.pending.items) |pending| if (!pending.request.operation.client.simulation) return pending.since;
        return null;
    }

    fn checkWatchdog(self: *WorldDataService) void {
        const at = persistence.now(self.io);
        if (self.lifecycle.takeDueRetry(at) == .retry_dependencies) self.retrySaveDrain();
        if (self.job) |job| {
            job.mutex.lockUncancelable(self.io);
            self.status.output_bytes = job.output_bytes;
            self.status.output_peak_bytes = job.peak_bytes;
            job.mutex.unlock(self.io);
        }
        switch (self.lifecycle.watchdog(at, self.lifecycleDeadlines(), self.lifecycleDeadlineObservations())) {
            .none => {},
            .cancel_capture => self.job.?.cancel(),
            .start_overdue => {
                const intent = self.next_intent.fetchAdd(1, .monotonic);
                self.beginCapture(intent, false) catch |err| self.failPersistence(err);
            },
        }
    }

    fn runReader(self: *WorldDataService) void {
        var batch: std.ArrayList(storage.BaseRead) = .empty;
        defer batch.deinit(self.allocator);
        while (self.read_requests.waitAndTakeAll(self.io, &batch)) {
            for (batch.items) |*read| {
                const result = self.readPersisted(read);
                self.notifyLoaded(.{ .id = read.id, .revision = read.revision, .result = result });
                read.deinit();
            }
            batch.clearRetainingCapacity();
        }
    }
    fn readPersisted(self: *WorldDataService, read: *const storage.BaseRead) !WorldChunk {
        const encoded = try read.read(self.allocator);
        defer self.allocator.free(encoded);
        var decoded = try format.decodeChunk(self.allocator, read.world_uuid, encoded, read.dimensions);
        defer decoded.deinit(self.allocator);
        var decoded_metadata = try format.decodeMetadata(self.allocator, decoded.blocks, decoded.metadata, read.dimensions);
        defer decoded_metadata.deinit(self.allocator);
        const live = self.worker_state.liveAllocator(self.allocator);
        var chunk = WorldChunk.initEmpty();
        if (!std.mem.allEqual(u8, decoded.blocks, 0)) {
            const data = try live.create(@import("world_chunk_data.zig").WorldChunkData);
            @memcpy(std.mem.asBytes(&data.blocks), decoded.blocks);
            chunk = WorldChunk.initBlocks(data);
        }
        errdefer chunk.deinit(live);
        chunk.chunk_revision = decoded.revision;
        chunk.flags.is_unreachable = decoded.is_unreachable;
        var custom_index: usize = 0;
        for (decoded.blocks, 0..) |material, cell| {
            if (material != 255) continue;
            const road = decoded_metadata.roads[custom_index];
            custom_index += 1;
            try chunk.metadata.roads.append(live, .{ .index = @intCast(cell), .slope = if (road.formation) |formation| .{
                .high_endpoint = formation.high_endpoint,
                .downhill = @enumFromInt(formation.direction),
                .length = formation.length,
                .section = formation.section,
            } else null });
        }
        for (decoded_metadata.construction) |cell| try chunk.metadata.constructed.append(live, @intCast(cell));
        // The decoder validated one event per cell; bulk import avoids the
        // replacement scans and shifts needed by interactive timer scheduling.
        try chunk.metadata.timed.reserve(live, decoded_metadata.timers.len);
        for (decoded_metadata.timers) |timer| chunk.metadata.timed.events.appendAssumeCapacity(.{ .block = @intCast(timer.cell), .kind = @enumFromInt(timer.kind), .due_tick = timer.deadline });
        std.mem.sort(transformations.Event, chunk.metadata.timed.events.items, {}, struct {
            fn less(_: void, a: transformations.Event, b: transformations.Event) bool {
                return a.due_tick < b.due_tick or (a.due_tick == b.due_tick and a.block < b.block);
            }
        }.less);
        return chunk;
    }
    fn installLoaded(self: *WorldDataService, id: u32, revision: u64, chunk: WorldChunk) !void {
        try self.worker_state.modified_chunks.ensureUnusedCapacity(self.allocator, 1);
        try self.base_revisions.ensureUnusedCapacity(self.allocator, 1);
        const capture_spare: usize = if (self.job) |job| job.sources.len else 0;
        try self.wal_revisions.ensureUnusedCapacity(self.allocator, @intCast(capture_spare + 1));
        try self.worker_state.timed_chunks.ensureUnusedCapacity(self.allocator, 1);
        self.worker_state.modified_chunks.putAssumeCapacity(id, chunk);
        self.base_revisions.putAssumeCapacity(id, revision);
        self.wal_revisions.putAssumeCapacity(id, revision);
        if (chunk.metadata.timed.events.items.len != 0) self.worker_state.timed_chunks.putAssumeCapacity(id, {});
    }

    fn failDependencyRead(self: *WorldDataService, err: anyerror) void {
        self.blocked_dependency_error = err;
        self.noteDrainFailure(err);
    }

    fn requireBase(self: *WorldDataService, id: u32) bool {
        if (self.worker_state.modified_chunks.contains(id)) return true;
        const catalog = if (self.catalog) |*value| value else return true;
        if (catalog.revision(id) == null) return true;
        self.read_discovered = true;
        if (self.read_failed.get(id)) |err| {
            self.terminal_read_failure = true;
            self.blocked_dependency_error = err;
            return false;
        }
        if (!self.read_pending.contains(id) and self.read_pending.count() < self.limits.pending_commands) {
            self.requests.mutex.lockUncancelable(self.io);
            if (self.loaded_ring.items.len == 0) self.loaded_ring.resize(self.allocator, self.limits.pending_commands) catch {
                self.requests.mutex.unlock(self.io);
                self.failDependencyRead(error.OutOfMemory);
                return false;
            };
            self.requests.mutex.unlock(self.io);
            self.read_failed.ensureUnusedCapacity(self.allocator, @intCast(self.read_pending.count() + 1)) catch {
                self.failDependencyRead(error.OutOfMemory);
                return false;
            };
            var read = catalog.prepareRead(id) catch |err| {
                self.failDependencyRead(err);
                return false;
            };
            if (read) |*handle| {
                self.read_pending.put(self.allocator, id, handle.revision) catch {
                    handle.deinit();
                    self.failDependencyRead(error.OutOfMemory);
                    return false;
                };
                self.read_requests.tryPush(self.io, self.allocator, handle.*) catch |err| {
                    _ = self.read_pending.remove(id);
                    handle.deinit();
                    self.failDependencyRead(err);
                    return false;
                };
            }
        }
        return false;
    }
    fn discoverRoadRunDependencies(self: *WorldDataService, operation: BlockOperation) !bool {
        self.run_write_ids.clearRetainingCapacity();
        if (operation.action != .remove) return true;
        var reader: ReadContext = .{ .state = &self.worker_state, .allocator = self.allocator };
        defer reader.deinit();
        const roads = @import("roads.zig");
        const context: roads.Context = .{ .allocator = self.allocator, .reader = .{ .layout = self.layout, .context = &reader, .block_at = ReadContext.read, .custom_shape_at = ReadContext.readShape }, .chunks = &self.worker_state.modified_chunks, .changed = &self.worker_state.road_changes, .max_plan_changes = self.limits.manifest_entries };
        const target: rules.Cell = .{ operation.block[0], operation.block[1], operation.block[2] };
        var sites: [9]rules.Cell = undefined;
        sites[0] = target;
        var count: usize = 1;
        for (std.enums.values(@import("engine").voxel_chunk.custom_block.Direction)) |direction| {
            for (0..2) |level| {
                sites[count] = target + direction.offset() + rules.Cell{ 0, 0, @intCast(level) };
                count += 1;
            }
        }
        for (sites) |site| {
            const block = @import("block_coordinates.zig").fromWorld(self.layout, site - @as(rules.Cell, self.layout.origin_chunk) * @as(rules.Cell, @splat(CHUNK_SIZE))) orelse continue;
            const coords, const local = world_module.splitBlockCoords(block);
            const chunk = self.worker_state.modified_chunks.get(self.layout.encodeChunkCoords(coords)) orelse continue;
            const road = chunk.metadata.road(transformations.index(local)) orelse continue;
            if (road.slope) |slope| try context.appendRunChunkIds(slope, &self.run_write_ids);
        }
        var ready = true;
        for (self.run_write_ids.items) |id| ready = self.requireBase(id) and ready;
        return ready;
    }

    fn dependenciesReady(self: *WorldDataService, request: Request) bool {
        if (self.catalog == null) return true;
        var ready = true;
        switch (request) {
            .operation => |edit| {
                const center, _ = world_module.splitBlockCoords(edit.operation.block);
                // Validator rechecks constructed cells within28 and their support within28.
                for (0..5) |z| for (0..5) |y| for (0..5) |x| {
                    const coords = self.layout.normalizeChunkCoords(center + ChunkCoords{ @as(i32, @intCast(x)) - 2, @as(i32, @intCast(y)) - 2, @as(i32, @intCast(z)) - 2 }) orelse continue;
                    ready = self.requireBase(self.layout.encodeChunkCoords(coords)) and ready;
                };
                self.run_gate_failure = null;
                if (ready) ready = self.discoverRoadRunDependencies(edit.operation) catch |err| blk: {
                    self.run_gate_failure = err;
                    break :blk true;
                };
            },
            .load_chunks => |load| {
                var z = load.z_start;
                while (z < load.z_end) : (z += 1) {
                    const coords: ChunkCoords = .{ load.column[0], load.column[1], z };
                    ready = self.requireBase(self.layout.encodeChunkCoords(coords)) and ready;
                    for (std.enums.values(Side)) |side| if (world_module.adjacentChunk(self.layout, coords, side)) |neighbor| {
                        ready = self.requireBase(self.layout.encodeChunkCoords(neighbor)) and ready;
                    };
                }
            },
            else => {},
        }
        return ready;
    }

    fn evictEligible(self: *WorldDataService) void {
        if (self.pending.items.len != 0 or self.waiting_reads.items.len != 0 or self.read_pending.count() != 0) return;
        var candidates: std.ArrayList(ChunkId) = .empty;
        defer candidates.deinit(self.allocator);
        var chunks = self.worker_state.modified_chunks.iterator();
        while (chunks.next()) |entry| {
            const id = entry.key_ptr.*;
            const clean_generated = entry.value_ptr.chunk_revision == 0 and (self.catalog == null or self.catalog.?.revision(id) == null);
            if ((!clean_generated and self.base_revisions.get(id) != entry.value_ptr.chunk_revision) or self.source_holds.contains(id)) continue;
            var subscribed = false;
            for (self.clients.items) |client| if (client.subscriptions.contains(id)) {
                subscribed = true;
                break;
            };
            if (subscribed) continue;
            var lazy = true;
            for (entry.value_ptr.metadata.timed.events.items) |timer| if (!timer.kind.isLazy()) {
                lazy = false;
                break;
            };
            if (!lazy) continue;
            candidates.append(self.allocator, id) catch return;
        }
        for (candidates.items) |id| {
            const removed = self.worker_state.modified_chunks.fetchRemove(id).?;
            removed.value.deinit(self.worker_state.liveAllocator(self.allocator));
            _ = self.worker_state.timed_chunks.remove(id);
        }
    }

    fn processTransformations(self: *WorldDataService) void {
        if (self.source_holds.count() != 0) return;
        const cutoff = self.worker_state.tick;
        // Fixed-size fair selection; loads cannot join this pass after its boundary.
        var due: [16]u32 = undefined;
        var count: usize = 0;
        self.status.timer_due_chunks = 0;
        self.status.timer_due_events = 0;
        self.status.oldest_timer_deadline = null;
        var iterator = self.worker_state.timed_chunks.keyIterator();
        while (iterator.next()) |entry| {
            const chunk = self.worker_state.modified_chunks.get(entry.*) orelse continue;
            const events = chunk.metadata.timed.events.items;
            if (events.len == 0 or events[0].due_tick > cutoff) continue;
            self.status.timer_due_chunks += 1;
            self.status.oldest_timer_deadline = if (self.status.oldest_timer_deadline) |old| @min(old, events[0].due_tick) else events[0].due_tick;
            var low: usize = 0;
            var high = events.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (events[middle].due_tick <= cutoff) low = middle + 1 else high = middle;
            }
            self.status.timer_due_events += low;
            const distance = entry.* -% self.timer_cursor;
            var at: usize = 0;
            while (at < count and due[at] -% self.timer_cursor < distance) : (at += 1) {}
            if (at == due.len) continue;
            const new_count = @min(count + 1, due.len);
            var move = new_count - 1;
            while (move > at) : (move -= 1) due[move] = due[move - 1];
            due[at] = entry.*;
            count = new_count;
        }
        for (due[0..count]) |id| {
            self.timer_cursor = id +% 1;
            const coords = self.layout.decodeChunkId(id);
            if (self.worker_state.transformChunk(self.allocator, coords)) {
                self.lifecycle.unsaved_work = true;
                self.publishMaterialChange(coords);
            }
        }
    }
};

const ReadContext = struct {
    state: *WorkerState,
    allocator: std.mem.Allocator,
    chunks: world_module.ChunksHashMap = .empty,
    failure: ?anyerror = null,

    fn deinit(self: *ReadContext) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
    }

    fn read(context: *anyopaque, block: [3]u32) ?@import("engine").voxel_chunk.BlockType {
        const self: *ReadContext = @ptrCast(@alignCast(context));
        const coords, const local = world_module.splitBlockCoords(block);
        const id = self.state.layout.encodeChunkCoords(coords);
        if (self.state.modified_chunks.getPtr(id)) |chunk| return chunk.content.getBlock(local);
        if (!self.chunks.contains(id)) {
            if (self.state.persistence_service) |service| if (!service.requireBase(id)) return null;
            const generator = ColumnGenerator.init(&self.state.generator, .{ coords[0], coords[1] });
            const chunk = generator.tryGenerateChunk(self.allocator, coords[2]) catch |err| {
                self.failure = err;
                return null;
            };
            self.chunks.put(self.allocator, id, chunk) catch |err| {
                chunk.deinit(self.allocator);
                self.failure = err;
                return null;
            };
        }
        return self.chunks.get(id).?.content.getBlock(local);
    }

    fn readShape(context: *anyopaque, block: [3]u32) ?@import("engine").voxel_chunk.custom_block.Shape {
        const self: *ReadContext = @ptrCast(@alignCast(context));
        if (read(context, block) != .custom) return null;
        const coords, const local = world_module.splitBlockCoords(block);
        const id = self.state.layout.encodeChunkCoords(coords);
        const chunk = self.state.modified_chunks.get(id) orelse self.chunks.get(id).?;
        const road = chunk.metadata.road(transformations.index(local)) orelse return null;
        return road.shape();
    }
};

const WorkerState = struct {
    layout: *const WorldLayout,
    generator: PreparedWorldGenerator,
    /// Committed edits survive cache eviction. Untouched chunks are regenerated on demand.
    modified_chunks: std.AutoHashMapUnmanaged(ChunkId, WorldChunk) = .empty,
    /// Retained independently of mesh allocation/subscription lifetime. Untouched inputs
    /// have revision zero; a neighboring edit may advance it without a chunk revision change.
    mesh_revisions: std.AutoHashMapUnmanaged(ChunkId, u64) = .empty,
    next_mesh_revision: u64 = 0,
    /// Bounded terrain-height cache, not block or mesh storage. Neighbor meshing otherwise
    /// repeats the same noise calculations for every z coordinate in a column.
    columns: std.AutoHashMapUnmanaged(u64, ColumnGenerator) = .empty,
    /// Bounded cache for immutable generated planes. Modified chunks keep their own
    /// incrementally updated masks and always take precedence over this cache.
    boundary_cache: std.AutoHashMapUnmanaged(ChunkId, BoundaryMasks) = .empty,
    tick: transformations.Tick = 0,
    /// Chunks without pending events are not visited by time processing.
    timed_chunks: std.AutoHashMapUnmanaged(ChunkId, void) = .empty,
    road_changes: std.ArrayList(ChunkId) = .empty,
    persistence_service: ?*WorldDataService = null,
    live_allocator: ?std.mem.Allocator = null,
    fn liveAllocator(self: *const WorkerState, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.live_allocator orelse fallback;
    }

    fn resolveRestoredPosition(self: *WorkerState, allocator: std.mem.Allocator, feet: [3]f64, body: @import("terrain_collision.zig").Body) StandingSpaceError!standing_space.Position {
        for (feet) |coordinate| if (!std.math.isFinite(coordinate) or @abs(coordinate) >= 0x1p62) return error.InvalidSearch;
        const position: standing_space.Position = feet;
        var temporary = world_module.World.init(allocator, self.layout) catch return error.MissingData;
        defer temporary.deinit();
        const bounds = body.bounds(position);
        const first = bounds.firstCell();
        const last = bounds.lastCell();
        var z = first[2];
        while (z <= last[2]) : (z += 1) {
            var y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) {
                    const block = @import("block_coordinates.zig").fromWorld(self.layout, .{ x, y, z }) orelse continue;
                    const coords, _ = world_module.splitBlockCoords(block);
                    const id = self.layout.encodeChunkCoords(coords);
                    if (!temporary.chunks.contains(id)) temporary.chunks.put(allocator, id, self.loadAt(allocator, coords)) catch return error.MissingData;
                }
            }
        }
        var query: @import("terrain_collision.zig").Query = .{ .world = &temporary, .body = body };
        if (query.overlap(position, false) == .clear) return position;
        return self.findStandingSpace(allocator, .{ .preferred_xy = .{ feet[0], feet[1] }, .clearance_size = .{ body.half_width * 2, body.half_width * 2, body.height }, .support_size = .{ body.half_width * 2, body.half_width * 2 }, .search_radius = 8 });
    }

    fn findStandingSpace(self: *WorkerState, allocator: std.mem.Allocator, query: StandingSpaceRequest) standing_space.Error!standing_space.Position {
        var context: ReadContext = .{ .state = self, .allocator = allocator };
        defer context.deinit();
        return standing_space.find(.{ .layout = self.layout, .context = &context, .block_at = ReadContext.read, .custom_shape_at = ReadContext.readShape }, query);
    }

    fn boundariesAt(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) BoundaryMasks {
        return self.tryBoundariesAt(allocator, coords) catch @panic("boundary dependency unavailable");
    }

    fn tryBoundariesAt(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) !BoundaryMasks {
        const id = self.layout.encodeChunkCoords(coords);
        if (self.modified_chunks.getPtr(id)) |chunk| return chunk.boundaries;
        // Check persisted ownership before consulting generated cache entries.
        if (self.persistence_service) |service| if (!service.requireBase(id)) return error.DependencyPending;
        if (self.boundary_cache.get(id)) |masks| return masks;
        const chunk = try self.tryLoadAt(allocator, coords);
        defer chunk.deinit(allocator);
        if (self.boundary_cache.count() >= 512) self.boundary_cache.clearRetainingCapacity();
        // Caching is optional; the correctly computed masks remain usable on OOM.
        self.boundary_cache.put(allocator, id, chunk.boundaries) catch {};
        return chunk.boundaries;
    }

    fn neighborBoundaries(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) BoundaryMasks {
        return self.tryNeighborBoundaries(allocator, coords) catch @panic("boundary dependency unavailable");
    }

    fn tryNeighborBoundaries(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) !BoundaryMasks {
        var masks: BoundaryMasks = @splat(.{});
        for (std.enums.values(Side)) |side| {
            const adjacent = world_module.adjacentChunk(self.layout, coords, side) orelse continue;
            masks[@intFromEnum(side)] = (try self.tryBoundariesAt(allocator, adjacent))[@intFromEnum(side.getOpposite())];
        }
        return masks;
    }

    fn meshRevision(self: *const WorkerState, coords: ChunkCoords) u64 {
        return self.mesh_revisions.get(self.layout.encodeChunkCoords(coords)) orelse 0;
    }

    fn loadAt(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) WorldChunk {
        // Legacy collision callers discard this temporary result when read_discovered
        // is set. Publication paths use tryLoadAt and cannot expose it.
        return self.tryLoadAt(allocator, coords) catch |err| switch (err) {
            error.DependencyPending => WorldChunk.initEmpty(),
            else => @panic("OOM"),
        };
    }

    fn tryLoadAt(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) !WorldChunk {
        const id = self.layout.encodeChunkCoords(coords);
        if (self.modified_chunks.get(id)) |chunk| return chunk.tryClone(allocator);
        if (self.persistence_service) |service| {
            if (!service.requireBase(id)) return error.DependencyPending;
        }
        const key = @as(u64, @intCast(coords[0])) << 32 | @as(u64, @intCast(coords[1]));
        if (!self.columns.contains(key)) {
            if (self.columns.count() >= 64) self.columns.clearRetainingCapacity();
            try self.columns.put(allocator, key, ColumnGenerator.init(&self.generator, .{ coords[0], coords[1] }));
        }
        return self.columns.getPtr(key).?.tryGenerateChunk(allocator, coords[2]);
    }

    fn deinit(self: *WorkerState, allocator: std.mem.Allocator) void {
        var iterator = self.modified_chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.deinit(self.liveAllocator(allocator));
        self.modified_chunks.deinit(allocator);
        self.mesh_revisions.deinit(allocator);
        self.columns.deinit(allocator);
        self.boundary_cache.deinit(allocator);
        self.timed_chunks.deinit(allocator);
        self.road_changes.deinit(allocator);
        self.generator.deinit(allocator);
    }

    fn loadChunk(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) WorldChunk {
        return self.loadAt(allocator, coords);
    }

    const ApplyResult = struct {
        status: OperationStatus,
        chunk: WorldChunk,
        revealed_neighbors: [6]?ChunkCoords,
        changed_below: ?ChunkCoords,
        diagnostics: world_module.EditResult,
    };

    fn applyOperation(self: *WorkerState, allocator: std.mem.Allocator, operation: BlockOperation) ApplyResult {
        return self.tryApplyOperation(allocator, operation) catch |err| {
            if (self.persistence_service) |service| {
                if (err == error.CapturePending or err == error.DependencyPending) service.operation_deferred = true else service.failPersistence(err);
            }
            return .{ .status = .resource_exhausted, .chunk = WorldChunk.initEmpty(), .revealed_neighbors = @splat(null), .changed_below = null, .diagnostics = .{ .status = .resource_exhausted } };
        };
    }

    fn ensureResident(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) !void {
        const id = self.layout.encodeChunkCoords(coords);
        if (self.modified_chunks.contains(id)) return;
        if (self.persistence_service) |service| if (!service.requireBase(id)) return error.DependencyPending;
        const generator = ColumnGenerator.init(&self.generator, .{ coords[0], coords[1] });
        const chunk = try generator.tryGenerateChunk(self.liveAllocator(allocator), coords[2]);
        errdefer chunk.deinit(self.liveAllocator(allocator));
        try self.modified_chunks.put(allocator, id, chunk);
    }

    fn tryApplyOperation(self: *WorkerState, allocator: std.mem.Allocator, operation: BlockOperation) !ApplyResult {
        const live = self.liveAllocator(allocator);
        self.road_changes.clearRetainingCapacity();
        if (self.persistence_service) |service| if (service.run_gate_failure) |err| return err;
        const cells = try world_module.tryCollectConstructed(allocator, self.layout, &self.modified_chunks, operation.block);
        defer allocator.free(cells);
        var context: ReadContext = .{ .state = self, .allocator = allocator };
        defer context.deinit();
        var diagnostics = world_module.validateEdit(allocator, .{ .layout = self.layout, .context = &context, .block_at = ReadContext.read, .custom_shape_at = ReadContext.readShape }, cells, operation);
        if (context.failure) |err| return err;
        if (self.persistence_service) |service| if (service.read_discovered) return error.DependencyPending;
        const coords, const local = world_module.splitBlockCoords(operation.block);
        const position = self.layout.encodeChunkCoords(coords);
        if (operation.player) |transfer| {
            const service = self.persistence_service orelse return error.MissingPlayer;
            const player = service.players.get(transfer.id);
            const matches = if (player) |p| switch (operation.action) {
                .remove => p.inventory == null,
                .put => |material| p.inventory == @as(?u8, @intFromEnum(material)),
            } else false;
            if (!matches) {
                diagnostics = .{ .status = .inventory_mismatch };
            } else if (diagnostics.status == .success and operation.action == .remove) {
                const history = if (self.modified_chunks.get(position)) |chunk| chunk.cell_changes else @import("cell_changes.zig").History{};
                if (!history.unchangedSince(transformations.index(local), transfer.expected_sequence)) diagnostics = .{ .status = .target_changed };
            }
        }
        if (diagnostics.status != .success) {
            const chunk = if (self.modified_chunks.get(position)) |stored| try stored.tryClone(allocator) else blk: {
                const generator = ColumnGenerator.init(&self.generator, .{ coords[0], coords[1] });
                break :blk try generator.tryGenerateChunk(allocator, coords[2]);
            };
            return .{ .status = diagnostics.status, .chunk = chunk, .revealed_neighbors = @splat(null), .changed_below = null, .diagnostics = diagnostics };
        }

        // Materialize unchanged dependencies before obtaining pointers; rehashing may move headers.
        try self.modified_chunks.ensureUnusedCapacity(allocator, 8);
        try self.ensureResident(allocator, coords);
        const previous_road = self.modified_chunks.get(position).?.metadata.road(transformations.index(local));
        const previous_flags = self.modified_chunks.get(position).?.flags;
        const road_context: @import("roads.zig").Context = .{
            .allocator = allocator,
            .reader = .{ .layout = self.layout, .context = &context, .block_at = ReadContext.read, .custom_shape_at = ReadContext.readShape },
            .chunks = &self.modified_chunks,
            .changed = &self.road_changes,
            .virtual_edit = operation,
        };
        var road_plan = try road_context.planAfterEdit(operation, previous_road);
        defer road_plan.deinit(allocator);
        if (context.failure) |err| return err;
        if (self.persistence_service) |service| {
            if (service.read_discovered) return error.DependencyPending;
            for (road_plan.chunk_ids) |id| if (service.source_holds.contains(id)) {
                service.operation_deferred = true;
                if (service.job) |job| job.prioritize(road_plan.chunk_ids);
                return error.CapturePending;
            };
        }
        try road_plan.reserveCommit(road_context);
        var revealed: [6]?ChunkCoords = @splat(null);
        if (operation.action == .remove) for (std.enums.values(Side)) |side| {
            const i = @intFromEnum(side);
            if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1) or !previous_flags.getSideSolidness(side)) continue;
            const neighbor = world_module.adjacentChunk(self.layout, coords, side) orelse continue;
            try self.ensureResident(allocator, neighbor);
            const neighbor_id = self.layout.encodeChunkCoords(neighbor);
            if (self.modified_chunks.get(neighbor_id).?.flags.is_unreachable) revealed[i] = neighbor;
        };
        var below_coords: ?ChunkCoords = null;
        var below_local: [3]u5 = undefined;
        var below_changed = false;
        var below_metadata = false;
        if (operation.block[2] != 0) {
            var below = operation.block;
            below[2] -= 1;
            const bcoords, const blocal = world_module.splitBlockCoords(below);
            try self.ensureResident(allocator, bcoords);
            const bchunk = self.modified_chunks.getPtr(self.layout.encodeChunkCoords(bcoords)).?;
            const material = bchunk.content.getBlock(blocal);
            if (material.isEarth()) {
                if (operation.action == .put) {
                    below_changed = material != .packed_dirt;
                    for (bchunk.metadata.timed.events.items) |event| if (event.block == transformations.index(blocal)) {
                        below_metadata = true;
                        break;
                    };
                } else if (material != .dirt) {
                    below_metadata = true;
                    try bchunk.metadata.timed.reserve(live, 1);
                }
                if (below_changed or below_metadata) {
                    below_coords = bcoords;
                    below_local = blocal;
                }
            }
        }
        const target = self.modified_chunks.getPtr(position).?;
        const road_growth: usize = if (operation.action == .put and operation.action.put == .country_road_adaptive) 1 else 0;
        const constructed_growth: usize = if (operation.action == .put) 1 else 0;
        const timer_growth: usize = if ((operation.action == .put and operation.action.put == .dirt) or (below_coords != null and operation.action == .remove and @reduce(.And, below_coords.? == coords))) 1 else 0;
        try target.metadata.reserve(live, road_growth, constructed_growth, timer_growth);
        _ = try target.prepareApply(live, local, operation.action);
        const covered = if (operation.action == .put and operation.action.put == .dirt and operation.block[2] + 1 < self.layout.size_in_blocks[2]) blk: {
            var above = operation.block;
            above[2] += 1;
            break :blk (ReadContext.read(&context, above) orelse return context.failure orelse error.DependencyPending) != .none;
        } else false;
        if (context.failure) |err| return err;
        if (self.persistence_service) |service| if (service.read_discovered) return error.DependencyPending;
        var reply = try target.tryClone(allocator);
        errdefer reply.deinit(allocator);
        try reply.metadata.reserve(allocator, road_growth, constructed_growth, timer_growth);
        if (operation.action == .put) _ = try reply.tryEnsureData(allocator);
        try self.mesh_revisions.ensureUnusedCapacity(allocator, @intCast(road_plan.chunk_ids.len + 8));
        try self.timed_chunks.ensureUnusedCapacity(allocator, 2);
        var changed_ids: std.ArrayList(u32) = .empty;
        defer changed_ids.deinit(allocator);
        try changed_ids.ensureTotalCapacity(allocator, road_plan.chunk_ids.len + 8);
        changed_ids.appendAssumeCapacity(position);
        for (road_plan.chunk_ids) |id| if (std.mem.indexOfScalar(u32, changed_ids.items, id) == null) changed_ids.appendAssumeCapacity(id);
        for (revealed) |neighbor| if (neighbor) |value| {
            const id = self.layout.encodeChunkCoords(value);
            if (std.mem.indexOfScalar(u32, changed_ids.items, id) == null) changed_ids.appendAssumeCapacity(id);
        };
        if (below_coords) |value| {
            const id = self.layout.encodeChunkCoords(value);
            if (std.mem.indexOfScalar(u32, changed_ids.items, id) == null) changed_ids.appendAssumeCapacity(id);
        }
        for (changed_ids.items) |id| _ = try std.math.add(u64, self.modified_chunks.get(id).?.chunk_revision, 1);
        const next_mesh = try std.math.add(u64, self.next_mesh_revision, 1);

        if (self.persistence_service) |service| try service.dirty_meshes.ensureUnusedCapacity(allocator, @intCast(changed_ids.items.len + 7));
        // All fallible work is complete. Commit every persistent field/cache together.
        std.debug.assert(target.applyPrepared(live, local, operation.action) == .success);
        if (operation.action == .put) {
            target.metadata.markConstructedAssumeCapacity(transformations.index(local));
            if (operation.action.put == .dirt) {
                if (covered) target.changeType(local, .packed_dirt) else target.metadata.timed.scheduleAssumeCapacity(.{
                    .block = transformations.index(local),
                    .kind = .compact_dirt,
                    .due_tick = self.tick +| transformations.transformation_delay,
                });
            }
        }
        if (below_coords) |value| {
            const below = self.modified_chunks.getPtr(self.layout.encodeChunkCoords(value)).?;
            if (operation.action == .put) {
                below.metadata.timed.cancel(transformations.index(below_local));
                if (below_changed) below.changeType(below_local, .packed_dirt);
            } else below.metadata.timed.scheduleAssumeCapacity(.{
                .block = transformations.index(below_local),
                .kind = .grow_grass,
                .due_tick = self.tick +| transformations.transformation_delay,
            });
        }
        for (revealed) |neighbor| if (neighbor) |value| {
            self.modified_chunks.getPtr(self.layout.encodeChunkCoords(value)).?.flags.is_unreachable = false;
        };
        road_plan.applyPrepared(road_context);
        self.next_mesh_revision = next_mesh;
        for (changed_ids.items) |id| {
            const chunk = self.modified_chunks.getPtr(id).?;
            chunk.chunk_revision += 1;
            self.mesh_revisions.putAssumeCapacity(id, next_mesh);
            if (chunk.metadata.timed.events.items.len == 0) _ = self.timed_chunks.remove(id) else self.timed_chunks.putAssumeCapacity(id, {});
        }
        for (std.enums.values(Side)) |side| {
            const i = @intFromEnum(side);
            if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1)) continue;
            const neighbor = world_module.adjacentChunk(self.layout, coords, side) orelse continue;
            self.mesh_revisions.putAssumeCapacity(self.layout.encodeChunkCoords(neighbor), next_mesh);
        }
        copyPreparedChunk(allocator, target, &reply);
        return .{ .status = .success, .chunk = reply, .revealed_neighbors = revealed, .changed_below = below_coords, .diagnostics = diagnostics };
    }

    fn copyPreparedChunk(allocator: std.mem.Allocator, source: *const WorldChunk, target: *WorldChunk) void {
        if (source.content == .blocks) {
            std.debug.assert(target.content == .blocks);
            target.content.blocks.* = source.content.blocks.*;
        } else {
            target.content.deinit(allocator);
            target.content = .empty;
        }
        target.flags = source.flags;
        target.solid_block_count = source.solid_block_count;
        target.chunk_revision = source.chunk_revision;
        target.cell_changes = source.cell_changes;
        target.boundaries = source.boundaries;
        target.metadata.roads.clearRetainingCapacity();
        target.metadata.roads.appendSliceAssumeCapacity(source.metadata.roads.items);
        target.metadata.constructed.clearRetainingCapacity();
        target.metadata.constructed.appendSliceAssumeCapacity(source.metadata.constructed.items);
        target.metadata.timed.events.clearRetainingCapacity();
        target.metadata.timed.events.appendSliceAssumeCapacity(source.metadata.timed.events.items);
    }

    fn refreshTimedIndex(self: *WorkerState, allocator: std.mem.Allocator, id: ChunkId) void {
        if (self.modified_chunks.get(id).?.metadata.timed.events.items.len == 0) {
            _ = self.timed_chunks.remove(id);
        } else self.timed_chunks.put(allocator, id, {}) catch @panic("OOM");
    }

    fn transformChunk(self: *WorkerState, allocator: std.mem.Allocator, coords: ChunkCoords) bool {
        const id = self.layout.encodeChunkCoords(coords);
        const source = self.modified_chunks.getPtr(id) orelse return false;
        const live = self.liveAllocator(allocator);
        var plan = @import("timer_kernel.zig").prepare(live, source, self.tick) catch |err| {
            if (self.persistence_service) |service| service.failPersistence(err);
            return false;
        };
        defer plan.deinit(live);
        if (!plan.metadata_changed and !plan.material_changed) return false;
        const revision = std.math.add(u64, source.chunk_revision, 1) catch return false;
        const mesh_revision = std.math.add(u64, self.next_mesh_revision, 1) catch return false;
        self.mesh_revisions.ensureUnusedCapacity(allocator, 1) catch return false;
        self.timed_chunks.ensureUnusedCapacity(allocator, 1) catch return false;
        if (self.persistence_service) |service| service.dirty_meshes.ensureUnusedCapacity(allocator, 1) catch return false;
        plan.applyPrepared(source);
        source.chunk_revision = revision;
        if (plan.material_changed) {
            self.next_mesh_revision = mesh_revision;
            self.mesh_revisions.putAssumeCapacity(id, mesh_revision);
        }
        if (source.metadata.timed.events.items.len == 0) _ = self.timed_chunks.remove(id) else self.timed_chunks.putAssumeCapacity(id, {});
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

fn readStateBlock(state: *WorkerState, block: [3]u32) @import("engine").voxel_chunk.BlockType {
    const coords, const local = world_module.splitBlockCoords(block);
    const chunk = state.loadAt(std.testing.allocator, coords);
    defer chunk.deinit(std.testing.allocator);
    return chunk.content.getBlock(local);
}

test "service publishes road formation and reversion atomically and retains custom meshes after eviction" {
    const allocator = std.testing.allocator;
    const service = try WorldDataService.create(std.testing.io, allocator, &test_layout, .flat);
    defer service.destroy();
    const editor = try service.createClient();
    const blocks = try service.createClient();
    const meshes = try service.createClient();
    const z: u32 = test_layout.size_in_blocks[2] / 2;
    const high = [3]u32{ 31, 65, z };
    const low = [3]u32{ 44, 65, z - 1 };
    const section_coords: ChunkCoords = .{ 1, 2, @intCast(z / CHUNK_SIZE) };
    const low_coords: ChunkCoords = .{ 1, 2, section_coords[2] - 1 };
    for (0..13) |i| _ = editor.submitOperation(.{ .block = .{ high[0] + @as(u32, @intCast(i)), high[1], z - 1 }, .action = .{ .put = .snow } });
    _ = editor.submitOperation(.{ .block = .{ low[0], low[1], z - 2 }, .action = .{ .put = .snow } });
    _ = editor.submitOperation(.{ .block = high, .action = .{ .put = .country_road_solid } });
    for (1..13) |i| _ = editor.submitOperation(.{ .block = .{ high[0] + @as(u32, @intCast(i)), high[1], z }, .action = .{ .put = .country_road_adaptive } });
    var edits: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&edits);
    try waitForResponses(editor, &edits, 27);
    for (edits.items) |response| try std.testing.expectEqual(OperationStatus.success, response.operation.?.status);
    _ = blocks.requestChunks(.{ 1, 2 }, low_coords[2], section_coords[2] + 1);
    const mesh_token = meshes.requestChunksInMode(.{ 1, 2 }, section_coords[2], section_coords[2] + 1, .mesh);
    var initial_blocks: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&initial_blocks);
    try waitForResponses(blocks, &initial_blocks, 2);
    var initial_mesh: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&initial_mesh);
    try waitForResponses(meshes, &initial_mesh, 1);
    try std.testing.expectEqual(@as(usize, 12), initial_mesh.items[0].data.mesh.custom_blocks.items.len);
    for (initial_mesh.items[0].data.mesh.custom_blocks.items) |block| try std.testing.expect(block.shape == .adaptive);
    _ = editor.submitOperation(.{ .block = low, .action = .{ .put = .country_road_solid } });
    try waitForResponses(editor, &edits, 28);
    var packages: std.ArrayList(ResponsePackage) = .empty;
    defer deinitTestPackages(&packages);
    blocks.takePackages(&packages);
    try std.testing.expectEqual(@as(usize, 1), packages.items.len);
    var found_sections = false;
    var found_endpoint = false;
    var section_revision: u64 = 0;
    for (packages.items[0].responses.items) |response| {
        if (response.data != .blocks) continue;
        if (@reduce(.And, response.coords == section_coords)) {
            found_sections = true;
            section_revision = response.chunk_revision;
            for (response.data.blocks.chunk.metadata.roads.items) |road| {
                try std.testing.expectEqual(@as(u32, 12), road.slope.?.length);
                try std.testing.expectEqual(@import("engine").voxel_chunk.custom_block.Direction.positive_x, road.slope.?.downhill);
            }
        }
        if (@reduce(.And, response.coords == low_coords)) found_endpoint = true;
    }
    try std.testing.expect(found_sections and found_endpoint);
    var formed_mesh: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&formed_mesh);
    try waitForResponses(meshes, &formed_mesh, 1);
    for (formed_mesh.items[0].data.mesh.custom_blocks.items) |block| try std.testing.expect(block.shape == .slope);
    meshes.evictChunk(test_layout.encodeChunkCoords(section_coords), mesh_token);
    _ = meshes.requestChunksInMode(.{ 1, 2 }, section_coords[2], section_coords[2] + 1, .mesh);
    var reloaded: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&reloaded);
    try waitForResponses(meshes, &reloaded, 1);
    try std.testing.expectEqual(section_revision, reloaded.items[0].chunk_revision);
    for (reloaded.items[0].data.mesh.custom_blocks.items) |block| try std.testing.expect(block.shape == .slope);
    // Service validation rejects removal of a road's direct support.
    _ = editor.submitOperation(.{ .block = .{ 34, 65, z - 1 }, .action = .remove });
    try waitForResponses(editor, &edits, 29);
    try std.testing.expectEqual(OperationStatus.constraint_violation, edits.items[28].operation.?.status);
    _ = editor.submitOperation(.{ .block = high, .action = .remove });
    try waitForResponses(editor, &edits, 30);
    var reverted: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&reverted);
    try waitForResponses(meshes, &reverted, 1);
    try std.testing.expect(reverted.items[0].chunk_revision > section_revision);
    for (reverted.items[0].data.mesh.custom_blocks.items) |block| try std.testing.expect(block.shape == .adaptive);
}

test "client and authority agree with only the player's 3x3x3 chunks and ignore extra support beyond 28 cells" {
    const allocator = std.testing.allocator;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    const Setup = struct {
        fn put(state: *WorkerState, cell: rules.Cell, material: rules.BlockType) void {
            const reader: rules.Reader = .{ .layout = state.layout, .context = state, .block_at = undefined };
            const normalized = reader.normalize(cell).?;
            const coords, const local = world_module.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
            const id = state.layout.encodeChunkCoords(coords);
            if (!state.modified_chunks.contains(id)) state.modified_chunks.put(std.testing.allocator, id, WorldChunk.initEmpty()) catch @panic("OOM");
            const chunk = state.modified_chunks.getPtr(id).?;
            std.debug.assert(chunk.apply(std.testing.allocator, local, .{ .put = material }) == .success);
            if (material == .rebar) chunk.metadata.markConstructed(std.testing.allocator, transformations.index(local));
        }
    };
    for ([_]rules.Cell{ .{ 64, 64, 64 }, .{ 95, 95, 95 }, .{ 255, 95, 95 } }) |player| {
        for ([_]u32{ 28, 29 }) |reach| {
            var state: WorkerState = .{ .layout = &layout, .generator = try WorldGenerator.prepare(.flat, allocator, &layout) };
            defer state.deinit(allocator);
            var client = try world_module.World.init(allocator, &layout);
            defer client.deinit();
            const reader: rules.Reader = .{ .layout = &layout, .context = &state, .block_at = undefined };
            // Exercise both extreme tool directions from a chunk boundary, plus x wrap.
            const delta: i64 = if (player[0] == 64) -4 else 4;
            const target = reader.normalize(player + @as(rules.Cell, @splat(delta))).?;
            const direction: i64 = if (delta < 0) 1 else -1;
            const levels = (reach + rules.Limits.reinforced_span - 1) / rules.Limits.reinforced_span;
            const origin = target - rules.Cell{ direction * reach, 0, levels };
            const player_chunk: ChunkCoords = .{ @intCast(@divFloor(player[0], CHUNK_SIZE)), @intCast(@divFloor(player[1], CHUNK_SIZE)), @intCast(@divFloor(player[2], CHUNK_SIZE)) };
            for (0..3) |z| {
                for (0..3) |y| {
                    for (0..3) |x| {
                        const coords = layout.normalizeChunkCoords(player_chunk + ChunkCoords{ @as(i32, @intCast(x)) - 1, @as(i32, @intCast(y)) - 1, @as(i32, @intCast(z)) - 1 }).?;
                        try state.modified_chunks.put(allocator, layout.encodeChunkCoords(coords), WorldChunk.initEmpty());
                    }
                }
            }
            Setup.put(&state, origin - rules.Cell{ 0, 0, 1 }, .stone);
            Setup.put(&state, origin, .rebar);
            var progress: u32 = 0;
            var level: i64 = 0;
            while (progress < reach) {
                const length = @min(rules.Limits.reinforced_span, reach - progress);
                level += 1;
                for (0..length + 1) |offset| {
                    if (progress + offset == reach) continue;
                    Setup.put(&state, origin + rules.Cell{ direction * @as(i64, @intCast(progress + offset)), 0, level }, .rebar);
                }
                progress += length;
            }
            // Subscribe the client to exactly the player's 27 chunks, even when the
            // authoritative fallback foundation lies just beyond those subscriptions.
            for (0..3) |z| {
                for (0..3) |y| {
                    for (0..3) |x| {
                        const coords = layout.normalizeChunkCoords(player_chunk + ChunkCoords{ @as(i32, @intCast(x)) - 1, @as(i32, @intCast(y)) - 1, @as(i32, @intCast(z)) - 1 }).?;
                        try client.insertChunk(coords, state.modified_chunks.get(layout.encodeChunkCoords(coords)).?.clone(allocator));
                    }
                }
            }
            try std.testing.expectEqual(27, client.chunks.count());
            const operation: BlockOperation = .{ .block = .{ @intCast(target[0]), @intCast(target[1]), @intCast(target[2]) }, .action = .{ .put = .rebar } };
            const preview = client.previewOperation(operation);
            try std.testing.expectEqual(if (reach == 28) OperationStatus.success else OperationStatus.constraint_violation, preview.status);
            if (reach == 29) try std.testing.expectEqual(rules.Reason.support_search_limit, preview.failure.?.reason);
            // Additional loaded chunks cannot change a decision or its diagnostics.
            var iterator = state.modified_chunks.iterator();
            while (iterator.next()) |entry| {
                const coords = layout.decodeChunkId(entry.key_ptr.*);
                if (!client.hasChunk(coords)) try client.insertChunk(coords, entry.value_ptr.clone(allocator));
            }
            try std.testing.expectEqualDeep(preview, client.previewOperation(operation));
            const applied = state.applyOperation(allocator, operation);
            defer applied.chunk.deinit(allocator);
            try std.testing.expectEqualDeep(preview, applied.diagnostics);
        }
    }
}

test "generated soil is already packed and grassy, but newly exposed soil waits thirty minutes" {
    const allocator = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.{
        .terrain = .{ .seed = 12345, .params = .{ .base_height = CHUNK_SIZE + 1, .height_amplitude = 0 } },
    }, allocator, &test_layout) };
    defer state.deinit(allocator);
    // Put the surface in the first layer of a chunk, with packed soil in the chunk below.
    const surface = [3]u32{ 10, 10, CHUNK_SIZE };
    const below = [3]u32{ 10, 10, CHUNK_SIZE - 1 };
    for ([_]transformations.Tick{ 0, transformations.transformation_delay * 2 }) |tick| {
        state.tick = tick;
        try std.testing.expectEqual(.grass, readStateBlock(&state, surface));
        try std.testing.expectEqual(.packed_dirt, readStateBlock(&state, below));
        try std.testing.expectEqual(.stone, readStateBlock(&state, .{ 10, 10, CHUNK_SIZE - 5 }));
        // Untouched terrain needs neither scheduled events nor retained modified chunks.
        try std.testing.expectEqual(0, state.timed_chunks.count());
        try std.testing.expectEqual(0, state.modified_chunks.count());
    }
    const mined = state.applyOperation(allocator, .{ .block = surface, .action = .remove });
    defer mined.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, mined.status);
    try std.testing.expectEqual(.dirt, mined.diagnostics.mined_type.?);
    const below_coords, _ = world_module.splitBlockCoords(below);
    try std.testing.expectEqual(below_coords, mined.changed_below.?);
    const events = state.modified_chunks.get(test_layout.encodeChunkCoords(below_coords)).?.metadata.timed.events.items;
    try std.testing.expectEqual(1, events.len);
    try std.testing.expectEqual(transformations.Kind.grow_grass, events[0].kind);
    try std.testing.expectEqual(state.tick + transformations.transformation_delay, events[0].due_tick);
    state.tick += transformations.transformation_delay - 1;
    try std.testing.expect(!state.transformChunk(allocator, below_coords));
    try std.testing.expectEqual(.packed_dirt, readStateBlock(&state, below));
    state.tick += 1;
    try std.testing.expect(state.transformChunk(allocator, below_coords));
    try std.testing.expectEqual(.grass, readStateBlock(&state, below));
    try std.testing.expectEqual(0, state.timed_chunks.count());
}

test "soil compacts at thirty minutes, grows grass later, and resets exposure after covering" {
    const allocator = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, allocator, &test_layout) };
    defer state.deinit(allocator);
    const surface = test_layout.size_in_blocks[2] / 2 - CHUNK_SIZE / 2;
    const block = [3]u32{ 10, 10, surface };
    const coords, _ = world_module.splitBlockCoords(block);
    const placed = state.applyOperation(allocator, .{ .block = block, .action = .{ .put = .dirt } });
    defer placed.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, placed.status);
    state.tick = transformations.transformation_delay - 1;
    try std.testing.expect(!state.transformChunk(allocator, coords));
    try std.testing.expectEqual(.dirt, readStateBlock(&state, block));
    state.tick += 1;
    try std.testing.expect(state.transformChunk(allocator, coords));
    try std.testing.expectEqual(.packed_dirt, readStateBlock(&state, block));
    state.tick = transformations.transformation_delay * 2;
    try std.testing.expect(state.transformChunk(allocator, coords));
    try std.testing.expectEqual(.grass, readStateBlock(&state, block));
    var above = block;
    above[2] += 1;
    // Sand is outside this feature's structural groups and can cover the surface.
    const cover = state.applyOperation(allocator, .{ .block = above, .action = .{ .put = .sand } });
    defer cover.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, cover.status);
    try std.testing.expectEqual(.packed_dirt, readStateBlock(&state, block));
    state.tick += transformations.transformation_delay;
    try std.testing.expect(!state.transformChunk(allocator, coords));
    const uncover = state.applyOperation(allocator, .{ .block = above, .action = .remove });
    defer uncover.chunk.deinit(allocator);
    state.tick += transformations.transformation_delay - 1;
    try std.testing.expect(!state.transformChunk(allocator, coords));
    state.tick += 1;
    try std.testing.expect(state.transformChunk(allocator, coords));
    try std.testing.expectEqual(.grass, readStateBlock(&state, block));
}

test "covering loose earth across a chunk boundary compacts it and cancels its old deadline" {
    const allocator = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, allocator, &test_layout) };
    defer state.deinit(allocator);
    const lower_coords: ChunkCoords = .{ 0, 0, 3 };
    const data = try allocator.create(@import("world_chunk_data.zig").WorldChunkData);
    data.* = @import("world_chunk_data.zig").WorldChunkData.initFilled(.packed_dirt);
    data.blocks[31][10][10] = .dirt;
    var lower = WorldChunk.initBlocks(data);
    lower.metadata.timed.schedule(allocator, .{ .block = transformations.index(.{ 10, 10, 31 }), .kind = .compact_dirt, .due_tick = transformations.transformation_delay });
    try state.modified_chunks.put(allocator, test_layout.encodeChunkCoords(lower_coords), lower);
    const block = [3]u32{ 10, 10, 4 * CHUNK_SIZE };
    const placed = state.applyOperation(allocator, .{ .block = block, .action = .{ .put = .planks } });
    defer placed.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, placed.status);
    try std.testing.expectEqual(lower_coords, placed.changed_below.?);
    const packed_chunk = state.modified_chunks.get(test_layout.encodeChunkCoords(lower_coords)).?;
    try std.testing.expectEqual(.packed_dirt, packed_chunk.content.getBlock(.{ 10, 10, 31 }));
    try std.testing.expectEqual(0, packed_chunk.metadata.timed.events.items.len);
    const removed = state.applyOperation(allocator, .{ .block = block, .action = .remove });
    defer removed.chunk.deinit(allocator);
    state.tick = transformations.transformation_delay;
    try std.testing.expect(state.transformChunk(allocator, lower_coords));
    try std.testing.expectEqual(.grass, readStateBlock(&state, .{ 10, 10, 4 * CHUNK_SIZE - 1 }));
}

test "mining natural stone yields crushed stone and does not allow placing natural rock" {
    const allocator = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, allocator, &test_layout) };
    defer state.deinit(allocator);
    const block = [3]u32{ 10, 10, test_layout.size_in_blocks[2] / 2 - CHUNK_SIZE / 2 - 1 };
    const mined = state.applyOperation(allocator, .{ .block = block, .action = .remove });
    defer mined.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, mined.status);
    try std.testing.expectEqual(.crushed_stone, mined.diagnostics.mined_type.?);
    const replaced = state.applyOperation(allocator, .{ .block = block, .action = .{ .put = .stone } });
    defer replaced.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.constraint_violation, replaced.status);
    try std.testing.expectEqual(rules.Reason.material_not_placeable, replaced.diagnostics.failure.?.reason);
}

test "evicting a subscription preserves timers and a large time step catches up both stages" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const block = [3]u32{ 10, 10, test_layout.size_in_blocks[2] / 2 - CHUNK_SIZE / 2 };
    const coords, const local = world_module.splitBlockCoords(block);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    const token = client.requestChunks(.{ 0, 0 }, coords[2], coords[2] + 1);
    try waitForResponses(client, &responses, 1);
    for (responses.items) |response| response.deinit(std.testing.allocator);
    responses.clearRetainingCapacity();
    _ = client.submitOperation(.{ .block = block, .action = .{ .put = .dirt } });
    try waitForResponses(client, &responses, 1);
    try std.testing.expectEqual(OperationStatus.success, responses.items[0].operation.?.status);
    for (responses.items) |response| response.deinit(std.testing.allocator);
    responses.clearRetainingCapacity();
    client.evictChunk(test_layout.encodeChunkCoords(coords), token);
    service.advanceTo(transformations.transformation_delay * 2);
    const reloaded = client.requestChunks(.{ 0, 0 }, coords[2], coords[2] + 1);
    var grown = false;
    while (!grown) {
        try std.testing.expect(try client.waitResponses(&responses));
        for (responses.items) |response| {
            if (response.subscription_id == reloaded and response.data == .blocks)
                grown = grown or response.data.blocks.chunk.content.getBlock(local) == .grass;
            response.deinit(std.testing.allocator);
        }
        responses.clearRetainingCapacity();
    }
    _ = client.submitOperation(.{ .block = block, .action = .remove });
    try waitForResponses(client, &responses, 1);
    try std.testing.expectEqual(.dirt, responses.items[0].operation.?.mined_type.?);
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
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, generator);
    defer service.destroy();
    const client = try service.createClient();
    const token = client.requestChunks(.{ 10, 20 }, 2, 6);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(client, &responses, 4);
    const column = ColumnGenerator.init(&service.worker_state.generator, .{ 10, 20 });
    for (responses.items, 2..) |response, z| {
        const expected = column.generateChunk(std.testing.allocator, @intCast(z));
        defer expected.deinit(std.testing.allocator);
        try std.testing.expectEqual(token, response.subscription_id);
        try std.testing.expectEqual(null, response.operation);
        try std.testing.expectEqual(ChunkCoords{ 10, 20, @intCast(z) }, response.coords);
        try std.testing.expectEqual(expected.flags, response.data.blocks.chunk.flags);
        try std.testing.expectEqual(expected.solid_block_count, response.data.blocks.chunk.solid_block_count);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.content.toData()), std.mem.asBytes(&response.data.blocks.chunk.content.toData()));
    }
}

test "service validates generator settings before startup and supports wide periods" {
    const small = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    try std.testing.expectError(error.NoisePeriodOutOfRange, WorldDataService.create(std.testing.io, std.testing.allocator, &small, .{ .terrain = .{ .seed = 1, .params = .{ .noise_scale = 0x1p-57, .octaves = 1 } } }));
    try std.testing.expectError(error.NoiseAmplitudeOutOfRange, WorldDataService.create(std.testing.io, std.testing.allocator, &small, .{ .terrain = .{ .seed = 1, .params = .{ .persistence = 1e308, .octaves = 3 } } }));
    const tall = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 1 << 26, 2 } });
    try std.testing.expectError(error.NoiseCoordinateOutOfRange, WorldDataService.create(std.testing.io, std.testing.allocator, &tall, .{ .terrain = .{ .seed = 1, .params = .{ .noise_scale = 0x1p-33, .octaves = 1 } } }));

    const wide = try WorldLayout.init(.{ .size_in_chunks = .{ 1 << 26, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &wide, .{ .terrain = .{ .seed = 12345, .params = .{ .noise_scale = 4 } } });
    defer service.destroy();
    try std.testing.expectEqual(@as(i64, 1) << 32, service.worker_state.generator.kind.terrain.octaves[3].x_period);
    // Requests exercise generation on the worker, including the far x seam.
    const client = try service.createClient();
    _ = client.requestChunks(.{ wide.size_in_chunks[0] - 1, 1 }, 0, 2);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(client, &responses, 2);
    for (responses.items) |response| {
        try std.testing.expectEqual(wide.size_in_chunks[0] - 1, response.coords[0]);
        try std.testing.expect(response.data == .blocks);
    }
}

test "service startup frees prepared octaves on allocation failure" {
    const Fixture = struct {
        fn createAndDestroy(allocator: std.mem.Allocator) !void {
            const service = try WorldDataService.create(std.testing.io, allocator, &test_layout, .{ .terrain = .{ .seed = 12345 } });
            defer service.destroy();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.createAndDestroy, .{});
}

test "commands validate against authority and return status plus independent snapshots" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const block = [3]u32{ 1, 2, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    const put = client.submitOperation(.{ .block = block, .action = .{ .put = .sand } });
    const duplicate = client.submitOperation(.{ .block = block, .action = .{ .put = .snow } });
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
        try std.testing.expectEqual(revision, response.data.blocks.chunk.chunk_revision);
    }
    try std.testing.expectEqual(.sand, responses.items[0].data.blocks.chunk.content.getBlock(.{ 1, 2, 31 }));
    try std.testing.expectEqual(.sand, responses.items[1].data.blocks.chunk.content.getBlock(.{ 1, 2, 31 }));
    try std.testing.expectEqual(1, responses.items[1].data.blocks.chunk.solid_block_count);
    try std.testing.expect(responses.items[2].data.blocks.chunk.content == .empty);
    try std.testing.expectEqual(WorldChunk.initEmpty().flags, responses.items[2].data.blocks.chunk.flags);
}

test "successful edits push data only to subscribers and combine the origin reply" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const origin = try service.createClient();
    const observer = try service.createClient();
    const other = try service.createClient();
    const z = WORLD_SIZE[2] - 1;
    const origin_token = origin.requestChunks(.{ 0, 0 }, z, z + 1);
    const observer_token = observer.requestChunks(.{ 0, 0 }, z, z + 1);
    _ = other.requestChunks(.{ 1, 0 }, z, z + 1);
    const block = [3]u32{ 0, 0, z * CHUNK_SIZE };
    const id = origin.submitOperation(.{ .block = block, .action = .{ .put = .sand } });
    _ = origin.submitOperation(.{ .block = block, .action = .{ .put = .snow } });
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
    try std.testing.expectEqual(.sand, observed.items[1].data.blocks.chunk.content.getBlock(.{ 0, 0, 0 }));
    try std.testing.expectEqual(origin_token, origin_responses.items[1].subscription_id);
    try std.testing.expectEqual(id, origin_responses.items[1].operation.?.request_id);
    var unrelated: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&unrelated);
    other.takeResponses(&unrelated);
    try std.testing.expectEqual(1, unrelated.items.len);
}

test "eviction stops pushes and a fresh load returns committed edits with a new token" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const main = try service.createClient();
    const npc = try service.createClient();
    const z = WORLD_SIZE[2] - 1;
    const position = test_layout.encodeChunkId(0, 0, z);
    const old_token = main.requestChunks(.{ 0, 0 }, z, z + 1);
    const block = [3]u32{ 16, 16, z * CHUNK_SIZE };
    _ = npc.submitOperation(.{ .block = block, .action = .{ .put = .sand } });
    main.evictChunk(position, old_token);
    _ = npc.submitOperation(.{ .block = block, .action = .remove });
    const new_token = main.requestChunks(.{ 0, 0 }, z, z + 1);
    // A delayed eviction for the old generation must not remove the new subscription.
    main.evictChunk(position, old_token);
    _ = npc.submitOperation(.{ .block = block, .action = .{ .put = .snow } });
    var npc_responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&npc_responses);
    try waitForResponses(npc, &npc_responses, 3);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    main.takeResponses(&responses);
    try std.testing.expect(responses.items.len >= 3);
    try std.testing.expectEqual(old_token, responses.items[0].subscription_id);
    var fresh = false;
    for (responses.items[1..]) |reply| {
        if (reply.subscription_id == new_token and reply.data.blocks.chunk.chunk_revision == 3) fresh = true;
    }
    try std.testing.expect(fresh);
}

fn putFromClient(client: *Client, block: [3]u32) void {
    _ = client.submitOperation(.{ .block = block, .action = .{ .put = .sand } });
}

test "concurrent clients cannot both put into the same empty block" {
    const io = std.testing.io;
    const service = try WorldDataService.create(io, std.testing.allocator, &test_layout, .flat);
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
    try std.testing.expectEqual(1, a_responses.items[0].data.blocks.chunk.chunk_revision);
    try std.testing.expectEqual(1, b_responses.items[0].data.blocks.chunk.chunk_revision);
}

test "service shutdown drains edits and frees unconsumed replies" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    const client = try service.createClient();
    for (0..4) |x| _ = client.requestChunks(.{ @intCast(x), 0 }, 0, WORLD_SIZE[2]);
    _ = client.submitOperation(.{ .block = .{ 0, 0, 0 }, .action = .remove });
    service.destroy();
}

test "shutdown skips generation requests but still commits commands" {
    var service = WorldDataService{
        .layout = &test_layout,
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .worker = undefined,
        .worker_state = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, std.testing.allocator, &test_layout) },
    };
    var client = Client{ .service = &service };
    defer service.requests.deinit(std.testing.allocator);
    defer service.worker_state.deinit(std.testing.allocator);
    defer client.responses.deinit(std.testing.allocator);
    defer client.pending.deinit(std.testing.allocator);
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
    var state = WorkerState{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = .{ .base_height = 200, .height_amplitude = 0 } } }, std.testing.allocator, &test_layout) };
    defer state.deinit(std.testing.allocator);
    const coords = ChunkCoords{ 0, 2, 3 };
    for (std.enums.values(Side), 0..) |side, index| {
        var local = [3]u32{ 8, 8, 8 };
        local[index / 2] = if (index % 2 == 0) 0 else CHUNK_SIZE - 1;
        const result = state.applyOperation(std.testing.allocator, .{
            .block = .{ @as(u32, @intCast(coords[0])) * CHUNK_SIZE + local[0], @as(u32, @intCast(coords[1])) * CHUNK_SIZE + local[1], @as(u32, @intCast(coords[2])) * CHUNK_SIZE + local[2] },
            .action = .remove,
        });
        defer result.chunk.deinit(std.testing.allocator);
        try std.testing.expectEqual(OperationStatus.success, result.status);
        try std.testing.expectEqual(index + 1, result.chunk.chunk_revision);
        for (result.revealed_neighbors, 0..) |neighbor_opt, neighbor_index| {
            if (neighbor_index == index) {
                const neighbor_coords = world_module.adjacentChunk(&test_layout, coords, side).?;
                try std.testing.expectEqual(neighbor_coords, neighbor_opt.?);
                const retained = state.modified_chunks.get(test_layout.encodeChunkCoords(neighbor_coords)).?;
                try std.testing.expect(!retained.flags.is_unreachable);
                try std.testing.expect(retained.isDirty());
                try std.testing.expectEqual(1, retained.chunk_revision);
                try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, retained.solid_block_count);
                const reloaded = state.loadChunk(std.testing.allocator, neighbor_coords);
                defer reloaded.deinit(std.testing.allocator);
                try std.testing.expectEqual(retained.flags, reloaded.flags);
                try std.testing.expectEqual(retained.chunk_revision, reloaded.chunk_revision);
            } else {
                try std.testing.expectEqual(null, neighbor_opt);
            }
        }
    }
    try std.testing.expectEqual(7, state.modified_chunks.count());

    // Resealing and reopening a wall never hides or revises the revealed neighbor again.
    for ([_]world_module.BlockAction{ .{ .put = .snow }, .remove, .remove }) |action| {
        const result = state.applyOperation(std.testing.allocator, .{
            .block = .{ 0, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 },
            .action = action,
        });
        defer result.chunk.deinit(std.testing.allocator);
        for (result.revealed_neighbors) |neighbor| try std.testing.expectEqual(null, neighbor);
    }
    const wrapped_neighbor = state.modified_chunks.get(test_layout.encodeChunkId(WORLD_SIZE[0] - 1, 2, 3)).?;
    try std.testing.expectEqual(1, wrapped_neighbor.chunk_revision);
    try std.testing.expect(!wrapped_neighbor.flags.is_unreachable);
}

test "interior edits expose no neighbors and a corner reveals three face neighbors" {
    var state = WorkerState{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, std.testing.allocator, &test_layout) };
    defer state.deinit(std.testing.allocator);
    const interior = state.applyOperation(std.testing.allocator, .{
        .block = .{ 8, 2 * CHUNK_SIZE + 8, 2 * CHUNK_SIZE + 8 },
        .action = .remove,
    });
    defer interior.chunk.deinit(std.testing.allocator);
    try std.testing.expect(interior.chunk.flags.is_unreachable);
    for (interior.revealed_neighbors) |neighbor| try std.testing.expectEqual(null, neighbor);
    try std.testing.expectEqual(1, state.modified_chunks.count());

    const corner = state.applyOperation(std.testing.allocator, .{
        .block = .{ 0, 2 * CHUNK_SIZE, 2 * CHUNK_SIZE },
        .action = .remove,
    });
    defer corner.chunk.deinit(std.testing.allocator);
    for (corner.revealed_neighbors, 0..) |neighbor, side| {
        try std.testing.expectEqual(side % 2 == 0, neighbor != null);
    }
    try std.testing.expectEqual(4, state.modified_chunks.count());
    try std.testing.expect(!state.modified_chunks.contains(test_layout.encodeChunkId(WORLD_SIZE[0] - 1, 1, 1)));

    // Revealing a previously edited chunk must preserve its blocks and advance its own
    // revision, independently of the operation that opened the neighboring wall.
    const opening = state.applyOperation(std.testing.allocator, .{
        .block = .{ CHUNK_SIZE, 2 * CHUNK_SIZE + 8, 2 * CHUNK_SIZE + 8 },
        .action = .remove,
    });
    defer opening.chunk.deinit(std.testing.allocator);
    try std.testing.expectEqual(ChunkCoords{ 0, 2, 2 }, opening.revealed_neighbors[@intFromEnum(Side.left)].?);
    const revealed = state.modified_chunks.get(test_layout.encodeChunkId(0, 2, 2)).?;
    try std.testing.expectEqual(3, revealed.chunk_revision);
    try std.testing.expect(!revealed.flags.is_unreachable);
    try std.testing.expectEqual(.none, revealed.content.getBlock(.{ 8, 8, 8 }));
    try std.testing.expectEqual(.none, revealed.content.getBlock(.{ 0, 0, 0 }));
    try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE - 2, revealed.solid_block_count);
}

test "reveals notify all neighbor subscribers and survive eviction and reload" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const origin = try service.createClient();
    const observer = try service.createClient();
    const other = try service.createClient();
    const coords = ChunkCoords{ 1, 1, 2 };
    const position = test_layout.encodeChunkCoords(coords);
    const origin_token = origin.requestChunks(.{ 1, 1 }, 2, 3);
    const observer_token = observer.requestChunks(.{ 1, 1 }, 2, 3);
    _ = other.requestChunks(.{ 5, 5 }, 2, 3);
    const edit = origin.submitOperation(.{ .block = .{ CHUNK_SIZE + 8, CHUNK_SIZE + 8, 3 * CHUNK_SIZE }, .action = .remove });
    var origin_responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&origin_responses);
    try waitForResponses(origin, &origin_responses, 3);
    try std.testing.expect(origin_responses.items[0].data.blocks.chunk.flags.is_unreachable);
    var reveal: ?ChunkResponse = null;
    var acknowledged = false;
    for (origin_responses.items) |reply| {
        if (reply.operation) |operation_result| {
            if (operation_result.request_id == edit) acknowledged = true;
        } else if (@reduce(.And, reply.coords == coords) and !reply.data.blocks.chunk.flags.is_unreachable) reveal = reply;
    }
    try std.testing.expect(acknowledged);
    try std.testing.expectEqual(origin_token, reveal.?.subscription_id);
    try std.testing.expectEqual(1, reveal.?.data.blocks.chunk.chunk_revision);

    var observed: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&observed);
    observer.takeResponses(&observed);
    try std.testing.expectEqual(2, observed.items.len);
    try std.testing.expectEqual(observer_token, observed.items[1].subscription_id);
    try std.testing.expectEqual(coords, observed.items[1].coords);
    try std.testing.expectEqual(null, observed.items[1].operation);
    try std.testing.expectEqual(1, observed.items[1].data.blocks.chunk.chunk_revision);
    try std.testing.expect(!observed.items[1].data.blocks.chunk.flags.is_unreachable);
    var unrelated: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&unrelated);
    other.takeResponses(&unrelated);
    try std.testing.expectEqual(1, unrelated.items.len);

    origin.evictChunk(position, origin_token);
    const reload_token = origin.requestChunks(.{ 1, 1 }, 2, 3);
    try waitForResponses(origin, &origin_responses, 4);
    const reload = origin_responses.items[3];
    try std.testing.expectEqual(reload_token, reload.subscription_id);
    try std.testing.expectEqual(1, reload.data.blocks.chunk.chunk_revision);
    try std.testing.expect(!reload.data.blocks.chunk.flags.is_unreachable);
    try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, reload.data.blocks.chunk.solid_block_count);
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
    const service = try WorldDataService.create(std.testing.io, allocator, &test_layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    _ = client.requestChunks(.{ 0, 2 }, 3, 4);
    const neighbor = ChunkCoords{ WORLD_SIZE[0] - 1, 2, 3 };
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
    client.evictChunk(test_layout.encodeChunkCoords(neighbor), mesh_token);
    var promoted: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&promoted);
    try waitForResponses(client, &promoted, 1);
    try std.testing.expectEqual(block_token, promoted.items[0].subscription_id);
    try std.testing.expectEqual(updates[1].mesh_revision, promoted.items[0].mesh_revision);
    try std.testing.expectEqual(updates[1].chunk_revision, promoted.items[0].chunk_revision);

    client.evictChunk(test_layout.encodeChunkCoords(neighbor), block_token);
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
    const service = try WorldDataService.create(std.testing.io, allocator, &test_layout, .flat);
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
        .{ .block = .{ 3 * CHUNK_SIZE - 1, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 }, .action = .{ .put = .sand } },
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

test "unreachable mesh subscriptions receive only metadata until reveal while block subscriptions receive blocks" {
    const allocator = std.testing.allocator;
    const service = try WorldDataService.create(std.testing.io, allocator, &test_layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const token = client.requestChunksInMode(.{ 2, 2 }, 2, 3, .mesh);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try waitForResponses(client, &responses, 1);
    try std.testing.expect(responses.items[0].data == .unreachable_chunk);
    try std.testing.expectEqual(token, responses.items[0].subscription_id.?);
    try std.testing.expectEqual(0, responses.items[0].chunk_revision);

    const block_client = try service.createClient();
    _ = block_client.requestChunks(.{ 2, 2 }, 2, 3);
    var block_responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&block_responses);
    try waitForResponses(block_client, &block_responses, 1);
    const enclosed = block_responses.items[0].data.blocks.chunk;
    try std.testing.expect(enclosed.flags.is_unreachable);
    try std.testing.expect(enclosed.content == .blocks);
    try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, enclosed.solid_block_count);
    _ = client.submitOperation(.{ .block = .{ 2 * CHUNK_SIZE + 8, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE }, .action = .remove });
    var packages = try takeTestPackages(client);
    defer deinitTestPackages(&packages);
    var revealed = false;
    for (packages.items[0].responses.items) |response| {
        if (response.subscription_id != token) continue;
        try std.testing.expectEqual(1, response.chunk_revision);
        try std.testing.expect(response.mesh_revision > responses.items[0].mesh_revision);
        try std.testing.expectEqual(1, response.data.mesh.blocks_grouped_by_side[@intFromEnum(Side.top)].items.len);
        revealed = true;
    }
    try std.testing.expect(revealed);
    _ = client.requestChunks(.{ 2, 2 }, 2, 3);
    try waitForResponses(client, &responses, 2);
    try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, responses.items[1].data.blocks.chunk.solid_block_count);
}

test "default terrain 7x7x7 meshes fit the unchanged GPU allocator including fragmentation" {
    const allocator = std.testing.allocator;
    const service = try WorldDataService.create(std.testing.io, allocator, &test_layout, .{ .terrain = .{ .seed = 12345 } });
    defer service.destroy();
    const client = try service.createClient();
    const origin = test_layout.origin_chunk;
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
        if (response.data == .unreachable_chunk) continue;
        for (response.data.mesh.blocks_grouped_by_side) |side| bytes += 4 * side.items.len;
        grid.appendChunk(.{ .chunk_coords = response.coords, .chunk_side_data = response.data.mesh.clone(allocator) });
    }
    try std.testing.expect(bytes > 0);
    try std.testing.expect(grid.hasUploadCapacity());
    std.debug.print("7x7x7 terrain: {d} KiB of mesh payload; fits 4 MiB slot allocator\n", .{bytes / 1024});
}

test "block subscriptions receive coalesced neighbor masks with mesh updates across x wrap" {
    const allocator = std.testing.allocator;
    const service = try WorldDataService.create(std.testing.io, allocator, &test_layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const coords = ChunkCoords{ 0, 2, 3 };
    const remote = ChunkCoords{ WORLD_SIZE[0] - 1, 2, 3 };
    const block_token = client.requestChunks(.{ coords[0], coords[1] }, 3, 4);
    const mesh_token = client.requestChunksInMode(.{ remote[0], remote[1] }, 3, 4, .mesh);
    var initial: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&initial);
    try waitForResponses(client, &initial, 2);
    const masks = initial.items[0].data.blocks.neighbors.?;
    try std.testing.expect(masks[@intFromEnum(Side.left)].contains(.left, .{ 0, 8, 8 }));
    try std.testing.expect(!masks[@intFromEnum(Side.left)].contains(.left, .{ 0, 8, 24 }));

    service.requests.mutex.lockUncancelable(service.io);
    for (8..10) |y| {
        service.requests.items.append(allocator, .{ .operation = .{
            .client = client,
            .request_id = client.nextRequestId(),
            .operation = .{ .block = .{ WORLD_SIZE[0] * CHUNK_SIZE - 1, 2 * CHUNK_SIZE + @as(u32, @intCast(y)), 3 * CHUNK_SIZE + 8 }, .action = .remove },
        } }) catch @panic("OOM");
    }
    service.requests.not_empty.signal(service.io);
    service.requests.mutex.unlock(service.io);
    var packages = try takeTestPackages(client);
    defer deinitTestPackages(&packages);
    try std.testing.expectEqual(1, packages.items.len);
    try std.testing.expectEqual(4, packages.items[0].responses.items.len);
    var boundary_count: usize = 0;
    var mesh_count: usize = 0;
    var ack_count: usize = 0;
    for (packages.items[0].responses.items) |response| {
        if (response.operation != null) ack_count += 1;
        switch (response.data) {
            .boundaries => |updated| {
                boundary_count += 1;
                try std.testing.expectEqual(block_token, response.subscription_id.?);
                try std.testing.expectEqual(coords, response.coords);
                try std.testing.expectEqual(2, response.mesh_revision);
                try std.testing.expect(!updated[0].contains(.left, .{ 0, 8, 8 }));
                try std.testing.expect(!updated[0].contains(.left, .{ 0, 9, 8 }));
                try std.testing.expect(updated[0].contains(.left, .{ 0, 10, 8 }));
                var mesh = mesher.extractChunkSideData(allocator, initial.items[0].data.blocks.chunk.content, updated);
                defer mesh.deinit(allocator);
                try std.testing.expectEqual(2, mesh.blocks_grouped_by_side[0].items.len);
            },
            .mesh => {
                mesh_count += 1;
                try std.testing.expectEqual(mesh_token, response.subscription_id.?);
                try std.testing.expectEqual(2, response.mesh_revision);
            },
            .acknowledgement => {},
            else => return error.UnexpectedBlockSnapshot,
        }
    }
    try std.testing.expectEqual(1, boundary_count);
    try std.testing.expectEqual(1, mesh_count);
    try std.testing.expectEqual(2, ack_count);

    // An interior edit cannot change the dependency mask of the block subscriber.
    _ = client.submitOperation(.{ .block = .{ remote[0] * CHUNK_SIZE + 8, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 }, .action = .remove });
    var interior = try takeTestPackages(client);
    defer deinitTestPackages(&interior);
    for (interior.items) |package| {
        for (package.responses.items) |response| try std.testing.expect(response.data != .boundaries);
    }
    // Initial planes on a new subscription use the edited masks, not generated cache data.
    const reload_token = client.requestChunks(.{ coords[0], coords[1] }, 3, 4);
    var reloaded: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&reloaded);
    try waitForResponses(client, &reloaded, 1);
    try std.testing.expectEqual(reload_token, reloaded.items[0].subscription_id.?);
    try std.testing.expectEqual(0, reloaded.items[0].chunk_revision);
    try std.testing.expectEqual(2, reloaded.items[0].mesh_revision);
    try std.testing.expect(!reloaded.items[0].data.blocks.neighbors.?[0].contains(.left, .{ 0, 8, 8 }));
}

test "neighbor masks expose world edges and cache generated planes independently of blocks" {
    var state = WorkerState{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, std.testing.allocator, &test_layout) };
    defer state.deinit(std.testing.allocator);
    const masks = state.neighborBoundaries(std.testing.allocator, .{ 0, 0, 0 });
    for ([_]Side{ .front, .bottom }) |side| {
        for (masks[@intFromEnum(side)].rows) |row| try std.testing.expectEqual(0, row);
    }
    for ([_]Side{ .left, .right, .back, .top }) |side| {
        for (masks[@intFromEnum(side)].rows) |row| try std.testing.expectEqual(std.math.maxInt(u32), row);
    }
    try std.testing.expectEqual(4, state.boundary_cache.count());
    try std.testing.expectEqual(0, state.modified_chunks.count());
    try std.testing.expectEqualDeep(masks, state.neighborBoundaries(std.testing.allocator, .{ 0, 0, 0 }));
    try std.testing.expectEqual(4, state.boundary_cache.count());
}

test "boundary-only observers are notified before the edit reply without subscribing to the source chunk" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const observer = try service.createClient();
    const editor = try service.createClient();
    const token = observer.requestChunks(.{ 2, 2 }, 3, 4);
    var initial: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&initial);
    try waitForResponses(observer, &initial, 1);
    _ = editor.submitOperation(.{ .block = .{ 3 * CHUNK_SIZE, 2 * CHUNK_SIZE + 8, 3 * CHUNK_SIZE + 8 }, .action = .remove });
    var replies: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&replies);
    try waitForResponses(editor, &replies, 1);
    var observed: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&observed);
    observer.takeResponses(&observed);
    try std.testing.expectEqual(1, observed.items.len);
    try std.testing.expectEqual(token, observed.items[0].subscription_id.?);
    try std.testing.expectEqual(1, observed.items[0].mesh_revision);
    try std.testing.expect(!observed.items[0].data.boundaries[@intFromEnum(Side.right)].contains(.right, .{ 31, 8, 8 }));

    observer.evictChunk(test_layout.encodeChunkCoords(.{ 2, 2, 3 }), token);
    _ = editor.submitOperation(.{ .block = .{ 3 * CHUNK_SIZE, 2 * CHUNK_SIZE + 9, 3 * CHUNK_SIZE + 8 }, .action = .remove });
    try waitForResponses(editor, &replies, 2);
    observer.takeResponses(&observed);
    try std.testing.expectEqual(1, observed.items.len);
}

test "soil placed beneath existing sand packs immediately and waits for exposure before growing grass" {
    const allocator = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, allocator, &test_layout) };
    defer state.deinit(allocator);
    const surface = test_layout.size_in_blocks[2] / 2 - CHUNK_SIZE / 2;
    const block = [3]u32{ 10, 10, surface };
    const covered = state.applyOperation(allocator, .{ .block = .{ 10, 10, surface + 1 }, .action = .{ .put = .sand } });
    defer covered.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, covered.status);
    const placed = state.applyOperation(allocator, .{ .block = block, .action = .{ .put = .dirt } });
    defer placed.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, placed.status);
    try std.testing.expectEqual(rules.BlockType.packed_dirt, readStateBlock(&state, block));
    try std.testing.expectEqual(rules.BlockType.packed_dirt, placed.chunk.content.getBlock(world_module.splitBlockCoords(block)[1]));
    try std.testing.expectEqual(0, placed.chunk.metadata.timed.events.items.len);
    const coords, _ = world_module.splitBlockCoords(block);
    state.tick = transformations.transformation_delay * 2;
    try std.testing.expect(!state.transformChunk(allocator, coords));
    try std.testing.expectEqual(.packed_dirt, readStateBlock(&state, block));
    const uncovered = state.applyOperation(allocator, .{ .block = .{ 10, 10, surface + 1 }, .action = .remove });
    defer uncovered.chunk.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, uncovered.status);
    state.tick += transformations.transformation_delay - 1;
    try std.testing.expect(!state.transformChunk(allocator, coords));
    state.tick += 1;
    try std.testing.expect(state.transformChunk(allocator, coords));
    try std.testing.expectEqual(.grass, readStateBlock(&state, block));
}

fn testSpaceQuery(xy: [2]f64) StandingSpaceRequest {
    return .{ .preferred_xy = xy, .clearance_size = .{ 2, 2, 3 }, .support_size = .{ 0.6, 0.6 } };
}

fn expectEditReply(client: *Client, id: u64) !void {
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try std.testing.expect(try client.waitResponses(&responses));
    try std.testing.expectEqual(1, responses.items.len);
    try std.testing.expectEqual(id, responses.items[0].operation.?.request_id);
    try std.testing.expectEqual(.success, responses.items[0].operation.?.status);
}

test "standing-space requests preserve active terrain subscriptions and queued packages" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const token = client.requestChunks(.{ 0, 0 }, 0, 1);
    const query = testSpaceQuery(.{ -21.5, -21.5 });
    try std.testing.expectEqual(standing_space.Position{ -21.5, -21.5, -16 }, try client.findStandingSpace(query));
    try std.testing.expectEqual(standing_space.Position{ -21.5, -21.5, -16 }, try client.findStandingSpace(query));
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try std.testing.expect(try client.waitResponses(&responses));
    try std.testing.expectEqual(1, responses.items.len);
    try std.testing.expectEqual(token, responses.items[0].subscription_id);
    try std.testing.expectEqual(.blocks, std.meta.activeTag(responses.items[0].data));
    try std.testing.expectEqual(1, client.subscriptions.count());
    try std.testing.expectEqual(1, service.clients.items.len);
}

test "standing-space search sees edits ordered before it, including after terrain eviction" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const token = client.requestChunks(.{ 0, 0 }, 0, 1);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    try std.testing.expect(try client.waitResponses(&responses));
    deinitResponses(&responses);
    client.evictChunk(layout.encodeChunkId(0, 0, 0), token);
    var query = testSpaceQuery(.{ -21.5, -21.5 });
    query.clearance_size = .{ 0.6, 0.6, 1.8 };
    try std.testing.expectEqual(standing_space.Position{ -21.5, -21.5, -16 }, try client.findStandingSpace(query));
    const put = client.submitOperation(.{ .block = .{ 10, 10, 16 }, .action = .{ .put = .dirt } });
    // Search before consuming the edit acknowledgment; worker ordering is the guarantee.
    try std.testing.expectEqual(standing_space.Position{ -21.5, -21.5, -15 }, try client.findStandingSpace(query));
    try expectEditReply(client, put);
    const remove = client.submitOperation(.{ .block = .{ 10, 10, 16 }, .action = .remove });
    try std.testing.expectEqual(standing_space.Position{ -21.5, -21.5, -16 }, try client.findStandingSpace(query));
    try expectEditReply(client, remove);
    const dig = client.submitOperation(.{ .block = .{ 10, 10, 15 }, .action = .remove });
    try std.testing.expectEqual(standing_space.Position{ -21.5, -21.5, -17 }, try client.findStandingSpace(query));
    try expectEditReply(client, dig);
    try std.testing.expectEqual(0, client.subscriptions.count());
}

test "standing-space failures and repeated searches create no clients, subscriptions or chunk replies" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .{
        .terrain = .{ .seed = 12345, .params = .{ .base_height = 64, .height_amplitude = 0 } },
    });
    defer service.destroy();
    const client = try service.createClient();
    const query = testSpaceQuery(.{ -0.05, -0.05 });
    for (0..2) |_| try std.testing.expectError(error.NoSpace, client.findStandingSpace(query));
    var invalid = query;
    invalid.support_size = .{ 3, 3 };
    try std.testing.expectError(error.InvalidSearch, client.findStandingSpace(invalid));
    try std.testing.expectEqual(0, client.subscriptions.count());
    try std.testing.expectEqual(1, service.clients.items.len);
    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    client.takeResponses(&responses);
    try std.testing.expectEqual(0, responses.items.len);
}

test "canceling a standing-space wait preserves the endpoint and ignores its late value reply" {
    const io = std.testing.io;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    client.space_responses.mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) client.space_responses.mutex.unlock(io);
    const canceled_id = client.requestStandingSpace(testSpaceQuery(.{ -0.05, -0.05 }));
    var task = try io.concurrent(Client.waitStandingSpace, .{ client, canceled_id });
    const result = task.cancel(io);
    client.space_responses.mutex.unlock(io);
    locked = false;
    try std.testing.expectError(error.Canceled, result);
    // A different position makes accepting the canceled reply observable.
    try std.testing.expectEqual(standing_space.Position{ 10.5, 10.5, -16 }, try client.findStandingSpace(testSpaceQuery(.{ 10.5, 10.5 })));
    try std.testing.expectEqual(0, client.subscriptions.count());
    try std.testing.expectEqual(1, service.clients.items.len);
    var leftovers: std.ArrayList(StandingSpaceResponse) = .empty;
    defer leftovers.deinit(service.allocator);
    client.space_responses.takeAll(io, &leftovers);
    try std.testing.expectEqual(0, leftovers.items.len);
}

test "standing-space queries use current blocks across chunk seams and above the old spawn height" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 8 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .{
        .terrain = .{ .seed = 12345, .params = .{ .base_height = 220, .height_amplitude = 0 } },
    });
    defer service.destroy();
    const client = try service.createClient();
    for ([_][2]f64{ .{ -2.06, -2.96 }, .{ -0.05, -0.05 }, .{ -31.95, -0.05 }, .{ 32.05, -0.05 } }) |xy|
        try std.testing.expectEqual(standing_space.Position{ xy[0], xy[1], 92 }, try client.findStandingSpace(testSpaceQuery(xy)));
    try std.testing.expectEqual(0, client.subscriptions.count());
}

test "default startup finds spare clearance around real player support" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .{ .terrain = .{ .seed = 12345 } });
    defer service.destroy();
    const client = try service.createClient();
    var query = testSpaceQuery(.{ -2.06, -2.96 });
    query.search_radius = 8;
    const position = try client.findStandingSpace(query);
    try std.testing.expect(@abs(position[0] - query.preferred_xy[0]) <= 8);
    try std.testing.expect(@abs(position[1] - query.preferred_xy[1]) <= 8);
    try std.testing.expectEqual(0, client.subscriptions.count());
}

test "service shutdown answers queued standing-space requests without loading terrain" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    service.is_shutting_down.store(true, .monotonic);
    try std.testing.expectError(error.ServiceStopped, client.findStandingSpace(testSpaceQuery(.{ 0.5, 0.5 })));
    try std.testing.expectEqual(0, client.subscriptions.count());
}

test "seeded client reconciliation converges to the authoritative worker after interleaved road edits" {
    const allocator = std.testing.allocator;
    const Fixture = @import("terrain_test_fixture.zig").Fixture;
    const coordinates = @import("block_coordinates.zig");
    const Harness = struct {
        const Snapshot = struct { coords: ChunkCoords, chunk: WorldChunk };
        replies: std.ArrayList(OperationResult) = .empty,
        snapshots: std.ArrayList(Snapshot) = .empty,
        successes: usize = 0,
        rejections: usize = 0,
        road_updates: usize = 0,
        batched_replies: bool = false,
        pending_rebases: bool = false,

        fn deinit(self: *@This()) void {
            for (self.snapshots.items) |snapshot| snapshot.chunk.deinit(std.testing.allocator);
            self.snapshots.deinit(std.testing.allocator);
            self.replies.deinit(std.testing.allocator);
        }

        // Use the real authority; do not give it optimistic World replay/undo.
        // Retain exactly the block dependencies returned by applyOperation(),
        // rather than refreshing every chunk and hiding missing reversion updates.
        fn apply(self: *@This(), state: *WorkerState, operation: BlockOperation, request_id: ?u64, random: std.Random) !void {
            const result = state.applyOperation(std.testing.allocator, operation);
            defer result.chunk.deinit(std.testing.allocator);
            if (request_id) |id| {
                try self.replies.append(std.testing.allocator, .{ .request_id = id, .status = result.status });
                if (result.status == .success) self.successes += 1 else self.rejections += 1;
            } else try std.testing.expectEqual(OperationStatus.success, result.status);
            self.road_updates += state.road_changes.items.len;

            var ids: std.ArrayList(ChunkId) = .empty;
            defer ids.deinit(std.testing.allocator);
            const coords, _ = world_module.splitBlockCoords(operation.block);
            try ids.append(std.testing.allocator, state.layout.encodeChunkCoords(coords));
            try ids.appendSlice(std.testing.allocator, state.road_changes.items);
            if (result.changed_below) |below| try ids.append(std.testing.allocator, state.layout.encodeChunkCoords(below));
            for (result.revealed_neighbors) |neighbor| if (neighbor) |value| {
                try ids.append(std.testing.allocator, state.layout.encodeChunkCoords(value));
            };
            // Related chunk order may vary, but commands and their replies stay FIFO.
            random.shuffle(ChunkId, ids.items);
            for (ids.items, 0..) |id, i| {
                if (std.mem.indexOfScalar(ChunkId, ids.items[0..i], id) != null) continue;
                const snapshot = state.modified_chunks.get(id).?.clone(std.testing.allocator);
                errdefer snapshot.deinit(std.testing.allocator);
                try self.snapshots.append(std.testing.allocator, .{ .coords = state.layout.decodeChunkId(id), .chunk = snapshot });
            }
        }

        fn deliver(self: *@This(), client: *world_module.World) !void {
            self.batched_replies = self.batched_replies or self.replies.items.len > 1;
            self.pending_rebases = self.pending_rebases or (self.snapshots.items.len > 0 and client.pending_operations.items.len > self.replies.items.len);
            // Match Game.applyPackage(): retire every reply before its snapshots.
            for (self.replies.items) |reply| client.acknowledgeOperationResult(reply.request_id, reply.status);
            for (self.snapshots.items) |*snapshot| {
                client.insertChunk(snapshot.coords, snapshot.chunk) catch |err| switch (err) {
                    error.StaleChunk => snapshot.chunk.deinit(std.testing.allocator),
                    else => return err,
                };
                snapshot.chunk = WorldChunk.initEmpty(); // Ownership moved or freed.
            }
            self.replies.clearRetainingCapacity();
            self.snapshots.clearRetainingCapacity();
        }

        fn expectConverged(client: *const world_module.World, state: *const WorkerState) !void {
            try std.testing.expectEqual(@as(usize, 0), client.pending_operations.items.len);
            try std.testing.expectEqual(state.modified_chunks.count(), client.chunks.count());
            var chunks = state.modified_chunks.iterator();
            while (chunks.next()) |entry| {
                const expected = entry.value_ptr;
                const actual = client.chunks.get(entry.key_ptr.*).?;
                const expected_data = expected.content.toData();
                const actual_data = actual.content.toData();
                try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected_data.blocks), std.mem.asBytes(&actual_data.blocks));
                try std.testing.expectEqual(expected.solid_block_count, actual.solid_block_count);
                try std.testing.expectEqual(actual_data.countSolidBlocks(), actual.solid_block_count);
                try std.testing.expectEqualDeep(expected.boundaries, actual.boundaries);
                try std.testing.expectEqualDeep(@import("boundary_mask.zig").extract(&actual_data), actual.boundaries);
                try std.testing.expectEqual(expected.chunk_revision, actual.chunk_revision);
                // Sparse roads and construction markers are sets, not ordered lists.
                try std.testing.expectEqual(expected.metadata.roads.items.len, actual.metadata.roads.items.len);
                for (expected.metadata.roads.items) |road|
                    try std.testing.expectEqualDeep(road, actual.metadata.road(road.index).?);
                try std.testing.expectEqual(expected.metadata.constructed.items.len, actual.metadata.constructed.items.len);
                for (expected.metadata.constructed.items) |index|
                    try std.testing.expect(std.mem.indexOfScalar(transformations.BlockIndex, actual.metadata.constructed.items, index) != null);
                try std.testing.expectEqualDeep(expected.metadata.timed.events.items, actual.metadata.timed.events.items);
            }
        }
    };

    var successes: usize = 0;
    var rejections: usize = 0;
    var road_updates: usize = 0;
    var batched_replies = false;
    var pending_rebases = false;
    // Fixed seeds and a finite queue give reproducible coverage without threads,
    // wall-clock waits, new dependencies, or any production instrumentation.
    for (0..32) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var client = try Fixture.init();
        defer client.deinit();
        client.fill(.{ -5, -3, -2 }, .{ 10, 4, -1 }, .stone);
        client.set(.{ -4, 0, 0 }, .country_road_solid);
        for (0..12) |i| client.set(.{ @as(i64, @intCast(i)) - 3, 0, 0 }, .country_road_adaptive);
        client.set(.{ 9, 0, -1 }, .none);
        client.set(.{ -2, -2, 0 }, .country_road_solid);
        for ([_]i64{ -1, 1, 2 }) |y| client.set(.{ -2, y, 0 }, .country_road_adaptive);
        client.set(.{ -2, 3, -1 }, .none);
        client.set(.{ 8, 1, -1 }, .none);
        for ([_]i64{ 1, 2 }) |x| {
            const block = coordinates.fromWorld(client.world.layout, .{ x, 2, 0 }).?;
            client.world.setBlockUnchecked(block, .dirt);
            const coords, const local = world_module.splitBlockCoords(block);
            const metadata = &client.world.chunks.getPtr(client.world.layout.encodeChunkCoords(coords)).?.metadata;
            metadata.markConstructed(allocator, transformations.index(local));
            metadata.timed.schedule(allocator, .{ .block = transformations.index(local), .kind = .compact_dirt, .due_tick = @intCast(100 + x) });
        }
        for (client.world.pending_operations.items) |*pending| {
            pending.road_undo.deinit(allocator);
            pending.road_formations.deinit(allocator);
        }
        client.world.pending_operations.clearRetainingCapacity();

        var state: WorkerState = .{ .layout = client.world.layout, .generator = try WorldGenerator.prepare(.flat, allocator, client.world.layout) };
        defer state.deinit(allocator);
        var initial = client.world.chunks.iterator();
        while (initial.next()) |entry| try state.modified_chunks.put(allocator, entry.key_ptr.*, entry.value_ptr.clone(allocator));
        var harness: Harness = .{};
        defer harness.deinit();
        var operations: [16]BlockOperation = undefined;
        var conflicts: [16]?BlockOperation = @splat(null);
        var deliveries: [16]bool = @splat(false);
        var queued: usize = 0;
        var processed: usize = 0;
        errdefer std.debug.print("reconciliation seed={d}\nlocal={any}\nconflicts={any}\ndeliveries={any}\n", .{ seed, operations[0..queued], conflicts[0..processed], deliveries });
        const sites = [_]struct { cell: rules.Cell, road: rules.BlockType }{
            .{ .cell = .{ -3, 1, 0 }, .road = .snow },
            .{ .cell = .{ 8, 1, -1 }, .road = .snow },
            .{ .cell = .{ 9, 0, -1 }, .road = .country_road_solid },
            .{ .cell = .{ -2, 0, 0 }, .road = .country_road_adaptive },
            .{ .cell = .{ -4, 0, 0 }, .road = .country_road_solid },
            .{ .cell = .{ 0, 0, 0 }, .road = .country_road_adaptive },
            .{ .cell = .{ 8, 0, 0 }, .road = .country_road_adaptive },
            .{ .cell = .{ -2, -2, 0 }, .road = .country_road_solid },
            .{ .cell = .{ -2, -1, 0 }, .road = .country_road_adaptive },
            .{ .cell = .{ -2, 1, 0 }, .road = .country_road_adaptive },
            .{ .cell = .{ -2, 2, 0 }, .road = .country_road_adaptive },
            .{ .cell = .{ -2, 3, -1 }, .road = .country_road_solid },
            .{ .cell = .{ 1, 2, 0 }, .road = .dirt },
            .{ .cell = .{ 2, 2, 0 }, .road = .dirt },
        };
        while (queued < operations.len) {
            // Start from the snow/endpoint/removal pattern, then vary materials,
            // repeated cells, crossing edits, conflicts, and delivery boundaries.
            const site = sites[if (queued < 4) queued else random.uintLessThan(usize, sites.len)];
            const block = coordinates.fromWorld(client.world.layout, site.cell).?;
            const operation: BlockOperation = .{
                .block = block,
                .action = if (try client.world.isBlockSolid(block)) .remove else .{
                    .put = if (queued < 4 or random.boolean()) site.road else .snow,
                },
            };
            try std.testing.expectEqual(OperationStatus.success, client.world.tryOperation(operation).status);
            client.world.pending_operations.items[client.world.pending_operations.items.len - 1].request_id = queued + 1;
            operations[queued] = operation;
            queued += 1;

            // Delay P's section snapshot until A and B are both optimistic.
            // Deliver it separately so the endpoint conflict cannot be hidden
            // by retiring every command before the first rebase.
            if (queued == 3) {
                try harness.apply(&state, operations[0], 1, random);
                processed = 1;
                try harness.deliver(&client.world);
            }
            while (queued >= 3 and processed < queued and (queued == 3 or queued == operations.len or random.boolean())) {
                const intent = operations[processed];
                // A is accepted; vary whether another client occupies B first.
                if (processed != 1 and random.uintLessThan(u8, 3) == 0) {
                    const conflict: BlockOperation = .{ .block = intent.block, .action = if (readStateBlock(&state, intent.block) == .none) .{ .put = .snow } else .remove };
                    conflicts[processed] = conflict;
                    try harness.apply(&state, conflict, null, random);
                }
                try harness.apply(&state, intent, processed + 1, random);
                processed += 1;
            }
            if (queued == 3 or queued == operations.len or random.boolean()) {
                deliveries[queued - 1] = true;
                try harness.deliver(&client.world);
                // Check every drained prefix too: later section snapshots must
                // not mask a divergence that occurred earlier in the schedule.
                if (processed == queued) try Harness.expectConverged(&client.world, &state);
            }
        }
        try Harness.expectConverged(&client.world, &state);
        successes += harness.successes;
        rejections += harness.rejections;
        road_updates += harness.road_updates;
        batched_replies = batched_replies or harness.batched_replies;
        pending_rebases = pending_rebases or harness.pending_rebases;
    }
    try std.testing.expect(successes > 0 and rejections > 0 and road_updates > 0);
    try std.testing.expectEqual(@as(usize, 512), successes + rejections);
    try std.testing.expect(batched_replies and pending_rebases);
}

test "refilling an underground hole packs soil under a ceiling, including across chunk boundaries" {
    const allocator = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, allocator, &test_layout) };
    defer state.deinit(allocator);
    const surface = test_layout.size_in_blocks[2] / 2 - CHUNK_SIZE / 2;
    for ([_]u32{ surface - 2, CHUNK_SIZE - 1 }) |z| {
        const block = [3]u32{ 10, 10, z };
        const mined = state.applyOperation(allocator, .{ .block = block, .action = .remove });
        defer mined.chunk.deinit(allocator);
        try std.testing.expectEqual(OperationStatus.success, mined.status);
        const filled = state.applyOperation(allocator, .{ .block = block, .action = .{ .put = .dirt } });
        defer filled.chunk.deinit(allocator);
        try std.testing.expectEqual(OperationStatus.success, filled.status);
        try std.testing.expectEqual(rules.BlockType.packed_dirt, readStateBlock(&state, block));
        try std.testing.expectEqual(0, filled.chunk.metadata.timed.events.items.len);
    }
}

const PersistenceFixture = struct {
    path: [:0]u8,
    store: storage.Store,
    service: *WorldDataService,
    layout: WorldLayout,
    fn init(limits: persistence.Limits) !*PersistenceFixture {
        const a = std.testing.allocator;
        const self = try a.create(PersistenceFixture);
        errdefer a.destroy(self);
        var uuid: [16]u8 = undefined;
        std.c.arc4random_buf(&uuid, uuid.len);
        self.path = try std.fmt.allocPrintSentinel(a, "/private/tmp/world-service-persistence-{x}", .{uuid}, 0);
        errdefer a.free(self.path);
        self.layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
        const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = 0, .seed = 0, .settings = &.{} });
        defer a.free(descriptor);
        const global = format.encodeGlobal(0);
        self.store = try storage.Store.create(a, self.path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
        errdefer self.store.deinit();
        self.service = try WorldDataService.createPersistent(std.testing.io, a, &self.layout, .flat, &self.store, limits);
        return self;
    }
    fn deinit(self: *PersistenceFixture) void {
        self.service.destroy();
        self.store.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.path) catch {};
        std.testing.allocator.free(self.path);
        std.testing.allocator.destroy(self);
    }
    fn waitSave(self: *PersistenceFixture, intent: u64) !persistence.Status {
        const deadline = persistence.now(std.testing.io) + 10 * std.time.ns_per_s;
        while (persistence.now(std.testing.io) < deadline) {
            const status = self.service.persistenceStatus();
            if (status.intent_id == intent and !status.active and (status.phase == .complete or status.phase == .failed)) return status;
            try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.TestSaveTimeout;
    }
    fn operation(client: *Client, command: BlockOperation) !OperationStatus {
        return (try operationResult(client, command)).status;
    }
    fn operationResult(client: *Client, command: BlockOperation) !OperationResult {
        const id = try client.trySubmitOperation(command);
        var replies: std.ArrayList(ChunkResponse) = .empty;
        defer deinitResponses(&replies);
        while (try client.waitResponses(&replies)) {
            for (replies.items) |reply| if (reply.operation) |result| if (result.request_id == id) return result;
            for (replies.items) |reply| reply.deinit(std.testing.allocator);
            replies.clearRetainingCapacity();
        }
        return error.ServiceStopped;
    }
};

test "public service commits ordered players and reloads exact base revisions with lazy timers" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    const client = try f.service.createClient();
    const block = [3]u32{ 10, 10, 48 };
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = block, .action = .{ .put = .dirt } }));
    client.publishCheckpoint(.{ .id = 9, .feet = .{ 1.5, 2.5, 3 }, .yaw = 0.5, .pitch = -0.25 });
    const second_player = try f.service.createClient();
    second_player.publishCheckpoint(.{ .id = 2, .feet = .{ 2.5, 3.5, 4 }, .yaw = 1, .pitch = 0.25 });
    const final = f.service.requestSave(true);
    const status = try f.waitSave(final);
    try std.testing.expectEqual(persistence.Phase.complete, status.phase);
    try std.testing.expectEqual(status.target_sequence, status.durable_sequence);
    // An unsubscribed all-lazy timer does not pin an exact base version.
    try std.testing.expectEqual(@as(usize, 0), status.retained_base_mismatch_chunks);
    var player_reader: format.Reader = .{ .bytes = f.store.players };
    try std.testing.expectEqual(@as(u64, 2), (try format.readPlayer(&player_reader)).id);
    try std.testing.expectEqual(@as(u64, 9), (try format.readPlayer(&player_reader)).id);
    const token = client.requestChunks(.{ 0, 0 }, 1, 2);
    var replies: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&replies);
    try std.testing.expect(try client.waitResponses(&replies));
    var revision: u64 = 0;
    var deadline: u64 = 0;
    for (replies.items) |reply| {
        if (reply.data != .blocks or reply.subscription_id != token) continue;
        const chunk = reply.data.blocks.chunk;
        try std.testing.expectEqual(rules.BlockType.dirt, chunk.content.getBlock(.{ 10, 10, 16 }));
        revision = chunk.chunk_revision;
        try std.testing.expectEqual(@as(usize, 1), chunk.metadata.timed.events.items.len);
        deadline = chunk.metadata.timed.events.items[0].due_tick;
    }
    try std.testing.expect(revision > 0);
    try std.testing.expectEqual(transformations.transformation_delay, deadline);
    for (replies.items) |reply| reply.deinit(std.testing.allocator);
    replies.clearRetainingCapacity();
    f.service.advanceTo(deadline + transformations.transformation_delay);
    try std.testing.expect(try client.waitResponses(&replies));
    var caught_up = false;
    for (replies.items) |reply| if (reply.data == .blocks) {
        const chunk = reply.data.blocks.chunk;
        caught_up = caught_up or chunk.content.getBlock(.{ 10, 10, 16 }) == .grass;
        if (caught_up) {
            try std.testing.expect(chunk.chunk_revision > revision);
            try std.testing.expectEqual(@as(usize, 0), chunk.metadata.timed.events.items.len);
        }
    };
    try std.testing.expect(caught_up);
    // Timer metadata consumption broke exact installed-base equality.
    const saved = (try f.store.readChunk(std.testing.allocator, f.layout.encodeChunkCoords(.{ 0, 0, 1 }))).?;
    defer std.testing.allocator.free(saved);
    var old = try format.decodeChunk(std.testing.allocator, f.store.world_uuid, saved, f.store.dimensions);
    defer old.deinit(std.testing.allocator);
    try std.testing.expectEqual(revision, old.revision);
}

test "public service live budget rejection preserves terrain and final save remains usable" {
    const f = try PersistenceFixture.init(.{ .live_bytes = 0 });
    defer f.deinit();
    const client = try f.service.createClient();
    try std.testing.expectEqual(OperationStatus.resource_exhausted, try PersistenceFixture.operation(client, .{ .block = .{ 10, 10, 48 }, .action = .{ .put = .snow } }));
    const status = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.complete, status.phase);
    try std.testing.expectEqual(@as(u64, 0), f.store.index.count());
}

test "public service bounds unread terminal operations and reopens admission when consumed" {
    const f = try PersistenceFixture.init(.{ .pending_commands = 1 });
    defer f.deinit();
    const client = try f.service.createClient();
    const first = try client.trySubmitOperation(.{ .block = .{ 10, 10, 48 }, .action = .{ .put = .snow } });
    try std.testing.expectError(error.Busy, client.trySubmitOperation(.{ .block = .{ 11, 10, 48 }, .action = .{ .put = .snow } }));
    var replies: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&replies);
    try std.testing.expect(try client.waitResponses(&replies));
    try std.testing.expectEqual(first, replies.items[replies.items.len - 1].operation.?.request_id);
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = .{ 11, 10, 48 }, .action = .{ .put = .snow } }));
}

test "public service restore reports failed persisted dependency instead of hanging" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    const client = try f.service.createClient();
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = .{ 10, 10, 48 }, .action = .{ .put = .snow } }));
    try std.testing.expectEqual(persistence.Phase.complete, (try f.waitSave(f.service.requestSave(true))).phase);
    f.service.destroy();
    var faults: @import("persistence/io.zig").Faults = .{ .operation = .read };
    f.store.setFaults(&faults);
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    const restored = try f.service.createClient();
    const origin = f.layout.origin_chunk * @as(ChunkCoords, @splat(CHUNK_SIZE));
    const feet = [3]f64{ @floatFromInt(10 - origin[0]), @floatFromInt(10 - origin[1]), @floatFromInt(49 - origin[2]) };
    try std.testing.expectError(error.MissingData, restored.resolveRestoredPosition(feet, .{}));
}

const ServiceWriteGate = struct {
    operation: @import("persistence/io.zig").Operation = .write,
    entered: Io.Event = .unset,
    released: Io.Event = .unset,
    once: std.atomic.Value(bool) = .init(false),
    fn hook(context: ?*anyopaque, operation: @import("persistence/io.zig").Operation) void {
        const self: *ServiceWriteGate = @ptrCast(@alignCast(context.?));
        if (operation != self.operation or self.once.swap(true, .acq_rel)) return;
        self.entered.set(std.testing.io);
        self.released.waitUncancelable(std.testing.io);
    }
};

fn waitServiceSources(service: *WorldDataService, released: bool) !persistence.Status {
    const until = persistence.now(std.testing.io) + 5 * std.time.ns_per_s;
    while (persistence.now(std.testing.io) < until) {
        const status = service.persistenceStatus();
        if (status.active and (status.source_count == 0) == released) return status;
        try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestSourceTimeout;
}

fn exerciseServiceCapturePolicy(mode: enum { capture_deadline, player_deadline, final_exempt, overdue_exempt }) !void {
    const f = try PersistenceFixture.init(.{
        .output_bytes = 33000,
        .capture_wait_ns = if (mode == .capture_deadline or mode == .final_exempt or mode == .overdue_exempt) 200 * std.time.ns_per_ms else 10 * std.time.ns_per_s,
        .player_wait_ns = 200 * std.time.ns_per_ms,
        .overdue_ns = if (mode == .overdue_exempt) 100 * std.time.ns_per_ms else 60 * std.time.ns_per_s,
    });
    defer f.deinit();
    const client = try f.service.createClient();
    for ([_]u32{ 10, 42, 74, 106 }) |x| try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = .{ x, 10, 48 }, .action = .{ .put = .snow } }));
    var gate: ServiceWriteGate = .{};
    var faults: @import("persistence/io.zig").Faults = .{ .enabled = false, .context = &gate, .hook = ServiceWriteGate.hook };
    f.store.setFaults(&faults);
    defer gate.released.set(std.testing.io);
    const intent = f.service.requestSave(mode == .final_exempt);
    try gate.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    _ = try waitServiceSources(f.service, false);
    if (mode == .capture_deadline) {
        _ = try waitServiceSources(f.service, true);
    } else if (mode == .player_deadline) {
        // The encoder is backpressured by the stalled writer; a player waiter
        // cancels normal capture and progresses before storage is unstalled.
        try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = .{ 106, 10, 48 }, .action = .remove }));
        _ = try waitServiceSources(f.service, true);
    } else {
        try Io.sleep(std.testing.io, .fromMilliseconds(500), .awake);
        const held = f.service.persistenceStatus();
        try std.testing.expect(held.active and held.source_count != 0);
        if (mode == .overdue_exempt) try std.testing.expect(held.overdue);
        if (mode == .final_exempt) {
            // Resuming cancels this final intent, then a late completion cannot
            // make its earlier capture authoritative over a newer edit.
            f.service.cancelSaveIntent(intent);
            try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = .{ 106, 10, 48 }, .action = .remove }));
        }
    }
    gate.released.set(std.testing.io);
    const done = try f.waitSave(intent);
    if (mode == .overdue_exempt) try std.testing.expectEqual(persistence.Phase.complete, done.phase) else try std.testing.expectEqual(persistence.Phase.failed, done.phase);
    f.store.setFaults(null);
    const next = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.complete, next.phase);
}

test "public service releases stalled capture at capture deadline" {
    try exerciseServiceCapturePolicy(.capture_deadline);
}
test "public service prioritizes player and cancels stalled capture at player deadline" {
    try exerciseServiceCapturePolicy(.player_deadline);
}
test "public service final capture ignores gameplay deadline and cancel intent resumes edits" {
    try exerciseServiceCapturePolicy(.final_exempt);
}
test "public service overdue capture ignores gameplay cancellation deadlines" {
    try exerciseServiceCapturePolicy(.overdue_exempt);
}

test "public service early capture failure retains requested intent identity" {
    const f = try PersistenceFixture.init(.{ .output_bytes = 1 });
    defer f.deinit();
    const client = try f.service.createClient();
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = .{ 10, 10, 48 }, .action = .{ .put = .snow } }));
    const intent = f.service.requestSave(true);
    const status = try f.waitSave(intent);
    try std.testing.expectEqual(persistence.Phase.failed, status.phase);
    try std.testing.expectEqual(intent, status.intent_id);
    try std.testing.expectEqual(@as(u64, 0), status.target_sequence);
    try std.testing.expectEqual(@as(u64, 0), status.durable_sequence);
}

test "public service released source accepts newer edit while older snapshot writes" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    const client = try f.service.createClient();
    const block = [3]u32{ 10, 10, 48 };
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = block, .action = .{ .put = .snow } }));
    var gate: ServiceWriteGate = .{};
    var faults: @import("persistence/io.zig").Faults = .{ .enabled = false, .context = &gate, .hook = ServiceWriteGate.hook };
    f.store.setFaults(&faults);
    defer gate.released.set(std.testing.io);
    const first = f.service.requestSave(false);
    try gate.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    _ = try waitServiceSources(f.service, true);
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = block, .action = .remove }));
    gate.released.set(std.testing.io);
    const old = try f.waitSave(first);
    try std.testing.expectEqual(persistence.Phase.complete, old.phase);
    try std.testing.expect(old.retained_base_mismatch_chunks != 0);
    f.store.setFaults(null);
    try std.testing.expectEqual(persistence.Phase.complete, (try f.waitSave(f.service.requestSave(true))).phase);
    const saved = (try f.store.readChunk(std.testing.allocator, f.layout.encodeChunkCoords(.{ 0, 0, 1 }))).?;
    defer std.testing.allocator.free(saved);
    var decoded = try format.decodeChunk(std.testing.allocator, f.store.world_uuid, saved, f.store.dimensions);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), decoded.revision);
    try std.testing.expectEqual(@as(u8, 0), decoded.blocks[transformations.index(.{ 10, 10, 16 })]);
}

test "public service final save retries transient persisted dependency once through watchdog" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    const original = try f.service.createClient();
    const block = [3]u32{ 10, 10, 48 };
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(original, .{ .block = block, .action = .{ .put = .snow } }));
    try std.testing.expectEqual(persistence.Phase.complete, (try f.waitSave(f.service.requestSave(true))).phase);
    f.service.destroy();
    var gate: ServiceWriteGate = .{ .operation = .read };
    var faults: @import("persistence/io.zig").Faults = .{ .operation = .read, .context = &gate, .hook = ServiceWriteGate.hook };
    f.store.setFaults(&faults);
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    defer gate.released.set(std.testing.io);
    const client = try f.service.createClient();
    _ = try client.trySubmitOperation(.{ .block = block, .action = .remove });
    try gate.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    const intent = f.service.requestSave(true);
    try Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    const released_at = persistence.now(std.testing.io);
    gate.released.set(std.testing.io);
    const saved = try f.waitSave(intent);
    try std.testing.expectEqual(persistence.Phase.complete, saved.phase);
    try std.testing.expect(persistence.now(std.testing.io) - released_at >= std.time.ns_per_s);
    f.store.setFaults(null);
}

fn savedDependencyFixture() !*PersistenceFixture {
    const f = try PersistenceFixture.init(.{});
    errdefer f.deinit();
    const client = try f.service.createClient();
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = .{ 10, 10, 48 }, .action = .{ .put = .snow } }));
    try std.testing.expectEqual(persistence.Phase.complete, (try f.waitSave(f.service.requestSave(true))).phase);
    return f;
}

fn waitDependencyFailure(service: *WorldDataService) !void {
    const until = persistence.now(std.testing.io) + 5 * std.time.ns_per_s;
    while (persistence.now(std.testing.io) < until) {
        const status = service.persistenceStatus();
        if (status.phase == .failed and status.pending_commands == 1) return;
        try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestDependencyFailureTimeout;
}

test "final save restarts an edit dependency that failed before the save request" {
    const f = try savedDependencyFixture();
    defer f.deinit();
    f.service.destroy();
    var faults: @import("persistence/io.zig").Faults = .{ .operation = .read };
    f.store.setFaults(&faults);
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    const client = try f.service.createClient();
    _ = try client.trySubmitOperation(.{ .block = .{ 10, 10, 48 }, .action = .remove });
    try waitDependencyFailure(f.service);
    const saved = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.complete, saved.phase);
    try std.testing.expectEqual(@as(usize, 0), saved.pending_commands);
    var replies: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&replies);
    try std.testing.expect(try client.waitResponses(&replies));
    try std.testing.expectEqual(OperationStatus.success, replies.items[0].operation.?.status);
    try std.testing.expectEqual(@as(u64, 2), replies.items[0].chunk_revision);
    const bytes = (try f.store.readChunk(std.testing.allocator, f.layout.encodeChunkCoords(.{ 0, 0, 1 }))).?;
    defer std.testing.allocator.free(bytes);
    var durable = try format.decodeChunk(std.testing.allocator, f.store.world_uuid, bytes, f.store.dimensions);
    defer durable.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), durable.revision);
    try std.testing.expectEqual(@as(u8, 0), durable.blocks[transformations.index(.{ 10, 10, 16 })]);
    f.store.setFaults(null);
}

const RepeatedReadFailure = struct {
    enabled: std.atomic.Value(bool) = .init(true),
    faults: @import("persistence/io.zig").Faults = .{ .operation = .read },
    fn hook(context: ?*anyopaque, operation: @import("persistence/io.zig").Operation) void {
        const self: *RepeatedReadFailure = @ptrCast(@alignCast(context.?));
        if (operation != .read) return;
        self.faults.enabled = self.enabled.load(.acquire);
        self.faults.observed = 0;
    }
};

test "final dependency drain has one automatic retry and explicit retry resumes the same edit" {
    const f = try savedDependencyFixture();
    defer f.deinit();
    f.service.destroy();
    var failure: RepeatedReadFailure = .{};
    failure.faults.context = &failure;
    failure.faults.hook = RepeatedReadFailure.hook;
    f.store.setFaults(&failure.faults);
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    const client = try f.service.createClient();
    _ = try client.trySubmitOperation(.{ .block = .{ 10, 10, 48 }, .action = .remove });
    try waitDependencyFailure(f.service);
    const started = persistence.now(std.testing.io);
    const failed = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.failed, failed.phase);
    try std.testing.expect(persistence.now(std.testing.io) - started >= std.time.ns_per_s);
    try std.testing.expectEqualStrings("Io", failed.error_name.?);
    try std.testing.expectEqual(@as(usize, 1), failed.pending_commands);
    try Io.sleep(std.testing.io, .fromMilliseconds(1100), .awake);
    try std.testing.expectEqual(failed.progress_generation, f.service.persistenceStatus().progress_generation);
    failure.enabled.store(false, .release);
    const saved = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.complete, saved.phase);
    try std.testing.expectEqual(@as(usize, 0), saved.pending_commands);
    f.store.setFaults(null);
}

test "final dependency drain reports permanent corruption without automatic retry" {
    const f = try savedDependencyFixture();
    defer f.deinit();
    f.service.destroy();
    var catalog = try f.store.snapshotCatalog();
    defer catalog.deinit();
    var read = (try catalog.prepareRead(f.layout.encodeChunkCoords(.{ 0, 0, 1 }))).?;
    defer read.deinit();
    const record = try read.read(std.testing.allocator);
    defer std.testing.allocator.free(record);
    record[record.len - 1] ^= 1;
    try read.file.write(record[record.len - 1 ..], read.offset + record.len - 1);
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    const client = try f.service.createClient();
    _ = try client.trySubmitOperation(.{ .block = .{ 10, 10, 48 }, .action = .remove });
    try waitDependencyFailure(f.service);
    const failed = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.failed, failed.phase);
    try std.testing.expectEqualStrings("ChecksumMismatch", failed.error_name.?);
    try std.testing.expectEqual(@as(u64, 0), failed.target_sequence);
    try std.testing.expectEqual(@as(usize, 1), failed.pending_commands);
    try Io.sleep(std.testing.io, .fromMilliseconds(1100), .awake);
    try std.testing.expectEqual(failed.progress_generation, f.service.persistenceStatus().progress_generation);
    const explicit = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.failed, explicit.phase);
    try std.testing.expectEqualStrings("ChecksumMismatch", explicit.error_name.?);
}

test "public service restores a dense timer chunk in deadline and cell order" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    f.service.destroy();
    const a = std.testing.allocator;
    const timers = try a.alloc(format.Timer, format.cell_count);
    defer a.free(timers);
    for (timers, 0..) |*timer, cell| timer.* = .{ .cell = @intCast(cell), .kind = @intCast(cell % 2), .deadline = 1000 + (format.cell_count - cell) % 17 };
    const metadata = try format.encodeMetadata(a, .{ .timers = timers });
    defer a.free(metadata);
    const blocks = [_]u8{@intFromEnum(rules.BlockType.dirt)} ** format.cell_count;
    const record = try format.encodeChunk(a, f.store.world_uuid, .{ .id = f.layout.encodeChunkCoords(.{ 0, 0, 1 }), .revision = 7, .is_unreachable = false, .blocks = &blocks, .metadata = metadata });
    defer a.free(record);
    const global = format.encodeGlobal(0);
    try f.store.beginSnapshot(1, &global, &.{}, 0, 1);
    try f.store.appendChunk(record);
    _ = try f.store.commitSnapshot();
    try f.store.compact();
    f.service = try WorldDataService.createPersistent(std.testing.io, a, &f.layout, .flat, &f.store, .{});
    const client = try f.service.createClient();
    _ = client.requestChunks(.{ 0, 0 }, 1, 2);
    var replies: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&replies);
    try std.testing.expect(try client.waitResponses(&replies));
    const events = replies.items[0].data.blocks.chunk.metadata.timed.events.items;
    try std.testing.expectEqual(format.cell_count, events.len);
    var seen = [_]bool{false} ** format.cell_count;
    for (events, 0..) |event, i| {
        try std.testing.expect(!seen[event.block]);
        seen[event.block] = true;
        try std.testing.expectEqual(timers[event.block].deadline, event.due_tick);
        try std.testing.expectEqual(timers[event.block].kind, @intFromEnum(event.kind));
        if (i != 0) try std.testing.expect(events[i - 1].due_tick < event.due_tick or (events[i - 1].due_tick == event.due_tick and events[i - 1].block < event.block));
    }
}

fn corruptDependencyRecord(f: *PersistenceFixture) !void {
    var catalog = try f.store.snapshotCatalog();
    defer catalog.deinit();
    var read = (try catalog.prepareRead(f.layout.encodeChunkCoords(.{ 0, 0, 1 }))).?;
    defer read.deinit();
    const record = try read.read(std.testing.allocator);
    defer std.testing.allocator.free(record);
    record[record.len - 1] ^= 1;
    try read.file.write(record[record.len - 1 ..], read.offset + record.len - 1);
}

fn waitAnyDependencyFailure(service: *WorldDataService) !void {
    const until = persistence.now(std.testing.io) + 5 * std.time.ns_per_s;
    while (persistence.now(std.testing.io) < until) {
        if (service.persistenceStatus().phase == .failed) return;
        try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.TestDependencyFailureTimeout;
}

test "final save reports permanent dependency failure with only waiting read queries" {
    const f = try savedDependencyFixture();
    defer f.deinit();
    f.service.destroy();
    try corruptDependencyRecord(f);
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    const client = try f.service.createClient();
    _ = client.requestChunks(.{ 0, 0 }, 1, 2);
    try waitAnyDependencyFailure(f.service);
    const failed = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.failed, failed.phase);
    try std.testing.expectEqualStrings("ChecksumMismatch", failed.error_name.?);
    try std.testing.expectEqual(@as(usize, 0), failed.pending_commands);
}

fn queuedFinalDependencyFailure(read_only: bool) !void {
    const f = try savedDependencyFixture();
    defer f.deinit();
    f.service.destroy();
    try corruptDependencyRecord(f);
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    var gate: ServiceWriteGate = .{};
    var faults: @import("persistence/io.zig").Faults = .{ .enabled = false, .context = &gate, .hook = ServiceWriteGate.hook };
    f.store.setFaults(&faults);
    defer gate.released.set(std.testing.io);
    const older = f.service.requestSave(false);
    try gate.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    const client = try f.service.createClient();
    if (read_only) {
        _ = client.requestChunks(.{ 0, 0 }, 1, 2);
        try waitAnyDependencyFailure(f.service);
    } else {
        _ = try client.trySubmitOperation(.{ .block = .{ 10, 10, 48 }, .action = .remove });
        try waitDependencyFailure(f.service);
    }
    const final = f.service.requestSave(true);
    gate.released.set(std.testing.io);
    const failed = try f.waitSave(final);
    try std.testing.expect(final != older);
    try std.testing.expectEqual(final, failed.intent_id);
    try std.testing.expectEqual(persistence.Phase.failed, failed.phase);
    try std.testing.expectEqualStrings("ChecksumMismatch", failed.error_name.?);
    try std.testing.expectEqual(@as(u64, 0), failed.target_sequence);
    f.store.setFaults(null);
}

test "queued final drain publishes its own mutation failure after an older job completes" {
    try queuedFinalDependencyFailure(false);
}

test "queued final drain publishes its own read query failure after an older job completes" {
    try queuedFinalDependencyFailure(true);
}

test "synchronous dependency preparation OOM schedules bounded final retry" {
    const f = try savedDependencyFixture();
    defer f.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var service: WorldDataService = .{
        .layout = &f.layout,
        .io = std.testing.io,
        .allocator = failing.allocator(),
        .worker = undefined,
        .worker_state = .{ .layout = &f.layout, .generator = undefined },
        .catalog = try f.store.snapshotCatalog(),
        .lifecycle = .{ .queued = .{ .intent = .{ .id = 11, .final = true }, .fence_remaining = 0 } },
    };
    defer service.catalog.?.deinit();
    try std.testing.expect(!service.requireBase(f.layout.encodeChunkCoords(.{ 0, 0, 1 })));
    try std.testing.expectEqual(@as(u64, 11), service.status.intent_id);
    try std.testing.expect(service.status.active);
    try std.testing.expect(service.lifecycle.queued.?.retry == .scheduled);
    try std.testing.expectEqualStrings("OutOfMemory", service.status.error_name.?);
    service.lifecycle.queued.?.retry = .exhausted;
    try std.testing.expect(!service.requireBase(f.layout.encodeChunkCoords(.{ 0, 0, 1 })));
    try std.testing.expect(!service.status.active);
    try std.testing.expect(service.lifecycle.queued.?.retry == .exhausted);
}

test "player transfers own inventory across checkpoints saves and game restarts" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    var client = try f.service.createClient();
    client.publishCheckpoint(.{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0, .inventory = 6 });
    const source = [3]u32{ 10, 10, 47 };
    const empty = [3]u32{ 10, 10, 48 };
    try std.testing.expectEqual(OperationStatus.inventory_mismatch, try PersistenceFixture.operation(client, .{ .block = empty, .action = .{ .put = .snow }, .player = .{ .id = 1, .expected_sequence = 0 } }));
    const mined = try PersistenceFixture.operationResult(client, .{ .block = source, .action = .remove, .player = .{ .id = 1, .expected_sequence = 0 } });
    try std.testing.expectEqual(OperationStatus.success, mined.status);
    try std.testing.expectEqual(rules.BlockType.crushed_stone, mined.mined_type.?);
    try std.testing.expectEqual(rules.BlockType.crushed_stone, mined.player_inventory.?.material.?);
    try std.testing.expectEqual(OperationStatus.inventory_mismatch, try PersistenceFixture.operation(client, .{ .block = .{ 11, 10, 47 }, .action = .remove, .player = .{ .id = 1, .expected_sequence = 1 } }));
    try std.testing.expectEqual(OperationStatus.inventory_mismatch, try PersistenceFixture.operation(client, .{ .block = empty, .action = .{ .put = .snow }, .player = .{ .id = 1, .expected_sequence = 1 } }));
    // Coalesced movement state cannot replace the authoritative carried material.
    client.publishCheckpoint(.{ .id = 1, .feet = .{ 1, 2, 3 }, .yaw = 0.5, .pitch = 0, .inventory = 6 });
    const saved = try f.waitSave(f.service.requestSave(true));
    try std.testing.expectEqual(persistence.Phase.complete, saved.phase);
    try std.testing.expectEqual(@as(?u8, 8), (try format.decodePlayer(f.store.players)).inventory);
    f.service.destroy();
    f.store.deinit();
    f.store = try storage.Store.open(std.testing.allocator, f.path, .{});
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    try std.testing.expectEqual(@as(?u8, 8), f.service.restoredPlayer(1).?.inventory);
    client = try f.service.createClient();
    const placed = try PersistenceFixture.operationResult(client, .{ .block = source, .action = .{ .put = .crushed_stone }, .player = .{ .id = 1, .expected_sequence = 1 } });
    try std.testing.expectEqual(OperationStatus.success, placed.status);
    try std.testing.expectEqual(null, placed.player_inventory.?.material);
    try std.testing.expectEqual(persistence.Phase.complete, (try f.waitSave(f.service.requestSave(true))).phase);
    f.service.destroy();
    f.store.deinit();
    f.store = try storage.Store.open(std.testing.allocator, f.path, .{});
    f.service = try WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .flat, &f.store, .{});
    try std.testing.expectEqual(null, f.service.restoredPlayer(1).?.inventory);
    const encoded = (try f.store.readChunk(std.testing.allocator, f.layout.encodeChunkCoords(.{ 0, 0, 1 }))).?;
    defer std.testing.allocator.free(encoded);
    var chunk = try format.decodeChunk(std.testing.allocator, f.store.world_uuid, encoded, f.store.dimensions);
    defer chunk.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, @intFromEnum(rules.BlockType.crushed_stone)), chunk.blocks[15 * 1024 + 10 * 32 + 10]);
}

test "player extraction rejects a replacement even when the replacement has the same material" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const player = try service.createClient();
    const npc = try service.createClient();
    player.publishCheckpoint(.{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    const block = [3]u32{ 10, 10, test_layout.size_in_blocks[2] - 1 };
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = block, .action = .{ .put = .sand } }));
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = block, .action = .remove }));
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = block, .action = .{ .put = .sand } }));
    const result = try PersistenceFixture.operationResult(player, .{ .block = block, .action = .remove, .player = .{ .id = 1, .expected_sequence = 1 } });
    try std.testing.expectEqual(OperationStatus.target_changed, result.status);
    try std.testing.expectEqual(null, result.player_inventory.?.material);
    const retry = try PersistenceFixture.operationResult(player, .{ .block = block, .action = .remove, .player = .{ .id = 1, .expected_sequence = 3 } });
    try std.testing.expectEqual(OperationStatus.success, retry.status);
    try std.testing.expectEqual(rules.BlockType.sand, retry.player_inventory.?.material.?);
}

test "saving before a player consumes its acknowledgement captures inventory and terrain together" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    const client = try f.service.createClient();
    client.publishCheckpoint(.{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    const source = [3]u32{ 10, 10, 47 };
    _ = try client.trySubmitOperation(.{ .block = source, .action = .remove, .player = .{ .id = 1, .expected_sequence = 0 } });
    // This can coalesce with the first movement checkpoint before registration runs.
    client.publishCheckpoint(.{ .id = 1, .feet = .{ 1, 2, 3 }, .yaw = 0, .pitch = 0 });
    try std.testing.expectEqual(persistence.Phase.complete, (try f.waitSave(f.service.requestSave(true))).phase);
    try std.testing.expectEqual(@as(usize, 1), f.service.outstanding_operations.load(.acquire));
    try std.testing.expectEqual(@as(?u8, 8), (try format.decodePlayer(f.store.players)).inventory);
    const encoded = (try f.store.readChunk(std.testing.allocator, f.layout.encodeChunkCoords(.{ 0, 0, 1 }))).?;
    defer std.testing.allocator.free(encoded);
    var chunk = try format.decodeChunk(std.testing.allocator, f.store.world_uuid, encoded, f.store.dimensions);
    defer chunk.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), chunk.blocks[15 * 1024 + 10 * 32 + 10]);
}

test "player extraction accepts unrelated NPC edits within the same chunk" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const player = try service.createClient();
    const npc = try service.createClient();
    player.publishCheckpoint(.{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    const source = [3]u32{ 10, 10, test_layout.size_in_blocks[2] - 1 };
    const other = [3]u32{ 11, 10, source[2] };
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = source, .action = .{ .put = .sand } }));
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = other, .action = .{ .put = .snow } }));
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = other, .action = .remove }));
    const result = try PersistenceFixture.operationResult(player, .{ .block = source, .action = .remove, .player = .{ .id = 1, .expected_sequence = 1 } });
    try std.testing.expectEqual(OperationStatus.success, result.status);
    try std.testing.expectEqual(rules.BlockType.sand, result.player_inventory.?.material.?);
}
