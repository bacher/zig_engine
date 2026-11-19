//! Client-owned complete warehouse replicas. Discovery/functional retention and
//! logical prediction are independent of terrain surfaces and GPU residency.
const std = @import("std");
const stream = @import("warehouse_stream.zig");
const state = @import("warehouse_state.zig");
const layout = @import("warehouse_layout.zig");
const command = @import("construction_state.zig");
const ChunkId = @import("consts.zig").ChunkId;
pub const Identity = stream.Identity;

pub const Limits = struct { objects: u32 = 4096, chunks: u32 = 8192, references: usize = 32768, pending: usize = 256 };
pub const Dependency = enum(u3) { dialog, transfer, recovery, collision };
pub const Entry = struct {
    identity: Identity,
    geometry: layout.Geometry,
    derived_layout: layout.Layout,
    subscription_id: u64 = 0,
    record: ?state.Record = null,
    resolved_sequence: u64 = 0,
    references: usize = 0,
    dependencies: std.EnumSet(Dependency) = .initEmpty(),
    resync: bool = true,
    retired: bool = false,
    control_queued: bool = false,
    visual_queued: bool = false,

    pub fn needed(self: Entry) bool {
        return self.references != 0 or self.dependencies.count() != 0;
    }
};
const Chunk = struct { subscription_id: u64, revision: u64, references: []const stream.Reference };
pub const Pending = struct { request_id: u64, command: command.CommandIdentity, identity: Identity, delta: i8, material: @import("engine").voxel_chunk.BlockType };
pub const Occupancy = union(enum) { unowned, unknown, empty, cargo: state.Record, member: state.Record };

pub const Cache = struct {
    world_session: u64 = 0,
    world_size: layout.Cell = .{ 1024, 1024, 1024 },
    revision: u64 = 0,
    limits: Limits = .{},
    objects: std.AutoHashMapUnmanaged(Identity, Entry) = .empty,
    chunks: std.AutoHashMapUnmanaged(ChunkId, Chunk) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    reference_count: usize = 0,
    controls: std.ArrayList(Identity) = .empty,
    /// Deduplicated changes to the cargo/marker cut, independent of inventory
    /// admission and subscription controls. Reserved incoming stock is invisible.
    visual_changes: std.ArrayList(Identity) = .empty,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| allocator.free(chunk.references);
        self.chunks.deinit(allocator);
        self.objects.deinit(allocator);
        self.pending.deinit(allocator);
        self.controls.deinit(allocator);
        self.visual_changes.deinit(allocator);
        self.* = .{};
    }

    pub fn acceptSession(self: *Cache, session: u64) bool {
        if (session == 0) return false;
        if (self.world_session == 0) self.world_session = session;
        return self.world_session == session;
    }

    fn matches(self: *const Cache, identity: Identity) bool {
        return identity.kind == .warehouse and identity.world_session == self.world_session and identity.id != 0 and identity.lifetime != 0;
    }

    fn queueControl(self: *Cache, identity: Identity) void {
        const entry = self.objects.getPtr(identity) orelse return;
        if (entry.control_queued) return;
        self.controls.appendAssumeCapacity(identity);
        entry.control_queued = true;
    }

    fn visualKey(self: *const Cache, identity: Identity) ?struct { stock: u16, active: u8, material: @import("engine").voxel_chunk.BlockType } {
        const value = self.record(identity) orelse return null;
        return .{ .stock = value.stock, .active = value.active, .material = value.material };
    }

    pub fn queueVisual(self: *Cache, identity: Identity) void {
        const entry = self.objects.getPtr(identity) orelse return;
        if (entry.visual_queued) return;
        self.visual_changes.appendAssumeCapacity(identity);
        entry.visual_queued = true;
    }

    pub fn clearVisualChanges(self: *Cache) void {
        for (self.visual_changes.items) |identity| if (self.objects.getPtr(identity)) |entry| {
            entry.visual_queued = false;
        };
        self.visual_changes.clearRetainingCapacity();
    }

    pub fn forget(self: *Cache, identity: Identity) void {
        for (self.visual_changes.items, 0..) |value, index| if (std.meta.eql(value, identity)) {
            _ = self.visual_changes.swapRemove(index);
            break;
        };
        _ = self.objects.remove(identity);
    }

    pub fn ensure(self: *Cache, allocator: std.mem.Allocator, reference: stream.Reference) !*Entry {
        if (!self.matches(reference.identity)) return error.InvalidWarehouseIdentity;
        try reference.geometry.validate(self.world_size);
        if (self.objects.getPtr(reference.identity)) |entry| {
            if (!std.meta.eql(entry.geometry, reference.geometry)) return error.InvalidWarehouseGeometry;
            return entry;
        }
        if (self.objects.count() >= self.limits.objects) return error.WarehouseCacheCapacity;
        try self.controls.ensureTotalCapacity(allocator, self.objects.count() + 1);
        try self.visual_changes.ensureTotalCapacity(allocator, self.objects.count() + 1);
        const result = try self.objects.getOrPut(allocator, reference.identity);
        result.value_ptr.* = .{ .identity = reference.identity, .geometry = reference.geometry, .derived_layout = layout.Layout.init(reference.geometry) };
        return result.value_ptr;
    }

    /// Full chunk discovery replaces one coherent generation. Object records are
    /// not embedded here, and stock revisions never rewrite these references.
    pub fn installChunk(self: *Cache, allocator: std.mem.Allocator, id: ChunkId, subscription_id: u64, revision: u64, references: []const stream.Reference) !bool {
        const old = self.chunks.get(id);
        if (old) |value| if (subscription_id < value.subscription_id or (subscription_id == value.subscription_id and revision < value.revision)) return false;
        if (old == null and self.chunks.count() >= self.limits.chunks) return error.WarehouseCacheCapacity;
        const old_count = if (old) |value| value.references.len else 0;
        if (references.len > self.limits.references -| (self.reference_count - old_count)) return error.WarehouseCacheCapacity;
        var additional: u32 = 0;
        for (references, 0..) |reference, index| {
            if (!self.matches(reference.identity)) return error.InvalidWarehouseIdentity;
            try reference.geometry.validate(self.world_size);
            for (references[0..index]) |previous| if (std.meta.eql(previous.identity, reference.identity)) return error.InvalidWarehouseDiscovery;
            if (self.objects.get(reference.identity)) |entry| {
                if (!std.meta.eql(entry.geometry, reference.geometry)) return error.InvalidWarehouseGeometry;
            } else additional += 1;
        }
        if (additional > self.limits.objects -| self.objects.count()) return error.WarehouseCacheCapacity;
        const copy = try allocator.dupe(stream.Reference, references);
        errdefer allocator.free(copy);
        try self.chunks.ensureUnusedCapacity(allocator, 1);
        try self.objects.ensureUnusedCapacity(allocator, additional);
        try self.controls.ensureTotalCapacity(allocator, self.objects.count() + additional);
        try self.visual_changes.ensureTotalCapacity(allocator, self.objects.count() + additional);
        // Every fallible step precedes discovery/refcount publication.
        for (references) |reference| if (!self.objects.contains(reference.identity)) {
            self.objects.putAssumeCapacity(reference.identity, .{ .identity = reference.identity, .geometry = reference.geometry, .derived_layout = layout.Layout.init(reference.geometry) });
        };
        if (old) |value| {
            for (value.references) |reference| {
                self.objects.getPtr(reference.identity).?.references -= 1;
                self.queueControl(reference.identity);
                self.queueVisual(reference.identity);
            }
        }
        for (references) |reference| {
            self.objects.getPtr(reference.identity).?.references += 1;
            self.queueControl(reference.identity);
            self.queueVisual(reference.identity);
        }
        self.chunks.putAssumeCapacity(id, .{ .subscription_id = subscription_id, .revision = revision, .references = copy });
        if (old) |value| allocator.free(value.references);
        self.reference_count = self.reference_count - old_count + references.len;
        self.revision +%= 1;
        return true;
    }

    pub fn removeChunk(self: *Cache, allocator: std.mem.Allocator, id: ChunkId) void {
        const removed = self.chunks.fetchRemove(id) orelse return;
        for (removed.value.references) |reference| if (self.objects.getPtr(reference.identity)) |entry| {
            entry.references -= 1;
            self.queueControl(reference.identity);
            self.queueVisual(reference.identity);
        };
        self.reference_count -= removed.value.references.len;
        allocator.free(removed.value.references);
        self.revision +%= 1;
    }

    pub fn pin(self: *Cache, identity: Identity, dependency: Dependency, enabled: bool) void {
        const entry = self.objects.getPtr(identity) orelse return;
        const needed = entry.needed();
        if (enabled) entry.dependencies.insert(dependency) else entry.dependencies.remove(dependency);
        self.queueControl(identity);
        if (needed != entry.needed()) self.queueVisual(identity);
    }

    pub fn subscribed(self: *Cache, identity: Identity, token: u64) void {
        const before = self.visualKey(identity);
        const entry = self.objects.getPtr(identity) orelse return;
        std.debug.assert(token != 0);
        entry.subscription_id = token;
        entry.record = null;
        entry.resolved_sequence = 0;
        entry.resync = false;
        self.revision +%= 1;
        if (before != null) self.queueVisual(identity);
    }

    pub fn invalidate(self: *Cache, identity: Identity) void {
        const entry = self.objects.getPtr(identity) orelse return;
        if (entry.retired) return;
        entry.resync = true;
        self.queueVisual(identity);
        self.queueControl(identity);
        self.revision +%= 1;
    }

    fn installRecord(entry: *Entry, value: state.Record, resolved_sequence: u64) bool {
        value.validate() catch return false;
        if (entry.retired or !std.meta.eql(value.identity, entry.identity) or !std.meta.eql(value.geometry, entry.geometry)) return false;
        if (resolved_sequence < entry.resolved_sequence) return false;
        if (entry.record) |old| if (value.revision < old.revision) return false;
        entry.record = value;
        entry.resolved_sequence = resolved_sequence;
        entry.resync = false;
        return true;
    }

    /// Management outcomes carry the same evaluated-command fence as transfer
    /// outcomes, even though they have no stock prediction of their own.
    pub fn acceptResultRecord(self: *Cache, value: state.Record, resolved_sequence: u64) bool {
        if (!self.matches(value.identity)) return false;
        const entry = self.objects.getPtr(value.identity) orelse return false;
        const before = self.visualKey(value.identity);
        if (!installRecord(entry, value, resolved_sequence)) return false;
        if (!std.meta.eql(before, self.visualKey(value.identity))) self.queueVisual(value.identity);
        self.revision +%= 1;
        return true;
    }

    pub fn apply(self: *Cache, update: stream.Update) bool {
        const identity = switch (update) {
            inline else => |value| value.identity,
        };
        const token = switch (update) {
            inline else => |value| value.subscription_id,
        };
        const entry = self.objects.getPtr(identity) orelse return false;
        if (!self.matches(identity) or entry.subscription_id == 0 or entry.subscription_id != token or entry.retired) return false;
        const before = self.visualKey(identity);
        switch (update) {
            .snapshot => |snapshot| {
                if (!installRecord(entry, snapshot.record, snapshot.resolved_sequence)) return false;
            },
            .unavailable => {
                entry.resync = true;
                self.queueControl(identity);
            },
            .retired => {
                entry.retired = true;
                entry.record = null;
                entry.resync = false;
            },
        }
        if (!std.meta.eql(before, self.visualKey(identity))) self.queueVisual(identity);
        self.revision +%= 1;
        return true;
    }

    /// A command result may establish a newer baseline before subscription
    /// publication. It cannot roll back a later simulation/object revision.
    pub fn resolveResult(self: *Cache, request_id: u64, value_record: ?state.Record, retired: ?Identity, resolved_sequence: u64) bool {
        var expected: ?Identity = null;
        for (self.pending.items) |pending| if (pending.request_id == request_id) {
            expected = pending.identity;
            break;
        };
        const identity = expected orelse return false;
        const before = self.visualKey(identity);
        if (value_record) |value| {
            value.validate() catch return false;
            if (!std.meta.eql(identity, value.identity)) return false;
            const entry = self.objects.get(identity) orelse return false;
            if (!std.meta.eql(entry.geometry, value.geometry)) return false;
        }
        if (retired) |value| if (!std.meta.eql(identity, value)) return false;
        var index: usize = 0;
        var matched = false;
        while (index < self.pending.items.len) {
            if (self.pending.items[index].request_id == request_id) {
                const removed = self.pending.orderedRemove(index);
                if (self.objects.getPtr(removed.identity)) |entry| {
                    var retained = false;
                    for (self.pending.items) |other| if (std.meta.eql(other.identity, removed.identity)) {
                        retained = true;
                        break;
                    };
                    if (!retained) {
                        entry.dependencies.remove(.transfer);
                        self.queueControl(removed.identity);
                    }
                }
                matched = true;
            } else index += 1;
        }
        if (!matched) return false;
        if (value_record) |value| if (self.objects.getPtr(value.identity)) |entry| {
            _ = installRecord(entry, value, resolved_sequence);
        };
        if (retired) |retired_identity| if (self.objects.getPtr(retired_identity)) |entry| {
            entry.retired = true;
            entry.record = null;
            entry.resync = false;
        };
        self.revision +%= 1;
        if (!std.meta.eql(before, self.visualKey(identity))) self.queueVisual(identity);
        return true;
    }

    pub fn predict(self: *Cache, allocator: std.mem.Allocator, value: Pending) !void {
        if (self.pending.items.len >= self.limits.pending) return error.WarehouseCacheCapacity;
        if (self.record(value.identity) == null) return error.MissingWarehouseData;
        for (self.pending.items) |existing| if (existing.request_id == value.request_id) return error.DuplicateWarehousePrediction;
        try self.pending.append(allocator, value);
        self.pin(value.identity, .transfer, true);
        self.queueVisual(value.identity);
        self.revision +%= 1;
    }

    pub fn record(self: *const Cache, identity: Identity) ?state.Record {
        const entry = self.objects.get(identity) orelse return null;
        if (entry.retired or entry.resync) return null;
        var value = entry.record orelse return null;
        for (self.pending.items) |prediction| {
            if (!std.meta.eql(prediction.identity, identity) or prediction.command.sequence <= entry.resolved_sequence or prediction.material != value.material) continue;
            if (prediction.delta > 0) {
                if (@as(u32, value.stock) + value.incoming < @as(u32, value.active) * layout.levels) value.stock += 1;
            } else if (value.stock != 0) value.stock -= 1;
        }
        return value;
    }

    pub fn chunkReferences(self: *const Cache, id: ChunkId) []const stream.Reference {
        return if (self.chunks.get(id)) |chunk| chunk.references else &.{};
    }

    pub fn occupancy(self: *const Cache, id: ChunkId, world_width: u32, cell: layout.Cell) Occupancy {
        for (self.chunkReferences(id)) |reference| {
            const relative = reference.geometry.relativeCell(world_width, cell) orelse continue;
            if (!reference.geometry.containsBody(relative)) continue;
            const entry = self.objects.get(reference.identity) orelse return .unknown;
            if (entry.retired) continue;
            const value = self.record(reference.identity) orelse return .unknown;
            if (entry.derived_layout.occupied(value.stock, value.active, relative)) return .{ .cargo = value };
            if (value.geometry.containsMember(relative)) return .{ .member = value };
            return .empty;
        }
        return .unowned;
    }

    pub fn claimed(self: *const Cache, id: ChunkId, world_width: u32, cell: layout.Cell) bool {
        for (self.chunkReferences(id)) |reference| {
            const entry = self.objects.get(reference.identity) orelse return true;
            if (entry.retired) continue;
            const relative = reference.geometry.relativeCell(world_width, cell) orelse continue;
            if (reference.geometry.containsEnvelope(relative)) return true;
        }
        return false;
    }
};

fn testRecord() state.Record {
    return .{ .identity = .{ .kind = .warehouse, .world_session = 91, .id = 1, .lifetime = 1 }, .geometry = .{ .origin = .{ 31, 31, 31 }, .bounds = .{ .xmin = 0, .xmax = 0, .ymin = 0, .ymax = 0 } }, .material = .dirt, .active = 1, .stock = 2, .revision = 1 };
}

fn testCache(allocator: std.mem.Allocator) !Cache {
    var cache: Cache = .{};
    errdefer cache.deinit(allocator);
    _ = cache.acceptSession(91);
    const value = testRecord();
    _ = try cache.installChunk(allocator, 1, 1, 1, &.{.{ .identity = value.identity, .geometry = value.geometry }});
    cache.subscribed(value.identity, 7);
    _ = cache.apply(.{ .snapshot = .{ .identity = value.identity, .record = value, .subscription_id = 7 } });
    return cache;
}

fn testPrediction(sequence: u64) Pending {
    return .{ .request_id = sequence, .command = .{ .world_session = 91, .client_session = 5, .sequence = sequence }, .identity = testRecord().identity, .delta = 1, .material = .dirt };
}

test "warehouse snapshot fence absorbs only evaluated predictions and retains result ownership" {
    const a = std.testing.allocator;
    var cache = try testCache(a);
    defer cache.deinit(a);
    const identity = testRecord().identity;
    try cache.predict(a, testPrediction(3));
    try cache.predict(a, testPrediction(5));
    try std.testing.expectEqual(@as(u16, 4), cache.record(identity).?.stock);
    var updated = testRecord();
    updated.stock = 3;
    updated.revision = 2;
    try std.testing.expect(cache.apply(.{ .snapshot = .{ .identity = identity, .record = updated, .subscription_id = 7, .resolved_sequence = 3 } }));
    try std.testing.expectEqual(@as(u16, 4), cache.record(identity).?.stock);
    try std.testing.expectEqual(@as(usize, 2), cache.pending.items.len);
    try std.testing.expect(cache.resolveResult(3, updated, null, 3));
    try std.testing.expectEqual(@as(u16, 4), cache.record(identity).?.stock);
    // An unrelated simulation change is retained when a rejected result's old
    // object arrives; only that command's overlay disappears.
    updated.stock = 2;
    updated.revision = 4;
    try std.testing.expect(cache.apply(.{ .snapshot = .{ .identity = identity, .record = updated, .subscription_id = 7, .resolved_sequence = 4 } }));
    try std.testing.expectEqual(@as(u16, 3), cache.record(identity).?.stock);
    try std.testing.expect(cache.resolveResult(5, testRecord(), null, 5));
    try std.testing.expectEqual(@as(u16, 2), cache.record(identity).?.stock);
    try std.testing.expect(!cache.resolveResult(5, testRecord(), null, 5));
}

test "warehouse result before snapshot preserves later accepted stock and token renewal guards" {
    const a = std.testing.allocator;
    var cache = try testCache(a);
    defer cache.deinit(a);
    const identity = testRecord().identity;
    try cache.predict(a, testPrediction(1));
    var result = testRecord();
    result.stock = 3;
    result.revision = 2;
    try std.testing.expect(cache.resolveResult(1, result, null, 1));
    result.stock = 4;
    result.revision = 3;
    _ = cache.apply(.{ .snapshot = .{ .identity = identity, .record = result, .subscription_id = 7, .resolved_sequence = 1 } });
    try std.testing.expectEqual(@as(u16, 4), cache.record(identity).?.stock);
    cache.subscribed(identity, 8);
    try std.testing.expect(!cache.apply(.{ .snapshot = .{ .identity = identity, .record = result, .subscription_id = 7 } }));
    try std.testing.expect(cache.record(identity) == null);
    _ = cache.apply(.{ .retired = .{ .identity = identity, .subscription_id = 8 } });
    try std.testing.expect(!cache.apply(.{ .snapshot = .{ .identity = identity, .record = result, .subscription_id = 8 } }));
}

test "warehouse discovery guards body unknown while halo stays traversable and claimed" {
    const a = std.testing.allocator;
    var cache = try testCache(a);
    defer cache.deinit(a);
    const identity = testRecord().identity;
    cache.invalidate(identity);
    try std.testing.expect(cache.occupancy(1, 1024, .{ 31, 31, 31 }) == .unknown);
    try std.testing.expect(cache.occupancy(1, 1024, .{ 32, 31, 31 }) == .unowned);
    try std.testing.expect(cache.claimed(1, 1024, .{ 32, 31, 31 }));
    cache.pin(identity, .dialog, true);
    cache.removeChunk(a, 1);
    try std.testing.expect(cache.objects.get(identity).?.needed());
    cache.pin(identity, .dialog, false);
    try std.testing.expect(!cache.objects.get(identity).?.needed());
}

test "warehouse deduplicated references retain one identity across chunk handoff" {
    const a = std.testing.allocator;
    var cache = try testCache(a);
    defer cache.deinit(a);
    const value = testRecord();
    _ = try cache.installChunk(a, 2, 4, 1, &.{.{ .identity = value.identity, .geometry = value.geometry }});
    try std.testing.expectEqual(@as(u32, 1), cache.objects.count());
    cache.removeChunk(a, 1);
    try std.testing.expectEqual(@as(usize, 1), cache.objects.get(value.identity).?.references);
    try std.testing.expect(!try cache.installChunk(a, 2, 3, 9, &.{}));
    try std.testing.expect(cache.record(value.identity) != null);
    _ = try cache.installChunk(a, 2, 4, 2, &.{});
    try std.testing.expect(!cache.objects.get(value.identity).?.needed());
}

fn allocationDiscovery(a: std.mem.Allocator) !void {
    var cache: Cache = .{};
    defer cache.deinit(a);
    _ = cache.acceptSession(91);
    const value = testRecord();
    _ = cache.installChunk(a, 1, 1, 1, &.{.{ .identity = value.identity, .geometry = value.geometry }}) catch |err| {
        try std.testing.expectEqual(@as(u32, 0), cache.objects.count());
        try std.testing.expectEqual(@as(u32, 0), cache.chunks.count());
        try std.testing.expectEqual(@as(usize, 0), cache.reference_count);
        return err;
    };
}

test "warehouse discovery allocation failures publish no owner or reference" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationDiscovery, .{});
}

test "warehouse later observer result fence absorbs earlier pending prediction" {
    const a = std.testing.allocator;
    var cache = try testCache(a);
    defer cache.deinit(a);
    const identity = testRecord().identity;
    try cache.predict(a, testPrediction(1));
    try cache.predict(a, testPrediction(2));
    var second = testRecord();
    second.stock = 4;
    second.revision = 3;
    try std.testing.expect(cache.resolveResult(2, second, null, 2));
    try std.testing.expectEqual(@as(u16, 4), cache.record(identity).?.stock);
    try std.testing.expectEqual(@as(usize, 1), cache.pending.items.len);
    var first = testRecord();
    first.stock = 3;
    first.revision = 2;
    try std.testing.expect(cache.resolveResult(1, first, null, 1));
    try std.testing.expectEqual(@as(u16, 4), cache.record(identity).?.stock);
}
