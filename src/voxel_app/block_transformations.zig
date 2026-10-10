//! Sparse, deadline-ordered time events, owned by chunk metadata rather than block cells.
const std = @import("std");

pub const Tick = u64;
pub const ticks_per_second: Tick = 60;
pub const transformation_delay: Tick = 30 * 60 * ticks_per_second;
pub const BlockIndex = u15;
pub const Kind = enum { compact_dirt, grow_grass };
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

    pub fn clone(self: Queue, allocator: std.mem.Allocator) Queue {
        var copy: Queue = .{};
        copy.events.appendSlice(allocator, self.events.items) catch @panic("OOM");
        return copy;
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
        self.events.insert(allocator, first, event) catch @panic("OOM");
    }

    /// Most calls inspect only the first deadline. Due events are removed as one prefix,
    /// avoiding a full block scan or repeated shifts when a whole surface grows grass.
    pub fn takeDue(self: *Queue, allocator: std.mem.Allocator, tick: Tick) []Event {
        var count: usize = 0;
        while (count < self.events.items.len and self.events.items[count].due_tick <= tick) : (count += 1) {}
        if (count == 0) return &.{};
        const due = allocator.dupe(Event, self.events.items[0..count]) catch @panic("OOM");
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
