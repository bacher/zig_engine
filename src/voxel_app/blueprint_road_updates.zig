//! Coalesced road work caused by real blueprint fulfillment. Queue publication
//! is separate from planning and structural validation, keeping fills constant work.
const std = @import("std");
const deferred_work = @import("deferred_world_work.zig");
pub const capacity: usize = 4096;
pub const Batch = struct {
    ids: [10]u32 = undefined,
    count: u4 = 0,

    pub fn add(self: *Batch, id: u32) void {
        for (self.ids[0..self.count]) |previous| if (previous == id) return;
        std.debug.assert(self.count < self.ids.len);
        self.ids[self.count] = id;
        self.count += 1;
    }
};
pub const Entry = struct { id: u32, cursor: usize = 0, dirty_again: bool = false, observed_revision: ?u64 = null };
pub const Queue = struct {
    entries: [capacity]Entry = undefined,
    slots: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    head: usize = 0,
    count: usize = 0,
    /// Changes only when durable membership changes, never for cursor progress.
    generation: u64 = 0,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    /// No semantic queue change on failure. Call before the fill mutates terrain.
    pub fn reserve(self: *Queue, allocator: std.mem.Allocator, batch: Batch) !void {
        return self.reserveWithLimit(allocator, batch, capacity);
    }

    /// Share the membership lookup with durable storage admission. Existing
    /// keys remain coalescible at the limit without allocation or extra probes.
    pub fn reserveWithLimit(self: *Queue, allocator: std.mem.Allocator, batch: Batch, limit: usize) !void {
        var additional: usize = 0;
        for (batch.ids[0..batch.count]) |id| if (!self.slots.contains(id)) {
            additional += 1;
        };
        if (additional > @min(capacity, limit) -| self.count) return error.RoadUpdatesFull;
        if (additional != 0) try self.slots.ensureUnusedCapacity(allocator, @intCast(additional));
    }

    /// Infallible after reserve, and only called for an accepted real fill.
    pub fn commit(self: *Queue, batch: Batch) void {
        for (batch.ids[0..batch.count]) |id| {
            if (self.slots.get(id)) |slot| {
                if (self.entries[slot].cursor != 0) self.entries[slot].dirty_again = true;
                continue;
            }
            std.debug.assert(self.count < capacity);
            const slot = (self.head + self.count) % capacity;
            self.entries[slot] = .{ .id = id };
            self.slots.putAssumeCapacity(id, slot);
            self.count += 1;
            self.generation +%= 1;
        }
    }

    /// Owned immutable capture, independent of later progress or invalidation.
    pub fn snapshotKeys(self: *const Queue, allocator: std.mem.Allocator) ![]deferred_work.Key {
        const keys = try allocator.alloc(deferred_work.Key, self.count);
        for (keys, 0..) |*key, offset| key.* = .{
            .kind = .road_shape,
            .chunk_id = self.entries[(self.head + offset) % capacity].id,
        };
        std.mem.sort(deferred_work.Key, keys, {}, deferred_work.lessThan);
        return keys;
    }

    pub fn snapshotEncoded(self: *const Queue, allocator: std.mem.Allocator, dimensions: [3]u32, max_entries: usize) ![]u8 {
        if (self.count > max_entries) return error.Capacity;
        const keys = try self.snapshotKeys(allocator);
        defer allocator.free(keys);
        return deferred_work.encode(allocator, keys, dimensions, max_entries);
    }

    /// Recreate scheduling from durable keys without loading any world data.
    /// Validation and allocation complete before membership changes. Runtime
    /// cursors/repasses intentionally restart; restored state is already saved.
    pub fn restore(self: *Queue, allocator: std.mem.Allocator, keys: []const deferred_work.Key) !void {
        if (self.count != 0) return error.RoadUpdatesNotEmpty;
        if (keys.len > capacity) return error.RoadUpdatesFull;
        for (keys, 0..) |key, index| {
            if (key.kind != .road_shape) return error.UnsupportedWorkKind;
            if (index != 0 and !deferred_work.lessThan({}, keys[index - 1], key)) return error.InvalidDeferredWork;
        }
        try self.slots.ensureUnusedCapacity(allocator, @intCast(keys.len));
        self.head = 0;
        for (keys, 0..) |key, slot| {
            self.entries[slot] = .{ .id = key.chunk_id };
            self.slots.putAssumeCapacity(key.chunk_id, slot);
        }
        self.count = keys.len;
        self.generation = 0;
    }

    /// Encoding canonicalizes metadata order even at the same chunk revision.
    /// Restart its pass when resident data is replaced by a persisted version.
    pub fn restartAfterLoad(self: *Queue, id: u32) void {
        const slot = self.slots.get(id) orelse return;
        self.entries[slot] = .{ .id = id };
    }

    pub fn peek(self: *Queue) ?*Entry {
        return if (self.count == 0) null else &self.entries[self.head];
    }

    pub fn advance(self: *Queue) void {
        self.peek().?.cursor += 1;
    }

    /// Keep this pass moving when metadata changes. A later pass revisits any
    /// road moved behind the cursor by swap-removal or added after its visit.
    pub fn observeRevision(self: *Queue, revision: u64) void {
        const entry = self.peek().?;
        if (entry.observed_revision) |previous| if (previous != revision and entry.cursor != 0) {
            entry.dirty_again = true;
        };
        entry.observed_revision = revision;
    }

    /// Return true when a queue slot becomes free. A dirty pass rejoins the tail
    /// so quieter chunks progress before its next pass. Any borrowed entry
    /// pointer is invalid after this call, even when the count stays unchanged.
    pub fn finish(self: *Queue) bool {
        const entry = self.peek().?;
        if (entry.dirty_again) {
            const id = entry.id;
            const tail = (self.head + self.count) % capacity;
            self.head = (self.head + 1) % capacity;
            // When full, tail is the old head; when alone, it is the new head.
            self.entries[tail] = .{ .id = id };
            self.slots.getPtr(id).?.* = tail;
            return false;
        }
        _ = self.slots.remove(entry.id);
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        self.generation +%= 1;
        return true;
    }
};

fn addTestChunk(queue: *Queue, id: u32) !void {
    var batch: Batch = .{};
    batch.add(id);
    try queue.reserve(std.testing.allocator, batch);
    queue.commit(batch);
}

fn expectQueueSlots(queue: *const Queue) !void {
    try std.testing.expectEqual(queue.count, queue.slots.count());
    for (0..queue.count) |offset| {
        const slot = (queue.head + offset) % capacity;
        try std.testing.expectEqual(slot, queue.slots.get(queue.entries[slot].id).?);
    }
}

test "dirty road chunks rejoin the tail and let quiet chunks finish" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    var batch: Batch = .{};
    batch.add(1);
    batch.add(1);
    batch.add(2);
    batch.add(3);
    try queue.reserve(std.testing.allocator, batch);
    queue.commit(batch);
    queue.observeRevision(10);
    queue.advance();
    try queue.reserve(std.testing.allocator, batch);
    queue.commit(batch);
    try std.testing.expect(!queue.finish());
    try std.testing.expectEqual(@as(usize, 3), queue.count);
    try expectQueueSlots(&queue);
    // More work for the requeued chunk is absorbed by its fresh pending pass.
    try addTestChunk(&queue, 1);
    try std.testing.expect(!queue.entries[queue.slots.get(1).?].dirty_again);
    for ([_]u32{ 2, 3 }) |id| {
        try std.testing.expectEqual(id, queue.peek().?.id);
        try std.testing.expect(queue.finish());
    }
    const repeated = queue.peek().?;
    try std.testing.expectEqual(@as(u32, 1), repeated.id);
    try std.testing.expectEqual(@as(usize, 0), repeated.cursor);
    try std.testing.expectEqual(@as(?u64, null), repeated.observed_revision);
    try std.testing.expect(queue.finish());
    try std.testing.expect(queue.peek() == null);
    try expectQueueSlots(&queue);
}

test "road revision changes request a later pass without restarting the cursor" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    try addTestChunk(&queue, 1);
    queue.observeRevision(10);
    queue.observeRevision(11);
    try std.testing.expect(!queue.peek().?.dirty_again);
    queue.advance();
    queue.observeRevision(11);
    try std.testing.expect(!queue.peek().?.dirty_again);
    queue.observeRevision(12);
    try std.testing.expect(queue.peek().?.dirty_again);
    try std.testing.expectEqual(@as(usize, 1), queue.peek().?.cursor);
    queue.advance();
    queue.observeRevision(13);
    try std.testing.expectEqual(@as(usize, 2), queue.peek().?.cursor);
    try std.testing.expectEqual(@as(?u64, 13), queue.peek().?.observed_revision);
    try std.testing.expect(!queue.finish());
    try std.testing.expect(queue.finish());
}

test "singleton road repasses wrap without allocating or losing coalesced work" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    try addTestChunk(&queue, 7);
    var batch: Batch = .{};
    batch.add(7);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    for (0..capacity + 2) |pass| {
        try queue.reserve(failing.allocator(), batch);
        queue.commit(batch);
        queue.observeRevision(@intCast(pass));
        queue.advance();
        try queue.reserve(failing.allocator(), batch);
        queue.commit(batch);
        try std.testing.expect(!queue.finish());
        try std.testing.expectEqual(@as(usize, 1), queue.count);
        try std.testing.expectEqual(@as(u32, 7), queue.peek().?.id);
        try std.testing.expectEqual(@as(usize, 0), queue.peek().?.cursor);
        try expectQueueSlots(&queue);
    }
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(queue.finish());
    try expectQueueSlots(&queue);
}

test "full road queue rotates dirty passes across wraparound without changing capacity" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    for (0..capacity) |id| try addTestChunk(&queue, @intCast(id));
    var extra: Batch = .{};
    extra.add(@intCast(capacity));
    try std.testing.expectError(error.RoadUpdatesFull, queue.reserve(a, extra));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    for (0..capacity + 2) |pass| {
        const id = queue.peek().?.id;
        try std.testing.expectEqual(@as(u32, @intCast(pass % capacity)), id);
        queue.observeRevision(1);
        queue.advance();
        var existing: Batch = .{};
        existing.add(id);
        try queue.reserve(failing.allocator(), existing);
        queue.commit(existing);
        try std.testing.expect(!queue.finish());
        try std.testing.expectEqual(capacity, queue.count);
    }
    try std.testing.expectEqual(@as(usize, 2), queue.head);
    try expectQueueSlots(&queue);
    try std.testing.expectError(error.RoadUpdatesFull, queue.reserve(a, extra));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    // Reuse a freed slot after wrapping, preserving every other queued ID.
    try std.testing.expect(queue.finish());
    try queue.reserve(a, extra);
    queue.commit(extra);
    try std.testing.expectEqual(capacity, queue.count);
    try std.testing.expect(!queue.slots.contains(2));
    try std.testing.expect(queue.slots.contains(@intCast(capacity)));
    try expectQueueSlots(&queue);
    for (0..capacity) |_| try std.testing.expect(queue.finish());
    try std.testing.expect(queue.peek() == null);
    try expectQueueSlots(&queue);
}

test "road repass revisits metadata swap-removed behind the cursor after quiet work" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    try addTestChunk(&queue, 1);
    try addTestChunk(&queue, 2);
    var roads = [_]u32{ 10, 11, 12 };
    var road_count: usize = roads.len;
    queue.observeRevision(1);
    try std.testing.expectEqual(@as(u32, 10), roads[queue.peek().?.cursor]);
    queue.advance();
    // Removing an earlier metadata record moves an unvisited road behind us.
    roads[0] = roads[road_count - 1];
    road_count -= 1;
    queue.observeRevision(2);
    try std.testing.expectEqual(@as(usize, 1), queue.peek().?.cursor);
    try std.testing.expectEqual(@as(u32, 11), roads[queue.peek().?.cursor]);
    queue.advance();
    try std.testing.expectEqual(road_count, queue.peek().?.cursor);
    try std.testing.expect(!queue.finish());
    try std.testing.expectEqual(@as(u32, 2), queue.peek().?.id);
    try std.testing.expect(queue.finish());
    try std.testing.expectEqual(@as(u32, 1), queue.peek().?.id);
    queue.observeRevision(2);
    try std.testing.expectEqual(@as(u32, 12), roads[queue.peek().?.cursor]);
    for (0..road_count) |_| queue.advance();
    try std.testing.expect(queue.finish());
    try std.testing.expect(queue.peek() == null);
}

test "durable road capture remains immutable across completion and new invalidation" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    try addTestChunk(&queue, 7);
    try addTestChunk(&queue, 2);
    const generation = queue.generation;
    const snapshot = try queue.snapshotKeys(a);
    defer a.free(snapshot);
    try std.testing.expectEqual(@as(u32, 2), snapshot[0].chunk_id);
    try std.testing.expectEqual(@as(u32, 7), snapshot[1].chunk_id);
    queue.advance();
    try addTestChunk(&queue, 7);
    try std.testing.expectEqual(generation, queue.generation);
    try std.testing.expect(!queue.finish());
    try std.testing.expectEqual(generation, queue.generation);
    // Clean completion changes membership. A later invalidation reintroduces
    // the key with another generation, so the older save cannot clear it.
    try std.testing.expect(queue.finish());
    try std.testing.expect(queue.finish());
    try addTestChunk(&queue, 7);
    try std.testing.expect(queue.generation != generation);
    try std.testing.expectEqual(@as(usize, 2), snapshot.len);
    try std.testing.expectEqual(@as(u32, 7), snapshot[1].chunk_id);
    try std.testing.expectEqual(@as(usize, 1), queue.count);
}

test "durable road restore starts fresh passes and preserves capture without world data" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    const keys = [_]deferred_work.Key{
        .{ .kind = .road_shape, .chunk_id = 1 },
        .{ .kind = .road_shape, .chunk_id = 5 },
    };
    try queue.restore(a, &keys);
    try std.testing.expectEqual(@as(u64, 0), queue.generation);
    try expectQueueSlots(&queue);
    try std.testing.expectEqual(@as(usize, 0), queue.peek().?.cursor);
    try std.testing.expect(!queue.peek().?.dirty_again);
    const bytes = try queue.snapshotEncoded(a, .{ 2, 2, 2 }, capacity);
    defer a.free(bytes);
    const decoded = try deferred_work.decode(a, bytes, .{ 2, 2, 2 }, capacity);
    defer a.free(decoded);
    try std.testing.expectEqualSlices(deferred_work.Key, &keys, decoded);
    try std.testing.expectError(error.RoadUpdatesNotEmpty, queue.restore(a, &keys));
}

test "failed durable road captures and restores leave queue membership and progress intact" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    try addTestChunk(&queue, 3);
    queue.observeRevision(10);
    queue.advance();
    const generation = queue.generation;
    // Both allocation boundaries of the convenience capture leave live work.
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, queue.snapshotEncoded(failing.allocator(), .{ 2, 2, 2 }, capacity));
        try std.testing.expectEqual(generation, queue.generation);
        try std.testing.expectEqual(@as(usize, 1), queue.count);
        try std.testing.expectEqual(@as(usize, 1), queue.peek().?.cursor);
    }
    var restored: Queue = .{};
    defer restored.deinit(a);
    const keys = [_]deferred_work.Key{.{ .kind = .road_shape, .chunk_id = 3 }};
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, restored.restore(failing.allocator(), &keys));
    try std.testing.expectEqual(@as(usize, 0), restored.count);
    try std.testing.expectEqual(@as(usize, 0), restored.slots.count());
    try std.testing.expectEqual(@as(u64, 0), restored.generation);
    const duplicate = [_]deferred_work.Key{ keys[0], keys[0] };
    try std.testing.expectError(error.InvalidDeferredWork, restored.restore(a, &duplicate));
    try std.testing.expectEqual(@as(usize, 0), restored.count);
}

test "durable road admission honors custom limits before mutation and coalesces existing work" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    var batch: Batch = .{};
    batch.add(1);
    batch.add(2);
    try queue.reserveWithLimit(a, batch, 2);
    queue.commit(batch);
    queue.advance();
    const generation = queue.generation;
    var extra: Batch = .{};
    extra.add(1);
    extra.add(3);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.RoadUpdatesFull, queue.reserveWithLimit(failing.allocator(), extra, 2));
    try std.testing.expectEqual(@as(usize, 2), queue.count);
    try std.testing.expectEqual(generation, queue.generation);
    try std.testing.expectEqual(@as(usize, 1), queue.peek().?.cursor);
    try std.testing.expect(!queue.peek().?.dirty_again);
    var repeated: Batch = .{};
    repeated.add(1);
    try queue.reserveWithLimit(failing.allocator(), repeated, 2);
    queue.commit(repeated);
    try std.testing.expect(queue.peek().?.dirty_again);
    try std.testing.expectEqual(generation, queue.generation);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try expectQueueSlots(&queue);
    var empty: Queue = .{};
    defer empty.deinit(a);
    try std.testing.expectError(error.RoadUpdatesFull, empty.reserveWithLimit(a, repeated, 0));
    try std.testing.expectEqual(@as(usize, 0), empty.count);
    try std.testing.expectEqual(@as(usize, 0), empty.slots.count());
}

test "same-revision reload restarts a queued pass without changing identity or fairness" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    try addTestChunk(&queue, 1);
    try addTestChunk(&queue, 2);
    queue.observeRevision(10);
    queue.advance();
    try addTestChunk(&queue, 1);
    try std.testing.expect(queue.peek().?.dirty_again);
    const generation = queue.generation;
    queue.restartAfterLoad(1);
    try std.testing.expectEqual(@as(u32, 1), queue.peek().?.id);
    try std.testing.expectEqual(@as(usize, 0), queue.peek().?.cursor);
    try std.testing.expect(!queue.peek().?.dirty_again);
    try std.testing.expectEqual(@as(?u64, null), queue.peek().?.observed_revision);
    queue.restartAfterLoad(99);
    try std.testing.expectEqual(generation, queue.generation);
    try std.testing.expectEqual(@as(usize, 2), queue.count);
    try expectQueueSlots(&queue);
    try std.testing.expect(queue.finish());
    try std.testing.expectEqual(@as(u32, 2), queue.peek().?.id);
}
