//! Detached surface effects of applying blueprint miniatures. Preparation reads
//! physical terrain only and never changes blocks, timers, or blueprint progress.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const runtime = @import("blueprint_runtime.zig");
const transformations = @import("block_transformations.zig");
const consts = @import("consts.zig");

pub const Cell = runtime.Cell;
pub const ChunkId = consts.ChunkId;
pub const GrowthMask = std.StaticBitSet(32768);
pub const Surface = struct {
    material: blueprint.BlockType,
    timer_kind: ?transformations.Kind = null,
};

/// The caller supplies a coherent physical block and its actual pending timer.
/// Unknown block or metadata state must fail the read, rather than imply air.
pub const Source = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, Cell) anyerror!Surface,
};

pub const Change = struct {
    block: Cell,
    clear_grass: bool,
    cancel_grow: bool,
};

pub const Plan = struct {
    changes: std.ArrayList(Change) = .empty,
    /// Canonical unique chunks with an actual material or timer change.
    chunk_ids: std.ArrayList(ChunkId) = .empty,
    /// Exact prepared grass-growth cancellations, including empty masks for
    /// changed chunks whose grass is cleared without a pending growth timer.
    cancel_grow: std.AutoHashMapUnmanaged(ChunkId, GrowthMask) = .empty,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.changes.deinit(allocator);
        self.chunk_ids.deinit(allocator);
        self.cancel_grow.deinit(allocator);
        self.* = undefined;
    }
};

/// Requires a certified definition and admitted, injective instance footprint.
/// Stage every listed block/timer/revision before publishing this plan together
/// with the instance. The plan needs no allocation while its changes are applied.
/// Empty definition cells, loose dirt, and its compaction timers are untouched.
pub fn prepare(allocator: std.mem.Allocator, layout: *const engine.WorldLayout, definition: blueprint.Definition, instance: runtime.Instance, source: Source) !Plan {
    var result: Plan = .{};
    errdefer result.deinit(allocator);
    for (definition.cells, 0..) |material, index| {
        if (material == .none) continue;
        var block = runtime.worldCell(layout, instance.origin, definition.size, instance.rotation, blueprint.cellAtIndex(definition.size, index)) orelse return error.InvalidBlueprint;
        if (block[2] == 0) continue;
        block[2] -= 1;
        const surface = try source.read(source.context, block);
        if (surface.material != .grass and surface.material != .packed_dirt) continue;
        const change: Change = .{ .block = block, .clear_grass = surface.material == .grass, .cancel_grow = surface.timer_kind == .grow_grass };
        if (!change.clear_grass and !change.cancel_grow) continue;
        try result.changes.append(allocator, change);
        const id = layout.encodeChunkCoords(.{
            @intCast(block[0] / consts.CHUNK_SIZE),
            @intCast(block[1] / consts.CHUNK_SIZE),
            @intCast(block[2] / consts.CHUNK_SIZE),
        });
        const entry = try result.cancel_grow.getOrPut(allocator, id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .initEmpty();
            try result.chunk_ids.append(allocator, id);
        }
        if (change.cancel_grow) entry.value_ptr.set(transformations.index(.{ @truncate(block[0]), @truncate(block[1]), @truncate(block[2]) }));
    }
    return result;
}

const Fixture = struct {
    surfaces: std.AutoHashMapUnmanaged(Cell, Surface) = .empty,
    reads: usize = 0,
    fail_at: ?Cell = null,

    fn deinit(self: *Fixture) void {
        self.surfaces.deinit(std.testing.allocator);
    }

    fn put(self: *Fixture, block: Cell, surface: Surface) !void {
        try self.surfaces.put(std.testing.allocator, block, surface);
    }

    fn source(self: *Fixture) Source {
        return .{ .context = self, .read = read };
    }

    fn read(context: *anyopaque, block: Cell) !Surface {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (self.fail_at) |failed| if (std.mem.eql(u32, &failed, &block)) return error.MissingData;
        return self.surfaces.get(block) orelse .{ .material = .none };
    }

    fn instance(origin: Cell, rotation: u2) runtime.Instance {
        return .{ .id = 1, .definition_id = 1, .owner = 1, .origin = origin, .rotation = rotation, .fulfilled = &.{}, .remaining = 0, .box_chunks = &.{} };
    }
};

test "miniature coverage clears only target-below grass and cancels only surface growth" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const definition: blueprint.Definition = .{ .size = .{ 7, 1, 1 }, .cells = &.{ .planks, .planks, .planks, .none, .planks, .planks, .planks }, .target_count = 6 };
    const instance = Fixture.instance(.{ 10, 10, 32 }, 0);
    var fixture: Fixture = .{};
    defer fixture.deinit();
    const surfaces = [_]Surface{
        .{ .material = .grass },
        .{ .material = .packed_dirt, .timer_kind = .grow_grass },
        .{ .material = .dirt, .timer_kind = .compact_dirt },
        .{ .material = .grass, .timer_kind = .grow_grass }, // Hole: never queried.
        .{ .material = .packed_dirt },
        .{ .material = .grass, .timer_kind = .compact_dirt },
        .{ .material = .stone, .timer_kind = .grow_grass },
    };
    for (surfaces, 0..) |surface, x| try fixture.put(.{ 10 + @as(u32, @intCast(x)), 10, 31 }, surface);
    var plan = try prepare(a, &layout, definition, instance, fixture.source());
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), fixture.reads);
    try std.testing.expectEqualDeep(&[_]Change{
        .{ .block = .{ 10, 10, 31 }, .clear_grass = true, .cancel_grow = false },
        .{ .block = .{ 11, 10, 31 }, .clear_grass = false, .cancel_grow = true },
        .{ .block = .{ 15, 10, 31 }, .clear_grass = true, .cancel_grow = false },
    }, plan.changes.items);
    try std.testing.expectEqualSlices(ChunkId, &.{layout.encodeChunkCoords(.{ 0, 0, 0 })}, plan.chunk_ids.items);
    const mask = plan.cancel_grow.getPtr(plan.chunk_ids.items[0]).?;
    try std.testing.expectEqual(@as(usize, 1), mask.count());
    for (0..surfaces.len) |x| try std.testing.expectEqual(x == 1, mask.isSet(transformations.index(.{ 10 + @as(u5, @intCast(x)), 10, 31 })));
    // Preparation itself changes no material or timer, even for planned effects.
    for (surfaces, 0..) |surface, x| try std.testing.expectEqualDeep(surface, fixture.surfaces.get(.{ 10 + @as(u32, @intCast(x)), 10, 31 }).?);
}

test "coverage uses rotated wrapped targets and deduplicates changed chunks across boundaries" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const definition: blueprint.Definition = .{ .size = .{ 2, 3, 2 }, .cells = &.{ .planks, .planks, .none, .planks, .planks, .none, .planks, .planks, .planks, .planks, .planks, .planks }, .target_count = 10 };
    const instance = Fixture.instance(.{ 127, 31, 32 }, 1);
    var fixture: Fixture = .{};
    defer fixture.deinit();
    // Clockwise rotation places (x,y,z) at (y,1-x,z), then wraps X. Upper
    // targets cover grass only through holes in the empty planned bottom layer.
    const expected = [_]Cell{
        .{ 127, 32, 31 }, .{ 127, 31, 31 }, .{ 0, 31, 31 }, .{ 1, 32, 31 },
        .{ 0, 32, 32 },   .{ 1, 31, 32 },
    };
    for (expected) |block| try fixture.put(block, .{ .material = .grass, .timer_kind = .grow_grass });
    var plan = try prepare(a, &layout, definition, instance, fixture.source());
    defer plan.deinit(a);
    try std.testing.expectEqual(expected.len, plan.changes.items.len);
    for (plan.changes.items, expected) |change, block| {
        try std.testing.expectEqual(block, change.block);
        try std.testing.expect(change.clear_grass and change.cancel_grow);
    }
    try std.testing.expectEqual(@as(usize, 10), fixture.reads);
    try std.testing.expectEqual(@as(usize, 6), plan.chunk_ids.items.len);
    for (plan.chunk_ids.items, 0..) |id, i| try std.testing.expect(std.mem.indexOfScalar(ChunkId, plan.chunk_ids.items[0..i], id) == null);
    try std.testing.expectEqual(plan.chunk_ids.items.len, plan.cancel_grow.count());
    for (plan.chunk_ids.items) |id| try std.testing.expectEqual(@as(usize, 1), plan.cancel_grow.getPtr(id).?.count());
    for (expected) |block| {
        const id = layout.encodeChunkCoords(.{ @intCast(block[0] / consts.CHUNK_SIZE), @intCast(block[1] / consts.CHUNK_SIZE), @intCast(block[2] / consts.CHUNK_SIZE) });
        try std.testing.expect(plan.cancel_grow.getPtr(id).?.isSet(transformations.index(.{ @truncate(block[0]), @truncate(block[1]), @truncate(block[2]) })));
    }
}

test "clearing grass without a growth event prepares an empty cancellation mask" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const definition: blueprint.Definition = .{ .size = .{ 1, 1, 1 }, .cells = &.{.planks}, .target_count = 1 };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.put(.{ 10, 10, 31 }, .{ .material = .grass });
    var plan = try prepare(a, &layout, definition, Fixture.instance(.{ 10, 10, 32 }, 0), fixture.source());
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), plan.changes.items.len);
    try std.testing.expect(plan.changes.items[0].clear_grass);
    try std.testing.expect(!plan.changes.items[0].cancel_grow);
    try std.testing.expectEqual(@as(usize, 1), plan.chunk_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.cancel_grow.getPtr(plan.chunk_ids.items[0]).?.count());
}

test "coverage skips cells without a below block and has no effects for loose soil" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const definition: blueprint.Definition = .{ .size = .{ 1, 1, 2 }, .cells = &.{ .dirt, .planks }, .target_count = 2 };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.put(.{ 10, 10, 0 }, .{ .material = .dirt, .timer_kind = .compact_dirt });
    var plan = try prepare(a, &layout, definition, Fixture.instance(.{ 10, 10, 0 }, 0), fixture.source());
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fixture.reads);
    try std.testing.expectEqual(@as(usize, 0), plan.changes.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.chunk_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), plan.cancel_grow.count());
    try std.testing.expectEqualDeep(Surface{ .material = .dirt, .timer_kind = .compact_dirt }, fixture.surfaces.get(.{ 10, 10, 0 }).?);
}

fn allocationFailureFixture(a: std.mem.Allocator) !void {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const definition: blueprint.Definition = .{ .size = .{ 2, 1, 1 }, .cells = &.{ .planks, .planks }, .target_count = 2 };
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.put(.{ 31, 10, 31 }, .{ .material = .grass, .timer_kind = .grow_grass });
    try fixture.put(.{ 32, 10, 31 }, .{ .material = .packed_dirt, .timer_kind = .grow_grass });
    defer {
        std.debug.assert(fixture.surfaces.get(.{ 31, 10, 31 }).?.material == .grass);
        std.debug.assert(fixture.surfaces.get(.{ 32, 10, 31 }).?.timer_kind == .grow_grass);
    }
    var plan = try prepare(a, &layout, definition, Fixture.instance(.{ 31, 10, 32 }, 0), fixture.source());
    defer plan.deinit(a);
}

test "coverage allocation and source-read failures free partial plans without touching surfaces" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureFixture, .{});
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const definition: blueprint.Definition = .{ .size = .{ 2, 1, 1 }, .cells = &.{ .planks, .planks }, .target_count = 2 };
    var fixture: Fixture = .{ .fail_at = .{ 11, 10, 31 } };
    defer fixture.deinit();
    try fixture.put(.{ 10, 10, 31 }, .{ .material = .grass, .timer_kind = .grow_grass });
    try std.testing.expectError(error.MissingData, prepare(std.testing.allocator, &layout, definition, Fixture.instance(.{ 10, 10, 32 }, 0), fixture.source()));
    try std.testing.expectEqualDeep(Surface{ .material = .grass, .timer_kind = .grow_grass }, fixture.surfaces.get(.{ 10, 10, 31 }).?);
}
