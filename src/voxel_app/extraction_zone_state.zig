//! Simulation-owned occupied cells and permanent claims, indexed by source chunk.
const std = @import("std");
const engine = @import("engine");
const geometry = @import("extraction_zone.zig");
const transformations = @import("block_transformations.zig");
const boundary_mask = @import("boundary_mask.zig");
const chunk_size = engine.chunk_utils.CHUNK_SIZE;

pub const Cell = geometry.Cell;
pub const Bounds = geometry.Bounds;
pub const Filter = geometry.Filter;
pub const Id = u64;
pub const BlockIndex = transformations.BlockIndex;

pub const Record = struct {
    id: Id,
    bounds: Bounds,
    filter: Filter,
};

pub const OwnedCell = struct {
    material: engine.voxel_chunk.BlockType,
    constructed: bool = false,
    slope: ?@import("road_data.zig").Slope = null,
    grass_due: ?transformations.Tick = null,

    pub fn valid(self: OwnedCell, world_size: Cell) bool {
        switch (self.material) {
            .none, .deeprock, .packed_dirt => return false,
            else => {},
        }
        if (self.grass_due != null and self.material != .dirt) return false;
        if (self.slope) |slope| {
            if (self.material != .custom or slope.length == 0 or slope.section >= slope.length) return false;
            for (slope.high_endpoint, world_size) |coordinate, limit| if (coordinate >= limit) return false;
        }
        return true;
    }
};

pub const SourceCell = struct { cell: Cell, value: OwnedCell };

pub const MaterialCounts = struct {
    occupied: usize = 0,
    earth: usize = 0,
    adaptive_road: usize = 0,

    fn add(self: *MaterialCounts, value: OwnedCell) void {
        self.occupied += 1;
        self.earth += @intFromBool(value.material.isEarth());
        self.adaptive_road += @intFromBool(value.material == .custom);
    }

    fn remove(self: *MaterialCounts, value: OwnedCell) void {
        self.occupied -= 1;
        self.earth -= @intFromBool(value.material.isEarth());
        self.adaptive_road -= @intFromBool(value.material == .custom);
    }
};

pub const Chunk = struct {
    pub const history_capacity = 64;

    claims: std.ArrayList(Id) = .empty,
    cells: std.AutoHashMapUnmanaged(BlockIndex, OwnedCell) = .empty,
    constructed: std.ArrayList(BlockIndex) = .empty,
    roads: std.ArrayList(BlockIndex) = .empty,
    pallet_indices: std.ArrayList(BlockIndex) = .empty,
    boundaries: boundary_mask.BoundaryMasks = @splat(.{}),
    timed: transformations.Queue = .{},
    revision: u64 = 0,
    history_base: u64 = 0,
    history: [history_capacity]BlockIndex = undefined,

    pub const Changes = struct {
        chunk: *const Chunk,
        current: u64,

        pub fn next(self: *Changes) ?BlockIndex {
            if (self.current == self.chunk.revision) return null;
            const index = self.chunk.history[self.current % history_capacity];
            self.current += 1;
            return index;
        }
    };

    /// A registration changes claim metadata, so it always requires a new
    /// baseline. This history covers cell-only changes after that boundary.
    pub fn changesSince(self: *const Chunk, base_revision: u64) ?Changes {
        if (base_revision < self.history_base or base_revision >= self.revision) return null;
        return .{ .chunk = self, .current = base_revision };
    }

    fn newBaseline(self: *Chunk) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
        self.history_base = self.revision;
    }

    fn recordCellChange(self: *Chunk, index: BlockIndex) void {
        if (self.revision == std.math.maxInt(u64)) {
            self.newBaseline();
            return;
        }
        self.history[self.revision % history_capacity] = index;
        self.revision += 1;
        self.history_base = @max(self.history_base, self.revision -| history_capacity);
    }

    fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        self.claims.deinit(allocator);
        self.cells.deinit(allocator);
        self.constructed.deinit(allocator);
        self.roads.deinit(allocator);
        self.pallet_indices.deinit(allocator);
        self.timed.deinit(allocator);
    }

    fn addAssumeCapacity(self: *Chunk, index: BlockIndex, value: OwnedCell) void {
        self.cells.putAssumeCapacityNoClobber(index, value);
        if (value.constructed) self.constructed.appendAssumeCapacity(index);
        if (value.material == .custom) self.roads.appendAssumeCapacity(index);
        if (value.material == .pallet) self.pallet_indices.appendAssumeCapacity(index);
        if (value.material.occludesFaces()) boundary_mask.update(&self.boundaries, transformations.coordinates(index), true);
        if (value.grass_due) |due| self.timed.events.appendAssumeCapacity(.{ .block = index, .kind = .grow_grass, .due_tick = due });
    }

    fn sortGrass(self: *Chunk) void {
        std.mem.sort(transformations.Event, self.timed.events.items, {}, struct {
            fn less(_: void, a: transformations.Event, b: transformations.Event) bool {
                return a.due_tick < b.due_tick or (a.due_tick == b.due_tick and a.block < b.block);
            }
        }.less);
    }
};

pub fn cellChunk(cell: Cell) Cell {
    return .{ cell[0] / chunk_size, cell[1] / chunk_size, cell[2] / chunk_size };
}

pub fn cellIndex(cell: Cell) BlockIndex {
    return transformations.index(.{ @truncate(cell[0]), @truncate(cell[1]), @truncate(cell[2]) });
}

pub fn worldCell(coords: Cell, index: BlockIndex) Cell {
    const local = transformations.coordinates(index);
    return .{ coords[0] * chunk_size + local[0], coords[1] * chunk_size + local[1], coords[2] * chunk_size + local[2] };
}

pub const State = struct {
    world_size: Cell = .{ 0, 0, 0 },
    records: std.ArrayList(Record) = .empty,
    by_chunk: std.AutoHashMapUnmanaged(Cell, Chunk) = .empty,
    grass_chunks: std.AutoHashMapUnmanaged(Cell, void) = .empty,
    material_counts: MaterialCounts = .{},
    revision: u64 = 0,

    pub fn init(world_size: Cell) State {
        return .{ .world_size = world_size };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var values = self.by_chunk.valueIterator();
        while (values.next()) |value| value.deinit(allocator);
        self.by_chunk.deinit(allocator);
        self.records.deinit(allocator);
        self.grass_chunks.deinit(allocator);
        self.* = .{};
    }

    fn touch(self: *State) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    pub fn get(self: *const State, id: Id) ?Record {
        if (id == 0 or id > self.records.items.len) return null;
        return self.records.items[@intCast(id - 1)];
    }

    pub fn chunk(self: *const State, coords: Cell) ?*const Chunk {
        return self.by_chunk.getPtr(coords);
    }

    pub fn revisionAt(self: *const State, coords: Cell) u64 {
        const entry = self.chunk(coords) orelse return 0;
        return entry.revision;
    }

    pub fn constructedInChunk(self: *const State, coords: Cell) []const BlockIndex {
        const entry = self.chunk(coords) orelse return &.{};
        return entry.constructed.items;
    }

    pub fn recordAt(self: *const State, cell: Cell) ?Record {
        const entry = self.chunk(cellChunk(cell)) orelse return null;
        for (entry.claims.items) |id| {
            const record = self.get(id).?;
            if (record.bounds.contains(self.world_size[0], cell)) return record;
        }
        return null;
    }

    pub fn cellAt(self: *const State, cell: Cell) ?OwnedCell {
        const entry = self.chunk(cellChunk(cell)) orelse return null;
        return entry.cells.get(cellIndex(cell));
    }

    /// Only the prepared road plan mutates through this pointer. Its caller must
    /// record each slope change with markCellChanged in the same worker turn.
    pub fn cellPtr(self: *State, cell: Cell) ?*OwnedCell {
        const entry = self.by_chunk.getPtr(cellChunk(cell)) orelse return null;
        return entry.cells.getPtr(cellIndex(cell));
    }

    pub fn markCellChanged(self: *State, cell: Cell) void {
        const entry = self.by_chunk.getPtr(cellChunk(cell)).?;
        const index = cellIndex(cell);
        std.debug.assert(entry.cells.contains(index));
        self.recordCellChange(entry, index);
    }

    pub fn setSoilMaterial(self: *State, cell: Cell, material: engine.voxel_chunk.BlockType) void {
        const entry = self.by_chunk.getPtr(cellChunk(cell)).?;
        const index = cellIndex(cell);
        const value = entry.cells.getPtr(index).?;
        std.debug.assert(value.material.isEarth() and material.isEarth());
        std.debug.assert(material != .grass or value.grass_due == null);
        if (value.material == material) return;
        value.material = material;
        self.recordCellChange(entry, index);
    }

    fn recordCellChange(self: *State, entry: *Chunk, index: BlockIndex) void {
        entry.recordCellChange(index);
        self.touch();
    }

    pub fn removeCell(self: *State, cell: Cell) bool {
        const coords = cellChunk(cell);
        const entry = self.by_chunk.getPtr(coords) orelse return false;
        const index = cellIndex(cell);
        const removed = entry.cells.fetchRemove(index) orelse return false;
        if (removed.value.constructed) {
            _ = entry.constructed.swapRemove(std.mem.indexOfScalar(BlockIndex, entry.constructed.items, index).?);
        }
        if (removed.value.material == .custom) {
            _ = entry.roads.swapRemove(std.mem.indexOfScalar(BlockIndex, entry.roads.items, index).?);
        }
        if (removed.value.material == .pallet) {
            _ = entry.pallet_indices.swapRemove(std.mem.indexOfScalar(BlockIndex, entry.pallet_indices.items, index).?);
        }
        if (removed.value.material.occludesFaces()) boundary_mask.update(&entry.boundaries, transformations.coordinates(index), false);
        if (removed.value.grass_due != null) {
            entry.timed.cancel(index);
            if (entry.timed.events.items.len == 0) _ = self.grass_chunks.remove(coords);
        }
        self.material_counts.remove(removed.value);
        self.recordCellChange(entry, index);
        return true;
    }

    pub fn reserveGrass(self: *State, allocator: std.mem.Allocator, cell: Cell) !void {
        const coords = cellChunk(cell);
        const entry = self.by_chunk.getPtr(coords).?;
        if (entry.cells.get(cellIndex(cell)).?.grass_due != null) return;
        if (entry.timed.events.items.len == 0) try self.grass_chunks.ensureUnusedCapacity(allocator, 1);
        try entry.timed.reserve(allocator, 1);
    }

    pub fn setGrassAssumeCapacity(self: *State, cell: Cell, due: ?transformations.Tick) void {
        const coords = cellChunk(cell);
        const entry = self.by_chunk.getPtr(coords).?;
        const index = cellIndex(cell);
        const value = entry.cells.getPtr(index).?;
        if (value.grass_due == due) return;
        if (due) |tick| {
            std.debug.assert(value.material == .dirt);
            if (entry.timed.events.items.len == 0) self.grass_chunks.putAssumeCapacityNoClobber(coords, {});
            entry.timed.scheduleAssumeCapacity(.{ .block = index, .kind = .grow_grass, .due_tick = tick });
        } else {
            entry.timed.cancel(index);
            if (entry.timed.events.items.len == 0) _ = self.grass_chunks.remove(coords);
        }
        value.grass_due = due;
        self.recordCellChange(entry, index);
    }

    pub fn setGrass(self: *State, allocator: std.mem.Allocator, cell: Cell, due: ?transformations.Tick) !void {
        if (due != null) try self.reserveGrass(allocator, cell);
        self.setGrassAssumeCapacity(cell, due);
    }

    pub fn canRegister(self: *const State, bounds: Bounds, budgets: geometry.Budgets) geometry.BoundsError!bool {
        try bounds.validate(self.world_size, budgets);
        return !self.intersects(bounds);
    }

    /// External bounds must be canonical, but may have different admission ceilings.
    pub fn intersects(self: *const State, bounds: Bounds) bool {
        if (self.records.items.len == 0) return false;
        var chunks = bounds.chunks(self.world_size);
        while (chunks.next()) |coords| {
            const entry = self.chunk(coords) orelse continue;
            for (entry.claims.items) |id| {
                if (bounds.intersects(self.world_size[0], self.get(id).?.bounds)) return true;
            }
        }
        return false;
    }

    /// All allocations and cell checks finish before the first claim or cell is
    /// published. The service can commit its prepared terrain holes afterwards.
    pub fn register(self: *State, allocator: std.mem.Allocator, bounds: Bounds, filter: Filter, budgets: geometry.Budgets, source: []const SourceCell) !Record {
        if (!filter.valid()) return error.InvalidFilter;
        if (!try self.canRegister(bounds, budgets)) return error.ConflictingClaim;
        if (source.len > try bounds.volume()) return error.InvalidCell;
        const SourceChunk = struct {
            seen: std.StaticBitSet(1 << @bitSizeOf(BlockIndex)) = .initEmpty(),
            occupied: u32 = 0,
            constructed: usize = 0,
            roads: usize = 0,
            pallets: usize = 0,
            timers: usize = 0,
        };
        var source_chunks: std.AutoHashMapUnmanaged(Cell, SourceChunk) = .empty;
        defer source_chunks.deinit(allocator);
        for (source) |item| {
            if (!bounds.contains(self.world_size[0], item.cell) or !item.value.valid(self.world_size)) return error.InvalidCell;
            const entry = try source_chunks.getOrPut(allocator, cellChunk(item.cell));
            if (!entry.found_existing) entry.value_ptr.* = .{};
            const index = cellIndex(item.cell);
            if (entry.value_ptr.seen.isSet(index)) return error.InvalidCell;
            entry.value_ptr.seen.set(index);
            entry.value_ptr.occupied += 1;
            entry.value_ptr.constructed += @intFromBool(item.value.constructed);
            entry.value_ptr.roads += @intFromBool(item.value.material == .custom);
            entry.value_ptr.pallets += @intFromBool(item.value.material == .pallet);
            entry.value_ptr.timers += @intFromBool(item.value.grass_due != null);
        }

        const id = try std.math.add(u64, self.records.items.len, 1);
        try self.records.ensureUnusedCapacity(allocator, 1);
        var chunks = bounds.chunks(self.world_size);
        var new_count: u32 = 0;
        while (chunks.next()) |coords| {
            if (!self.by_chunk.contains(coords)) new_count = try std.math.add(u32, new_count, 1);
        }
        try self.by_chunk.ensureUnusedCapacity(allocator, new_count);
        var timed_chunks: u32 = 0;
        var counts = source_chunks.iterator();
        while (counts.next()) |entry| {
            if (entry.value_ptr.timers != 0 and !self.grass_chunks.contains(entry.key_ptr.*)) timed_chunks += 1;
        }
        try self.grass_chunks.ensureUnusedCapacity(allocator, timed_chunks);
        errdefer {
            chunks = bounds.chunks(self.world_size);
            while (chunks.next()) |coords| {
                const entry = self.by_chunk.getPtr(coords) orelse continue;
                if (entry.claims.items.len == 0) {
                    entry.deinit(allocator);
                    _ = self.by_chunk.remove(coords);
                }
            }
        }
        chunks = bounds.chunks(self.world_size);
        while (chunks.next()) |coords| {
            const entry = self.by_chunk.getOrPutAssumeCapacity(coords);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            try entry.value_ptr.claims.ensureUnusedCapacity(allocator, 1);
            if (source_chunks.getPtr(coords)) |prepared| {
                try entry.value_ptr.cells.ensureUnusedCapacity(allocator, prepared.occupied);
                try entry.value_ptr.constructed.ensureUnusedCapacity(allocator, prepared.constructed);
                try entry.value_ptr.roads.ensureUnusedCapacity(allocator, prepared.roads);
                try entry.value_ptr.pallet_indices.ensureUnusedCapacity(allocator, prepared.pallets);
                try entry.value_ptr.timed.reserve(allocator, prepared.timers);
            }
        }

        const record: Record = .{ .id = id, .bounds = bounds, .filter = filter };
        self.records.appendAssumeCapacity(record);
        chunks = bounds.chunks(self.world_size);
        while (chunks.next()) |coords| {
            const entry = self.by_chunk.getPtr(coords).?;
            entry.claims.appendAssumeCapacity(id);
            entry.newBaseline();
        }
        for (source) |item| {
            self.by_chunk.getPtr(cellChunk(item.cell)).?.addAssumeCapacity(cellIndex(item.cell), item.value);
            self.material_counts.add(item.value);
        }
        counts = source_chunks.iterator();
        while (counts.next()) |entry| {
            if (entry.value_ptr.timers == 0) continue;
            self.grass_chunks.putAssumeCapacity(entry.key_ptr.*, {});
            self.by_chunk.getPtr(entry.key_ptr.*).?.sortGrass();
        }
        self.touch();
        return record;
    }

    /// Recovery populates the sparse occupied state once all claims are rebuilt.
    /// Call finishRestore before publishing it to timer readers.
    pub fn restoreCell(self: *State, allocator: std.mem.Allocator, cell: Cell, value: OwnedCell) !void {
        if (self.recordAt(cell) == null or !value.valid(self.world_size)) return error.InvalidCell;
        const coords = cellChunk(cell);
        const entry = self.by_chunk.getPtr(coords).?;
        const index = cellIndex(cell);
        if (entry.cells.contains(index)) return error.InvalidCell;
        try entry.cells.ensureUnusedCapacity(allocator, 1);
        if (value.constructed) try entry.constructed.ensureUnusedCapacity(allocator, 1);
        if (value.material == .custom) try entry.roads.ensureUnusedCapacity(allocator, 1);
        if (value.material == .pallet) try entry.pallet_indices.ensureUnusedCapacity(allocator, 1);
        if (value.grass_due != null) {
            try entry.timed.reserve(allocator, 1);
            if (entry.timed.events.items.len == 0) try self.grass_chunks.put(allocator, coords, {});
        }
        entry.addAssumeCapacity(index, value);
        self.material_counts.add(value);
    }

    pub fn finishRestore(self: *State, revision: u64) void {
        var keys = self.grass_chunks.keyIterator();
        while (keys.next()) |key| self.by_chunk.getPtr(key.*).?.sortGrass();
        self.revision = revision;
    }
};

fn claimWithCells(a: std.mem.Allocator) !void {
    var state = State.init(.{ 128, 128, 128 });
    defer state.deinit(a);
    const bounds: Bounds = .{ .min = .{ 127, 31, 8 }, .size = .{ 2, 2, 1 } };
    const stone: Cell = .{ 127, 31, 8 };
    const plank: Cell = .{ 0, 31, 8 };
    const air: Cell = .{ 0, 32, 8 };
    const original = try state.register(a, bounds, @bitCast(@as(u8, 1)), .{}, &.{
        .{ .cell = stone, .value = .{ .material = .stone } },
        .{ .cell = plank, .value = .{ .material = .planks, .constructed = true } },
    });
    try std.testing.expectEqual(original.id, state.recordAt(air).?.id);
    try std.testing.expectEqual(null, state.cellAt(air));
    try std.testing.expect(!state.cellAt(stone).?.constructed);
    try std.testing.expect(!original.filter.matches(state.cellAt(stone).?.material));
    try std.testing.expectEqualSlices(BlockIndex, &.{cellIndex(plank)}, state.constructedInChunk(cellChunk(plank)));
    try std.testing.expect(state.removeCell(plank));
    try std.testing.expectEqual(original.id, state.recordAt(plank).?.id);
    try std.testing.expectEqual(null, state.cellAt(plank));
    try std.testing.expectEqual(0, state.constructedInChunk(cellChunk(plank)).len);
    try std.testing.expectError(error.ConflictingClaim, state.register(a, bounds, .{}, .{}, &.{}));
}

test "sparse extraction ownership preserves provenance and protected air across the seam" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, claimWithCells, .{});
}
