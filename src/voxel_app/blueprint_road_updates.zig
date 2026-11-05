//! Coalesced road work caused by real blueprint fulfillment. Queue publication
//! is separate from planning and structural validation, keeping fills constant work.
const std = @import("std");
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

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    /// No semantic queue change on failure. Call before the fill mutates terrain.
    pub fn reserve(self: *Queue, allocator: std.mem.Allocator, batch: Batch) !void {
        var additional: usize = 0;
        for (batch.ids[0..batch.count]) |id| if (!self.slots.contains(id)) {
            additional += 1;
        };
        if (additional > capacity - self.count) return error.RoadUpdatesFull;
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
        }
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
