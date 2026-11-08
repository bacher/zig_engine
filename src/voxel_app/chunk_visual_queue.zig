//! Deferred presentation work only. The caller keeps authoritative world changes
//! immediate and rebuilds all visuals for a chunk together when taking its item.
//! Admit only loaded chunks and remove them on eviction or representation changes:
//! then live queue memory is bounded by loaded chunks, with no canceled backlog.
const std = @import("std");

pub const Item = struct {
    id: u32,
    /// The caller rechecks this identity before reading the chunk or publishing.
    subscription: ?u64,
    marked_frame: u64,
};

pub const Stats = struct {
    marks: u64 = 0,
    enqueued: u64 = 0,
    coalesced: u64 = 0,
    subscription_replacements: u64 = 0,
    canceled: u64 = 0,
    taken: u64 = 0,
    /// Nonempty head inspections, including waits for the coalescing interval.
    /// Empty frames inspect no queued work at all.
    head_checks: u64 = 0,
    peak_pending: usize = 0,
};

/// A FIFO with one live entry per chunk. Links use chunk IDs, so dense hash-map
/// removal cannot invalidate them. There are no canceled entries to scan later.
/// mark/remove/take have expected O(1) cost; none scans the pending population.
/// Calls are confined to the client thread, with monotonically increasing frames.
pub const Queue = struct {
    const Node = struct { item: Item, previous: ?u32 = null, next: ?u32 = null };

    entries: std.AutoArrayHashMapUnmanaged(u32, Node) = .empty,
    head: ?u32 = null,
    tail: ?u32 = null,
    min_age_frames: u64 = 2,
    stats: Stats = .{},

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = .{ .min_age_frames = self.min_age_frames };
    }

    pub fn count(self: *const Queue) usize {
        return self.entries.count();
    }

    /// Retained allocation follows peak simultaneous pending work, never the
    /// number of different chunks visited during a streaming session.
    pub fn capacity(self: *const Queue) usize {
        return self.entries.capacity();
    }

    pub fn contains(self: *const Queue, id: u32) bool {
        return self.entries.contains(id);
    }

    /// Repeated changes keep the first mark's age and FIFO position. Work always
    /// reads the latest chunk state when taken, rather than storing snapshots.
    /// A new subscription is a new lifetime and rejoins the tail with a fresh age.
    /// Allocation failure leaves queue membership and existing work unchanged.
    pub fn mark(self: *Queue, allocator: std.mem.Allocator, id: u32, subscription: ?u64, frame: u64) !void {
        if (self.entries.getPtr(id)) |node| {
            self.stats.marks +%= 1;
            if (node.item.subscription == subscription) {
                self.stats.coalesced +%= 1;
                return;
            }
            self.unlink(node.*);
            node.* = .{ .item = .{ .id = id, .subscription = subscription, .marked_frame = frame } };
            self.append(id, node);
            self.stats.subscription_replacements +%= 1;
            return;
        }

        const entry = try self.entries.getOrPut(allocator, id);
        std.debug.assert(!entry.found_existing);
        entry.value_ptr.* = .{ .item = .{ .id = id, .subscription = subscription, .marked_frame = frame } };
        self.append(id, entry.value_ptr);
        self.stats.marks +%= 1;
        self.stats.enqueued +%= 1;
        self.stats.peak_pending = @max(self.stats.peak_pending, self.count());
    }

    pub fn cancel(self: *Queue, id: u32) bool {
        const node = self.entries.get(id) orelse return false;
        self.unlink(node);
        const removed = self.entries.swapRemove(id);
        std.debug.assert(removed);
        self.stats.canceled +%= 1;
        return true;
    }

    pub fn remove(self: *Queue, id: u32) bool {
        return self.cancel(id);
    }

    pub fn clearRetainingCapacity(self: *Queue) void {
        self.stats.canceled +%= self.count();
        self.entries.clearRetainingCapacity();
        self.head = null;
        self.tail = null;
    }

    /// A young head means all later work is young too. Marks never postpone an
    /// existing subscription, so continuously changing chunks still converge.
    /// The caller must validate subscription/liveness before using the result.
    pub fn take(self: *Queue, frame: u64) ?Item {
        const id = self.head orelse return null;
        self.stats.head_checks +%= 1;
        const node = self.entries.get(id).?;
        if (frame -| node.item.marked_frame < self.min_age_frames) return null;
        self.unlink(node);
        const removed = self.entries.swapRemove(id);
        std.debug.assert(removed);
        self.stats.taken +%= 1;
        return node.item;
    }

    fn append(self: *Queue, id: u32, node: *Node) void {
        node.previous = self.tail;
        node.next = null;
        if (self.tail) |previous| {
            self.entries.getPtr(previous).?.next = id;
        } else {
            self.head = id;
        }
        self.tail = id;
    }

    fn unlink(self: *Queue, node: Node) void {
        if (node.previous) |previous| {
            self.entries.getPtr(previous).?.next = node.next;
        } else {
            self.head = node.next;
        }
        if (node.next) |next| {
            self.entries.getPtr(next).?.previous = node.previous;
        } else {
            self.tail = node.previous;
        }
    }
};

/// Limits whole coherent chunk builds. Time is supplied by the caller so the
/// policy is deterministic in CPU tests and does not require a clock per mark.
/// One build is allowed to make progress even when its cost exceeds the soft
/// time budget; the caller checks elapsed time between builds, never mid-chunk.
pub const FrameBudget = struct {
    max_items: u32 = 4,
    max_elapsed_ns: u64 = 2_000_000,
    completed: u32 = 0,

    pub fn canStart(self: *const FrameBudget, elapsed_ns: u64) bool {
        return self.completed < self.max_items and
            (self.completed == 0 or elapsed_ns < self.max_elapsed_ns);
    }

    pub fn record(self: *FrameBudget) void {
        self.completed +|= 1;
    }
};

fn expectOrder(queue: *const Queue, expected: []const u32) !void {
    try std.testing.expectEqual(expected.len, queue.count());
    var id = queue.head;
    var previous: ?u32 = null;
    for (expected) |wanted| {
        try std.testing.expectEqual(@as(?u32, wanted), id);
        const node = queue.entries.get(wanted).?;
        try std.testing.expectEqual(previous, node.previous);
        previous = wanted;
        id = node.next;
    }
    try std.testing.expectEqual(@as(?u32, null), id);
    try std.testing.expectEqual(previous, queue.tail);
}

test "marks coalesce across frames without resetting age or FIFO position" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    try queue.mark(std.testing.allocator, 1, 10, 4);
    try queue.mark(std.testing.allocator, 2, 20, 4);
    try queue.mark(std.testing.allocator, 1, 10, 5);
    try std.testing.expect(queue.take(5) == null);
    try queue.mark(std.testing.allocator, 1, 10, 6);
    try expectOrder(&queue, &.{ 1, 2 });
    const item = queue.take(6).?;
    try std.testing.expectEqual(@as(u32, 1), item.id);
    try std.testing.expectEqual(@as(u64, 4), item.marked_frame);
    try std.testing.expectEqual(@as(?u64, 10), item.subscription);
    try std.testing.expectEqual(@as(u32, 2), queue.take(6).?.id);
    try std.testing.expect(queue.take(6) == null);
    try std.testing.expectEqual(@as(u64, 4), queue.stats.marks);
    try std.testing.expectEqual(@as(u64, 2), queue.stats.enqueued);
    try std.testing.expectEqual(@as(u64, 2), queue.stats.coalesced);
    try std.testing.expectEqual(@as(u64, 2), queue.stats.taken);
    try std.testing.expectEqual(@as(usize, 2), queue.stats.peak_pending);
}

test "hot chunks rejoin the tail after service and quiet chunks cannot starve" {
    var queue: Queue = .{ .min_age_frames = 0 };
    defer queue.deinit(std.testing.allocator);
    for ([_]u32{ 1, 2, 3 }) |id| try queue.mark(std.testing.allocator, id, 1, 0);
    for (0..3) |frame| {
        // Every frame changes all chunks, including one already rebuilt.
        for ([_]u32{ 1, 2, 3 }) |id| try queue.mark(std.testing.allocator, id, 1, frame);
        var budget: FrameBudget = .{ .max_items = 1 };
        var taken: u32 = 0;
        while (budget.canStart(0)) {
            const item = queue.take(frame) orelse break;
            try std.testing.expectEqual(@as(u32, @intCast(frame + 1)), item.id);
            budget.record();
            taken += 1;
        }
        try std.testing.expectEqual(@as(u32, 1), taken);
    }
    try expectOrder(&queue, &.{ 1, 2 });
}

test "cancel unlinks head middle tail and sole entries immediately" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    for ([_]u32{ 1, 2, 3, 4, 5 }) |id| try queue.mark(std.testing.allocator, id, null, 0);
    try std.testing.expect(queue.cancel(3));
    try expectOrder(&queue, &.{ 1, 2, 4, 5 });
    try std.testing.expect(queue.remove(1));
    try expectOrder(&queue, &.{ 2, 4, 5 });
    try std.testing.expect(queue.cancel(5));
    try expectOrder(&queue, &.{ 2, 4 });
    try std.testing.expect(queue.cancel(2));
    try std.testing.expect(queue.cancel(4));
    try expectOrder(&queue, &.{});
    try std.testing.expect(!queue.remove(4));
    try std.testing.expectEqual(@as(u64, 5), queue.stats.canceled);
}

test "reload replaces stale identity and gets a fresh coalescing interval" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    try queue.mark(std.testing.allocator, 1, 10, 0);
    try queue.mark(std.testing.allocator, 2, 20, 0);
    try queue.mark(std.testing.allocator, 1, 11, 1);
    try expectOrder(&queue, &.{ 2, 1 });
    try std.testing.expectEqual(@as(u32, 2), queue.take(2).?.id);
    try std.testing.expect(queue.take(2) == null);
    const item = queue.take(3).?;
    try std.testing.expectEqual(@as(?u64, 11), item.subscription);
    try std.testing.expectEqual(@as(u64, 1), item.marked_frame);
    try std.testing.expectEqual(@as(u64, 1), queue.stats.subscription_replacements);
    // An explicit unload also removes the old age and identity completely.
    try queue.mark(std.testing.allocator, 1, 11, 4);
    try std.testing.expect(queue.cancel(1));
    try queue.mark(std.testing.allocator, 1, 12, 5);
    try std.testing.expect(queue.take(6) == null);
    try std.testing.expectEqual(@as(?u64, 12), queue.take(7).?.subscription);
}

test "streaming cancellations do not retain canceled entries or grow storage" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    for (0..64) |id| try queue.mark(std.testing.allocator, @intCast(id), 1, 0);
    const capacity = queue.capacity();
    queue.clearRetainingCapacity();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for (100..10100) |id| {
        try queue.mark(failing.allocator(), @intCast(id), 1, 0);
        try std.testing.expectEqual(@as(usize, 1), queue.count());
        try std.testing.expect(queue.cancel(@intCast(id)));
    }
    try std.testing.expectEqual(capacity, queue.capacity());
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try expectOrder(&queue, &.{});
}

test "coalescing and replacing existing subscriptions do not allocate" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    try queue.mark(std.testing.allocator, 1, 1, 0);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try queue.mark(failing.allocator(), 1, 1, 1);
    try queue.mark(failing.allocator(), 1, 2, 2);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try expectOrder(&queue, &.{1});
    try std.testing.expectEqual(@as(?u64, 2), queue.take(4).?.subscription);
}

test "failed new admission leaves existing work and FIFO links intact" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);
    try queue.mark(std.testing.allocator, 1, 1, 0);
    const capacity = queue.capacity();
    for (2..capacity + 1) |id| try queue.mark(std.testing.allocator, @intCast(id), 1, 0);
    const previous_count = queue.count();
    const previous_marks = queue.stats.marks;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, queue.mark(failing.allocator(), @intCast(capacity + 1), 1, 1));
    try std.testing.expectEqual(previous_count, queue.count());
    try std.testing.expectEqual(previous_marks, queue.stats.marks);
    for (1..capacity + 1) |id| try std.testing.expectEqual(@as(u32, @intCast(id)), queue.take(2).?.id);
    try expectOrder(&queue, &.{});
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var queue: Queue = .{};
    defer queue.deinit(allocator);
    for (0..65) |id| try queue.mark(allocator, @intCast(id), 1, 0);
    try queue.mark(allocator, 1, 1, 1);
    try queue.mark(allocator, 2, 2, 1);
    try std.testing.expect(queue.cancel(0));
    var taken: usize = 0;
    while (queue.take(3)) |_| taken += 1;
    try std.testing.expectEqual(@as(usize, 64), taken);
    try expectOrder(&queue, &.{});
}

test "every admission allocation failure releases queue storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

test "frame budget bounds count and time while allowing one whole chunk overshoot" {
    var count_limited: FrameBudget = .{ .max_items = 2 };
    try std.testing.expect(count_limited.canStart(0));
    count_limited.record();
    try std.testing.expect(count_limited.canStart(0));
    count_limited.record();
    try std.testing.expect(!count_limited.canStart(0));
    var timed: FrameBudget = .{};
    try std.testing.expect(timed.canStart(timed.max_elapsed_ns + 1));
    timed.record();
    try std.testing.expect(timed.canStart(timed.max_elapsed_ns - 1));
    try std.testing.expect(!timed.canStart(timed.max_elapsed_ns));
    var disabled: FrameBudget = .{ .max_items = 0 };
    try std.testing.expect(!disabled.canStart(0));
    var one_only: FrameBudget = .{ .max_elapsed_ns = 0 };
    try std.testing.expect(one_only.canStart(0));
    one_only.record();
    try std.testing.expect(!one_only.canStart(0));
}

test {
    _ = @import("chunk_visual_queue_benchmark.zig");
}
