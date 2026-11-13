//! Detached destination admission. Snapshot acquisition and dependency rechecks
//! belong to the service; this helper holds no live world or generator pointers.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const runtime = @import("blueprint_runtime.zig");
const rules = @import("block_rules.zig");
const consts = @import("consts.zig");
const WorldChunkData = @import("world_chunk_data.zig").WorldChunkData;
const transforms = @import("block_transformations.zig");
pub const ChunkId = consts.ChunkId;
pub const Cell = runtime.Cell;
pub const default_max_snapshot_bytes: usize = 128 * 1024 * 1024;

test {
    _ = @import("blueprint_soil.zig");
}

/// Apply this before cloning the next source chunk. Slice clones allocate from
/// their lengths; the index bound includes its retained hash/list capacities.
pub fn estimatedChunkBytes(immutable_len: usize, index: runtime.ChunkIndex) usize {
    return @sizeOf(WorldChunkData) +|
        immutable_len *| @sizeOf(transforms.BlockIndex) +|
        index.estimatedOwnedBytes();
}
pub const ChunkSnapshot = struct {
    revision: u64,
    blocks: *WorldChunkData,
    /// Sorted canonical floor indices captured from the source generator,
    /// independently of corrupted or hypothetical physical block contents.
    immutable: []const transforms.BlockIndex = &.{},
    index: runtime.ChunkIndex = .{},
    /// Exact pending grass-growth membership captured with this chunk revision.
    /// Compaction events remain distinct and never enter this coverage mask.
    grow_grass: std.StaticBitSet(32768) = .initEmpty(),

    pub fn deinit(self: *ChunkSnapshot, allocator: std.mem.Allocator) void {
        allocator.destroy(self.blocks);
        allocator.free(self.immutable);
        self.index.deinit(allocator);
        self.* = undefined;
    }

    pub fn estimatedOwnedBytes(self: ChunkSnapshot) usize {
        return estimatedChunkBytes(self.immutable.len, self.index);
    }
};

pub const Snapshot = struct {
    layout: engine.WorldLayout,
    chunks: std.AutoHashMapUnmanaged(ChunkId, ChunkSnapshot) = .empty,
    overlay_revision: u64,
    playable_y_inset: u32 = 0,

    /// Canonical protection is independent of the captured physical material.
    pub fn isImmutable(self: *const Snapshot, cell: Cell) bool {
        const chunk = self.chunks.getPtr(chunkId(&self.layout, cell)) orelse return false;
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

    fn cancelled(self: Options) bool {
        return if (self.cancel) |token| token.load(.acquire) else false;
    }
};

pub const RejectCode = @import("blueprint_result.zig").RejectCode;
pub const Rejection = @import("blueprint_result.zig").Rejection;
pub const Prepared = struct {
    publication: runtime.PreparedPublication,
    foundation_reads: usize = 0,
    /// Structural target checks are certified at compile time, never repeated here.
    validated_targets: usize = 0,
    /// Pure additions preserve existing support witnesses without rechecking them.
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

const View = struct {
    snapshot: *const Snapshot,
    publication: ?*const runtime.PreparedPublication = null,

    fn reader(self: *View) rules.Reader {
        return .{ .layout = &self.snapshot.layout, .context = self, .block_at = read, .immutable_at = immutable, .playable_y_inset = self.snapshot.playable_y_inset };
    }

    fn target(self: *const View, cell: Cell) ?runtime.Target {
        const id = chunkId(&self.snapshot.layout, cell);
        if (self.publication) |publication| if (publication.chunks.get(id)) |index| return index.lookup.get(cell);
        const chunk = self.snapshot.chunks.getPtr(id) orelse return null;
        return chunk.index.lookup.get(cell);
    }

    fn read(context: *anyopaque, cell: Cell) ?rules.BlockType {
        const self: *View = @ptrCast(@alignCast(context));
        const chunk = self.snapshot.chunks.getPtr(chunkId(&self.snapshot.layout, cell)) orelse return null;
        if (self.publication != null) if (self.target(cell)) |planned| return planned.material;
        return chunk.blocks.blocks[cell[2] % 32][cell[1] % 32][cell[0] % 32];
    }

    fn immutable(context: *anyopaque, cell: Cell) bool {
        const self: *View = @ptrCast(@alignCast(context));
        return self.snapshot.isImmutable(cell);
    }
};

/// Requires immutable contents certified by blueprint.compile under the current
/// rules. Definition remains the owned serialization type; well-formedness alone
/// does not establish this trusted-input contract. The caller retains snapshot,
/// definition, and instance. Success owns a cloned instance and publication data.
pub fn prepareCertified(allocator: std.mem.Allocator, snapshot: *const Snapshot, definition: blueprint.Definition, instance: runtime.Instance, options: Options) !Result {
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
    // Publication swaps complete footprint indexes, including target-free cavity
    // chunks. Missing sources must never silently become empty replacement indexes.
    for (instance.box_chunks) |id| if (!snapshot.chunks.contains(id)) return .{ .rejected = .{ .code = .missing_data } };
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
        if (root[2] < rules.Platform.depth) return .{ .rejected = .{ .code = .foundation, .cell = root } };
        for (0..rules.Platform.width) |y| for (0..rules.Platform.width) |x| {
            const position = rules.Cell{ root[0], root[1], root[2] } + rules.Cell{ @as(i64, @intCast(x)) - rules.Platform.xy_radius, @as(i64, @intCast(y)) - rules.Platform.xy_radius, -1 };
            const normalized = physical.normalize(position) orelse return .{ .rejected = .{ .code = .foundation, .cell = root } };
            try platform_xy.put(allocator, .{ @intCast(normalized[0]), @intCast(normalized[1]) }, {});
        };
    }
    var foundation_reads: usize = 0;
    var coordinates = platform_xy.keyIterator();
    while (coordinates.next()) |xy| {
        if (foundation_reads & 255 == 0 and options.cancelled()) return .cancelled;
        for (1..rules.Platform.depth + 1) |depth| {
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
    if (options.cancelled()) {
        publication.deinit(allocator);
        return .cancelled;
    }
    // The full real platforms replace the compiler's virtual platform witnesses
    // within the same fixed windows. Rotation/translation preserve those proofs;
    // additions in real terrain and other sites retain them by monotonicity.
    return .{ .prepared = .{ .publication = publication, .foundation_reads = foundation_reads } };
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

    fn put(self: *Fixture, cell: Cell, material: rules.BlockType) !void {
        const chunk = self.snapshot.chunks.getPtr(chunkId(&self.snapshot.layout, cell)).?;
        chunk.blocks.blocks[cell[2] % 32][cell[1] % 32][cell[0] % 32] = material;
    }

    fn existing(self: *Fixture, cell: Cell, material: rules.BlockType, planned: bool) !void {
        if (!planned) return self.put(cell, material);
        const index = &self.snapshot.chunks.getPtr(chunkId(&self.snapshot.layout, cell)).?.index;
        try index.targets.append(std.testing.allocator, cell);
        try index.lookup.put(std.testing.allocator, cell, .{ .instance_id = 99, .cell_index = @intCast(index.targets.items.len - 1), .material = material, .chunk_slot = index.targets.items.len - 1 });
    }

    /// Independently evaluate the old roots in their own support windows, before
    /// and after adding the entire batch. Never use this as admission evidence.
    fn expectValidRoots(self: *Fixture, roots: []const Cell, publication: ?*const runtime.PreparedPublication) !void {
        const existing_overlay: runtime.PreparedPublication = .{ .instance = undefined };
        var view: View = .{ .snapshot = &self.snapshot, .publication = publication orelse &existing_overlay };
        var shared: rules.Validator = .{ .allocator = std.testing.allocator, .reader = view.reader() };
        defer shared.deinit();
        for (roots) |cell| {
            var fresh: rules.Validator = .{ .allocator = std.testing.allocator, .reader = view.reader() };
            defer fresh.deinit();
            for ([_]*rules.Validator{ &fresh, &shared }) |validator| {
                if (validator.checkExisting(.{ cell[0], cell[1], cell[2] })) |failure| {
                    std.debug.print("existing root {any} failed with {s}\n", .{ cell, @tagName(failure.reason) });
                    return error.TestUnexpectedResult;
                }
            }
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
    var result = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expect(result == .prepared);
    defer result.prepared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 36), result.prepared.foundation_reads);
    try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
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
    try fixture.put(.{ 10, 10, 4 }, .planks);
    try std.testing.expectEqual(RejectCode.occupied, (try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
    try fixture.put(.{ 10, 10, 4 }, .none);
    try fixture.put(.{ 9, 9, 1 }, .none);
    try std.testing.expectEqual(RejectCode.foundation, (try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
}

test "destination platform rejects loose soil and accepts its compacted replacement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 1, 1, 1 }, &.{.planks});
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    // One off-center loose cell is enough to break the full platform witness.
    const cell: Cell = .{ 9, 9, 1 };
    try fixture.put(cell, .dirt);
    const rejected = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expectEqual(RejectCode.foundation, rejected.rejected.code);
    try std.testing.expectEqual(cell, rejected.rejected.cell.?);
    try fixture.put(cell, .packed_dirt);
    var accepted = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expect(accepted == .prepared);
    defer accepted.prepared.deinit(std.testing.allocator);
}

test "composed admission preserves water and snow above a proposed sand target" {
    for ([_]rules.BlockType{ .water, .snow }) |material| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const definition = try fixture.definition(.{ 1, 1, 1 }, &.{.sand});
        var instance = try fixture.instance(.{ 10, 10, 4 });
        defer instance.deinit(std.testing.allocator);
        try fixture.put(.{ 10, 10, 5 }, material);
        var result = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
        try std.testing.expect(result == .prepared);
        defer result.prepared.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
        try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_dependents);
        const blocks = fixture.snapshot.chunks.get(chunkId(&fixture.snapshot.layout, .{ 10, 10, 5 })).?.blocks;
        try std.testing.expectEqual(material, blocks.blocks[5][10][10]);
        try std.testing.expectEqual(rules.BlockType.none, blocks.blocks[4][10][10]);
    }
}

test "finite batches preserve real and planned crushed bridge prefixes in both orientations" {
    for ([_]bool{ false, true }) |planned| {
        for (0..2) |axis| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            const definition = try fixture.definition(.{ 1, 1, 6 }, &([_]rules.BlockType{.crushed_stone} ** 6));
            var instance = try fixture.instance(.{ 10, 10, 4 });
            defer instance.deinit(std.testing.allocator);
            var roots: [6]Cell = undefined;
            for (&roots, 0..) |*cell, level| {
                cell.* = .{ 10, 10, 10 + @as(u32, @intCast(level)) };
                try fixture.existing(cell.*, .crushed_stone, planned);
            }
            for ([_]u32{ 9, 11 }) |side| {
                var support: Cell = .{ 10, 10, 9 };
                support[axis] = side;
                try fixture.put(support, .stone);
                support[2] += 1;
                try fixture.put(support, .stone);
            }
            try fixture.expectValidRoots(&roots, null);
            var result = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
            try std.testing.expect(result == .prepared);
            defer result.prepared.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_dependents);
            try fixture.expectValidRoots(&roots, &result.prepared.publication);
            for (4..10) |z| try std.testing.expectEqual(rules.BlockType.none, fixture.snapshot.chunks.get(chunkId(&fixture.snapshot.layout, instance.origin)).?.blocks.blocks[z][10][10]);
            if (planned) {
                const index = fixture.snapshot.chunks.get(chunkId(&fixture.snapshot.layout, roots[0])).?.index;
                try std.testing.expectEqual(@as(usize, 6), index.targets.items.len);
                for (roots) |cell| try std.testing.expectEqual(@as(u64, 99), index.lookup.get(cell).?.instance_id);
            }
        }
    }
}

test "admission detects missing dependencies finite bounds cancellation and snapshot budget" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 1, 1, 1 }, &.{.planks});
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    try std.testing.expectEqual(RejectCode.budget_exceeded, (try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{ .max_snapshot_chunks = 1 })).rejected.code);
    var token = std.atomic.Value(bool).init(true);
    try std.testing.expect((try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{ .cancel = &token })) == .cancelled);
    fixture.snapshot.playable_y_inset = 11;
    try std.testing.expectEqual(RejectCode.bounds, (try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
    fixture.snapshot.playable_y_inset = 0;
    var removed = fixture.snapshot.chunks.fetchRemove(chunkId(&fixture.snapshot.layout, instance.origin)).?.value;
    removed.deinit(std.testing.allocator);
    try std.testing.expectEqual(RejectCode.missing_data, (try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
}

test "harmless cavity earth preserves an independent lateral plank route" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 3, 1, 2 }, &.{ .rebar, .none, .rebar, .planks, .planks, .planks });
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    try fixture.put(.{ 11, 10, 4 }, .dirt);
    var result = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expect(result == .prepared);
    defer result.prepared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_dependents);
    try std.testing.expectEqual(rules.BlockType.dirt, fixture.snapshot.chunks.get(chunkId(&fixture.snapshot.layout, .{ 11, 10, 4 })).?.blocks.blocks[4][10][11]);
}

test "finite batches retain lower independent plank and mixed reinforced routes" {
    for ([_]bool{ false, true }) |planned| {
        for ([_]bool{ false, true }) |reinforced| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            const limit = if (reinforced) rules.Limits.mineral_height else rules.Limits.wood_height;
            const span = if (reinforced) rules.Limits.reinforced_span else rules.Limits.plank_span;
            const floor_z = limit + 3;
            var cells: [rules.Limits.mineral_height]rules.BlockType = undefined;
            for (cells[0..limit], 0..) |*material, level| material.* = if (!reinforced) .planks else if (level % 2 == 0) .rebar else .reinforced_concrete;
            const definition = try fixture.definition(.{ 1, 1, limit }, cells[0..limit]);
            var instance = try fixture.instance(.{ 10 + span + 1, 10, 4 });
            defer instance.deinit(std.testing.allocator);
            for (4..6) |z| for (9..12) |y| for (9..12) |x| try fixture.put(.{ @intCast(x), @intCast(y), @intCast(z) }, .stone);
            var roots: [32]Cell = undefined;
            var count: usize = 0;
            for (6..floor_z) |z| {
                const material: rules.BlockType = if (!reinforced) .tree_trunk else if (z % 2 == 0) .rebar else .reinforced_concrete;
                roots[count] = .{ 10, 10, @intCast(z) };
                try fixture.existing(roots[count], material, planned);
                count += 1;
            }
            for (0..span + 1) |offset| {
                roots[count] = .{ 10 + @as(u32, @intCast(offset)), 10, floor_z };
                try fixture.existing(roots[count], if (!reinforced) .planks else if (offset % 2 == 0) .rebar else .reinforced_concrete, planned);
                count += 1;
            }
            for (1..3) |level| {
                roots[count] = .{ 10 + span, 10, floor_z + @as(u32, @intCast(level)) };
                try fixture.existing(roots[count], if (!reinforced) .planks else if (level == 1) .rebar else .reinforced_concrete, planned);
                count += 1;
            }
            // The old tower already reaches its height limit. The new, closer
            // full-height column must not discard the original lower route.
            try fixture.expectValidRoots(roots[0..count], null);
            var result = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
            try std.testing.expect(result == .prepared);
            defer result.prepared.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_dependents);
            try fixture.expectValidRoots(roots[0..count], &result.prepared.publication);
        }
    }
}

test "finite batches preserve real and planned footprint and road support witnesses" {
    for ([_]bool{ false, true }) |planned| {
        for ([_]rules.BlockType{ .dirt, .sand, .country_road_solid, .country_road_adaptive, .custom }) |material| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            const definition = try fixture.definition(.{ 2, 1, 2 }, &.{ .rebar, .rebar, .planks, .planks });
            var instance = try fixture.instance(.{ 12, 10, 4 });
            defer instance.deinit(std.testing.allocator);
            const root: Cell = .{ 10, 10, 5 };
            for (9..12) |y| for (9..12) |x| try fixture.put(.{ @intCast(x), @intCast(y), 4 }, if (material.isRoad()) .country_road_adaptive else .stone);
            try fixture.existing(root, material, planned);
            try fixture.expectValidRoots(&.{root}, null);
            var result = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
            try std.testing.expect(result == .prepared);
            defer result.prepared.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_dependents);
            try fixture.expectValidRoots(&.{root}, &result.prepared.publication);
        }
    }
}

test "admission does not certify or scan pre-existing invalid planned roots" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const definition = try fixture.definition(.{ 1, 1, 2 }, &.{ .planks, .planks });
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(std.testing.allocator);
    const old_root: Cell = .{ 11, 10, 20 };
    try fixture.existing(old_root, .planks, true);
    var result = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
    try std.testing.expect(result == .prepared);
    defer result.prepared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
    try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_dependents);
    var view: View = .{ .snapshot = &fixture.snapshot, .publication = &result.prepared.publication };
    var validator: rules.Validator = .{ .allocator = std.testing.allocator, .reader = view.reader() };
    defer validator.deinit();
    try std.testing.expect(validator.checkExisting(.{ old_root[0], old_root[1], old_root[2] }) != null);
    try std.testing.expectEqual(@as(u64, 99), result.prepared.publication.chunks.get(chunkId(&fixture.snapshot.layout, old_root)).?.lookup.get(old_root).?.instance_id);
}

test "compiler rejects well-formed unsupported contents before certified admission" {
    const cells = [_]rules.BlockType{ .planks, .none, .none, .planks };
    const definition: blueprint.Definition = .{ .size = .{ 2, 1, 2 }, .cells = &cells, .target_count = 2 };
    try definition.validateWellFormed(31, blueprint.default_max_cells);
    const compiled = try blueprint.compile(std.testing.allocator, .{ .size = definition.size, .cells = definition.cells }, .{ .horizontal_limit = 31 });
    try std.testing.expect(compiled == .invalid);
    try std.testing.expectEqual(blueprint.DiagnosticCode.structural, compiled.invalid.code);
    try std.testing.expectEqual(rules.Reason.horizontal_span, compiled.invalid.failure.?.reason);
}

test "target-only admission retains all allowed materials overlap immutable and platform checks" {
    for ([_]rules.BlockType{ .dirt, .sand, .crushed_stone, .tree_trunk, .planks, .rebar, .reinforced_concrete, .country_road_solid }) |material| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const definition = try fixture.definition(.{ 1, 1, 1 }, &.{material});
        var instance = try fixture.instance(.{ 10, 10, 4 });
        defer instance.deinit(std.testing.allocator);
        var result = try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{});
        try std.testing.expect(result == .prepared);
        defer result.prepared.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
        try std.testing.expectEqual(@as(usize, 27), result.prepared.foundation_reads);
        try fixture.existing(instance.origin, material, true);
        try std.testing.expectEqual(RejectCode.overlap, (try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
        const chunk = fixture.snapshot.chunks.getPtr(chunkId(&fixture.snapshot.layout, instance.origin)).?;
        _ = chunk.index.removeTarget(instance.origin);
        chunk.immutable = try std.testing.allocator.dupe(transforms.BlockIndex, &.{localIndex(instance.origin)});
        try std.testing.expectEqual(RejectCode.immutable, (try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
        std.testing.allocator.free(chunk.immutable);
        chunk.immutable = &.{};
        try fixture.put(.{ 9, 9, 1 }, .none);
        try fixture.existing(.{ 9, 9, 1 }, .rebar, true);
        try std.testing.expectEqual(RejectCode.foundation, (try prepareCertified(std.testing.allocator, &fixture.snapshot, definition, instance, .{})).rejected.code);
    }
}

fn allocationFixture(allocator: std.mem.Allocator, fixture: *const Fixture, definition: blueprint.Definition, instance: runtime.Instance) !void {
    var result = try prepareCertified(allocator, &fixture.snapshot, definition, instance, .{});
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

const DifferentialAdmissionWorld = struct {
    resident: Snapshot,

    fn init(layout: engine.WorldLayout) !DifferentialAdmissionWorld {
        var result: DifferentialAdmissionWorld = .{ .resident = .{ .layout = layout, .overlay_revision = 7 } };
        errdefer result.resident.deinit(std.testing.allocator);
        for (0..@intCast(layout.size_in_chunks[2])) |z| for (0..@intCast(layout.size_in_chunks[1])) |y| for (0..@intCast(layout.size_in_chunks[0])) |x| {
            const blocks = try std.testing.allocator.create(WorldChunkData);
            errdefer std.testing.allocator.destroy(blocks);
            blocks.* = WorldChunkData.initEmpty();
            try result.resident.chunks.put(std.testing.allocator, layout.encodeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) }), .{ .revision = 1, .blocks = blocks });
        };
        return result;
    }

    fn canonical(self: *const DifferentialAdmissionWorld, cell: rules.Cell) Cell {
        return .{ @intCast(@mod(cell[0], self.resident.layout.size_in_blocks[0])), @intCast(cell[1]), @intCast(cell[2]) };
    }

    fn put(self: *DifferentialAdmissionWorld, cell: rules.Cell, material: rules.BlockType) void {
        const normalized = self.canonical(cell);
        const chunk = self.resident.chunks.getPtr(chunkId(&self.resident.layout, normalized)).?;
        chunk.blocks.blocks[normalized[2] % 32][normalized[1] % 32][normalized[0] % 32] = material;
    }

    fn cloneSelected(self: *const DifferentialAdmissionWorld, ids: []const ChunkId) !Snapshot {
        const allocator = std.testing.allocator;
        var result: Snapshot = .{ .layout = self.resident.layout, .overlay_revision = self.resident.overlay_revision };
        errdefer result.deinit(allocator);
        for (ids) |id| {
            const source = self.resident.chunks.get(id).?;
            const blocks = try allocator.create(WorldChunkData);
            errdefer allocator.destroy(blocks);
            blocks.* = source.blocks.*;
            var index = try source.index.clone(allocator);
            errdefer index.deinit(allocator);
            const immutable = try allocator.dupe(transforms.BlockIndex, source.immutable);
            errdefer allocator.free(immutable);
            try result.chunks.put(allocator, id, .{ .revision = source.revision, .blocks = blocks, .immutable = immutable, .index = index });
        }
        return result;
    }
};

fn expectSamePublication(expected: runtime.PreparedPublication, actual: runtime.PreparedPublication) !void {
    const left = expected.instance;
    const right = actual.instance;
    try std.testing.expectEqual(left.id, right.id);
    try std.testing.expectEqual(left.definition_id, right.definition_id);
    try std.testing.expectEqual(left.owner, right.owner);
    try std.testing.expectEqual(left.origin, right.origin);
    try std.testing.expectEqual(left.rotation, right.rotation);
    try std.testing.expectEqual(left.remaining, right.remaining);
    try std.testing.expectEqual(left.active, right.active);
    try std.testing.expectEqualSlices(u8, left.fulfilled, right.fulfilled);
    try std.testing.expectEqual(left.box_chunks.len, right.box_chunks.len);
    for (left.box_chunks) |id| try std.testing.expect(std.mem.indexOfScalar(ChunkId, right.box_chunks, id) != null);
    try std.testing.expectEqual(expected.chunks.count(), actual.chunks.count());
    var chunks = expected.chunks.iterator();
    while (chunks.next()) |entry| {
        const other = actual.chunks.get(entry.key_ptr.*).?;
        const index = entry.value_ptr;
        try std.testing.expectEqual(index.instances.items.len, other.instances.items.len);
        for (index.instances.items) |id| try std.testing.expect(std.mem.indexOfScalar(u64, other.instances.items, id) != null);
        try std.testing.expectEqual(index.targets.items.len, other.targets.items.len);
        try std.testing.expectEqual(index.lookup.count(), other.lookup.count());
        for (index.targets.items) |cell| {
            const target = index.lookup.get(cell).?;
            const other_target = other.lookup.get(cell).?;
            try std.testing.expectEqual(target.instance_id, other_target.instance_id);
            try std.testing.expectEqual(target.cell_index, other_target.cell_index);
            try std.testing.expectEqual(target.material, other_target.material);
            try std.testing.expectEqual(cell, other.targets.items[other_target.chunk_slot]);
        }
    }
}

fn structurallyCheckedPublication(snapshot: *const Snapshot, definition: blueprint.Definition, instance: runtime.Instance) !runtime.PreparedPublication {
    const allocator = std.testing.allocator;
    var sources: std.AutoHashMapUnmanaged(ChunkId, runtime.ChunkIndex) = .empty;
    defer sources.deinit(allocator);
    var chunks = snapshot.chunks.iterator();
    while (chunks.next()) |entry| try sources.put(allocator, entry.key_ptr.*, entry.value_ptr.index);
    var owned_instance = try instance.clone(allocator);
    var publication = runtime.buildPublication(allocator, &snapshot.layout, definition, owned_instance, &sources, null) catch |err| {
        owned_instance.deinit(allocator);
        return err;
    };
    errdefer publication.deinit(allocator);
    var view: View = .{ .snapshot = snapshot, .publication = &publication };
    var shared: rules.Validator = .{ .allocator = allocator, .reader = view.reader() };
    defer shared.deinit();
    for (definition.cells, 0..) |material, index| {
        if (material == .none) continue;
        const cell = runtime.worldCell(&snapshot.layout, instance.origin, definition.size, instance.rotation, blueprint.cellAtIndex(definition.size, index)).?;
        var fresh: rules.Validator = .{ .allocator = allocator, .reader = view.reader() };
        defer fresh.deinit();
        for ([_]*rules.Validator{ &fresh, &shared }) |validator| {
            if (validator.checkExisting(.{ cell[0], cell[1], cell[2] })) |failure| {
                std.debug.print("certified target {any} failed reference validation: {s}\n", .{ cell, @tagName(failure.reason) });
                return error.TestUnexpectedResult;
            }
        }
    }
    return publication;
}

test "certified admission agrees with complete-world structural reference across materials rotations and seams" {
    const allocator = std.testing.allocator;
    const region = @import("blueprint_admission_region.zig");
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    // Enumerate all resident chunks independently of the production collector.
    var all_ids: [64]ChunkId = undefined;
    var count: usize = 0;
    for (0..4) |z| for (0..4) |y| for (0..4) |x| {
        all_ids[count] = layout.encodeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) });
        count += 1;
    };
    const size: blueprint.Size = .{ 31, 7, 20 };
    var mixed = [_]rules.BlockType{.none} ** (31 * 7 * 20);
    mixed[blueprint.linearIndex(size, .{ 0, 3, 0 }).?] = .rebar;
    // Reach 27 leaves room for the far platform corner at distance 28.
    for (1..8) |level| {
        const start = (level - 1) * 4;
        for (0..@min(4, 27 - start) + 1) |step| mixed[blueprint.linearIndex(size, .{ @intCast(start + step), 3, @intCast(level) }).?] = .rebar;
    }
    for (0..20) |z| mixed[blueprint.linearIndex(size, .{ 30, 6, @intCast(z) }).?] = if (z % 2 == 0) .rebar else .reinforced_concrete;
    for (0..12) |z| mixed[blueprint.linearIndex(size, .{ 30, 0, @intCast(z) }).?] = .tree_trunk;
    mixed[blueprint.linearIndex(size, .{ 0, 6, 0 }).?] = .tree_trunk;
    for (0..3) |x| mixed[blueprint.linearIndex(size, .{ @intCast(x), 6, 1 }).?] = .planks;
    for (2..12) |z| mixed[blueprint.linearIndex(size, .{ 2, 6, @intCast(z) }).?] = .planks;
    for (0..6) |z| mixed[blueprint.linearIndex(size, .{ 10, 0, @intCast(z) }).?] = .stone;
    mixed[blueprint.linearIndex(size, .{ 15, 0, 0 }).?] = .grass;
    mixed[blueprint.linearIndex(size, .{ 16, 0, 0 }).?] = .sand;
    mixed[blueprint.linearIndex(size, .{ 15, 6, 0 }).?] = .country_road_solid;
    const fallback = [_]rules.BlockType{.stone} ** 7 ++ [_]rules.BlockType{.rebar};
    const platforms = [_]rules.BlockType{ .stone, .packed_dirt, .grass, .clay, .crushed_stone, .rebar, .reinforced_concrete, .metal_ore, .limestone, .coal, .deeprock };
    var cavity_controls: usize = 0;
    for ([_]blueprint.Snapshot{ .{ .size = size, .cells = &mixed }, .{ .size = .{ 1, 1, 8 }, .cells = &fallback } }, 0..) |input, scenario| {
        const compiled = try blueprint.compile(allocator, input, .{ .horizontal_limit = blueprint.horizontalLimit(&layout) });
        try std.testing.expect(compiled == .valid);
        var certified = compiled.valid;
        defer certified.deinit(allocator);
        try std.testing.expectEqual(@as(u32, if (scenario == 0) 0 else 7), certified.substituted_count);
        const definition = certified.definition;
        if (scenario == 0) {
            try std.testing.expectEqual(rules.BlockType.crushed_stone, definition.blockAt(.{ 10, 0, 0 }).?);
            try std.testing.expectEqual(rules.BlockType.dirt, definition.blockAt(.{ 15, 0, 0 }).?);
        }
        for (0..4) |turn| for ([_]Cell{ .{ 31, 31, 64 }, .{ 126, 31, 64 } }) |origin| {
            const rotation: u2 = @intCast(turn);
            const fulfilled = try allocator.alloc(u8, (definition.cells.len + 7) / 8);
            @memset(fulfilled, 0);
            var instance: runtime.Instance = .{ .id = 1, .definition_id = 1, .owner = 1, .origin = origin, .rotation = rotation, .fulfilled = fulfilled, .remaining = definition.target_count, .box_chunks = try runtime.boxChunks(allocator, &layout, origin, definition.size, rotation) };
            defer instance.deinit(allocator);
            var world = try DifferentialAdmissionWorld.init(layout);
            defer world.resident.deinit(allocator);
            var first_bottom: ?Cell = null;
            for (definition.cells[0 .. @as(usize, definition.size[0]) * definition.size[1]], 0..) |material, index| {
                if (material == .none) continue;
                const root = runtime.worldCell(&layout, origin, definition.size, rotation, blueprint.cellAtIndex(definition.size, index)).?;
                if (first_bottom == null) first_bottom = root;
                for (1..4) |depth| for (0..3) |y| for (0..3) |x| world.put(rules.Cell{ root[0], root[1], root[2] } + rules.Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -@as(i64, @intCast(depth)) }, platforms[((depth - 1) * 9 + y * 3 + x) % platforms.len]);
            }
            if (scenario == 0) {
                const cavity = runtime.worldCell(&layout, origin, definition.size, rotation, .{ 12, 2, 4 }).?;
                world.put(.{ cavity[0], cavity[1], cavity[2] }, .sand);
            }
            world.put(rules.Cell{ origin[0], origin[1], origin[2] } + rules.Cell{ -2, 0, 1 }, .rebar);
            const footprint = instance.box_chunks[0];
            const coords = layout.decodeChunkId(footprint);
            const sentinel: Cell = .{ @as(u32, @intCast(coords[0])) * 32 + 31, @as(u32, @intCast(coords[1])) * 32 + 31, 95 };
            const old_index = &world.resident.chunks.getPtr(footprint).?.index;
            try old_index.instances.append(allocator, 99);
            try old_index.targets.append(allocator, sentinel);
            try old_index.lookup.put(allocator, sentinel, .{ .instance_id = 99, .cell_index = 7, .material = .planks, .chunk_slot = 0 });
            const selected = try region.chunks(allocator, &layout, origin, definition.size, rotation, 1024);
            defer allocator.free(selected);
            try std.testing.expect(selected.len < all_ids.len);
            var narrow = try world.cloneSelected(selected);
            defer narrow.deinit(allocator);
            var complete = try world.cloneSelected(&all_ids);
            defer complete.deinit(allocator);
            // The oracle repeats every full proof on complete data, with fresh
            // and shared validator caches, independently of prepareCertified.
            var reference = try structurallyCheckedPublication(&complete, definition, instance);
            defer reference.deinit(allocator);
            var result = try prepareCertified(allocator, &narrow, definition, instance, .{});
            try std.testing.expect(result == .prepared);
            defer result.prepared.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_dependents);
            try expectSamePublication(reference, result.prepared.publication);
            const retained = result.prepared.publication.chunks.get(footprint).?;
            try std.testing.expect(std.mem.indexOfScalar(u64, retained.instances.items, 99) != null);
            try std.testing.expectEqual(@as(u64, 99), retained.lookup.get(sentinel).?.instance_id);
            // A cavity-only chunk remains a required complete index source.
            for (instance.box_chunks) |id| {
                var has_target = false;
                for (definition.cells, 0..) |material, index| {
                    if (material == .none) continue;
                    const cell = runtime.worldCell(&layout, origin, definition.size, rotation, blueprint.cellAtIndex(definition.size, index)).?;
                    has_target = has_target or chunkId(&layout, cell) == id;
                }
                if (has_target) continue;
                var missing_cavity = try world.cloneSelected(selected);
                defer missing_cavity.deinit(allocator);
                var removed = missing_cavity.chunks.fetchRemove(id).?.value;
                removed.deinit(allocator);
                try std.testing.expectEqual(RejectCode.missing_data, (try prepareCertified(allocator, &missing_cavity, definition, instance, .{})).rejected.code);
                cavity_controls += 1;
                break;
            }
            const source_id = chunkId(&layout, .{ first_bottom.?[0], first_bottom.?[1], first_bottom.?[2] - 1 });
            try std.testing.expect(std.mem.indexOfScalar(ChunkId, instance.box_chunks, source_id) == null);
            var removed = narrow.chunks.fetchRemove(source_id).?.value;
            removed.deinit(allocator);
            try std.testing.expectEqual(RejectCode.missing_data, (try prepareCertified(allocator, &narrow, definition, instance, .{})).rejected.code);
        };
    }
    try std.testing.expect(cavity_controls > 0);
}

test "seeded certified admission preserves complete-world proofs under mixed platforms and additions" {
    const allocator = std.testing.allocator;
    const region = @import("blueprint_admission_region.zig");
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const seed: u64 = 530811;
    const candidate_count = 32;
    const materials = [_]rules.BlockType{ .none, .none, .none, .stone, .crushed_stone, .dirt, .packed_dirt, .grass, .sand, .tree_trunk, .planks, .rebar, .reinforced_concrete, .country_road_solid };
    const platforms = [_]rules.BlockType{ .stone, .packed_dirt, .grass, .clay, .crushed_stone, .rebar, .reinforced_concrete, .metal_ore, .limestone, .coal, .deeprock };
    const additions = [_]rules.BlockType{ .sand, .leaves, .water, .snow, .tree_trunk, .crushed_stone, .rebar, .stone, .dirt };
    var accepted: usize = 0;
    var multilayer: usize = 0;
    var transform_count: usize = 0;
    var reference_target_checks: usize = 0;
    var cavity_additions: usize = 0;
    var surrounding_additions: usize = 0;
    for (0..candidate_count) |candidate| {
        // A candidate's contents do not depend on which earlier candidates compiled.
        var prng = std.Random.DefaultPrng.init(seed + @as(u64, @intCast(candidate)));
        const random = prng.random();
        const kind = candidate % 4;
        const size: blueprint.Size = .{ 2 + random.uintLessThan(u32, 4), 2 + random.uintLessThan(u32, 4), if (kind == 0) 1 else 2 + random.uintLessThan(u32, 7) };
        var storage = [_]rules.BlockType{.none} ** (5 * 5 * 8);
        const cells = storage[0 .. @as(usize, size[0]) * size[1] * size[2]];
        errdefer std.debug.print("seeded admission seed={d} candidate={d} raw_shape={any} cells={any}\n", .{ seed, candidate, size, cells });
        if (kind == 0 or kind == 2) {
            // Flat floors guarantee broad bottom-material coverage; arbitrary
            // sparse volumes also generate invalid candidates for the compiler.
            for (cells) |*material| material.* = materials[random.uintLessThan(usize, materials.len)];
            cells[0] = .stone;
            cells[@as(usize, size[0]) * size[1] - 1] = .packed_dirt;
        } else {
            for (0..size[1]) |y| for (0..size[0]) |x| {
                if (x == 0 and y == 0) {
                    for (0..size[2]) |z| cells[(z * size[1] + y) * size[0] + x] = .planks;
                    continue;
                }
                if (x == size[0] - 1 and y == size[1] - 1) {
                    cells[y * size[0] + x] = .packed_dirt;
                    continue;
                }
                if (random.uintLessThan(u32, 4) == 0) continue;
                const family = random.uintLessThan(u32, 5);
                var height = 1 + random.uintLessThan(u32, size[2]);
                if (family == 2) height = @min(height, rules.Limits.crushed_column);
                if (family >= 3) height = 1;
                for (0..height) |z| {
                    cells[(z * size[1] + y) * size[0] + x] = switch (family) {
                        0 => if (random.boolean()) .tree_trunk else .planks,
                        1 => if (random.boolean()) .rebar else .reinforced_concrete,
                        2 => if (random.boolean()) .stone else .crushed_stone,
                        3 => if (random.boolean()) .sand else .grass,
                        else => .country_road_solid,
                    };
                }
            };
            if (kind == 3) for (0..3) |_| {
                cells[random.uintLessThan(usize, cells.len)] = materials[random.uintLessThan(usize, materials.len)];
            };
        }
        const compiled = try blueprint.compile(allocator, .{ .size = size, .cells = cells }, .{ .horizontal_limit = blueprint.horizontalLimit(&layout), .max_cells = 256 });
        try std.testing.expect(compiled != .cancelled);
        if (compiled != .valid) continue;
        var certified = compiled.valid;
        defer certified.deinit(allocator);
        const definition = certified.definition;
        accepted += 1;
        if (definition.size[2] > 1) multilayer += 1;
        for (0..4) |turn| for ([_]Cell{ .{ 31, 31, 64 }, .{ 126, 31, 64 } }, 0..) |origin, origin_index| {
            const rotation: u2 = @intCast(turn);
            errdefer std.debug.print("seeded admission seed={d} candidate={d} certified_shape={any} origin={any} rotation={d}\n", .{ seed, candidate, definition.size, origin, rotation });
            var world = try DifferentialAdmissionWorld.init(layout);
            defer world.resident.deinit(allocator);
            var terrain_prng = std.Random.DefaultPrng.init(seed + candidate_count + @as(u64, @intCast(candidate * 8 + turn * 2 + origin_index)));
            const terrain_random = terrain_prng.random();
            for (definition.cells[0 .. @as(usize, definition.size[0]) * definition.size[1]], 0..) |material, index| {
                if (material == .none) continue;
                const root = runtime.worldCell(&layout, origin, definition.size, rotation, blueprint.cellAtIndex(definition.size, index)).?;
                for (1..rules.Platform.depth + 1) |depth| for (0..rules.Platform.width) |y| for (0..rules.Platform.width) |x| {
                    const position = rules.Cell{ root[0], root[1], root[2] } + rules.Cell{ @as(i64, @intCast(x)) - rules.Platform.xy_radius, @as(i64, @intCast(y)) - rules.Platform.xy_radius, -@as(i64, @intCast(depth)) };
                    world.put(position, platforms[terrain_random.uintLessThan(usize, platforms.len)]);
                };
            }
            for (definition.cells, 0..) |material, index| {
                if (material != .none or !terrain_random.boolean()) continue;
                const cell = runtime.worldCell(&layout, origin, definition.size, rotation, blueprint.cellAtIndex(definition.size, index)).?;
                world.put(.{ cell[0], cell[1], cell[2] }, additions[terrain_random.uintLessThan(usize, additions.len)]);
                cavity_additions += 1;
            }
            var physical: View = .{ .snapshot = &world.resident };
            const rotated_size = blueprint.rotatedSize(definition.size, rotation);
            for (0..8) |_| {
                const cell = rules.Cell{ origin[0], origin[1], origin[2] } + rules.Cell{
                    if (terrain_random.boolean()) -1 else @intCast(rotated_size[0]),
                    terrain_random.uintLessThan(u32, rotated_size[1]),
                    terrain_random.uintLessThan(u32, rotated_size[2]),
                };
                if (physical.reader().get(cell) != .none) continue;
                world.put(cell, additions[terrain_random.uintLessThan(usize, additions.len)]);
                surrounding_additions += 1;
            }
            const fulfilled = try allocator.alloc(u8, (definition.cells.len + 7) / 8);
            @memset(fulfilled, 0);
            var instance: runtime.Instance = .{ .id = 1, .definition_id = 1, .owner = 1, .origin = origin, .rotation = rotation, .fulfilled = fulfilled, .remaining = definition.target_count, .box_chunks = &.{} };
            defer instance.deinit(allocator);
            instance.box_chunks = try runtime.boxChunks(allocator, &layout, origin, definition.size, rotation);
            const selected = try region.chunks(allocator, &layout, origin, definition.size, rotation, 1024);
            defer allocator.free(selected);
            try std.testing.expect(selected.len < world.resident.chunks.count());
            var narrow = try world.cloneSelected(selected);
            defer narrow.deinit(allocator);
            var reference = try structurallyCheckedPublication(&world.resident, definition, instance);
            defer reference.deinit(allocator);
            var result = try prepareCertified(allocator, &narrow, definition, instance, .{});
            try std.testing.expect(result == .prepared);
            defer result.prepared.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_targets);
            try std.testing.expectEqual(@as(usize, 0), result.prepared.validated_dependents);
            try expectSamePublication(reference, result.prepared.publication);
            transform_count += 1;
            reference_target_checks += 2 * definition.target_count;
        };
    }
    std.debug.print("seeded certified admission seed={d}: {d}/{d} accepted, {d} multilayer, {d} transforms, {d} full target checks, {d} cavity and {d} surrounding additions\n", .{ seed, accepted, candidate_count, multilayer, transform_count, reference_target_checks, cavity_additions, surrounding_additions });
    // Eight flat and eight unperturbed column candidates must exercise the
    // certificate; a compiler that rejects everything cannot make this test pass.
    try std.testing.expect(accepted >= 16);
    try std.testing.expect(multilayer >= 8);
    try std.testing.expectEqual(accepted * 8, transform_count);
    try std.testing.expect(cavity_additions > 0);
    try std.testing.expect(surrounding_additions > 0);
}

test "compiler rejects the clipped support route that box-face validation misses" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const size: blueprint.Size = .{ 31, 5, 9 };
    var source = [_]rules.BlockType{.none} ** (31 * 5 * 9);
    source[blueprint.linearIndex(size, .{ 0, 2, 0 }).?] = .rebar;
    // Seven four-cell overhangs make the far target depend on the bottom
    // source exactly 28 cells away, while keeping mineral height below 20.
    for (1..8) |level| for (0..5) |step| {
        source[blueprint.linearIndex(size, .{ @intCast((level - 1) * 4 + step), 2, @intCast(level) }).?] = .rebar;
    };
    // Independent wood roots make the failing far target strictly interior
    // on all six box faces without adding any reinforced support route.
    for (0..9) |z| source[blueprint.linearIndex(size, .{ 30, 4, @intCast(z) }).?] = .tree_trunk;
    source[blueprint.linearIndex(size, .{ 30, 0, 0 }).?] = .tree_trunk;
    const compiled = try blueprint.compile(allocator, .{ .size = size, .cells = &source }, .{ .horizontal_limit = blueprint.horizontalLimit(&fixture.snapshot.layout) });
    try std.testing.expect(compiled == .invalid);
    try std.testing.expectEqual(blueprint.DiagnosticCode.structural, compiled.invalid.code);
    try std.testing.expectEqual(rules.Reason.support_search_limit, compiled.invalid.failure.?.reason);
    // This deliberately uncertified definition is used only by the full
    // validator below, never by certificate-based admission.
    const definition: blueprint.Definition = .{ .size = size, .cells = try allocator.dupe(rules.BlockType, &source), .target_count = 46 };
    try definition.validateWellFormed(31, blueprint.default_max_cells);
    try fixture.state.insertDefinition(allocator, .{ .id = 1, .owner = 1, .name = try allocator.dupe(u8, "uncertified face-only control"), .definition = definition });
    var instance = try fixture.instance(.{ 10, 10, 4 });
    defer instance.deinit(allocator);
    var sources: std.AutoHashMapUnmanaged(ChunkId, runtime.ChunkIndex) = .empty;
    defer sources.deinit(allocator);
    var chunks = fixture.snapshot.chunks.iterator();
    while (chunks.next()) |entry| try sources.put(allocator, entry.key_ptr.*, entry.value_ptr.index);
    var owned_instance = try instance.clone(allocator);
    var publication = runtime.buildPublication(allocator, &fixture.snapshot.layout, definition, owned_instance, &sources, null) catch |err| {
        owned_instance.deinit(allocator);
        return err;
    };
    defer publication.deinit(allocator);
    for ([_]blueprint.LocalCell{ .{ 0, 2, 0 }, .{ 30, 4, 0 }, .{ 30, 0, 0 } }) |local| {
        const root = runtime.worldCell(&fixture.snapshot.layout, instance.origin, size, 0, local).?;
        for (1..4) |depth| for (0..3) |y| for (0..3) |x| {
            try fixture.put(.{ root[0] + @as(u32, @intCast(x)) - 1, root[1] + @as(u32, @intCast(y)) - 1, root[2] - @as(u32, @intCast(depth)) }, .packed_dirt);
        };
    }
    // Full ordinary validation still distinguishes an unsupported interior cell
    // from every occupied face cell; the compiler now makes this check itself.
    var view: View = .{ .snapshot = &fixture.snapshot, .publication = &publication };
    const bad_local: blueprint.LocalCell = .{ 28, 2, 7 };
    const bad_world = runtime.worldCell(&fixture.snapshot.layout, instance.origin, size, 0, bad_local).?;
    var boundary_count: usize = 0;
    var failed_count: usize = 0;
    for (definition.cells, 0..) |material, index| {
        if (material == .none) continue;
        const local = blueprint.cellAtIndex(size, index);
        const cell = runtime.worldCell(&fixture.snapshot.layout, instance.origin, size, 0, local).?;
        var validator: rules.Validator = .{ .allocator = allocator, .reader = view.reader() };
        defer validator.deinit();
        const failure = validator.checkExisting(.{ cell[0], cell[1], cell[2] });
        var boundary = false;
        for (local, size) |coordinate, extent| boundary = boundary or coordinate == 0 or coordinate == extent - 1;
        if (boundary) {
            boundary_count += 1;
            try std.testing.expect(failure == null);
        }
        if (std.mem.eql(u32, &local, &bad_local)) {
            try std.testing.expect(!boundary);
            try std.testing.expect(failure != null);
            try std.testing.expectEqual(rules.Reason.support_search_limit, failure.?.reason);
            try std.testing.expectEqual(@as(u32, 29), failure.?.actual);
            try std.testing.expectEqual(@as(u32, 28), failure.?.limit);
            failed_count += 1;
        } else try std.testing.expect(failure == null);
    }
    try std.testing.expectEqual(@as(usize, 12), boundary_count);
    try std.testing.expectEqual(@as(usize, 1), failed_count);
    try std.testing.expectEqual(Cell{ 38, 12, 11 }, bad_world);
}
