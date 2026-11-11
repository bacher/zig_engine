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
const GeneratedChunkCache = @import("generated_chunk_cache.zig").Cache;
const ChunkId = @import("./consts.zig").ChunkId;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WORLD_SIZE = test_layout.size_in_chunks;
const Side = @import("engine").voxel_chunk.Side;
const transformations = @import("block_transformations.zig");
const rules = @import("block_rules.zig");
const mutation_guard = @import("mutation_guard.zig");
const standing_space = @import("standing_space.zig");
const blueprint = @import("blueprint.zig");
const blueprint_runtime = @import("blueprint_runtime.zig");
const blueprint_wire = @import("persistence/blueprints.zig");
const deferred_work = @import("deferred_world_work.zig");
const blueprint_admission = @import("blueprint_admission.zig");
const blueprint_admission_region = @import("blueprint_admission_region.zig");
const blueprint_road_updates = @import("blueprint_road_updates.zig");
const background_work_log = std.log.scoped(.background_world_work);
pub const BlueprintRejection = @import("blueprint_result.zig").Rejection;
pub const BlueprintResult = @import("blueprint_result.zig").Result;
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
    blueprint_changes: std.ArrayList(blueprint_runtime.Change) = .empty,

    pub fn deinit(self: *ResponsePackage, allocator: std.mem.Allocator) void {
        for (self.responses.items) |response| response.deinit(allocator);
        self.responses.deinit(allocator);
        for (self.blueprint_changes.items) |*change| change.deinit(allocator);
        self.blueprint_changes.deinit(allocator);
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
const BlueprintApplyRequest = struct {
    client: *Client,
    request_id: u64,
    owner: u64,
    definition_id: u64,
    origin: [3]u32,
    rotation: u2,
};

const BlueprintAdmissionTask = struct {
    service: *WorldDataService,
    request: BlueprintApplyRequest,
    snapshot: blueprint_admission.Snapshot,
    definition: blueprint.Definition,
    instance: blueprint_runtime.Instance,
    client_count: usize,
    response_copies: std.ArrayList(blueprint_runtime.Instance) = .empty,
    chunk_ids: []ChunkId,
    cursor: usize = 0,
    snapshot_bytes: usize = 0,
    waiting_for_data: bool = false,
    waiting_for_journal: bool = false,
    cancel: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
    result: ?(anyerror!blueprint_admission.Result) = null,
    retired: std.atomic.Value(bool) = .init(false),

    fn run(task: *BlueprintAdmissionTask) void {
        task.result = task.prepare();
        task.service.requests.push(task.service.io, task.service.allocator, .{ .blueprint_prepared = task });
    }

    fn prepare(task: *BlueprintAdmissionTask) !blueprint_admission.Result {
        const allocator = task.service.allocator;
        var result = try blueprint_admission.prepareCertified(allocator, &task.snapshot, task.definition, task.instance, .{ .cancel = &task.cancel });
        errdefer if (result == .prepared) result.prepared.deinit(allocator);
        if (result == .prepared) {
            try task.response_copies.ensureTotalCapacity(allocator, task.client_count);
            for (0..task.client_count) |_| {
                if (task.cancel.load(.acquire)) {
                    result.prepared.deinit(allocator);
                    return .cancelled;
                }
                task.response_copies.appendAssumeCapacity(try result.prepared.publication.instance.clone(allocator));
            }
        }
        return result;
    }

    fn release(task: *BlueprintAdmissionTask) void {
        const allocator = task.service.allocator;
        if (task.result) |result| if (result) |owned| switch (owned) {
            .prepared => |prepared| {
                var value = prepared;
                value.deinit(allocator);
            },
            else => {},
        } else |_| {};
        for (task.response_copies.items) |*copy| copy.deinit(allocator);
        task.response_copies.deinit(allocator);
        task.snapshot.deinit(allocator);
        task.instance.deinit(allocator);
        allocator.free(task.chunk_ids);
        task.retired.store(true, .release);
    }
};

const Request = union(enum) {
    register: *Client,
    register_player: format.Player,
    blueprint_save: struct {
        client: *Client,
        request_id: u64,
        idempotency_key: ?u64 = null,
        owner: u64,
        name: []const u8,
        candidate: blueprint.CertifiedDefinition,
    },
    blueprint_apply: BlueprintApplyRequest,
    blueprint_prepared: *BlueprintAdmissionTask,
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

fn requestClient(request: Request) *Client {
    return switch (request) {
        .operation => |value| value.client,
        .blueprint_save => |value| value.client,
        .blueprint_apply => |value| value.client,
        else => unreachable,
    };
}

/// One endpoint per producer/consumer thread. Endpoints and their queued replies are owned
/// by the service and remain alive until it is destroyed. Stop all clients' tasks first.
pub const Client = struct {
    const BlueprintSaveKey = struct { explicit: bool, value: u64 };

    service: *WorldDataService,
    responses: Mailbox(ResponsePackage) = .{},
    /// Value-only query replies never consume chunk packages or create subscriptions.
    space_responses: Mailbox(StandingSpaceResponse) = .{},
    blueprint_results: Mailbox(BlueprintResult) = .{},
    /// Worker-owned successful Save identities, scoped to this endpoint's
    /// lifetime. Automatic transport identities and explicit retry keys differ.
    blueprint_save_keys: std.AutoHashMapUnmanaged(BlueprintSaveKey, u64) = .empty,
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

    /// The operation owns the checked contents only after successful enqueue.
    pub fn trySaveBlueprint(self: *Client, owner: u64, name: []const u8, candidate: *blueprint.CertifiedDefinition) !u64 {
        return self.submitBlueprintSave(owner, name, candidate, null);
    }

    /// Reusing a key on this endpoint returns the original definition only for
    /// the same owner, canonical name, and immutable contents.
    pub fn trySaveBlueprintWithKey(self: *Client, owner: u64, name: []const u8, candidate: *blueprint.CertifiedDefinition, idempotency_key: u64) !u64 {
        return self.submitBlueprintSave(owner, name, candidate, idempotency_key);
    }

    fn submitBlueprintSave(self: *Client, owner: u64, name: []const u8, candidate: *blueprint.CertifiedDefinition, idempotency_key: ?u64) !u64 {
        if (self.service.is_shutting_down.load(.acquire)) return error.ServiceStopped;
        const canonical = try blueprint_wire.trimmedName(name);
        const owned_name = try self.service.allocator.dupe(u8, canonical);
        errdefer self.service.allocator.free(owned_name);
        const id = self.nextRequestId();
        try self.service.requests.tryPush(self.service.io, self.service.allocator, .{ .blueprint_save = .{
            .client = self,
            .request_id = id,
            .idempotency_key = idempotency_key,
            .owner = owner,
            .name = owned_name,
            .candidate = candidate.*,
        } });
        candidate.* = undefined;
        self.last_operation_id = id;
        return id;
    }

    pub fn tryApplyBlueprint(self: *Client, owner: u64, definition_id: u64, origin: [3]u32, rotation: u2) !u64 {
        if (self.service.is_shutting_down.load(.acquire)) return error.ServiceStopped;
        const id = self.nextRequestId();
        try self.service.requests.tryPush(self.service.io, self.service.allocator, .{ .blueprint_apply = .{
            .client = self,
            .request_id = id,
            .owner = owner,
            .definition_id = definition_id,
            .origin = origin,
            .rotation = rotation,
        } });
        self.last_operation_id = id;
        return id;
    }

    pub fn takeBlueprintResults(self: *Client, out: *std.ArrayList(BlueprintResult)) void {
        self.blueprint_results.takeAll(self.service.io, out);
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

    /// Poll only the latest outstanding search. Discard older value-only replies
    /// without waiting for a result or consuming terrain packages/subscriptions.
    pub fn pollStandingSpace(self: *Client, request_id: u64) ?StandingSpaceResponse {
        self.space_responses.mutex.lockUncancelable(self.service.io);
        defer self.space_responses.mutex.unlock(self.service.io);
        defer self.space_responses.items.clearRetainingCapacity();
        for (self.space_responses.items.items) |reply|
            if (reply.request_id == request_id) return reply;
        return null;
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
            for (package.blueprint_changes.items) |*change| change.deinit(self.service.allocator);
            package.blueprint_changes.deinit(self.service.allocator);
        }
        packages.deinit(self.service.allocator);
    }

    fn append(self: *Client, response: ChunkResponse) void {
        self.pending.responses.append(self.service.allocator, response) catch @panic("OOM");
    }
};

/// One warning budget for the service, retained across errors and recoveries.
/// Recovery is reported only for an episode with a visible warning, bounding
/// rapidly alternating failures/successes to one warning/recovery pair per interval.
const DeferredWorkLog = struct {
    const repeat_interval_ns: i96 = 30 * std.time.ns_per_s;
    next_warning_ns: ?i96 = null,
    warning_active: bool = false,

    fn failure(self: *DeferredWorkLog, at: i96) bool {
        if (self.next_warning_ns) |deadline| if (at < deadline) return false;
        self.next_warning_ns = at + repeat_interval_ns;
        self.warning_active = true;
        return true;
    }

    fn recover(self: *DeferredWorkLog) bool {
        const report = self.warning_active;
        self.warning_active = false;
        return report;
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
    /// Only reads without a foreground consumer; these never gate final saves.
    deferred_reads: std.AutoHashMapUnmanaged(u32, void) = .empty,
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
    /// Immutable definition views borrow the live library; fulfillment records are values.
    /// Only the prefix frozen into a successfully committed Job is retired.
    blueprint_journal: std.ArrayList(blueprint_wire.Op) = .empty,
    blueprint_journal_bytes: usize = 0,
    blueprint_journal_summary: blueprint_wire.PrepareSummary = .{},
    blueprint_library_bytes: usize = 0,
    captured_blueprint_operations: usize = 0,
    captured_blueprint_summary: blueprint_wire.PrepareSummary = .{},
    blueprint_task: ?*BlueprintAdmissionTask = null,
    blueprint_retired: std.ArrayList(*BlueprintAdmissionTask) = .empty,
    blueprint_road_queue: blueprint_road_updates.Queue = .{},
    blueprint_road_waiting: bool = false,
    /// Failed journal-prefix captures sleep until an explicit/bounded retry.
    internal_capture_suspended: bool = false,
    captured_work_generation: u64 = 0,
    processing_deferred_work: bool = false,
    deferred_work_log: DeferredWorkLog = .{},
    /// Retained mutations stay FIFO without shifting request payloads on drain/retry.
    pending: std.Deque(Pending) = .empty,
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
    const Pending = struct { request: Request, since: i96, waiting_for_journal: bool = false };

    /// Validate/prepare generation before starting the worker. The allocator must
    /// be thread-safe; messages transfer ownership between tasks.
    pub fn create(io: Io, allocator: std.mem.Allocator, layout: *const WorldLayout, generator: WorldGenerator) !*WorldDataService {
        return createConfigured(io, allocator, layout, generator, null, .{});
    }

    pub fn createPersistent(io: Io, allocator: std.mem.Allocator, layout: *const WorldLayout, generator: WorldGenerator, store: *storage.Store, limits: persistence.Limits) !*WorldDataService {
        return createConfigured(io, allocator, layout, generator, store, limits);
    }

    fn createConfigured(io: Io, allocator: std.mem.Allocator, layout: *const WorldLayout, generator: WorldGenerator, store: ?*storage.Store, limits: persistence.Limits) !*WorldDataService {
        // Reject mismatched descriptors before preparing terrain or launching work.
        if (store) |saved| {
            const descriptor = try format.decodeDescriptor(saved.descriptor);
            const seed: u64 = switch (generator) {
                .flat => 0,
                .flat_seeded => |value| value,
                .natural => |value| value.seed,
                .terrain => return error.UnsupportedGenerator,
            };
            const settings: format.GeneratorSettings = switch (generator) {
                .flat, .flat_seeded => .flat,
                .natural => |value| .{ .natural = value.settings },
                .terrain => unreachable,
            };
            try format.validateRuntimeIdentity(descriptor, .{ @intCast(layout.size_in_chunks[0]), @intCast(layout.size_in_chunks[1]), @intCast(layout.size_in_chunks[2]) }, seed, settings);
        }
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
            .worker_state = .{ .layout = owned_layout, .generator = prepared, .blueprints = .{ .layout = owned_layout }, .live_allocator = if (budget) |owned| owned.allocator() else null },
            .budget = budget,
        };
        // No asynchronous task owns self until initialization is complete.
        errdefer if (self.catalog) |*catalog| catalog.deinit();
        errdefer self.players.deinit(allocator);
        errdefer self.restored_players.deinit(allocator);
        errdefer self.worker_state.blueprints.deinit(allocator);
        errdefer self.blueprint_road_queue.deinit(allocator);
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
            try self.restoreBlueprints(saved);
            try self.restoreDeferredWork(saved);
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

    /// Immutable after creation; the service must outlive every borrowing client.
    pub fn preparedGenerator(self: *const WorldDataService) *const PreparedWorldGenerator {
        return &self.worker_state.generator;
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
            .pending_commands = self.pending.len + @as(usize, if (self.blueprint_task != null) 1 else 0),
            .pending_reads = self.read_pending.count() - self.deferred_reads.count(),
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
        for (self.blueprint_retired.items) |task| {
            if (task.future) |*future| future.await(self.io);
            self.allocator.destroy(task);
        }
        self.blueprint_retired.deinit(self.allocator);
        self.read_requests.close(self.io);
        if (self.reader) |*reader| reader.await(self.io);
        self.requests.close(self.io);
        for (self.clients.items) |client| {
            for (client.responses.items.items) |*package| package.deinit(self.allocator);
            client.pending.deinit(self.allocator);
            client.responses.deinit(self.allocator);
            client.space_responses.deinit(self.allocator);
            client.blueprint_results.deinit(self.allocator);
            client.blueprint_save_keys.deinit(self.allocator);
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
        self.blueprint_journal.deinit(self.allocator);
        self.blueprint_road_queue.deinit(self.allocator);
        self.run_write_ids.deinit(self.allocator);
        self.discardPendingBlueprintSaves();
        self.pending.deinit(self.allocator);
        self.waiting_reads.deinit(self.allocator);
        self.retry_reads.deinit(self.allocator);
        self.read_pending.deinit(self.allocator);
        self.deferred_reads.deinit(self.allocator);
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
                if (self.blueprint_task) |task| {
                    task.cancel.store(true, .release);
                    if (task.future == null) self.rejectBlueprintApplication(task, .stale, null);
                }
            }
            self.async_progress = false;
            self.drainPersistenceEvents();
            if (self.shutdown_started and self.job == null and self.compactor == null and self.read_pending.count() == 0 and self.blueprint_task == null) {
                // Producers have stopped. Process the last accepted queue before
                // ending, including registration and terminal read completions.
                self.requests.takeAll(self.io, &batch);
                if (batch.items.len == 0) break;
            } else if (self.async_progress or (self.blueprint_task != null and self.blueprint_task.?.future == null and !self.blueprint_task.?.waiting_for_data and !self.blueprint_task.?.waiting_for_journal) or (self.blueprint_road_queue.count != 0 and !self.blueprint_road_waiting) or (self.next_mesh_load < self.mesh_loads.items.len and !self.is_shutting_down.load(.monotonic))) {
                self.requests.takeAll(self.io, &batch);
            } else if (!self.waitForWork(&batch)) break;
            self.drainPersistenceEvents();
            for (batch.items) |request| {
                self.processRequest(request);
                self.publishPersistenceStatus();
            }
            batch.clearRetainingCapacity();
            self.reapBlueprintRetirements();
            if (self.is_shutting_down.load(.monotonic)) continue;
            self.advanceBlueprintAdmission();
            self.worker_state.blueprints.cleanup(self.allocator, 4);
            self.processBlueprintRoadUpdates();
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
                if (client.pending.responses.items.len == 0 and client.pending.blueprint_changes.items.len == 0) continue;
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
            var climate: mesher.ClimateMap = undefined;
            self.preparedGenerator().fillClimateMap(.{ coords[0], coords[1] }, &climate);
            mesh = mesher.tryExtractChunkGeometryWithClimate(self.allocator, chunk, neighbors, &climate) catch return;
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
        defer self.updateSimulationPause();
        const commands = self.pending.len + @as(usize, if (self.blueprint_task != null) 1 else 0);
        if (self.lifecycle.request(.{ .id = id, .final = final }, commands) == .none) {
            // Keep the original intent/fence. A running writer owns the next
            // wake; an idle drain may retain FIFO work without an Apply.
            if (self.job != null) return;
            if (self.internal_capture_suspended) {
                self.retrySaveDrain();
            } else if (self.lifecycle.queued.?.fence_remaining == 0) {
                self.retryPending();
            } else if (self.blueprint_task != null) {
                self.retryWaitingBlueprintApplication();
            } else if (self.pending.len != 0) {
                self.retryPending();
            }
            return;
        }
        self.selectSaveDrain();
        self.retrySaveDrain();
    }

    /// Wake reads, mutation dependencies, and prepared applications. A journal
    /// capture can fail before creating a Job, so no completion may arrive.
    fn retrySaveDrain(self: *WorldDataService) void {
        defer self.updateSimulationPause();
        self.internal_capture_suspended = false;
        self.blueprint_road_waiting = false;
        self.retryReadFailures();
        self.retryWaitingReads();
        self.retryWaitingBlueprintApplication();
        self.retryPending();
    }

    fn selectSaveDrain(self: *WorldDataService) void {
        const save = self.lifecycle.selectDrain() orelse return;
        self.reportSaveDrain(save);
    }

    fn reportSaveDrain(self: *WorldDataService, save: save_lifecycle.Intent) void {
        self.internal_capture_suspended = false;
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
        if (self.job == null) if (self.lifecycle.queued) |drain| {
            // A failed internal prefix capture may have overwritten the public
            // intent even though the queued drain was already selected.
            self.status.intent_id = drain.intent.id;
            self.status.target_sequence = 0;
        };
        self.failPersistence(err);
        if (self.lifecycle.dependencyFailed(err, persistence.now(self.io))) self.status.active = true;
        self.internal_capture_suspended = true;
        self.updateSimulationPause();
    }

    fn noteDeferredWorkFailure(self: *WorldDataService, err: anyerror) void {
        // A saved obligation makes background failure independent of save success.
        self.status.deferred_work_error_name = @errorName(err);
        self.status.progress_generation +%= 1;
        if (self.deferred_work_log.failure(persistence.now(self.io))) {
            background_work_log.warn("Background world work failed: {s}", .{@errorName(err)});
        }
    }

    fn clearDeferredWorkFailure(self: *WorldDataService) void {
        const previous = self.status.deferred_work_error_name orelse return;
        self.status.deferred_work_error_name = null;
        if (self.deferred_work_log.recover()) {
            // A successful step proves progress, not completion of the whole queue.
            background_work_log.info("Background world work resumed (last error: {s})", .{previous});
        }
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
        const ordered = request == .operation or request == .blueprint_save or request == .blueprint_apply;
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
        if (ordered and (self.blueprint_task != null or self.pending.len != 0 or !dependencies_ready or !admission_ready)) {
            if (!requestClient(request).simulation) {
                if (self.source_holds.count() != 0) self.status.capture_waited_operations +%= 1 else if (self.read_pending.count() != 0) self.status.dependency_waited_operations +%= 1;
            }
            self.pending.pushBack(self.allocator, .{ .request = request, .since = persistence.now(self.io) }) catch @panic("OOM");
            return;
        }
        self.processAdmitted(request);
    }

    fn processAdmitted(self: *WorldDataService, request: Request) void {
        switch (request) {
            .blueprint_save => |save| self.saveBlueprint(save),
            .blueprint_apply => |apply| self.beginBlueprintApplication(apply),
            .blueprint_prepared => |task| self.finishBlueprintApplication(task),
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
                if (self.blueprint_task) |task| task.waiting_for_data = false;
                self.blueprint_road_waiting = false;
                _ = self.read_pending.remove(loaded.id);
                const deferred_only = self.deferred_reads.remove(loaded.id);
                if (loaded.result) |chunk| {
                    const current_revision = self.worker_state.modified_chunks.get(loaded.id);
                    if (current_revision != null or (self.catalog.?.revision(loaded.id) orelse 0) != loaded.revision) {
                        chunk.deinit(self.worker_state.liveAllocator(self.allocator));
                    } else {
                        self.installLoaded(loaded.id, loaded.revision, chunk) catch |err| {
                            chunk.deinit(self.worker_state.liveAllocator(self.allocator));
                            self.read_failed.put(self.allocator, loaded.id, err) catch {};
                            self.noteDeferredWorkFailure(err);
                        };
                    }
                } else |err| {
                    self.read_failed.put(self.allocator, loaded.id, err) catch {};
                    self.noteDeferredWorkFailure(err);
                }
                // Background dependency loads have no foreground publication to wake.
                if (!deferred_only) {
                    const loaded_coords = self.layout.decodeChunkId(loaded.id);
                    self.dirty_meshes.put(self.allocator, loaded.id, {}) catch self.failPersistence(error.OutOfMemory);
                    for (std.enums.values(Side)) |side| if (world_module.adjacentChunk(self.layout, loaded_coords, side)) |neighbor| {
                        self.dirty_meshes.put(self.allocator, self.layout.encodeChunkCoords(neighbor), {}) catch self.failPersistence(error.OutOfMemory);
                    };
                }
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
                self.updateSimulationPause();
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
            .register => |client| {
                self.clients.append(self.allocator, client) catch @panic("OOM");
                self.publishBlueprintBaseline(client) catch self.failPersistence(error.OutOfMemory);
            },
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
                if (edit.operation.blueprint != null) return self.processBlueprintFulfillment(edit);
                const coords, const local = world_module.splitBlockCoords(edit.operation.block);
                const position = self.layout.encodeChunkCoords(coords);
                self.read_discovered = false;
                self.operation_deferred = false;
                edit.client.pending.responses.ensureUnusedCapacity(self.allocator, 1) catch {
                    self.pending.pushFront(self.allocator, .{ .request = request, .since = self.processing_since orelse persistence.now(self.io) }) catch @panic("OOM");
                    self.operation_deferred = true;
                    self.failPersistence(error.OutOfMemory);
                    return;
                };
                const result = self.worker_state.applyOperation(self.allocator, edit.operation);
                var reply_moved = false;
                defer if (!reply_moved) result.chunk.deinit(self.allocator);
                if (self.read_discovered or self.operation_deferred) {
                    self.pending.pushFront(self.allocator, .{ .request = request, .since = self.processing_since orelse persistence.now(self.io) }) catch @panic("OOM");
                    return;
                }
                if (result.status == .success) {
                    if (edit.operation.player) |transfer| {
                        // The player record exists and was checked before the terrain
                        // commit. This part of the same service turn cannot allocate.
                        const player = self.players.getPtr(transfer.id).?;
                        player.inventory = if (edit.operation.action == .remove) if (result.diagnostics.mined_type) |item| @intFromEnum(item) else null else null;
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

    fn publishBlueprintBaseline(self: *WorldDataService, client: *Client) !void {
        const state = &self.worker_state.blueprints;
        try client.pending.blueprint_changes.ensureUnusedCapacity(self.allocator, state.definitions.count() + state.instances.count());
        var definitions = state.definitions.valueIterator();
        while (definitions.next()) |definition| {
            client.pending.blueprint_changes.appendAssumeCapacity(.{ .definition = try definition.clone(self.allocator) });
        }
        var instances = state.instances.valueIterator();
        while (instances.next()) |instance| {
            if (instance.active) client.pending.blueprint_changes.appendAssumeCapacity(.{ .instance = try instance.clone(self.allocator) });
        }
    }

    fn saveBlueprint(self: *WorldDataService, save: anytype) void {
        self.operation_deferred = false;
        self.read_discovered = false;
        self.trySaveBlueprint(save) catch |err| {
            if (err == error.OutOfMemory or err == error.JournalBackpressure) {
                // Finalization transferred ownership to this command. Keep its payload
                // for a retry instead of destroying a checked, finalized design.
                self.pending.pushFront(self.allocator, .{ .request = .{ .blueprint_save = save }, .since = self.processing_since orelse persistence.now(self.io), .waiting_for_journal = err == error.JournalBackpressure }) catch @panic("OOM retaining blueprint Save");
                self.operation_deferred = true;
                self.failPersistence(err);
                if (err == error.JournalBackpressure) self.drainBlueprintJournal();
                return;
            }
            var candidate = save.candidate;
            candidate.deinit(self.allocator);
            self.allocator.free(save.name);
            save.client.blueprint_results.push(self.io, self.allocator, .{ .request_id = save.request_id, .kind = .save, .status = if (err == error.LibraryCapacity or err == error.Capacity) .resource_exhausted else .invalid });
            save.client.resolved_request = @max(save.client.resolved_request, save.request_id);
            self.applyEligibleCheckpoint(save.client);
        };
    }

    /// Persist the already accepted prefix without including the retained Save
    /// payload. Its eventual completion retries that command before a later fence.
    fn drainBlueprintJournal(self: *WorldDataService) void {
        if (self.store == null or self.job != null or self.is_shutting_down.load(.acquire)) return;
        self.internal_capture_suspended = false;
        const intent = self.next_intent.fetchAdd(1, .monotonic);
        self.beginCapture(intent, false) catch |err| self.noteDrainFailure(err);
    }

    fn restoreDeferredWork(self: *WorldDataService, saved: *const storage.Store) !void {
        const keys = try deferred_work.decode(self.allocator, saved.pending_work, saved.dimensions, @min(saved.limits.max_pending_work, blueprint_road_updates.capacity));
        defer self.allocator.free(keys);
        try self.blueprint_road_queue.restore(self.allocator, keys);
        self.captured_work_generation = self.blueprint_road_queue.generation;
    }

    fn retryWaitingBlueprintApplication(self: *WorldDataService) void {
        if (self.job != null) return;
        const task = self.blueprint_task orelse return;
        if (!task.waiting_for_journal) return;
        // Reuse the prepared result and recheck dependencies before publication.
        // Another drain-start failure leaves it waiting for the next save retry.
        task.waiting_for_journal = false;
        self.finishBlueprintApplication(task);
    }

    fn addBlueprintSummary(self: *WorldDataService, summary: *blueprint_wire.PrepareSummary, operation: blueprint_wire.Op) !void {
        const cells = switch (operation) {
            .instance => |instance| (self.worker_state.blueprints.definitions.get(instance.definition_id) orelse return error.InvalidBlueprint).definition.cells.len,
            else => 0,
        };
        try summary.addOperation(operation, cells);
    }

    fn blueprintJournalMemory(self: *const WorldDataService, summary: blueprint_wire.PrepareSummary, capacity: usize) !usize {
        const limits = if (self.store) |store| store.limits.blueprints else blueprint_wire.Limits{};
        return std.math.add(usize, try blueprint_wire.prepareMemoryBound(summary, limits), try std.math.add(usize, summary.encoded_bytes, try std.math.mul(usize, capacity, @sizeOf(blueprint_wire.Op))));
    }

    fn captureWorkingOverhead(self: *const WorldDataService, source_count: usize, scratch: usize) !usize {
        var bytes = try std.math.add(usize, @sizeOf(persistence.Job), scratch);
        const work_count = @min(blueprint_road_updates.capacity, self.blueprint_road_queue.count + 10);
        bytes = try std.math.add(usize, bytes, try persistence.pendingWorkMemoryBound(try deferred_work.encodedSize(work_count)));
        bytes = try std.math.add(usize, bytes, try std.math.mul(usize, work_count, @sizeOf(deferred_work.Key)));
        bytes = try std.math.add(usize, bytes, try std.math.mul(usize, self.players.count(), format.player_record_size + @sizeOf(u64)));
        bytes = try std.math.add(usize, bytes, try std.math.mul(usize, source_count, 2 * @sizeOf(persistence.Source) + 2 + @sizeOf([]u8)));
        const ring_target = try std.math.add(usize, source_count, 4);
        const ring_peak = try std.math.add(usize, self.completion_ring.capacity, @max(self.completion_ring.capacity, ring_target));
        bytes = try std.math.add(usize, bytes, try std.math.mul(usize, ring_peak, @sizeOf(persistence.Event)));
        const hold_target = @max(@as(usize, self.source_holds.capacity()), try std.math.mul(usize, source_count, 4));
        const wal_target = @max(@as(usize, self.wal_revisions.capacity()), try std.math.mul(usize, try std.math.add(usize, self.wal_revisions.count(), source_count), 4));
        const hash_peak = try std.math.add(usize, try std.math.add(usize, hold_target, self.source_holds.capacity()), try std.math.add(usize, wal_target, self.wal_revisions.capacity()));
        return std.math.add(usize, bytes, try std.math.add(usize, try std.math.mul(usize, hash_peak, @sizeOf(u32) + @sizeOf(u64) + 16), 512));
    }

    /// Count every resident modified chunk as potentially dirty and reserve the
    /// largest legal metadata scratch. A fill can additionally dirty its target
    /// chunk and the chunk below. No chunk or journal scan is needed here.
    fn blueprintJournalAllowance(self: *const WorldDataService) !usize {
        const sources = @min(self.limits.manifest_entries, try std.math.add(usize, self.worker_state.modified_chunks.count(), 2));
        const overhead = try self.captureWorkingOverhead(sources, persistence.maximumScratchBound());
        return self.limits.working_bytes -| self.limits.output_bytes -| overhead;
    }

    /// Constant-time journal admission precedes terrain/inventory changes. Never
    /// inspect writer-owned persisted state or rescan the journal on a fill.
    fn reserveBlueprintJournal(self: *WorldDataService, operation: blueprint_wire.Op) !void {
        if (self.store == null) return;
        const limits = self.store.?.limits.blueprints;
        var one: blueprint_wire.PrepareSummary = .{};
        try self.addBlueprintSummary(&one, operation);
        const allowance = try self.blueprintJournalAllowance();
        const initial_capacity = std.ArrayList(blueprint_wire.Op).growCapacity(1);
        if (one.operation_count > limits.max_operations or one.encoded_bytes > limits.max_changes_bytes or
            (operation == .definition and operation.definition.cells.len > limits.max_cells) or
            try self.blueprintJournalMemory(one, initial_capacity) > allowance) return error.Capacity;
        var next = self.blueprint_journal_summary;
        try self.addBlueprintSummary(&next, operation);
        if (next.operation_count > limits.max_operations or next.encoded_bytes > limits.max_changes_bytes) return error.JournalBackpressure;
        const current_capacity = self.blueprint_journal.capacity;
        const next_capacity = if (current_capacity >= next.operation_count) current_capacity else std.ArrayList(blueprint_wire.Op).growCapacity(next.operation_count);
        const growth_peak = try std.math.mul(usize, try std.math.add(usize, next_capacity, if (next_capacity > current_capacity) current_capacity else 0), @sizeOf(blueprint_wire.Op));
        if (@max(try self.blueprintJournalMemory(next, next_capacity), growth_peak) > allowance) return error.JournalBackpressure;
        if (self.job) |job| {
            // The committed prefix's encoded/prepared storage lives until the
            // writer finishes. Replace only its journal-capacity reservation.
            const in_flight = try std.math.add(usize, job.working_reserved_bytes - job.blueprint_journal_reserved_bytes, growth_peak);
            if (in_flight > self.limits.working_bytes) return error.JournalBackpressure;
        }
        try self.blueprint_journal.ensureTotalCapacityPrecise(self.allocator, next_capacity);
    }

    fn appendBlueprintJournal(self: *WorldDataService, operation: blueprint_wire.Op) void {
        self.addBlueprintSummary(&self.blueprint_journal_summary, operation) catch unreachable;
        self.blueprint_journal.appendAssumeCapacity(operation);
        self.blueprint_journal_bytes += switch (operation) {
            .definition => |definition| definition.cells.len + definition.name.len + 128,
            .instance => 64,
            .fulfill => 13,
        };
    }

    fn discardPendingBlueprintSaves(self: *WorldDataService) void {
        var pending_commands = self.pending.iterator();
        while (pending_commands.next()) |pending| if (pending.request == .blueprint_save) {
            var candidate = pending.request.blueprint_save.candidate;
            candidate.deinit(self.allocator);
            self.allocator.free(pending.request.blueprint_save.name);
        };
    }

    fn trySaveBlueprint(self: *WorldDataService, save: anytype) !void {
        const state = &self.worker_state.blueprints;
        if (!self.players.contains(save.owner)) return error.UnknownPlayer;
        const definition = save.candidate.definition;
        const key: Client.BlueprintSaveKey = .{ .explicit = save.idempotency_key != null, .value = save.idempotency_key orelse save.request_id };
        if (save.client.blueprint_save_keys.get(key)) |existing_id| {
            const existing = state.definitions.get(existing_id) orelse return error.ConflictingBlueprintSave;
            if (existing.owner != save.owner or !std.mem.eql(u8, existing.name, save.name) or
                !std.mem.eql(u32, &existing.definition.size, &definition.size) or
                existing.definition.target_count != definition.target_count or
                !std.mem.eql(rules.BlockType, existing.definition.cells, definition.cells)) return error.ConflictingBlueprintSave;
            var candidate = save.candidate;
            candidate.deinit(self.allocator);
            self.allocator.free(save.name);
            save.client.resolved_request = @max(save.client.resolved_request, save.request_id);
            save.client.blueprint_results.push(self.io, self.allocator, .{ .request_id = save.request_id, .kind = .save, .status = .success, .definition_id = existing_id });
            self.applyEligibleCheckpoint(save.client);
            return;
        }
        // The compiler certificate owns immutable contents. Save repeats scalar
        // dimensions/ownership checks, never source capture or structural validation.
        const count = try blueprint.checkedVolume(definition.size, blueprint.horizontalLimit(self.layout), blueprint.default_max_cells);
        if (count != definition.cells.len or definition.target_count == 0) return error.InvalidDefinition;
        const id = std.math.add(u64, state.max_definition_id, 1) catch return error.LibraryCapacity;
        const limits = if (self.store) |store| store.limits.blueprints else blueprint_wire.Limits{};
        if (save.client.blueprint_save_keys.count() >= limits.max_definitions) return error.LibraryCapacity;
        const bytes = try std.math.add(usize, definition.cells.len, save.name.len + 128);
        var retained = self.blueprint_library_bytes;
        var active = state.instances.valueIterator();
        while (active.next()) |instance| retained = try std.math.add(usize, retained, instance.fulfilled.len + 128);
        if (state.definitions.count() >= limits.max_definitions or bytes > limits.max_state_bytes -| retained) return error.LibraryCapacity;
        try self.reserveBlueprintJournal(.{ .definition = .{ .id = id, .owner = save.owner, .name = save.name, .size = definition.size, .cells = std.mem.sliceAsBytes(definition.cells), .target_count = definition.target_count } });
        try state.definitions.ensureUnusedCapacity(self.allocator, 1);
        try save.client.blueprint_save_keys.ensureUnusedCapacity(self.allocator, 1);
        const saved: blueprint_runtime.SavedDefinition = .{ .id = id, .owner = save.owner, .name = save.name, .definition = definition };
        var copies: std.ArrayList(blueprint_runtime.SavedDefinition) = .empty;
        defer copies.deinit(self.allocator);
        errdefer for (copies.items) |*copy| copy.deinit(self.allocator);
        try copies.ensureTotalCapacity(self.allocator, self.clients.items.len);
        for (self.clients.items) |client| {
            try client.pending.blueprint_changes.ensureUnusedCapacity(self.allocator, 1);
            copies.appendAssumeCapacity(try saved.clone(self.allocator));
        }
        try state.insertDefinition(self.allocator, saved);
        save.client.blueprint_save_keys.putAssumeCapacity(key, id);
        if (self.store != null) {
            self.appendBlueprintJournal(.{ .definition = .{
                .id = id,
                .owner = save.owner,
                .name = saved.name,
                .size = definition.size,
                .cells = std.mem.sliceAsBytes(definition.cells),
                .target_count = definition.target_count,
            } });
        }
        self.blueprint_library_bytes += bytes;
        for (self.clients.items, copies.items) |client, copy| client.pending.blueprint_changes.appendAssumeCapacity(.{ .definition = copy });
        copies.clearRetainingCapacity();
        self.lifecycle.unsaved_work = true;
        save.client.resolved_request = @max(save.client.resolved_request, save.request_id);
        save.client.blueprint_results.push(self.io, self.allocator, .{ .request_id = save.request_id, .kind = .save, .status = .success, .definition_id = id });
        self.applyEligibleCheckpoint(save.client);
    }

    fn restoreBlueprints(self: *WorldDataService, saved: *storage.Store) !void {
        const Restore = struct {
            service: *WorldDataService,
            store: *storage.Store,
            blocks: std.AutoHashMapUnmanaged(ChunkId, *[32768]u8) = .empty,

            fn get(context: *@This(), block: [3]u32) !u8 {
                const coords, const local = world_module.splitBlockCoords(block);
                const id = context.service.layout.encodeChunkCoords(coords);
                const data = context.blocks.get(id) orelse blk: {
                    const owned = try context.service.allocator.create([32768]u8);
                    errdefer context.service.allocator.destroy(owned);
                    if (try context.store.readChunk(context.service.allocator, id)) |encoded| {
                        defer context.service.allocator.free(encoded);
                        var decoded = try format.decodeChunk(context.service.allocator, context.store.world_uuid, encoded, context.store.dimensions);
                        defer decoded.deinit(context.service.allocator);
                        @memcpy(owned, decoded.blocks);
                    } else {
                        const generator = ColumnGenerator.init(&context.service.worker_state.generator, .{ coords[0], coords[1] });
                        const chunk = try generator.tryGenerateChunk(context.service.allocator, coords[2]);
                        defer chunk.deinit(context.service.allocator);
                        const raw = chunk.content.toData();
                        @memcpy(owned, std.mem.asBytes(&raw.blocks));
                    }
                    try context.blocks.put(context.service.allocator, id, owned);
                    break :blk owned;
                };
                return data[transformations.index(local)];
            }
            fn deinit(context: *@This()) void {
                var values = context.blocks.valueIterator();
                while (values.next()) |value| context.service.allocator.destroy(value.*);
                context.blocks.deinit(context.service.allocator);
            }
        };
        var restore: Restore = .{ .service = self, .store = saved };
        defer restore.deinit();
        try saved.blueprints.validateTerrain(&restore, Restore.get, saved.dimensions);
        const state = &self.worker_state.blueprints;
        var definitions = saved.blueprints.definitions.valueIterator();
        while (definitions.next()) |definition| {
            const name = try self.allocator.dupe(u8, definition.name);
            errdefer self.allocator.free(name);
            const cells = try self.allocator.alloc(rules.BlockType, definition.cells.len);
            errdefer self.allocator.free(cells);
            @memcpy(std.mem.sliceAsBytes(cells), definition.cells);
            try state.insertDefinition(self.allocator, .{ .id = definition.id, .owner = definition.owner, .name = name, .definition = .{ .size = definition.size, .cells = cells, .target_count = definition.target_count } });
            self.blueprint_library_bytes += cells.len + name.len + 128;
        }
        var instances = saved.blueprints.instances.valueIterator();
        while (instances.next()) |instance| {
            var value = try state.prepareInstance(self.allocator, self.layout, instance.id, instance.definition_id, instance.owner, instance.origin, @intCast(instance.rotation));
            errdefer value.deinit(self.allocator);
            if (value.fulfilled.len != instance.fulfilled.len) return error.InvalidBlueprint;
            @memcpy(value.fulfilled, instance.fulfilled);
            value.remaining = instance.remaining;
            try state.insertInstance(self.allocator, self.layout, value);
        }
        state.max_definition_id = saved.blueprints.max_definition_id;
        state.max_instance_id = saved.blueprints.max_instance_id;
    }

    fn beginBlueprintApplication(self: *WorldDataService, apply: BlueprintApplyRequest) void {
        self.operation_deferred = false;
        self.read_discovered = false;
        self.tryBeginBlueprintApplication(apply) catch |err| {
            apply.client.blueprint_results.push(self.io, self.allocator, .{
                .request_id = apply.request_id,
                .kind = .apply,
                .status = if (err == error.OutOfMemory or err == error.Capacity or err == error.Busy) .resource_exhausted else .invalid,
                .rejection = switch (err) {
                    error.InvalidFootprint => .{ .code = .bounds },
                    error.Overlap => .{ .code = .overlap },
                    error.UnknownDefinition, error.WrongOwner => .{ .code = .invalid_definition },
                    else => null,
                },
            });
            apply.client.resolved_request = @max(apply.client.resolved_request, apply.request_id);
            self.applyEligibleCheckpoint(apply.client);
        };
    }

    fn tryBeginBlueprintApplication(self: *WorldDataService, apply: BlueprintApplyRequest) !void {
        if (self.is_shutting_down.load(.acquire)) return error.ServiceStopped;
        if (self.blueprint_task != null or self.blueprint_retired.items.len >= 8) return error.Busy;
        // Every admission owns one retirement slot before it can acquire resources.
        try self.blueprint_retired.ensureUnusedCapacity(self.allocator, 1);
        const state = &self.worker_state.blueprints;
        const saved = state.definitions.get(apply.definition_id) orelse return error.UnknownDefinition;
        if (saved.owner != apply.owner or !self.players.contains(apply.owner)) return error.WrongOwner;
        if (!blueprint_runtime.validFootprint(self.layout, apply.origin, saved.definition.size, apply.rotation)) return error.InvalidFootprint;
        const limits = if (self.store) |store| store.limits.blueprints else blueprint_wire.Limits{};
        if (state.instances.count() >= limits.max_instances) return error.Capacity;
        var retained = self.blueprint_library_bytes;
        var active = state.instances.valueIterator();
        while (active.next()) |instance| retained = try std.math.add(usize, retained, instance.fulfilled.len + 128);
        if ((saved.definition.cells.len + 7) / 8 + 128 > limits.max_state_bytes -| retained) return error.Capacity;
        const id = try std.math.add(u64, state.max_instance_id, 1);
        var instance = try state.prepareInstance(self.allocator, self.layout, id, saved.id, apply.owner, apply.origin, apply.rotation);
        errdefer instance.deinit(self.allocator);
        if (state.overlaps(self.layout, instance)) return error.Overlap;
        const chunk_ids = try blueprint_admission_region.chunks(self.allocator, self.layout, apply.origin, saved.definition.size, apply.rotation, 1024);
        errdefer self.allocator.free(chunk_ids);
        const task = try self.allocator.create(BlueprintAdmissionTask);
        errdefer self.allocator.destroy(task);
        task.* = .{
            .service = self,
            .request = apply,
            .definition = saved.definition,
            .instance = instance,
            .client_count = self.clients.items.len,
            .chunk_ids = chunk_ids,
            .snapshot = .{ .layout = self.layout.*, .overlay_revision = state.revision, .playable_y_inset = self.worker_state.generator.playableYInset() },
        };
        self.blueprint_task = task;
        self.async_progress = true;
    }

    fn currentBlueprintDependency(self: *const WorldDataService, id: ChunkId) u64 {
        if (self.worker_state.modified_chunks.get(id)) |chunk| return chunk.chunk_revision;
        return if (self.catalog) |catalog| catalog.revision(id) orelse 0 else 0;
    }

    fn advanceBlueprintAdmission(self: *WorldDataService) void {
        self.reapBlueprintRetirements();
        const task = self.blueprint_task orelse return;
        if (task.future != null or task.waiting_for_data or task.waiting_for_journal) return;
        if (self.worker_state.blueprints.revision != task.snapshot.overlay_revision) {
            self.rejectBlueprintApplication(task, .stale, null);
            return;
        }
        var copied: usize = 0;
        while (task.cursor < task.chunk_ids.len and copied < 4) : (copied += 1) {
            const id = task.chunk_ids[task.cursor];
            self.blocked_dependency_error = null;
            if (!self.requireBase(id)) {
                if (self.blocked_dependency_error != null) self.rejectBlueprintApplication(task, .missing_data, null) else task.waiting_for_data = true;
                return;
            }
            self.copyBlueprintDependency(task, id) catch |err| {
                self.rejectBlueprintApplication(task, if (err == error.OutOfMemory or err == error.Capacity) .resource_exhausted else .missing_data, null);
                return;
            };
            task.cursor += 1;
        }
        if (task.cursor != task.chunk_ids.len) return;
        task.future = self.io.concurrent(BlueprintAdmissionTask.run, .{task}) catch {
            self.rejectBlueprintApplication(task, .resource_exhausted, null);
            return;
        };
    }

    fn copyBlueprintDependency(self: *WorldDataService, task: *BlueprintAdmissionTask, id: ChunkId) !void {
        const coords = self.layout.decodeChunkId(id);
        const chunk = try self.worker_state.tryLoadAt(self.allocator, coords);
        defer chunk.deinit(self.allocator);
        const source_index = self.worker_state.blueprints.chunks.get(id) orelse blueprint_runtime.ChunkIndex{};
        var immutable: std.ArrayList(transformations.BlockIndex) = .empty;
        defer immutable.deinit(self.allocator);
        if (coords[2] == 0) for (0..32768) |index| {
            const local = transformations.coordinates(@intCast(index));
            const cell: [3]u32 = .{ @as(u32, @intCast(coords[0])) * CHUNK_SIZE + local[0], @as(u32, @intCast(coords[1])) * CHUNK_SIZE + local[1], local[2] };
            if (cell[2] < self.worker_state.generator.deeprockThickness(cell[0], cell[1])) try immutable.append(self.allocator, @intCast(index));
        };
        const estimate = blueprint_admission.estimatedChunkBytes(immutable.items.len, source_index);
        if (estimate > 128 * 1024 * 1024 -| task.snapshot_bytes) return error.Capacity;
        const blocks = try self.allocator.create(@import("world_chunk_data.zig").WorldChunkData);
        errdefer self.allocator.destroy(blocks);
        blocks.* = chunk.content.toData();
        const mask = try immutable.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(mask);
        var index = try source_index.clone(self.allocator);
        errdefer index.deinit(self.allocator);
        try task.snapshot.chunks.put(self.allocator, id, .{ .revision = chunk.chunk_revision, .blocks = blocks, .immutable = mask, .index = index });
        task.snapshot_bytes += estimate;
    }

    fn finishBlueprintApplication(self: *WorldDataService, task: *BlueprintAdmissionTask) void {
        if (self.blueprint_task != task) return;
        if (task.future) |*future| future.await(self.io);
        task.future = null;
        if (self.is_shutting_down.load(.acquire)) {
            self.rejectBlueprintApplication(task, .stale, null);
            return;
        }
        const result = task.result.? catch {
            self.rejectBlueprintApplication(task, .resource_exhausted, null);
            return;
        };
        switch (result) {
            .cancelled => self.rejectBlueprintApplication(task, .stale, null),
            .rejected => |rejection| self.rejectBlueprintApplication(task, switch (rejection.code) {
                .missing_data => .missing_data,
                .budget_exceeded => .resource_exhausted,
                else => .invalid,
            }, rejection),
            .prepared => {
                self.commitBlueprintApplication(task) catch |err| {
                    if (err == error.JournalBackpressure) {
                        task.waiting_for_journal = true;
                        self.drainBlueprintJournal();
                        return;
                    }
                    self.rejectBlueprintApplication(task, if (err == error.StalePreparation or err == error.Overlap) .stale else .resource_exhausted, null);
                    return;
                };
            },
        }
    }

    fn commitBlueprintApplication(self: *WorldDataService, task: *BlueprintAdmissionTask) !void {
        const state = &self.worker_state.blueprints;
        if (state.revision != task.snapshot.overlay_revision) return error.StalePreparation;
        if (self.clients.items.len != task.client_count) return error.StalePreparation;
        var dependencies = task.snapshot.chunks.iterator();
        while (dependencies.next()) |dependency| if (self.currentBlueprintDependency(dependency.key_ptr.*) != dependency.value_ptr.revision) return error.StalePreparation;
        const result = if (task.result.?) |*value| value else |err| return err;
        const prepared = &result.prepared;
        const proposed = prepared.publication.instance;
        try self.reserveBlueprintJournal(.{ .instance = .{ .id = proposed.id, .definition_id = proposed.definition_id, .owner = proposed.owner, .origin = proposed.origin, .rotation = proposed.rotation } });
        try state.reservePublication(self.allocator, self.layout, &prepared.publication);
        for (self.clients.items) |client| {
            try client.pending.blueprint_changes.ensureUnusedCapacity(self.allocator, 1);
        }
        std.debug.assert(task.response_copies.items.len == self.clients.items.len);
        const instance = prepared.publication.instance;
        state.publishPublication(&prepared.publication);
        if (self.store != null) {
            self.appendBlueprintJournal(.{ .instance = .{ .id = instance.id, .definition_id = instance.definition_id, .owner = instance.owner, .origin = instance.origin, .rotation = instance.rotation } });
        }
        for (self.clients.items, task.response_copies.items) |client, copy| client.pending.blueprint_changes.appendAssumeCapacity(.{ .instance = copy });
        task.response_copies.clearRetainingCapacity();
        self.lifecycle.unsaved_work = true;
        task.request.client.resolved_request = @max(task.request.client.resolved_request, task.request.request_id);
        task.request.client.blueprint_results.push(self.io, self.allocator, .{ .request_id = task.request.request_id, .kind = .apply, .status = .success, .definition_id = instance.definition_id, .instance_id = instance.id });
        self.applyEligibleCheckpoint(task.request.client);
        self.retireBlueprintTask(task);
        self.lifecycle.commandResolved();
        self.retryPending();
    }

    fn rejectBlueprintApplication(self: *WorldDataService, task: *BlueprintAdmissionTask, status: @FieldType(BlueprintResult, "status"), rejection: ?BlueprintRejection) void {
        task.request.client.resolved_request = @max(task.request.client.resolved_request, task.request.request_id);
        task.request.client.blueprint_results.push(self.io, self.allocator, .{ .request_id = task.request.request_id, .kind = .apply, .status = status, .rejection = rejection });
        self.applyEligibleCheckpoint(task.request.client);
        self.retireBlueprintTask(task);
        self.lifecycle.commandResolved();
        self.retryPending();
    }

    fn retireBlueprintTask(self: *WorldDataService, task: *BlueprintAdmissionTask) void {
        self.blueprint_task = null;
        self.blueprint_retired.appendAssumeCapacity(task);
        task.future = self.io.concurrent(BlueprintAdmissionTask.release, .{task}) catch blk: {
            BlueprintAdmissionTask.release(task);
            break :blk null;
        };
    }

    fn reapBlueprintRetirements(self: *WorldDataService) void {
        var i: usize = 0;
        while (i < self.blueprint_retired.items.len) {
            const task = self.blueprint_retired.items[i];
            if (!task.retired.load(.acquire)) {
                i += 1;
                continue;
            }
            if (task.future) |*future| future.await(self.io);
            _ = self.blueprint_retired.swapRemove(i);
            self.allocator.destroy(task);
        }
    }

    /// A submitted identity selects a separate path before ordinary dependency,
    /// construction, road, or structural validation work.
    fn processBlueprintFulfillment(self: *WorldDataService, edit: @FieldType(Request, "operation")) void {
        self.read_discovered = false;
        self.operation_deferred = false;
        const coords, const local = world_module.splitBlockCoords(edit.operation.block);
        const id = self.layout.encodeChunkCoords(coords);
        edit.client.pending.responses.ensureUnusedCapacity(self.allocator, 1) catch {
            self.pending.pushFront(self.allocator, .{ .request = .{ .operation = edit }, .since = self.processing_since orelse persistence.now(self.io) }) catch @panic("OOM");
            self.operation_deferred = true;
            self.failPersistence(error.OutOfMemory);
            return;
        };
        const result = self.tryCommitBlueprintFulfillment(edit.operation) catch |err| blk: {
            if (err == error.DependencyPending or err == error.CapturePending or err == error.RoadUpdatesFull or err == error.JournalBackpressure) {
                self.pending.pushFront(self.allocator, .{ .request = .{ .operation = edit }, .since = self.processing_since orelse persistence.now(self.io), .waiting_for_journal = err == error.JournalBackpressure }) catch @panic("OOM");
                self.operation_deferred = true;
                if (err == error.JournalBackpressure) self.drainBlueprintJournal();
                return;
            }
            self.failPersistence(err);
            break :blk WorkerState.BlueprintCommit{ .diagnostics = .{ .status = .resource_exhausted } };
        };
        if (result.diagnostics.status == .success) {
            if (edit.operation.player) |transfer| {
                self.players.getPtr(transfer.id).?.inventory = null;
                self.player_generation +%= 1;
            }
            self.lifecycle.unsaved_work = true;
            const fulfillment = edit.operation.blueprint.?;
            if (self.store != null) {
                self.appendBlueprintJournal(.{ .fulfill = .{ .instance_id = fulfillment.instance_id, .cell_index = fulfillment.cell_index } });
            }
            for (self.clients.items) |client| client.pending.blueprint_changes.appendAssumeCapacity(.{ .fulfill = fulfillment });
            self.publishMaterialChange(coords);
            if (result.changed_below) |below| if (!@reduce(.And, below == coords)) self.publishMaterialChange(below);
            for (std.enums.values(Side)) |side| {
                const i = @intFromEnum(side);
                if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1)) continue;
                const neighbor = world_module.adjacentChunk(self.layout, coords, side) orelse continue;
                self.dirty_meshes.putAssumeCapacity(self.layout.encodeChunkCoords(neighbor), {});
                for (self.clients.items) |client| {
                    const sub = client.subscriptions.getPtr(self.layout.encodeChunkCoords(neighbor)) orelse continue;
                    if (sub.mode == .mesh) sub.mesh_pending = true else sub.boundaries_pending = true;
                }
            }
        } else if (edit.client.subscriptions.getPtr(id)) |sub| {
            // Rejections coalesce an authoritative rebase too, without cloning per attempt.
            if (sub.mode == .blocks) sub.blocks_pending = true;
        }
        if (self.is_shutting_down.load(.monotonic)) {
            if (edit.counted) _ = self.outstanding_operations.fetchSub(1, .release);
            edit.client.resolved_request = edit.request_id;
            return;
        }
        var response: ChunkResponse = .{ .coords = coords, .subscription_id = if (edit.client.subscriptions.get(id)) |sub| sub.id else null, .chunk_revision = if (self.worker_state.modified_chunks.get(id)) |chunk| chunk.chunk_revision else 0, .mesh_revision = self.worker_state.meshRevision(coords), .data = .acknowledgement, .operation = .{ .request_id = edit.request_id, .status = result.diagnostics.status, .failure = result.diagnostics.failure, .counted = edit.counted } };
        if (edit.operation.player) |transfer| {
            const material = if (self.players.get(transfer.id)) |player| player.inventory else null;
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
    }

    fn tryCommitBlueprintFulfillment(self: *WorldDataService, operation: BlockOperation) !WorkerState.BlueprintCommit {
        // Reserve all outward ownership before terrain, inventory, or progress changes.
        if (operation.blueprint) |target| try self.reserveBlueprintJournal(.{ .fulfill = .{ .instance_id = target.instance_id, .cell_index = target.cell_index } });
        for (self.clients.items) |client| try client.pending.blueprint_changes.ensureUnusedCapacity(self.allocator, 1);
        const road_batch = try self.prepareBlueprintRoadUpdates(operation.block);
        const result = try self.worker_state.tryFulfillBlueprint(self.allocator, operation);
        if (result.diagnostics.status == .success) self.commitBlueprintRoadUpdates(road_batch);
        return result;
    }

    fn prepareBlueprintRoadUpdates(self: *WorldDataService, block: [3]u32) !blueprint_road_updates.Batch {
        var batch: blueprint_road_updates.Batch = .{};
        const center: rules.Cell = .{ block[0], block[1], block[2] };
        const offsets = [_]rules.Cell{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 } };
        for (0..2) |level| for (offsets) |offset| {
            const seed = @import("block_coordinates.zig").fromStorage(self.layout, center + offset + rules.Cell{ 0, 0, @intCast(level) }) orelse continue;
            const coords, _ = world_module.splitBlockCoords(seed);
            const id = self.layout.encodeChunkCoords(coords);
            const possible = if (self.worker_state.modified_chunks.get(id)) |chunk|
                chunk.metadata.roads.items.len != 0
            else if (self.catalog) |catalog|
                catalog.revision(id) != null
            else
                false;
            if (possible) batch.add(id);
        };
        const limit = if (self.store) |saved| saved.limits.max_pending_work else blueprint_road_updates.capacity;
        try self.blueprint_road_queue.reserveWithLimit(self.allocator, batch, limit);
        return batch;
    }

    fn commitBlueprintRoadUpdates(self: *WorldDataService, batch: blueprint_road_updates.Batch) void {
        const generation = self.blueprint_road_queue.generation;
        self.blueprint_road_queue.commit(batch);
        if (self.blueprint_road_queue.generation != generation) self.lifecycle.unsaved_work = true;
        if (batch.count != 0) self.blueprint_road_waiting = false;
    }

    /// A bounded batch amortizes worker/publication overhead independently from
    /// structural fills. Entry completion/requeue also consumes one work unit.
    const blueprint_road_work_per_turn: usize = 16;

    fn processBlueprintRoadUpdates(self: *WorldDataService) void {
        _ = self.processBlueprintRoadUpdatesWithBudget(blueprint_road_work_per_turn);
    }

    fn processBlueprintRoadUpdatesWithBudget(self: *WorldDataService, budget: usize) usize {
        const generation = self.blueprint_road_queue.generation;
        defer {
            if (self.blueprint_road_queue.generation != generation) self.lifecycle.unsaved_work = true;
            self.updateSimulationPause();
        }
        var processed: usize = 0;
        while (processed < budget and self.processBlueprintRoadUpdate()) : (processed += 1) {}
        return processed;
    }

    /// Read current metadata at each step. Concurrently accepted edits request a
    /// coalesced next pass instead of repeatedly restarting the current cursor.
    fn processBlueprintRoadUpdate(self: *WorldDataService) bool {
        const entry = self.blueprint_road_queue.peek() orelse return false;
        self.processing_deferred_work = true;
        defer self.processing_deferred_work = false;
        self.blueprint_road_waiting = false;
        self.read_discovered = false;
        self.blocked_dependency_error = null;
        if (!self.requireBase(entry.id)) {
            self.blueprint_road_waiting = true;
            if (self.blocked_dependency_error) |err| self.noteDeferredWorkFailure(err);
            return false;
        }
        const chunk = self.worker_state.modified_chunks.get(entry.id) orelse {
            self.clearDeferredWorkFailure();
            if (self.blueprint_road_queue.finish()) {
                self.processing_deferred_work = false;
                self.retryPending();
            }
            return true;
        };
        self.blueprint_road_queue.observeRevision(chunk.chunk_revision);
        if (entry.cursor >= chunk.metadata.roads.items.len) {
            self.clearDeferredWorkFailure();
            if (self.blueprint_road_queue.finish()) {
                self.processing_deferred_work = false;
                self.retryPending();
            }
            return true;
        }
        const road = chunk.metadata.roads.items[entry.cursor];
        const coords = self.layout.decodeChunkId(entry.id);
        const local = transformations.coordinates(road.index);
        const block: [3]u32 = .{
            @as(u32, @intCast(coords[0])) * CHUNK_SIZE + local[0],
            @as(u32, @intCast(coords[1])) * CHUNK_SIZE + local[1],
            @as(u32, @intCast(coords[2])) * CHUNK_SIZE + local[2],
        };
        self.tryProcessBlueprintRoadSeed(block, road) catch |err| {
            self.blueprint_road_waiting = true;
            if (err != error.DependencyPending and err != error.CapturePending) self.noteDeferredWorkFailure(err);
            return false;
        };
        // Our own atomic shape updates do not require restarting this pass.
        entry.observed_revision = self.worker_state.modified_chunks.get(entry.id).?.chunk_revision;
        self.clearDeferredWorkFailure();
        self.blueprint_road_queue.advance();
        return true;
    }

    fn tryProcessBlueprintRoadSeed(self: *WorldDataService, block: [3]u32, previous: @import("road_data.zig").Road) !void {
        const roads = @import("roads.zig");
        var read: ReadContext = .{ .state = &self.worker_state, .allocator = self.allocator };
        defer read.deinit();
        self.worker_state.road_changes.clearRetainingCapacity();
        const context: roads.Context = .{ .allocator = self.allocator, .reader = read.reader(), .chunks = &self.worker_state.modified_chunks, .changed = &self.worker_state.road_changes, .max_plan_changes = self.limits.manifest_entries };
        var plan = try context.planAfterEdit(.{ .block = block, .action = .{ .put = .custom } }, previous);
        defer plan.deinit(self.allocator);
        if (read.failure) |err| return err;
        if (self.read_discovered) return error.DependencyPending;
        if (plan.changes.len == 0) return;
        for (plan.chunk_ids) |id| if (self.source_holds.contains(id)) {
            if (self.job) |job| job.prioritize(plan.chunk_ids);
            return error.CapturePending;
        };
        // Shapes preserve structural material capabilities, so their publication
        // requires no support or surrounding-construction validation.
        try plan.reserveCommit(context);
        const additional = std.math.mul(usize, plan.chunk_ids.len, 7) catch return error.Capacity;
        try self.worker_state.mesh_revisions.ensureUnusedCapacity(self.allocator, @intCast(additional));
        try self.dirty_meshes.ensureUnusedCapacity(self.allocator, @intCast(additional));
        const mesh_revision = try std.math.add(u64, self.worker_state.next_mesh_revision, 1);
        for (plan.chunk_ids) |id| _ = try std.math.add(u64, self.worker_state.modified_chunks.get(id).?.chunk_revision, 1);
        // All fallible work precedes these metadata/revision/publication writes.
        plan.applyPrepared(context);
        self.worker_state.next_mesh_revision = mesh_revision;
        for (plan.chunk_ids) |id| {
            self.worker_state.modified_chunks.getPtr(id).?.chunk_revision += 1;
            self.worker_state.mesh_revisions.putAssumeCapacity(id, mesh_revision);
            const changed = self.layout.decodeChunkId(id);
            self.publishMaterialChange(changed);
            for (std.enums.values(Side)) |side| {
                const neighbor = world_module.adjacentChunk(self.layout, changed, side) orelse continue;
                const neighbor_id = self.layout.encodeChunkCoords(neighbor);
                self.worker_state.mesh_revisions.putAssumeCapacity(neighbor_id, mesh_revision);
                self.dirty_meshes.putAssumeCapacity(neighbor_id, {});
                for (self.clients.items) |client| {
                    const sub = client.subscriptions.getPtr(neighbor_id) orelse continue;
                    if (sub.mode == .mesh) sub.mesh_pending = true else sub.boundaries_pending = true;
                }
            }
        }
        self.lifecycle.unsaved_work = true;
    }

    fn blueprintDependencies(self: *WorldDataService, operation: BlockOperation) Dependencies {
        var result: Dependencies = .{ .ids = undefined, .count = 0 };
        const center: rules.Cell = .{ operation.block[0], operation.block[1], operation.block[2] };
        const offsets = [_]rules.Cell{ .{ 0, 0, 0 }, .{ 0, 0, -1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
        for (offsets, 0..) |offset, i| {
            if (i == 6 and (operation.action != .put or operation.action.put != .dirt)) continue;
            const block = @import("block_coordinates.zig").fromStorage(self.layout, center + offset) orelse continue;
            const coords, _ = world_module.splitBlockCoords(block);
            const id = self.layout.encodeChunkCoords(coords);
            if (std.mem.indexOfScalar(u32, result.ids[0..result.count], id) != null) continue;
            result.ids[result.count] = id;
            result.count += 1;
        }
        return result;
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
        self.updateSimulationPause();
        if (self.budget) |budget| {
            const stats = budget.stats();
            self.status.live_used_bytes = stats.used;
            self.status.live_peak_bytes = stats.peak;
            self.status.live_allocation_count = stats.allocations;
            self.status.live_rejections = stats.rejections;
        }
        self.scheduleWatchdog();
        self.status.overdue = self.lifecycle.overdue;
        self.status.pending_commands = self.pending.len + @as(usize, if (self.blueprint_task != null) 1 else 0) + self.blueprint_road_queue.count;
        self.status.resident_chunks = self.worker_state.modified_chunks.count();
        self.status.source_count = self.source_holds.count();
        self.status_mutex.lockUncancelable(self.io);
        self.published_status = self.status;
        self.status_mutex.unlock(self.io);
    }

    fn updateSimulationPause(self: *WorldDataService) void {
        self.simulation_paused.store(self.source_holds.count() != 0, .release);
    }

    /// Conservative bounded superset of every write performed by afterEdit: road runs
    /// are at most twelve cells, their candidate seeds add one, and revelation reaches
    /// one face neighbor. Include all z planes touched by covering/uncovering soil.
    fn admissible(self: *WorldDataService, request: Request) bool {
        if (request == .operation or request == .blueprint_save or request == .blueprint_apply) {
            if (self.blueprint_task != null) return false;
        }
        if (request != .operation) return true;
        const edit = request.operation;
        if (self.source_holds.count() == 0) return true;
        if (edit.client.simulation) return false;
        if (edit.operation.blueprint != null) {
            const small = self.blueprintDependencies(edit.operation);
            for (small.ids[0..small.count]) |id| if (self.source_holds.contains(id)) {
                if (self.job) |job| job.prioritize(small.ids[0..small.count]);
                return false;
            };
            return !self.lifecycle.overdue;
        }
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

    /// Advance a queued save without retrying retained mutations. An older
    /// writer's failure must not restart a journal-blocked FIFO head here.
    fn advanceSaveDrain(self: *WorldDataService) void {
        self.selectSaveDrain();
        // A preceding writer may have been the last source of wakes.
        // Revisit retained query failures when this drain takes over.
        if (self.lifecycle.needsQueryRecheck(self.lifecycleObservations())) self.retryWaitingReads();
        if (self.lifecycle.takeReady(self.lifecycleObservations())) |save| self.beginCapture(save.id, save.final) catch |err| self.failPersistence(err);
    }

    fn retryPending(self: *WorldDataService) void {
        while (true) {
            self.advanceSaveDrain();
            if (self.pending.len == 0) break;
            if (self.internal_capture_suspended and self.pending.frontPtr().?.waiting_for_journal) break;
            self.blocked_dependency_error = null;
            if (!self.dependenciesReady(self.pending.frontPtr().?.request)) {
                if (self.blocked_dependency_error) |err| self.noteDrainFailure(err);
                break;
            }
            if (!self.admissible(self.pending.frontPtr().?.request)) break;
            const pending = self.pending.popFront().?;
            self.processing_since = pending.since;
            self.processAdmitted(pending.request);
            self.processing_since = null;
            // Apply remains the FIFO head until detached admission publishes or rejects.
            if (pending.request == .blueprint_apply and self.blueprint_task != null) break;
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
        // Freeze pending obligations with the same terrain/progress prefix.
        defer self.updateSimulationPause();
        self.status.intent_id = intent;
        self.status.target_sequence = 0;
        self.status.active = false;
        const store = self.store orelse return;
        if (self.is_shutting_down.load(.acquire)) return error.ServiceStopped;
        std.debug.assert(self.job == null and self.source_holds.count() == 0);
        const blueprint_change_bytes = try blueprint_wire.encodedOpsSize(self.blueprint_journal.items);
        // Rebuild once at the capture boundary, never on each fulfillment.
        var blueprint_summary: blueprint_wire.PrepareSummary = .{};
        for (self.blueprint_journal.items) |operation| try self.addBlueprintSummary(&blueprint_summary, operation);
        self.blueprint_journal_summary = blueprint_summary;
        const blueprint_prepare_bytes = try blueprint_wire.prepareMemoryBound(blueprint_summary, store.limits.blueprints);
        const journal_capacity_bytes = try std.math.mul(usize, self.blueprint_journal.capacity, @sizeOf(blueprint_wire.Op));
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
        var largest_output: usize = 0;
        var preflight_chunks = self.worker_state.modified_chunks.iterator();
        while (preflight_chunks.next()) |entry| {
            if (entry.value_ptr.chunk_revision == 0 or self.wal_revisions.get(entry.key_ptr.*) == entry.value_ptr.chunk_revision) continue;
            source_count = try std.math.add(usize, source_count, 1);
            if (source_count > self.limits.manifest_entries) return error.ManifestCapacityExceeded;
            const source = persistence.Source.freeze(entry.key_ptr.*, 0, entry.value_ptr);
            scratch_peak = @max(scratch_peak, try persistence.scratchBound(source));
            largest_output = @max(largest_output, try persistence.outputBound(source));
            if (try persistence.outputBound(source) > self.limits.output_bytes) return error.OutputCapacityTooSmall;
        }
        // Before allocating any capture manifest or growing bookkeeping, reserve
        // a conservative peak including old/new hash-table and ring overlap.
        var preflight_bytes = try std.math.add(usize, self.limits.output_bytes, try self.captureWorkingOverhead(source_count, scratch_peak));
        preflight_bytes = try std.math.add(usize, preflight_bytes, blueprint_change_bytes);
        preflight_bytes = try std.math.add(usize, preflight_bytes, blueprint_prepare_bytes);
        preflight_bytes = try std.math.add(usize, preflight_bytes, journal_capacity_bytes);
        // A bounded smaller queue lets an admitted journal drain without
        // dropping operations or separating blueprint progress from terrain.
        var job_limits = self.limits;
        if (preflight_bytes > self.limits.working_bytes) {
            const excess = preflight_bytes - self.limits.working_bytes;
            if (excess > job_limits.output_bytes -| largest_output) return error.WorkingCapacityExceeded;
            job_limits.output_bytes -= excess;
            preflight_bytes -= excess;
        }
        const blueprint_changes = if (blueprint_change_bytes != 0)
            try blueprint_wire.encodeOps(self.allocator, self.blueprint_journal.items)
        else
            @as([]u8, &.{});
        errdefer self.allocator.free(blueprint_changes);
        const pending_work = try self.blueprint_road_queue.snapshotEncoded(self.allocator, store.dimensions, store.limits.max_pending_work);
        errdefer self.allocator.free(pending_work);
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
        job.* = .{ .allocator = self.allocator, .io = self.io, .store = store, .store_mutex = &self.store_mutex, .limits = job_limits, .notify = .{ .context = self, .send = notifyPersistence }, .epoch = self.capture_epoch, .sequence = try std.math.add(u64, self.status.durable_sequence, 1), .tick = self.worker_state.tick, .final = final, .sources = frozen, .players = players, .player_count = self.players.count(), .blueprint_changes = blueprint_changes, .blueprint_summary = blueprint_summary, .blueprint_journal_reserved_bytes = journal_capacity_bytes, .pending_work = pending_work };
        const job_manifest = try std.math.mul(usize, source_count, @sizeOf(persistence.Source) + 2 + @sizeOf([]u8));
        const job_baseline = try std.math.add(usize, try std.math.add(usize, blueprint_prepare_bytes, try persistence.pendingWorkMemoryBound(pending_work.len)), try std.math.add(usize, job_limits.output_bytes, try std.math.add(usize, job_manifest, try std.math.add(usize, players.len + blueprint_changes.len, try std.math.add(usize, scratch_peak, @sizeOf(persistence.Job))))));
        job.extra_working_bytes = @max(bookkeeping, preflight_bytes - job_baseline);
        for (frozen) |source| self.source_holds.putAssumeCapacity(source.id, source.revision);
        errdefer self.source_holds.clearRetainingCapacity();
        try job.start();
        self.job = job;
        const started = persistence.now(self.io);
        self.lifecycle.started(.{ .id = intent, .final = final }, job.epoch, started);
        self.captured_player_generation = self.player_generation;
        self.captured_work_generation = self.blueprint_road_queue.generation;
        self.captured_blueprint_operations = self.blueprint_journal.items.len;
        self.captured_blueprint_summary = blueprint_summary;
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
        defer self.updateSimulationPause();
        const job = self.job orelse return;
        switch (event) {
            .released => |released| {
                if (released.epoch != job.epoch or self.source_holds.get(released.id) != released.revision) return;
                _ = self.source_holds.remove(released.id);
                self.blueprint_road_waiting = false;
                self.status.progress_generation +%= 1;
                if (self.source_holds.count() == 0) {
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
                const committed_ops = self.captured_blueprint_operations;
                std.debug.assert(committed_ops <= self.blueprint_journal.items.len);
                var committed_bytes: usize = 0;
                for (self.blueprint_journal.items[0..committed_ops]) |operation| committed_bytes += switch (operation) {
                    .definition => |definition| definition.cells.len + definition.name.len + 128,
                    .instance => 64,
                    .fulfill => 13,
                };
                const remaining_ops = self.blueprint_journal.items.len - committed_ops;
                std.mem.copyForwards(blueprint_wire.Op, self.blueprint_journal.items[0..remaining_ops], self.blueprint_journal.items[committed_ops..]);
                self.blueprint_journal.items.len = remaining_ops;
                self.blueprint_journal_bytes -|= committed_bytes;
                inline for (std.meta.fields(blueprint_wire.PrepareSummary)) |field| {
                    @field(self.blueprint_journal_summary, field.name) -= @field(self.captured_blueprint_summary, field.name);
                }
                self.captured_blueprint_summary = .{};
                self.captured_blueprint_operations = 0;
                if (remaining_ops == 0) {
                    self.blueprint_journal.deinit(self.allocator);
                    self.blueprint_journal = .empty;
                }
                self.lifecycle.unsaved_work = self.player_generation != self.captured_player_generation or remaining_ops != 0 or self.blueprint_road_queue.generation != self.captured_work_generation;
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
                // Only a processed commit retires the journal prefix. A later
                // finalization failure still leaves that durable progress valid.
                const committed = self.lifecycle.active.?.stage == .finalizing;
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
                const handoff = !committed and self.lifecycle.queued != null and self.lifecycle.queued.?.fence_remaining == 0;
                switch (completion.outcome) {
                    .complete => self.status.phase = .complete,
                    .canceled, .failed => |err| if (committed or handoff) self.failPersistence(err) else self.noteDrainFailure(err),
                }
                self.status.progress_generation +%= 1;
                // An uncommitted failure cannot free journal space. Retrying
                // blocked mutations would start another failing prefix writer.
                if (committed) {
                    if (self.pending.len != 0) self.pending.frontPtr().?.waiting_for_journal = false;
                    self.retryWaitingBlueprintApplication();
                    self.retryPending();
                } else if (handoff) {
                    // This queued intent owns its first capture, independently
                    // of the old failure. Preserve its remaining readiness gates.
                    self.reportSaveDrain(self.lifecycle.queued.?.intent);
                    self.advanceSaveDrain();
                }
            },
        }
    }

    fn oldestPlayerWait(self: *WorldDataService) ?i96 {
        var pending_commands = self.pending.iterator();
        while (pending_commands.next()) |pending| if (!requestClient(pending.request).simulation) return pending.since;
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
                self.requestSaveTransition(intent, false);
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
        try validateRestoredFloor(&self.worker_state.generator, self.layout.decodeChunkId(decoded.id), decoded.blocks, decoded_metadata);
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
        // Persistence canonicalizes road order without changing chunk revision.
        // A resident cursor cannot be carried across that array replacement.
        self.blueprint_road_queue.restartAfterLoad(id);
        self.worker_state.generated_chunks.remove(self.allocator, id);
        self.worker_state.modified_chunks.putAssumeCapacity(id, chunk);
        self.base_revisions.putAssumeCapacity(id, revision);
        self.wal_revisions.putAssumeCapacity(id, revision);
        if (chunk.metadata.timed.events.items.len != 0) self.worker_state.timed_chunks.putAssumeCapacity(id, {});
    }

    fn failDependencyRead(self: *WorldDataService, err: anyerror) void {
        self.blocked_dependency_error = err;
        if (self.processing_deferred_work) self.noteDeferredWorkFailure(err) else self.noteDrainFailure(err);
    }

    fn requireBase(self: *WorldDataService, id: u32) bool {
        if (self.worker_state.modified_chunks.contains(id)) return true;
        const catalog = if (self.catalog) |*value| value else return true;
        if (catalog.revision(id) == null) return true;
        // A foreground consumer promotes a shared dependency into its save fence.
        if (!self.processing_deferred_work and self.deferred_reads.count() != 0) _ = self.deferred_reads.remove(id);
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
                if (self.processing_deferred_work) self.deferred_reads.ensureUnusedCapacity(self.allocator, 1) catch {
                    handle.deinit();
                    self.failDependencyRead(error.OutOfMemory);
                    return false;
                };
                self.read_pending.put(self.allocator, id, handle.revision) catch {
                    handle.deinit();
                    self.failDependencyRead(error.OutOfMemory);
                    return false;
                };
                if (self.processing_deferred_work) self.deferred_reads.putAssumeCapacity(id, {});
                self.read_requests.tryPush(self.io, self.allocator, handle.*) catch |err| {
                    _ = self.read_pending.remove(id);
                    _ = self.deferred_reads.remove(id);
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
        const context: roads.Context = .{ .allocator = self.allocator, .reader = reader.reader(), .chunks = &self.worker_state.modified_chunks, .changed = &self.worker_state.road_changes, .max_plan_changes = self.limits.manifest_entries };
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
                if (edit.operation.blueprint != null) {
                    const small = self.blueprintDependencies(edit.operation);
                    for (small.ids[0..small.count]) |id| ready = self.requireBase(id) and ready;
                    return ready;
                }
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
        if (self.pending.len != 0 or self.waiting_reads.items.len != 0 or self.read_pending.count() != 0) return;
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

/// A decoded record must preserve the complete canonical mask before it can
/// enter resident state. This applies equally to base and WAL-backed reads.
fn validateRestoredFloor(generator: *const PreparedWorldGenerator, coords: ChunkCoords, blocks: []const u8, metadata: format.Metadata) !void {
    const floor_id = @intFromEnum(@import("engine").voxel_chunk.BlockType.deeprock);
    if (coords[2] != 0) {
        if (std.mem.indexOfScalar(u8, blocks, floor_id) != null) return error.InvalidWorldData;
        return;
    }
    for (0..CHUNK_SIZE) |y| for (0..CHUNK_SIZE) |x| {
        const gx = @as(u32, @intCast(coords[0])) * CHUNK_SIZE + @as(u32, @intCast(x));
        const gy = @as(u32, @intCast(coords[1])) * CHUNK_SIZE + @as(u32, @intCast(y));
        const thickness = generator.deeprockThickness(gx, gy);
        for (0..CHUNK_SIZE) |z| {
            if ((blocks[(z * CHUNK_SIZE + y) * CHUNK_SIZE + x] == floor_id) != (z < thickness)) return error.InvalidWorldData;
        }
    };
    // Construction and timers on an otherwise valid protected material are
    // corruption too; restoration never repairs or silently regenerates records.
    for (metadata.construction) |index| if (blocks[index] == @intFromEnum(@import("engine").voxel_chunk.BlockType.deeprock)) return error.InvalidWorldData;
    for (metadata.timers) |timer| if (blocks[timer.cell] == @intFromEnum(@import("engine").voxel_chunk.BlockType.deeprock)) return error.InvalidWorldData;
}

const ReadContext = struct {
    state: *WorkerState,
    allocator: std.mem.Allocator,
    /// Operation-local fallback when shared caching is disabled or its index
    /// cannot grow. Shared entries have the worker's lifetime instead.
    chunks: world_module.ChunksHashMap = .empty,
    failure: ?anyerror = null,
    read_count: u64 = 0,

    fn immutableAt(context: *anyopaque, block: [3]u32) bool {
        const self: *ReadContext = @ptrCast(@alignCast(context));
        return block[2] < self.state.generator.deeprockThickness(block[0], block[1]);
    }

    fn reader(self: *ReadContext) rules.Reader {
        return .{ .layout = self.state.layout, .context = self, .block_at = read, .custom_shape_at = readShape, .immutable_at = immutableAt, .playable_y_inset = self.state.generator.playableYInset() };
    }

    fn deinit(self: *ReadContext) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
    }

    fn read(context: *anyopaque, block: [3]u32) ?@import("engine").voxel_chunk.BlockType {
        const self: *ReadContext = @ptrCast(@alignCast(context));
        self.read_count +%= 1;
        const coords, const local = world_module.splitBlockCoords(block);
        const chunk = self.chunkAt(coords) catch |err| {
            if (err != error.DependencyPending) self.failure = err;
            return null;
        };
        return chunk.content.getBlock(local);
    }

    /// Borrowed only until the next cache access. Callers consume the requested
    /// block/shape immediately; reads never pin every active site's support.
    fn chunkAt(self: *ReadContext, coords: ChunkCoords) !*const WorldChunk {
        const id = self.state.layout.encodeChunkCoords(coords);
        if (self.state.modified_chunks.getPtr(id)) |chunk| return chunk;
        // Catalog-backed data must be loaded even if a generated entry exists.
        if (self.state.persistence_service) |service| if (!service.requireBase(id)) return error.DependencyPending;
        if (self.chunks.getPtr(id)) |chunk| return chunk;
        if (self.state.generated_chunks.get(id)) |chunk| return chunk;
        const generator = ColumnGenerator.init(&self.state.generator, .{ coords[0], coords[1] });
        const chunk = try generator.tryGenerateChunk(self.allocator, coords[2]);
        self.state.generated_chunk_count +%= 1;
        // Cache metadata is optional. On allocation failure retain the ordinary
        // per-operation owner, so caching cannot turn a usable read into OOM.
        if (self.state.generated_chunks.insert(self.allocator, id, chunk) catch false)
            return self.state.generated_chunks.peek(id).?;
        errdefer chunk.deinit(self.allocator);
        try self.chunks.put(self.allocator, id, chunk);
        return self.chunks.getPtr(id).?;
    }

    fn readShape(context: *anyopaque, block: [3]u32) ?@import("engine").voxel_chunk.custom_block.Shape {
        const self: *ReadContext = @ptrCast(@alignCast(context));
        if (read(context, block) != .custom) return null;
        const coords, const local = world_module.splitBlockCoords(block);
        const id = self.state.layout.encodeChunkCoords(coords);
        const chunk = self.state.modified_chunks.get(id) orelse self.chunks.get(id) orelse self.state.generated_chunks.peek(id).?.*;
        const road = chunk.metadata.road(transformations.index(local)) orelse return null;
        return road.shape();
    }
};

const WorkerState = struct {
    layout: *const WorldLayout,
    generator: PreparedWorldGenerator,
    blueprints: blueprint_runtime.State = .{},
    /// Committed edits survive cache eviction. Untouched chunks are regenerated on demand.
    modified_chunks: std.AutoHashMapUnmanaged(ChunkId, WorldChunk) = .empty,
    /// Immutable generated data, independently bounded and never captured as
    /// authoritative state. Uses the service allocator, not the live-state budget.
    generated_chunks: GeneratedChunkCache = .{},
    /// Successful generated materializations by read/load/promotion paths.
    generated_chunk_count: u64 = 0,
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
    blueprint_last_support_reads: u8 = 0,
    blueprint_support_reads: u64 = 0,
    blueprint_fulfillment_attempts: u64 = 0,
    ordinary_validation_calls: u64 = 0,
    fn liveAllocator(self: *const WorkerState, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.live_allocator orelse fallback;
    }

    fn resolveRestoredPosition(self: *WorkerState, allocator: std.mem.Allocator, feet: [3]f64, body: @import("terrain_collision.zig").Body) StandingSpaceError!standing_space.Position {
        for (feet) |coordinate| if (!std.math.isFinite(coordinate) or @abs(coordinate) >= 0x1p62) return error.InvalidSearch;
        const position: standing_space.Position = feet;
        var temporary = world_module.World.init(allocator, self.layout) catch return error.MissingData;
        defer temporary.deinit();
        temporary.playable_y_inset = self.generator.playableYInset();
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
        return standing_space.find(context.reader(), query);
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
        const masks = if (self.generated_chunks.peek(id)) |chunk| chunk.boundaries else blk: {
            const chunk = try self.tryLoadAt(allocator, coords);
            defer chunk.deinit(allocator);
            break :blk chunk.boundaries;
        };
        if (self.boundary_cache.count() >= 512) self.boundary_cache.clearRetainingCapacity();
        // Caching is optional; the correctly computed masks remain usable on OOM.
        self.boundary_cache.put(allocator, id, masks) catch {};
        return masks;
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
        if (self.generated_chunks.peek(id)) |chunk| return chunk.tryClone(allocator);
        const key = @as(u64, @intCast(coords[0])) << 32 | @as(u64, @intCast(coords[1]));
        if (!self.columns.contains(key)) {
            if (self.columns.count() >= 64) self.columns.clearRetainingCapacity();
            try self.columns.put(allocator, key, ColumnGenerator.init(&self.generator, .{ coords[0], coords[1] }));
        }
        const chunk = try self.columns.getPtr(key).?.tryGenerateChunk(allocator, coords[2]);
        self.generated_chunk_count +%= 1;
        return chunk;
    }

    fn deinit(self: *WorkerState, allocator: std.mem.Allocator) void {
        self.blueprints.deinit(allocator);
        var iterator = self.modified_chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.deinit(self.liveAllocator(allocator));
        self.modified_chunks.deinit(allocator);
        self.generated_chunks.deinit(allocator);
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
        const live = self.liveAllocator(allocator);
        if (self.generated_chunks.peek(id)) |cached| {
            // Reserve the destination before releasing cache ownership. Persistent
            // live-state allocations use a distinct budget wrapper and must clone;
            // freeing a backing allocation through that wrapper is invalid.
            try self.modified_chunks.ensureUnusedCapacity(allocator, 1);
            const chunk = if (live.ptr == allocator.ptr and live.vtable == allocator.vtable)
                self.generated_chunks.take(id).?
            else
                try cached.tryClone(live);
            self.modified_chunks.putAssumeCapacity(id, chunk);
            self.generated_chunks.remove(allocator, id);
            return;
        }
        const generator = ColumnGenerator.init(&self.generator, .{ coords[0], coords[1] });
        const chunk = try generator.tryGenerateChunk(live, coords[2]);
        errdefer chunk.deinit(live);
        self.generated_chunk_count +%= 1;
        try self.modified_chunks.put(allocator, id, chunk);
    }

    fn tryApplyOperation(self: *WorkerState, allocator: std.mem.Allocator, operation: BlockOperation) !ApplyResult {
        self.ordinary_validation_calls +%= 1;
        const live = self.liveAllocator(allocator);
        self.road_changes.clearRetainingCapacity();
        if (self.persistence_service) |service| if (service.run_gate_failure) |err| return err;
        const cells: []const rules.Cell = if (operation.action == .remove)
            try world_module.tryCollectConstructed(allocator, self.layout, &self.modified_chunks, operation.block)
        else
            &.{};
        defer if (operation.action == .remove) allocator.free(cells);
        var context: ReadContext = .{ .state = self, .allocator = allocator };
        defer context.deinit();
        var diagnostics = world_module.validateCompletedEdit(allocator, context.reader(), &self.blueprints, cells, operation);
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
            const chunk = try (try context.chunkAt(coords)).tryClone(allocator);
            return .{ .status = diagnostics.status, .chunk = chunk, .revealed_neighbors = @splat(null), .changed_below = null, .diagnostics = diagnostics };
        }

        // Materialize unchanged dependencies before obtaining pointers; rehashing may move headers.
        try self.modified_chunks.ensureUnusedCapacity(allocator, 8);
        try self.ensureResident(allocator, coords);
        const previous_road = self.modified_chunks.get(position).?.metadata.road(transformations.index(local));
        const previous_flags = self.modified_chunks.get(position).?.flags;
        const road_context: @import("roads.zig").Context = .{
            .allocator = allocator,
            .reader = context.reader(),
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
        // Validate both the target and indirect soil/timer writes as one plan.
        // Road section writes were validated by the shared road planner above.
        var writes: [2]mutation_guard.Write = undefined;
        writes[0] = .{ .block = operation.block, .material = if (operation.action == .put) operation.action.put else .none };
        var write_count: usize = 1;
        if (below_coords != null) {
            var below_block = operation.block;
            below_block[2] -= 1;
            writes[1] = .{ .block = below_block, .material = if (below_changed) .packed_dirt else ReadContext.read(&context, below_block) orelse return error.DependencyPending };
            write_count += 1;
        }
        if (mutation_guard.validateWrites(context.reader(), writes[0..write_count])) |failure| {
            const rejected: world_module.EditResult = .{ .status = .constraint_violation, .failure = failure };
            return .{ .status = rejected.status, .chunk = try target.tryClone(allocator), .revealed_neighbors = @splat(null), .changed_below = null, .diagnostics = rejected };
        }
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

    const BlueprintCommit = struct { diagnostics: world_module.EditResult, changed_below: ?ChunkCoords = null };

    fn tryFulfillBlueprint(self: *WorkerState, allocator: std.mem.Allocator, operation: BlockOperation) !BlueprintCommit {
        var context: ReadContext = .{ .state = self, .allocator = allocator };
        defer context.deinit();
        var diagnostics = world_module.validateBlueprintFulfillment(context.reader(), &self.blueprints, operation);
        const support_reads = context.read_count -| 1; // The separate target occupancy read is not support.
        std.debug.assert(support_reads <= 5);
        self.blueprint_last_support_reads = @intCast(support_reads);
        self.blueprint_support_reads +%= support_reads;
        self.blueprint_fulfillment_attempts +%= 1;
        if (context.failure) |err| return err;
        if (self.persistence_service) |service| if (service.read_discovered) return error.DependencyPending;
        if (operation.player) |transfer| {
            const service = self.persistence_service orelse return error.MissingPlayer;
            const player = service.players.get(transfer.id);
            if (player == null or operation.action != .put or player.?.inventory != @as(?u8, @intFromEnum(operation.action.put))) diagnostics = .{ .status = .inventory_mismatch };
        }
        if (diagnostics.status != .success) return .{ .diagnostics = diagnostics };
        const live = self.liveAllocator(allocator);
        const coords, const local = world_module.splitBlockCoords(operation.block);
        const id = self.layout.encodeChunkCoords(coords);
        var below_coords: ?ChunkCoords = null;
        var below_local: [3]u5 = undefined;
        var below_changed = false;
        if (operation.block[2] != 0) {
            var below = operation.block;
            below[2] -= 1;
            const material = ReadContext.read(&context, below) orelse return context.failure orelse error.DependencyPending;
            if (material.isEarth()) {
                const bc, const bl = world_module.splitBlockCoords(below);
                below_coords = bc;
                below_local = bl;
                below_changed = material != .packed_dirt;
            }
        }
        const covered = if (operation.action.put == .dirt and operation.block[2] + 1 < self.layout.size_in_blocks[2]) blk: {
            var above = operation.block;
            above[2] += 1;
            break :blk (ReadContext.read(&context, above) orelse return context.failure orelse error.DependencyPending) != .none;
        } else false;
        if (context.failure) |err| return err;
        if (self.persistence_service) |service| if (service.read_discovered) return error.DependencyPending;
        try self.modified_chunks.ensureUnusedCapacity(allocator, 2);
        try self.ensureResident(allocator, coords);
        if (below_coords) |below| try self.ensureResident(allocator, below);
        const target = self.modified_chunks.getPtr(id).?;
        try target.metadata.reserve(live, 0, 1, if (operation.action.put == .dirt and !covered) 1 else 0);
        const prepared = try target.prepareApply(live, local, operation.action);
        if (prepared != .success) return .{ .diagnostics = .{ .status = prepared } };
        _ = try std.math.add(u64, target.chunk_revision, 1);
        if (below_coords) |below| {
            const bid = self.layout.encodeChunkCoords(below);
            if (bid != id) _ = try std.math.add(u64, self.modified_chunks.get(bid).?.chunk_revision, 1);
        }
        const next_mesh = try std.math.add(u64, self.next_mesh_revision, 1);
        try self.mesh_revisions.ensureUnusedCapacity(allocator, 8);
        try self.timed_chunks.ensureUnusedCapacity(allocator, 2);
        if (self.persistence_service) |service| try service.dirty_meshes.ensureUnusedCapacity(allocator, 8);
        // Earth aging is structurally equivalent and cannot change target identity.
        // No road planning, dependent enumeration, or ordinary validator is invoked here.
        std.debug.assert(target.applyPrepared(live, local, operation.action) == .success);
        target.metadata.appendConstructedKnownEmptyAssumeCapacity(transformations.index(local));
        if (operation.action.put == .dirt) {
            if (covered) target.changeType(local, .packed_dirt) else target.metadata.timed.scheduleAssumeCapacity(.{ .block = transformations.index(local), .kind = .compact_dirt, .due_tick = self.tick +| transformations.transformation_delay });
        }
        target.chunk_revision += 1;
        self.next_mesh_revision = next_mesh;
        self.mesh_revisions.putAssumeCapacity(id, next_mesh);
        if (target.metadata.timed.events.items.len != 0) self.timed_chunks.putAssumeCapacity(id, {});
        if (below_coords) |below| {
            const bid = self.layout.encodeChunkCoords(below);
            const chunk = self.modified_chunks.getPtr(bid).?;
            chunk.metadata.timed.cancel(transformations.index(below_local));
            if (below_changed) chunk.changeType(below_local, .packed_dirt);
            if (bid != id) chunk.chunk_revision += 1;
            self.mesh_revisions.putAssumeCapacity(bid, next_mesh);
            if (chunk.metadata.timed.events.items.len == 0) _ = self.timed_chunks.remove(bid) else self.timed_chunks.putAssumeCapacity(bid, {});
        }
        for (std.enums.values(Side)) |side| {
            const i = @intFromEnum(side);
            if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1)) continue;
            if (world_module.adjacentChunk(self.layout, coords, side)) |neighbor| self.mesh_revisions.putAssumeCapacity(self.layout.encodeChunkCoords(neighbor), next_mesh);
        }
        std.debug.assert(self.blueprints.fulfill(self.layout, operation.blueprint.?));
        return .{ .diagnostics = .{ .status = .success }, .changed_below = below_coords };
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
        var context: ReadContext = .{ .state = self, .allocator = allocator };
        defer context.deinit();
        // Consumption/rescheduling is itself a persistent write. Reject the
        // complete timer plan if any due event targets the immutable mask.
        for (source.metadata.timed.events.items) |event| {
            if (event.due_tick > self.tick) continue;
            const local = transformations.coordinates(event.block);
            const block: [3]u32 = .{
                @as(u32, @intCast(coords[0])) * CHUNK_SIZE + local[0],
                @as(u32, @intCast(coords[1])) * CHUNK_SIZE + local[1],
                @as(u32, @intCast(coords[2])) * CHUNK_SIZE + local[2],
            };
            if (mutation_guard.validateWrites(context.reader(), &.{.{ .block = block, .material = source.content.getBlock(local) }}) != null) return false;
        }
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

test "rejected edits share generated chunks without making authoritative residents" {
    const a = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
    defer state.deinit(a);
    const block: [3]u32 = .{ 10, 10, 40 };
    for (0..3) |_| {
        const result = try state.tryApplyOperation(a, .{ .block = block, .action = .{ .put = .planks } });
        defer result.chunk.deinit(a);
        try std.testing.expectEqual(OperationStatus.already_exists, result.status);
        try std.testing.expectEqual(rules.BlockType.stone, result.chunk.content.getBlock(.{ 10, 10, 8 }));
    }
    try std.testing.expectEqual(@as(u64, 1), state.generated_chunk_count);
    try std.testing.expect(state.generated_chunks.hits > 0);
    try std.testing.expectEqual(@as(usize, 1), state.generated_chunks.count());
    try std.testing.expectEqual(@as(usize, 0), state.modified_chunks.count());
    try std.testing.expectEqual(@as(usize, 0), state.timed_chunks.count());
    try std.testing.expectEqual(@as(usize, 0), state.mesh_revisions.count());
}

test "promotion moves cached generated data once and later reads see real edits" {
    const a = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
    defer state.deinit(a);
    const coords: ChunkCoords = .{ 0, 0, 1 };
    const id = test_layout.encodeChunkCoords(coords);
    {
        var context: ReadContext = .{ .state = &state, .allocator = a };
        defer context.deinit();
        try std.testing.expectEqual(rules.BlockType.stone, context.reader().get(.{ 10, 10, 40 }).?);
    }
    const generated = state.generated_chunks.peek(id).?.content.blocks;
    const flags = state.generated_chunks.peek(id).?.flags;
    try state.ensureResident(a, coords);
    const resident = state.modified_chunks.getPtr(id).?;
    try std.testing.expectEqual(generated, resident.content.blocks);
    try std.testing.expectEqual(flags, resident.flags);
    try std.testing.expectEqual(@as(u64, 1), state.generated_chunk_count);
    try std.testing.expectEqual(@as(usize, 0), state.generated_chunks.count());
    try std.testing.expectEqual(OperationStatus.success, try resident.tryApply(a, .{ 10, 10, 8 }, .remove));
    resident.chunk_revision = 1;
    var context: ReadContext = .{ .state = &state, .allocator = a };
    defer context.deinit();
    try std.testing.expectEqual(rules.BlockType.none, context.reader().get(.{ 10, 10, 40 }).?);
    try std.testing.expectEqual(@as(u64, 1), state.generated_chunk_count);
}

test "generated cache does not bypass live budget and clone failure retains its owner" {
    const a = std.testing.allocator;
    var budget = @import("persistence/budget.zig").Budget.init(a, 0);
    {
        var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout), .live_allocator = budget.allocator() };
        defer state.deinit(a);
        const coords: ChunkCoords = .{ 0, 0, 1 };
        const id = test_layout.encodeChunkCoords(coords);
        {
            var context: ReadContext = .{ .state = &state, .allocator = a };
            defer context.deinit();
            try std.testing.expectEqual(rules.BlockType.stone, context.reader().get(.{ 10, 10, 40 }).?);
        }
        const generated = state.generated_chunks.peek(id).?.content.blocks;
        try std.testing.expectError(error.OutOfMemory, state.ensureResident(a, coords));
        try std.testing.expectEqual(generated, state.generated_chunks.peek(id).?.content.blocks);
        try std.testing.expectEqual(@as(usize, 0), state.modified_chunks.count());
        try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
        budget.limit = 128 * 1024;
        try state.ensureResident(a, coords);
        try std.testing.expect(generated != state.modified_chunks.get(id).?.content.blocks);
        try std.testing.expectEqual(@sizeOf(@import("world_chunk_data.zig").WorldChunkData), budget.stats().used);
        try std.testing.expectEqual(@as(usize, 0), state.generated_chunks.count());
        try std.testing.expectEqual(@as(u64, 1), state.generated_chunk_count);
    }
    try std.testing.expectEqual(@as(usize, 0), budget.stats().used);
}

test "generated cache promotion preserves ownership on resident index allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
    defer state.deinit(a);
    const coords: ChunkCoords = .{ 0, 0, 1 };
    const id = test_layout.encodeChunkCoords(coords);
    {
        var context: ReadContext = .{ .state = &state, .allocator = a };
        defer context.deinit();
        try std.testing.expectEqual(rules.BlockType.stone, context.reader().get(.{ 10, 10, 40 }).?);
    }
    const generated = state.generated_chunks.peek(id).?.content.blocks;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, state.ensureResident(a, coords));
    try std.testing.expectEqual(@as(usize, 0), state.modified_chunks.count());
    try std.testing.expectEqual(generated, state.generated_chunks.peek(id).?.content.blocks);
    try std.testing.expectEqual(@as(u64, 1), state.generated_chunk_count);
}

fn testReadContextCacheIndexOom(comptime reserve_fallback: bool) !void {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    const data_bytes = @sizeOf(@import("world_chunk_data.zig").WorldChunkData);
    {
        var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
        defer state.deinit(a);
        const coords: ChunkCoords = .{ 0, 0, 1 };
        const id = test_layout.encodeChunkCoords(coords);
        const retained_id = test_layout.encodeChunkCoords(.{ 1, 0, 1 });
        const column = ColumnGenerator.init(&state.generator, .{ 1, 0 });
        {
            const chunk = try column.tryGenerateChunk(a, 1);
            errdefer chunk.deinit(a);
            try std.testing.expect(try state.generated_chunks.insert(a, retained_id, chunk));
        }
        const retained_data = state.generated_chunks.peek(retained_id).?.content.blocks;
        const capacity = state.generated_chunks.entries.capacity();
        state.generated_chunks.max_entries = capacity + 1;
        // Make the next insertion grow the shared index while retaining a real
        // block allocation whose ownership must survive that failed growth.
        for (1..capacity) |offset| {
            try std.testing.expect(try state.generated_chunks.insert(a, retained_id + @as(ChunkId, @intCast(offset)), WorldChunk.initEmpty()));
        }
        const retained_bytes = failing.allocated_bytes - failing.freed_bytes;
        const retained_allocations = failing.allocations - failing.deallocations;
        {
            var context: ReadContext = .{ .state = &state, .allocator = a };
            defer context.deinit();
            // A persistent allocator failure can still use an already reserved
            // operation-local slot after optional shared-cache insertion fails.
            if (reserve_fallback) try context.chunks.ensureUnusedCapacity(a, 1);
            const allocations = failing.allocations;
            const deallocations = failing.deallocations;
            const allocated_bytes = failing.allocated_bytes;
            const freed_bytes = failing.freed_bytes;
            // Flat stone materializes in one allocation. Fail every allocation
            // after it, and reject in-place growth so the cache cannot escape OOM.
            failing.fail_index = failing.alloc_index + 1;
            failing.resize_fail_index = failing.resize_index;
            const result = context.reader().get(.{ 10, 10, 40 });
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(allocations + 1, failing.allocations);
            try std.testing.expectEqual(allocated_bytes + data_bytes, failing.allocated_bytes);
            try std.testing.expectEqual(@as(u64, 1), state.generated_chunk_count);
            if (reserve_fallback) {
                try std.testing.expectEqual(rules.BlockType.stone, result.?);
                try std.testing.expect(context.failure == null);
                try std.testing.expectEqual(@as(usize, 1), context.chunks.count());
                const fallback_data = context.chunks.get(id).?.content.blocks;
                for (0..3) |_| {
                    try std.testing.expectEqual(rules.BlockType.stone, context.reader().get(.{ 10, 10, 40 }).?);
                    try std.testing.expectEqual(fallback_data, context.chunks.get(id).?.content.blocks);
                }
                try std.testing.expectEqual(@as(u64, 1), state.generated_chunk_count);
                try std.testing.expectEqual(allocations + 1, failing.allocations);
                try std.testing.expectEqual(deallocations, failing.deallocations);
                try std.testing.expectEqual(freed_bytes, failing.freed_bytes);
            } else {
                try std.testing.expect(result == null);
                try std.testing.expectEqual(error.OutOfMemory, context.failure.?);
                try std.testing.expectEqual(@as(usize, 0), context.chunks.count());
                try std.testing.expectEqual(deallocations + 1, failing.deallocations);
                try std.testing.expectEqual(freed_bytes + data_bytes, failing.freed_bytes);
            }
            try std.testing.expect(state.generated_chunks.peek(id) == null);
            try std.testing.expectEqual(capacity, state.generated_chunks.count());
            try std.testing.expectEqual(capacity, state.generated_chunks.entries.capacity());
            try std.testing.expectEqual(@as(u64, 0), state.generated_chunks.evictions);
            try std.testing.expectEqual(@as(usize, 0), state.generated_chunks.eviction_cursor);
            try std.testing.expectEqual(data_bytes, state.generated_chunks.blockBytes());
            try std.testing.expectEqual(retained_data, state.generated_chunks.peek(retained_id).?.content.blocks);
            try std.testing.expectEqual(rules.BlockType.stone, state.generated_chunks.peek(retained_id).?.content.getBlock(.{ 10, 10, 8 }));
            for (1..capacity) |offset| {
                try std.testing.expect(state.generated_chunks.peek(retained_id + @as(ChunkId, @intCast(offset))).?.content == .empty);
            }
        }
        // Context teardown releases the fallback map and block exactly once;
        // the shared cache still owns all of its original allocations.
        try std.testing.expectEqual(retained_bytes, failing.allocated_bytes - failing.freed_bytes);
        try std.testing.expectEqual(retained_allocations, failing.allocations - failing.deallocations);
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
}

test "read context retains generated data locally when shared cache index growth fails" {
    try testReadContextCacheIndexOom(true);
}

test "read context frees generated data when shared and local cache indices cannot grow" {
    try testReadContextCacheIndexOom(false);
}

test "cold blueprint support reuses generated chunks across operations with bounded eviction" {
    try @import("blueprint_cold_support_tests.zig").run(struct {
        pub const State = WorkerState;

        pub fn init(allocator: std.mem.Allocator, layout: *const WorldLayout, generator: WorldGenerator) !State {
            return .{ .layout = layout, .generator = try generator.prepare(allocator, layout) };
        }

        pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
            state.deinit(allocator);
        }

        pub fn fulfill(state: *State, allocator: std.mem.Allocator, operation: BlockOperation) !WorkerState.BlueprintCommit {
            return state.tryFulfillBlueprint(allocator, operation);
        }
    });
}

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
            // A resource foundation keeps the route's exact 28-cell boundary
            // independent of the three-layer platform required by ordinary stone.
            Setup.put(&state, origin - rules.Cell{ 0, 0, 1 }, .limestone);
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
    const cover = state.applyOperation(allocator, .{ .block = above, .action = .{ .put = .snow } });
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

test "canonical deeprock rejects direct indirect and timer writes without partial effects" {
    const a = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
    defer state.deinit(a);
    const x: u32 = 10;
    const y: u32 = 10;
    const thickness = state.generator.deeprockThickness(x, y);
    const protected = [3]u32{ x, y, thickness - 1 };
    const direct = state.applyOperation(a, .{ .block = protected, .action = .remove });
    defer direct.chunk.deinit(a);
    try std.testing.expectEqual(OperationStatus.constraint_violation, direct.status);
    try std.testing.expectEqual(rules.Reason.immutable_cell, direct.diagnostics.failure.?.reason);
    try std.testing.expectEqual(@as(u64, 0), direct.chunk.chunk_revision);

    // Even corrupted resident contents cannot grant permission at a canonical
    // floor coordinate. Include a legal upper timer to prove atomic rejection.
    const data = try a.create(@import("world_chunk_data.zig").WorldChunkData);
    data.* = @import("world_chunk_data.zig").WorldChunkData.initEmpty();
    const protected_local = world_module.splitBlockCoords(protected)[1];
    data.blocks[protected_local[2]][y][x] = .grass;
    data.blocks[8][5][5] = .dirt;
    var source = WorldChunk.initBlocks(data);
    try source.metadata.timed.trySchedule(a, .{ .block = transformations.index(protected_local), .kind = .grow_grass, .due_tick = 1 });
    try source.metadata.timed.trySchedule(a, .{ .block = transformations.index(.{ 5, 5, 8 }), .kind = .compact_dirt, .due_tick = 1 });
    const id = test_layout.encodeChunkId(0, 0, 0);
    try state.modified_chunks.put(a, id, source);
    const indirect = state.applyOperation(a, .{ .block = .{ x, y, thickness }, .action = .{ .put = .snow } });
    defer indirect.chunk.deinit(a);
    try std.testing.expectEqual(OperationStatus.constraint_violation, indirect.status);
    try std.testing.expectEqual(rules.Reason.immutable_cell, indirect.diagnostics.failure.?.reason);
    try std.testing.expectEqual(rules.BlockType.none, data.blocks[thickness][y][x]);
    try std.testing.expectEqual(rules.BlockType.grass, data.blocks[protected_local[2]][y][x]);
    state.tick = transformations.transformation_delay * 2;
    try std.testing.expect(!state.transformChunk(a, .{ 0, 0, 0 }));
    const unchanged = state.modified_chunks.get(id).?;
    try std.testing.expectEqual(rules.BlockType.dirt, unchanged.content.getBlock(.{ 5, 5, 8 }));
    try std.testing.expectEqual(@as(usize, 2), unchanged.metadata.timed.events.items.len);
    try std.testing.expectEqual(@as(u64, 0), unchanged.chunk_revision);
    try std.testing.expectEqual(@as(u64, 0), unchanged.cell_changes.sequence);
}

test "sand and clay never acquire soil timers from exposure or covering" {
    const a = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
    defer state.deinit(a);
    const coords: ChunkCoords = .{ 0, 0, 2 };
    const data = try a.create(@import("world_chunk_data.zig").WorldChunkData);
    data.* = @import("world_chunk_data.zig").WorldChunkData.initEmpty();
    data.blocks[3][8][8] = .sand;
    data.blocks[4][8][8] = .snow;
    data.blocks[3][8][12] = .clay;
    try state.modified_chunks.put(a, test_layout.encodeChunkCoords(coords), WorldChunk.initBlocks(data));
    for ([_]u32{ 8, 12 }) |x| {
        const block = [3]u32{ x, 8, 2 * CHUNK_SIZE + 4 };
        if (x == 12) {
            const placed = state.applyOperation(a, .{ .block = block, .action = .{ .put = .snow } });
            defer placed.chunk.deinit(a);
            try std.testing.expectEqual(OperationStatus.success, placed.status);
        }
        const removed = state.applyOperation(a, .{ .block = block, .action = .remove });
        defer removed.chunk.deinit(a);
        try std.testing.expectEqual(OperationStatus.success, removed.status);
    }
    try std.testing.expectEqual(@as(usize, 0), state.modified_chunks.get(test_layout.encodeChunkCoords(coords)).?.metadata.timed.events.items.len);
    try std.testing.expectEqual(rules.BlockType.sand, data.blocks[3][8][8]);
    try std.testing.expectEqual(rules.BlockType.clay, data.blocks[3][8][12]);
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
    const put = client.submitOperation(.{ .block = block, .action = .{ .put = .snow } });
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
    try std.testing.expectEqual(.snow, responses.items[0].data.blocks.chunk.content.getBlock(.{ 1, 2, 31 }));
    try std.testing.expectEqual(.snow, responses.items[1].data.blocks.chunk.content.getBlock(.{ 1, 2, 31 }));
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
    const id = origin.submitOperation(.{ .block = block, .action = .{ .put = .snow } });
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
    try std.testing.expectEqual(.snow, observed.items[1].data.blocks.chunk.content.getBlock(.{ 0, 0, 0 }));
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
    _ = npc.submitOperation(.{ .block = block, .action = .{ .put = .snow } });
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
    _ = client.submitOperation(.{ .block = block, .action = .{ .put = .snow } });
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
    _ = client.submitOperation(.{ .block = .{ 0, 0, 4 }, .action = .remove });
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
    _ = client.submitOperation(.{ .block = .{ 0, 0, 4 }, .action = .remove });
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

test "generated boundary masks need no full chunk clone and survive cache index OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
    defer state.deinit(a);
    const coords: ChunkCoords = .{ 0, 0, 1 };
    const id = test_layout.encodeChunkCoords(coords);
    {
        var context: ReadContext = .{ .state = &state, .allocator = a };
        defer context.deinit();
        try std.testing.expectEqual(rules.BlockType.stone, context.reader().get(.{ 10, 10, 40 }).?);
    }
    const cached = state.generated_chunks.peek(id).?;
    const blocks = cached.content.blocks;
    const expected = cached.boundaries;
    const bytes = failing.allocated_bytes;
    const generations = state.generated_chunk_count;
    // Both a full-block clone and the optional boundary-index insertion would
    // fail. The masks already exist and must remain usable without either.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectEqualDeep(expected, try state.tryBoundariesAt(a, coords));
    try std.testing.expectEqual(bytes, failing.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), state.boundary_cache.count());
    try std.testing.expectEqual(blocks, state.generated_chunks.peek(id).?.content.blocks);
    try std.testing.expectEqual(generations, state.generated_chunk_count);
    try std.testing.expectEqual(@as(usize, 0), state.modified_chunks.count());
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expectEqualDeep(expected, try state.tryBoundariesAt(a, coords));
    try std.testing.expectEqualDeep(expected, state.boundary_cache.get(id).?);
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
    const covering = [3]u32{ 10, 10, surface + 1 };
    const covering_coords, const covering_local = world_module.splitBlockCoords(covering);
    var natural = state.loadAt(allocator, covering_coords);
    try std.testing.expectEqual(OperationStatus.success, try natural.tryApply(allocator, covering_local, .{ .put = .sand }));
    try state.modified_chunks.put(allocator, test_layout.encodeChunkCoords(covering_coords), natural);
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

test "standing-space polling returns only the latest success or error and preserves terrain replies" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    const barrier = try service.createClient();
    // An empty endpoint must return immediately, even with no search underway.
    try std.testing.expectEqual(null, client.pollStandingSpace(1));
    const token = client.requestChunks(.{ 0, 0 }, 0, 1);
    const old_id = client.requestStandingSpace(testSpaceQuery(.{ -21.5, -21.5 }));
    const latest_id = client.requestStandingSpace(testSpaceQuery(.{ 10.5, 10.5 }));
    // A separate endpoint establishes that both earlier query replies are ready
    // without consuming either of this endpoint's reply channels.
    _ = try barrier.findStandingSpace(testSpaceQuery(.{ 0.5, 0.5 }));
    const latest = client.pollStandingSpace(latest_id).?;
    try std.testing.expectEqual(latest_id, latest.request_id);
    try std.testing.expectEqual(standing_space.Position{ 10.5, 10.5, -16 }, try latest.result);
    try std.testing.expectEqual(null, client.pollStandingSpace(old_id));
    try std.testing.expectEqual(null, client.pollStandingSpace(latest_id));

    var invalid = testSpaceQuery(.{ 0.5, 0.5 });
    invalid.support_size = .{ 3, 3 };
    const failed_id = client.requestStandingSpace(invalid);
    _ = try barrier.findStandingSpace(testSpaceQuery(.{ 0.5, 0.5 }));
    const failed = client.pollStandingSpace(failed_id).?;
    try std.testing.expectEqual(failed_id, failed.request_id);
    try std.testing.expectError(error.InvalidSearch, failed.result);
    try std.testing.expectEqual(null, client.pollStandingSpace(failed_id));

    var responses: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&responses);
    try std.testing.expect(try client.waitResponses(&responses));
    try std.testing.expectEqual(1, responses.items.len);
    try std.testing.expectEqual(token, responses.items[0].subscription_id);
    try std.testing.expectEqual(.blocks, std.meta.activeTag(responses.items[0].data));
    try std.testing.expectEqual(1, client.subscriptions.count());
    try std.testing.expectEqual(2, service.clients.items.len);
}

test "standing-space polling discards a stale reply while the latest search is pending" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &layout, .flat);
    defer service.destroy();
    const client = try service.createClient();
    client.space_responses.push(service.io, service.allocator, .{ .request_id = 1, .result = .{ 0.5, 0.5, -16 } });
    try std.testing.expectEqual(null, client.pollStandingSpace(2));
    try std.testing.expectEqual(null, client.pollStandingSpace(1));
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
        const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ 4, 4, 4 }, .generator_id = format.generator_id, .seed = 0, .settings = &format.flat_settings });
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

test "generated cache cannot bypass pending or failed persisted reads or a reloaded edit" {
    const a = std.testing.allocator;
    const f = try savedDependencyFixture();
    defer f.deinit();
    var service: WorldDataService = .{
        .layout = &f.layout,
        .io = std.testing.io,
        .allocator = a,
        .worker = undefined,
        .worker_state = .{ .layout = &f.layout, .generator = try WorldGenerator.prepare(.flat, a, &f.layout) },
        .catalog = try f.store.snapshotCatalog(),
    };
    defer service.catalog.?.deinit();
    defer service.worker_state.deinit(a);
    defer service.read_pending.deinit(a);
    defer service.read_failed.deinit(a);
    defer service.base_revisions.deinit(a);
    defer service.wal_revisions.deinit(a);
    const block: [3]u32 = .{ 10, 10, 48 };
    const coords, _ = world_module.splitBlockCoords(block);
    const id = f.layout.encodeChunkCoords(coords);
    // Deliberately retain generated air before exposing an edited saved catalog.
    {
        var context: ReadContext = .{ .state = &service.worker_state, .allocator = a };
        defer context.deinit();
        try std.testing.expectEqual(rules.BlockType.none, context.reader().get(.{ 10, 10, 48 }).?);
    }
    const hits = service.worker_state.generated_chunks.hits;
    try std.testing.expectEqual(@as(usize, 1), service.worker_state.generated_chunks.count());
    try std.testing.expectEqual(@as(usize, 0), service.worker_state.modified_chunks.count());
    _ = try service.worker_state.tryBoundariesAt(a, coords);
    const revision = service.catalog.?.revision(id).?;
    try service.read_pending.put(a, id, revision);
    service.worker_state.persistence_service = &service;
    {
        var context: ReadContext = .{ .state = &service.worker_state, .allocator = a };
        defer context.deinit();
        try std.testing.expect(context.reader().get(.{ 10, 10, 48 }) == null);
        try std.testing.expect(context.failure == null);
    }
    try std.testing.expect(service.read_discovered);
    try std.testing.expectError(error.DependencyPending, service.worker_state.ensureResident(a, coords));
    try std.testing.expectError(error.DependencyPending, service.worker_state.tryLoadAt(a, coords));
    try std.testing.expectError(error.DependencyPending, service.worker_state.tryBoundariesAt(a, coords));
    try service.read_failed.put(a, id, error.ChecksumMismatch);
    {
        var context: ReadContext = .{ .state = &service.worker_state, .allocator = a };
        defer context.deinit();
        try std.testing.expect(context.reader().get(.{ 10, 10, 48 }) == null);
    }
    try std.testing.expectEqual(error.ChecksumMismatch, service.blocked_dependency_error.?);
    try std.testing.expectError(error.DependencyPending, service.worker_state.tryBoundariesAt(a, coords));
    try std.testing.expectEqual(hits, service.worker_state.generated_chunks.hits);
    try std.testing.expectEqual(@as(u64, 1), service.worker_state.generated_chunk_count);
    var read = (try service.catalog.?.prepareRead(id)).?;
    defer read.deinit();
    const loaded = try service.readPersisted(&read);
    service.installLoaded(id, revision, loaded) catch |err| {
        loaded.deinit(a);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 0), service.worker_state.generated_chunks.count());
    {
        var context: ReadContext = .{ .state = &service.worker_state, .allocator = a };
        defer context.deinit();
        try std.testing.expectEqual(rules.BlockType.snow, context.reader().get(.{ 10, 10, 48 }).?);
    }
    const removed = service.worker_state.modified_chunks.fetchRemove(id).?.value;
    removed.deinit(a);
    {
        var context: ReadContext = .{ .state = &service.worker_state, .allocator = a };
        defer context.deinit();
        try std.testing.expect(context.reader().get(.{ 10, 10, 48 }) == null);
    }
    try std.testing.expectEqual(@as(u64, 1), service.worker_state.generated_chunk_count);
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

test "forbidden resource mining and no-item foliage clearing preserve inventory and saved edits" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    f.service.destroy();
    const a = std.testing.allocator;
    var blocks = [_]u8{0} ** format.cell_count;
    const leaf = [3]u32{ 1, 2, 40 };
    const snow = [3]u32{ 9, 2, 40 };
    const destination = [3]u32{ 10, 2, 40 };
    blocks[transformations.index(.{ 1, 2, 8 })] = @intFromEnum(rules.BlockType.leaves);
    blocks[transformations.index(.{ 9, 2, 8 })] = @intFromEnum(rules.BlockType.snow);
    const resources = [_]rules.BlockType{ .metal_ore, .limestone, .clay, .coal };
    for (resources, 0..) |resource, i| blocks[transformations.index(.{ @intCast(4 + i), 5, 8 })] = @intFromEnum(resource);
    const metadata = try format.encodeMetadata(a, .{});
    defer a.free(metadata);
    const id = f.layout.encodeChunkId(0, 0, 1);
    const record = try format.encodeChunk(a, f.store.world_uuid, .{ .id = id, .revision = 1, .is_unreachable = false, .blocks = &blocks, .metadata = metadata });
    defer a.free(record);
    const global = format.encodeGlobal(0);
    try f.store.beginSnapshot(1, &global, &.{}, 0, 1);
    try f.store.appendChunk(record);
    _ = try f.store.commitSnapshot();
    try f.store.compact();
    f.service = try WorldDataService.createPersistent(std.testing.io, a, &f.layout, .flat, &f.store, .{});
    var client = try f.service.createClient();
    client.publishCheckpoint(.{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    for (resources, 0..) |_, i| {
        const block = [3]u32{ @intCast(4 + i), 5, 40 };
        for ([_]bool{ false, true }) |player| {
            const result = try PersistenceFixture.operationResult(client, .{ .block = block, .action = .remove, .player = if (player) .{ .id = 1, .expected_sequence = 0 } else null });
            try std.testing.expectEqual(OperationStatus.constraint_violation, result.status);
            try std.testing.expectEqual(rules.Reason.mining_forbidden, result.failure.?.reason);
            try std.testing.expectEqual(@as(?rules.BlockType, null), result.mined_type);
        }
    }
    const acquired = try PersistenceFixture.operationResult(client, .{ .block = snow, .action = .remove, .player = .{ .id = 1, .expected_sequence = 0 } });
    try std.testing.expectEqual(OperationStatus.success, acquired.status);
    try std.testing.expectEqual(rules.BlockType.snow, acquired.player_inventory.?.material.?);
    const occupied = try PersistenceFixture.operationResult(client, .{ .block = leaf, .action = .remove, .player = .{ .id = 1, .expected_sequence = 0 } });
    try std.testing.expectEqual(OperationStatus.inventory_mismatch, occupied.status);
    try std.testing.expectEqual(rules.BlockType.snow, occupied.player_inventory.?.material.?);
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = destination, .action = .{ .put = .snow }, .player = .{ .id = 1, .expected_sequence = 0 } }));
    const cleared = try PersistenceFixture.operationResult(client, .{ .block = leaf, .action = .remove, .player = .{ .id = 1, .expected_sequence = 0 } });
    try std.testing.expectEqual(OperationStatus.success, cleared.status);
    try std.testing.expectEqual(@as(?rules.BlockType, null), cleared.mined_type);
    try std.testing.expectEqual(@as(?rules.BlockType, null), cleared.player_inventory.?.material);
    try std.testing.expectEqual(persistence.Phase.complete, (try f.waitSave(f.service.requestSave(true))).phase);
    f.service.destroy();
    f.store.deinit();
    f.store = try storage.Store.open(a, f.path, .{});
    f.service = try WorldDataService.createPersistent(std.testing.io, a, &f.layout, .flat, &f.store, .{});
    try std.testing.expectEqual(@as(?u8, null), f.service.restoredPlayer(1).?.inventory);
    client = try f.service.createClient();
    const gone = try PersistenceFixture.operationResult(client, .{ .block = leaf, .action = .remove });
    try std.testing.expectEqual(OperationStatus.already_removed, gone.status);
    for (resources, 0..) |resource, i| {
        const result = try PersistenceFixture.operationResult(client, .{ .block = .{ @intCast(4 + i), 5, 40 }, .action = .remove });
        try std.testing.expectEqual(OperationStatus.constraint_violation, result.status);
        try std.testing.expectEqual(rules.Reason.mining_forbidden, result.failure.?.reason);
        try std.testing.expectEqual(@as(?rules.BlockType, null), resource.minedType());
    }
}

test "player extraction rejects a replacement even when the replacement has the same material" {
    const service = try WorldDataService.create(std.testing.io, std.testing.allocator, &test_layout, .flat);
    defer service.destroy();
    const player = try service.createClient();
    const npc = try service.createClient();
    player.publishCheckpoint(.{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    const block = [3]u32{ 10, 10, test_layout.size_in_blocks[2] - 1 };
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = block, .action = .{ .put = .snow } }));
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = block, .action = .remove }));
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = block, .action = .{ .put = .snow } }));
    const result = try PersistenceFixture.operationResult(player, .{ .block = block, .action = .remove, .player = .{ .id = 1, .expected_sequence = 1 } });
    try std.testing.expectEqual(OperationStatus.target_changed, result.status);
    try std.testing.expectEqual(null, result.player_inventory.?.material);
    const retry = try PersistenceFixture.operationResult(player, .{ .block = block, .action = .remove, .player = .{ .id = 1, .expected_sequence = 3 } });
    try std.testing.expectEqual(OperationStatus.success, retry.status);
    try std.testing.expectEqual(rules.BlockType.snow, retry.player_inventory.?.material.?);
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
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = source, .action = .{ .put = .snow } }));
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = other, .action = .{ .put = .snow } }));
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(npc, .{ .block = other, .action = .remove }));
    const result = try PersistenceFixture.operationResult(player, .{ .block = source, .action = .remove, .player = .{ .id = 1, .expected_sequence = 1 } });
    try std.testing.expectEqual(OperationStatus.success, result.status);
    try std.testing.expectEqual(rules.BlockType.snow, result.player_inventory.?.material.?);
}

test "restored chunks preserve exact canonical floor and reject protected metadata" {
    const a = std.testing.allocator;
    var prepared = try WorldGenerator.prepare(.flat, a, &test_layout);
    defer prepared.deinit(a);
    const column = ColumnGenerator.init(&prepared, .{ 0, 0 });
    const original = try column.tryGenerateChunk(a, 0);
    defer original.deinit(a);
    var blocks: [format.cell_count]u8 = undefined;
    @memcpy(&blocks, std.mem.asBytes(&original.content.blocks.blocks));
    const metadata: format.Metadata = .{ .roads = &.{}, .construction = &.{}, .timers = &.{} };
    try validateRestoredFloor(&prepared, .{ 0, 0, 0 }, &blocks, metadata);
    // Valid edits above the mask survive; corrupt records are never repaired.
    blocks[4 * 32 * 32] = @intFromEnum(@import("engine").voxel_chunk.BlockType.none);
    try validateRestoredFloor(&prepared, .{ 0, 0, 0 }, &blocks, metadata);
    const original_floor = blocks[0];
    blocks[0] = @intFromEnum(@import("engine").voxel_chunk.BlockType.stone);
    try std.testing.expectError(error.InvalidWorldData, validateRestoredFloor(&prepared, .{ 0, 0, 0 }, &blocks, metadata));
    blocks[0] = original_floor;
    blocks[3 * 32 * 32] = original_floor;
    try std.testing.expectError(error.InvalidWorldData, validateRestoredFloor(&prepared, .{ 0, 0, 0 }, &blocks, metadata));
    @memcpy(&blocks, std.mem.asBytes(&original.content.blocks.blocks));
    var construction = [_]u16{0};
    var invalid_metadata = metadata;
    invalid_metadata.construction = &construction;
    try std.testing.expectError(error.InvalidWorldData, validateRestoredFloor(&prepared, .{ 0, 0, 0 }, &blocks, invalid_metadata));
    try std.testing.expectError(error.InvalidWorldData, validateRestoredFloor(&prepared, .{ 0, 0, 1 }, &blocks, metadata));
}

test "persistent runtime identity mismatches fail before generator preparation" {
    const f = try PersistenceFixture.init(.{});
    defer f.deinit();
    try std.testing.expectError(error.InvalidDescriptor, WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .{ .flat_seeded = 1 }, &f.store, .{}));
    try std.testing.expectError(error.UnsupportedGenerator, WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &f.layout, .{ .terrain = .{ .seed = 0 } }, &f.store, .{}));
    const wrong_layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 4, 4 } });
    try std.testing.expectError(error.InvalidDescriptor, WorldDataService.createPersistent(std.testing.io, std.testing.allocator, &wrong_layout, .flat, &f.store, .{}));
}

const FloorRestoreSource = enum { base, wal };

fn exerciseLazyFloorRestore(source: FloorRestoreSource, corrupt_floor: bool) !void {
    const a = std.testing.allocator;
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/world-floor-restore-{x}", .{uuid}, 0);
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const dimensions: [3]u32 = .{ @intCast(layout.size_in_chunks[0]), @intCast(layout.size_in_chunks[1]), @intCast(layout.size_in_chunks[2]) };
    const seed: u64 = 0x9182736455aabbcc;
    const generator = WorldGenerator{ .flat_seeded = seed };
    var prepared = try generator.prepare(a, &layout);
    defer prepared.deinit(a);
    const column = ColumnGenerator.init(&prepared, .{ 0, 0 });
    const original = try column.tryGenerateChunk(a, 0);
    defer original.deinit(a);
    var blocks: [format.cell_count]u8 = undefined;
    @memcpy(&blocks, std.mem.asBytes(&original.content.blocks.blocks));
    // This edit is deliberately outside every possible 1--3-block floor mask.
    const edited_cell = (8 * CHUNK_SIZE + 12) * CHUNK_SIZE + 10;
    blocks[edited_cell] = @intFromEnum(rules.BlockType.none);
    if (corrupt_floor) blocks[0] = @intFromEnum(rules.BlockType.stone);
    const id = layout.encodeChunkCoords(.{ 0, 0, 0 });
    const encoded = try format.encodeChunk(a, uuid, .{ .id = id, .revision = 7, .is_unreachable = false, .blocks = &blocks, .metadata = &.{} });
    defer a.free(encoded);
    // Both variants are valid checksummed storage records. Only the prepared
    // generator has enough identity information to recognize the floor conflict.
    try format.validateChunkRecord(uuid, encoded, dimensions);
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = dimensions, .generator_id = format.generator_id, .seed = seed, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(44);
    var store = try storage.Store.create(a, path, .{
        .world_uuid = uuid,
        .descriptor = descriptor,
        .global = &global,
        .players = &.{},
        .player_count = 0,
        .chunks = if (source == .base) &.{encoded} else &.{},
    }, .{});
    var store_open = true;
    defer if (store_open) store.deinit();
    if (source == .wal) {
        try store.beginSnapshot(1, &global, &.{}, 0, 1);
        try store.appendChunk(encoded);
        _ = try store.commitSnapshot();
    }
    store.deinit();
    store_open = false;
    // Existing recovery installs a committed WAL generation into the base. The
    // exact chunk bytes must survive that path before lazy service validation.
    store = try storage.Store.open(a, path, .{});
    store_open = true;
    const restored_record = (try store.readChunk(a, id)).?;
    defer a.free(restored_record);
    try std.testing.expectEqualSlices(u8, encoded, restored_record);
    const file_size = try store.base.size();
    const before = try a.alloc(u8, @intCast(file_size));
    defer a.free(before);
    try store.base.read(before, 0);
    const service = try WorldDataService.createPersistent(std.testing.io, a, &layout, generator, &store, .{});
    defer service.destroy();
    try std.testing.expect(service.persistenceStatus().phase != .failed);
    const client = try service.createClient();
    const token = client.requestChunks(.{ 0, 0 }, 0, 1);
    var replies: std.ArrayList(ChunkResponse) = .empty;
    defer deinitResponses(&replies);
    if (corrupt_floor) {
        try waitAnyDependencyFailure(service);
        const status = service.persistenceStatus();
        try std.testing.expectEqualStrings("InvalidWorldData", status.error_name.?);
        client.takeResponses(&replies);
        // Failure must not publish a regenerated substitute or any partial chunk.
        for (replies.items) |reply| try std.testing.expect(reply.data != .blocks or !std.meta.eql(reply.coords, ChunkCoords{ 0, 0, 0 }));
    } else {
        try waitForResponses(client, &replies, 1);
        var found = false;
        for (replies.items) |reply| {
            if (reply.subscription_id != token or reply.data != .blocks) continue;
            const chunk = reply.data.blocks.chunk;
            try std.testing.expectEqual(@as(u64, 7), chunk.chunk_revision);
            const data = chunk.content.toData();
            try std.testing.expectEqualSlices(u8, &blocks, std.mem.asBytes(&data.blocks));
            try std.testing.expectEqual(rules.BlockType.none, data.blocks[8][12][10]);
            found = true;
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(file_size, try store.base.size());
    const after = try a.alloc(u8, @intCast(file_size));
    defer a.free(after);
    try store.base.read(after, 0);
    try std.testing.expectEqualSlices(u8, before, after);
    const after_record = (try store.readChunk(a, id)).?;
    defer a.free(after_record);
    try std.testing.expectEqualSlices(u8, encoded, after_record);
}

test "lazy restored base and WAL chunks retain upper edits above the seeded floor" {
    for ([_]FloorRestoreSource{ .base, .wal }) |source| try exerciseLazyFloorRestore(source, false);
}

test "lazy restored base and WAL floor conflicts fail without rewriting or regeneration" {
    for ([_]FloorRestoreSource{ .base, .wal }) |source| try exerciseLazyFloorRestore(source, true);
}

test "natural profile service saves mined starter sand and bottom edits across a fresh reopen" {
    const a = std.testing.allocator;
    const Test = struct {
        fn load(client: *Client, coords: ChunkCoords) !WorldChunk {
            const token = try client.tryRequestChunksInMode(.{ coords[0], coords[1] }, coords[2], coords[2] + 1, .blocks);
            var replies: std.ArrayList(ChunkResponse) = .empty;
            defer deinitResponses(&replies);
            const deadline = persistence.now(std.testing.io) + 10 * std.time.ns_per_s;
            while (persistence.now(std.testing.io) < deadline) {
                client.takeResponses(&replies);
                for (replies.items) |reply| if (reply.subscription_id == token and reply.data == .blocks)
                    return reply.data.blocks.chunk.tryClone(std.testing.allocator);
                for (replies.items) |reply| reply.deinit(std.testing.allocator);
                replies.clearRetainingCapacity();
                try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            }
            return error.TestLoadTimeout;
        }

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
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/natural-service-reopen-{x}", .{uuid}, 0);
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    const layout = try WorldLayout.init(@import("consts.zig").WORLD_SETTINGS);
    const dimensions: [3]u32 = .{ @intCast(layout.size_in_chunks[0]), @intCast(layout.size_in_chunks[1]), @intCast(layout.size_in_chunks[2]) };
    const generator: WorldGenerator = .{ .natural = .{ .seed = 12345 } };
    const settings = format.encodeNaturalSettings(.{});
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = dimensions, .generator_id = format.generator_id, .seed = 12345, .settings = &settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(0);
    var store = try storage.Store.create(a, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
    var store_open = true;
    defer if (store_open) store.deinit();
    var service: ?*WorldDataService = try WorldDataService.createPersistent(std.testing.io, a, &layout, generator, &store, .{});
    defer if (service) |running| running.destroy();
    var client = try service.?.createClient();
    const prepared = service.?.preparedGenerator();
    const fingerprint = prepared.kind.natural.fingerprint();
    const first_start = prepared.firstStart().?;
    var starter_sand: ?[3]u32 = null;
    for (prepared.kind.natural.deposits.items[0..prepared.kind.natural.deposits.count]) |deposit| {
        if (deposit.size_class == .starter and deposit.resource == .sand) starter_sand = deposit.center;
    }
    const sand = starter_sand.?;
    const bottom = [3]u32{ sand[0], sand[1], 4 };
    try std.testing.expectEqual(rules.BlockType.sand, prepared.referenceMaterialAt(sand[0], sand[1], sand[2]));
    try std.testing.expectEqual(rules.BlockType.stone, prepared.referenceMaterialAt(bottom[0], bottom[1], bottom[2]));
    const sand_coords, const sand_local = world_module.splitBlockCoords(sand);
    const bottom_coords, const bottom_local = world_module.splitBlockCoords(bottom);
    var climate: @import("world_environment.zig").ClimateMap = undefined;
    prepared.fillClimateMap(.{ sand_coords[0], sand_coords[1] }, &climate);
    const feet: [3]f64 = .{
        @as(f64, @floatFromInt(first_start[0])) - @as(f64, @floatFromInt(layout.origin_chunk[0])) * CHUNK_SIZE + 0.5,
        @as(f64, @floatFromInt(first_start[1])) - @as(f64, @floatFromInt(layout.origin_chunk[1])) * CHUNK_SIZE + 0.5,
        @as(f64, @floatFromInt(first_start[2])) - @as(f64, @floatFromInt(layout.origin_chunk[2])) * CHUNK_SIZE,
    };
    client.publishCheckpoint(.{ .id = 7, .feet = feet, .yaw = 0, .pitch = 0 });
    const mined = try PersistenceFixture.operationResult(client, .{ .block = sand, .action = .remove, .player = .{ .id = 7, .expected_sequence = 0 } });
    try std.testing.expectEqual(OperationStatus.success, mined.status);
    try std.testing.expectEqual(rules.BlockType.sand, mined.mined_type.?);
    try std.testing.expectEqual(rules.BlockType.sand, mined.player_inventory.?.material.?);
    try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = bottom, .action = .remove }));
    const expected_sand = try Test.load(client, sand_coords);
    defer expected_sand.deinit(a);
    const expected_bottom = try Test.load(client, bottom_coords);
    defer expected_bottom.deinit(a);
    try std.testing.expectEqual(rules.BlockType.none, expected_sand.content.getBlock(sand_local));
    try std.testing.expectEqual(rules.BlockType.none, expected_bottom.content.getBlock(bottom_local));
    try Test.save(service.?);
    service.?.destroy();
    service = null;
    store.deinit();
    store_open = false;
    store = try storage.Store.open(a, path, .{});
    store_open = true;
    const reopened_descriptor = try format.decodeDescriptor(store.descriptor);
    const reopened_settings = try format.decodeGeneratorSettings(reopened_descriptor.settings);
    try std.testing.expect(reopened_settings == .natural);
    service = try WorldDataService.createPersistent(std.testing.io, a, &layout, .{ .natural = .{ .seed = reopened_descriptor.seed, .settings = reopened_settings.natural } }, &store, .{});
    client = try service.?.createClient();
    const reopened = service.?.preparedGenerator();
    try std.testing.expectEqualSlices(u8, &fingerprint, &reopened.kind.natural.fingerprint());
    try std.testing.expectEqualDeep(first_start, reopened.firstStart().?);
    var reopened_climate: @import("world_environment.zig").ClimateMap = undefined;
    reopened.fillClimateMap(.{ sand_coords[0], sand_coords[1] }, &reopened_climate);
    try std.testing.expectEqualDeep(climate, reopened_climate);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(rules.BlockType.sand)), service.?.restoredPlayer(7).?.inventory);
    for ([_]ChunkCoords{ sand_coords, bottom_coords }, [_]WorldChunk{ expected_sand, expected_bottom }) |coords, expected| {
        const actual = try Test.load(client, coords);
        defer actual.deinit(a);
        const expected_data = expected.content.toData();
        const actual_data = actual.content.toData();
        try std.testing.expectEqual(expected.chunk_revision, actual.chunk_revision);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected_data.blocks), std.mem.asBytes(&actual_data.blocks));
        try std.testing.expectEqualDeep(expected.metadata.timed.events.items, actual.metadata.timed.events.items);
        try std.testing.expectEqualDeep(expected.metadata.constructed.items, actual.metadata.constructed.items);
        if (coords[2] == 0) for (0..CHUNK_SIZE) |y| for (0..CHUNK_SIZE) |x| {
            const thickness = reopened.deeprockThickness(@as(i64, coords[0]) * CHUNK_SIZE + @as(i64, @intCast(x)), @as(u32, @intCast(coords[1])) * CHUNK_SIZE + @as(u32, @intCast(y)));
            for (0..CHUNK_SIZE) |z| try std.testing.expectEqual(z < thickness, actual_data.blocks[z][y][x] == .deeprock);
        };
    }
}

const BlueprintSaveFixture = struct {
    service: WorldDataService,
    client: Client,

    fn init(self: *@This()) !void {
        return self.initWithAllocator(std.testing.allocator);
    }

    fn initWithAllocator(self: *@This(), a: std.mem.Allocator) !void {
        self.service = .{ .layout = &test_layout, .io = std.testing.io, .allocator = a, .worker = undefined, .worker_state = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) } };
        self.client = .{ .service = &self.service };
        errdefer self.deinit();
        try self.service.clients.append(a, &self.client);
        try self.service.players.put(a, 1, .{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    }

    fn deinit(self: *@This()) void {
        const a = self.service.allocator;
        if (self.service.job) |job| {
            job.cancel();
            job.deinit();
        }
        self.service.discardPendingBlueprintSaves();
        self.service.pending.deinit(a);
        self.client.pending.deinit(a);
        for (self.client.responses.items.items) |*package| package.deinit(a);
        self.client.responses.deinit(a);
        self.client.blueprint_results.deinit(a);
        self.client.blueprint_save_keys.deinit(a);
        self.service.clients.deinit(a);
        self.service.players.deinit(a);
        self.service.blueprint_journal.deinit(a);
        self.service.completion_ring.deinit(a);
        self.service.source_holds.deinit(a);
        self.service.wal_revisions.deinit(a);
        self.service.base_revisions.deinit(a);
        self.service.requests.deinit(a);
        if (self.service.catalog) |*catalog| catalog.deinit();
        self.service.worker_state.deinit(a);
    }

    fn request(self: *@This(), id: u64) !@FieldType(Request, "blueprint_save") {
        const a = self.service.allocator;
        const result = try blueprint.compile(a, .{ .size = .{ 1, 1, 1 }, .cells = &.{.planks} }, .{ .horizontal_limit = blueprint.horizontalLimit(&test_layout) });
        if (result != .valid) return error.InvalidTestBlueprint;
        var candidate = result.valid;
        errdefer candidate.deinit(a);
        return .{ .client = &self.client, .owner = 1, .request_id = id, .name = try a.dupe(u8, "Save fixture"), .candidate = candidate };
    }
};

test "Apply captures cavity index sources and retains every narrowed dependency version gate" {
    const a = std.testing.allocator;
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const service = &fixture.service;
    defer {
        if (service.blueprint_task) |task| {
            service.blueprint_task = null;
            task.release();
            a.destroy(task);
        }
        service.blueprint_retired.deinit(a);
    }
    const state = &service.worker_state.blueprints;
    const cells = try a.alloc(rules.BlockType, 65);
    @memset(cells, .none);
    cells[0] = .planks;
    cells[cells.len - 1] = .planks;
    try state.insertDefinition(a, .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Sparse box"), .definition = .{ .size = .{ 65, 1, 1 }, .cells = cells, .target_count = 2 } });
    try state.insertDefinition(a, .{ .id = 2, .owner = 1, .name = try a.dupe(u8, "Neighbor"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{.planks}), .target_count = 1 } });
    const neighbor: blueprint_runtime.Cell = .{ 50, 30, 64 };
    try state.insertInstance(a, &test_layout, try state.prepareInstance(a, &test_layout, 99, 2, 1, neighbor, 0));
    try service.tryBeginBlueprintApplication(.{ .client = &fixture.client, .request_id = 1, .owner = 1, .definition_id = 1, .origin = .{ 30, 31, 64 }, .rotation = 0 });
    const task = service.blueprint_task.?;
    // Both new targets sit exactly above a chunk boundary. Their platform
    // crosses Y=32 and reads three actual levels below Z=64.
    for (task.chunk_ids) |id| {
        const coords = test_layout.decodeChunkId(id);
        var chunk = WorldChunk.initEmpty();
        if (coords[2] == 1) {
            const data = try chunk.tryEnsureData(a);
            @memset(std.mem.asBytes(&data.blocks), @intFromEnum(rules.BlockType.stone));
        }
        chunk.chunk_revision = 1;
        try service.worker_state.modified_chunks.put(a, id, chunk);
        try service.copyBlueprintDependency(task, id);
    }
    try std.testing.expectEqual(@as(usize, 12), task.chunk_ids.len);
    try std.testing.expectEqual(task.chunk_ids.len, task.snapshot.chunks.count());
    for (task.instance.box_chunks) |id| try std.testing.expect(task.snapshot.chunks.contains(id));
    const cavity_id = test_layout.encodeChunkCoords(.{ 1, 0, 2 });
    const captured = task.snapshot.chunks.get(cavity_id).?.index;
    try std.testing.expectEqualSlices(u64, &.{99}, captured.instances.items);
    try std.testing.expectEqualSlices(blueprint_runtime.Cell, &.{neighbor}, captured.targets.items);
    try std.testing.expectEqualDeep(state.chunks.get(cavity_id).?.lookup.get(neighbor).?, captured.lookup.get(neighbor).?);
    try std.testing.expect(captured.targets.items.ptr != state.chunks.get(cavity_id).?.targets.items.ptr);
    task.result = try task.prepare();
    const result = try task.result.?;
    try std.testing.expect(result == .prepared);
    try std.testing.expectEqual(@as(usize, 54), result.prepared.foundation_reads);
    try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
    const publication = result.prepared.publication.chunks.get(cavity_id).?;
    try std.testing.expectEqualSlices(u64, &.{ 99, 100 }, publication.instances.items);
    try std.testing.expectEqualSlices(blueprint_runtime.Cell, &.{neighbor}, publication.targets.items);
    try std.testing.expectEqualDeep(captured.lookup.get(neighbor).?, publication.lookup.get(neighbor).?);
    // A changed support-only source and a changed cavity publication source
    // both invalidate preparation before any publication or journal mutation.
    for ([_]ChunkId{ test_layout.encodeChunkCoords(.{ 2, 1, 1 }), cavity_id }) |id| {
        service.worker_state.modified_chunks.getPtr(id).?.chunk_revision += 1;
        try std.testing.expectError(error.StalePreparation, service.commitBlueprintApplication(task));
        service.worker_state.modified_chunks.getPtr(id).?.chunk_revision -= 1;
        try std.testing.expectEqual(@as(u32, 1), state.instances.count());
        try std.testing.expectEqual(@as(usize, 0), service.blueprint_journal.items.len);
    }
    state.revision +%= 1;
    try std.testing.expectError(error.StalePreparation, service.commitBlueprintApplication(task));
    try std.testing.expectEqual(@as(u32, 1), state.instances.count());
}

test "blueprint admission replies retain reasons and cells after their task retires" {
    const a = std.testing.allocator;
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const service = &fixture.service;
    defer {
        if (service.blueprint_task) |task| {
            task.release();
            a.destroy(task);
        }
        for (service.blueprint_retired.items) |task| {
            if (task.future) |*future| future.await(service.io);
            if (!task.retired.load(.acquire)) task.release();
            a.destroy(task);
        }
        service.blueprint_retired.deinit(a);
    }
    service.saveBlueprint(try fixture.request(1));
    var replies: std.ArrayList(BlueprintResult) = .empty;
    defer replies.deinit(a);
    fixture.client.takeBlueprintResults(&replies);
    replies.clearRetainingCapacity();
    for (std.enums.values(blueprint_admission.RejectCode), 0..) |code, index| {
        const request_id: u64 = index + 2;
        const rejection: BlueprintRejection = .{
            .code = code,
            .cell = if (code == .budget_exceeded or code == .invalid_definition or code == .bounds) null else .{ 10, 11, 70 },
            .failure = if (code == .composition) .{
                .reason = .would_invalidate_structure,
                .cause = .horizontal_span,
                .subject = .{ 10, 11, 70 },
                .actual = 8,
                .limit = 6,
                .involved_count = 1,
                .involved = .{.{ 10, 11, 70 }} ++ @as([31]rules.Cell, @splat(@splat(0))),
            } else null,
        };
        try service.tryBeginBlueprintApplication(.{ .client = &fixture.client, .request_id = request_id, .owner = 1, .definition_id = 1, .origin = .{ 10, 10, 70 }, .rotation = 0 });
        const task = service.blueprint_task.?;
        task.result = .{ .rejected = rejection };
        service.finishBlueprintApplication(task);
        if (task.future) |*future| future.await(service.io);
        service.reapBlueprintRetirements();
        fixture.client.takeBlueprintResults(&replies);
        try std.testing.expectEqual(@as(usize, 1), replies.items.len);
        const reply = replies.items[0];
        try std.testing.expectEqual(request_id, reply.request_id);
        try std.testing.expectEqual(.apply, reply.kind);
        try std.testing.expectEqual(@as(@FieldType(BlueprintResult, "status"), switch (code) {
            .missing_data => .missing_data,
            .budget_exceeded => .resource_exhausted,
            else => .invalid,
        }), reply.status);
        try std.testing.expectEqualDeep(rejection, reply.rejection.?);
        try std.testing.expectEqual(request_id, fixture.client.resolved_request);
        try std.testing.expectEqual(@as(u32, 0), service.worker_state.blueprints.instances.count());
        replies.clearRetainingCapacity();
    }
    // These rejections happen before the detached worker can start.
    service.beginBlueprintApplication(.{ .client = &fixture.client, .request_id = 20, .owner = 1, .definition_id = 1, .origin = test_layout.size_in_blocks, .rotation = 0 });
    var instance = try service.worker_state.blueprints.prepareInstance(a, &test_layout, 1, 1, 1, .{ 10, 10, 70 }, 0);
    var owns_instance = true;
    defer if (owns_instance) instance.deinit(a);
    try service.worker_state.blueprints.insertInstance(a, &test_layout, instance);
    owns_instance = false;
    service.beginBlueprintApplication(.{ .client = &fixture.client, .request_id = 21, .owner = 1, .definition_id = 1, .origin = .{ 10, 10, 70 }, .rotation = 0 });
    fixture.client.takeBlueprintResults(&replies);
    try std.testing.expectEqual(@as(usize, 2), replies.items.len);
    try std.testing.expectEqual(.bounds, replies.items[0].rejection.?.code);
    try std.testing.expectEqual(.overlap, replies.items[1].rejection.?.code);
    try std.testing.expectEqual(null, service.blueprint_task);
}

test "blueprint Save keys return the original definition and separate automatic identities" {
    const a = std.testing.allocator;
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var first = try fixture.request(1);
    first.idempotency_key = 9;
    fixture.service.saveBlueprint(first);
    const revision = fixture.service.worker_state.blueprints.revision;
    const bytes = fixture.service.blueprint_library_bytes;
    var retry = try fixture.request(2);
    retry.idempotency_key = 9;
    fixture.service.saveBlueprint(retry);
    try std.testing.expectEqual(@as(u32, 1), fixture.service.worker_state.blueprints.definitions.count());
    try std.testing.expectEqual(@as(u32, 1), fixture.client.blueprint_save_keys.count());
    try std.testing.expectEqual(@as(usize, 1), fixture.client.pending.blueprint_changes.items.len);
    try std.testing.expectEqual(revision, fixture.service.worker_state.blueprints.revision);
    try std.testing.expectEqual(bytes, fixture.service.blueprint_library_bytes);
    // An automatic identity with the same numeric value remains a new Save.
    fixture.service.saveBlueprint(try fixture.request(9));
    var replies: std.ArrayList(BlueprintResult) = .empty;
    defer replies.deinit(a);
    fixture.client.takeBlueprintResults(&replies);
    try std.testing.expectEqual(@as(usize, 3), replies.items.len);
    try std.testing.expectEqual(.success, replies.items[0].status);
    try std.testing.expectEqual(.success, replies.items[1].status);
    try std.testing.expectEqual(replies.items[0].definition_id, replies.items[1].definition_id);
    try std.testing.expect(replies.items[2].definition_id != replies.items[0].definition_id);
    try std.testing.expectEqual(@as(u32, 2), fixture.service.worker_state.blueprints.definitions.count());
}

test "blueprint Save keys reject changed payloads and owners without taking another identity" {
    const a = std.testing.allocator;
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var first = try fixture.request(1);
    first.idempotency_key = 7;
    fixture.service.saveBlueprint(first);
    try fixture.service.players.put(a, 2, .{ .id = 2, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 });
    for (0..6) |variant| {
        var conflicting = try fixture.request(2 + variant);
        conflicting.idempotency_key = 7;
        switch (variant) {
            0 => {
                a.free(conflicting.name);
                conflicting.name = try a.dupe(u8, "Changed name");
            },
            1 => @constCast(conflicting.candidate.definition.cells)[0] = .sand,
            2 => conflicting.candidate.definition.size = .{ 1, 2, 1 },
            3 => conflicting.candidate.definition.target_count = 2,
            4 => conflicting.owner = 2,
            5 => conflicting.owner = 999,
            else => unreachable,
        }
        fixture.service.saveBlueprint(conflicting);
    }
    var replies: std.ArrayList(BlueprintResult) = .empty;
    defer replies.deinit(a);
    fixture.client.takeBlueprintResults(&replies);
    try std.testing.expectEqual(@as(usize, 7), replies.items.len);
    for (replies.items[1..]) |reply| try std.testing.expectEqual(.invalid, reply.status);
    try std.testing.expectEqual(@as(u32, 1), fixture.service.worker_state.blueprints.definitions.count());
    try std.testing.expectEqual(@as(u32, 1), fixture.client.blueprint_save_keys.count());
    try std.testing.expectEqual(@as(usize, 1), fixture.client.pending.blueprint_changes.items.len);
}

test "explicit Save retry API preserves caller ownership when enqueue fails" {
    const a = std.testing.allocator;
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var request = try fixture.request(1);
    defer {
        request.candidate.deinit(a);
        a.free(request.name);
    }
    fixture.service.requests.close(fixture.service.io);
    try std.testing.expectError(error.ServiceStopped, fixture.client.trySaveBlueprintWithKey(1, "Retry", &request.candidate, 33));
    try std.testing.expectEqual(rules.BlockType.planks, request.candidate.definition.cells[0]);
    try std.testing.expectEqual(@as(u32, 0), fixture.client.blueprint_save_keys.count());
}

fn exerciseBlueprintSavePublication(allocator: std.mem.Allocator) !void {
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.initWithAllocator(allocator);
    defer fixture.deinit();
    var request = try fixture.request(1);
    request.idempotency_key = 12;
    var owns_request = true;
    defer if (owns_request) {
        request.candidate.deinit(allocator);
        allocator.free(request.name);
    };
    // Result delivery has preexisting capacity so injected failures exercise
    // every fallible publication reservation rather than an infallible mailbox.
    try fixture.client.blueprint_results.items.ensureUnusedCapacity(allocator, 1);
    fixture.service.trySaveBlueprint(request) catch |err| {
        try std.testing.expectEqual(@as(u32, 0), fixture.service.worker_state.blueprints.definitions.count());
        try std.testing.expectEqual(@as(u32, 0), fixture.client.blueprint_save_keys.count());
        try std.testing.expectEqual(@as(usize, 0), fixture.client.pending.blueprint_changes.items.len);
        return err;
    };
    owns_request = false;
    try std.testing.expectEqual(@as(u32, 1), fixture.service.worker_state.blueprints.definitions.count());
    try std.testing.expectEqual(@as(u32, 1), fixture.client.blueprint_save_keys.count());
}

test "blueprint Save publication reserves its retry ledger before ownership transfer" {
    try exerciseBlueprintSavePublication(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseBlueprintSavePublication, .{});
}

test "permanent blueprint library limits reject terminally and preserve later command progress" {
    for ([_]bool{ false, true }) |exhausted_ids| {
        var fixture: BlueprintSaveFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        if (exhausted_ids) fixture.service.worker_state.blueprints.max_definition_id = std.math.maxInt(u64) else fixture.service.blueprint_library_bytes = (blueprint_wire.Limits{}).max_state_bytes;
        fixture.service.saveBlueprint(try fixture.request(1));
        try std.testing.expectEqual(@as(usize, 0), fixture.service.pending.len);
        try std.testing.expectEqual(@as(u32, 0), fixture.service.worker_state.blueprints.definitions.count());
        try std.testing.expectEqual(@as(u64, 1), fixture.client.resolved_request);
        fixture.service.worker_state.blueprints.max_definition_id = 0;
        fixture.service.blueprint_library_bytes = 0;
        fixture.service.saveBlueprint(try fixture.request(2));
        var results: std.ArrayList(BlueprintResult) = .empty;
        defer results.deinit(std.testing.allocator);
        fixture.client.takeBlueprintResults(&results);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqual(.resource_exhausted, results.items[0].status);
        try std.testing.expectEqual(.success, results.items[1].status);
        try std.testing.expectEqual(@as(usize, 0), fixture.service.blueprint_journal.items.len);
    }
}

test "shutdown frees only live blueprint Save payloads across a wrapped retained queue" {
    const a = std.testing.allocator;
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const service = &fixture.service;
    try service.pending.ensureTotalCapacityPrecise(a, 4);
    // Real completed Saves leave stale, already-transferred payloads in the ring.
    for (1..4) |id| {
        try service.pending.pushBack(a, .{ .request = .{ .blueprint_save = try fixture.request(id) }, .since = 0 });
        service.retryPending();
    }
    for (4..7) |id| try service.pending.pushBack(a, .{ .request = .{ .blueprint_save = try fixture.request(id) }, .since = 0 });
    try std.testing.expect(service.pending.head + service.pending.len > service.pending.buffer.len);
    service.is_shutting_down.store(true, .release);
    var another = try fixture.request(7);
    defer {
        another.candidate.deinit(a);
        a.free(another.name);
    }
    try std.testing.expectError(error.ServiceStopped, fixture.client.trySaveBlueprint(1, "Stopped", &another.candidate));
    try std.testing.expectEqual(rules.BlockType.planks, another.candidate.definition.cells[0]);
    try std.testing.expectError(error.ServiceStopped, fixture.client.tryApplyBlueprint(1, 1, .{ 0, 0, 48 }, 0));
    try std.testing.expectEqual(@as(usize, 0), service.requests.items.items.len);
    // Fixture shutdown must free both wrapped live spans exactly once, while
    // stale slots and the library's transferred payloads retain their own owners.
}

test "wrapped retained Saves preserve FIFO identity wait age and fence through allocation failure" {
    const a = std.testing.allocator;
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const service = &fixture.service;
    try service.pending.ensureTotalCapacityPrecise(a, 4);
    for (1..4) |id| {
        try service.pending.pushBack(a, .{ .request = .{ .blueprint_save = try fixture.request(id) }, .since = 0 });
        service.retryPending();
    }
    for (4..7) |id| try service.pending.pushBack(a, .{ .request = .{ .blueprint_save = try fixture.request(id) }, .since = @intCast(id * 10) });
    try std.testing.expect(service.pending.head + service.pending.len > service.pending.buffer.len);
    _ = service.lifecycle.request(.{ .id = 100, .final = false }, service.pending.len);
    // Reserving publication fails after popping the head. Retaining that owned
    // command must reuse its slot without moving it behind the later Saves.
    {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        service.allocator = failing.allocator();
        defer service.allocator = a;
        service.retryPending();
        try std.testing.expect(failing.has_induced_failure);
    }
    try std.testing.expectEqual(@as(usize, 3), service.pending.len);
    try std.testing.expectEqual(@as(usize, 3), service.lifecycle.queued.?.fence_remaining);
    try std.testing.expectEqual(@as(u64, 4), service.pending.front().?.request.blueprint_save.request_id);
    try std.testing.expectEqual(@as(?i96, 40), service.oldestPlayerWait());
    try std.testing.expectEqual(@as(u64, 3), fixture.client.resolved_request);
    service.retryPending();
    try std.testing.expectEqual(@as(usize, 0), service.pending.len);
    try std.testing.expect(service.lifecycle.queued == null);
    try std.testing.expectEqual(@as(?i96, null), service.oldestPlayerWait());
    var results: std.ArrayList(BlueprintResult) = .empty;
    defer results.deinit(a);
    fixture.client.takeBlueprintResults(&results);
    try std.testing.expectEqual(@as(usize, 6), results.items.len);
    for (results.items, 1..) |result, id| {
        try std.testing.expectEqual(id, result.request_id);
        try std.testing.expectEqual(.success, result.status);
        try std.testing.expectEqual(id, result.definition_id.?);
    }
}

test "blueprint journal backpressure drains accepted prefix before a queued final Save" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/blueprint-backpressure-{x}", .{uuid}, 0);
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = .{ @intCast(test_layout.size_in_chunks[0]), @intCast(test_layout.size_in_chunks[1]), @intCast(test_layout.size_in_chunks[2]) }, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(0);
    var store = try storage.Store.create(a, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
    defer store.deinit();
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.service.store = &store;
    fixture.service.saveBlueprint(try fixture.request(1));
    try std.testing.expectEqual(@as(usize, 1), fixture.service.blueprint_journal.items.len);
    // One real operation per transaction forces a drain before the next Save.
    store.limits.blueprints.max_operations = 1;
    fixture.service.saveBlueprint(try fixture.request(2));
    try std.testing.expect(fixture.service.operation_deferred);
    try std.testing.expect(fixture.service.job != null);
    fixture.service.requestSaveTransition(100, true);
    try std.testing.expectEqual(@as(usize, 1), fixture.service.pending.len);
    const end = persistence.now(io) + 10 * std.time.ns_per_s;
    while (persistence.now(io) < end) {
        fixture.service.drainPersistenceEvents();
        if (fixture.service.status.intent_id == 100 and !fixture.service.status.active and fixture.service.status.phase == .complete) break;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u64, 100), fixture.service.status.intent_id);
    try std.testing.expectEqual(persistence.Phase.complete, fixture.service.status.phase);
    try std.testing.expectEqual(@as(usize, 0), fixture.service.pending.len);
    try std.testing.expectEqual(@as(u32, 2), store.blueprints.definitions.count());
    try std.testing.expectEqual(@as(usize, 0), fixture.service.blueprint_journal.items.len);
}

fn installFulfillmentTestSite(state: *WorkerState, allocator: std.mem.Allocator, origin: [3]u32, size: [3]u32, cells: []const rules.BlockType) !void {
    var count: u32 = 0;
    for (cells) |material| if (material != .none) {
        count += 1;
    };
    try state.blueprints.insertDefinition(allocator, .{ .id = 1, .owner = 1, .name = try allocator.dupe(u8, "test site"), .definition = .{ .size = size, .cells = try allocator.dupe(rules.BlockType, cells), .target_count = count } });
    const instance = try state.blueprints.prepareInstance(allocator, state.layout, 1, 1, 1, origin, 0);
    try state.blueprints.insertInstance(allocator, state.layout, instance);
}

fn exerciseBlueprintResponsePreparation(allocator: std.mem.Allocator) !void {
    var service: WorldDataService = undefined;
    service.allocator = allocator;
    const id = test_layout.encodeChunkCoords(.{ 0, 0, 0 });
    const fulfilled = try allocator.dupe(u8, &.{0});
    const box_chunks = allocator.dupe(ChunkId, &.{id}) catch |err| {
        allocator.free(fulfilled);
        return err;
    };
    var task: BlueprintAdmissionTask = .{
        .service = &service,
        .request = undefined,
        .snapshot = .{ .layout = test_layout, .overlay_revision = 0 },
        .definition = .{ .size = .{ 1, 1, 1 }, .cells = &.{.planks}, .target_count = 1 },
        .instance = .{ .id = 1, .definition_id = 1, .owner = 1, .origin = .{ 10, 10, 4 }, .rotation = 0, .fulfilled = fulfilled, .remaining = 1, .box_chunks = box_chunks },
        .client_count = 3,
        .chunk_ids = &.{},
    };
    defer task.release();
    const blocks = try allocator.create(@import("world_chunk_data.zig").WorldChunkData);
    blocks.* = @import("world_chunk_data.zig").WorldChunkData.initEmpty();
    for (0..4) |level| @memset(std.mem.asBytes(&blocks.blocks[level]), @intFromEnum(rules.BlockType.stone));
    task.snapshot.chunks.put(allocator, id, .{ .revision = 0, .blocks = blocks }) catch |err| {
        allocator.destroy(blocks);
        return err;
    };
    task.result = try task.prepare();
    const result = try task.result.?;
    try std.testing.expect(result == .prepared);
    try std.testing.expectEqual(@as(usize, 3), task.response_copies.items.len);
    for (task.response_copies.items, 0..) |copy, index| {
        try std.testing.expect(copy.fulfilled.ptr != task.instance.fulfilled.ptr);
        try std.testing.expect(copy.fulfilled.ptr != result.prepared.publication.instance.fulfilled.ptr);
        try std.testing.expect(copy.box_chunks.ptr != result.prepared.publication.instance.box_chunks.ptr);
        for (task.response_copies.items[0..index]) |previous| try std.testing.expect(previous.fulfilled.ptr != copy.fulfilled.ptr);
    }
    task.response_copies.items[0].fulfilled[0] = 1;
    try std.testing.expectEqual(@as(u8, 0), task.response_copies.items[1].fulfilled[0]);
}

test "admission helper owns independent client publication copies through allocation failures" {
    try exerciseBlueprintResponsePreparation(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseBlueprintResponsePreparation, .{});
}

test "new client registration invalidates prepared admission before publication" {
    var service: WorldDataService = .{ .layout = &test_layout, .io = std.testing.io, .allocator = std.testing.allocator, .worker = undefined, .worker_state = .{ .layout = &test_layout, .generator = undefined } };
    var task: BlueprintAdmissionTask = .{
        .service = &service,
        .request = undefined,
        .snapshot = .{ .layout = test_layout, .overlay_revision = 0 },
        .definition = undefined,
        .instance = undefined,
        .client_count = 1,
        .chunk_ids = &.{},
    };
    try std.testing.expectError(error.StalePreparation, service.commitBlueprintApplication(&task));
    try std.testing.expectEqual(@as(u32, 0), service.worker_state.blueprints.instances.count());
    try std.testing.expectEqual(@as(u64, 0), service.worker_state.blueprints.revision);
}

test "authority blueprint fulfillment probes five real neighbors and never enters ordinary validation" {
    const a = std.testing.allocator;
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
    defer state.deinit(a);
    const coords: ChunkCoords = .{ 0, 0, 2 };
    var chunk = WorldChunk.initEmpty();
    try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 10, 10, 5 }, .{ .put = .sand }));
    try state.modified_chunks.put(a, test_layout.encodeChunkCoords(coords), chunk);
    const first: [3]u32 = .{ 10, 10, 70 };
    const second: [3]u32 = .{ 11, 10, 70 };
    try installFulfillmentTestSite(&state, a, first, .{ 2, 1, 1 }, &.{ .planks, .planks });
    const original_calls = state.ordinary_validation_calls;
    const unsupported = try state.tryFulfillBlueprint(a, .{ .block = second, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 1, .cell_index = 1 } });
    try std.testing.expectEqual(OperationStatus.constraint_violation, unsupported.diagnostics.status);
    try std.testing.expectEqual(@as(u8, 5), state.blueprint_last_support_reads);
    try std.testing.expectEqual(@as(u32, 2), state.blueprints.instances.get(1).?.remaining);
    const wrong = try state.tryFulfillBlueprint(a, .{ .block = first, .action = .{ .put = .sand }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } });
    try std.testing.expectEqual(OperationStatus.inventory_mismatch, wrong.diagnostics.status);
    try std.testing.expectEqual(@as(u8, 0), state.blueprint_last_support_reads);
    const one = try state.tryFulfillBlueprint(a, .{ .block = first, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } });
    try std.testing.expectEqual(OperationStatus.success, one.diagnostics.status);
    try std.testing.expectEqual(@as(u8, 1), state.blueprint_last_support_reads);
    const two = try state.tryFulfillBlueprint(a, .{ .block = second, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 1, .cell_index = 1 } });
    try std.testing.expectEqual(OperationStatus.success, two.diagnostics.status);
    try std.testing.expect(state.blueprint_last_support_reads <= 5);
    try std.testing.expectEqual(original_calls, state.ordinary_validation_calls);
    try std.testing.expect(!state.blueprints.instances.get(1).?.active);
    try std.testing.expectEqual(@as(u32, 0), state.blueprints.instances.get(1).?.remaining);
    try std.testing.expectEqual(@as(usize, 1), state.blueprints.cleanup_queue.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.modified_chunks.get(test_layout.encodeChunkCoords(coords)).?.metadata.constructed.items.len);
    const replay = try state.tryFulfillBlueprint(a, .{ .block = first, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } });
    try std.testing.expectEqual(OperationStatus.target_changed, replay.diagnostics.status);
}

test "authority blueprint batch coalesces block payload and couples inventory with progress" {
    const a = std.testing.allocator;
    var service: WorldDataService = .{ .layout = &test_layout, .io = std.testing.io, .allocator = a, .worker = undefined, .worker_state = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) } };
    defer service.worker_state.deinit(a);
    defer service.clients.deinit(a);
    defer service.players.deinit(a);
    defer service.blueprint_journal.deinit(a);
    defer service.dirty_meshes.deinit(a);
    var origin: Client = .{ .service = &service };
    var observer: Client = .{ .service = &service };
    defer origin.subscriptions.deinit(a);
    defer observer.subscriptions.deinit(a);
    defer origin.pending.deinit(a);
    defer observer.pending.deinit(a);
    defer origin.responses.deinit(a);
    defer observer.responses.deinit(a);
    service.worker_state.persistence_service = &service;
    try service.clients.appendSlice(a, &.{ &origin, &observer });
    try service.players.put(a, 1, .{ .id = 1, .feet = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0, .inventory = @intFromEnum(rules.BlockType.planks) });
    const coords: ChunkCoords = .{ 0, 0, 2 };
    const id = test_layout.encodeChunkCoords(coords);
    var chunk = WorldChunk.initEmpty();
    try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 10, 10, 5 }, .{ .put = .sand }));
    try service.worker_state.modified_chunks.put(a, id, chunk);
    try origin.subscriptions.put(a, id, .{ .id = 1, .mode = .blocks });
    try observer.subscriptions.put(a, id, .{ .id = 2, .mode = .blocks });
    try installFulfillmentTestSite(&service.worker_state, a, .{ 10, 10, 70 }, .{ 2, 1, 1 }, &.{ .planks, .planks });
    service.processBlueprintFulfillment(.{ .client = &origin, .request_id = 1, .operation = .{ .block = .{ 10, 10, 70 }, .action = .{ .put = .sand }, .player = .{ .id = 1, .expected_sequence = 0 }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } } });
    try std.testing.expectEqual(OperationStatus.inventory_mismatch, origin.pending.responses.items[0].operation.?.status);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(rules.BlockType.planks)), service.players.get(1).?.inventory);
    service.processBlueprintFulfillment(.{ .client = &origin, .request_id = 2, .operation = .{ .block = .{ 10, 10, 70 }, .action = .{ .put = .planks }, .player = .{ .id = 1, .expected_sequence = 0 }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } } });
    try std.testing.expectEqual(@as(?u8, null), service.players.get(1).?.inventory);
    service.players.getPtr(1).?.inventory = @intFromEnum(rules.BlockType.planks);
    service.processBlueprintFulfillment(.{ .client = &origin, .request_id = 3, .operation = .{ .block = .{ 11, 10, 70 }, .action = .{ .put = .planks }, .player = .{ .id = 1, .expected_sequence = 0 }, .blueprint = .{ .instance_id = 1, .cell_index = 1 } } });
    try std.testing.expectEqual(@as(?u8, null), service.players.get(1).?.inventory);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_journal.items.len);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_journal_bytes);
    for (origin.pending.responses.items) |response| try std.testing.expect(response.data == .acknowledgement);
    try std.testing.expectEqual(@as(usize, 2), origin.pending.blueprint_changes.items.len);
    try std.testing.expectEqual(@as(u64, 0), service.worker_state.ordinary_validation_calls);
    service.flushPackages();
    var packages: std.ArrayList(ResponsePackage) = .empty;
    defer packages.deinit(a);
    origin.takePackages(&packages);
    defer for (packages.items) |*package| package.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), packages.items.len);
    var payloads: usize = 0;
    for (packages.items[0].responses.items) |response| if (response.data == .blocks) {
        payloads += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), payloads);
    try std.testing.expectEqual(@as(usize, 2), packages.items[0].blueprint_changes.items.len);
    var observed: std.ArrayList(ResponsePackage) = .empty;
    observer.takePackages(&observed);
    defer observed.deinit(a);
    defer for (observed.items) |*package| package.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), observed.items.len);
    try std.testing.expectEqual(@as(usize, 2), observed.items[0].blueprint_changes.items.len);
}

test "interleaved fulfillment across 128 sites keeps bounded support work and coalesces replies" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var service: WorldDataService = .{ .layout = &test_layout, .io = io, .allocator = a, .worker = undefined, .worker_state = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) } };
    defer service.worker_state.deinit(a);
    defer service.clients.deinit(a);
    defer service.blueprint_journal.deinit(a);
    defer service.blueprint_road_queue.deinit(a);
    defer service.dirty_meshes.deinit(a);
    var client: Client = .{ .service = &service };
    defer client.pending.deinit(a);
    defer client.subscriptions.deinit(a);
    defer client.responses.deinit(a);
    try service.clients.append(a, &client);
    service.worker_state.persistence_service = &service;
    for (0..2) |x| {
        var chunk = WorldChunk.initEmpty();
        const blocks = try chunk.tryEnsureData(a);
        for (3..6) |z| @memset(std.mem.asBytes(&blocks.blocks[z]), @intFromEnum(rules.BlockType.stone));
        const id = test_layout.encodeChunkCoords(.{ @intCast(x), 0, 2 });
        service.worker_state.modified_chunks.put(a, id, chunk) catch |err| {
            chunk.deinit(a);
            return err;
        };
        try client.subscriptions.put(a, id, .{ .id = x + 1, .mode = .blocks });
    }
    const material = try a.alloc(rules.BlockType, 64);
    @memset(material, .planks);
    try service.worker_state.blueprints.insertDefinition(a, .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Many sites"), .definition = .{ .size = .{ 4, 4, 4 }, .cells = material, .target_count = 64 } });
    for (0..128) |site| {
        const position: [3]u32 = .{ @intCast((site % 16) * 4), @intCast((site / 16) * 4), 70 };
        const instance = try service.worker_state.blueprints.prepareInstance(a, &test_layout, site + 1, 1, 1, position, 0);
        try service.worker_state.blueprints.insertInstance(a, &test_layout, instance);
    }
    const start = persistence.now(io);
    for (0..64) |cell_index| for (0..128) |site| {
        const position: [3]u32 = .{ @intCast((site % 16) * 4 + cell_index % 4), @intCast((site / 16) * 4 + (cell_index / 4) % 4), @intCast(70 + cell_index / 16) };
        service.processBlueprintFulfillment(.{ .client = &client, .request_id = cell_index * 128 + site + 1, .operation = .{ .block = position, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = site + 1, .cell_index = @intCast(cell_index) } } });
        try std.testing.expectEqual(OperationStatus.success, client.pending.responses.items[client.pending.responses.items.len - 1].operation.?.status);
        try std.testing.expect(service.worker_state.blueprint_last_support_reads <= 5);
    };
    const fill_ns = persistence.now(io) - start;
    try std.testing.expectEqual(@as(u64, 8192), service.worker_state.blueprint_support_reads);
    try std.testing.expectEqual(@as(u64, 0), service.worker_state.ordinary_validation_calls);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.count);
    var instances = service.worker_state.blueprints.instances.valueIterator();
    while (instances.next()) |instance| try std.testing.expect(!instance.active and instance.remaining == 0);
    for (client.pending.responses.items) |response| try std.testing.expect(response.data == .acknowledgement);
    const progress = try a.alloc(blueprint_wire.Op, 8192);
    defer a.free(progress);
    for (client.pending.blueprint_changes.items, progress) |change, *operation| operation.* = .{ .fulfill = .{ .instance_id = change.fulfill.instance_id, .cell_index = change.fulfill.cell_index } };
    const encoded = try blueprint_wire.encodeOps(a, progress);
    defer a.free(encoded);
    // The enclosing journal supplies its byte length; each fill is thirteen bytes.
    try std.testing.expectEqual(@as(usize, 8192 * 13), encoded.len);
    const flush_start = persistence.now(io);
    service.flushPackages();
    const flush_ns = persistence.now(io) - flush_start;
    var packages: std.ArrayList(ResponsePackage) = .empty;
    defer packages.deinit(a);
    client.takePackages(&packages);
    defer for (packages.items) |*package| package.deinit(a);
    var snapshots: usize = 0;
    var acknowledgments: usize = 0;
    for (packages.items) |package| for (package.responses.items) |response| {
        if (response.data == .blocks) snapshots += 1;
        if (response.operation != null) acknowledgments += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), snapshots);
    try std.testing.expectEqual(@as(usize, 8192), acknowledgments);
    if (@import("builtin").mode == .ReleaseFast) std.debug.print("blueprint interleaved sites=128 fills=8192 fill_ms={d:.3} support_reads=8192 ordinary_calls=0 flush_ms={d:.3} block_snapshots=2 raw_block_bytes=65536 progress_bytes={d}\n", .{ @as(f64, @floatFromInt(fill_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(flush_ns)) / std.time.ns_per_ms, encoded.len });
}

const BlueprintRoadFixture = struct {
    service: WorldDataService,

    fn init(self: *@This()) !void {
        const a = std.testing.allocator;
        self.service = .{ .layout = &test_layout, .io = std.testing.io, .allocator = a, .worker = undefined, .worker_state = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) } };
        self.service.worker_state.persistence_service = &self.service;
        var chunk = WorldChunk.initEmpty();
        errdefer chunk.deinit(a);
        for (10..15) |x| {
            try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(x), 10, 5 }, .{ .put = .stone }));
        }
        try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 15, 10, 4 }, .{ .put = .stone }));
        try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 10, 10, 6 }, .{ .put = .country_road_solid }));
        for (11..15) |x| try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(x), 10, 6 }, .{ .put = .country_road_adaptive }));
        try self.service.worker_state.modified_chunks.put(a, test_layout.encodeChunkCoords(.{ 0, 0, 2 }), chunk);
        try installFulfillmentTestSite(&self.service.worker_state, a, .{ 15, 10, 69 }, .{ 1, 1, 1 }, &.{.country_road_solid});
    }

    fn deinit(self: *@This()) void {
        const a = std.testing.allocator;
        self.service.worker_state.deinit(a);
        self.service.blueprint_road_queue.deinit(a);
        self.service.source_holds.deinit(a);
        self.service.blueprint_journal.deinit(a);
        self.service.dirty_meshes.deinit(a);
        self.service.pending.deinit(a);
    }

    fn fill(self: *@This()) !WorkerState.BlueprintCommit {
        return self.service.tryCommitBlueprintFulfillment(.{ .block = .{ 15, 10, 69 }, .action = .{ .put = .country_road_solid }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } });
    }

    fn slope(self: *@This()) ?@import("road_data.zig").Slope {
        return self.service.worker_state.modified_chunks.get(test_layout.encodeChunkCoords(.{ 0, 0, 2 })).?.metadata.road(transformations.index(.{ 11, 10, 6 })).?.slope;
    }
};

const BlueprintRoadThroughputTest = struct {
    const site_count = 128;
    const fills_per_site = 64;
    // The same workload can be copied onto the pre-fix source for comparison.
    const has_road_capture_gate = @hasDecl(WorldDataService, "roadCaptureBlocked");

    fn origin(site: usize, sites_per_chunk: usize) [3]u32 {
        const slot = site % sites_per_chunk;
        return .{ @intCast((site / sites_per_chunk) * 2 * CHUNK_SIZE + 6 + (slot % 2) * 16), @intCast(1 + (slot / 2) * 4), 69 };
    }

    fn makeChunk(first_site: usize, sites_per_chunk: usize) !WorldChunk {
        const a = std.testing.allocator;
        var chunk = WorldChunk.initEmpty();
        errdefer chunk.deinit(a);
        for (first_site..first_site + sites_per_chunk) |site| {
            const position = origin(site, sites_per_chunk);
            const x: usize = position[0] % CHUNK_SIZE;
            const y: usize = position[1];
            for (x - 5..x) |support_x| try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(support_x), @intCast(y), 5 }, .{ .put = .stone }));
            try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(x), @intCast(y), 4 }, .{ .put = .stone }));
            for (y..y + 3) |support_y| for (x + 2..x + 8) |support_x| try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(support_x), @intCast(support_y), 4 }, .{ .put = .stone }));
            try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(x - 5), @intCast(y), 6 }, .{ .put = .country_road_solid }));
            for (x - 4..x) |road_x| try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(road_x), @intCast(y), 6 }, .{ .put = .country_road_adaptive }));
        }
        return chunk;
    }

    fn run(sites_per_chunk: usize) !void {
        const a = std.testing.allocator;
        const io = std.testing.io;
        const chunk_count = site_count / sites_per_chunk;
        var service: WorldDataService = .{ .layout = &test_layout, .io = io, .allocator = a, .worker = undefined, .worker_state = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) } };
        defer service.worker_state.deinit(a);
        defer service.clients.deinit(a);
        defer service.blueprint_journal.deinit(a);
        defer service.blueprint_road_queue.deinit(a);
        defer service.source_holds.deinit(a);
        defer service.dirty_meshes.deinit(a);
        defer service.pending.deinit(a);
        var client: Client = .{ .service = &service };
        defer client.pending.deinit(a);
        defer client.responses.deinit(a);
        var npc: Client = .{ .service = &service, .simulation = true };
        defer npc.pending.deinit(a);
        defer npc.responses.deinit(a);
        try service.clients.append(a, &client);
        service.worker_state.persistence_service = &service;
        for (0..chunk_count) |index| {
            var chunk = try makeChunk(index * sites_per_chunk, sites_per_chunk);
            service.worker_state.modified_chunks.put(a, test_layout.encodeChunkCoords(.{ @intCast(index * 2), 0, 2 }), chunk) catch |err| {
                chunk.deinit(a);
                return err;
            };
        }
        // Every site finishes an actual ramp plus 63 supported building cells.
        // Three full plank layers and half the top layer avoid unsupported gaps.
        var cells: [8 * 3 * 4]rules.BlockType = @splat(.none);
        cells[0] = .country_road_solid;
        for (0..4) |z| for (0..3) |y| for (2..8) |x| {
            if (z == 3 and y * 6 + x - 2 >= 9) continue;
            cells[(z * 3 + y) * 8 + x] = .planks;
        };
        try service.worker_state.blueprints.insertDefinition(a, .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Road throughput"), .definition = .{ .size = .{ 8, 3, 4 }, .cells = try a.dupe(rules.BlockType, &cells), .target_count = fills_per_site } });
        for (0..site_count) |site| {
            const instance = try service.worker_state.blueprints.prepareInstance(a, &test_layout, site + 1, 1, 1, origin(site, sites_per_chunk), 0);
            try service.worker_state.blueprints.insertInstance(a, &test_layout, instance);
        }
        // Both phases run synchronously on resident chunks without file I/O or
        // sleeps. Thread CPU time distinguishes active work from elapsed time.
        const cpu_clock_available = if (Io.Clock.cpu_thread.resolution(io)) |resolution| resolution.nanoseconds > 0 else |_| false;
        const fill_start = persistence.now(io);
        const fill_cpu_start = if (cpu_clock_available) Io.Clock.cpu_thread.now(io).toNanoseconds() else 0;
        var fills: usize = 0;
        for (cells, 0..) |material, cell_index| {
            if (material == .none) continue;
            for (0..site_count) |site| {
                const position = origin(site, sites_per_chunk);
                service.processRequest(.{ .operation = .{ .client = &client, .request_id = fills + 1, .operation = .{ .block = .{ position[0] + @as(u32, @intCast(cell_index % 8)), position[1] + @as(u32, @intCast((cell_index / 8) % 3)), position[2] + @as(u32, @intCast(cell_index / 24)) }, .action = .{ .put = material }, .blueprint = .{ .instance_id = site + 1, .cell_index = @intCast(cell_index) } } } });
                try std.testing.expectEqual(OperationStatus.success, client.pending.responses.items[client.pending.responses.items.len - 1].operation.?.status);
                try std.testing.expect(service.worker_state.blueprint_last_support_reads <= 5);
                fills += 1;
            }
        }
        const fill_cpu_ns = if (cpu_clock_available) Io.Clock.cpu_thread.now(io).toNanoseconds() - fill_cpu_start else 0;
        const fill_ns = persistence.now(io) - fill_start;
        try std.testing.expectEqual(@as(usize, site_count * fills_per_site), fills);
        try std.testing.expectEqual(@as(u64, site_count * fills_per_site), service.worker_state.blueprint_support_reads);
        try std.testing.expectEqual(@as(u64, 0), service.worker_state.ordinary_validation_calls);
        const queued_chunks = service.blueprint_road_queue.count;
        try std.testing.expectEqual(chunk_count, queued_chunks);
        var instances = service.worker_state.blueprints.instances.valueIterator();
        while (instances.next()) |instance| try std.testing.expect(!instance.active and instance.remaining == 0);
        for (0..site_count) |site| {
            const position = origin(site, sites_per_chunk);
            const chunk = service.worker_state.modified_chunks.get(test_layout.encodeChunkCoords(.{ @intCast(position[0] / CHUNK_SIZE), 0, 2 })).?;
            try std.testing.expect(chunk.metadata.road(transformations.index(.{ @intCast(position[0] % CHUNK_SIZE - 4), @intCast(position[1]), 6 })).?.slope == null);
        }
        // Exercise a real accepted-prefix boundary without creating a writer:
        // store=null excludes persistence I/O from this admission/road delay.
        const admission_start = persistence.now(io);
        service.requestSaveTransition(100, false);
        const replay: Request = .{ .operation = .{ .client = &client, .request_id = fills + 1, .operation = .{ .block = origin(0, sites_per_chunk), .action = .{ .put = .country_road_solid }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } } } };
        var npc_replay = replay;
        npc_replay.operation.client = &npc;
        try std.testing.expectEqual(has_road_capture_gate, !service.admissible(replay));
        try std.testing.expectEqual(has_road_capture_gate, !service.admissible(npc_replay));
        try std.testing.expectEqual(has_road_capture_gate, service.simulationPaused());
        service.processRequest(replay);
        service.processRequest(npc_replay);
        const retained_replays: usize = if (has_road_capture_gate) 2 else 0;
        try std.testing.expectEqual(retained_replays, service.pending.len);
        const drain_start = persistence.now(io);
        const drain_cpu_start = if (cpu_clock_available) Io.Clock.cpu_thread.now(io).toNanoseconds() else 0;
        var turns: usize = 0;
        var work_units: usize = 0;
        const batch_budget = if (@hasDecl(WorldDataService, "processBlueprintRoadUpdatesWithBudget")) WorldDataService.blueprint_road_work_per_turn else 1;
        while (service.blueprint_road_queue.peek() != null) {
            try std.testing.expect(turns < site_count * 4 + chunk_count);
            try std.testing.expectEqual(has_road_capture_gate, !service.admissible(replay));
            try std.testing.expectEqual(has_road_capture_gate, !service.admissible(npc_replay));
            try std.testing.expectEqual(has_road_capture_gate, service.simulationPaused());
            try std.testing.expectEqual(retained_replays, service.pending.len);
            try std.testing.expectEqual(fills + @as(usize, if (has_road_capture_gate) 0 else 1), client.pending.responses.items.len);
            try std.testing.expectEqual(@as(usize, if (has_road_capture_gate) 0 else 1), npc.pending.responses.items.len);
            const processed = if (@hasDecl(WorldDataService, "processBlueprintRoadUpdatesWithBudget"))
                service.processBlueprintRoadUpdatesWithBudget(batch_budget)
            else blk: {
                service.processBlueprintRoadUpdates();
                break :blk @as(usize, 1);
            };
            try std.testing.expect(processed > 0 and processed <= batch_budget);
            work_units += processed;
            try std.testing.expect(!service.blueprint_road_waiting);
            turns += 1;
        }
        const drain_cpu_ns = if (cpu_clock_available) Io.Clock.cpu_thread.now(io).toNanoseconds() - drain_cpu_start else 0;
        const drain_ns = persistence.now(io) - drain_start;
        const admission_road_delay_ns = if (has_road_capture_gate) persistence.now(io) - admission_start else 0;
        const seeds = work_units - chunk_count;
        try std.testing.expectEqual(@as(usize, site_count * 4), seeds);
        try std.testing.expectEqual(site_count * 4 + chunk_count, work_units);
        try std.testing.expectEqual((work_units + batch_budget - 1) / batch_budget, turns);
        try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.count);
        try std.testing.expectEqual(@as(usize, 0), service.pending.len);
        try std.testing.expect(service.admissible(replay) and service.admissible(npc_replay));
        try std.testing.expect(!service.simulationPaused());
        try std.testing.expectEqual(fills + 1, client.pending.responses.items.len);
        try std.testing.expectEqual(@as(usize, 1), npc.pending.responses.items.len);
        try std.testing.expectEqual(OperationStatus.target_changed, client.pending.responses.items[fills].operation.?.status);
        try std.testing.expectEqual(OperationStatus.target_changed, npc.pending.responses.items[0].operation.?.status);
        try std.testing.expectEqual(@as(u64, site_count * fills_per_site), service.worker_state.blueprint_support_reads);
        try std.testing.expectEqual(@as(u64, 0), service.worker_state.ordinary_validation_calls);
        for (0..site_count) |site| {
            const position = origin(site, sites_per_chunk);
            const chunk = service.worker_state.modified_chunks.get(test_layout.encodeChunkCoords(.{ @intCast(position[0] / CHUNK_SIZE), 0, 2 })).?;
            for (0..4) |section| {
                const road = chunk.metadata.road(transformations.index(.{ @intCast(position[0] % CHUNK_SIZE - 4 + section), @intCast(position[1]), 6 })).?;
                try std.testing.expectEqualDeep(@as(?@import("road_data.zig").Slope, .{ .high_endpoint = .{ position[0] - 5, position[1], 70 }, .downhill = .positive_x, .length = 4, .section = @intCast(section) }), road.slope);
            }
        }
        if (@import("builtin").mode == .ReleaseFast) std.debug.print("blueprint roads sites=128 fills=8192 queued_chunks={d} adaptive_cells=512 fill_ms={d:.3} fill_cpu_ms={d:.3} drain_ms={d:.3} drain_cpu_ms={d:.3} admission_road_delay_ms={d:.3} admission_gate={s} cpu_clock={s} road_seeds={d} road_work_units={d} batch_budget={d} road_turns={d} remaining_chunks=0 support_reads={d} ordinary_calls={d}\n", .{ queued_chunks, @as(f64, @floatFromInt(fill_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(fill_cpu_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(drain_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(drain_cpu_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(admission_road_delay_ns)) / std.time.ns_per_ms, if (has_road_capture_gate) "held" else "baseline_open", if (cpu_clock_available) "thread" else "unavailable", seeds, work_units, batch_budget, turns, service.worker_state.blueprint_support_reads, service.worker_state.ordinary_validation_calls });
    }
};

test "interleaved road blueprint workload separates fill throughput from bounded actual road drain" {
    for ([_]usize{ 16, 1 }) |sites_per_chunk| try BlueprintRoadThroughputTest.run(sites_per_chunk);
}

test "blueprint fulfillment queues adaptive road work and delayed safe plans publish atomically" {
    var fixture: BlueprintRoadFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const result = try fixture.fill();
    try std.testing.expectEqual(OperationStatus.success, result.diagnostics.status);
    try std.testing.expectEqual(@as(u8, 1), fixture.service.worker_state.blueprint_last_support_reads);
    try std.testing.expectEqual(@as(u64, 0), fixture.service.worker_state.ordinary_validation_calls);
    try std.testing.expect(fixture.slope() == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.service.blueprint_road_queue.count);
    const id = test_layout.encodeChunkCoords(.{ 0, 0, 2 });
    const before = fixture.service.worker_state.modified_chunks.get(id).?.chunk_revision;
    _ = fixture.service.processBlueprintRoadUpdatesWithBudget(1);
    try std.testing.expect(fixture.slope() != null);
    try std.testing.expectEqual(before + 1, fixture.service.worker_state.modified_chunks.get(id).?.chunk_revision);
    try std.testing.expect(fixture.service.dirty_meshes.contains(id));
    try std.testing.expect(fixture.service.lifecycle.unsaved_work);
}

test "delayed road plans retain source-held work and form beneath real and pending overhead roads" {
    const a = std.testing.allocator;
    var fixture: BlueprintRoadFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try std.testing.expectEqual(OperationStatus.success, (try fixture.fill()).diagnostics.status);
    const id = test_layout.encodeChunkCoords(.{ 0, 0, 2 });
    try fixture.service.source_holds.put(a, id, 1);
    _ = fixture.service.processBlueprintRoadUpdatesWithBudget(1);
    try std.testing.expect(fixture.slope() == null);
    try std.testing.expect(fixture.service.blueprint_road_waiting);
    try std.testing.expectEqual(@as(usize, 0), fixture.service.blueprint_road_queue.peek().?.cursor);
    _ = fixture.service.source_holds.remove(id);
    try fixture.service.worker_state.blueprints.insertDefinition(a, .{ .id = 2, .owner = 1, .name = try a.dupe(u8, "upper road"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{.country_road_solid}), .target_count = 1 } });
    const upper = try fixture.service.worker_state.blueprints.prepareInstance(a, &test_layout, 2, 2, 1, .{ 12, 10, 71 }, 0);
    try fixture.service.worker_state.blueprints.insertInstance(a, &test_layout, upper);
    const chunk = fixture.service.worker_state.modified_chunks.getPtr(id).?;
    try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 13, 10, 7 }, .{ .put = .country_road_solid }));
    try chunk.metadata.tryMarkConstructed(a, transformations.index(.{ 13, 10, 7 }));
    const before = chunk.chunk_revision;
    _ = fixture.service.processBlueprintRoadUpdatesWithBudget(1);
    try std.testing.expect(fixture.slope() != null);
    try std.testing.expectEqual(before + 1, fixture.service.worker_state.modified_chunks.get(id).?.chunk_revision);
    try std.testing.expectEqual(rules.BlockType.country_road_solid, fixture.service.worker_state.modified_chunks.get(id).?.content.getBlock(.{ 13, 10, 7 }));
    try std.testing.expectEqual(@as(u32, 1), fixture.service.worker_state.blueprints.instances.get(2).?.remaining);
    try std.testing.expectEqual(@as(u64, 0), fixture.service.worker_state.ordinary_validation_calls);
    try std.testing.expect(!fixture.service.blueprint_road_waiting);
    try std.testing.expectEqual(@as(usize, 1), fixture.service.blueprint_road_queue.peek().?.cursor);
    try std.testing.expect(fixture.service.worker_state.blueprints.targetAt(.{ 12, 10, 71 }) != null);
}

test "ordinary puts agree across dense sites while removals protect lateral platform and pending support" {
    const a = std.testing.allocator;
    const Setup = struct {
        fn put(chunk: *WorldChunk, local: [3]u5, material: rules.BlockType, constructed: bool) !void {
            try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(std.testing.allocator, local, .{ .put = material }));
            if (constructed) try chunk.metadata.tryMarkConstructed(std.testing.allocator, transformations.index(local));
        }
    };
    var state: WorkerState = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) };
    defer state.deinit(a);
    const coords: ChunkCoords = .{ 0, 0, 2 };
    const id = test_layout.encodeChunkCoords(coords);
    try state.modified_chunks.put(a, id, WorldChunk.initEmpty());
    const chunk = state.modified_chunks.getPtr(id).?;
    try Setup.put(chunk, .{ 6, 6, 5 }, .stone, false);
    for (3..6) |z| for (9..12) |y| for (9..12) |x| try Setup.put(chunk, .{ @intCast(x), @intCast(y), @intCast(z) }, .stone, false);
    for (10..13) |x| try Setup.put(chunk, .{ @intCast(x), 10, 6 }, .planks, true);
    for (3..6) |z| for (9..12) |y| for (19..22) |x| try Setup.put(chunk, .{ @intCast(x), @intCast(y), @intCast(z) }, .packed_dirt, false);
    try Setup.put(chunk, .{ 20, 10, 6 }, .tree_trunk, true);
    for (3..6) |z| for (23..26) |y| for (23..26) |x| try Setup.put(chunk, .{ @intCast(x), @intCast(y), @intCast(z) }, .stone, false);
    for (10..14) |z| for (20..28) |y| for (2..10) |x| try Setup.put(chunk, .{ @intCast(x), @intCast(y), @intCast(z) }, .water, true);
    var targets: [64]rules.BlockType = @splat(.water);
    targets[0] = .planks;
    try installFulfillmentTestSite(&state, a, .{ 24, 24, 70 }, .{ 4, 4, 4 }, &targets);

    var client = try world_module.World.init(a, &test_layout);
    defer client.deinit();
    try client.insertChunk(coords, try chunk.tryClone(a));
    try client.applyBlueprintChanges(&.{ .{ .definition = state.blueprints.definitions.get(1).? }, .{ .instance = state.blueprints.instances.get(1).? } });
    const operation: BlockOperation = .{ .block = .{ 6, 6, 70 }, .action = .{ .put = .tree_trunk } };
    // Both sides reject an isolated stone, then accept the same edit once all
    // 27 platform cells exist, including qualifying mixed-material corners.
    const isolated = client.previewOperation(operation);
    try std.testing.expectEqual(OperationStatus.constraint_violation, isolated.status);
    try std.testing.expectEqual(rules.Reason.missing_foundation, isolated.failure.?.reason);
    try std.testing.expectEqual(@as(u32, 1), isolated.failure.?.actual);
    try std.testing.expectEqual(@as(u32, 27), isolated.failure.?.limit);
    {
        const rejected = try state.tryApplyOperation(a, operation);
        defer rejected.chunk.deinit(a);
        try std.testing.expectEqualDeep(isolated, rejected.diagnostics);
    }
    try std.testing.expectEqual(rules.BlockType.none, readStateBlock(&state, operation.block));
    try std.testing.expectEqual(@as(usize, 0), client.pending_operations.items.len);
    const platform_materials = [_]rules.BlockType{ .stone, .dirt, .packed_dirt, .grass, .clay, .crushed_stone, .rebar, .reinforced_concrete, .metal_ore, .limestone, .coal };
    const platform_chunk = state.modified_chunks.getPtr(id).?;
    var platform_index: usize = 0;
    for (3..6) |z| for (5..8) |y| for (5..8) |x| {
        if (x == 6 and y == 6 and z == 5) continue;
        try Setup.put(platform_chunk, .{ @intCast(x), @intCast(y), @intCast(z) }, platform_materials[platform_index % platform_materials.len], false);
        platform_index += 1;
    };
    try std.testing.expectEqual(@as(usize, 26), platform_index);
    try client.insertChunk(coords, try platform_chunk.tryClone(a));
    const collections = &world_module.Testing.constructed_collection_calls;
    const before_client_put = collections.load(.monotonic);
    const preview = client.tryOperation(operation);
    try std.testing.expectEqual(OperationStatus.success, preview.status);
    try std.testing.expectEqual(before_client_put, collections.load(.monotonic));
    client.pending_operations.items[0].request_id = 1;
    const before_authority_put = collections.load(.monotonic);
    const applied = try state.tryApplyOperation(a, operation);
    defer applied.chunk.deinit(a);
    try std.testing.expectEqualDeep(preview, applied.diagnostics);
    try std.testing.expectEqual(before_authority_put, collections.load(.monotonic));
    client.acknowledgeOperation(1);
    try client.insertChunk(coords, try applied.chunk.tryClone(a));
    try std.testing.expectEqual(@as(usize, 0), client.pending_operations.items.len);
    try std.testing.expectEqual(rules.BlockType.tree_trunk, readStateBlock(&state, operation.block));
    const authority = state.modified_chunks.get(id).?;
    const received = client.getChunk(coords).?;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&authority.content.blocks.blocks), std.mem.asBytes(&received.content.blocks.blocks));
    try std.testing.expectEqualSlices(transformations.BlockIndex, authority.metadata.constructed.items, received.metadata.constructed.items);

    // Each removal is outside the planned box; dependent validation must supply
    // the rejection, including the off-center cell in the trunk's soil platform.
    const supports = [_][3]u32{
        .{ 10, 10, 69 }, // Sole foundation of a lateral plank beam.
        .{ 19, 9, 69 }, // Platform corner, away from the trunk's direct column.
        .{ 24, 24, 69 }, // Foundation of the pending plank target.
    };
    for (supports) |support| {
        const before = readStateBlock(&state, support);
        const removal: BlockOperation = .{ .block = support, .action = .remove };
        const before_client_remove = collections.load(.monotonic);
        const rejected = client.tryOperation(removal);
        try std.testing.expectEqual(OperationStatus.constraint_violation, rejected.status);
        try std.testing.expectEqual(rules.Reason.would_remove_support, rejected.failure.?.reason);
        try std.testing.expectEqual(before_client_remove + 1, collections.load(.monotonic));
        const before_authority_remove = collections.load(.monotonic);
        const actual = try state.tryApplyOperation(a, removal);
        defer actual.chunk.deinit(a);
        try std.testing.expectEqualDeep(rejected, actual.diagnostics);
        try std.testing.expectEqual(before_authority_remove + 1, collections.load(.monotonic));
        try std.testing.expectEqual(before, readStateBlock(&state, support));
        try std.testing.expectEqual(before, client.reader().get(.{ support[0], support[1], support[2] }).?);
        try std.testing.expectEqual(@as(usize, 0), client.pending_operations.items.len);
        try std.testing.expectEqual(@as(u32, 64), state.blueprints.instances.get(1).?.remaining);
        try std.testing.expectEqual(@as(u32, 64), client.blueprints.instances.get(1).?.remaining);
        try std.testing.expectEqual(rules.BlockType.planks, state.blueprints.targetAt(.{ 24, 24, 70 }).?.material);
        try std.testing.expectEqual(rules.BlockType.planks, client.blueprints.targetAt(.{ 24, 24, 70 }).?.material);
    }
}

test "ordinary authority and client converge when roads form beneath real and pending overhead roads" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |planned| {
        var fixture: BlueprintRoadFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const state = &fixture.service.worker_state;
        // This fixture normally fulfills the low endpoint; exercise an ordinary
        // endpoint command here, while optionally retaining a separate overhead site.
        state.blueprints.deinit(a);
        state.blueprints = .{};
        const coords: ChunkCoords = .{ 0, 0, 2 };
        const id = test_layout.encodeChunkCoords(coords);
        const overhead = [3]u32{ 12, 10, 71 };
        if (planned) {
            try installFulfillmentTestSite(state, a, overhead, .{ 1, 1, 1 }, &.{.country_road_solid});
        } else {
            const chunk = state.modified_chunks.getPtr(id).?;
            try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 12, 10, 7 }, .{ .put = .country_road_solid }));
            try chunk.metadata.tryMarkConstructed(a, transformations.index(.{ 12, 10, 7 }));
        }
        // Outside the ordinary endpoint window, inside the old shape-change halo.
        const distant: ChunkCoords = .{ @intCast(test_layout.size_in_chunks[0] - 1), 0, 2 };
        var unrelated = WorldChunk.initEmpty();
        try std.testing.expectEqual(OperationStatus.success, try unrelated.tryApply(a, .{ 16, 10, 6 }, .{ .put = .planks }));
        try unrelated.metadata.tryMarkConstructed(a, transformations.index(.{ 16, 10, 6 }));
        try state.modified_chunks.put(a, test_layout.encodeChunkCoords(distant), unrelated);
        var client = try world_module.World.init(a, &test_layout);
        defer client.deinit();
        var chunks = state.modified_chunks.iterator();
        while (chunks.next()) |entry| try client.insertChunk(test_layout.decodeChunkId(entry.key_ptr.*), try entry.value_ptr.tryClone(a));
        if (planned) try client.applyBlueprintChanges(&.{ .{ .definition = state.blueprints.definitions.get(1).? }, .{ .instance = state.blueprints.instances.get(1).? } });
        const operation: BlockOperation = .{ .block = .{ 15, 10, 69 }, .action = .{ .put = .country_road_solid } };
        try std.testing.expectEqual(OperationStatus.success, client.tryOperation(operation).status);
        client.pending_operations.items[0].request_id = 1;
        const result = try state.tryApplyOperation(a, operation);
        defer result.chunk.deinit(a);
        try std.testing.expectEqual(OperationStatus.success, result.status);
        try std.testing.expectEqual(@as(u64, 1), state.ordinary_validation_calls);
        client.acknowledgeOperation(1);
        try client.insertChunk(coords, try result.chunk.tryClone(a));
        try std.testing.expectEqual(@as(usize, 0), client.pending_operations.items.len);
        const authoritative = state.modified_chunks.get(id).?;
        const received = client.getChunk(coords).?;
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&authoritative.content.blocks.blocks), std.mem.asBytes(&received.content.blocks.blocks));
        try std.testing.expectEqualSlices(@import("road_data.zig").Road, authoritative.metadata.roads.items, received.metadata.roads.items);
        for (11..15) |x| try std.testing.expect(client.customShape(.{ @intCast(x), 10, 70 }).? == .slope);
        if (planned) {
            try std.testing.expectEqual(@as(u32, 1), state.blueprints.instances.get(1).?.remaining);
            try std.testing.expectEqual(@as(u32, 1), client.blueprints.instances.get(1).?.remaining);
            try std.testing.expect(state.blueprints.targetAt(overhead) != null);
            try std.testing.expect(client.blueprints.targetAt(overhead) != null);
        } else try std.testing.expectEqual(rules.BlockType.country_road_solid, received.content.getBlock(.{ 12, 10, 7 }));
    }
}

test "road queue capacity rejects a fill before terrain inventory or progress changes" {
    var fixture: BlueprintRoadFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (0..blueprint_road_updates.capacity) |i| {
        var batch: blueprint_road_updates.Batch = .{};
        batch.add(@intCast(1_000_000 + i));
        try fixture.service.blueprint_road_queue.reserve(std.testing.allocator, batch);
        fixture.service.blueprint_road_queue.commit(batch);
    }
    try std.testing.expectError(error.RoadUpdatesFull, fixture.fill());
    try std.testing.expectEqual(@as(u32, 1), fixture.service.worker_state.blueprints.instances.get(1).?.remaining);
    const target = fixture.service.worker_state.modified_chunks.get(test_layout.encodeChunkCoords(.{ 0, 0, 2 })).?;
    try std.testing.expectEqual(rules.BlockType.none, target.content.getBlock(.{ 15, 10, 5 }));
    try std.testing.expect(fixture.service.worker_state.blueprints.targetAt(.{ 15, 10, 69 }) != null);
}

test "blueprint singleton journal limits reject before publication or an empty drain" {
    for ([_]blueprint_wire.Limits{ .{ .max_operations = 0 }, .{ .max_changes_bytes = 12 }, .{ .max_cells = 0 } }) |limits| {
        var fixture: BlueprintSaveFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var store: storage.Store = undefined;
        store.limits = .{ .blueprints = limits };
        fixture.service.store = &store;
        fixture.service.saveBlueprint(try fixture.request(1));
        var replies: std.ArrayList(BlueprintResult) = .empty;
        defer replies.deinit(std.testing.allocator);
        fixture.client.takeBlueprintResults(&replies);
        try std.testing.expectEqual(@as(usize, 1), replies.items.len);
        try std.testing.expectEqual(.resource_exhausted, replies.items[0].status);
        try std.testing.expectEqual(@as(u32, 0), fixture.service.worker_state.blueprints.definitions.count());
        try std.testing.expectEqual(@as(usize, 0), fixture.service.blueprint_journal.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.service.pending.len);
        try std.testing.expectEqual(null, fixture.service.job);
    }
}

test "small encoder queues retain journal admission when working memory is available" {
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var store: storage.Store = undefined;
    store.limits = .{};
    fixture.service.store = &store;
    fixture.service.limits.output_bytes = 33_000;
    fixture.service.saveBlueprint(try fixture.request(1));
    try std.testing.expectEqual(@as(u32, 1), fixture.service.worker_state.blueprints.definitions.count());
    try std.testing.expectEqual(@as(usize, 1), fixture.service.blueprint_journal.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.service.blueprint_journal_summary.operation_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.service.pending.len);
}

const BlueprintJournalBudgetTest = struct {
    fn allowance(service: *WorldDataService, wanted: usize) !void {
        // Choose the smallest configured budget admitting this much journal
        // space; the production overhead calculation remains the oracle.
        var low: usize = 0;
        var high: usize = 64 * 1024 * 1024;
        service.limits.working_bytes = high;
        if (try service.blueprintJournalAllowance() < wanted) return error.TestBudgetTooLarge;
        while (low < high) {
            const middle = low + (high - low) / 2;
            service.limits.working_bytes = middle;
            if (try service.blueprintJournalAllowance() >= wanted) high = middle else low = middle + 1;
        }
        service.limits.working_bytes = low;
        try std.testing.expectEqual(wanted, try service.blueprintJournalAllowance());
    }

    fn seed(fixture: *BlueprintSaveFixture) !void {
        const a = fixture.service.allocator;
        const service = &fixture.service;
        service.worker_state.persistence_service = service;
        var chunk = WorldChunk.initEmpty();
        var owns_chunk = true;
        errdefer if (owns_chunk) chunk.deinit(a);
        for (10..13) |x| try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(x), 10, 5 }, .{ .put = .stone }));
        try service.worker_state.modified_chunks.put(a, test_layout.encodeChunkCoords(.{ 0, 0, 2 }), chunk);
        owns_chunk = false;
        try installFulfillmentTestSite(&service.worker_state, a, .{ 10, 10, 70 }, .{ 3, 1, 1 }, &.{ .planks, .planks, .planks });
        const definition = service.worker_state.blueprints.definitions.get(1).?;
        const instance = service.worker_state.blueprints.instances.get(1).?;
        const operations = [_]blueprint_wire.Op{
            .{ .definition = .{ .id = definition.id, .owner = definition.owner, .name = definition.name, .size = definition.definition.size, .cells = std.mem.sliceAsBytes(definition.definition.cells), .target_count = definition.definition.target_count } },
            .{ .instance = .{ .id = instance.id, .definition_id = instance.definition_id, .owner = instance.owner, .origin = instance.origin, .rotation = instance.rotation } },
        };
        for (operations) |operation| {
            try service.reserveBlueprintJournal(operation);
            service.appendBlueprintJournal(operation);
        }
        service.blueprint_library_bytes = definition.name.len + definition.definition.cells.len + 128;
        service.players.getPtr(1).?.inventory = @intFromEnum(rules.BlockType.planks);
    }

    fn fill(fixture: *BlueprintSaveFixture, request_id: u64, index: u32, material: rules.BlockType) void {
        fixture.service.processBlueprintFulfillment(.{ .client = &fixture.client, .request_id = request_id, .operation = .{
            .block = .{ 10 + index, 10, 70 },
            .action = .{ .put = material },
            .player = .{ .id = 1, .expected_sequence = 0 },
            .blueprint = .{ .instance_id = 1, .cell_index = index },
        } });
    }

    fn waitJob(service: *WorldDataService) !void {
        const io = std.testing.io;
        const deadline = persistence.now(io) + 10 * std.time.ns_per_s;
        while (service.job != null and persistence.now(io) < deadline) {
            service.drainPersistenceEvents();
            if (service.job != null) try Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(service.job == null);
        try std.testing.expectEqual(persistence.Phase.complete, service.status.phase);
    }

    fn cleanup(fixture: *BlueprintSaveFixture) void {
        fixture.service.dirty_meshes.deinit(fixture.service.allocator);
        fixture.service.blueprint_road_queue.deinit(fixture.service.allocator);
        fixture.deinit();
    }
};

test "blueprint journal fulfillment accounting never rescans its accepted prefix" {
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var store: storage.Store = undefined;
    store.limits = .{};
    fixture.service.store = &store;
    fixture.service.saveBlueprint(try fixture.request(1));
    try std.testing.expectEqual(@as(usize, 1), fixture.service.blueprint_journal.items.len);
    const original_name = fixture.service.blueprint_journal.items[0].definition.name;
    // A full prefix scan would reject this name. The immutable saved definition
    // remains valid; only this borrowed journal view is poisoned for the probe.
    fixture.service.blueprint_journal.items[0].definition.name = &.{0xff};
    defer fixture.service.blueprint_journal.items[0].definition.name = original_name;
    const operation: blueprint_wire.Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } };
    var expected = fixture.service.blueprint_journal_summary;
    try expected.addOperation(operation, 0);
    try fixture.service.reserveBlueprintJournal(operation);
    fixture.service.appendBlueprintJournal(operation);
    try std.testing.expectEqualDeep(expected, fixture.service.blueprint_journal_summary);
    try std.testing.expectEqual(@as(usize, 2), fixture.service.blueprint_journal.items.len);
}

test "blueprint journal memory backpressure preserves physical inventory and progress before retry" {
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer BlueprintJournalBudgetTest.cleanup(&fixture);
    var store: storage.Store = undefined;
    store.limits = .{};
    fixture.service.store = &store;
    try BlueprintJournalBudgetTest.seed(&fixture);
    const before = fixture.service.blueprint_journal_summary;
    const operation: blueprint_wire.Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } };
    var one: blueprint_wire.PrepareSummary = .{};
    try one.addOperation(operation, 0);
    const one_bytes = try fixture.service.blueprintJournalMemory(one, std.ArrayList(blueprint_wire.Op).growCapacity(1));
    try BlueprintJournalBudgetTest.allowance(&fixture.service, one_bytes + 128);
    // An existing writer makes the deferred command wait instead of starting
    // I/O against this deliberately minimal Store fixture.
    var job: persistence.Job = undefined;
    fixture.service.job = &job;
    defer fixture.service.job = null;
    BlueprintJournalBudgetTest.fill(&fixture, 1, 0, .planks);
    try std.testing.expect(fixture.service.operation_deferred);
    try std.testing.expectEqual(@as(usize, 1), fixture.service.pending.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.client.pending.responses.items.len);
    try std.testing.expectEqualDeep(before, fixture.service.blueprint_journal_summary);
    try std.testing.expectEqual(@as(u32, 3), fixture.service.worker_state.blueprints.instances.get(1).?.remaining);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(rules.BlockType.planks)), fixture.service.players.get(1).?.inventory);
    const chunk = fixture.service.worker_state.modified_chunks.get(test_layout.encodeChunkCoords(.{ 0, 0, 2 })).?;
    try std.testing.expectEqual(rules.BlockType.none, chunk.content.getBlock(.{ 10, 10, 6 }));
    try std.testing.expectEqual(@as(u64, 0), fixture.service.worker_state.blueprint_fulfillment_attempts);
}

test "blueprint journal reservations include old new growth and the in flight encoded prefix" {
    const a = std.testing.allocator;
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var store: storage.Store = undefined;
    store.limits = .{};
    fixture.service.store = &store;
    const capacity = 32 * 1024;
    try fixture.service.blueprint_journal.ensureTotalCapacityPrecise(a, capacity);
    for (0..capacity) |index| fixture.service.appendBlueprintJournal(.{ .fulfill = .{ .instance_id = 1, .cell_index = @intCast(index) } });
    const operation: blueprint_wire.Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = capacity } };
    var next = fixture.service.blueprint_journal_summary;
    try next.addOperation(operation, 0);
    const next_capacity = std.ArrayList(blueprint_wire.Op).growCapacity(capacity + 1);
    const growth_peak = (capacity + next_capacity) * @sizeOf(blueprint_wire.Op);
    try std.testing.expect(growth_peak > try fixture.service.blueprintJournalMemory(next, next_capacity));
    try BlueprintJournalBudgetTest.allowance(&fixture.service, growth_peak - 1);
    try std.testing.expectError(error.JournalBackpressure, fixture.service.reserveBlueprintJournal(operation));
    try std.testing.expectEqual(@as(usize, capacity), fixture.service.blueprint_journal.capacity);
    try std.testing.expectEqual(@as(usize, capacity), fixture.service.blueprint_journal.items.len);
    try BlueprintJournalBudgetTest.allowance(&fixture.service, growth_peak);
    try fixture.service.reserveBlueprintJournal(operation);
    fixture.service.appendBlueprintJournal(operation);
    try std.testing.expectEqual(next_capacity, fixture.service.blueprint_journal.capacity);
    fixture.service.limits.working_bytes = 64 * 1024 * 1024;
    const current_bytes = next_capacity * @sizeOf(blueprint_wire.Op);
    var job: persistence.Job = undefined;
    job.blueprint_journal_reserved_bytes = capacity * @sizeOf(blueprint_wire.Op);
    job.working_reserved_bytes = fixture.service.limits.working_bytes - current_bytes + job.blueprint_journal_reserved_bytes + 1;
    fixture.service.job = &job;
    defer fixture.service.job = null;
    const before = fixture.service.blueprint_journal_summary;
    try std.testing.expectError(error.JournalBackpressure, fixture.service.reserveBlueprintJournal(operation));
    try std.testing.expectEqualDeep(before, fixture.service.blueprint_journal_summary);
    // At equality the retained encoded/prepared prefix remains charged, while
    // the old shared journal charge is replaced exactly once.
    job.working_reserved_bytes -= 1;
    try fixture.service.reserveBlueprintJournal(operation);
    fixture.service.appendBlueprintJournal(operation);
    try std.testing.expectEqual(before.operation_count + 1, fixture.service.blueprint_journal_summary.operation_count);
}

test "budgeted blueprint writer drains prefixes retries fills and restores an atomic suffix" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var uuid: [16]u8 = undefined;
    std.c.arc4random_buf(&uuid, uuid.len);
    const path = try std.fmt.allocPrintSentinel(a, "/private/tmp/blueprint-memory-drain-{x}", .{uuid}, 0);
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    const dimensions: [3]u32 = .{ @intCast(test_layout.size_in_chunks[0]), @intCast(test_layout.size_in_chunks[1]), @intCast(test_layout.size_in_chunks[2]) };
    const descriptor = try format.encodeDescriptor(a, .{ .dimensions = dimensions, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
    defer a.free(descriptor);
    const global = format.encodeGlobal(0);
    var store = try storage.Store.create(a, path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{});
    var store_open = true;
    defer if (store_open) store.deinit();
    var fixture: BlueprintSaveFixture = undefined;
    try fixture.init();
    var fixture_open = true;
    defer if (fixture_open) BlueprintJournalBudgetTest.cleanup(&fixture);
    fixture.service.store = &store;
    fixture.service.limits.output_bytes = 64 * 1024;
    try BlueprintJournalBudgetTest.seed(&fixture);
    try fixture.service.blueprint_journal.ensureTotalCapacityPrecise(a, 16);
    BlueprintJournalBudgetTest.fill(&fixture, 1, 0, .planks);
    try std.testing.expectEqual(OperationStatus.success, fixture.client.pending.responses.items[0].operation.?.status);
    const prefix = fixture.service.blueprint_journal_summary;
    const source = persistence.Source.freeze(test_layout.encodeChunkCoords(.{ 0, 0, 2 }), 0, fixture.service.worker_state.modified_chunks.getPtr(test_layout.encodeChunkCoords(.{ 0, 0, 2 })).?);
    const full_capture = fixture.service.limits.output_bytes + try fixture.service.captureWorkingOverhead(1, try persistence.scratchBound(source)) + prefix.encoded_bytes + try blueprint_wire.prepareMemoryBound(prefix, store.limits.blueprints) + fixture.service.blueprint_journal.capacity * @sizeOf(blueprint_wire.Op);
    // Simulate a tighter capture budget after admission. The queue can shrink
    // by one byte while the complete atomic blueprint prefix remains intact.
    fixture.service.limits.working_bytes = full_capture - 1;
    var gate: ServiceWriteGate = .{};
    var faults: @import("persistence/io.zig").Faults = .{ .enabled = false, .context = &gate, .hook = ServiceWriteGate.hook };
    store.setFaults(&faults);
    defer gate.released.set(io);
    try fixture.service.beginCapture(101, false);
    try std.testing.expectEqual(fixture.service.limits.output_bytes - 1, fixture.service.job.?.limits.output_bytes);
    try std.testing.expect(fixture.service.job.?.working_reserved_bytes <= fixture.service.limits.working_bytes);
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    const released_deadline = persistence.now(io) + 5 * std.time.ns_per_s;
    while (fixture.service.source_holds.count() != 0 and persistence.now(io) < released_deadline) {
        fixture.service.drainPersistenceEvents();
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u32, 0), fixture.service.source_holds.count());
    fixture.service.limits.working_bytes = 64 * 1024 * 1024;
    fixture.service.players.getPtr(1).?.inventory = @intFromEnum(rules.BlockType.planks);
    BlueprintJournalBudgetTest.fill(&fixture, 2, 1, .planks);
    try std.testing.expectEqual(OperationStatus.success, fixture.client.pending.responses.items[1].operation.?.status);
    fixture.service.players.getPtr(1).?.inventory = @intFromEnum(rules.BlockType.planks);
    const accepted_suffix = fixture.service.blueprint_journal_summary;
    BlueprintJournalBudgetTest.fill(&fixture, 3, 2, .sand);
    try std.testing.expectEqual(OperationStatus.inventory_mismatch, fixture.client.pending.responses.items[2].operation.?.status);
    try std.testing.expectEqualDeep(accepted_suffix, fixture.service.blueprint_journal_summary);
    const fill_last: blueprint_wire.Op = .{ .fulfill = .{ .instance_id = 1, .cell_index = 2 } };
    var one: blueprint_wire.PrepareSummary = .{};
    try one.addOperation(fill_last, 0);
    try BlueprintJournalBudgetTest.allowance(&fixture.service, (try fixture.service.blueprintJournalMemory(one, std.ArrayList(blueprint_wire.Op).growCapacity(1))) + 128);
    BlueprintJournalBudgetTest.fill(&fixture, 4, 2, .planks);
    try std.testing.expect(fixture.service.operation_deferred);
    try std.testing.expectEqual(@as(usize, 1), fixture.service.pending.len);
    try std.testing.expectEqualDeep(accepted_suffix, fixture.service.blueprint_journal_summary);
    try std.testing.expectEqual(@as(u32, 1), fixture.service.worker_state.blueprints.instances.get(1).?.remaining);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(rules.BlockType.planks)), fixture.service.players.get(1).?.inventory);
    try std.testing.expectEqual(rules.BlockType.none, fixture.service.worker_state.modified_chunks.get(source.id).?.content.getBlock(.{ 12, 10, 6 }));
    fixture.service.limits.working_bytes = 64 * 1024 * 1024;
    gate.released.set(io);
    try BlueprintJournalBudgetTest.waitJob(&fixture.service);
    try std.testing.expectEqual(@as(usize, 0), fixture.service.pending.len);
    try std.testing.expectEqual(OperationStatus.success, fixture.client.pending.responses.items[3].operation.?.status);
    try std.testing.expectEqual(@as(u32, 2), store.blueprints.instances.get(1).?.remaining);
    try std.testing.expectEqual(@as(u32, 0), fixture.service.worker_state.blueprints.instances.get(1).?.remaining);
    var suffix: blueprint_wire.PrepareSummary = .{};
    try suffix.addOperation(.{ .fulfill = .{ .instance_id = 1, .cell_index = 1 } }, 0);
    try suffix.addOperation(fill_last, 0);
    try std.testing.expectEqualDeep(suffix, fixture.service.blueprint_journal_summary);
    try std.testing.expectEqual(@as(usize, 2), fixture.service.blueprint_journal.items.len);
    try std.testing.expect(fixture.service.blueprint_journal.capacity >= 16);
    try fixture.service.beginCapture(102, true);
    try BlueprintJournalBudgetTest.waitJob(&fixture.service);
    try std.testing.expectEqualDeep(blueprint_wire.PrepareSummary{}, fixture.service.blueprint_journal_summary);
    try std.testing.expectEqual(@as(usize, 0), fixture.service.blueprint_journal.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.service.blueprint_journal.capacity);
    try std.testing.expectEqual(@as(u32, 0), store.blueprints.instances.count());
    try std.testing.expectEqual(@as(?u8, null), fixture.service.players.get(1).?.inventory);
    store.setFaults(null);
    BlueprintJournalBudgetTest.cleanup(&fixture);
    fixture_open = false;
    store.deinit();
    store_open = false;
    store = try storage.Store.open(a, path, .{});
    store_open = true;
    try std.testing.expectEqual(@as(u64, 2), store.sequence);
    try std.testing.expectEqual(@as(u32, 1), store.blueprints.definitions.count());
    try std.testing.expectEqual(@as(u32, 0), store.blueprints.instances.count());
    try std.testing.expectEqual(@as(u64, 1), store.blueprints.max_instance_id);
    const player = try format.decodePlayer(store.players);
    try std.testing.expectEqual(@as(?u8, null), player.inventory);
    const encoded = (try store.readChunk(a, source.id)).?;
    defer a.free(encoded);
    var restored = try format.decodeChunk(a, store.world_uuid, encoded, dimensions);
    defer restored.deinit(a);
    for (10..13) |x| try std.testing.expectEqual(@intFromEnum(rules.BlockType.planks), restored.blocks[transformations.index(.{ @intCast(x), 10, 6 })]);
}

const PreparedBlueprintDrainTest = struct {
    const chunk_id = test_layout.encodeChunkCoords(.{ 0, 0, 2 });
    const dimensions: [3]u32 = .{ @intCast(test_layout.size_in_chunks[0]), @intCast(test_layout.size_in_chunks[1]), @intCast(test_layout.size_in_chunks[2]) };
    path: [:0]u8,
    store: storage.Store,
    store_open: bool = false,
    fixture: BlueprintSaveFixture,
    fixture_open: bool = false,

    fn init(self: *@This()) !void {
        const a = std.testing.allocator;
        var uuid: [16]u8 = undefined;
        std.c.arc4random_buf(&uuid, uuid.len);
        self.path = try std.fmt.allocPrintSentinel(a, "/private/tmp/blueprint-prepared-drain-{x}", .{uuid}, 0);
        errdefer a.free(self.path);
        errdefer std.Io.Dir.cwd().deleteTree(std.testing.io, self.path) catch {};
        const descriptor = try format.encodeDescriptor(a, .{ .dimensions = dimensions, .generator_id = 2, .seed = 0, .settings = &format.flat_settings });
        defer a.free(descriptor);
        const global = format.encodeGlobal(0);
        self.store = try storage.Store.create(a, self.path, .{ .world_uuid = uuid, .descriptor = descriptor, .global = &global, .players = &.{}, .player_count = 0 }, .{ .blueprints = .{ .max_operations = 1 } });
        self.store_open = true;
        errdefer self.store.deinit();
        try self.fixture.init();
        self.fixture_open = true;
        errdefer self.cleanupFixture();
        self.fixture.service.store = &self.store;
        self.fixture.service.worker_state.persistence_service = &self.fixture.service;
        // Keep these tests small while retaining the real encoder and writer.
        self.fixture.service.limits.output_bytes = 64 * 1024;
        self.fixture.service.saveBlueprint(try self.fixture.request(1));
    }

    fn cleanupFixture(self: *@This()) void {
        if (!self.fixture_open) return;
        const service = &self.fixture.service;
        const a = std.testing.allocator;
        service.allocator = a;
        if (service.blueprint_task) |task| {
            service.blueprint_task = null;
            if (task.future) |*future| future.await(service.io);
            if (!task.retired.load(.acquire)) task.release();
            a.destroy(task);
        }
        for (service.blueprint_retired.items) |task| {
            if (task.future) |*future| future.await(service.io);
            if (!task.retired.load(.acquire)) task.release();
            a.destroy(task);
        }
        service.blueprint_retired.deinit(a);
        BlueprintJournalBudgetTest.cleanup(&self.fixture);
        self.fixture_open = false;
    }

    fn deinit(self: *@This()) void {
        self.cleanupFixture();
        if (self.store_open) self.store.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.path) catch {};
        std.testing.allocator.free(self.path);
    }

    fn prepare(self: *@This()) !*BlueprintAdmissionTask {
        const a = std.testing.allocator;
        const service = &self.fixture.service;
        var chunk = WorldChunk.initEmpty();
        var owns_chunk = true;
        defer if (owns_chunk) chunk.deinit(a);
        const data = try chunk.tryEnsureData(a);
        for (0..6) |z| @memset(std.mem.asBytes(&data.blocks[z]), @intFromEnum(rules.BlockType.stone));
        chunk.chunk_revision = 1;
        try service.worker_state.modified_chunks.put(a, chunk_id, chunk);
        owns_chunk = false;
        const state = &service.worker_state.blueprints;
        var instance = try state.prepareInstance(a, &test_layout, 1, 1, 1, .{ 10, 10, 70 }, 0);
        var owns_instance = true;
        defer if (owns_instance) instance.deinit(a);
        const task = try a.create(BlueprintAdmissionTask);
        errdefer a.destroy(task);
        const ids = try a.dupe(ChunkId, &.{chunk_id});
        task.* = .{
            .service = service,
            .request = .{ .client = &self.fixture.client, .request_id = 2, .owner = 1, .definition_id = 1, .origin = .{ 10, 10, 70 }, .rotation = 0 },
            .snapshot = .{ .layout = test_layout, .overlay_revision = state.revision, .playable_y_inset = service.worker_state.generator.playableYInset() },
            .definition = state.definitions.get(1).?.definition,
            .instance = instance,
            .client_count = service.clients.items.len,
            .chunk_ids = ids,
            .cursor = ids.len,
        };
        owns_instance = false;
        errdefer task.release();
        try service.copyBlueprintDependency(task, chunk_id);
        task.result = try task.prepare();
        try std.testing.expect((try task.result.?) == .prepared);
        try service.blueprint_retired.ensureUnusedCapacity(a, 1);
        service.blueprint_task = task;
        return task;
    }

    fn expectWaiting(self: *@This(), task: *BlueprintAdmissionTask, intent: u64, fence: usize, err: anyerror, automatic_retry: bool) !void {
        const service = &self.fixture.service;
        try std.testing.expect(service.blueprint_task == task);
        try std.testing.expect(task.waiting_for_journal);
        try std.testing.expect(service.job == null);
        try std.testing.expect(service.lifecycle.active == null);
        try std.testing.expectEqual(intent, service.lifecycle.queued.?.intent.id);
        try std.testing.expectEqual(intent, service.status.intent_id);
        try std.testing.expectEqual(@as(u64, 0), service.status.target_sequence);
        try std.testing.expectEqual(persistence.Phase.failed, service.status.phase);
        try std.testing.expectEqualStrings(@errorName(err), service.status.error_name.?);
        try std.testing.expectEqual(automatic_retry, service.status.active);
        try std.testing.expectEqual(fence, service.lifecycle.queued.?.fence_remaining);
        try std.testing.expectEqual(@as(u32, 0), service.worker_state.blueprints.instances.count());
        try std.testing.expectEqual(@as(u64, 0), service.worker_state.blueprints.max_instance_id);
        try std.testing.expectEqual(@as(u64, 1), self.fixture.client.resolved_request);
        try std.testing.expectEqual(@as(usize, 1), service.blueprint_journal.items.len);
        try std.testing.expectEqual(@as(u64, 0), service.worker_state.blueprint_fulfillment_attempts);
        try std.testing.expectEqual(rules.BlockType.none, service.worker_state.modified_chunks.get(chunk_id).?.content.getBlock(.{ 10, 10, 6 }));
        try std.testing.expectEqual(@as(?u8, null), service.players.get(1).?.inventory);
        try std.testing.expectEqual(@as(usize, 1), self.fixture.client.blueprint_results.items.items.len);
    }

    fn expectNoOrdinaryRetry(self: *@This()) !void {
        const service = &self.fixture.service;
        const next = service.next_intent.load(.monotonic);
        const progress = service.status.progress_generation;
        const fence = service.lifecycle.queued.?.fence_remaining;
        for (0..4) |_| {
            service.advanceBlueprintAdmission();
            service.retryPending();
            service.checkWatchdog();
        }
        try std.testing.expectEqual(next, service.next_intent.load(.monotonic));
        try std.testing.expectEqual(progress, service.status.progress_generation);
        try std.testing.expectEqual(fence, service.lifecycle.queued.?.fence_remaining);
    }

    fn waitSave(self: *@This(), intent: u64) !void {
        const service = &self.fixture.service;
        const end = persistence.now(std.testing.io) + 10 * std.time.ns_per_s;
        while (persistence.now(std.testing.io) < end) {
            service.drainPersistenceEvents();
            if (service.status.intent_id == intent and !service.status.active and service.status.phase == .complete) break;
            try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(service.blueprint_task == null);
        try std.testing.expect(service.job == null);
        try std.testing.expect(service.lifecycle.active == null);
        try std.testing.expect(service.lifecycle.queued == null);
        try std.testing.expectEqual(intent, service.status.intent_id);
        try std.testing.expectEqual(persistence.Phase.complete, service.status.phase);
        try std.testing.expect(!service.status.active);
        try std.testing.expectEqual(@as(usize, 0), service.pending.len);
    }

    fn reopen(self: *@This(), definitions: u32, instance: bool) !void {
        self.cleanupFixture();
        self.store.deinit();
        self.store_open = false;
        self.store = try storage.Store.open(std.testing.allocator, self.path, .{});
        self.store_open = true;
        try std.testing.expectEqual(definitions, self.store.blueprints.definitions.count());
        try std.testing.expectEqual(@as(u32, if (instance) 1 else 0), self.store.blueprints.instances.count());
        if (instance) {
            const restored_instance = self.store.blueprints.instances.get(1).?;
            try std.testing.expectEqual(@as(u64, 1), restored_instance.definition_id);
            try std.testing.expectEqual(@as(u32, 1), restored_instance.remaining);
        }
        const bytes = (try self.store.readChunk(std.testing.allocator, chunk_id)).?;
        defer std.testing.allocator.free(bytes);
        var restored = try format.decodeChunk(std.testing.allocator, self.store.world_uuid, bytes, dimensions);
        defer restored.deinit(std.testing.allocator);
        try std.testing.expectEqual(@intFromEnum(rules.BlockType.stone), restored.blocks[transformations.index(.{ 10, 10, 5 })]);
        try std.testing.expectEqual(@intFromEnum(rules.BlockType.none), restored.blocks[transformations.index(.{ 10, 10, 6 })]);
    }
};

test "prepared blueprint Apply retries synchronous journal drain failure before its final Save fence" {
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    const task = try f.prepare();
    service.limits.manifest_entries = 0;
    service.finishBlueprintApplication(task);
    try std.testing.expect(task.waiting_for_journal);
    // This later owned command must stay behind Apply, including through a
    // failed prefix writer and the final Save's two-command fence.
    service.processRequest(.{ .blueprint_save = try f.fixture.request(3) });
    service.requestSaveTransition(100, true);
    try f.expectWaiting(task, 100, 2, error.ManifestCapacityExceeded, false);
    try std.testing.expectEqual(@as(usize, 1), service.pending.len);
    try std.testing.expectEqual(@as(u32, 1), service.worker_state.blueprints.definitions.count());
    try std.testing.expect(service.lifecycle.queued.?.retry == .available);
    try f.expectNoOrdinaryRetry();
    service.limits.manifest_entries = 65536;
    service.requestSaveTransition(101, true);
    try std.testing.expect(service.job != null);
    try std.testing.expect(service.status.intent_id != 101);
    try std.testing.expectEqual(@as(u64, 101), service.lifecycle.queued.?.intent.id);
    try std.testing.expect(!service.lifecycle.active.?.intent.final);
    try f.waitSave(101);
    var results: std.ArrayList(BlueprintResult) = .empty;
    defer results.deinit(std.testing.allocator);
    f.fixture.client.takeBlueprintResults(&results);
    try std.testing.expectEqual(@as(usize, 3), results.items.len);
    try std.testing.expectEqual(@as(u64, 2), results.items[1].request_id);
    try std.testing.expectEqual(.apply, results.items[1].kind);
    try std.testing.expectEqual(.success, results.items[1].status);
    try std.testing.expectEqual(@as(u64, 3), results.items[2].request_id);
    try std.testing.expectEqual(.save, results.items[2].kind);
    try std.testing.expectEqual(.success, results.items[2].status);
    try std.testing.expectEqual(@as(u64, 3), f.fixture.client.resolved_request);
    try f.reopen(2, true);
}

test "prepared blueprint Apply uses one bounded watchdog retry for synchronous journal OOM" {
    for ([_]bool{ false, true }) |repeat_failure| {
        var f: PreparedBlueprintDrainTest = undefined;
        try f.init();
        defer f.deinit();
        const service = &f.fixture.service;
        const task = try f.prepare();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        service.allocator = failing.allocator();
        defer service.allocator = std.testing.allocator;
        service.finishBlueprintApplication(task);
        service.requestSaveTransition(100, true);
        try std.testing.expect(failing.has_induced_failure);
        try f.expectWaiting(task, 100, 1, error.OutOfMemory, true);
        try std.testing.expect(service.lifecycle.queued.?.retry == .scheduled);
        const deadline = service.lifecycle.queued.?.retry.scheduled;
        const prepared_blocks = task.snapshot.chunks.get(PreparedBlueprintDrainTest.chunk_id).?.blocks;
        const prepared_fulfilled = (try task.result.?).prepared.publication.instance.fulfilled.ptr;
        // Repeated dependency failures share the original deadline.
        service.retrySaveDrain();
        try std.testing.expectEqual(deadline, service.lifecycle.queued.?.retry.scheduled);
        try std.testing.expectEqual(prepared_blocks, task.snapshot.chunks.get(PreparedBlueprintDrainTest.chunk_id).?.blocks);
        try std.testing.expectEqual(prepared_fulfilled, (try task.result.?).prepared.publication.instance.fulfilled.ptr);
        try f.expectNoOrdinaryRetry();
        service.lifecycle.queued.?.retry = .{ .scheduled = persistence.now(std.testing.io) - 1 };
        if (!repeat_failure) service.allocator = std.testing.allocator;
        service.checkWatchdog();
        if (repeat_failure) {
            try f.expectWaiting(task, 100, 1, error.OutOfMemory, false);
            try std.testing.expect(service.lifecycle.queued.?.retry == .exhausted);
            // Neither another OOM nor ordinary watchdog progress replenishes
            // the consumed automatic retry. Explicit Save can still recover.
            service.retrySaveDrain();
            try std.testing.expect(service.lifecycle.queued.?.retry == .exhausted);
            try f.expectNoOrdinaryRetry();
            service.allocator = std.testing.allocator;
            service.requestSaveTransition(101, true);
        }
        try std.testing.expect(service.job != null);
        try f.waitSave(if (repeat_failure) 101 else 100);
        try std.testing.expectEqual(@as(u32, 1), service.worker_state.blueprints.instances.count());
        try std.testing.expectEqual(@as(u64, 2), f.fixture.client.resolved_request);
        try f.reopen(1, true);
    }
}

test "prepared blueprint Apply revalidates dependencies after synchronous journal drain failure" {
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    const task = try f.prepare();
    service.limits.manifest_entries = 0;
    service.finishBlueprintApplication(task);
    service.requestSaveTransition(100, true);
    try f.expectWaiting(task, 100, 1, error.ManifestCapacityExceeded, false);
    service.worker_state.modified_chunks.getPtr(PreparedBlueprintDrainTest.chunk_id).?.chunk_revision += 1;
    service.limits.manifest_entries = 65536;
    service.requestSaveTransition(101, true);
    try std.testing.expect(service.blueprint_task == null);
    try std.testing.expectEqual(@as(u32, 0), service.worker_state.blueprints.instances.count());
    try std.testing.expectEqual(@as(u64, 2), f.fixture.client.resolved_request);
    try f.waitSave(101);
    var results: std.ArrayList(BlueprintResult) = .empty;
    defer results.deinit(std.testing.allocator);
    f.fixture.client.takeBlueprintResults(&results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(@as(u64, 2), results.items[1].request_id);
    try std.testing.expectEqual(.stale, results.items[1].status);
    try f.reopen(1, false);
}

test "wrapped retained edits validate in order and Save freezes only its selected prefix" {
    const a = std.testing.allocator;
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    const client = &f.fixture.client;
    const id = PreparedBlueprintDrainTest.chunk_id;
    const block: [3]u32 = .{ 10, 10, 70 };
    var chunk = WorldChunk.initEmpty();
    try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 10, 10, 5 }, .{ .put = .stone }));
    chunk.chunk_revision = 1;
    try service.worker_state.modified_chunks.put(a, id, chunk);
    try service.pending.ensureTotalCapacityPrecise(a, 4);
    // Three actual conflict results advance the ring without changing terrain.
    for (2..5) |request_id| {
        try service.source_holds.put(a, id, 1);
        service.processRequest(.{ .operation = .{ .client = client, .request_id = request_id, .operation = .{ .block = block, .action = .remove } } });
        try std.testing.expect(service.source_holds.remove(id));
        service.retryPending();
    }
    try service.source_holds.put(a, id, 1);
    for (5..7) |request_id| service.processRequest(.{ .operation = .{ .client = client, .request_id = request_id, .operation = .{ .block = block, .action = .{ .put = .snow } } } });
    service.requestSaveTransition(100, false);
    try std.testing.expectEqual(@as(usize, 2), service.lifecycle.queued.?.fence_remaining);
    // This later Remove must observe the preceding Put, but belongs after Save.
    service.processRequest(.{ .operation = .{ .client = client, .request_id = 7, .operation = .{ .block = block, .action = .remove } } });
    try std.testing.expect(service.pending.head + service.pending.len > service.pending.buffer.len);
    try std.testing.expect(service.source_holds.remove(id));
    service.retryPending();
    try f.waitSave(100);
    try std.testing.expectEqual(@as(usize, 0), service.pending.len);
    const replies = client.pending.responses.items;
    try std.testing.expectEqual(@as(usize, 6), replies.len);
    const statuses = [_]OperationStatus{ .already_removed, .already_removed, .already_removed, .success, .already_exists, .success };
    for (replies, statuses, 2..) |reply, expected, request_id| {
        try std.testing.expectEqual(request_id, reply.operation.?.request_id);
        try std.testing.expectEqual(expected, reply.operation.?.status);
    }
    try std.testing.expectEqual(rules.BlockType.none, service.worker_state.modified_chunks.get(id).?.content.getBlock(.{ 10, 10, 6 }));
    // Install the committed WAL prefix without capturing the later live edit.
    try f.store.compact();
    const encoded = (try f.store.readChunk(a, id)).?;
    defer a.free(encoded);
    var saved = try format.decodeChunk(a, f.store.world_uuid, encoded, f.store.dimensions);
    defer saved.deinit(a);
    try std.testing.expectEqual(@intFromEnum(rules.BlockType.snow), saved.blocks[transformations.index(.{ 10, 10, 6 })]);
}

test "coalesced ordinary Save retries a prepared blueprint without widening its original fence" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Submit = struct {
        fn ordinary(service: *WorldDataService) !u64 {
            const id = service.requestSave(false);
            var requests: std.ArrayList(Request) = .empty;
            defer requests.deinit(std.testing.allocator);
            service.requests.takeAll(service.io, &requests);
            try std.testing.expectEqual(@as(usize, 1), requests.items.len);
            try std.testing.expectEqual(id, requests.items[0].save.id);
            try std.testing.expect(!requests.items[0].save.final);
            service.processRequest(requests.items[0]);
            return id;
        }
    };
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    defer service.read_failed.deinit(a);
    const task = try f.prepare();
    const prepared_blocks = task.snapshot.chunks.get(PreparedBlueprintDrainTest.chunk_id).?.blocks;
    const prepared_fulfilled = (try task.result.?).prepared.publication.instance.fulfilled.ptr;
    service.limits.manifest_entries = 0;
    service.finishBlueprintApplication(task);
    const original = try Submit.ordinary(service);
    try f.expectWaiting(task, original, 1, error.ManifestCapacityExceeded, false);
    try std.testing.expect(!service.lifecycle.queued.?.intent.final);
    // This command arrived after the ordinary Save selected its prefix. A
    // coalesced retry must wake Apply without moving this later command into it.
    service.processRequest(.{ .blueprint_save = try f.fixture.request(3) });
    for (0..3) |_| {
        const next = service.next_intent.load(.monotonic);
        const progress = service.status.progress_generation;
        const retry = try Submit.ordinary(service);
        try std.testing.expect(retry != original);
        // One public request identity and one attempted internal prefix writer.
        try std.testing.expectEqual(next + 2, service.next_intent.load(.monotonic));
        try std.testing.expectEqual(progress + 1, service.status.progress_generation);
        try f.expectWaiting(task, original, 1, error.ManifestCapacityExceeded, false);
        try std.testing.expectEqual(@as(usize, 1), service.pending.len);
        try std.testing.expectEqual(@as(u64, 3), service.pending.frontPtr().?.request.blueprint_save.request_id);
        try std.testing.expectEqual(prepared_blocks, task.snapshot.chunks.get(PreparedBlueprintDrainTest.chunk_id).?.blocks);
        try std.testing.expectEqual(prepared_fulfilled, (try task.result.?).prepared.publication.instance.fulfilled.ptr);
        try std.testing.expect(service.lifecycle.queued.?.retry == .available);
    }
    try f.expectNoOrdinaryRetry();
    var gate: ServiceWriteGate = .{};
    var faults: @import("persistence/io.zig").Faults = .{ .enabled = false, .context = &gate, .hook = ServiceWriteGate.hook };
    f.store.setFaults(&faults);
    // This defer precedes fixture cleanup even when an assertion fails while
    // the real writer is blocked in its fault hook.
    defer gate.released.set(io);
    service.limits.manifest_entries = 65536;
    const recovering = try Submit.ordinary(service);
    try std.testing.expect(recovering != original);
    try std.testing.expect(service.job != null);
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    const writer = service.job.?;
    const epoch = writer.epoch;
    const active_intent = service.status.intent_id;
    const next = service.next_intent.load(.monotonic);
    const progress = service.status.progress_generation;
    try std.testing.expect(active_intent != original);
    try std.testing.expectEqual(original, service.lifecycle.queued.?.intent.id);
    try std.testing.expectEqual(@as(usize, 1), service.lifecycle.queued.?.fence_remaining);
    // With a writer already active, coalescing is an allocation-free guard.
    // Retained dependency state must not be swept by the general retry path.
    try service.read_failed.put(a, PreparedBlueprintDrainTest.chunk_id, error.OutOfMemory);
    {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        service.allocator = failing.allocator();
        defer service.allocator = a;
        for (0..4) |index| service.requestSaveTransition(900 + index, false);
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expect(service.job == writer);
        try std.testing.expectEqual(epoch, service.job.?.epoch);
        try std.testing.expectEqual(active_intent, service.status.intent_id);
        try std.testing.expectEqual(next, service.next_intent.load(.monotonic));
        try std.testing.expectEqual(progress, service.status.progress_generation);
        try std.testing.expectEqual(original, service.lifecycle.queued.?.intent.id);
        try std.testing.expectEqual(@as(usize, 1), service.lifecycle.queued.?.fence_remaining);
        try std.testing.expectEqual(@as(usize, 1), service.pending.len);
        try std.testing.expect(service.read_failed.contains(PreparedBlueprintDrainTest.chunk_id));
        try std.testing.expect(service.blueprint_task == task);
        try std.testing.expect(task.waiting_for_journal);
    }
    service.read_failed.clearRetainingCapacity();
    gate.released.set(io);
    try f.waitSave(original);
    f.store.setFaults(null);
    // The original Save persisted Apply's instance. The later Save command was
    // accepted only afterward and still belongs to the unsaved journal suffix.
    try std.testing.expectEqual(@as(u64, 2), f.store.sequence);
    try std.testing.expectEqual(@as(u32, 1), f.store.blueprints.definitions.count());
    try std.testing.expectEqual(@as(u32, 1), f.store.blueprints.instances.count());
    try std.testing.expectEqual(@as(u32, 2), service.worker_state.blueprints.definitions.count());
    try std.testing.expectEqual(@as(usize, 1), service.blueprint_journal.items.len);
    try std.testing.expectEqual(@as(u64, 2), service.blueprint_journal.items[0].definition.id);
    try std.testing.expectEqual(@as(u64, 3), f.fixture.client.resolved_request);
    var results: std.ArrayList(BlueprintResult) = .empty;
    defer results.deinit(a);
    f.fixture.client.takeBlueprintResults(&results);
    try std.testing.expectEqual(@as(usize, 3), results.items.len);
    try std.testing.expectEqual(@as(u64, 2), results.items[1].request_id);
    try std.testing.expectEqual(.success, results.items[1].status);
    try std.testing.expectEqual(@as(u64, 3), results.items[2].request_id);
    try std.testing.expectEqual(.success, results.items[2].status);
    try f.reopen(1, true);
}

const AsyncBlueprintPrefixTest = struct {
    const RearmedWriteFailure = struct {
        armed: std.atomic.Value(bool) = .init(true),
        injected: std.atomic.Value(u32) = .init(0),
        remaining: u8 = 4,
        faults: @import("persistence/io.zig").Faults = .{ .operation = .write, .enabled = false },

        fn hook(context: ?*anyopaque, operation: @import("persistence/io.zig").Operation) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (operation != .write) return;
            self.faults.enabled = false;
            if (!self.armed.load(.acquire) or self.remaining == 0) return;
            self.remaining -= 1;
            _ = self.injected.fetchAdd(1, .acq_rel);
            // Faults normally disables itself after one failure. Rearm only
            // from its writer-thread hook and keep the script bounded.
            self.faults.observed = 0;
            self.faults.after = 0;
            self.faults.enabled = true;
        }
    };

    const Completion = struct { failure: ?anyerror, committed: bool };

    fn finishOne(service: *WorldDataService) !Completion {
        const job = service.job orelse return error.MissingPrefixWriter;
        const epoch = job.epoch;
        job.writer.await(service.io);
        var committed = false;
        // Process exactly this writer's terminal event. A broken completion
        // policy may start a replacement; the assertion can catch it without
        // following a restart loop or depending on thread scheduling.
        for (0..8) |_| {
            service.requests.mutex.lockUncancelable(service.io);
            if (service.completion_count == 0) {
                service.requests.mutex.unlock(service.io);
                return error.MissingPrefixCompletion;
            }
            const event = service.completion_ring.items[service.completion_head];
            service.completion_head = (service.completion_head + 1) % service.completion_ring.items.len;
            service.completion_count -= 1;
            service.requests.mutex.unlock(service.io);
            if (event == .committed and event.committed == epoch) committed = true;
            service.persistenceEvent(event);
            if (event == .finished and event.finished.epoch == epoch) return .{ .failure = event.finished.failure, .committed = committed };
        }
        return error.MissingPrefixCompletion;
    }

    fn expectSleeping(f: *PreparedBlueprintDrainTest) !void {
        const epoch = f.fixture.service.capture_epoch;
        try f.expectNoOrdinaryRetry();
        try std.testing.expect(f.fixture.service.job == null);
        try std.testing.expectEqual(epoch, f.fixture.service.capture_epoch);
    }
};

test "failed ordinary and canceled final blueprint prefixes wait for explicit Save retry" {
    for ([_]bool{ false, true }) |cancel_prefix| {
        var f: PreparedBlueprintDrainTest = undefined;
        try f.init();
        defer f.deinit();
        const service = &f.fixture.service;
        const task = try f.prepare();
        const blocks = task.snapshot.chunks.get(PreparedBlueprintDrainTest.chunk_id).?.blocks;
        const fulfilled = (try task.result.?).prepared.publication.instance.fulfilled.ptr;
        var failure: AsyncBlueprintPrefixTest.RearmedWriteFailure = .{};
        failure.faults.context = &failure;
        failure.faults.hook = AsyncBlueprintPrefixTest.RearmedWriteFailure.hook;
        var gate: ServiceWriteGate = .{};
        var cancellation_faults: @import("persistence/io.zig").Faults = .{ .enabled = false, .context = &gate, .hook = ServiceWriteGate.hook };
        f.store.setFaults(if (cancel_prefix) &cancellation_faults else &failure.faults);
        defer gate.released.set(std.testing.io);
        service.finishBlueprintApplication(task);
        if (cancel_prefix) service.processRequest(.{ .blueprint_save = try f.fixture.request(3) });
        service.requestSaveTransition(100, cancel_prefix);
        // The ordinary case excludes a later command; the canceled final Save
        // already includes both commands in its original fence.
        if (!cancel_prefix) service.processRequest(.{ .blueprint_save = try f.fixture.request(3) });
        if (cancel_prefix) {
            try gate.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
            // The single source fits the queue. Complete encoding first so the
            // cancellation deterministically fails footer authorization.
            service.job.?.encoder.await(std.testing.io);
            service.job.?.cancel();
            gate.released.set(std.testing.io);
        }
        const epoch = service.capture_epoch;
        const next = service.next_intent.load(.monotonic);
        const completion = try AsyncBlueprintPrefixTest.finishOne(service);
        try std.testing.expect(!completion.committed);
        try std.testing.expectEqual(if (cancel_prefix) error.Cancelled else error.Io, completion.failure.?);
        try f.expectWaiting(task, 100, if (cancel_prefix) 2 else 1, completion.failure.?, false);
        try std.testing.expectEqual(epoch, service.capture_epoch);
        try std.testing.expectEqual(next, service.next_intent.load(.monotonic));
        try std.testing.expectEqual(@as(u64, 0), f.store.sequence);
        try std.testing.expect(service.lifecycle.queued.?.retry == .available);
        try std.testing.expectEqual(@as(usize, 1), service.pending.len);
        try std.testing.expectEqual(blocks, task.snapshot.chunks.get(PreparedBlueprintDrainTest.chunk_id).?.blocks);
        try std.testing.expectEqual(fulfilled, (try task.result.?).prepared.publication.instance.fulfilled.ptr);
        try AsyncBlueprintPrefixTest.expectSleeping(&f);
        failure.armed.store(false, .release);
        f.store.setFaults(null);
        service.requestSaveTransition(101, false);
        try std.testing.expect(service.job != null);
        try std.testing.expectEqual(@as(u64, 100), service.lifecycle.queued.?.intent.id);
        try f.waitSave(100);
        try std.testing.expectEqual(@as(u32, if (cancel_prefix) 2 else 1), f.store.blueprints.definitions.count());
        try std.testing.expectEqual(@as(u32, 2), service.worker_state.blueprints.definitions.count());
        try std.testing.expectEqual(@as(u64, 3), f.fixture.client.resolved_request);
        try f.reopen(if (cancel_prefix) 2 else 1, true);
    }
}

test "asynchronous blueprint prefix Io consumes one delayed final retry without restarting a loop" {
    for ([_]bool{ false, true }) |repeat_failure| {
        var f: PreparedBlueprintDrainTest = undefined;
        try f.init();
        defer f.deinit();
        const service = &f.fixture.service;
        const task = try f.prepare();
        const blocks = task.snapshot.chunks.get(PreparedBlueprintDrainTest.chunk_id).?.blocks;
        const fulfilled = (try task.result.?).prepared.publication.instance.fulfilled.ptr;
        var failure: AsyncBlueprintPrefixTest.RearmedWriteFailure = .{};
        failure.faults.context = &failure;
        failure.faults.hook = AsyncBlueprintPrefixTest.RearmedWriteFailure.hook;
        f.store.setFaults(&failure.faults);
        service.finishBlueprintApplication(task);
        service.processRequest(.{ .blueprint_save = try f.fixture.request(3) });
        service.requestSaveTransition(100, true);
        const epoch = service.capture_epoch;
        const next = service.next_intent.load(.monotonic);
        const initial = try AsyncBlueprintPrefixTest.finishOne(service);
        try std.testing.expect(!initial.committed);
        try std.testing.expectEqual(error.Io, initial.failure.?);
        try f.expectWaiting(task, 100, 2, error.Io, true);
        try std.testing.expect(service.lifecycle.queued.?.retry == .scheduled);
        try std.testing.expectEqual(epoch, service.capture_epoch);
        try std.testing.expectEqual(next, service.next_intent.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 1), failure.injected.load(.acquire));
        try AsyncBlueprintPrefixTest.expectSleeping(&f);
        if (!repeat_failure) {
            failure.armed.store(false, .release);
            f.store.setFaults(null);
        }
        service.lifecycle.queued.?.retry = .{ .scheduled = persistence.now(std.testing.io) - 1 };
        service.checkWatchdog();
        try std.testing.expect(service.job != null);
        try std.testing.expect(service.lifecycle.queued.?.retry == .exhausted);
        try std.testing.expectEqual(epoch + 1, service.capture_epoch);
        try std.testing.expectEqual(next + 1, service.next_intent.load(.monotonic));
        if (repeat_failure) {
            const retried = try AsyncBlueprintPrefixTest.finishOne(service);
            try std.testing.expect(!retried.committed);
            try std.testing.expectEqual(error.Io, retried.failure.?);
            try f.expectWaiting(task, 100, 2, error.Io, false);
            try std.testing.expect(service.lifecycle.queued.?.retry == .exhausted);
            try std.testing.expectEqual(@as(u32, 2), failure.injected.load(.acquire));
            try std.testing.expectEqual(epoch + 1, service.capture_epoch);
            try std.testing.expectEqual(next + 1, service.next_intent.load(.monotonic));
            try std.testing.expectEqual(@as(u64, 0), f.store.sequence);
            try std.testing.expectEqual(blocks, task.snapshot.chunks.get(PreparedBlueprintDrainTest.chunk_id).?.blocks);
            try std.testing.expectEqual(fulfilled, (try task.result.?).prepared.publication.instance.fulfilled.ptr);
            try AsyncBlueprintPrefixTest.expectSleeping(&f);
            failure.armed.store(false, .release);
            f.store.setFaults(null);
            // An ordinary explicit retry keeps the final intent and its spent
            // retry budget while restarting the same prepared application.
            service.requestSaveTransition(101, false);
            try std.testing.expectEqual(@as(u64, 100), service.lifecycle.queued.?.intent.id);
            try std.testing.expect(service.lifecycle.queued.?.retry == .exhausted);
        }
        try f.waitSave(100);
        try std.testing.expectEqual(@as(u64, 3), f.fixture.client.resolved_request);
        try f.reopen(2, true);
    }
}

test "blueprint prefix committed before compaction failure still wakes its prepared Apply" {
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    const task = try f.prepare();
    var faults: @import("persistence/io.zig").Faults = .{ .operation = .read };
    f.store.setFaults(&faults);
    // The real final writer commits the full journal, then reads it during
    // compaction. A later compaction error does not undo that durable progress.
    try service.beginCapture(200, true);
    service.finishBlueprintApplication(task);
    service.requestSaveTransition(100, true);
    const completion = try AsyncBlueprintPrefixTest.finishOne(service);
    try std.testing.expect(completion.committed);
    try std.testing.expectEqual(error.Io, completion.failure.?);
    try std.testing.expect(service.blueprint_task == null);
    try std.testing.expectEqual(@as(u64, 2), f.fixture.client.resolved_request);
    try f.waitSave(100);
    f.store.setFaults(null);
    try std.testing.expectEqual(@as(u64, 2), f.store.sequence);
    try f.reopen(1, true);
}

test "ordinary Save handoff and explicit FIFO retry preserve idle drain ordering" {
    const Case = enum { ready, retained_save, later_apply };
    for ([_]Case{ .ready, .retained_save, .later_apply }) |case| {
        const retained_save = case == .retained_save;
        var f: PreparedBlueprintDrainTest = undefined;
        try f.init();
        defer f.deinit();
        const service = &f.fixture.service;
        var faults: @import("persistence/io.zig").Faults = .{ .operation = .write };
        f.store.setFaults(&faults);
        if (retained_save) {
            service.saveBlueprint(try f.fixture.request(2));
        } else {
            try service.beginCapture(200, false);
        }
        service.requestSaveTransition(100, false);
        const later_task = if (case == .later_apply) try f.prepare() else null;
        const completion = try AsyncBlueprintPrefixTest.finishOne(service);
        try std.testing.expectEqual(error.Io, completion.failure.?);
        try std.testing.expect(!completion.committed);
        if (retained_save) {
            try std.testing.expect(service.job == null);
            try std.testing.expect(service.blueprint_task == null);
            try std.testing.expectEqual(@as(u64, 100), service.status.intent_id);
            try std.testing.expectEqual(@as(u64, 0), service.status.target_sequence);
            try std.testing.expectEqual(persistence.Phase.failed, service.status.phase);
            try std.testing.expect(!service.status.active);
            try std.testing.expectEqual(@as(usize, 1), service.lifecycle.queued.?.fence_remaining);
            const epoch = service.capture_epoch;
            const progress = service.status.progress_generation;
            for (0..4) |_| service.checkWatchdog();
            try std.testing.expectEqual(epoch, service.capture_epoch);
            try std.testing.expectEqual(progress, service.status.progress_generation);
            // Journal-blocked work still needs an explicit coalesced request.
            service.requestSaveTransition(101, false);
            try std.testing.expectEqual(@as(u64, 100), service.lifecycle.queued.?.intent.id);
            try std.testing.expectEqual(@as(usize, 1), service.lifecycle.queued.?.fence_remaining);
        } else {
            // A ready successor takes over automatically, even when a later
            // Apply is preparing. This is its first attempt, not a prefix retry.
            try std.testing.expectEqual(@as(u64, 100), service.lifecycle.active.?.intent.id);
            try std.testing.expect(service.status.error_name == null);
        }
        try std.testing.expect(service.job != null);
        if (later_task) |task| service.finishBlueprintApplication(task);
        try f.waitSave(100);
        f.store.setFaults(null);
        try std.testing.expectEqual(@as(u32, if (retained_save) 2 else 1), f.store.blueprints.definitions.count());
        try std.testing.expectEqual(@as(u64, if (retained_save) 2 else 1), f.store.sequence);
        try std.testing.expectEqual(@as(u64, if (retained_save or later_task != null) 2 else 1), f.fixture.client.resolved_request);
        if (later_task != null) {
            try std.testing.expectEqual(@as(u32, 0), f.store.blueprints.instances.count());
            try std.testing.expectEqual(@as(u32, 1), service.worker_state.blueprints.instances.count());
        }
    }
}

fn exerciseReadySaveAfterOlderCaptureFailure(mode: enum { watchdog_cancel, io_failure }, queued_final: bool) !void {
    const io = std.testing.io;
    const f = try PersistenceFixture.init(.{
        .output_bytes = if (mode == .watchdog_cancel) 33000 else 256 * 1024,
        .capture_wait_ns = if (mode == .watchdog_cancel) 200 * std.time.ns_per_ms else 60 * std.time.ns_per_s,
        .player_wait_ns = 60 * std.time.ns_per_s,
        .overdue_ns = 60 * std.time.ns_per_s,
    });
    defer f.deinit();
    const client = try f.service.createClient();
    for ([_]u32{ 10, 42, 74, 106 }) |x| try std.testing.expectEqual(OperationStatus.success, try PersistenceFixture.operation(client, .{ .block = .{ x, 10, 48 }, .action = .{ .put = .snow } }));
    var gate: ServiceWriteGate = .{};
    var faults: @import("persistence/io.zig").Faults = .{ .enabled = mode == .io_failure, .operation = .write, .context = &gate, .hook = ServiceWriteGate.hook };
    f.store.setFaults(&faults);
    // Release before fixture cleanup awaits the writer on any failed assertion.
    defer gate.released.set(io);
    const older = f.service.requestSave(false);
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    if (mode == .watchdog_cancel) _ = try waitServiceSources(f.service, false);
    const queued = f.service.requestSave(queued_final);
    try std.testing.expect(queued != older);
    // A value-only invalid query follows the public Save in the same mailbox.
    // Its reply proves the queued intent was processed while the old writer
    // remained gated, without adding mutations or persistence dependencies.
    const barrier = client.requestStandingSpace(.{ .preferred_xy = .{ 0, 0 }, .clearance_size = .{ 0, 0, 0 }, .support_size = .{ 0, 0 } });
    const barrier_deadline = persistence.now(io) + 5 * std.time.ns_per_s;
    var barrier_seen = false;
    while (persistence.now(io) < barrier_deadline) {
        if (client.pollStandingSpace(barrier)) |reply| {
            try std.testing.expectError(error.InvalidSearch, reply.result);
            barrier_seen = true;
            break;
        }
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(barrier_seen);
    // The small watchdog-case output queue cannot encode all four sources
    // while the writer is gated. Their release proves real watchdog cancellation;
    // its terminal event must hand off the already ready queued Save afterward.
    const released = try waitServiceSources(f.service, true);
    try std.testing.expectEqual(older, released.intent_id);
    try std.testing.expect(released.active);
    try std.testing.expectEqual(@as(usize, 0), released.pending_commands);
    try std.testing.expectEqual(@as(u64, 0), released.durable_sequence);
    gate.released.set(io);
    const handoff_deadline = persistence.now(io) + 5 * std.time.ns_per_s;
    var handed_off: ?persistence.Status = null;
    while (persistence.now(io) < handoff_deadline) {
        const status = f.service.persistenceStatus();
        if (status.intent_id == queued) {
            handed_off = status;
            break;
        }
        try Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(handed_off != null);
    // The older capture's error must not become the visible outcome of the
    // queued Save before that Save has attempted its own healthy capture.
    try std.testing.expect(handed_off.?.error_name == null);
    try std.testing.expect(handed_off.?.phase != .failed);
    const done = try f.waitSave(queued);
    try std.testing.expectEqual(persistence.Phase.complete, done.phase);
    try std.testing.expectEqual(queued, done.intent_id);
    try std.testing.expectEqual(@as(u64, 1), done.target_sequence);
    try std.testing.expectEqual(@as(u64, 1), done.durable_sequence);
    try std.testing.expectEqual(@as(usize, 0), done.pending_commands);
    f.store.setFaults(null);
    try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
    try std.testing.expectEqual(@as(u64, if (queued_final) 1 else 0), f.store.base_sequence);
    try std.testing.expectEqual(@as(u32, 4), f.store.index.count());
    for (0..4) |x| {
        const id = f.layout.encodeChunkCoords(.{ @intCast(x), 0, 1 });
        const location = f.store.index.get(id).?;
        var read: storage.BaseRead = .{ .file = try location.file.duplicate(), .offset = location.offset, .length = location.length, .revision = location.revision, .id = id, .world_uuid = f.store.world_uuid, .dimensions = f.store.dimensions };
        defer read.deinit();
        const bytes = try read.read(std.testing.allocator);
        defer std.testing.allocator.free(bytes);
        var restored = try format.decodeChunk(std.testing.allocator, f.store.world_uuid, bytes, f.store.dimensions);
        defer restored.deinit(std.testing.allocator);
        try std.testing.expectEqual(@intFromEnum(rules.BlockType.snow), restored.blocks[transformations.index(.{ 10, 10, 16 })]);
    }
}

test "public ready queued Save takes over an autosave canceled by the real watchdog" {
    for ([_]bool{ false, true }) |final| try exerciseReadySaveAfterOlderCaptureFailure(.watchdog_cancel, final);
}

test "public ready queued Save takes over an older Io failure without inheriting its outcome" {
    for ([_]bool{ false, true }) |final| try exerciseReadySaveAfterOlderCaptureFailure(.io_failure, final);
}

test "queued Save handoff respects read gates without retrying later journal work" {
    const a = std.testing.allocator;
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    defer service.read_pending.deinit(a);
    defer service.deferred_reads.deinit(a);
    var faults: @import("persistence/io.zig").Faults = .{ .operation = .write };
    f.store.setFaults(&faults);
    try service.beginCapture(200, false);
    service.requestSaveTransition(100, true);
    // This later Save is outside the final fence. Its full journal must
    // not trigger another prefix writer while other readiness gates wait.
    service.processRequest(.{ .blueprint_save = try f.fixture.request(2) });
    const id = PreparedBlueprintDrainTest.chunk_id;
    try service.read_pending.put(a, id, 0);
    const epoch = service.capture_epoch;
    const next = service.next_intent.load(.monotonic);
    const completion = try AsyncBlueprintPrefixTest.finishOne(service);
    try std.testing.expectEqual(error.Io, completion.failure.?);
    try std.testing.expect(!completion.committed);
    try std.testing.expect(service.job == null);
    try std.testing.expectEqual(@as(u64, 100), service.status.intent_id);
    try std.testing.expectEqual(@as(u64, 0), service.status.target_sequence);
    try std.testing.expectEqual(persistence.Phase.capturing, service.status.phase);
    try std.testing.expect(service.status.active);
    try std.testing.expect(service.status.error_name == null);
    try std.testing.expect(service.lifecycle.queued.?.retry == .available);
    try std.testing.expectEqual(@as(usize, 0), service.lifecycle.queued.?.fence_remaining);
    try std.testing.expectEqual(@as(usize, 1), service.pending.len);
    try std.testing.expectEqual(epoch, service.capture_epoch);
    try std.testing.expectEqual(next, service.next_intent.load(.monotonic));
    // Releasing the remaining gate uses the existing save-readiness path.
    try std.testing.expect(service.read_pending.remove(id));
    service.retryPending();
    try f.waitSave(100);
    f.store.setFaults(null);
    try std.testing.expectEqual(@as(u64, 1), f.store.sequence);
    try std.testing.expectEqual(@as(u32, 1), f.store.blueprints.definitions.count());
    try std.testing.expectEqual(@as(u32, 2), service.worker_state.blueprints.definitions.count());
    try std.testing.expectEqual(@as(usize, 1), service.blueprint_journal.items.len);
    try std.testing.expectEqual(@as(u64, 2), service.blueprint_journal.items[0].definition.id);
}

const BlueprintRoadSaveTest = struct {
    const coords: ChunkCoords = .{ 0, 0, 2 };
    const chunk_id = test_layout.encodeChunkCoords(coords);
    const dimensions: [3]u32 = .{ @intCast(test_layout.size_in_chunks[0]), @intCast(test_layout.size_in_chunks[1]), @intCast(test_layout.size_in_chunks[2]) };

    fn initFixture(fixture: *BlueprintSaveFixture, store: *storage.Store) !void {
        var roads: BlueprintRoadFixture = undefined;
        try roads.init();
        defer roads.deinit();
        try fixture.init();
        errdefer BlueprintJournalBudgetTest.cleanup(fixture);
        std.mem.swap(WorkerState, &fixture.service.worker_state, &roads.service.worker_state);
        fixture.service.worker_state.persistence_service = &fixture.service;
        roads.service.worker_state.persistence_service = &roads.service;
        fixture.service.store = store;
        fixture.service.limits.output_bytes = 64 * 1024;
        const state = &fixture.service.worker_state.blueprints;
        const definition = state.definitions.get(1).?;
        const instance = state.instances.get(1).?;
        const operations = [_]blueprint_wire.Op{
            .{ .definition = .{ .id = definition.id, .owner = definition.owner, .name = definition.name, .size = definition.definition.size, .cells = std.mem.sliceAsBytes(definition.definition.cells), .target_count = definition.definition.target_count } },
            .{ .instance = .{ .id = instance.id, .definition_id = instance.definition_id, .owner = instance.owner, .origin = instance.origin, .rotation = instance.rotation } },
        };
        for (operations) |operation| {
            try fixture.service.reserveBlueprintJournal(operation);
            fixture.service.appendBlueprintJournal(operation);
        }
        fixture.service.blueprint_library_bytes = definition.name.len + definition.definition.cells.len + 128;
    }

    fn load(client: *Client) !WorldChunk {
        const token = try client.tryRequestChunksInMode(.{ coords[0], coords[1] }, coords[2], coords[2] + 1, .blocks);
        var replies: std.ArrayList(ChunkResponse) = .empty;
        defer deinitResponses(&replies);
        const deadline = persistence.now(std.testing.io) + 10 * std.time.ns_per_s;
        while (persistence.now(std.testing.io) < deadline) {
            client.takeResponses(&replies);
            for (replies.items) |reply| if (reply.subscription_id == token and reply.data == .blocks)
                return reply.data.blocks.chunk.tryClone(std.testing.allocator);
            for (replies.items) |reply| reply.deinit(std.testing.allocator);
            replies.clearRetainingCapacity();
            try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.TestLoadTimeout;
    }

    fn settle(service: *WorldDataService) !void {
        const intent = service.requestSave(true);
        const deadline = persistence.now(std.testing.io) + 10 * std.time.ns_per_s;
        while (persistence.now(std.testing.io) < deadline) {
            const status = service.persistenceStatus();
            if (status.intent_id == intent and !status.active and (status.phase == .complete or status.phase == .failed)) {
                try std.testing.expectEqual(persistence.Phase.complete, status.phase);
                return;
            }
            try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.TestSaveTimeout;
    }
};

fn queueBlueprintSaveTestRoadGate(service: *WorldDataService) !void {
    var batch: blueprint_road_updates.Batch = .{};
    batch.add(PreparedBlueprintDrainTest.chunk_id);
    try service.blueprint_road_queue.reserve(std.testing.allocator, batch);
    service.blueprint_road_queue.commit(batch);
}

test "road completion cannot restart a blueprint prefix after an uncommitted older writer fails" {
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    const task = try f.prepare();
    var faults: @import("persistence/io.zig").Faults = .{ .operation = .write };
    f.store.setFaults(&faults);
    try service.beginCapture(200, false);
    service.finishBlueprintApplication(task);
    try std.testing.expect(task.waiting_for_journal);
    try queueBlueprintSaveTestRoadGate(service);
    service.requestSaveTransition(100, true);
    const epoch = service.capture_epoch;
    const next = service.next_intent.load(.monotonic);
    const completion = try AsyncBlueprintPrefixTest.finishOne(service);
    try std.testing.expect(!completion.committed);
    try std.testing.expectEqual(error.Io, completion.failure.?);
    try std.testing.expect(service.job == null);
    _ = service.processBlueprintRoadUpdatesWithBudget(1);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.count);
    try std.testing.expect(service.job == null);
    try std.testing.expect(service.blueprint_task == task);
    try std.testing.expect(task.waiting_for_journal);
    try std.testing.expectEqual(epoch, service.capture_epoch);
    try std.testing.expectEqual(next, service.next_intent.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), service.lifecycle.queued.?.fence_remaining);
    try AsyncBlueprintPrefixTest.expectSleeping(&f);
    f.store.setFaults(null);
    service.requestSaveTransition(101, false);
    try f.waitSave(100);
    try std.testing.expectEqual(@as(u32, 1), f.store.blueprints.instances.count());
}

test "freeing road queue capacity resumes a retained fill while capture is suspended" {
    const a = std.testing.allocator;
    var fixture: BlueprintRoadFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const service = &fixture.service;
    var client: Client = .{ .service = service };
    defer client.pending.deinit(a);
    for (0..blueprint_road_updates.capacity) |i| {
        var batch: blueprint_road_updates.Batch = .{};
        batch.add(@intCast(1_000_000 + i));
        try service.blueprint_road_queue.reserve(a, batch);
        service.blueprint_road_queue.commit(batch);
    }
    service.processRequest(.{ .operation = .{ .client = &client, .request_id = 1, .operation = .{
        .block = .{ 15, 10, 69 },
        .action = .{ .put = .country_road_solid },
        .blueprint = .{ .instance_id = 1, .cell_index = 0 },
    } } });
    try std.testing.expectEqual(@as(usize, 1), service.pending.len);
    try std.testing.expect(!service.pending.frontPtr().?.waiting_for_journal);
    try std.testing.expectEqual(@as(usize, 0), client.pending.responses.items.len);
    try std.testing.expectEqual(@as(u32, 1), service.worker_state.blueprints.instances.get(1).?.remaining);
    service.noteDrainFailure(error.Io);
    try std.testing.expect(service.internal_capture_suspended);
    // The head has no resident roads, so one real processor turn frees a slot
    // and must wake the capacity-blocked fill despite the suspended capture.
    _ = service.processBlueprintRoadUpdatesWithBudget(1);
    try std.testing.expectEqual(@as(usize, 0), service.pending.len);
    try std.testing.expectEqual(@as(usize, 1), client.pending.responses.items.len);
    try std.testing.expectEqual(OperationStatus.success, client.pending.responses.items[0].operation.?.status);
    try std.testing.expectEqual(@as(u32, 0), service.worker_state.blueprints.instances.get(1).?.remaining);
    try std.testing.expect(!service.worker_state.blueprints.instances.get(1).?.active);
    const id = test_layout.encodeChunkCoords(.{ 0, 0, 2 });
    try std.testing.expectEqual(rules.BlockType.country_road_solid, service.worker_state.modified_chunks.get(id).?.content.getBlock(.{ 15, 10, 5 }));
    try std.testing.expectEqual(blueprint_road_updates.capacity, service.blueprint_road_queue.count);
    try std.testing.expect(service.blueprint_road_queue.slots.contains(id));
    try std.testing.expect(service.job == null);
}

const BlueprintRoadSchedulingTest = struct {
    service: WorldDataService,
    client: Client,
    next_request: u64 = 1,

    fn init(self: *@This()) !void {
        const a = std.testing.allocator;
        self.* = .{
            .service = .{ .layout = &test_layout, .io = std.testing.io, .allocator = a, .worker = undefined, .worker_state = .{ .layout = &test_layout, .generator = try WorldGenerator.prepare(.flat, a, &test_layout) } },
            .client = undefined,
        };
        self.service.worker_state.persistence_service = &self.service;
        self.client = .{ .service = &self.service };
    }

    fn deinit(self: *@This()) void {
        const a = std.testing.allocator;
        self.client.pending.deinit(a);
        self.service.worker_state.deinit(a);
        self.service.blueprint_road_queue.deinit(a);
        self.service.source_holds.deinit(a);
        self.service.blueprint_journal.deinit(a);
        self.service.dirty_meshes.deinit(a);
        self.service.pending.deinit(a);
    }

    fn makeChunk(ramps: usize) !WorldChunk {
        const a = std.testing.allocator;
        var chunk = WorldChunk.initEmpty();
        errdefer chunk.deinit(a);
        for (0..ramps) |row| {
            const y: u5 = @intCast(2 + row * 5);
            for (10..15) |x| try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(x), y, 5 }, .{ .put = .stone }));
            try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 15, y, 4 }, .{ .put = .stone }));
            try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 10, y, 6 }, .{ .put = .country_road_solid }));
            for (11..15) |x| try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ @intCast(x), y, 6 }, .{ .put = .country_road_adaptive }));
            try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 15, y, 5 }, .{ .put = .country_road_solid }));
        }
        try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 25, 25, 5 }, .{ .put = .limestone }));
        return chunk;
    }

    fn addChunk(self: *@This(), coords: ChunkCoords, ramps: usize) !void {
        const a = std.testing.allocator;
        var chunk = try makeChunk(ramps);
        errdefer chunk.deinit(a);
        const id = self.service.layout.encodeChunkCoords(coords);
        var batch: blueprint_road_updates.Batch = .{};
        batch.add(id);
        try self.service.blueprint_road_queue.reserve(a, batch);
        try self.service.worker_state.modified_chunks.put(a, id, chunk);
        self.service.blueprint_road_queue.commit(batch);
    }

    fn slope(self: *@This(), coords: ChunkCoords, row: usize) ?@import("road_data.zig").Slope {
        const chunk = self.service.worker_state.modified_chunks.get(self.service.layout.encodeChunkCoords(coords)).?;
        return chunk.metadata.road(transformations.index(.{ 11, @intCast(2 + row * 5), 6 })).?.slope;
    }

    fn edit(self: *@This(), coords: ChunkCoords, put: bool) !void {
        const id = self.service.layout.encodeChunkCoords(coords);
        const revision = self.service.worker_state.modified_chunks.get(id).?.chunk_revision;
        const responses = self.client.pending.responses.items.len;
        self.service.processRequest(.{ .operation = .{
            .client = &self.client,
            .request_id = self.next_request,
            .operation = .{ .block = .{ @as(u32, @intCast(coords[0])) * CHUNK_SIZE + 25, @as(u32, @intCast(coords[1])) * CHUNK_SIZE + 25, @as(u32, @intCast(coords[2])) * CHUNK_SIZE + 6 }, .action = if (put) .{ .put = .planks } else .remove },
        } });
        self.next_request += 1;
        try std.testing.expectEqual(responses + 1, self.client.pending.responses.items.len);
        try std.testing.expectEqual(OperationStatus.success, self.client.pending.responses.items[responses].operation.?.status);
        try std.testing.expectEqual(revision + 1, self.service.worker_state.modified_chunks.get(id).?.chunk_revision);
    }
};

test "unrelated real edits retain road cursor progress and request one complete next pass" {
    var f: BlueprintRoadSchedulingTest = undefined;
    try f.init();
    defer f.deinit();
    const coords: ChunkCoords = .{ 0, 0, 2 };
    try f.addChunk(coords, 5);
    for (0..12) |step| {
        try std.testing.expectEqual(@as(usize, 1), f.service.processBlueprintRoadUpdatesWithBudget(1));
        try std.testing.expectEqual(step + 1, f.service.blueprint_road_queue.peek().?.cursor);
        if (step != 11) try f.edit(coords, step % 2 == 0);
    }
    try std.testing.expect(f.service.blueprint_road_queue.peek().?.dirty_again);
    try std.testing.expect(f.slope(coords, 0) != null);
    try std.testing.expect(f.slope(coords, 4) == null);
    var remaining_work: usize = 0;
    while (f.service.blueprint_road_queue.count != 0 and remaining_work < 42) {
        remaining_work += f.service.processBlueprintRoadUpdatesWithBudget(2);
        try std.testing.expect(!f.service.blueprint_road_waiting);
    }
    try std.testing.expectEqual(@as(usize, 0), f.service.blueprint_road_queue.count);
    // Eight remaining seeds, completion, then exactly one full 20-seed pass.
    try std.testing.expectEqual(@as(usize, 30), remaining_work);
    for (0..5) |row| try std.testing.expect(f.slope(coords, row) != null);
}

test "road metadata swap-removal before or after the cursor retains the moved seed" {
    const a = std.testing.allocator;
    for ([_]usize{ 0, 5 }) |removed_slot| {
        var f: BlueprintRoadFixture = undefined;
        try f.init();
        defer f.deinit();
        var client: Client = .{ .service = &f.service };
        defer client.pending.deinit(a);
        const id = test_layout.encodeChunkCoords(.{ 0, 0, 2 });
        {
            const chunk = f.service.worker_state.modified_chunks.getPtr(id).?;
            for (0..4) |decoy| {
                const y: u5 = @intCast(22 + decoy * 2);
                try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 25, y, 5 }, .{ .put = .stone }));
                try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 25, y, 6 }, .{ .put = .country_road_adaptive }));
            }
            // Visit three incomplete ramp seeds before fulfillment. The final
            // unvisited seed is last, where a real removal can swap it behind us.
            std.mem.swap(@import("road_data.zig").Road, &chunk.metadata.roads.items[0], &chunk.metadata.roads.items[7]);
        }
        var batch: blueprint_road_updates.Batch = .{};
        batch.add(id);
        try f.service.blueprint_road_queue.reserve(a, batch);
        f.service.blueprint_road_queue.commit(batch);
        try std.testing.expectEqual(@as(usize, 4), f.service.processBlueprintRoadUpdatesWithBudget(4));
        try std.testing.expectEqual(@as(usize, 4), f.service.blueprint_road_queue.peek().?.cursor);
        try std.testing.expect(f.slope() == null);
        try std.testing.expectEqual(OperationStatus.success, (try f.fill()).diagnostics.status);
        const removed = f.service.worker_state.modified_chunks.get(id).?.metadata.roads.items[removed_slot];
        const local = transformations.coordinates(removed.index);
        const moved = f.service.worker_state.modified_chunks.get(id).?.metadata.roads.items[7].index;
        const revision = f.service.worker_state.modified_chunks.get(id).?.chunk_revision;
        f.service.processRequest(.{ .operation = .{ .client = &client, .request_id = 1, .operation = .{ .block = .{ local[0], local[1], 2 * CHUNK_SIZE + @as(u32, local[2]) }, .action = .remove } } });
        try std.testing.expectEqual(@as(usize, 1), client.pending.responses.items.len);
        try std.testing.expectEqual(OperationStatus.success, client.pending.responses.items[0].operation.?.status);
        const chunk = f.service.worker_state.modified_chunks.get(id).?;
        try std.testing.expectEqual(revision + 1, chunk.chunk_revision);
        try std.testing.expectEqual(@as(usize, 7), chunk.metadata.roads.items.len);
        try std.testing.expectEqual(moved, chunk.metadata.roads.items[removed_slot].index);
        try std.testing.expectEqual(@as(usize, 4), f.service.blueprint_road_queue.peek().?.cursor);
        try std.testing.expectEqual(@as(usize, 3), f.service.processBlueprintRoadUpdatesWithBudget(3));
        try std.testing.expectEqual(@as(usize, 7), f.service.blueprint_road_queue.peek().?.cursor);
        if (removed_slot == 0) try std.testing.expect(f.slope() == null);
        try std.testing.expectEqual(@as(usize, 1), f.service.processBlueprintRoadUpdatesWithBudget(1));
        try std.testing.expectEqual(@as(usize, 0), f.service.blueprint_road_queue.peek().?.cursor);
        try std.testing.expectEqual(@as(usize, 8), f.service.processBlueprintRoadUpdatesWithBudget(16));
        try std.testing.expectEqual(@as(usize, 0), f.service.blueprint_road_queue.count);
        const finished = f.service.worker_state.modified_chunks.get(id).?;
        for (11..15) |x| try std.testing.expect(finished.metadata.road(transformations.index(.{ @intCast(x), 10, 6 })).?.slope != null);
    }
}

test "a continuously edited road chunk completes its pass and yields to a quiet ramp" {
    var f: BlueprintRoadSchedulingTest = undefined;
    try f.init();
    defer f.deinit();
    const busy: ChunkCoords = .{ 0, 0, 2 };
    const quiet: ChunkCoords = .{ 2, 0, 2 };
    try f.addChunk(busy, 2);
    try f.addChunk(quiet, 1);
    const busy_id = test_layout.encodeChunkCoords(busy);
    const quiet_id = test_layout.encodeChunkCoords(quiet);
    for (0..8) |step| {
        try std.testing.expectEqual(busy_id, f.service.blueprint_road_queue.peek().?.id);
        try std.testing.expectEqual(@as(usize, 1), f.service.processBlueprintRoadUpdatesWithBudget(1));
        try std.testing.expectEqual(step + 1, f.service.blueprint_road_queue.peek().?.cursor);
        try f.edit(busy, step % 2 == 0);
    }
    try std.testing.expect(f.slope(quiet, 0) == null);
    try std.testing.expectEqual(@as(usize, 1), f.service.processBlueprintRoadUpdatesWithBudget(1));
    try std.testing.expectEqual(quiet_id, f.service.blueprint_road_queue.peek().?.id);
    try std.testing.expectEqual(@as(usize, 2), f.service.blueprint_road_queue.count);
    try std.testing.expectEqual(@as(usize, 1), f.service.processBlueprintRoadUpdatesWithBudget(1));
    try std.testing.expect(f.slope(quiet, 0) != null);
    try std.testing.expectEqual(@as(usize, 4), f.service.processBlueprintRoadUpdatesWithBudget(4));
    try std.testing.expect(!f.service.blueprint_road_queue.slots.contains(quiet_id));
    try std.testing.expect(f.service.blueprint_road_queue.slots.contains(busy_id));
    try std.testing.expectEqual(busy_id, f.service.blueprint_road_queue.peek().?.id);
    try std.testing.expectEqual(@as(usize, 0), f.service.blueprint_road_queue.peek().?.cursor);
}

test "road service batches spend at most sixteen seed and completion work units" {
    var f: BlueprintRoadSchedulingTest = undefined;
    try f.init();
    defer f.deinit();
    const first: ChunkCoords = .{ 0, 0, 2 };
    const second: ChunkCoords = .{ 2, 0, 2 };
    try f.addChunk(first, 5);
    try f.addChunk(second, 1);
    try std.testing.expectEqual(@as(usize, 16), WorldDataService.blueprint_road_work_per_turn);
    try std.testing.expectEqual(@as(usize, 0), f.service.processBlueprintRoadUpdatesWithBudget(0));
    try std.testing.expectEqual(@as(usize, 0), f.service.blueprint_road_queue.peek().?.cursor);
    f.service.processBlueprintRoadUpdates();
    try std.testing.expectEqual(@as(usize, 16), f.service.blueprint_road_queue.peek().?.cursor);
    try std.testing.expectEqual(@as(usize, 2), f.service.blueprint_road_queue.count);
    for (0..4) |row| try std.testing.expect(f.slope(first, row) != null);
    try std.testing.expect(f.slope(first, 4) == null);
    try std.testing.expect(f.slope(second, 0) == null);
    // Four seeds and completion remain in the first chunk; the quiet chunk
    // then consumes its four seeds and its own completion in the same turn.
    try std.testing.expectEqual(@as(usize, 10), f.service.processBlueprintRoadUpdatesWithBudget(WorldDataService.blueprint_road_work_per_turn));
    try std.testing.expectEqual(@as(usize, 0), f.service.blueprint_road_queue.count);
    try std.testing.expect(f.slope(first, 4) != null);
    try std.testing.expect(f.slope(second, 0) != null);
    try std.testing.expectEqual(@as(usize, 0), f.service.processBlueprintRoadUpdatesWithBudget(16));
}

test "a blocked road batch yields without spending its remaining seed budget" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |capture_hold| {
        var f: BlueprintRoadFixture = undefined;
        try f.init();
        defer f.deinit();
        try std.testing.expectEqual(OperationStatus.success, (try f.fill()).diagnostics.status);
        const id = test_layout.encodeChunkCoords(.{ 0, 0, 2 });
        const revision = f.service.worker_state.modified_chunks.get(id).?.chunk_revision;
        if (capture_hold) try f.service.source_holds.put(a, id, 1) else f.service.limits.manifest_entries = 0;
        try std.testing.expectEqual(@as(usize, 0), f.service.processBlueprintRoadUpdatesWithBudget(16));
        try std.testing.expect(f.service.blueprint_road_waiting);
        try std.testing.expectEqual(@as(usize, 1), f.service.blueprint_road_queue.count);
        try std.testing.expectEqual(@as(usize, 0), f.service.blueprint_road_queue.peek().?.cursor);
        try std.testing.expectEqual(revision, f.service.worker_state.modified_chunks.get(id).?.chunk_revision);
        try std.testing.expect(f.slope() == null);
        if (capture_hold) {
            try std.testing.expect(!f.service.internal_capture_suspended);
            try std.testing.expect(f.service.source_holds.remove(id));
        } else {
            try std.testing.expectEqualStrings("Capacity", f.service.status.deferred_work_error_name.?);
            try std.testing.expect(!f.service.internal_capture_suspended);
            f.service.limits.manifest_entries = 65536;
        }
        try std.testing.expectEqual(@as(usize, 5), f.service.processBlueprintRoadUpdatesWithBudget(16));
        try std.testing.expectEqual(@as(usize, 0), f.service.blueprint_road_queue.count);
        try std.testing.expect(f.slope() != null);
    }
}

test "road batches yield once for an asynchronous base read and resume after its completion" {
    const a = std.testing.allocator;
    const saved = try savedDependencyFixture();
    defer saved.deinit();
    var service: WorldDataService = .{
        .layout = &saved.layout,
        .io = std.testing.io,
        .allocator = a,
        .worker = undefined,
        .worker_state = .{ .layout = &saved.layout, .generator = try WorldGenerator.prepare(.flat, a, &saved.layout) },
        .catalog = try saved.store.snapshotCatalog(),
    };
    service.worker_state.persistence_service = &service;
    defer service.worker_state.deinit(a);
    defer service.catalog.?.deinit();
    defer service.blueprint_road_queue.deinit(a);
    defer service.source_holds.deinit(a);
    defer service.dirty_meshes.deinit(a);
    defer service.base_revisions.deinit(a);
    defer service.wal_revisions.deinit(a);
    defer service.read_pending.deinit(a);
    defer service.deferred_reads.deinit(a);
    defer service.read_failed.deinit(a);
    defer service.loaded_ring.deinit(a);
    defer {
        for (service.read_requests.items.items) |*read| read.deinit();
        service.read_requests.deinit(a);
    }
    const absent = saved.layout.encodeChunkCoords(.{ 0, 0, 1 });
    const quiet_coords: ChunkCoords = .{ 2, 0, 2 };
    const quiet = saved.layout.encodeChunkCoords(quiet_coords);
    var chunk = try BlueprintRoadSchedulingTest.makeChunk(1);
    var owns_chunk = true;
    defer if (owns_chunk) chunk.deinit(a);
    try service.worker_state.modified_chunks.put(a, quiet, chunk);
    owns_chunk = false;
    var batch: blueprint_road_updates.Batch = .{};
    batch.add(absent);
    batch.add(quiet);
    try service.blueprint_road_queue.reserve(a, batch);
    service.blueprint_road_queue.commit(batch);
    for (0..2) |_| {
        try std.testing.expectEqual(@as(usize, 0), service.processBlueprintRoadUpdatesWithBudget(16));
        try std.testing.expect(service.blueprint_road_waiting);
        try std.testing.expectEqual(@as(usize, 1), service.read_pending.count());
        try std.testing.expectEqual(@as(usize, 1), service.read_requests.items.items.len);
        try std.testing.expectEqual(absent, service.blueprint_road_queue.peek().?.id);
        try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.peek().?.cursor);
        try std.testing.expect(service.worker_state.modified_chunks.get(quiet).?.metadata.roads.items[0].slope == null);
    }
    var reads: std.ArrayList(storage.BaseRead) = .empty;
    defer {
        for (reads.items) |*read| read.deinit();
        reads.deinit(a);
    }
    service.read_requests.takeAll(service.io, &reads);
    try std.testing.expectEqual(@as(usize, 1), reads.items.len);
    const read = &reads.items[0];
    const loaded = try service.readPersisted(read);
    service.processRequest(.{ .chunk_loaded = .{ .id = read.id, .revision = read.revision, .result = loaded } });
    try std.testing.expectEqual(@as(usize, 0), service.read_pending.count());
    try std.testing.expectEqual(@as(usize, 6), service.processBlueprintRoadUpdatesWithBudget(16));
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.count);
    try std.testing.expect(service.worker_state.modified_chunks.get(quiet).?.metadata.roads.items[0].slope != null);
}

// These tests deliberately drive writer completions without road turns so a
// successful save must retain obligations, rather than accidentally drain them.
fn initDeferredRoadSaveTest(f: *PreparedBlueprintDrainTest) !void {
    try f.init();
    errdefer f.deinit();
    f.cleanupFixture();
    f.store.limits.blueprints.max_operations = 16;
    try BlueprintRoadSaveTest.initFixture(&f.fixture, &f.store);
    f.fixture_open = true;
}

fn fillDeferredRoadSaveTest(f: *PreparedBlueprintDrainTest) !void {
    f.fixture.service.processBlueprintFulfillment(.{ .client = &f.fixture.client, .request_id = 1, .operation = .{
        .block = .{ 15, 10, 69 },
        .action = .{ .put = .country_road_solid },
        .blueprint = .{ .instance_id = 1, .cell_index = 0 },
    } });
    try std.testing.expectEqual(OperationStatus.success, f.fixture.client.pending.responses.items[0].operation.?.status);
    try std.testing.expectEqual(@as(usize, 1), f.fixture.service.blueprint_road_queue.count);
}

test "ordinary and final Save preserve unfinished road shapes across loss of every volatile owner" {
    const a = std.testing.allocator;
    var reference: BlueprintRoadFixture = undefined;
    try reference.init();
    defer reference.deinit();
    try std.testing.expectEqual(OperationStatus.success, (try reference.fill()).diagnostics.status);
    _ = reference.service.processBlueprintRoadUpdatesWithBudget(16);
    const expected = reference.service.worker_state.modified_chunks.get(BlueprintRoadSaveTest.chunk_id).?.metadata.roads.items;
    for (expected) |road| try std.testing.expect(road.slope != null);
    for ([_]bool{ false, true }) |final| {
        var f: PreparedBlueprintDrainTest = undefined;
        try initDeferredRoadSaveTest(&f);
        defer f.deinit();
        try fillDeferredRoadSaveTest(&f);
        const service = &f.fixture.service;
        // Runtime pass state must not become part of durable identity.
        service.blueprint_road_queue.advance();
        try queueBlueprintSaveTestRoadGate(service);
        try std.testing.expect(service.blueprint_road_queue.peek().?.dirty_again);
        try std.testing.expect(service.worker_state.modified_chunks.get(BlueprintRoadSaveTest.chunk_id).?.metadata.road(transformations.index(.{ 11, 10, 6 })).?.slope == null);
        service.requestSaveTransition(100, final);
        try std.testing.expect(service.job != null);
        try f.waitSave(100);
        try std.testing.expectEqual(@as(usize, 1), service.blueprint_road_queue.count);
        const saved_keys = try @import("deferred_world_work.zig").decode(a, f.store.pending_work, f.store.dimensions, 4096);
        defer a.free(saved_keys);
        try std.testing.expectEqual(@as(usize, 1), saved_keys.len);
        try std.testing.expectEqual(BlueprintRoadSaveTest.chunk_id, saved_keys[0].chunk_id);
        f.cleanupFixture();
        f.store.deinit();
        f.store_open = false;
        f.store = try storage.Store.open(a, f.path, .{});
        f.store_open = true;
        try std.testing.expectEqual(@as(u32, 0), f.store.blueprints.instances.count());
        const restored_service = try WorldDataService.createPersistent(std.testing.io, a, &test_layout, .flat, &f.store, .{});
        defer restored_service.destroy();
        const client = try restored_service.createClient();
        const deadline = persistence.now(std.testing.io) + 10 * std.time.ns_per_s;
        var formed = false;
        while (persistence.now(std.testing.io) < deadline) {
            const chunk = try BlueprintRoadSaveTest.load(client);
            defer chunk.deinit(a);
            try std.testing.expectEqual(rules.BlockType.country_road_solid, chunk.content.getBlock(.{ 15, 10, 5 }));
            formed = true;
            for (expected) |road| {
                const actual = chunk.metadata.road(road.index) orelse {
                    formed = false;
                    break;
                };
                if (!std.meta.eql(road, actual)) {
                    formed = false;
                    break;
                }
            }
            if (formed) break;
            try Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expect(formed);
        try BlueprintRoadSaveTest.settle(restored_service);
        try std.testing.expectEqual(@as(usize, 0), f.store.pending_work.len);
    }
}

test "a no-op road pass marks its durable removal unsaved and the next Save clears it" {
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    try queueBlueprintSaveTestRoadGate(service);
    service.requestSaveTransition(100, false);
    try f.waitSave(100);
    try std.testing.expect(f.store.pending_work.len != 0);
    try std.testing.expect(!service.lifecycle.unsaved_work);
    try std.testing.expectEqual(@as(usize, 1), service.processBlueprintRoadUpdatesWithBudget(1));
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.count);
    try std.testing.expect(service.lifecycle.unsaved_work);
    service.requestSaveTransition(101, true);
    try f.waitSave(101);
    try std.testing.expectEqual(@as(usize, 0), f.store.pending_work.len);
    try std.testing.expect(!service.lifecycle.unsaved_work);
}

test "in-flight obligation snapshot stays immutable while clean completion and new work remain unsaved" {
    const a = std.testing.allocator;
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    try queueBlueprintSaveTestRoadGate(service);
    var gate: ServiceWriteGate = .{};
    var faults: @import("persistence/io.zig").Faults = .{ .enabled = false, .context = &gate, .hook = ServiceWriteGate.hook };
    f.store.setFaults(&faults);
    defer gate.released.set(std.testing.io);
    try service.beginCapture(100, false);
    try gate.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    const captured_generation = service.blueprint_road_queue.generation;
    try std.testing.expectEqual(@as(usize, 1), service.processBlueprintRoadUpdatesWithBudget(1));
    var later: blueprint_road_updates.Batch = .{};
    later.add(PreparedBlueprintDrainTest.chunk_id + 1);
    try service.blueprint_road_queue.reserve(a, later);
    service.blueprint_road_queue.commit(later);
    try std.testing.expect(captured_generation != service.blueprint_road_queue.generation);
    const frozen = try @import("deferred_world_work.zig").decode(a, service.job.?.pending_work, f.store.dimensions, 4096);
    defer a.free(frozen);
    try std.testing.expectEqual(PreparedBlueprintDrainTest.chunk_id, frozen[0].chunk_id);
    gate.released.set(std.testing.io);
    const completion = try AsyncBlueprintPrefixTest.finishOne(service);
    try std.testing.expect(completion.committed);
    try std.testing.expect(completion.failure == null);
    f.store.setFaults(null);
    try std.testing.expect(service.lifecycle.unsaved_work);
    try std.testing.expectEqual(PreparedBlueprintDrainTest.chunk_id + 1, service.blueprint_road_queue.peek().?.id);
    const saved = try @import("deferred_world_work.zig").decode(a, f.store.pending_work, f.store.dimensions, 4096);
    defer a.free(saved);
    try std.testing.expectEqualSlices(@import("deferred_world_work.zig").Key, frozen, saved);
}

test "failed and canceled captures retain pending road identity without publishing an empty replacement" {
    for ([_]bool{ false, true }) |cancel| {
        var f: PreparedBlueprintDrainTest = undefined;
        try f.init();
        defer f.deinit();
        const service = &f.fixture.service;
        try queueBlueprintSaveTestRoadGate(service);
        const generation = service.blueprint_road_queue.generation;
        var gate: ServiceWriteGate = .{};
        var faults: @import("persistence/io.zig").Faults = if (cancel)
            .{ .enabled = false, .context = &gate, .hook = ServiceWriteGate.hook }
        else
            .{ .operation = .write };
        f.store.setFaults(&faults);
        defer gate.released.set(std.testing.io);
        try service.beginCapture(100, false);
        if (cancel) {
            try gate.entered.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
            service.processRequest(.{ .cancel_save = 100 });
            gate.released.set(std.testing.io);
        }
        const completion = try AsyncBlueprintPrefixTest.finishOne(service);
        try std.testing.expect(!completion.committed);
        try std.testing.expect(completion.failure != null);
        f.store.setFaults(null);
        try std.testing.expectEqual(@as(u64, 0), f.store.sequence);
        try std.testing.expectEqual(generation, service.blueprint_road_queue.generation);
        try std.testing.expectEqual(@as(usize, 1), service.blueprint_road_queue.count);
        service.requestSaveTransition(101, true);
        try f.waitSave(101);
        try std.testing.expect(f.store.pending_work.len != 0);
    }
}

test "internal prefix overdue and final captures all start while road work remains pending" {
    const Mode = enum { prefix, overdue, final };
    for ([_]Mode{ .prefix, .overdue, .final }) |mode| {
        var f: PreparedBlueprintDrainTest = undefined;
        try f.init();
        defer f.deinit();
        const service = &f.fixture.service;
        try queueBlueprintSaveTestRoadGate(service);
        switch (mode) {
            .prefix => service.drainBlueprintJournal(),
            .overdue => {
                service.lifecycle.unsaved_work = true;
                service.lifecycle.last_success_ns = persistence.now(std.testing.io) - service.limits.overdue_ns - 1;
                service.checkWatchdog();
            },
            .final => service.requestSaveTransition(100, true),
        }
        try std.testing.expect(service.job != null);
        const intent = service.status.intent_id;
        try f.waitSave(intent);
        try std.testing.expectEqual(@as(usize, 1), service.blueprint_road_queue.count);
        try std.testing.expect(f.store.pending_work.len != 0);
    }
}

test "pending roads allow player NPC and timer progress while source holds still protect captures" {
    const a = std.testing.allocator;
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    const id = PreparedBlueprintDrainTest.chunk_id;
    var chunk = WorldChunk.initEmpty();
    var owns_chunk = true;
    defer if (owns_chunk) chunk.deinit(a);
    for ([_]u5{ 10, 11 }) |x| try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ x, 10, 5 }, .{ .put = .limestone }));
    try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(a, .{ 20, 20, 6 }, .{ .put = .dirt }));
    const event: transformations.Event = .{ .block = transformations.index(.{ 20, 20, 6 }), .kind = .compact_dirt, .due_tick = 1 };
    try chunk.metadata.timed.trySchedule(a, event);
    chunk.chunk_revision = 7;
    try service.worker_state.modified_chunks.put(a, id, chunk);
    owns_chunk = false;
    try service.worker_state.timed_chunks.put(a, id, {});
    service.worker_state.tick = event.due_tick + transformations.transformation_delay;
    try queueBlueprintSaveTestRoadGate(service);
    var simulation: Client = .{ .service = service, .simulation = true };
    defer simulation.pending.deinit(a);
    const player: Request = .{ .operation = .{ .client = &f.fixture.client, .request_id = 2, .operation = .{ .block = .{ 10, 10, 70 }, .action = .{ .put = .planks } } } };
    const npc: Request = .{ .operation = .{ .client = &simulation, .request_id = 1, .operation = .{ .block = .{ 11, 10, 70 }, .action = .{ .put = .planks } } } };
    try service.source_holds.put(a, id, 7);
    try std.testing.expect(!service.admissible(player));
    try std.testing.expect(!service.admissible(npc));
    service.processTransformations();
    try std.testing.expectEqual(@as(u64, 7), service.worker_state.modified_chunks.get(id).?.chunk_revision);
    try std.testing.expect(service.source_holds.remove(id));
    service.publishPersistenceStatus();
    try std.testing.expect(!service.simulationPaused());
    try std.testing.expect(service.admissible(player));
    try std.testing.expect(service.admissible(npc));
    service.processRequest(player);
    service.processRequest(npc);
    try std.testing.expectEqual(@as(usize, 0), service.pending.len);
    try std.testing.expectEqual(OperationStatus.success, f.fixture.client.pending.responses.items[0].operation.?.status);
    try std.testing.expectEqual(OperationStatus.success, simulation.pending.responses.items[0].operation.?.status);
    service.processTransformations();
    try std.testing.expectEqual(rules.BlockType.grass, service.worker_state.modified_chunks.get(id).?.content.getBlock(.{ 20, 20, 6 }));
    try std.testing.expectEqual(@as(usize, 1), service.blueprint_road_queue.count);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.peek().?.cursor);
}

test "final Save excludes background road reads until a foreground consumer shares them" {
    const a = std.testing.allocator;
    const saved = try savedDependencyFixture();
    defer saved.deinit();
    var service: WorldDataService = .{
        .layout = &saved.layout,
        .io = std.testing.io,
        .allocator = a,
        .worker = undefined,
        .worker_state = .{ .layout = &saved.layout, .generator = try WorldGenerator.prepare(.flat, a, &saved.layout) },
        .catalog = try saved.store.snapshotCatalog(),
    };
    service.worker_state.persistence_service = &service;
    defer service.worker_state.deinit(a);
    defer service.catalog.?.deinit();
    defer service.blueprint_road_queue.deinit(a);
    defer service.read_pending.deinit(a);
    defer service.deferred_reads.deinit(a);
    defer service.read_failed.deinit(a);
    defer service.loaded_ring.deinit(a);
    defer {
        for (service.read_requests.items.items) |*read| read.deinit();
        service.read_requests.deinit(a);
    }
    const id = saved.layout.encodeChunkCoords(.{ 0, 0, 1 });
    var batch: blueprint_road_updates.Batch = .{};
    batch.add(id);
    try service.blueprint_road_queue.reserve(a, batch);
    service.blueprint_road_queue.commit(batch);
    try std.testing.expectEqual(@as(usize, 0), service.processBlueprintRoadUpdatesWithBudget(1));
    try std.testing.expectEqual(@as(u32, 1), service.read_pending.count());
    try std.testing.expect(service.deferred_reads.contains(id));
    // The real asynchronous request remains unanswered. Its durable marker
    // lets the final save's readiness gate proceed without the read consumer.
    var lifecycle: save_lifecycle.Lifecycle = .{};
    _ = lifecycle.request(.{ .id = 100, .final = true }, 0);
    try std.testing.expectEqual(@as(u64, 100), lifecycle.takeReady(service.lifecycleObservations()).?.id);
    // Foreground reuse of the same in-flight I/O must promote it into the
    // ordinary final-read fence, without issuing a duplicate request.
    try std.testing.expect(!service.requireBase(id));
    try std.testing.expect(!service.deferred_reads.contains(id));
    try std.testing.expectEqual(@as(usize, 1), service.read_requests.items.items.len);
    _ = lifecycle.request(.{ .id = 101, .final = true }, 0);
    try std.testing.expect(lifecycle.takeReady(service.lifecycleObservations()) == null);
}

test "cold background read failure preserves an independent successful Save" {
    const a = std.testing.allocator;
    var f: PreparedBlueprintDrainTest = undefined;
    try initDeferredRoadSaveTest(&f);
    defer f.deinit();
    try fillDeferredRoadSaveTest(&f);
    const service = &f.fixture.service;
    defer service.read_pending.deinit(a);
    defer service.deferred_reads.deinit(a);
    defer service.read_failed.deinit(a);
    defer service.loaded_ring.deinit(a);
    defer {
        for (service.read_requests.items.items) |*read| read.deinit();
        service.read_requests.deinit(a);
    }
    service.requestSaveTransition(100, true);
    try f.waitSave(100);
    const id = BlueprintRoadSaveTest.chunk_id;
    try std.testing.expect(!service.worker_state.modified_chunks.contains(id));
    try std.testing.expectEqual(@as(usize, 0), service.processBlueprintRoadUpdatesWithBudget(1));
    try std.testing.expect(service.deferred_reads.contains(id));
    // An ordinary asynchronous wait must not begin a warning episode.
    try std.testing.expectEqual(null, service.deferred_work_log.next_warning_ns);
    const read = service.read_requests.items.items[0];
    service.requestSaveTransition(101, true);
    try f.waitSave(101);
    const sequence = f.store.sequence;
    service.dirty_meshes.clearRetainingCapacity();
    service.processRequest(.{ .chunk_loaded = .{ .id = read.id, .revision = read.revision, .result = error.Io } });
    try std.testing.expectEqual(persistence.Phase.complete, service.status.phase);
    try std.testing.expect(service.status.error_name == null);
    try std.testing.expectEqualStrings("Io", service.status.deferred_work_error_name.?);
    try std.testing.expect(service.deferred_work_log.warning_active);
    try std.testing.expectEqual(sequence, f.store.sequence);
    try std.testing.expectEqual(@as(u32, 0), service.dirty_meshes.count());
    try std.testing.expectEqual(@as(usize, 1), service.blueprint_road_queue.count);
}

test "a successful no-op road pass clears the recovered background diagnostic" {
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    try queueBlueprintSaveTestRoadGate(service);
    service.noteDeferredWorkFailure(error.Io);
    const deadline = service.deferred_work_log.next_warning_ns;
    // Switching error codes shares the same service-wide warning budget.
    service.noteDeferredWorkFailure(error.Capacity);
    try std.testing.expectEqual(deadline, service.deferred_work_log.next_warning_ns);
    try std.testing.expectEqualStrings("Capacity", service.status.deferred_work_error_name.?);
    try std.testing.expectEqual(@as(usize, 1), service.processBlueprintRoadUpdatesWithBudget(1));
    try std.testing.expect(service.status.deferred_work_error_name == null);
    try std.testing.expect(!service.deferred_work_log.warning_active);
    try std.testing.expectEqual(deadline, service.deferred_work_log.next_warning_ns);
    // Further successful work cannot repeat the recovery or reset the deadline.
    service.clearDeferredWorkFailure();
    try std.testing.expectEqual(deadline, service.deferred_work_log.next_warning_ns);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.count);
}

test "a partially processed road Save preserves formed history when durable passes restart" {
    const a = std.testing.allocator;
    var f: PreparedBlueprintDrainTest = undefined;
    try initDeferredRoadSaveTest(&f);
    defer f.deinit();
    try fillDeferredRoadSaveTest(&f);
    const service = &f.fixture.service;
    const id = BlueprintRoadSaveTest.chunk_id;
    try std.testing.expectEqual(@as(usize, 1), service.processBlueprintRoadUpdatesWithBudget(1));
    const expected = try a.dupe(@import("road_data.zig").Road, service.worker_state.modified_chunks.get(id).?.metadata.roads.items);
    defer a.free(expected);
    for (expected) |road| try std.testing.expect(road.slope != null);
    try queueBlueprintSaveTestRoadGate(service);
    try std.testing.expect(service.blueprint_road_queue.peek().?.dirty_again);
    service.requestSaveTransition(100, false);
    try f.waitSave(100);
    const location = f.store.index.get(id).?;
    var read: storage.BaseRead = .{ .file = try location.file.duplicate(), .offset = location.offset, .length = location.length, .revision = location.revision, .id = id, .world_uuid = f.store.world_uuid, .dimensions = f.store.dimensions };
    defer read.deinit();
    const reloaded = try service.readPersisted(&read);
    defer reloaded.deinit(a);
    for (expected) |road| try std.testing.expectEqualDeep(road, reloaded.metadata.road(road.index).?);
    service.blueprint_road_queue.deinit(a);
    service.blueprint_road_queue = .{};
    try service.restoreDeferredWork(&f.store);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.peek().?.cursor);
    try std.testing.expect(!service.blueprint_road_queue.peek().?.dirty_again);
    const revision = service.worker_state.modified_chunks.get(id).?.chunk_revision;
    _ = service.processBlueprintRoadUpdatesWithBudget(16);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.count);
    try std.testing.expectEqual(revision, service.worker_state.modified_chunks.get(id).?.chunk_revision);
    for (expected) |road| try std.testing.expectEqualDeep(road, service.worker_state.modified_chunks.get(id).?.metadata.road(road.index).?);
}

test "same-revision reload revisits road seeds reordered behind a partially processed cursor" {
    const a = std.testing.allocator;
    var f: PreparedBlueprintDrainTest = undefined;
    try f.init();
    defer f.deinit();
    const service = &f.fixture.service;
    const id = PreparedBlueprintDrainTest.chunk_id;
    var chunk = try BlueprintRoadSchedulingTest.makeChunk(2);
    var owns_chunk = true;
    defer if (owns_chunk) chunk.deinit(a);
    // Visit the higher row first. Persistence sorts roads by block index,
    // which moves every unvisited seed for the lower row behind this cursor.
    try std.testing.expectEqual(@as(usize, 8), chunk.metadata.roads.items.len);
    for (0..4) |index| std.mem.swap(@import("road_data.zig").Road, &chunk.metadata.roads.items[index], &chunk.metadata.roads.items[index + 4]);
    try service.worker_state.modified_chunks.put(a, id, chunk);
    owns_chunk = false;
    try queueBlueprintSaveTestRoadGate(service);
    try std.testing.expectEqual(@as(usize, 4), service.processBlueprintRoadUpdatesWithBudget(4));
    try std.testing.expectEqual(@as(usize, 4), service.blueprint_road_queue.peek().?.cursor);
    const before = service.worker_state.modified_chunks.get(id).?;
    const high = before.metadata.road(transformations.index(.{ 11, 7, 6 })).?;
    try std.testing.expect(high.slope != null);
    try std.testing.expect(before.metadata.road(transformations.index(.{ 11, 2, 6 })).?.slope == null);
    const revision = before.chunk_revision;
    service.requestSaveTransition(100, true);
    try f.waitSave(100);
    try std.testing.expect(!service.worker_state.modified_chunks.contains(id));
    var catalog = try f.store.snapshotCatalog();
    defer catalog.deinit();
    var read = (try catalog.prepareRead(id)).?;
    defer read.deinit();
    const reloaded = try service.readPersisted(&read);
    var owns_reload = true;
    defer if (owns_reload) reloaded.deinit(a);
    try std.testing.expectEqual(revision, reloaded.chunk_revision);
    try std.testing.expectEqual(transformations.index(.{ 11, 2, 6 }), reloaded.metadata.roads.items[0].index);
    try service.installLoaded(id, revision, reloaded);
    owns_reload = false;
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.peek().?.cursor);
    _ = service.processBlueprintRoadUpdatesWithBudget(16);
    try std.testing.expectEqual(@as(usize, 0), service.blueprint_road_queue.count);
    const after = service.worker_state.modified_chunks.get(id).?;
    try std.testing.expect(after.metadata.road(transformations.index(.{ 11, 2, 6 })).?.slope != null);
    try std.testing.expectEqualDeep(high, after.metadata.road(high.index).?);
}

test "background work warnings stay bounded across bursts, error changes, and recoveries" {
    var log: DeferredWorkLog = .{};
    try std.testing.expect(!log.recover());
    var warnings: usize = 0;
    var recoveries: usize = 0;
    // Ten thousand separate failed attempts followed by successful steps must
    // not bypass the shared limiter by repeatedly opening a new episode.
    for (0..10_000) |attempt| {
        if (log.failure(@as(i96, @intCast(attempt)) * std.time.ns_per_ms)) warnings += 1;
        if (log.recover()) recoveries += 1;
        try std.testing.expect(!log.recover());
    }
    try std.testing.expectEqual(@as(usize, 1), warnings);
    try std.testing.expectEqual(@as(usize, 1), recoveries);
    const interval = DeferredWorkLog.repeat_interval_ns;
    try std.testing.expect(!log.failure(interval - 1));
    try std.testing.expect(log.failure(interval));
    // A persistent failure gets a reminder at the exact 30-second boundary.
    try std.testing.expect(!log.failure(2 * interval - 1));
    try std.testing.expect(log.failure(2 * interval));
    try std.testing.expect(log.recover());
    try std.testing.expect(!log.recover());
    try std.testing.expect(!log.failure(2 * interval + 1));
    try std.testing.expect(!log.recover());
    try std.testing.expect(log.failure(3 * interval));
}

// The dedicated benchmark target can use the private payload layout in test
// builds. Importing the service never registers or runs the timing workload.
pub const PendingCommandBenchmark = if (@import("builtin").is_test) struct {
    pub fn run() !void {
        try @import("pending_command_benchmark.zig").run(WorldDataService.Pending, (persistence.Limits{}).pending_commands);
    }
} else void;
