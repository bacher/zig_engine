//! Detached zone chunk publications. Each cell-only delta names its exact base.
const std = @import("std");
const state_module = @import("extraction_zone_state.zig");

pub const ChunkId = @import("consts.zig").ChunkId;
pub const BlockIndex = state_module.BlockIndex;
pub const OwnedCell = state_module.OwnedCell;
pub const Record = state_module.Record;

pub const Cell = struct { index: BlockIndex, value: OwnedCell };
pub const Change = struct { index: BlockIndex, value: ?OwnedCell };

pub const Snapshot = struct {
    chunk_id: ChunkId,
    subscription_id: u64,
    terrain_revision: u64,
    revision: u64,
    claims: []const Record = &.{},
    cells: []const Cell = &.{},

    pub fn estimatedOwnedBytes(self: Snapshot) usize {
        return self.claims.len * @sizeOf(Record) + self.cells.len * @sizeOf(Cell);
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.claims);
        allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const Delta = struct {
    chunk_id: ChunkId,
    subscription_id: u64,
    terrain_revision: u64,
    base_revision: u64,
    revision: u64,
    /// Sorted local indices. Each index occurs once with its final value, or
    /// null when its terrain has been excavated. Claims stay in the baseline.
    changes: []const Change,

    pub fn estimatedOwnedBytes(self: Delta) usize {
        return self.changes.len * @sizeOf(Change);
    }

    pub fn deinit(self: *Delta, allocator: std.mem.Allocator) void {
        allocator.free(self.changes);
        self.* = undefined;
    }
};

/// The outer response package may carry several independent chunks.
pub const Update = union(enum) {
    snapshot: Snapshot,
    delta: Delta,

    pub fn estimatedOwnedBytes(self: Update) usize {
        return switch (self) {
            inline else => |payload| payload.estimatedOwnedBytes(),
        };
    }

    pub fn deinit(self: *Update, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*payload| payload.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub fn snapshotBytes(state: *const state_module.State, coords: state_module.Cell) usize {
    const chunk = state.chunk(coords) orelse return 0;
    return chunk.claims.items.len * @sizeOf(Record) + @as(usize, chunk.cells.count()) * @sizeOf(Cell);
}

pub fn snapshot(allocator: std.mem.Allocator, state: *const state_module.State, coords: state_module.Cell, chunk_id: ChunkId, subscription_id: u64, terrain_revision: u64) !Snapshot {
    const chunk = state.chunk(coords);
    var result: Snapshot = .{
        .chunk_id = chunk_id,
        .subscription_id = subscription_id,
        .terrain_revision = terrain_revision,
        .revision = if (chunk) |source| source.revision else 0,
    };
    const source = chunk orelse return result;

    const claims = try allocator.alloc(Record, source.claims.items.len);
    errdefer allocator.free(claims);
    for (claims, source.claims.items) |*record, claim| record.* = state.get(claim).?;
    const cells = try allocator.alloc(Cell, source.cells.count());
    var entries = source.cells.iterator();
    var i: usize = 0;
    while (entries.next()) |entry| : (i += 1) cells[i] = .{ .index = entry.key_ptr.*, .value = entry.value_ptr.* };
    std.mem.sort(Cell, cells, {}, struct {
        fn less(_: void, lhs: Cell, rhs: Cell) bool {
            return lhs.index < rhs.index;
        }
    }.less);
    result.claims = claims;
    result.cells = cells;
    return result;
}

pub fn deltaBytes(state: *const state_module.State, coords: state_module.Cell, base_revision: u64) ?usize {
    const chunk = state.chunk(coords) orelse return null;
    var indices: [state_module.Chunk.history_capacity]BlockIndex = undefined;
    const changed = changedIndices(chunk, base_revision, &indices) orelse return null;
    return changed.len * @sizeOf(Change);
}

/// Null means there is no forward delta from this revision. Check the current
/// State.revisionAt to distinguish an up-to-date subscriber from a baseline miss.
pub fn delta(allocator: std.mem.Allocator, state: *const state_module.State, coords: state_module.Cell, chunk_id: ChunkId, subscription_id: u64, terrain_revision: u64, base_revision: u64) !?Delta {
    const chunk = state.chunk(coords) orelse return null;
    var indices: [state_module.Chunk.history_capacity]BlockIndex = undefined;
    const changed = changedIndices(chunk, base_revision, &indices) orelse return null;
    std.mem.sort(BlockIndex, changed, {}, std.sort.asc(BlockIndex));
    const changes = try allocator.alloc(Change, changed.len);
    for (changes, changed) |*change, index| change.* = .{ .index = index, .value = chunk.cells.get(index) };
    return .{
        .chunk_id = chunk_id,
        .subscription_id = subscription_id,
        .terrain_revision = terrain_revision,
        .base_revision = base_revision,
        .revision = chunk.revision,
        .changes = changes,
    };
}

fn changedIndices(chunk: *const state_module.Chunk, base_revision: u64, indices: *[state_module.Chunk.history_capacity]BlockIndex) ?[]BlockIndex {
    var history = chunk.changesSince(base_revision) orelse return null;
    var count: usize = 0;
    while (history.next()) |index| {
        if (std.mem.indexOfScalar(BlockIndex, indices[0..count], index) != null) continue;
        indices[count] = index;
        count += 1;
    }
    return indices[0..count];
}

fn publicationScenario(a: std.mem.Allocator) !void {
    var state = state_module.State.init(.{ 128, 128, 128 });
    defer state.deinit(a);
    const soil: state_module.Cell = .{ 127, 10, 10 };
    const road: state_module.Cell = .{ 127, 11, 10 };
    const stone: state_module.Cell = .{ 127, 12, 10 };
    const across_seam: state_module.Cell = .{ 0, 10, 10 };
    _ = try state.register(a, .{ .min = soil, .size = .{ 2, 3, 1 } }, .{}, .{}, &.{
        .{ .cell = soil, .value = .{ .material = .dirt, .constructed = true, .grass_due = 30 } },
        .{ .cell = road, .value = .{ .material = .custom } },
        .{ .cell = stone, .value = .{ .material = .stone } },
    });
    const coords = state_module.cellChunk(soil);
    const other_coords = state_module.cellChunk(across_seam);
    const other_revision = state.revisionAt(other_coords);
    var baseline = try snapshot(a, &state, coords, 71, 10, 8);
    defer baseline.deinit(a);
    try std.testing.expectEqual(snapshotBytes(&state, coords), baseline.estimatedOwnedBytes());
    try std.testing.expectEqual(@as(usize, 3), baseline.cells.len);
    try std.testing.expectEqual(@as(usize, 1), baseline.claims.len);

    state.setGrassAssumeCapacity(soil, null);
    state.setSoilMaterial(soil, .grass);
    const slope = @import("road_data.zig").Slope{ .high_endpoint = road, .downhill = .positive_x, .length = 2, .section = 0 };
    state.cellPtr(road).?.slope = slope;
    state.markCellChanged(road);
    try std.testing.expect(state.removeCell(stone));
    var batch = (try delta(a, &state, coords, 71, 10, 10, baseline.revision)).?;
    defer batch.deinit(a);
    try std.testing.expectEqual(baseline.revision, batch.base_revision);
    try std.testing.expectEqual(state.revisionAt(coords), batch.revision);
    try std.testing.expectEqual(@as(?usize, batch.estimatedOwnedBytes()), deltaBytes(&state, coords, baseline.revision));
    try std.testing.expectEqual(@as(u64, 10), batch.terrain_revision);
    try std.testing.expectEqualSlices(Change, &.{
        .{ .index = state_module.cellIndex(soil), .value = .{ .material = .grass, .constructed = true } },
        .{ .index = state_module.cellIndex(road), .value = .{ .material = .custom, .slope = slope } },
        .{ .index = state_module.cellIndex(stone), .value = null },
    }, batch.changes);
    try std.testing.expectEqual(other_revision, state.revisionAt(other_coords));
    try std.testing.expectEqual(@as(?u64, 30), baseline.cells[0].value.grass_due);

    const previous_revision = batch.revision;
    const adjacent: state_module.Cell = .{ 127, 13, 10 };
    _ = try state.register(a, .{ .min = adjacent, .size = .{ 1, 1, 1 } }, .{}, .{}, &.{});
    try std.testing.expectEqual(null, deltaBytes(&state, coords, previous_revision));
    var refreshed = try snapshot(a, &state, coords, 71, 10, 11);
    defer refreshed.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), refreshed.claims.len);
    try std.testing.expectEqual(@as(usize, 2), refreshed.cells.len);
    try std.testing.expect(refreshed.revision > previous_revision);
}

test "extraction zone stream batches exact-base changes and forces a baseline for new claims" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, publicationScenario, .{});
}

test "extraction zone stream bounds history and falls back for an expired base" {
    const a = std.testing.allocator;
    var state = state_module.State.init(.{ 128, 128, 128 });
    defer state.deinit(a);
    const soil: state_module.Cell = .{ 10, 10, 10 };
    _ = try state.register(a, .{ .min = soil, .size = .{ 1, 1, 1 } }, .{}, .{}, &.{.{ .cell = soil, .value = .{ .material = .dirt } }});
    const coords = state_module.cellChunk(soil);
    const base = state.revisionAt(coords);
    for (0..state_module.Chunk.history_capacity + 1) |i| state.setSoilMaterial(soil, if (i % 2 == 0) .grass else .dirt);
    try std.testing.expectEqual(null, deltaBytes(&state, coords, base));
    try std.testing.expectEqual(@as(?usize, @sizeOf(Change)), deltaBytes(&state, coords, base + 1));
    try std.testing.expectEqual(null, deltaBytes(&state, coords, state.revisionAt(coords)));
}
