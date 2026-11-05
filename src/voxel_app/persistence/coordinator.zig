//! Bounded no-COW encoder/writer pipeline. Only the service owns mutable sources.
const std = @import("std");
const Io = std.Io;
const format = @import("format.zig");
const storage = @import("storage.zig");
const blueprints = @import("blueprints.zig");
const deferred_work = @import("../deferred_world_work.zig");
const world = @import("../world.zig");
const transformations = @import("../block_transformations.zig");
const Road = @import("../road_data.zig").Road;

pub const Limits = struct {
    output_bytes: usize = 32 * 1024 * 1024,
    working_bytes: usize = 64 * 1024 * 1024,
    manifest_entries: usize = 65536,
    pending_commands: usize = 256,
    live_bytes: usize = 512 * 1024 * 1024,
    capture_wait_ns: u64 = 500 * std.time.ns_per_ms,
    player_wait_ns: u64 = 100 * std.time.ns_per_ms,
    overdue_ns: u64 = 180 * std.time.ns_per_s,
};
pub const Phase = enum { idle, capturing, writing, compacting, complete, failed };
pub const Status = struct {
    intent_id: u64 = 0,
    phase: Phase = .idle,
    sequence: u64 = 0,
    durable_sequence: u64 = 0,
    target_sequence: u64 = 0,
    tick: u64 = 0,
    source_count: usize = 0,
    pending_commands: usize = 0,
    output_bytes: usize = 0,
    output_peak_bytes: usize = 0,
    source_bytes: usize = 0,
    live_used_bytes: usize = 0,
    live_peak_bytes: usize = 0,
    live_allocation_count: u64 = 0,
    live_rejections: u64 = 0,
    confirmed_operations: u64 = 0,
    capture_waited_operations: u64 = 0,
    dependency_waited_operations: u64 = 0,
    max_player_wait_ns: u64 = 0,
    total_player_wait_ns: u64 = 0,
    timer_due_chunks: usize = 0,
    timer_due_events: usize = 0,
    oldest_timer_deadline: ?u64 = null,
    resident_chunks: usize = 0,
    retained_base_mismatch_chunks: usize = 0,
    overdue: bool = false,
    active: bool = false,
    progress_generation: u64 = 0,
    error_name: ?[]const u8 = null,
    deferred_work_error_name: ?[]const u8 = null,
    capture_started_ns: i96 = 0,
    sources_released_ns: i96 = 0,
    wal_committed_ns: i96 = 0,
    base_installed_ns: i96 = 0,
};
/// All descriptors/scalars are copied at the boundary. No live chunk header escapes.
pub const Source = struct {
    id: u32,
    revision: u64,
    epoch: u64,
    is_unreachable: bool,
    blocks: ?*const [32768]u8,
    roads: []const Road,
    constructed: []const transformations.BlockIndex,
    events: []const transformations.Event,
    retained_bytes: ?usize = null,

    pub fn freeze(id: u32, epoch: u64, chunk: *const world.WorldChunk) Source {
        return .{ .id = id, .revision = chunk.chunk_revision, .epoch = epoch, .is_unreachable = chunk.flags.is_unreachable, .blocks = if (chunk.content == .blocks) @ptrCast(&chunk.content.blocks.blocks) else null, .roads = chunk.metadata.roads.items, .constructed = chunk.metadata.constructed.items, .events = chunk.metadata.timed.events.items, .retained_bytes = (if (chunk.content == .blocks) @as(usize, 32768) else 0) + chunk.metadata.roads.capacity * @sizeOf(Road) + chunk.metadata.constructed.capacity * @sizeOf(transformations.BlockIndex) + chunk.metadata.timed.events.capacity * @sizeOf(transformations.Event) };
    }
    pub fn pinnedBytes(self: Source) usize {
        return self.retained_bytes orelse ((if (self.blocks != null) @as(usize, 32768) else 0) + self.roads.len * @sizeOf(Road) +
            self.constructed.len * @sizeOf(transformations.BlockIndex) + self.events.len * @sizeOf(transformations.Event));
    }
};
pub const Event = union(enum) {
    released: struct { epoch: u64, id: u32, revision: u64 },
    encoded: u64,
    committed: u64,
    compacted: u64,
    finished: struct { epoch: u64, failure: ?anyerror },
};
pub const Notify = struct { context: *anyopaque, send: *const fn (*anyopaque, Event) void };

pub fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub const Job = struct {
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
    store_mutex: *Io.Mutex,
    limits: Limits,
    notify: Notify,
    epoch: u64,
    sequence: u64,
    tick: u64,
    final: bool,
    sources: []Source,
    players: []u8,
    player_count: u64,
    /// Owned, already encoded authoritative changes through this capture fence.
    blueprint_changes: []u8 = &.{},
    /// Owned canonical complete set frozen at the same boundary as sources.
    pending_work: []u8 = &.{},
    /// The service supplies exact new-instance bitmap sizes. Direct callers
    /// derive a conservative summary without reading the writer-owned State.
    blueprint_summary: ?blueprints.PrepareSummary = null,
    /// Included in extra_working_bytes; admission may replace only this shared
    /// journal-array charge when its capacity grows during the running job.
    blueprint_journal_reserved_bytes: usize = 0,
    canceled: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    // A job enqueues at most one record per source, so a monotonic head uses
    // the reserved descriptor array without compaction, wraparound, or growth.
    output: std.ArrayList([]u8) = .empty,
    output_head: usize = 0,
    output_bytes: usize = 0,
    peak_bytes: usize = 0,
    released: []bool = &.{},
    priority: []bool = &.{},
    priority_next: usize = 0,
    commit_started: bool = false,
    // Peak service-owned capture bookkeeping and temporary preparation overlap.
    extra_working_bytes: usize = 0,
    working_reserved_bytes: usize = 0,
    encode_active_ns: u64 = 0,
    output_wait_ns: u64 = 0,
    encoded_bytes: u64 = 0,
    write_ns: u64 = 0,
    commit_ns: u64 = 0,
    installed_catalog: ?storage.BaseCatalog = null,
    start_ready: bool = false,
    start_failed: bool = false,
    encoder_finished: bool = false,
    encoder_error: ?anyerror = null,
    encoder: Io.Future(void) = undefined,
    writer: Io.Future(void) = undefined,

    pub fn start(self: *Job) !void {
        if (self.sources.len > self.limits.manifest_entries) return error.ManifestCapacityExceeded;
        var scratch: usize = 0;
        for (self.sources) |source| {
            // A small queue is safe when every source's worst-case record fits.
            // Check before workers borrow buffers so reserveOutput cannot deadlock.
            if (try outputBound(source) > self.limits.output_bytes) return error.OutputCapacityTooSmall;
            scratch = @max(scratch, try scratchBound(source));
        }
        const manifest = try std.math.mul(usize, self.sources.len, @sizeOf(Source) + 2 + @sizeOf([]u8));
        const blueprint_summary = if (self.blueprint_summary) |supplied| verified: {
            var framing_limits = self.store.limits.blueprints;
            // Count framing without pessimistic bitmap multiplication: exact
            // summaries can fit when max_cells times instance_count overflows.
            framing_limits.max_cells = 0;
            const framing = try blueprints.summarizeEncoded(self.blueprint_changes, framing_limits);
            var supplied_framing = supplied;
            supplied_framing.new_instance_bitmap_bytes = 0;
            if (!std.meta.eql(supplied_framing, framing)) return error.InvalidBlueprintSummary;
            const max_cells = self.store.limits.blueprints.max_cells;
            const bitmap_per_instance = max_cells / 8 + @intFromBool(max_cells % 8 != 0);
            const maximum_bitmap_bytes = std.math.mul(usize, framing.instance_count, bitmap_per_instance) catch std.math.maxInt(usize);
            if (supplied.new_instance_bitmap_bytes < framing.instance_count or supplied.new_instance_bitmap_bytes > maximum_bitmap_bytes)
                return error.InvalidBlueprintSummary;
            break :verified supplied;
        } else try blueprints.summarizeEncoded(self.blueprint_changes, self.store.limits.blueprints);
        const blueprint_prepare = try blueprints.prepareMemoryBound(blueprint_summary, self.store.limits.blueprints);
        // The empty set is valid without consulting world dimensions.
        if (self.pending_work.len != 0) try deferred_work.validate(self.pending_work, self.store.dimensions, self.store.limits.max_pending_work);
        self.working_reserved_bytes = try std.math.add(usize, self.limits.output_bytes, try std.math.add(usize, manifest, try std.math.add(usize, self.players.len + self.blueprint_changes.len, scratch + @sizeOf(Job))));
        self.working_reserved_bytes = try std.math.add(usize, self.working_reserved_bytes, blueprint_prepare);
        self.working_reserved_bytes = try std.math.add(usize, self.working_reserved_bytes, try pendingWorkMemoryBound(self.pending_work.len));
        self.working_reserved_bytes = try std.math.add(usize, self.working_reserved_bytes, self.extra_working_bytes);
        if (self.working_reserved_bytes > self.limits.working_bytes) return error.WorkingCapacityExceeded;
        self.released = try self.allocator.alloc(bool, self.sources.len);
        errdefer {
            self.allocator.free(self.released);
            self.released = &.{};
        }
        @memset(self.released, false);
        self.priority = try self.allocator.alloc(bool, self.sources.len);
        errdefer {
            self.allocator.free(self.priority);
            self.priority = &.{};
        }
        @memset(self.priority, false);
        self.priority_next = self.sources.len;
        try self.output.ensureTotalCapacityPrecise(self.allocator, self.sources.len);
        errdefer {
            self.output.deinit(self.allocator);
            self.output = .empty;
        }
        std.mem.sort(Source, self.sources, {}, struct {
            fn less(_: void, a: Source, b: Source) bool {
                return a.id < b.id;
            }
        }.less);
        self.encoder = try self.io.concurrent(encode, .{self});
        self.writer = self.io.concurrent(write, .{self}) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.start_failed = true;
            self.start_ready = true;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
            self.encoder.await(self.io);
            return err;
        };
        self.mutex.lockUncancelable(self.io);
        self.start_ready = true;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
    pub fn prioritize(self: *Job, ids: []const u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (ids) |id| {
            var lo: usize = 0;
            var hi = self.sources.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.sources[mid].id < id) lo = mid + 1 else hi = mid;
            }
            if (lo < self.sources.len and self.sources[lo].id == id and !self.released[lo]) {
                self.priority[lo] = true;
                self.priority_next = @min(self.priority_next, lo);
            }
        }
    }
    pub fn cancel(self: *Job) void {
        self.mutex.lockUncancelable(self.io);
        // Admission and the footer transition share this short lock. Never hold
        // it across disk I/O; cancellation cannot block the authority on a sync.
        if (!self.commit_started) self.canceled.store(true, .release);
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
    fn authorizeCommit(context: *anyopaque) bool {
        const self: *Job = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.canceled.load(.acquire)) return false;
        self.commit_started = true;
        return true;
    }
    pub fn deinit(self: *Job) void {
        self.writer.await(self.io);
        self.encoder.await(self.io);
        for (self.output.items[self.output_head..]) |bytes| self.allocator.free(bytes);
        self.output.deinit(self.allocator);
        if (self.installed_catalog) |*catalog| catalog.deinit();
        self.allocator.free(self.released);
        self.allocator.free(self.priority);
        self.allocator.free(self.sources);
        self.allocator.free(self.players);
        self.allocator.free(self.blueprint_changes);
        self.allocator.free(self.pending_work);
        self.allocator.destroy(self);
    }
    fn emit(self: *Job, event: Event) void {
        self.notify.send(self.notify.context, event);
    }
    fn encode(self: *Job) void {
        self.mutex.lockUncancelable(self.io);
        while (!self.start_ready) self.changed.waitUncancelable(self.io, &self.mutex);
        const failed = self.start_failed;
        self.mutex.unlock(self.io);
        // A failed start retains source ownership in its caller and emits no
        // completions for a job that was never published to the authority.
        if (failed) return;
        self.encodeAll() catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.encoder_error = err;
            self.mutex.unlock(self.io);
        };
        // Exactly one release per source, including failed/unvisited sources.
        // Completion storage can be reserved before either worker starts.
        for (self.sources, 0..) |source, i| {
            self.mutex.lockUncancelable(self.io);
            const already_released = self.released[i];
            self.released[i] = true;
            self.mutex.unlock(self.io);
            if (!already_released) self.emit(.{ .released = .{ .epoch = self.epoch, .id = source.id, .revision = source.revision } });
        }
        self.emit(.{ .encoded = self.epoch });
        self.mutex.lockUncancelable(self.io);
        self.encoder_finished = true;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
    fn encodeAll(self: *Job) !void {
        var next: usize = 0;
        for (0..self.sources.len) |_| {
            if (self.canceled.load(.acquire)) return error.CaptureCanceled;
            self.mutex.lockUncancelable(self.io);
            while (self.priority_next < self.sources.len and (!self.priority[self.priority_next] or self.released[self.priority_next])) self.priority_next += 1;
            while (next < self.sources.len and self.released[next]) next += 1;
            const index = if (self.priority_next < self.sources.len) self.priority_next else next;
            self.priority[index] = false;
            self.mutex.unlock(self.io);
            const source = self.sources[index];
            var reserved = try outputBound(source);
            try self.reserveOutput(reserved);
            defer if (reserved != 0) self.releaseOutput(reserved);
            const started = now(self.io);
            const record = try encodeSource(self.allocator, self.store.world_uuid, source);
            var owned = true;
            defer if (owned) self.allocator.free(record);
            self.mutex.lockUncancelable(self.io);
            self.encode_active_ns +|= @intCast(@max(0, now(self.io) - started));
            self.encoded_bytes +|= record.len;
            std.debug.assert(record.len <= reserved);
            self.output_bytes -= reserved - record.len;
            reserved = record.len;
            self.released[index] = true;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
            // The record already owns the source independently of the disk.
            self.emit(.{ .released = .{ .epoch = self.epoch, .id = source.id, .revision = source.revision } });
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.canceled.load(.acquire)) return error.CaptureCanceled;
            self.output.appendAssumeCapacity(record);
            owned = false;
            reserved = 0;
            self.changed.broadcast(self.io);
        }
    }
    fn reserveOutput(self: *Job, bytes: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const started = now(self.io);
        while (bytes > self.limits.output_bytes - self.output_bytes) {
            if (self.canceled.load(.acquire)) return error.CaptureCanceled;
            self.changed.waitUncancelable(self.io, &self.mutex);
        }
        self.output_wait_ns +|= @intCast(@max(0, now(self.io) - started));
        if (self.canceled.load(.acquire)) return error.CaptureCanceled;
        self.output_bytes += bytes;
        self.peak_bytes = @max(self.peak_bytes, self.output_bytes);
    }
    fn releaseOutput(self: *Job, bytes: usize) void {
        self.mutex.lockUncancelable(self.io);
        self.output_bytes -= bytes;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
    fn write(self: *Job) void {
        self.writeAll() catch |err| {
            self.cancel();
            // Cancellation/source release does not wait for WAL repair.
            self.encoder.await(self.io);
            self.store_mutex.lockUncancelable(self.io);
            self.store.cancelSnapshot() catch {};
            self.store.repair() catch {};
            self.store_mutex.unlock(self.io);
            self.emit(.{ .finished = .{ .epoch = self.epoch, .failure = err } });
            return;
        };
        self.emit(.{ .finished = .{ .epoch = self.epoch, .failure = null } });
    }
    fn writeAll(self: *Job) !void {
        self.store_mutex.lockUncancelable(self.io);
        defer self.store_mutex.unlock(self.io);
        const global = format.encodeGlobal(self.tick);
        try self.store.beginSnapshotWithState(self.sequence, &global, self.players, self.player_count, self.sources.len, self.blueprint_changes, self.pending_work);
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.output_head == self.output.items.len and !self.encoder_finished)
                self.changed.waitUncancelable(self.io, &self.mutex);
            if (self.output_head == self.output.items.len) {
                const failure = self.encoder_error;
                self.mutex.unlock(self.io);
                if (failure) |err| return err;
                break;
            }
            const record = self.output.items[self.output_head];
            self.output_head += 1;
            // Bytes remain charged while the writer owns them.
            self.mutex.unlock(self.io);
            defer {
                self.allocator.free(record);
                self.releaseOutput(record.len);
            }
            const started = now(self.io);
            try self.store.appendChunk(record);
            self.write_ns +|= @intCast(@max(0, now(self.io) - started));
        }
        const started = now(self.io);
        _ = try self.store.commitSnapshotControlled(self, authorizeCommit);
        self.commit_ns = @intCast(@max(0, now(self.io) - started));
        self.emit(.{ .committed = self.epoch });
        if (self.final) {
            try self.store.compact();
            self.installed_catalog = try self.store.snapshotCatalog();
            self.emit(.{ .compacted = self.epoch });
        }
    }
};

/// Capture owns one encoded set; the writer prepares one replacement before commit.
pub fn pendingWorkMemoryBound(encoded_len: usize) !usize {
    return std.math.mul(usize, encoded_len, 2);
}

fn encodeSource(allocator: std.mem.Allocator, uuid: [16]u8, source: Source) ![]u8 {
    const sorted = try allocator.dupe(Road, source.roads);
    defer allocator.free(sorted);
    std.mem.sort(Road, sorted, {}, struct {
        fn less(_: void, a: Road, b: Road) bool {
            return a.index < b.index;
        }
    }.less);
    const roads = try allocator.alloc(format.CustomRoad, sorted.len);
    defer allocator.free(roads);
    for (sorted, roads) |road, *encoded| encoded.* = .{ .formation = if (road.slope) |slope| .{
        .high_endpoint = slope.high_endpoint,
        .direction = @intCast(@intFromEnum(slope.downhill)),
        .length = slope.length,
        .section = slope.section,
    } else null };
    const constructed = try allocator.alloc(u16, source.constructed.len);
    defer allocator.free(constructed);
    for (source.constructed, constructed) |cell, *encoded| encoded.* = cell;
    const timers = try allocator.alloc(format.Timer, source.events.len);
    defer allocator.free(timers);
    for (source.events, timers) |event, *encoded| encoded.* = .{ .cell = event.block, .kind = @intFromEnum(event.kind), .deadline = event.due_tick };
    const encoded_metadata = try format.encodeMetadata(allocator, .{ .roads = roads, .construction = constructed, .timers = timers });
    defer allocator.free(encoded_metadata);
    const air = [_]u8{0} ** 32768;
    return format.encodeChunk(allocator, uuid, .{ .id = source.id, .revision = source.revision, .is_unreachable = source.is_unreachable, .blocks = if (source.blocks) |blocks| blocks else &air, .metadata = encoded_metadata });
}

fn metadataBound(source: Source) !usize {
    if (source.roads.len > format.cell_count or source.constructed.len > format.cell_count or source.events.len > format.cell_count) return error.InvalidMetadata;
    var size: usize = 0;
    if (source.roads.len != 0) size += 9 + source.roads.len * 23;
    if (source.constructed.len != 0) size += 9 + source.constructed.len * 2;
    if (source.events.len != 0) size += 9 + source.events.len * 11;
    return size;
}
pub fn outputBound(source: Source) !usize {
    return 58 + (if (source.blocks != null) @as(usize, format.cell_count) else 0) + try metadataBound(source);
}
pub fn scratchBound(source: Source) !usize {
    // Temporary encoded metadata overlaps the final record. RLE uses a bounded
    // stack buffer; allocator/stack overhead remains outside process-RAM claims.
    return try metadataBound(source) + source.roads.len * (@sizeOf(Road) + @sizeOf(format.CustomRoad)) + source.constructed.len * @sizeOf(u16) + source.events.len * @sizeOf(format.Timer);
}

/// Admission can reserve a legal source's scratch without scanning chunk data.
pub fn maximumScratchBound() usize {
    return format.maximum_metadata_size + format.cell_count * (@sizeOf(Road) + @sizeOf(format.CustomRoad) + @sizeOf(u16) + @sizeOf(format.Timer));
}

test "job reserves blueprint preparation before allocating or starting workers" {
    const operation: blueprints.Op = .{ .instance = .{ .id = 1, .definition_id = 1, .owner = 1, .origin = .{ 0, 0, 0 }, .rotation = 0 } };
    const changes = try blueprints.encodeOps(std.testing.allocator, &.{operation});
    defer std.testing.allocator.free(changes);
    var exact: blueprints.PrepareSummary = .{};
    try exact.addOperation(operation, 8);
    var store: storage.Store = undefined;
    store.limits = .{};
    var store_mutex: Io.Mutex = .init;
    var sources = [_]Source{.{ .id = 0, .revision = 1, .epoch = 1, .is_unreachable = false, .blocks = null, .roads = &.{}, .constructed = &.{}, .events = &.{} }};
    const baseline = 64 + @sizeOf(Source) + 2 + @sizeOf([]u8) + changes.len + @sizeOf(Job);
    for ([_]?blueprints.PrepareSummary{ exact, null }) |supplied| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var job: Job = .{
            .allocator = failing.allocator(),
            .io = std.testing.io,
            .store = &store,
            .store_mutex = &store_mutex,
            .limits = .{ .output_bytes = 64, .working_bytes = baseline },
            .notify = .{ .context = &store, .send = struct {
                fn send(_: *anyopaque, _: Event) void {
                    unreachable;
                }
            }.send },
            .epoch = 1,
            .sequence = 1,
            .tick = 0,
            .final = false,
            .sources = &sources,
            .players = &.{},
            .player_count = 0,
            .blueprint_changes = changes,
            .blueprint_summary = supplied,
        };
        if (supplied) |valid| {
            var missing_bitmap = valid;
            missing_bitmap.new_instance_bitmap_bytes = 0;
            var oversized_bitmap = valid;
            oversized_bitmap.new_instance_bitmap_bytes = store.limits.blueprints.max_cells / 8 + 1;
            for ([_]blueprints.PrepareSummary{ .{}, missing_bitmap, oversized_bitmap }) |invalid| {
                job.blueprint_summary = invalid;
                try std.testing.expectError(error.InvalidBlueprintSummary, job.start());
                try std.testing.expect(!failing.has_induced_failure);
            }
            job.blueprint_summary = valid;
        }
        try std.testing.expectError(error.WorkingCapacityExceeded, job.start());
        try std.testing.expect(!failing.has_induced_failure);
        const summary = supplied orelse try blueprints.summarizeEncoded(changes, store.limits.blueprints);
        try std.testing.expectEqual(baseline + try blueprints.prepareMemoryBound(summary, store.limits.blueprints), job.working_reserved_bytes);
        // At the exact bound the next failure is the first descriptor allocation,
        // so no writer can observe this deliberately uninitialized Store.
        job.limits.working_bytes = job.working_reserved_bytes;
        try std.testing.expectError(error.OutOfMemory, job.start());
        try std.testing.expect(failing.has_induced_failure);
    }
}

test "capture pending-work memory includes captured and prepared copies before allocation" {
    const pending = [_]u8{ 1, 0, 0, 0, 0 };
    var store: storage.Store = undefined;
    store.limits = .{};
    store.dimensions = .{ 4, 4, 4 };
    var mutex: Io.Mutex = .init;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const baseline = 64 + @sizeOf(Job);
    var job: Job = .{
        .allocator = failing.allocator(),
        .io = std.testing.io,
        .store = &store,
        .store_mutex = &mutex,
        .limits = .{ .output_bytes = 64, .working_bytes = baseline },
        .notify = .{ .context = &store, .send = struct {
            fn send(_: *anyopaque, _: Event) void {
                unreachable;
            }
        }.send },
        .epoch = 1,
        .sequence = 1,
        .tick = 0,
        .final = false,
        .sources = &.{},
        .players = &.{},
        .player_count = 0,
        .pending_work = @constCast(&pending),
    };
    try std.testing.expectError(error.WorkingCapacityExceeded, job.start());
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(baseline + try pendingWorkMemoryBound(pending.len), job.working_reserved_bytes);
    try std.testing.expectError(error.Overflow, pendingWorkMemoryBound(std.math.maxInt(usize)));
}
