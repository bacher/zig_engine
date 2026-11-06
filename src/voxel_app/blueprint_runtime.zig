//! Mutable libraries and construction indexes. Structural semantics live in
//! blueprint/block_rules; this module never searches support on fulfillment.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const rules = @import("block_rules.zig");
const ChunkId = @import("consts.zig").ChunkId;
const chunk_size = @import("consts.zig").CHUNK_SIZE;
pub const Cell = [3]u32;

pub const SavedDefinition = struct {
    id: u64,
    owner: u64,
    name: []const u8,
    definition: blueprint.Definition,

    pub fn deinit(self: *SavedDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.definition.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: SavedDefinition, allocator: std.mem.Allocator) !SavedDefinition {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        return .{ .id = self.id, .owner = self.owner, .name = name, .definition = try self.definition.clone(allocator) };
    }
};

pub const Instance = struct {
    id: u64,
    definition_id: u64,
    owner: u64,
    origin: Cell,
    rotation: u2,
    fulfilled: []u8,
    remaining: u32,
    active: bool = true,
    box_chunks: []ChunkId,
    cleanup_cursor: usize = 0,

    pub fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        allocator.free(self.fulfilled);
        allocator.free(self.box_chunks);
        self.* = undefined;
    }

    pub fn isFulfilled(self: Instance, index: usize) bool {
        return self.fulfilled[index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8))) != 0;
    }

    pub fn clone(self: Instance, allocator: std.mem.Allocator) !Instance {
        const bits = try allocator.dupe(u8, self.fulfilled);
        errdefer allocator.free(bits);
        var copy = self;
        copy.fulfilled = bits;
        copy.box_chunks = try allocator.dupe(ChunkId, self.box_chunks);
        return copy;
    }
};

pub const Target = struct {
    instance_id: u64,
    cell_index: u32,
    material: rules.BlockType,
    chunk_slot: usize = 0,
};

pub const ChunkIndex = struct {
    targets: std.ArrayList(Cell) = .empty,
    lookup: std.AutoHashMapUnmanaged(Cell, Target) = .empty,
    instances: std.ArrayList(u64) = .empty,

    /// Swap-remove one target and repair its replacement's slot without allocation.
    pub fn removeTarget(self: *ChunkIndex, cell: Cell) ?Target {
        const target = self.lookup.fetchRemove(cell) orelse return null;
        _ = self.targets.swapRemove(target.value.chunk_slot);
        if (target.value.chunk_slot < self.targets.items.len) self.lookup.getPtr(self.targets.items[target.value.chunk_slot]).?.chunk_slot = target.value.chunk_slot;
        return target.value;
    }

    pub fn deinit(self: *ChunkIndex, allocator: std.mem.Allocator) void {
        self.targets.deinit(allocator);
        self.lookup.deinit(allocator);
        self.instances.deinit(allocator);
    }

    pub fn clone(self: ChunkIndex, allocator: std.mem.Allocator) !ChunkIndex {
        var result: ChunkIndex = .{};
        errdefer result.deinit(allocator);
        result.targets = try self.targets.clone(allocator);
        result.lookup = try self.lookup.clone(allocator);
        result.instances = try self.instances.clone(allocator);
        return result;
    }

    /// Conservative requested-allocation accounting, including retained capacity
    /// and hash metadata/alignment. Backing allocator pages are additional.
    pub fn estimatedOwnedBytes(self: ChunkIndex) usize {
        return self.targets.capacity *| @sizeOf(Cell) +|
            self.instances.capacity *| @sizeOf(u64) +|
            @as(usize, self.lookup.capacity()) *| (@sizeOf(Cell) + @sizeOf(Target) + 1) +|
            (if (self.lookup.capacity() == 0) @as(usize, 0) else 64);
    }
};

/// Prepared off the mutation path. After publication this owns the replaced
/// chunk records, which can be reclaimed by a helper or bounded retirement job.
pub const PreparedPublication = struct {
    instance: Instance,
    chunks: std.AutoHashMapUnmanaged(ChunkId, ChunkIndex) = .empty,
    published: bool = false,

    pub fn deinit(self: *PreparedPublication, allocator: std.mem.Allocator) void {
        if (!self.published) self.instance.deinit(allocator);
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| chunk.deinit(allocator);
        self.chunks.deinit(allocator);
        self.* = undefined;
    }
};

/// Takes instance ownership on success. Source indexes stay unchanged during
/// preparation; only footprint chunks are cloned and extended. Client callers
/// may supply preceding fulfillments to filter from these owned clones.
pub fn buildPublication(allocator: std.mem.Allocator, layout: *const engine.WorldLayout, definition: blueprint.Definition, instance: Instance, source: *const std.AutoHashMapUnmanaged(ChunkId, ChunkIndex), fulfillments: ?*const FulfillmentSet) !PreparedPublication {
    var result: PreparedPublication = .{ .instance = instance };
    errdefer {
        var iterator = result.chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.deinit(allocator);
        result.chunks.deinit(allocator);
    }
    try result.chunks.ensureTotalCapacity(allocator, @intCast(instance.box_chunks.len));
    for (instance.box_chunks) |id| {
        var index = if (source.get(id)) |existing| try existing.clone(allocator) else ChunkIndex{};
        errdefer index.deinit(allocator);
        // Source entries may borrow an earlier publication. Filter only this
        // owned clone, preserving both rollback and its original commit point.
        if (fulfillments) |removed| if (removed.count() != 0) {
            var slot: usize = 0;
            while (slot < index.targets.items.len) {
                const cell = index.targets.items[slot];
                const target = index.lookup.get(cell).?;
                if (removed.contains(.{ .instance_id = target.instance_id, .cell_index = target.cell_index })) {
                    _ = index.removeTarget(cell).?;
                } else slot += 1;
            }
        };
        try index.instances.append(allocator, instance.id);
        result.chunks.putAssumeCapacity(id, index);
    }
    for (definition.cells, 0..) |material, index| {
        if (material == .none or instance.isFulfilled(index)) continue;
        const cell = worldCell(layout, instance.origin, definition.size, instance.rotation, blueprint.cellAtIndex(definition.size, index)) orelse return error.InvalidFootprint;
        const chunk = result.chunks.getPtr(chunkId(layout, cell)).?;
        if (chunk.lookup.contains(cell)) return error.Overlap;
        try chunk.targets.ensureUnusedCapacity(allocator, 1);
        try chunk.lookup.put(allocator, cell, .{ .instance_id = instance.id, .cell_index = @intCast(index), .material = material, .chunk_slot = chunk.targets.items.len });
        chunk.targets.appendAssumeCapacity(cell);
    }
    return result;
}

pub const Fulfill = struct { instance_id: u64, cell_index: u32 };
pub const FulfillmentSet = std.AutoHashMapUnmanaged(Fulfill, void);
pub const Change = union(enum) {
    definition: SavedDefinition,
    instance: Instance,
    fulfill: Fulfill,

    pub fn deinit(self: *Change, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .definition => |*value| value.deinit(allocator),
            .instance => |*value| value.deinit(allocator),
            .fulfill => {},
        }
    }
};

pub fn worldCell(layout: *const engine.WorldLayout, origin: Cell, size: blueprint.Size, rotation: u2, local: Cell) ?Cell {
    const offset = blueprint.rotatedCell(size, local, rotation);
    const y = std.math.add(u32, origin[1], offset[1]) catch return null;
    const z = std.math.add(u32, origin[2], offset[2]) catch return null;
    if (y >= layout.size_in_blocks[1] or z >= layout.size_in_blocks[2]) return null;
    return .{ @intCast((@as(u64, origin[0]) + offset[0]) % layout.size_in_blocks[0]), y, z };
}

pub fn validFootprint(layout: *const engine.WorldLayout, origin: Cell, size: blueprint.Size, rotation: u2) bool {
    for (origin, 0..) |coordinate, axis| if (coordinate >= layout.size_in_blocks[axis]) return false;
    const rotated = blueprint.rotatedSize(size, rotation);
    if (rotated[0] == 0 or rotated[1] == 0 or rotated[2] == 0 or
        rotated[0] > blueprint.horizontalLimit(layout) or rotated[1] > blueprint.horizontalLimit(layout)) return false;
    return @as(u64, origin[1]) + rotated[1] <= layout.size_in_blocks[1] and
        @as(u64, origin[2]) + rotated[2] <= layout.size_in_blocks[2];
}

pub fn contains(layout: *const engine.WorldLayout, origin: Cell, size: blueprint.Size, rotation: u2, cell: Cell) bool {
    const rotated = blueprint.rotatedSize(size, rotation);
    const dx = (@as(u64, cell[0]) + layout.size_in_blocks[0] - origin[0]) % layout.size_in_blocks[0];
    return dx < rotated[0] and cell[1] >= origin[1] and @as(u64, cell[1]) < @as(u64, origin[1]) + rotated[1] and
        cell[2] >= origin[2] and @as(u64, cell[2]) < @as(u64, origin[2]) + rotated[2];
}

fn chunkId(layout: *const engine.WorldLayout, cell: Cell) ChunkId {
    return layout.encodeChunkCoords(.{ @intCast(cell[0] / chunk_size), @intCast(cell[1] / chunk_size), @intCast(cell[2] / chunk_size) });
}

pub fn boxChunks(allocator: std.mem.Allocator, layout: *const engine.WorldLayout, origin: Cell, size: blueprint.Size, rotation: u2) ![]ChunkId {
    if (!validFootprint(layout, origin, size, rotation)) return error.InvalidFootprint;
    const rotated = blueprint.rotatedSize(size, rotation);
    const low_x = origin[0] / chunk_size;
    const high_x = (@as(u64, origin[0]) + rotated[0] - 1) / chunk_size;
    var result: std.ArrayList(ChunkId) = .empty;
    errdefer result.deinit(allocator);
    var z = origin[2] / chunk_size;
    while (z <= (origin[2] + rotated[2] - 1) / chunk_size) : (z += 1) {
        var y = origin[1] / chunk_size;
        while (y <= (origin[1] + rotated[1] - 1) / chunk_size) : (y += 1) {
            var x: u64 = low_x;
            while (x <= high_x) : (x += 1) {
                const coords: engine.ChunkCoords = .{ @intCast(x % @as(u64, @intCast(layout.size_in_chunks[0]))), @intCast(y), @intCast(z) };
                try result.append(allocator, layout.encodeChunkCoords(coords));
            }
        }
    }
    return result.toOwnedSlice(allocator);
}

pub const State = struct {
    /// Immutable world layout; set by world/service init or first insertion.
    layout: ?*const engine.WorldLayout = null,
    definitions: std.AutoHashMapUnmanaged(u64, SavedDefinition) = .empty,
    instances: std.AutoHashMapUnmanaged(u64, Instance) = .empty,
    chunks: std.AutoHashMapUnmanaged(ChunkId, ChunkIndex) = .empty,
    cleanup_queue: std.ArrayList(u64) = .empty,
    cleanup_head: usize = 0,
    revision: u64 = 0,
    max_definition_id: u64 = 0,
    max_instance_id: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var definitions = self.definitions.valueIterator();
        while (definitions.next()) |definition| definition.deinit(allocator);
        self.definitions.deinit(allocator);
        var instances = self.instances.valueIterator();
        while (instances.next()) |instance| instance.deinit(allocator);
        self.instances.deinit(allocator);
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| chunk.deinit(allocator);
        self.chunks.deinit(allocator);
        self.cleanup_queue.deinit(allocator);
        self.* = .{};
    }

    pub fn targetAt(self: *const State, cell: Cell) ?Target {
        const layout = self.layout orelse return null;
        const chunk = self.chunks.get(chunkId(layout, cell)) orelse return null;
        return chunk.lookup.get(cell);
    }

    pub fn chunkTargets(self: *const State, id: ChunkId) []const Cell {
        return if (self.chunks.get(id)) |index| index.targets.items else &.{};
    }

    pub fn chunkInstances(self: *const State, id: ChunkId) []const u64 {
        return if (self.chunks.get(id)) |index| index.instances.items else &.{};
    }

    pub fn boxAt(self: *const State, layout: *const engine.WorldLayout, cell: Cell) ?u64 {
        for (self.chunkInstances(chunkId(layout, cell))) |id| {
            const instance = self.instances.get(id) orelse continue;
            if (!instance.active) continue;
            const definition = self.definitions.get(instance.definition_id) orelse continue;
            if (contains(layout, instance.origin, definition.definition.size, instance.rotation, cell)) return id;
        }
        return null;
    }

    /// Takes ownership only on success. Trusted in-process certification is not repeated.
    pub fn insertDefinition(self: *State, allocator: std.mem.Allocator, value: SavedDefinition) !void {
        if (value.id == 0 or self.definitions.contains(value.id)) return error.DuplicateDefinition;
        try self.definitions.put(allocator, value.id, value);
        self.max_definition_id = @max(self.max_definition_id, value.id);
        self.revision +%= 1;
    }

    pub fn prepareInstance(self: *const State, allocator: std.mem.Allocator, layout: *const engine.WorldLayout, id: u64, definition_id: u64, owner: u64, origin: Cell, rotation: u2) !Instance {
        const saved = self.definitions.get(definition_id) orelse return error.UnknownDefinition;
        if (saved.owner != owner) return error.WrongOwner;
        const box_chunks = try boxChunks(allocator, layout, origin, saved.definition.size, rotation);
        errdefer allocator.free(box_chunks);
        const bits = try allocator.alloc(u8, (saved.definition.cells.len + 7) / 8);
        @memset(bits, 0);
        return .{ .id = id, .definition_id = definition_id, .owner = owner, .origin = origin, .rotation = rotation, .fulfilled = bits, .remaining = saved.definition.target_count, .box_chunks = box_chunks };
    }

    pub fn overlaps(self: *const State, layout: *const engine.WorldLayout, candidate: Instance) bool {
        const saved = self.definitions.get(candidate.definition_id) orelse return true;
        const size = blueprint.rotatedSize(saved.definition.size, candidate.rotation);
        for (candidate.box_chunks) |chunk| for (self.chunkInstances(chunk)) |id| {
            const other = self.instances.get(id) orelse continue;
            if (!other.active) continue;
            const other_definition = self.definitions.get(other.definition_id) orelse return true;
            const other_size = blueprint.rotatedSize(other_definition.definition.size, other.rotation);
            if (@as(u64, candidate.origin[1]) >= @as(u64, other.origin[1]) + other_size[1] or
                @as(u64, other.origin[1]) >= @as(u64, candidate.origin[1]) + size[1] or
                @as(u64, candidate.origin[2]) >= @as(u64, other.origin[2]) + other_size[2] or
                @as(u64, other.origin[2]) >= @as(u64, candidate.origin[2]) + size[2]) continue;
            const delta = (@as(u64, other.origin[0]) + layout.size_in_blocks[0] - candidate.origin[0]) % layout.size_in_blocks[0];
            const reverse = (@as(u64, candidate.origin[0]) + layout.size_in_blocks[0] - other.origin[0]) % layout.size_in_blocks[0];
            if (delta < size[0] or reverse < other_size[0]) return true;
        };
        return false;
    }

    /// Reserve the complete target/index publication before inserting any planned cell.
    /// Empty capacity-only chunk entries on failure do not enforce any restriction.
    pub fn reserveInstance(self: *State, allocator: std.mem.Allocator, layout: *const engine.WorldLayout, instance: Instance) !void {
        self.layout = layout;
        if (instance.id == 0 or self.instances.contains(instance.id)) return error.DuplicateInstance;
        const saved = self.definitions.get(instance.definition_id) orelse return error.UnknownDefinition;
        if (self.overlaps(layout, instance)) return error.Overlap;
        try self.instances.ensureUnusedCapacity(allocator, 1);
        try self.chunks.ensureUnusedCapacity(allocator, @intCast(instance.box_chunks.len));
        // Each admitted instance reserves its eventual O(1) retirement enqueue.
        try self.cleanup_queue.ensureTotalCapacity(allocator, self.cleanup_queue.items.len + self.instances.count() + 1);
        var counts: std.AutoHashMapUnmanaged(ChunkId, usize) = .empty;
        defer counts.deinit(allocator);
        for (saved.definition.cells, 0..) |material, index| {
            if (material == .none or instance.isFulfilled(index)) continue;
            const cell = worldCell(layout, instance.origin, saved.definition.size, instance.rotation, blueprint.cellAtIndex(saved.definition.size, index)) orelse return error.InvalidFootprint;
            if (self.targetAt(cell) != null) return error.Overlap;
            const entry = try counts.getOrPut(allocator, chunkId(layout, cell));
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
        for (instance.box_chunks) |id| {
            const entry = try self.chunks.getOrPut(allocator, id);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            try entry.value_ptr.instances.ensureUnusedCapacity(allocator, 1);
            try entry.value_ptr.targets.ensureUnusedCapacity(allocator, counts.get(id) orelse 0);
            try entry.value_ptr.lookup.ensureUnusedCapacity(allocator, @intCast(counts.get(id) orelse 0));
        }
    }

    /// Matching reserveInstance must have completed without intervening mutation.
    pub fn insertInstancePrepared(self: *State, layout: *const engine.WorldLayout, instance: Instance) void {
        const saved = self.definitions.get(instance.definition_id).?;
        for (instance.box_chunks) |id| self.chunks.getPtr(id).?.instances.appendAssumeCapacity(instance.id);
        for (saved.definition.cells, 0..) |material, index| {
            if (material == .none or instance.isFulfilled(index)) continue;
            const cell = worldCell(layout, instance.origin, saved.definition.size, instance.rotation, blueprint.cellAtIndex(saved.definition.size, index)).?;
            const chunk = self.chunks.getPtr(chunkId(layout, cell)).?;
            chunk.lookup.putAssumeCapacity(cell, .{ .instance_id = instance.id, .cell_index = @intCast(index), .material = material, .chunk_slot = chunk.targets.items.len });
            chunk.targets.appendAssumeCapacity(cell);
        }
        self.instances.putAssumeCapacity(instance.id, instance);
        self.max_instance_id = @max(self.max_instance_id, instance.id);
        self.revision +%= 1;
    }

    pub fn insertInstance(self: *State, allocator: std.mem.Allocator, layout: *const engine.WorldLayout, instance: Instance) !void {
        try self.reserveInstance(allocator, layout, instance);
        self.insertInstancePrepared(layout, instance);
    }

    /// Capacity preparation only; never visits definition cells or target entries.
    pub fn reservePublication(self: *State, allocator: std.mem.Allocator, layout: *const engine.WorldLayout, prepared: *const PreparedPublication) !void {
        if (prepared.published or prepared.instance.id == 0 or self.instances.contains(prepared.instance.id)) return error.DuplicateInstance;
        if (!self.definitions.contains(prepared.instance.definition_id)) return error.UnknownDefinition;
        if (self.overlaps(layout, prepared.instance)) return error.Overlap;
        self.layout = layout;
        try self.instances.ensureUnusedCapacity(allocator, 1);
        try self.chunks.ensureUnusedCapacity(allocator, @intCast(prepared.chunks.count()));
        try self.cleanup_queue.ensureTotalCapacity(allocator, self.cleanup_queue.items.len + self.instances.count() + 1);
    }

    /// Caller rechecks terrain dependencies and the overlay epoch after helper
    /// preparation. One chunk-record swap per footprint chunk, with no target scan.
    /// Replaced records remain owned by `prepared` for deferred reclamation.
    pub fn publishPublication(self: *State, prepared: *PreparedPublication) void {
        std.debug.assert(!prepared.published);
        var iterator = prepared.chunks.iterator();
        while (iterator.next()) |replacement| {
            const current = self.chunks.getOrPutAssumeCapacity(replacement.key_ptr.*);
            const old = if (current.found_existing) current.value_ptr.* else ChunkIndex{};
            current.value_ptr.* = replacement.value_ptr.*;
            replacement.value_ptr.* = old;
        }
        const instance = prepared.instance;
        self.instances.putAssumeCapacity(instance.id, instance);
        self.max_instance_id = @max(self.max_instance_id, instance.id);
        self.revision +%= 1;
        prepared.published = true;
    }

    /// No allocation, instance scan, or structural validation. Swap-removal keeps
    /// visible-chunk target traversal proportional to remaining miniatures.
    pub fn fulfill(self: *State, layout: *const engine.WorldLayout, value: Fulfill) bool {
        const instance = self.instances.getPtr(value.instance_id) orelse return false;
        if (!instance.active) return false;
        const saved = self.definitions.get(instance.definition_id) orelse return false;
        if (value.cell_index >= saved.definition.cells.len or saved.definition.cells[value.cell_index] == .none or instance.isFulfilled(value.cell_index)) return false;
        const cell = worldCell(layout, instance.origin, saved.definition.size, instance.rotation, blueprint.cellAtIndex(saved.definition.size, value.cell_index)) orelse return false;
        const chunk = self.chunks.getPtr(chunkId(layout, cell)).?;
        _ = chunk.removeTarget(cell) orelse return false;
        instance.fulfilled[value.cell_index / 8] |= @as(u8, 1) << @as(u3, @intCast(value.cell_index % 8));
        instance.remaining -= 1;
        if (instance.remaining == 0) {
            instance.active = false;
            self.cleanup_queue.appendAssumeCapacity(instance.id);
        }
        self.revision +%= 1;
        return true;
    }

    /// Bounded deferred retirement, separate from fulfillment and completion.
    pub fn cleanup(self: *State, allocator: std.mem.Allocator, chunk_budget: usize) void {
        var budget = chunk_budget;
        while (budget != 0 and self.cleanup_head < self.cleanup_queue.items.len) {
            const id = self.cleanup_queue.items[self.cleanup_head];
            const instance = self.instances.getPtr(id) orelse {
                self.cleanup_head += 1;
                continue;
            };
            while (budget != 0 and instance.cleanup_cursor < instance.box_chunks.len) {
                const chunk_id = instance.box_chunks[instance.cleanup_cursor];
                if (self.chunks.getPtr(chunk_id)) |chunk| {
                    if (std.mem.indexOfScalar(u64, chunk.instances.items, id)) |slot| _ = chunk.instances.swapRemove(slot);
                    if (chunk.instances.items.len == 0 and chunk.targets.items.len == 0) {
                        var removed = self.chunks.fetchRemove(chunk_id).?.value;
                        removed.deinit(allocator);
                    }
                }
                instance.cleanup_cursor += 1;
                // Detached publication snapshots include these index records.
                // Retiring an inactive box must invalidate their overlay epoch.
                self.revision +%= 1;
                budget -= 1;
            }
            if (instance.cleanup_cursor == instance.box_chunks.len) {
                var removed = self.instances.fetchRemove(id).?.value;
                removed.deinit(allocator);
                self.cleanup_head += 1;
            }
        }
        if (self.cleanup_head == self.cleanup_queue.items.len) {
            self.cleanup_queue.clearRetainingCapacity();
            self.cleanup_head = 0;
        }
    }

    pub fn collectAffected(self: *const State, allocator: std.mem.Allocator, layout: *const engine.WorldLayout, target: Cell, real: []const rules.Cell) ![]rules.Cell {
        var unique: std.AutoHashMapUnmanaged(rules.Cell, void) = .empty;
        defer unique.deinit(allocator);
        for (real) |cell| try unique.put(allocator, cell, {});
        const center: rules.Cell = .{ target[0], target[1], target[2] };
        const radius = rules.Limits.support_radius;
        var z = @divFloor(center[2] - radius, chunk_size);
        while (z <= @divFloor(center[2] + radius, chunk_size)) : (z += 1) {
            var y = @divFloor(center[1] - radius, chunk_size);
            while (y <= @divFloor(center[1] + radius, chunk_size)) : (y += 1) {
                var x = @divFloor(center[0] - radius, chunk_size);
                while (x <= @divFloor(center[0] + radius, chunk_size)) : (x += 1) {
                    const coords = layout.normalizeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) }) orelse continue;
                    for (self.chunkTargets(layout.encodeChunkCoords(coords))) |cell| {
                        const signed: rules.Cell = .{ cell[0], cell[1], cell[2] };
                        if (rules.distance(layout, signed, center) <= radius) try unique.put(allocator, signed, {});
                    }
                }
            }
        }
        const result = try allocator.alloc(rules.Cell, unique.count());
        var iterator = unique.keyIterator();
        var i: usize = 0;
        while (iterator.next()) |cell| : (i += 1) result[i] = cell.*;
        const Order = struct {
            layout: *const engine.WorldLayout,
            center: rules.Cell,
            fn less(context: @This(), a: rules.Cell, b: rules.Cell) bool {
                const da = rules.displacement(context.layout, a, context.center);
                const db = rules.displacement(context.layout, b, context.center);
                inline for (.{ 2, 1, 0 }) |axis| if (da[axis] != db[axis]) return da[axis] < db[axis];
                return false;
            }
        };
        std.mem.sort(rules.Cell, result, Order{ .layout = layout, .center = center }, Order.less);
        return result;
    }
};

pub const CompletedReader = struct {
    physical: rules.Reader,
    state: *const State,

    pub fn reader(self: *CompletedReader) rules.Reader {
        var result = self.physical;
        result.context = self;
        result.block_at = read;
        result.custom_shape_at = shape;
        result.immutable_at = immutable;
        return result;
    }

    fn read(context: *anyopaque, cell: Cell) ?rules.BlockType {
        const self: *CompletedReader = @ptrCast(@alignCast(context));
        const actual = self.physical.get(.{ cell[0], cell[1], cell[2] }) orelse return null;
        return if (self.state.targetAt(cell)) |target| target.material else actual;
    }

    fn shape(context: *anyopaque, cell: Cell) ?engine.voxel_chunk.custom_block.Shape {
        const self: *CompletedReader = @ptrCast(@alignCast(context));
        return if (self.physical.custom_shape_at) |get| get(self.physical.context, cell) else null;
    }

    fn immutable(context: *anyopaque, cell: Cell) bool {
        const self: *CompletedReader = @ptrCast(@alignCast(context));
        return self.physical.isImmutable(.{ cell[0], cell[1], cell[2] });
    }
};
