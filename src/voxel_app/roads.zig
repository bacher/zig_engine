//! Incremental road formation. A completed run owns its cells until it is broken.
const std = @import("std");
const engine = @import("engine");
const world = @import("world.zig");
const rules = @import("block_rules.zig");
const data = @import("road_data.zig");
const custom = engine.voxel_chunk.custom_block;
const Cell = rules.Cell;
pub const minimum_length: u32 = 4;
pub const maximum_length: u32 = 12;
pub const Undo = struct { block: [3]u32, slope: ?data.Slope };
const Change = struct { cell: Cell, slope: ?data.Slope };
const blueprint_runtime = @import("blueprint_runtime.zig");
pub const Plan = struct {
    changes: []Change,
    chunk_ids: []u32,
    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.changes);
        allocator.free(self.chunk_ids);
        self.* = undefined;
    }
    pub fn reserveCommit(self: Plan, context: Context) !void {
        try context.changed.ensureUnusedCapacity(context.allocator, self.chunk_ids.len);
    }
    pub fn applyPrepared(self: Plan, context: Context) void {
        std.debug.assert(context.undo == null and context.formed == null);
        var commit = context;
        commit.prepared = true;
        commit.virtual_edit = null;
        for (self.changes) |change| commit.set(change.cell, change.slope);
    }
};

/// Validate the final indirect shape writes together, before publishing any
/// material or metadata. Existing unfinished physical structures may temporarily
/// be invalid; all affected constructions must remain valid with targets filled.
pub fn validateCompletedPlan(allocator: std.mem.Allocator, physical: rules.Reader, state: *const blueprint_runtime.State, chunks: *const world.ChunksHashMap, plan: Plan, operation: ?world.BlockOperation) !?rules.Failure {
    if (plan.changes.len == 0) return null;
    const Final = struct {
        physical: rules.Reader,
        plan: Plan,
        operation: ?world.BlockOperation,
        fn read(context: *anyopaque, block: [3]u32) ?rules.BlockType {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.operation) |edit| if (std.mem.eql(u32, &block, &edit.block)) return switch (edit.action) {
                .remove => .none,
                .put => |value| if (value == .country_road_adaptive) .custom else value,
            };
            return self.physical.block_at(self.physical.context, block);
        }
        fn shape(context: *anyopaque, block: [3]u32) ?custom.Shape {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (self.plan.changes) |change| if (@reduce(.And, change.cell == Cell{ block[0], block[1], block[2] })) return (data.Road{ .index = 0, .slope = change.slope }).shape();
            if (self.operation) |edit| if (std.mem.eql(u32, &block, &edit.block)) return switch (edit.action) {
                .remove => null,
                .put => |value| if (value == .country_road_adaptive or value == .custom) .adaptive else null,
            };
            return if (self.physical.custom_shape_at) |get| get(self.physical.context, block) else null;
        }
        fn immutable(context: *anyopaque, block: [3]u32) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.physical.isImmutable(.{ block[0], block[1], block[2] });
        }
        fn reader(self: *@This()) rules.Reader {
            var result = self.physical;
            result.context = self;
            result.block_at = read;
            result.custom_shape_at = shape;
            result.immutable_at = immutable;
            return result;
        }
    };
    var final: Final = .{ .physical = physical, .plan = plan, .operation = operation };
    const final_physical = final.reader();
    if (operation) |edit| if (edit.action == .put) {
        var validator: rules.Validator = .{ .allocator = allocator, .reader = final_physical };
        defer validator.deinit();
        const failure = validator.checkExisting(.{ edit.block[0], edit.block[1], edit.block[2] });
        if (validator.allocation_failed) return error.OutOfMemory;
        if (failure) |reason| return reason;
    };
    var completed: blueprint_runtime.CompletedReader = .{ .physical = final_physical, .state = state };
    if (operation == null) return validateShapeOnlyPlan(allocator, physical, &completed, plan);
    var unique: std.AutoHashMapUnmanaged(Cell, void) = .empty;
    defer unique.deinit(allocator);
    for (plan.changes) |change| {
        if (physical.isImmutable(change.cell)) return .{ .reason = .immutable_cell, .subject = change.cell };
        const block: [3]u32 = .{ @intCast(change.cell[0]), @intCast(change.cell[1]), @intCast(change.cell[2]) };
        const real = try world.tryCollectConstructed(allocator, physical.layout, chunks, block);
        defer allocator.free(real);
        const affected = try state.collectAffected(allocator, physical.layout, block, real);
        defer allocator.free(affected);
        for (affected) |cell| try unique.put(allocator, cell, {});
    }
    if (operation) |edit| if (edit.action == .put) {
        try unique.put(allocator, .{ edit.block[0], edit.block[1], edit.block[2] }, {});
    };
    var validator: rules.Validator = .{ .allocator = allocator, .reader = completed.reader() };
    defer validator.deinit();
    var cells = unique.keyIterator();
    while (cells.next()) |cell| {
        const failure = validator.checkExisting(cell.*);
        if (validator.allocation_failed) return error.OutOfMemory;
        if (failure) |reason| return reason;
    }
    return null;
}

/// Shapes affect only the road's own immediate support and roads directly above.
/// Other construction rules read materials, which this plan does not change.
fn validateShapeOnlyPlan(allocator: std.mem.Allocator, physical: rules.Reader, completed: *blueprint_runtime.CompletedReader, plan: Plan) !?rules.Failure {
    const reader = completed.reader();
    // Immediate road checks have no shared support search to cache. Disabling
    // both caches keeps this path allocation-free while sharing the game rules.
    var validator: rules.Validator = .{ .allocator = allocator, .reader = reader, .cache_limit = 0, .failure_cache_limit = 0 };
    defer validator.deinit();
    for (plan.changes) |change| {
        if (physical.isImmutable(change.cell)) return .{ .reason = .immutable_cell, .subject = change.cell };
        const own_failure = validator.checkExisting(change.cell);
        if (validator.allocation_failed) return error.OutOfMemory;
        if (own_failure) |failure| return failure;
        const above = change.cell + Cell{ 0, 0, 1 };
        const material = reader.get(above) orelse return .{ .reason = .missing_data, .subject = above };
        if (!material.isRoad()) continue;
        const above_failure = validator.checkExisting(above);
        if (validator.allocation_failed) return error.OutOfMemory;
        if (above_failure) |failure| return failure;
    }
    return null;
}

test "road final-shape validation protects real and miniature road dependents" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var terrain = try world.World.init(a, &layout);
    defer terrain.deinit();
    for (0..2) |z| for (0..2) |y| for (0..2) |x| try terrain.insertChunk(.{ @intCast(x), @intCast(y), @intCast(z) }, world.WorldChunk.initEmpty());
    const chunk = terrain.chunks.getPtr(layout.encodeChunkCoords(.{ 0, 0, 0 })).?;
    try std.testing.expectEqual(world.OperationStatus.success, try chunk.tryApply(a, .{ 10, 10, 9 }, .{ .put = .stone }));
    try std.testing.expectEqual(world.OperationStatus.success, try chunk.tryApply(a, .{ 10, 10, 10 }, .{ .put = .country_road_adaptive }));
    const changes = [_]Change{.{ .cell = .{ 10, 10, 10 }, .slope = .{ .high_endpoint = .{ 9, 10, 10 }, .downhill = .positive_x, .length = 4, .section = 0 } }};
    const plan: Plan = .{ .changes = @constCast(&changes), .chunk_ids = &.{} };
    try std.testing.expectEqual(@as(?rules.Failure, null), try validateCompletedPlan(a, terrain.reader(), &terrain.blueprints, &terrain.chunks, plan, null));
    try std.testing.expectEqual(world.OperationStatus.success, try chunk.tryApply(a, .{ 10, 10, 11 }, .{ .put = .country_road_solid }));
    try chunk.metadata.tryMarkConstructed(a, @import("block_transformations.zig").index(.{ 10, 10, 11 }));
    const real = (try validateCompletedPlan(a, terrain.reader(), &terrain.blueprints, &terrain.chunks, plan, null)).?;
    try std.testing.expectEqual(rules.Reason.road_support, real.reason);
    try std.testing.expectEqual(world.OperationStatus.success, try chunk.tryApply(a, .{ 10, 10, 11 }, .remove));
    var saved: blueprint_runtime.SavedDefinition = .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Road"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{.country_road_solid}), .target_count = 1 } };
    terrain.blueprints.insertDefinition(a, saved) catch |err| {
        saved.deinit(a);
        return err;
    };
    var site = try terrain.blueprints.prepareInstance(a, terrain.layout, 1, 1, 1, .{ 10, 10, 11 }, 0);
    terrain.blueprints.insertInstance(a, terrain.layout, site) catch |err| {
        site.deinit(a);
        return err;
    };
    const planned = (try validateCompletedPlan(a, terrain.reader(), &terrain.blueprints, &terrain.chunks, plan, null)).?;
    try std.testing.expectEqual(rules.Reason.road_support, planned.reason);
    // Planning/validation never changes the road or publishes a partial formation.
    try std.testing.expectEqual(@as(?data.Slope, null), chunk.metadata.road(@import("block_transformations.zig").index(.{ 10, 10, 10 })).?.slope);
    try std.testing.expect(terrain.blueprints.targetAt(.{ 10, 10, 11 }) != null);
}

const ShapeOnlyValidationTest = struct {
    const layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } }) catch unreachable;
    blocks: std.AutoHashMapUnmanaged(Cell, rules.BlockType) = .empty,
    shapes: std.AutoHashMapUnmanaged(Cell, custom.Shape) = .empty,
    blueprints: blueprint_runtime.State = .{},
    chunks: world.ChunksHashMap = .empty,
    center: Cell = .{ 10, 10, 10 },
    missing: ?Cell = null,
    immutable: ?Cell = null,
    reads: usize = 0,
    distant_reads: usize = 0,
    out_of_bounds_reads: usize = 0,

    fn deinit(self: *@This()) void {
        const a = std.testing.allocator;
        self.blocks.deinit(a);
        self.shapes.deinit(a);
        self.blueprints.deinit(a);
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| chunk.deinit(a);
        self.chunks.deinit(a);
    }

    fn read(context: *anyopaque, block: [3]u32) ?rules.BlockType {
        const self: *@This() = @ptrCast(@alignCast(context));
        const cell: Cell = .{ block[0], block[1], block[2] };
        self.reads += 1;
        if (rules.distance(&layout, cell, self.center) > 1) self.distant_reads += 1;
        for (block, layout.size_in_blocks) |coordinate, limit| if (coordinate >= limit) {
            self.out_of_bounds_reads += 1;
        };
        if (self.missing) |missing| if (@reduce(.And, missing == cell)) return null;
        return self.blocks.get(cell) orelse .none;
    }

    fn shape(context: *anyopaque, block: [3]u32) ?custom.Shape {
        const self: *@This() = @ptrCast(@alignCast(context));
        const cell: Cell = .{ block[0], block[1], block[2] };
        if (self.shapes.get(cell)) |value| return value;
        return if (self.blocks.get(cell) == .custom) .adaptive else null;
    }

    fn isImmutable(context: *anyopaque, block: [3]u32) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        const cell: Cell = .{ block[0], block[1], block[2] };
        return if (self.immutable) |immutable| @reduce(.And, immutable == cell) else false;
    }

    fn reader(self: *@This()) rules.Reader {
        return .{ .layout = &layout, .context = self, .block_at = read, .custom_shape_at = shape, .immutable_at = isImmutable };
    }

    fn put(self: *@This(), cell: Cell, material: rules.BlockType) !void {
        try self.blocks.put(std.testing.allocator, cell, material);
    }

    fn markConstructed(self: *@This(), cell: Cell) !void {
        const coords, const local = world.splitBlockCoords(.{ @intCast(cell[0]), @intCast(cell[1]), @intCast(cell[2]) });
        const entry = try self.chunks.getOrPut(std.testing.allocator, layout.encodeChunkCoords(coords));
        if (!entry.found_existing) entry.value_ptr.* = world.WorldChunk.initEmpty();
        try entry.value_ptr.metadata.tryMarkConstructed(std.testing.allocator, @import("block_transformations.zig").index(local));
    }

    fn addTarget(self: *@This(), cell: Cell, material: rules.BlockType) !void {
        const a = std.testing.allocator;
        const id: u64 = self.blueprints.definitions.count() + 1;
        var saved: blueprint_runtime.SavedDefinition = .{ .id = id, .owner = 1, .name = try a.dupe(u8, "Shape target"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{material}), .target_count = 1 } };
        self.blueprints.insertDefinition(a, saved) catch |err| {
            saved.deinit(a);
            return err;
        };
        var instance = try self.blueprints.prepareInstance(a, &layout, id, id, 1, .{ @intCast(cell[0]), @intCast(cell[1]), @intCast(cell[2]) }, 0);
        self.blueprints.insertInstance(a, &layout, instance) catch |err| {
            instance.deinit(a);
            return err;
        };
    }

    fn slope(cell: Cell) data.Slope {
        return .{ .high_endpoint = .{ @intCast(if (cell[0] == 0) layout.size_in_blocks[0] - 1 else cell[0] - 1), @intCast(cell[1]), @intCast(cell[2]) }, .downhill = .positive_x, .length = 4, .section = 0 };
    }

    fn plan(changes: []const Change) Plan {
        return .{ .changes = @constCast(changes), .chunk_ids = &.{} };
    }
};

test "shape-only road validation matches material-path checks for road support and miniature targets" {
    const c: Cell = .{ 10, 10, 10 };
    const below = c - Cell{ 0, 0, 1 };
    const above = c + Cell{ 0, 0, 1 };
    const harmless_edit: world.BlockOperation = .{ .block = .{ 14, 10, 10 }, .action = .{ .put = .country_road_solid } };
    // The existing material-edit validator is the independent broad oracle.
    for ([_]rules.BlockType{ .stone, .sand, .custom, .custom }, 0..) |support, support_case| {
        for ([_]bool{ false, true }) |formed| for (0..3) |above_case| {
            var f: ShapeOnlyValidationTest = .{};
            defer f.deinit();
            try f.put(c, .custom);
            try f.put(below, support);
            try f.put(.{ 14, 10, 9 }, .stone);
            try f.markConstructed(c);
            if (support_case == 3) try f.shapes.put(std.testing.allocator, below, ShapeOnlyValidationTest.slope(below).shape());
            if (above_case == 1) {
                try f.put(above, .country_road_solid);
                try f.markConstructed(above);
            } else if (above_case == 2) try f.addTarget(above, .country_road_solid);
            const changes = [_]Change{.{ .cell = c, .slope = if (formed) ShapeOnlyValidationTest.slope(c) else null }};
            const plan = ShapeOnlyValidationTest.plan(&changes);
            const narrow = try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, plan, null);
            try std.testing.expect(f.reads <= 6);
            try std.testing.expectEqual(@as(usize, 0), f.distant_reads);
            const broad = try validateCompletedPlan(std.testing.allocator, f.reader(), &f.blueprints, &f.chunks, plan, harmless_edit);
            try std.testing.expectEqual(broad == null, narrow == null);
            if (broad) |failure| try std.testing.expectEqual(failure.reason, narrow.?.reason);
            try std.testing.expect(f.shapes.get(c) == null);
        };
    }
}

test "shape-only stacked road checks see every final shape before validating any section" {
    var f: ShapeOnlyValidationTest = .{};
    defer f.deinit();
    const lower: Cell = .{ 10, 10, 10 };
    const upper = lower + Cell{ 0, 0, 1 };
    const lower_slope = ShapeOnlyValidationTest.slope(lower);
    const upper_slope = ShapeOnlyValidationTest.slope(upper);
    try f.put(lower - Cell{ 0, 0, 1 }, .stone);
    try f.put(lower, .custom);
    try f.put(upper, .custom);
    try f.shapes.put(std.testing.allocator, lower, lower_slope.shape());
    const unsafe = [_]Change{.{ .cell = upper, .slope = upper_slope }};
    const rejected = (try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, ShapeOnlyValidationTest.plan(&unsafe), null)).?;
    try std.testing.expectEqual(rules.Reason.road_support, rejected.reason);
    // The upper section is checked first, but its support's reversion is already visible.
    const safe = [_]Change{ .{ .cell = upper, .slope = upper_slope }, .{ .cell = lower, .slope = null } };
    try std.testing.expectEqual(@as(?rules.Failure, null), try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, ShapeOnlyValidationTest.plan(&safe), null));
    const broken = [_]Change{ .{ .cell = upper, .slope = null }, .{ .cell = lower, .slope = lower_slope } };
    try std.testing.expectEqual(rules.Reason.road_support, (try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, ShapeOnlyValidationTest.plan(&broken), null)).?.reason);
    try std.testing.expectEqualDeep(lower_slope.shape(), f.shapes.get(lower).?);
    try std.testing.expect(f.shapes.get(upper) == null);
}

test "shape-only plans ignore other materials and unrelated invalid constructions while material edits retain broad checks" {
    var f: ShapeOnlyValidationTest = .{};
    defer f.deinit();
    const c: Cell = .{ 10, 10, 10 };
    const above = c + Cell{ 0, 0, 1 };
    const unrelated: Cell = .{ 20, 20, 10 };
    try f.put(c - Cell{ 0, 0, 1 }, .stone);
    try f.put(c, .custom);
    try f.markConstructed(c);
    try f.put(unrelated, .planks);
    try f.markConstructed(unrelated);
    try f.put(.{ 14, 10, 9 }, .stone);
    const changes = [_]Change{.{ .cell = c, .slope = ShapeOnlyValidationTest.slope(c) }};
    const plan = ShapeOnlyValidationTest.plan(&changes);
    for ([_]rules.BlockType{ .planks, .sand, .reinforced_concrete, .dirt }) |material| {
        try f.put(above, material);
        try std.testing.expectEqual(@as(?rules.Failure, null), try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, plan, null));
    }
    try std.testing.expectEqual(@as(usize, 0), f.distant_reads);
    try f.put(above, .none);
    const failure = (try validateCompletedPlan(std.testing.allocator, f.reader(), &f.blueprints, &f.chunks, plan, .{ .block = .{ 14, 10, 10 }, .action = .{ .put = .country_road_solid } })).?;
    try std.testing.expectEqualDeep(unrelated, failure.subject);
}

test "shape-only plans fail closed for missing cells and immutable writes without allocating or mutating" {
    var f: ShapeOnlyValidationTest = .{};
    defer f.deinit();
    const c: Cell = .{ 10, 10, 10 };
    try f.put(c, .custom);
    try f.put(c - Cell{ 0, 0, 1 }, .stone);
    const changes = [_]Change{.{ .cell = c, .slope = ShapeOnlyValidationTest.slope(c) }};
    const plan = ShapeOnlyValidationTest.plan(&changes);
    try std.testing.expectEqual(@as(?rules.Failure, null), try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, plan, null));
    try std.testing.expectEqual(@as(usize, 4), f.reads);
    for ([_]Cell{ c, c - Cell{ 0, 0, 1 }, c + Cell{ 0, 0, 1 } }) |missing| {
        f.missing = missing;
        const failure = (try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, plan, null)).?;
        try std.testing.expectEqual(rules.Reason.missing_data, failure.reason);
    }
    // A miniature cannot hide a missing physical dependency.
    try f.addTarget(c + Cell{ 0, 0, 1 }, .country_road_solid);
    try std.testing.expectEqual(rules.Reason.missing_data, (try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, plan, null)).?.reason);
    f.missing = null;
    f.immutable = c;
    try std.testing.expectEqual(rules.Reason.immutable_cell, (try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, plan, null)).?.reason);
    try std.testing.expectEqual(@as(usize, 0), f.distant_reads);
    try std.testing.expectEqual(@as(u32, 1), f.blueprints.instances.get(1).?.remaining);
    try std.testing.expectEqual(@as(u32, 0), f.shapes.count());
}

test "shape-only dependency reads respect wrapped seam columns vertical chunk boundaries and finite bounds" {
    for ([_]Cell{ .{ 0, 0, 31 }, .{ 63, 63, 63 }, .{ 32, 32, 32 } }) |c| {
        var f: ShapeOnlyValidationTest = .{ .center = c };
        defer f.deinit();
        try f.put(c, .custom);
        try f.put(c - Cell{ 0, 0, 1 }, .stone);
        const changes = [_]Change{.{ .cell = c, .slope = ShapeOnlyValidationTest.slope(c) }};
        const plan = ShapeOnlyValidationTest.plan(&changes);
        try std.testing.expectEqual(@as(?rules.Failure, null), try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, plan, null));
        if (c[2] < 63) {
            try f.addTarget(c + Cell{ 0, 0, 1 }, .country_road_solid);
            try std.testing.expectEqual(rules.Reason.road_support, (try validateCompletedPlan(std.testing.failing_allocator, f.reader(), &f.blueprints, &f.chunks, plan, null)).?.reason);
        }
        try std.testing.expectEqual(@as(usize, 0), f.distant_reads);
        try std.testing.expectEqual(@as(usize, 0), f.out_of_bounds_reads);
    }
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    reader: rules.Reader,
    chunks: *world.ChunksHashMap,
    changed: *std.ArrayList(u32),
    undo: ?*std.ArrayList(Undo) = null,
    formed: ?*std.ArrayList(data.Slope) = null,
    planned: ?*std.ArrayList(Change) = null,
    planning_failure: ?*?anyerror = null,
    prepared: bool = false,
    virtual_edit: ?world.BlockOperation = null,
    max_plan_changes: usize = std.math.maxInt(usize),

    /// Discover the complete section-change footprint before reserving and
    /// applying it. Authoritative callers do not request optimistic undo data.
    /// Includes members absent from the current resident map, so callers can
    /// load/gate a persisted formation before computing its exact mutation plan.
    pub fn appendRunChunkIds(self: Context, slope: data.Slope, ids: *std.ArrayList(u32)) !void {
        for (0..self.memberLimit(slope)) |section| {
            const cell = self.normalize(self.sectionCell(slope, @intCast(section))) orelse continue;
            const coords, _ = world.splitBlockCoords(.{ @intCast(cell[0]), @intCast(cell[1]), @intCast(cell[2]) });
            const id = self.reader.layout.encodeChunkCoords(coords);
            if (std.mem.indexOfScalar(u32, ids.items, id) == null) {
                if (ids.items.len >= self.max_plan_changes) return error.Capacity;
                try ids.append(self.allocator, id);
            }
        }
    }

    pub fn planAfterEdit(self: Context, operation: world.BlockOperation, previous: ?data.Road) !Plan {
        return self.planReplay(operation, previous, &.{});
    }

    pub fn planReplay(self: Context, operation: world.BlockOperation, previous: ?data.Road, formations: []const data.Slope) !Plan {
        std.debug.assert(self.undo == null and self.formed == null);
        var changes: std.ArrayList(Change) = .empty;
        errdefer changes.deinit(self.allocator);
        var failure: ?anyerror = null;
        var planner = self;
        planner.planned = &changes;
        planner.planning_failure = &failure;
        for (formations) |formation| planner.restoreFormation(formation);
        planner.afterEdit(operation, previous);
        if (failure) |err| return err;
        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(self.allocator);
        for (changes.items) |change| {
            if (self.reader.isImmutable(change.cell)) return error.ImmutableCell;
            const coords, _ = world.splitBlockCoords(.{ @intCast(change.cell[0]), @intCast(change.cell[1]), @intCast(change.cell[2]) });
            const id = self.reader.layout.encodeChunkCoords(coords);
            if (std.mem.indexOfScalar(u32, ids.items, id) == null) try ids.append(self.allocator, id);
        }
        const owned_changes = try changes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_changes);
        return .{ .changes = owned_changes, .chunk_ids = try ids.toOwnedSlice(self.allocator) };
    }

    pub fn tryAfterEdit(self: Context, operation: world.BlockOperation, previous: ?data.Road) !void {
        var plan = try self.planAfterEdit(operation, previous);
        defer plan.deinit(self.allocator);
        try plan.reserveCommit(self);
        plan.applyPrepared(self);
    }

    fn normalize(self: Context, cell: Cell) ?Cell {
        return self.reader.normalize(cell);
    }

    fn readMaterial(self: Context, cell: Cell) ?engine.voxel_chunk.BlockType {
        const normalized = self.normalize(cell) orelse return null;
        if (self.virtual_edit) |edit| {
            if (@reduce(.And, normalized == Cell{ edit.block[0], edit.block[1], edit.block[2] })) return switch (edit.action) {
                .remove => .none,
                .put => |value| if (value == .country_road_adaptive) .custom else value,
            };
        }
        return self.reader.get(normalized);
    }

    fn record(self: Context, cell: Cell) ?data.Road {
        const normalized = self.normalize(cell) orelse return null;
        if (self.planned) |changes| {
            for (changes.items) |change| if (@reduce(.And, change.cell == normalized)) {
                const coords, const local = world.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
                _ = coords;
                return .{ .index = @import("block_transformations.zig").index(local), .slope = change.slope };
            };
        }
        if (self.virtual_edit) |edit| {
            if (@reduce(.And, normalized == Cell{ edit.block[0], edit.block[1], edit.block[2] })) {
                return switch (edit.action) {
                    .remove => null,
                    .put => |value| if (value == .country_road_adaptive or value == .custom) .{ .index = @import("block_transformations.zig").index(world.splitBlockCoords(edit.block)[1]) } else null,
                };
            }
        }
        const coords, const local = world.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
        const chunk = self.chunks.get(self.reader.layout.encodeChunkCoords(coords)) orelse return null;
        return chunk.metadata.road(@import("block_transformations.zig").index(local));
    }

    fn unformed(self: Context, cell: Cell) bool {
        const road = self.record(cell) orelse return false;
        return road.slope == null and self.readMaterial(cell) == .custom;
    }

    fn supported(self: Context, cell: Cell) bool {
        const below = cell - Cell{ 0, 0, 1 };
        const material = self.readMaterial(below) orelse return false;
        if (!rules.supportsRoad(material)) return false;
        if (material == .custom) return if (self.record(below)) |road| road.slope == null else false;
        return true;
    }

    fn mark(self: Context, id: u32) void {
        if (std.mem.indexOfScalar(u32, self.changed.items, id) == null)
            if (self.prepared) self.changed.appendAssumeCapacity(id) else self.changed.append(self.allocator, id) catch @panic("OOM");
    }

    fn set(self: Context, cell: Cell, slope: ?data.Slope) void {
        const normalized = self.normalize(cell) orelse return;
        if (self.reader.isImmutable(normalized)) {
            if (self.planning_failure) |failure| failure.* = error.ImmutableCell;
            return;
        }
        const coords, const local = world.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
        const id = self.reader.layout.encodeChunkCoords(coords);
        const observed = self.record(normalized) orelse return;
        if (std.meta.eql(observed.slope, slope)) return;
        if (self.planned) |changes| {
            if (self.planning_failure.?.* != null) return;
            for (changes.items) |*change| if (@reduce(.And, change.cell == normalized)) {
                change.slope = slope;
                return;
            };
            if (changes.items.len >= self.max_plan_changes) {
                self.planning_failure.?.* = error.Capacity;
                return;
            }
            changes.append(self.allocator, .{ .cell = normalized, .slope = slope }) catch |err| {
                self.planning_failure.?.* = err;
            };
            return;
        }
        const chunk = self.chunks.getPtr(id) orelse return;
        const road = chunk.metadata.roadPtr(@import("block_transformations.zig").index(local)) orelse return;
        if (self.undo) |entries| {
            const block: [3]u32 = .{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) };
            var seen = false;
            for (entries.items) |entry| if (std.meta.eql(entry.block, block)) {
                seen = true;
                break;
            };
            if (!seen) entries.append(self.allocator, .{ .block = block, .slope = road.slope }) catch @panic("OOM");
        }
        road.slope = slope;
        self.mark(id);
    }

    fn sectionCell(self: Context, slope: data.Slope, section: u32) Cell {
        const high: Cell = .{ slope.high_endpoint[0], slope.high_endpoint[1], slope.high_endpoint[2] };
        const cell = high + slope.downhill.offset() * @as(Cell, @splat(@as(i64, section) + 1));
        return self.normalize(cell) orelse cell;
    }

    fn lowEndpoint(self: Context, slope: data.Slope) Cell {
        return self.sectionCell(slope, slope.length) - Cell{ 0, 0, 1 };
    }

    fn memberLimit(self: Context, slope: data.Slope) u64 {
        // X wraps, so later laps revisit the same cells. Y is finite, so
        // later out-of-bounds sections cannot affect stored road ownership.
        const available: u64 = switch (slope.downhill) {
            .positive_x, .negative_x => self.reader.layout.size_in_blocks[0],
            .positive_y => self.reader.layout.size_in_blocks[1] - slope.high_endpoint[1] - 1,
            .negative_y => slope.high_endpoint[1],
        };
        return @min(@as(u64, slope.length), available);
    }

    fn revert(self: Context, slope: data.Slope) void {
        for (0..self.memberLimit(slope)) |i| {
            if (self.planning_failure) |failure| if (failure.* != null) return;
            const member = self.sectionCell(slope, @intCast(i));
            const road = self.record(member) orelse continue;
            const existing = road.slope orelse continue;
            if (sameRun(existing, slope)) self.set(member, null);
        }
    }

    /// Find both ends of an unclaimed straight row, without choosing ambiguous axes.
    fn candidate(self: Context, seed: Cell, axis: usize) ?data.Slope {
        if (!self.unformed(seed)) return null;
        var ends: [2]struct { cell: Cell, high: bool, count: u32 } = undefined;
        for (0..2) |side| {
            const sign: i64 = if (side == 0) -1 else 1;
            const step: Cell = if (axis == 0) .{ sign, 0, 0 } else .{ 0, sign, 0 };
            var cursor = seed;
            var count: u32 = 0;
            while (count <= maximum_length) : (count += 1) {
                cursor = self.normalize(cursor + step) orelse return null;
                const material = self.readMaterial(cursor) orelse return null;
                if (self.unformed(cursor)) continue;
                if (material == .country_road_solid) {
                    ends[side] = .{ .cell = cursor, .high = true, .count = count };
                } else if (material == .none and self.readMaterial(cursor - Cell{ 0, 0, 1 }) == .country_road_solid) {
                    ends[side] = .{ .cell = cursor - Cell{ 0, 0, 1 }, .high = false, .count = count };
                } else return null;
                break;
            } else return null;
        }
        if (ends[0].high == ends[1].high) return null;
        const n = ends[0].count + ends[1].count + 1;
        if (n < minimum_length or n > maximum_length) return null;
        const high = ends[if (ends[0].high) @as(usize, 0) else 1].cell;
        const direction: custom.Direction = if (axis == 0)
            (if (ends[0].high) .positive_x else .negative_x)
        else
            (if (ends[0].high) .positive_y else .negative_y);
        const result: data.Slope = .{ .high_endpoint = .{ @intCast(high[0]), @intCast(high[1]), @intCast(high[2]) }, .downhill = direction, .length = n, .section = 0 };
        for (0..n) |i| {
            const member = self.sectionCell(result, @intCast(i));
            if (!self.supported(member)) return null;
            // A formed section no longer supplies a full top face for a stacked road.
            const above = self.readMaterial(member + Cell{ 0, 0, 1 }) orelse return null;
            if (above.isRoad()) return null;
        }
        return result;
    }

    fn ambiguous(self: Context, slope: data.Slope) bool {
        const other_axis: usize = if (@intFromEnum(slope.downhill) < 2) 1 else 0;
        for (0..slope.length) |i| if (self.candidate(self.sectionCell(slope, @intCast(i)), other_axis) != null) return true;
        return false;
    }

    /// Replay a previously chosen orientation after rebasing. A later crossing
    /// must not make that choice ambiguous, but new authoritative ownership,
    /// missing members, unsupported cells, or changed endpoints take precedence.
    pub fn restoreFormation(self: Context, slope: data.Slope) void {
        const high: Cell = .{ slope.high_endpoint[0], slope.high_endpoint[1], slope.high_endpoint[2] };
        const low = self.lowEndpoint(slope);
        if (self.readMaterial(high) != .country_road_solid or self.readMaterial(low) != .country_road_solid or self.readMaterial(low + Cell{ 0, 0, 1 }) != .none) return;
        for (0..slope.length) |i| {
            const member = self.sectionCell(slope, @intCast(i));
            const road = self.record(member) orelse return;
            if (self.readMaterial(member) != .custom or !self.supported(member)) return;
            const above = self.readMaterial(member + Cell{ 0, 0, 1 }) orelse return;
            if (above.isRoad()) return;
            if (road.slope) |existing| if (!sameRun(existing, slope)) return;
        }
        for (0..slope.length) |i| {
            var section = slope;
            section.section = @intCast(i);
            self.set(self.sectionCell(slope, @intCast(i)), section);
        }
    }

    /// previous preserves a removed section's ownership after its cell becomes air.
    pub fn afterEdit(self: Context, operation: world.BlockOperation, previous: ?data.Road) void {
        const target: Cell = .{ operation.block[0], operation.block[1], operation.block[2] };
        if (operation.action == .remove) {
            if (previous) |road| if (road.slope) |slope| self.revert(slope);
            for (std.enums.values(custom.Direction)) |direction| {
                for (0..2) |level| {
                    const neighbor = target + direction.offset() + Cell{ 0, 0, @intCast(level) };
                    const road = self.record(neighbor) orelse continue;
                    const slope = road.slope orelse continue;
                    const high: Cell = .{ slope.high_endpoint[0], slope.high_endpoint[1], slope.high_endpoint[2] };
                    if (@reduce(.And, target == high) or @reduce(.And, target == self.lowEndpoint(slope))) self.revert(slope);
                }
            }
            return;
        }
        var candidate_storage: [20]data.Slope = undefined;
        var candidate_count: usize = 0;
        for (0..2) |level| {
            for (0..5) |neighbor| {
                const seed = target + Cell{ 0, 0, @intCast(level) } + (if (neighbor == 4) @as(Cell, @splat(0)) else @as(custom.Direction, @enumFromInt(neighbor)).offset());
                for (0..2) |axis| {
                    const slope = self.candidate(seed, axis) orelse continue;
                    var seen = false;
                    for (candidate_storage[0..candidate_count]) |existing| if (sameRun(existing, slope)) {
                        seen = true;
                        break;
                    };
                    if (!seen) {
                        candidate_storage[candidate_count] = slope;
                        candidate_count += 1;
                    }
                }
            }
        }
        // Resolve all ambiguity before mutating anything; loop order cannot select a winner.
        var allowed_storage: [20]data.Slope = undefined;
        var allowed_count: usize = 0;
        for (candidate_storage[0..candidate_count]) |slope| if (!self.ambiguous(slope)) {
            allowed_storage[allowed_count] = slope;
            allowed_count += 1;
        };
        for (allowed_storage[0..allowed_count]) |slope| {
            for (0..slope.length) |i| {
                var section = slope;
                section.section = @intCast(i);
                self.set(self.sectionCell(slope, @intCast(i)), section);
            }
            if (self.formed) |entries| {
                var seen = false;
                for (entries.items) |existing| if (sameRun(existing, slope)) {
                    seen = true;
                    break;
                };
                if (!seen) entries.append(self.allocator, slope) catch @panic("OOM");
            }
        }
    }
};

fn sameRun(a: data.Slope, b: data.Slope) bool {
    return std.meta.eql(a.high_endpoint, b.high_endpoint) and a.downhill == b.downhill and a.length == b.length;
}

test {
    _ = @import("road_tests.zig");
}
