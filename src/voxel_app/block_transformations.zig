//! Sparse, deadline-ordered time events, owned by chunk metadata rather than block cells.
const std = @import("std");

pub const Tick = u64;
pub const ticks_per_second: Tick = 60;
pub const transformation_delay: Tick = 30 * 60 * ticks_per_second;
pub const BlockIndex = u15;
pub const Kind = enum(u8) {
    compact_dirt = 0,
    grow_grass = 1,
    pub fn isLazy(self: Kind) bool {
        return switch (self) {
            .compact_dirt, .grow_grass => true,
        };
    }
};
pub const Event = struct { block: BlockIndex, kind: Kind, due_tick: Tick };

pub fn index(local: [3]u5) BlockIndex {
    return @as(BlockIndex, local[2]) * 1024 + @as(BlockIndex, local[1]) * 32 + local[0];
}

pub fn coordinates(block: BlockIndex) [3]u5 {
    return .{ @truncate(block), @truncate(block >> 5), @truncate(block >> 10) };
}

pub const Queue = struct {
    events: std.ArrayList(Event) = .empty,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
    }

    pub fn tryClone(self: Queue, allocator: std.mem.Allocator) !Queue {
        return .{ .events = try self.events.clone(allocator) };
    }

    pub fn clone(self: Queue, allocator: std.mem.Allocator) Queue {
        return self.tryClone(allocator) catch @panic("OOM");
    }

    pub fn reserve(self: *Queue, allocator: std.mem.Allocator, additional: usize) !void {
        try self.events.ensureUnusedCapacity(allocator, additional);
    }

    pub fn cancel(self: *Queue, block: BlockIndex) void {
        for (self.events.items, 0..) |event, i| {
            if (event.block == block) {
                _ = self.events.orderedRemove(i);
                return;
            }
        }
    }

    /// A cell has at most one pending transformation. Replacing its event also resets its timer.
    pub fn schedule(self: *Queue, allocator: std.mem.Allocator, event: Event) void {
        self.trySchedule(allocator, event) catch @panic("OOM");
    }

    /// Reserve before canceling an old event, so failure leaves it intact.
    pub fn trySchedule(self: *Queue, allocator: std.mem.Allocator, event: Event) !void {
        const exists = for (self.events.items) |old| {
            if (old.block == event.block) break true;
        } else false;
        if (!exists) try self.reserve(allocator, 1);
        self.scheduleAssumeCapacity(event);
    }

    pub fn scheduleAssumeCapacity(self: *Queue, event: Event) void {
        self.cancel(event.block);
        var first: usize = 0;
        var end = self.events.items.len;
        while (first < end) {
            const middle = first + (end - first) / 2;
            const existing = self.events.items[middle];
            if (existing.due_tick < event.due_tick or (existing.due_tick == event.due_tick and existing.block < event.block)) {
                first = middle + 1;
            } else end = middle;
        }
        self.events.insertAssumeCapacity(first, event);
    }

    /// Most calls inspect only the first deadline. Due events are removed as one prefix,
    /// avoiding a full block scan or repeated shifts when a whole surface grows grass.
    pub fn takeDue(self: *Queue, allocator: std.mem.Allocator, tick: Tick) []Event {
        return self.tryTakeDue(allocator, tick) catch @panic("OOM");
    }

    pub fn tryTakeDue(self: *Queue, allocator: std.mem.Allocator, tick: Tick) ![]Event {
        var count: usize = 0;
        while (count < self.events.items.len and self.events.items[count].due_tick <= tick) : (count += 1) {}
        if (count == 0) return &.{};
        const due = try allocator.dupe(Event, self.events.items[0..count]);
        const remaining = self.events.items.len - count;
        std.mem.copyForwards(Event, self.events.items[0..remaining], self.events.items[count..]);
        self.events.items.len = remaining;
        return due;
    }
};

test "deadlines remain ordered and replacement cancels an earlier incarnation" {
    const allocator = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(allocator);
    queue.schedule(allocator, .{ .block = 2, .kind = .grow_grass, .due_tick = 20 });
    queue.schedule(allocator, .{ .block = 1, .kind = .compact_dirt, .due_tick = 10 });
    queue.schedule(allocator, .{ .block = 2, .kind = .compact_dirt, .due_tick = 30 });
    const early = queue.takeDue(allocator, 9);
    defer allocator.free(early);
    try std.testing.expectEqual(0, early.len);
    const first = queue.takeDue(allocator, 10);
    defer allocator.free(first);
    try std.testing.expectEqual(1, first.len);
    try std.testing.expectEqual(1, first[0].block);
    const second = queue.takeDue(allocator, 30);
    defer allocator.free(second);
    try std.testing.expectEqual(1, second.len);
    try std.testing.expectEqual(Kind.compact_dirt, second[0].kind);
}

test "chunk-local indices cover all 32768 cells without aliasing" {
    for (0..32768) |value| {
        const block: BlockIndex = @intCast(value);
        try std.testing.expectEqual(block, index(coordinates(block)));
    }
}

fn exerciseFallibleQueue(a: std.mem.Allocator) !void {
    var source: Queue = .{};
    defer source.deinit(a);
    try source.trySchedule(a, .{ .block = 1, .kind = .compact_dirt, .due_tick = 10 });
    try source.trySchedule(a, .{ .block = 1, .kind = .grow_grass, .due_tick = 20 });
    var copy = try source.tryClone(a);
    defer copy.deinit(a);
    const due = try copy.tryTakeDue(a, 20);
    defer a.free(due);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(@as(usize, 1), source.events.items.len);
}
test "fallible queue cloning rescheduling and extraction release every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFallibleQueue, .{});
}
test "failed event insertion preserves existing deadlines" {
    var source: Queue = .{};
    defer source.deinit(std.testing.allocator);
    try source.trySchedule(std.testing.allocator, .{ .block = 1, .kind = .compact_dirt, .due_tick = 10 });
    // Fill the allocated capacity before attempting insertion through a failing allocator.
    while (source.events.items.len < source.events.capacity) source.scheduleAssumeCapacity(.{ .block = @intCast(source.events.items.len + 1), .kind = .grow_grass, .due_tick = 20 });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const before = source.events.items.len;
    try std.testing.expectError(error.OutOfMemory, source.trySchedule(failing.allocator(), .{ .block = 32767, .kind = .grow_grass, .due_tick = 30 }));
    try std.testing.expectEqual(before, source.events.items.len);
    try std.testing.expectEqual(@as(Tick, 10), source.events.items[0].due_tick);
    // Replacement reuses its canceled slot, even when allocations are unavailable.
    try source.trySchedule(failing.allocator(), .{ .block = 1, .kind = .grow_grass, .due_tick = 40 });
    try std.testing.expectEqual(before, source.events.items.len);
}
