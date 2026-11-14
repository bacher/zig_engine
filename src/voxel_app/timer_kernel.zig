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
/// All allocations finish before the first transition; failure leaves source
/// blocks and timers untouched. Every soil deadline has one terminal outcome.
pub fn prepare(a: std.mem.Allocator, source: *const world.WorldChunk, cutoff: timers.Tick) !Plan {
    return prepareWithExposure(a, source, cutoff, null);
}

pub const Exposure = struct {
    context: *anyopaque,
    /// Reads composed physical cover. Unknown dependencies preserve the deadline.
    exposed: *const fn (*anyopaque, [3]u5) ?bool,
    /// Suppresses growth for active site targets, including transferred portions,
    /// and for terrain covered by pending targets, without physical reads.
    grass_allowed: ?*const fn (*anyopaque, [3]u5) bool = null,
};

pub fn prepareWithExposure(a: std.mem.Allocator, source: *const world.WorldChunk, cutoff: timers.Tick, exposure: ?Exposure) !Plan {
    var result: Plan = .{ .timed = try source.metadata.timed.tryClone(a) };
    errdefer result.deinit(a);
    try result.changes.ensureTotalCapacity(a, source.metadata.timed.events.items.len);
    const events = &result.timed.events;
    var retained: usize = 0;
    var cursor: usize = 0;
    while (cursor < events.items.len and events.items[cursor].due_tick <= cutoff) : (cursor += 1) {
        const event = events.items[cursor];
        if (event.kind == .initialize_grass) {
            events.items[retained] = event;
            retained += 1;
            continue;
        }
        const local = timers.coordinates(event.block);
        result.consumed += 1;
        if (source.content.getBlock(local) != .dirt) continue;
        if (exposure) |check| {
            if (check.grass_allowed) |allowed| if (!allowed(check.context, local)) continue;
            const exposed = check.exposed(check.context, local) orelse {
                events.items[retained] = event;
                retained += 1;
                result.consumed -= 1;
                continue;
            };
            if (!exposed) continue;
        }
        result.changes.appendAssumeCapacity(.{ .cell = event.block, .material = .grass });
    }
    const remaining = events.items.len - cursor;
    std.mem.copyForwards(timers.Event, events.items[retained .. retained + remaining], events.items[cursor..]);
    events.items.len = retained + remaining;
    result.material_changed = result.changes.items.len != 0;
    result.metadata_changed = result.consumed != 0;
    return result;
}
fn fixture(a: std.mem.Allocator) !world.WorldChunk {
    var chunk = world.WorldChunk.initEmpty();
    errdefer chunk.deinit(a);
    _ = try chunk.tryApply(a, .{ 1, 1, 1 }, .{ .put = .dirt });
    try chunk.metadata.timed.trySchedule(a, .{ .block = timers.index(.{ 1, 1, 1 }), .kind = .grow_grass, .due_tick = 10 });
    return chunk;
}
test "grass deadline is terminal idempotent and catch-up preserves the original outcome" {
    const a = std.testing.allocator;
    var source = try fixture(a);
    defer source.deinit(a);
    var early = try prepare(a, &source, 9);
    defer early.deinit(a);
    try std.testing.expect(!early.material_changed and !early.metadata_changed);
    var first = try prepare(a, &source, 10);
    defer first.deinit(a);
    try std.testing.expectEqual(BlockType.grass, first.changes.items[0].material);
    try std.testing.expectEqual(@as(usize, 1), first.consumed);
    try std.testing.expectEqual(@as(usize, 0), first.timed.events.items.len);
    var intermediate = try source.tryClone(a);
    defer intermediate.deinit(a);
    first.applyPrepared(&intermediate);
    var repeated = try prepare(a, &intermediate, 10);
    defer repeated.deinit(a);
    try std.testing.expect(!repeated.metadata_changed);
    var direct = try prepare(a, &source, 10 + timers.transformation_delay);
    defer direct.deinit(a);
    try std.testing.expectEqual(BlockType.grass, direct.changes.items[0].material);
    try std.testing.expectEqual(@as(usize, 1), direct.consumed);
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

test "maximum deadlines remain terminal and future events keep stable deadline-cell order" {
    const a = std.testing.allocator;
    var source = try fixture(a);
    defer source.deinit(a);
    source.metadata.timed.events.items[0].due_tick = std.math.maxInt(u64) - 1;
    var before = try prepare(a, &source, std.math.maxInt(u64) - 2);
    defer before.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), before.consumed);
    var result = try prepare(a, &source, std.math.maxInt(u64));
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), result.consumed);
    try std.testing.expectEqual(BlockType.grass, result.changes.items[0].material);
    try std.testing.expectEqual(@as(usize, 0), result.timed.events.items.len);
    try source.metadata.timed.trySchedule(a, .{ .block = 4, .kind = .grow_grass, .due_tick = 100 });
    try source.metadata.timed.trySchedule(a, .{ .block = 3, .kind = .grow_grass, .due_tick = 100 });
    var future = try prepare(a, &source, 0);
    defer future.deinit(a);
    try std.testing.expectEqual(@as(timers.BlockIndex, 3), future.timed.events.items[0].block);
    try std.testing.expectEqual(@as(timers.BlockIndex, 4), future.timed.events.items[1].block);
}

test "unknown exposure defers grass without changing the material or original deadline" {
    const a = std.testing.allocator;
    var source = try fixture(a);
    defer source.deinit(a);
    const Unknown = struct {
        fn exposed(_: *anyopaque, _: [3]u5) ?bool {
            return null;
        }
    };
    var context: u8 = 0;
    var result = try prepareWithExposure(a, &source, 10 + timers.transformation_delay, .{ .context = &context, .exposed = Unknown.exposed });
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), result.consumed);
    try std.testing.expect(!result.material_changed and !result.metadata_changed);
    try std.testing.expectEqual(@as(usize, 1), result.timed.events.items.len);
    try std.testing.expectEqual(timers.Kind.grow_grass, result.timed.events.items[0].kind);
    try std.testing.expectEqual(@as(timers.Tick, 10), result.timed.events.items[0].due_tick);
    try std.testing.expectEqual(BlockType.dirt, source.content.getBlock(.{ 1, 1, 1 }));
}

test "active target or planned cover suppresses grass without checking physical exposure" {
    const a = std.testing.allocator;
    var source = try fixture(a);
    defer source.deinit(a);
    const Covered = struct {
        fn allowed(_: *anyopaque, _: [3]u5) bool {
            return false;
        }
        fn exposed(_: *anyopaque, _: [3]u5) ?bool {
            @panic("suppressed growth must not query physical exposure");
        }
    };
    var context: u8 = 0;
    var result = try prepareWithExposure(a, &source, std.math.maxInt(u64), .{ .context = &context, .exposed = Covered.exposed, .grass_allowed = Covered.allowed });
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), result.consumed);
    try std.testing.expect(!result.material_changed);
    try std.testing.expectEqual(@as(usize, 0), result.changes.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.timed.events.items.len);
}

test "mixed unknown and ready grass deadlines retain ordering without consuming deferred work" {
    const a = std.testing.allocator;
    var source = world.WorldChunk.initEmpty();
    defer source.deinit(a);
    for (1..5) |x| {
        const local: [3]u5 = .{ @intCast(x), 1, 1 };
        _ = try source.tryApply(a, local, .{ .put = .dirt });
        try source.metadata.timed.trySchedule(a, .{ .block = timers.index(local), .kind = .grow_grass, .due_tick = x * 10 });
    }
    const Mixed = struct {
        fn exposed(_: *anyopaque, local: [3]u5) ?bool {
            return if (local[0] == 2) true else null;
        }
    };
    var context: u8 = 0;
    var result = try prepareWithExposure(a, &source, 30, .{ .context = &context, .exposed = Mixed.exposed });
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), result.consumed);
    try std.testing.expectEqual(@as(usize, 1), result.changes.items.len);
    try std.testing.expectEqual(timers.index(.{ 2, 1, 1 }), result.changes.items[0].cell);
    try std.testing.expectEqualDeep(&[_]timers.Event{
        .{ .block = timers.index(.{ 1, 1, 1 }), .kind = .grow_grass, .due_tick = 10 },
        .{ .block = timers.index(.{ 3, 1, 1 }), .kind = .grow_grass, .due_tick = 30 },
        .{ .block = timers.index(.{ 4, 1, 1 }), .kind = .grow_grass, .due_tick = 40 },
    }, result.timed.events.items);
    try std.testing.expectEqual(@as(usize, 4), source.metadata.timed.events.items.len);
    try std.testing.expectEqual(BlockType.dirt, source.content.getBlock(.{ 2, 1, 1 }));
}

test "construction initialization markers persist through every timer cutoff" {
    const a = std.testing.allocator;
    var source = try fixture(a);
    defer source.deinit(a);
    try source.metadata.timed.trySchedule(a, .{ .block = timers.index(.{ 1, 1, 1 }), .kind = .initialize_grass, .due_tick = 7 });
    var result = try prepare(a, &source, std.math.maxInt(u64));
    defer result.deinit(a);
    try std.testing.expect(!result.material_changed and !result.metadata_changed);
    try std.testing.expectEqual(@as(usize, 0), result.consumed);
    try std.testing.expectEqual(@as(usize, 1), result.timed.events.items.len);
    try std.testing.expectEqual(timers.Kind.initialize_grass, result.timed.events.items[0].kind);
    try std.testing.expectEqual(@as(timers.Tick, 7), result.timed.events.items[0].due_tick);
    try std.testing.expectEqual(BlockType.dirt, source.content.getBlock(.{ 1, 1, 1 }));
}
