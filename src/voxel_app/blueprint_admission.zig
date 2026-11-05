//! Detached destination admission. Snapshot acquisition and dependency rechecks
//! belong to the service; this helper holds no live world or generator pointers.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const runtime = @import("blueprint_runtime.zig");
const rules = @import("block_rules.zig");
const consts = @import("consts.zig");
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;
const Road = @import("road_data.zig").Road;
const transforms = @import("block_transformations.zig");
pub const ChunkId = consts.ChunkId;
pub const Cell = runtime.Cell;
pub const default_max_snapshot_bytes: usize = 128 * 1024 * 1024;

/// Apply this before cloning the next source chunk. Slice clones allocate from
/// their lengths; the index bound includes its retained hash/list capacities.
pub fn estimatedChunkBytes(constructed_len: usize, road_len: usize, immutable_len: usize, index: runtime.ChunkIndex) usize {
    return @sizeOf(WorldChunkData) +|
        constructed_len *| @sizeOf(transforms.BlockIndex) +|
        road_len *| @sizeOf(Road) +|
        immutable_len *| @sizeOf(transforms.BlockIndex) +|
        index.estimatedOwnedBytes();
}
pub const ChunkSnapshot = struct {
    revision: u64,
    blocks: *WorldChunkData,
    constructed: []const transforms.BlockIndex = &.{},
    roads: []const Road = &.{},
    /// Sorted canonical floor indices captured from the source generator,
    /// independently of corrupted or hypothetical physical block contents.
    immutable: []const transforms.BlockIndex = &.{},
    index: runtime.ChunkIndex = .{},

    pub fn deinit(self: *ChunkSnapshot, allocator: std.mem.Allocator) void {
        allocator.destroy(self.blocks);
        allocator.free(self.constructed);
        allocator.free(self.roads);
        allocator.free(self.immutable);
        self.index.deinit(allocator);
        self.* = undefined;
    }

    pub fn estimatedOwnedBytes(self: ChunkSnapshot) usize {
        return estimatedChunkBytes(self.constructed.len, self.roads.len, self.immutable.len, self.index);
    }
};

pub const Snapshot = struct {
    layout: engine.WorldLayout,
    chunks: std.AutoHashMapUnmanaged(ChunkId, ChunkSnapshot) = .empty,
    overlay_revision: u64,
    playable_y_inset: u32 = 0,

    pub fn estimatedOwnedBytes(self: *const Snapshot) usize {
        var result = @as(usize, self.chunks.capacity()) *| (@sizeOf(ChunkId) + @sizeOf(ChunkSnapshot) + 1) +| 64;
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| result +|= chunk.estimatedOwnedBytes();
        return result;
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| chunk.deinit(allocator);
        self.chunks.deinit(allocator);
        self.* = undefined;
    }
};

pub const Options = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    max_snapshot_chunks: usize = 1024,
    max_snapshot_bytes: usize = default_max_snapshot_bytes,
    cache_entries: usize = 8192,

    fn cancelled(self: Options) bool {
        return if (self.cancel) |token| token.load(.acquire) else false;
    }
};

pub const RejectCode = @import("blueprint_result.zig").RejectCode;
pub const Rejection = @import("blueprint_result.zig").Rejection;
pub const Prepared = struct {
    publication: runtime.PreparedPublication,
    foundation_reads: usize = 0,
    validated_targets: usize = 0,
    validated_dependents: usize = 0,

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        self.publication.deinit(allocator);
        self.* = undefined;
    }
};
pub const Result = union(enum) { prepared: Prepared, rejected: Rejection, cancelled: void };

fn chunkId(layout: *const engine.WorldLayout, cell: Cell) ChunkId {
    return layout.encodeChunkCoords(.{ @intCast(cell[0] / consts.CHUNK_SIZE), @intCast(cell[1] / consts.CHUNK_SIZE), @intCast(cell[2] / consts.CHUNK_SIZE) });
}

fn localIndex(cell: Cell) transforms.BlockIndex {
    return transforms.index(.{ @truncate(cell[0]), @truncate(cell[1]), @truncate(cell[2]) });
}

fn globalCell(layout: *const engine.WorldLayout, id: ChunkId, local: transforms.BlockIndex) Cell {
    const chunk = layout.decodeChunkId(id);
    const offset = transforms.coordinates(local);
    return .{
        @as(u32, @intCast(chunk[0])) * consts.CHUNK_SIZE + offset[0],
        @as(u32, @intCast(chunk[1])) * consts.CHUNK_SIZE + offset[1],
        @as(u32, @intCast(chunk[2])) * consts.CHUNK_SIZE + offset[2],
    };
}

const View = struct {
    snapshot: *const Snapshot,
    publication: ?*const runtime.PreparedPublication = null,

    fn reader(self: *View) rules.Reader {
        return .{ .layout = &self.snapshot.layout, .context = self, .block_at = read, .custom_shape_at = shape, .immutable_at = immutable, .playable_y_inset = self.snapshot.playable_y_inset };
    }

    fn target(self: *const View, cell: Cell) ?runtime.Target {
        const id = chunkId(&self.snapshot.layout, cell);
        if (self.publication) |publication| if (publication.chunks.get(id)) |index| return index.lookup.get(cell);
        const chunk = self.snapshot.chunks.get(id) orelse return null;
        return chunk.index.lookup.get(cell);
    }

    fn read(context: *anyopaque, cell: Cell) ?rules.BlockType {
        const self: *View = @ptrCast(@alignCast(context));
        const chunk = self.snapshot.chunks.get(chunkId(&self.snapshot.layout, cell)) orelse return null;
        if (self.publication != null) if (self.target(cell)) |planned| return planned.material;
        return chunk.blocks.blocks[cell[2] % 32][cell[1] % 32][cell[0] % 32];
    }

    fn shape(context: *anyopaque, cell: Cell) ?engine.voxel_chunk.custom_block.Shape {
        const self: *View = @ptrCast(@alignCast(context));
        const chunk = self.snapshot.chunks.get(chunkId(&self.snapshot.layout, cell)) orelse return null;
        const local = localIndex(cell);
        for (chunk.roads) |road| if (road.index == local) return road.shape();
        return null;
    }

    fn immutable(context: *anyopaque, cell: Cell) bool {
        const self: *View = @ptrCast(@alignCast(context));
        const chunk = self.snapshot.chunks.get(chunkId(&self.snapshot.layout, cell)) orelse return false;
        const target_index = localIndex(cell);
        var low: usize = 0;
        var high: usize = chunk.immutable.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const index = chunk.immutable[middle];
            if (index < target_index) low = middle + 1 else if (index > target_index) high = middle else return true;
        }
        return false;
    }
};

fn affected(layout: *const engine.WorldLayout, origin: Cell, size: blueprint.Size, cell: Cell) bool {
    const radius = rules.Limits.support_radius;
    const dx = (@as(u64, cell[0]) + layout.size_in_blocks[0] - origin[0]) % layout.size_in_blocks[0];
    if (dx > @as(u64, size[0]) - 1 + radius and dx + radius < layout.size_in_blocks[0]) return false;
    inline for (1..3) |axis| {
        if (@as(i64, cell[axis]) < @as(i64, origin[axis]) - radius or
            @as(u64, cell[axis]) > @as(u64, origin[axis]) + size[axis] - 1 + radius) return false;
    }
    return true;
}

/// The caller retains snapshot, definition, and instance. A successful result
/// owns an independent cloned instance and all publication resources.
pub fn prepare(allocator: std.mem.Allocator, snapshot: *const Snapshot, definition: blueprint.Definition, instance: runtime.Instance, options: Options) !Result {
    if (options.cancelled()) return .cancelled;
    if (snapshot.chunks.count() > options.max_snapshot_chunks or snapshot.estimatedOwnedBytes() > options.max_snapshot_bytes) return .{ .rejected = .{ .code = .budget_exceeded } };
    definition.validateWellFormed(blueprint.horizontalLimit(&snapshot.layout), blueprint.default_max_cells) catch return .{ .rejected = .{ .code = .invalid_definition } };
    if (instance.id == 0 or !instance.active or instance.remaining != definition.target_count or instance.fulfilled.len != (definition.cells.len + 7) / 8)
        return .{ .rejected = .{ .code = .invalid_definition } };
    for (instance.fulfilled) |bits| if (bits != 0) return .{ .rejected = .{ .code = .invalid_definition } };
    if (!runtime.validFootprint(&snapshot.layout, instance.origin, definition.size, instance.rotation)) return .{ .rejected = .{ .code = .bounds } };
    const size = blueprint.rotatedSize(definition.size, instance.rotation);
    if (instance.origin[1] < snapshot.playable_y_inset or @as(u64, instance.origin[1]) + size[1] > snapshot.layout.size_in_blocks[1] - snapshot.playable_y_inset)
        return .{ .rejected = .{ .code = .bounds } };
    var source: std.AutoHashMapUnmanaged(ChunkId, runtime.ChunkIndex) = .empty;
    defer source.deinit(allocator); // borrowed chunk values
    var source_chunks = snapshot.chunks.iterator();
    while (source_chunks.next()) |chunk| try source.put(allocator, chunk.key_ptr.*, chunk.value_ptr.index);
    var view: View = .{ .snapshot = snapshot };
    const physical = view.reader();
    // Target checks remain physical. Correct existing materials do not count
    // as fulfillment, and canonical immutable air cannot be overwritten.
    for (definition.cells, 0..) |material, index| {
        if (index & 255 == 0 and options.cancelled()) return .cancelled;
        if (material == .none) continue;
        const cell = runtime.worldCell(&snapshot.layout, instance.origin, definition.size, instance.rotation, blueprint.cellAtIndex(definition.size, index)).?;
        const block = physical.get(.{ cell[0], cell[1], cell[2] }) orelse return .{ .rejected = .{ .code = .missing_data, .cell = cell } };
        if (block != .none) return .{ .rejected = .{ .code = .occupied, .cell = cell } };
        if (physical.isImmutable(.{ cell[0], cell[1], cell[2] })) return .{ .rejected = .{ .code = .immutable, .cell = cell } };
        if (view.target(cell) != null) return .{ .rejected = .{ .code = .overlap, .cell = cell } };
    }
    // Query the deduplicated bottom platform union: a one-cell XY dilation,
    // followed by three real Z reads per resulting coordinate.
    var platform_xy: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    defer platform_xy.deinit(allocator);
    for (definition.cells[0 .. @as(usize, definition.size[0]) * definition.size[1]], 0..) |material, index| {
        if (material == .none) continue;
        const root = runtime.worldCell(&snapshot.layout, instance.origin, definition.size, instance.rotation, blueprint.cellAtIndex(definition.size, index)).?;
        if (root[2] < 3) return .{ .rejected = .{ .code = .foundation, .cell = root } };
        for (0..3) |y| for (0..3) |x| {
            const position = rules.Cell{ root[0], root[1], root[2] } + rules.Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -1 };
            const normalized = physical.normalize(position) orelse return .{ .rejected = .{ .code = .foundation, .cell = root } };
            try platform_xy.put(allocator, .{ @intCast(normalized[0]), @intCast(normalized[1]) }, {});
        };
    }
    var foundation_reads: usize = 0;
    var coordinates = platform_xy.keyIterator();
    while (coordinates.next()) |xy| {
        if (foundation_reads & 255 == 0 and options.cancelled()) return .cancelled;
        for (1..4) |depth| {
            const cell: Cell = .{ xy[0], xy[1], instance.origin[2] - @as(u32, @intCast(depth)) };
            const material = physical.get(.{ cell[0], cell[1], cell[2] }) orelse return .{ .rejected = .{ .code = .missing_data, .cell = cell } };
            foundation_reads += 1;
            if (!material.isStablePlatformMaterial()) return .{ .rejected = .{ .code = .foundation, .cell = cell } };
        }
    }
    var owned_instance = try instance.clone(allocator);
    var publication = runtime.buildPublication(allocator, &snapshot.layout, definition, owned_instance, &source, null) catch |err| {
        owned_instance.deinit(allocator);
        return err;
    };
    var own_publication = true;
    defer if (own_publication) publication.deinit(allocator);
    view.publication = &publication;
    var validator: rules.Validator = .{ .allocator = allocator, .reader = view.reader(), .cache_limit = options.cache_entries, .cancel = options.cancel };
    defer validator.deinit();
    var targets: usize = 0;
    for (definition.cells, 0..) |material, index| {
        if (index & 255 == 0 and options.cancelled()) return .cancelled;
        if (material == .none) continue;
        const cell = runtime.worldCell(&snapshot.layout, instance.origin, definition.size, instance.rotation, blueprint.cellAtIndex(definition.size, index)).?;
        const failed = validator.checkExisting(.{ cell[0], cell[1], cell[2] });
        if (options.cancelled()) return .cancelled;
        if (validator.allocation_failed) return error.OutOfMemory;
        if (failed) |failure| return .{ .rejected = .{ .code = .composition, .cell = cell, .failure = failure } };
        targets += 1;
    }
    var dependents: usize = 0;
    var chunks = snapshot.chunks.iterator();
    while (chunks.next()) |chunk| {
        for (chunk.value_ptr.constructed) |local| {
            const cell = globalCell(&snapshot.layout, chunk.key_ptr.*, local);
            if (!affected(&snapshot.layout, instance.origin, size, cell)) continue;
            if (view.target(cell)) |target| if (target.instance_id == instance.id) continue;
            const failed = validator.checkExisting(.{ cell[0], cell[1], cell[2] });
            if (options.cancelled()) return .cancelled;
            if (validator.allocation_failed) return error.OutOfMemory;
            if (failed) |failure| return .{ .rejected = .{ .code = .composition, .cell = cell, .failure = failure } };
            dependents += 1;
        }
        for (chunk.value_ptr.index.targets.items) |cell| {
            if (!affected(&snapshot.layout, instance.origin, size, cell)) continue;
            const failed = validator.checkExisting(.{ cell[0], cell[1], cell[2] });
            if (options.cancelled()) return .cancelled;
            if (validator.allocation_failed) return error.OutOfMemory;
            if (failed) |failure| return .{ .rejected = .{ .code = .composition, .cell = cell, .failure = failure } };
            dependents += 1;
        }
    }
    own_publication = false;
    return .{ .prepared = .{ .publication = publication, .foundation_reads = foundation_reads, .validated_targets = targets, .validated_dependents = dependents } };
}

const Fixture = struct {
    snapshot: Snapshot,
    state: runtime.State,

    fn init() !Fixture {
        const allocator = std.testing.allocator;
        const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
        var result: Fixture = .{ .snapshot = .{ .layout = layout, .overlay_revision = 0 }, .state = .{} };
        errdefer result.deinit();
        for (0..2) |z| for (0..2) |y| for (0..2) |x| {
            const blocks = try allocator.create(WorldChunkData);
            blocks.* = WorldChunkData.initEmpty();
            if (z == 0) for (0..4) |level| @memset(std.mem.asBytes(&blocks.blocks[level]), @intFromEnum(rules.BlockType.stone));
            const id = layout.encodeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) });
            try result.snapshot.chunks.put(allocator, id, .{ .revision = 1, .blocks = blocks });
        };
        return result;
    }

    fn deinit(self: *Fixture) void {
        self.snapshot.deinit(std.testing.allocator);
        self.state.deinit(std.testing.allocator);
    }

    fn put(self: *Fixture, cell: Cell, material: rules.BlockType, constructed: bool) !void {
        const chunk = self.snapshot.chunks.getPtr(chunkId(&self.snapshot.layout, cell)).?;
        chunk.blocks.blocks[cell[2] % 32][cell[1] % 32][cell[0] % 32] = material;
        if (constructed) {
            const old = chunk.constructed;
            const next = try std.testing.allocator.alloc(transforms.BlockIndex, old.len + 1);
            @memcpy(next[0..old.len], old);
            next[old.len] = localIndex(cell);
            std.testing.allocator.free(old);
            chunk.constructed = next;
        }
    }

    fn definition(self: *Fixture, size: blueprint.Size, cells: []const rules.BlockType) !blueprint.Definition {
        const compiled = try blueprint.compile(std.testing.allocator, .{ .size = size, .cells = cells }, .{ .horizontal_limit = blueprint.horizontalLimit(&self.snapshot.layout) });
        if (compiled != .valid) return error.InvalidFixture;
        const value = compiled.valid.definition;
        try self.state.insertDefinition(std.testing.allocator, .{ .id = self.state.max_definition_id + 1, .owner = 1, .name = try std.testing.allocator.dupe(u8, "fixture"), .definition = value });
        return value;
    }

    fn instance(self: *Fixture, origin: Cell) !runtime.Instance {
        return self.state.prepareInstance(std.testing.allocator, &self.snapshot.layout, self.state.max_instance_id + 1, self.state.max_definition_id, 1, origin, 0);
    }
};

test "canonical immutable lookup finds sorted floor indices at either edge and between gaps" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const chunk = fixture.snapshot.chunks.getPtr(chunkId(&fixture.snapshot.layout, .{ 0, 0, 0 })).?;
    chunk.immutable = try std.testing.allocator.dupe(transforms.BlockIndex, &.{ 0, 5, 17, 32767 });
    var view: View = .{ .snapshot = &fixture.snapshot };
    const reader = view.reader();
    for ([_]transforms.BlockIndex{ 0, 5, 17, 32767 }) |index| {
        const cell = transforms.coordinates(index);
        try std.testing.expect(reader.isImmutable(.{ cell[0], cell[1], cell[2] }));
    }
    for ([_]transforms.BlockIndex{ 1, 4, 6, 16, 18, 32766 }) |index| {
        const cell = transforms.coordinates(index);
        try std.testing.expect(!reader.isImmutable(.{ cell[0], cell[1], cell[2] }));
    }
}

test "detached admission prebuilds chunk publication and completion stays constant work" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 2, 1, 1 }, &.{ .rebar, .rebar });
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    var result = try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expect(result == .prepared);
    defer result.prepared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 36), result.prepared.foundation_reads);
    try std.testing.expectEqual(@as(usize, 2), result.prepared.validated_targets);
    try fixture.state.reservePublication(std.testing.allocator, &fixture.snapshot.layout, &result.prepared.publication);
    fixture.state.publishPublication(&result.prepared.publication);
    try std.testing.expect(fixture.state.targetAt(.{ 10, 10, 4 }) != null);
    try std.testing.expect(fixture.state.fulfill(&fixture.snapshot.layout, .{ .instance_id = instance.id, .cell_index = 0 }));
    try std.testing.expect(fixture.state.targetAt(.{ 10, 10, 4 }) == null);
    try std.testing.expect(fixture.state.targetAt(.{ 11, 10, 4 }) != null);
    try std.testing.expect(fixture.state.fulfill(&fixture.snapshot.layout, .{ .instance_id = instance.id, .cell_index = 1 }));
    try std.testing.expect(fixture.state.boxAt(&fixture.snapshot.layout, .{ 10, 10, 4 }) == null);
    fixture.state.cleanup(std.testing.allocator, 1);
}

test "destination admission rejects occupied targets and incomplete physical platforms" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 1, 1, 1 }, &.{.planks});
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    try fixture.put(.{ 10, 10, 4 }, .planks, false);
    try std.testing.expectEqual(RejectCode.occupied, (try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
    try fixture.put(.{ 10, 10, 4 }, .none, false);
    try fixture.put(.{ 9, 9, 1 }, .none, false);
    try std.testing.expectEqual(RejectCode.foundation, (try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
}

test "composed admission discovers water and snow above a proposed sand target" {
    for ([_]rules.BlockType{ .water, .snow }) |material| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const definition = try fixture.definition(.{ 1, 1, 1 }, &.{.sand});
        var instance = try fixture.instance(.{ 10, 10, 4 });
        defer instance.deinit(std.testing.allocator);
        try fixture.put(.{ 10, 10, 5 }, material, true);
        const result = try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
        try std.testing.expectEqual(RejectCode.composition, result.rejected.code);
        try std.testing.expectEqual(rules.Reason.incompatible_support, result.rejected.failure.?.reason);
        try std.testing.expectEqualDeep(@as(?Cell, .{ 10, 10, 5 }), result.rejected.cell);
    }
}

test "composed admission rejects a seventh crushed bridge cell above a six-cell blueprint" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 1, 1, 6 }, &([_]rules.BlockType{.crushed_stone} ** 6));
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    try fixture.put(.{ 10, 10, 10 }, .crushed_stone, true);
    for ([_]u32{ 9, 11 }) |x| {
        try fixture.put(.{ x, 10, 9 }, .stone, false);
        try fixture.put(.{ x, 10, 10 }, .stone, false);
    }
    const result = try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expectEqual(RejectCode.composition, result.rejected.code);
    try std.testing.expectEqual(rules.Reason.crushed_column, result.rejected.failure.?.reason);
    try std.testing.expectEqualDeep(@as(?Cell, .{ 10, 10, 10 }), result.rejected.cell);
}

test "admission detects missing dependencies finite bounds cancellation and snapshot budget" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 1, 1, 1 }, &.{.planks});
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    try std.testing.expectEqual(RejectCode.budget_exceeded, (try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{ .max_snapshot_chunks = 1 })).rejected.code);
    var token = std.atomic.Value(bool).init(true);
    try std.testing.expect((try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{ .cancel = &token })) == .cancelled);
    fixture.snapshot.playable_y_inset = 11;
    try std.testing.expectEqual(RejectCode.bounds, (try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
    fixture.snapshot.playable_y_inset = 0;
    var removed = fixture.snapshot.chunks.fetchRemove(chunkId(&fixture.snapshot.layout, instance.origin)).?.value;
    removed.deinit(std.testing.allocator);
    try std.testing.expectEqual(RejectCode.missing_data, (try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
}

test "harmless cavity earth preserves an independent lateral plank route" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 3, 1, 2 }, &.{ .rebar, .none, .rebar, .planks, .planks, .planks });
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    try fixture.put(.{ 11, 10, 4 }, .dirt, true);
    var result = try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expect(result == .prepared);
    defer result.prepared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.prepared.validated_dependents);
    try std.testing.expectEqual(rules.BlockType.dirt, fixture.snapshot.chunks.get(chunkId(&fixture.snapshot.layout, .{ 11, 10, 4 })).?.blocks.blocks[4][10][11]);
}

test "pending targets of another site participate as completed dependents" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 1, 1, 6 }, &([_]rules.BlockType{.crushed_stone} ** 6));
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    const cell: Cell = .{ 10, 10, 10 };
    const index = &fixture.snapshot.chunks.getPtr(chunkId(&fixture.snapshot.layout, cell)).?.index;
    try index.targets.append(std.testing.allocator, cell);
    try index.lookup.put(std.testing.allocator, cell, .{ .instance_id = 99, .cell_index = 0, .material = .crushed_stone });
    for ([_]u32{ 9, 11 }) |x| {
        try fixture.put(.{ x, 10, 9 }, .stone, false);
        try fixture.put(.{ x, 10, 10 }, .stone, false);
    }
    const result = try prepare(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expectEqual(RejectCode.composition, result.rejected.code);
    try std.testing.expectEqual(rules.Reason.crushed_column, result.rejected.failure.?.reason);
    try std.testing.expectEqualDeep(@as(?Cell, cell), result.rejected.cell);
}

fn allocationFixture(allocator: std.mem.Allocator, fixture: *const Fixture, definition: blueprint.Definition, instance: runtime.Instance) !void {
    var result = try prepare(allocator, &fixture.snapshot, definition, instance, .{});
    if (result != .prepared) return error.TestUnexpectedResult;
    defer result.prepared.deinit(allocator);
}

test "all detached admission allocation failures preserve snapshot and free publication state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 2, 1, 1 }, &.{ .rebar, .rebar });
    var instance = try fixture.instance(.{ 31, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{ &fixture, definition, instance });
    try std.testing.expectEqual(@as(usize, 0), fixture.state.instances.count());
    try std.testing.expect(fixture.state.targetAt(instance.origin) == null);
}
