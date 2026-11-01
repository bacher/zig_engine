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

    /// Return true when a queue slot becomes free. An edit after earlier seeds
    /// were processed requests one more coalesced pass instead of losing work.
    pub fn finish(self: *Queue) bool {
        const entry = self.peek().?;
        if (entry.dirty_again) {
            entry.cursor = 0;
            entry.dirty_again = false;
            entry.observed_revision = null;
            return false;
        }
        _ = self.slots.remove(entry.id);
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        return true;
    }
};

test "road work coalesces chunks and retains a second pass after interleaved fills" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    var batch: Batch = .{};
    batch.add(1);
    batch.add(1);
    batch.add(2);
    try queue.reserve(std.testing.allocator, batch);
    queue.commit(batch);
    try std.testing.expectEqual(@as(usize, 2), queue.count);
    queue.advance();
    try queue.reserve(std.testing.allocator, batch);
    queue.commit(batch);
    try std.testing.expect(!queue.finish());
    try std.testing.expectEqual(@as(usize, 0), queue.peek().?.cursor);
    try std.testing.expect(queue.finish());
    try std.testing.expectEqual(@as(u32, 2), queue.peek().?.id);
}

test "full road queue rejects new chunks before fill and still accepts coalesced dirty work" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    for (0..capacity) |id| {
        var batch: Batch = .{};
        batch.add(@intCast(id));
        try queue.reserve(std.testing.allocator, batch);
        queue.commit(batch);
    }
    var extra: Batch = .{};
    extra.add(@intCast(capacity));
    try std.testing.expectError(error.RoadUpdatesFull, queue.reserve(std.testing.allocator, extra));
    try std.testing.expectEqual(capacity, queue.count);
    var existing: Batch = .{};
    existing.add(0);
    try queue.reserve(std.testing.allocator, existing);
    queue.commit(existing);
    try std.testing.expect(queue.finish());
    try queue.reserve(std.testing.allocator, extra);
    queue.commit(extra);
    try std.testing.expectEqual(capacity, queue.count);
}
