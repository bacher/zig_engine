//! Chunk-local finite timer transitions. Preparation owns detached state; publication
//! and revision assignment belong to the authoritative service after capture gating.
const std = @import("std");
const world = @import("world.zig");
const timers = @import("block_transformations.zig");
const BlockType = @import("engine").voxel_chunk.BlockType;
pub const Change = struct { cell: timers.BlockIndex, material: BlockType };
pub const Plan = struct {
    timed: timers.Queue,
    changes: std.ArrayList(Change) = .empty,
    material_changed: bool = false,
    metadata_changed: bool = false,
    consumed: usize = 0,
    pub fn deinit(self: *Plan, a: std.mem.Allocator) void {
        self.timed.deinit(a);
        self.changes.deinit(a);
        self.* = undefined;
    }
    /// Caller has gated the exact source incarnation and reserved publication
    /// bookkeeping. Changes preserve occupancy, custom records and construction.
    pub fn applyPrepared(self: *Plan, chunk: *world.WorldChunk) void {
        for (self.changes.items) |change| chunk.changeType(timers.coordinates(change.cell), change.material);
        std.mem.swap(timers.Queue, &chunk.metadata.timed, &self.timed);
    }
};
pub const Prepared = Plan;
fn less(_: void, a: timers.Event, b: timers.Event) bool {
    return a.due_tick < b.due_tick or (a.due_tick == b.due_tick and a.block < b.block);
}
fn siftDown(items: []timers.Event) void {
    var i: usize = 0;
    while (true) {
        const left = i * 2 + 1;
        if (left >= items.len) return;
        var child = left;
        if (left + 1 < items.len and less({}, items[left + 1], items[left])) child += 1;
        if (!less({}, items[child], items[i])) return;
        std.mem.swap(timers.Event, &items[i], &items[child]);
        i = child;
    }
}
fn push(list: *std.ArrayList(timers.Event), event: timers.Event) void {
    list.appendAssumeCapacity(event);
    var i = list.items.len - 1;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (!less({}, list.items[i], list.items[parent])) break;
        std.mem.swap(timers.Event, &list.items[i], &list.items[parent]);
        i = parent;
    }
}
/// O(N log N), at most two transitions per initial event. All allocations finish
/// before the first transition; failure leaves source blocks and timers untouched.
pub fn prepare(a: std.mem.Allocator, source: *const world.WorldChunk, cutoff: timers.Tick) !Plan {
    var result: Plan = .{ .timed = try source.metadata.timed.tryClone(a) };
    errdefer result.deinit(a);
    try result.changes.ensureTotalCapacity(a, source.metadata.timed.events.items.len);
    var changed = std.StaticBitSet(32768).initEmpty();
    var positions: [32768]u16 = undefined;
    const queue = &result.timed.events;
    std.mem.sort(timers.Event, queue.items, {}, less);
    while (queue.items.len > 0 and queue.items[0].due_tick <= cutoff) {
        const event = queue.items[0];
        queue.items[0] = queue.items[queue.items.len - 1];
        queue.items.len -= 1;
        siftDown(queue.items);
        result.metadata_changed = true;
        result.consumed += 1;
        const local = timers.coordinates(event.block);
        const material = if (changed.isSet(event.block)) result.changes.items[positions[event.block]].material else source.content.getBlock(local);
        switch (event.kind) {
            .compact_dirt => {
                if (material != .dirt) continue;
                recordChange(&result, &changed, &positions, event.block, .packed_dirt);
                result.material_changed = true;
                // The removed event supplies capacity for its sole finite successor.
                push(queue, .{ .block = event.block, .kind = .grow_grass, .due_tick = event.due_tick +| timers.transformation_delay });
            },
            .grow_grass => {
                if (material != .packed_dirt) continue;
                recordChange(&result, &changed, &positions, event.block, .grass);
                result.material_changed = true;
            },
        }
    }
    std.mem.sort(timers.Event, queue.items, {}, less);
    return result;
}
fn recordChange(plan: *Plan, changed: *std.StaticBitSet(32768), positions: *[32768]u16, cell: timers.BlockIndex, material: BlockType) void {
    if (changed.isSet(cell)) {
        plan.changes.items[positions[cell]].material = material;
        return;
    }
    positions[cell] = @intCast(plan.changes.items.len);
    changed.set(cell);
    plan.changes.appendAssumeCapacity(.{ .cell = cell, .material = material });
}
fn fixture(a: std.mem.Allocator) !world.WorldChunk {
    var chunk = world.WorldChunk.initEmpty();
    errdefer chunk.deinit(a);
    _ = try chunk.tryApply(a, .{ 1, 1, 1 }, .{ .put = .dirt });
    try chunk.metadata.timed.trySchedule(a, .{ .block = timers.index(.{ 1, 1, 1 }), .kind = .compact_dirt, .due_tick = 10 });
    return chunk;
}
test "fixed cutoff finite chain is idempotent and incremental equivalent" {
    const a = std.testing.allocator;
    var source = try fixture(a);
    defer source.deinit(a);
    var first = try prepare(a, &source, 10);
    defer first.deinit(a);
    try std.testing.expectEqual(BlockType.packed_dirt, first.changes.items[0].material);
    try std.testing.expectEqual(@as(u64, 10 + timers.transformation_delay), first.timed.events.items[0].due_tick);
    var intermediate = try source.tryClone(a);
    defer intermediate.deinit(a);
    first.applyPrepared(&intermediate);
    var repeated = try prepare(a, &intermediate, 10);
    defer repeated.deinit(a);
    try std.testing.expect(!repeated.metadata_changed);
    var incremental = try prepare(a, &intermediate, 10 + timers.transformation_delay);
    defer incremental.deinit(a);
    var direct = try prepare(a, &source, 10 + timers.transformation_delay);
    defer direct.deinit(a);
    try std.testing.expectEqual(direct.changes.items[0].material, incremental.changes.items[0].material);
    try std.testing.expectEqual(@as(usize, 2), direct.consumed);
    try std.testing.expectEqual(@as(usize, 0), direct.timed.events.items.len);
    try std.testing.expectEqual(BlockType.dirt, source.content.getBlock(.{ 1, 1, 1 }));
}
test "intervening edits win and invalid events are persistent metadata-only consumption" {
    const a = std.testing.allocator;
    var source = try fixture(a);
    defer source.deinit(a);
    source.changeType(.{ 1, 1, 1 }, .stone);
    var result = try prepare(a, &source, std.math.maxInt(u64));
    defer result.deinit(a);
    try std.testing.expect(result.metadata_changed);
    try std.testing.expect(!result.material_changed);
    try std.testing.expectEqual(@as(usize, 0), result.changes.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.timed.events.items.len);
    try std.testing.expectEqual(@as(usize, 1), source.metadata.timed.events.items.len);
}
fn allocationScenario(a: std.mem.Allocator) !void {
    var source = try fixture(a);
    defer source.deinit(a);
    var result = try prepare(a, &source, std.math.maxInt(u64));
    defer result.deinit(a);
    result.applyPrepared(&source);
}
test "timer preparation releases all allocations and never partially edits source" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "deadline saturation stays finite and future events keep stable deadline-cell order" {
    const a = std.testing.allocator;
    var source = try fixture(a);
    defer source.deinit(a);
    source.metadata.timed.events.items[0].due_tick = std.math.maxInt(u64) - 1;
    var before = try prepare(a, &source, std.math.maxInt(u64) - 2);
    defer before.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), before.consumed);
    var result = try prepare(a, &source, std.math.maxInt(u64));
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), result.consumed);
    try std.testing.expectEqual(BlockType.grass, result.changes.items[0].material);
    try std.testing.expectEqual(@as(usize, 0), result.timed.events.items.len);
    try source.metadata.timed.trySchedule(a, .{ .block = 4, .kind = .grow_grass, .due_tick = 100 });
    try source.metadata.timed.trySchedule(a, .{ .block = 3, .kind = .grow_grass, .due_tick = 100 });
    var future = try prepare(a, &source, 0);
    defer future.deinit(a);
    try std.testing.expectEqual(@as(timers.BlockIndex, 3), future.timed.events.items[0].block);
    try std.testing.expectEqual(@as(timers.BlockIndex, 4), future.timed.events.items[1].block);
}
