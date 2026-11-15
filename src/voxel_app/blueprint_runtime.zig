//! Mutable libraries and construction indexes. Structural semantics live in
//! blueprint/block_rules; this module never searches support on fulfillment.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const rules = @import("block_rules.zig");
const ChunkId = @import("consts.zig").ChunkId;
const chunk_size = @import("consts.zig").CHUNK_SIZE;
pub const Cell = [3]u32;
pub const Phase = @import("construction_state.zig").Phase;
pub const Identity = @import("construction_state.zig").Identity;
pub const ObjectKind = @import("construction_state.zig").ObjectKind;
pub const StorageOwner = @import("construction_state.zig").StorageOwner;

/// Rebuildable grouping, never an independent target-membership authority.
pub const TargetGroup = struct {
    chunk_id: ChunkId,
    first: u32,
    count: u32,
    transferred: bool = false,
    terrain_revision: u64 = 0,
};

pub const Transfer = struct { instance_id: u64, chunk_id: ChunkId, terrain_revision: u64 };
pub const Completion = struct { instance_id: u64, completion_tick: u64 = 0 };

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
    phase: Phase = .building,
    revision: u64 = 0,
    lifetime: u64 = 0,
    box_chunks: []ChunkId,
    target_groups: []TargetGroup = &.{},
    target_indices: []u32 = &.{},
    remaining_groups: u32 = 0,
    cleanup_cursor: usize = 0,

    pub fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        allocator.free(self.fulfilled);
        allocator.free(self.box_chunks);
        allocator.free(self.target_groups);
        allocator.free(self.target_indices);
        self.* = undefined;
    }

    pub fn estimatedOwnedBytes(self: Instance) usize {
        return self.fulfilled.len +| self.box_chunks.len *| @sizeOf(ChunkId) +|
            self.target_groups.len *| @sizeOf(TargetGroup) +| self.target_indices.len *| @sizeOf(u32);
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
        errdefer allocator.free(copy.box_chunks);
        copy.target_groups = try allocator.dupe(TargetGroup, self.target_groups);
        errdefer allocator.free(copy.target_groups);
        copy.target_indices = try allocator.dupe(u32, self.target_indices);
        return copy;
    }

    pub fn groupIndex(self: Instance, id: ChunkId) ?usize {
        var low: usize = 0;
        var high = self.target_groups.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const group = self.target_groups[middle];
            if (group.chunk_id == id) return middle;
            if (group.chunk_id < id) low = middle + 1 else high = middle;
        }
        return null;
    }

    pub fn targetsOfGroup(self: Instance, group: TargetGroup) []const u32 {
        return self.target_indices[group.first..][0..group.count];
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
    retired_instance: ?Instance = null,

    pub fn estimatedOwnedBytes(self: *const PreparedPublication) usize {
        var bytes = estimatedMapBytes(ChunkId, ChunkIndex, self.chunks.capacity());
        if (!self.published) bytes +|= self.instance.estimatedOwnedBytes();
        if (self.retired_instance) |instance| bytes +|= instance.estimatedOwnedBytes();
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| bytes +|= chunk.estimatedOwnedBytes();
        return bytes;
    }

    pub fn deinit(self: *PreparedPublication, allocator: std.mem.Allocator) void {
        if (!self.published) self.instance.deinit(allocator);
        if (self.retired_instance) |*instance| instance.deinit(allocator);
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
    return buildPublicationReplacing(allocator, layout, definition, instance, source, fulfillments, null, null);
}

/// Replaces progress for the same immutable descriptor/lifetime. All old
/// footprint sources remain untouched until publication succeeds. A different
/// completed source may retain pending entries after a missed final update;
/// only those entries can yield to the snapshot before bounded source cleanup.
pub fn buildSnapshotPublication(allocator: std.mem.Allocator, layout: *const engine.WorldLayout, definition: blueprint.Definition, instance: Instance, source: *const State) !PreparedPublication {
    try validateSnapshot(layout, definition, instance);
    return buildPublicationReplacing(allocator, layout, definition, instance, &source.chunks, null, instance.id, source);
}

/// Full/resync snapshots are uncommon and validate their complete payload once.
/// Routine deltas use the allocation-free, bounded local transition APIs.
pub fn validateSnapshot(layout: *const engine.WorldLayout, definition: blueprint.Definition, instance: Instance) !void {
    if (instance.id == 0 or instance.lifetime != instance.id or !validFootprint(layout, instance.origin, definition.size, instance.rotation) or instance.active != (instance.phase != .complete) or instance.fulfilled.len != (definition.cells.len + 7) / 8 or instance.target_indices.len != definition.target_count) return error.InvalidConstructionSnapshot;
    if (definition.cells.len % 8 != 0 and instance.fulfilled[instance.fulfilled.len - 1] >> @as(u3, @intCast(definition.cells.len % 8)) != 0) return error.InvalidConstructionSnapshot;
    var remaining = definition.target_count;
    for (definition.cells, 0..) |material, index| if (instance.isFulfilled(index)) {
        if (material == .none) return error.InvalidConstructionSnapshot;
        remaining -= 1;
    };
    if (instance.remaining != remaining or (remaining != 0) != (instance.phase == .building)) return error.InvalidConstructionSnapshot;
    var count: usize = 0;
    var remaining_groups: u32 = 0;
    for (instance.target_groups, 0..) |group, group_slot| {
        if (group.count == 0 or group.first != count or group.count > instance.target_indices.len - count or (group_slot != 0 and instance.target_groups[group_slot - 1].chunk_id >= group.chunk_id) or group.transferred != (group.terrain_revision != 0) or (instance.phase == .building and group.transferred)) return error.InvalidConstructionSnapshot;
        if (!group.transferred) remaining_groups += 1;
        var previous: ?u32 = null;
        for (instance.targetsOfGroup(group)) |index| {
            if (index >= definition.cells.len or definition.cells[index] == .none or (previous != null and previous.? >= index)) return error.InvalidConstructionSnapshot;
            const cell = worldCell(layout, instance.origin, definition.size, instance.rotation, blueprint.cellAtIndex(definition.size, index)).?;
            if (chunkId(layout, cell) != group.chunk_id) return error.InvalidConstructionSnapshot;
            previous = index;
        }
        count += group.count;
    }
    if (count != definition.target_count or instance.remaining_groups != remaining_groups or (instance.phase == .complete and remaining_groups != 0)) return error.InvalidConstructionSnapshot;
    const expected_revision = @as(u64, definition.target_count - remaining) + instance.target_groups.len - remaining_groups + @intFromBool(instance.phase == .complete);
    if (instance.revision != expected_revision) return error.InvalidConstructionSnapshot;
    // Footprint discovery itself is immutable and must cover the exact box,
    // including box-only chunks. Enumeration needs no temporary allocation.
    const rotated = blueprint.rotatedSize(definition.size, instance.rotation);
    var box_count: usize = 0;
    var z = instance.origin[2] / chunk_size;
    while (z <= (instance.origin[2] + rotated[2] - 1) / chunk_size) : (z += 1) {
        var y = instance.origin[1] / chunk_size;
        while (y <= (instance.origin[1] + rotated[1] - 1) / chunk_size) : (y += 1) {
            var x: u64 = instance.origin[0] / chunk_size;
            while (x <= (@as(u64, instance.origin[0]) + rotated[0] - 1) / chunk_size) : (x += 1) {
                const expected = layout.encodeChunkCoords(.{ @intCast(x % @as(u64, @intCast(layout.size_in_chunks[0]))), @intCast(y), @intCast(z) });
                if (box_count >= instance.box_chunks.len or instance.box_chunks[box_count] != expected) return error.InvalidConstructionSnapshot;
                box_count += 1;
            }
        }
    }
    if (box_count != instance.box_chunks.len) return error.InvalidConstructionSnapshot;
}

fn buildPublicationReplacing(allocator: std.mem.Allocator, layout: *const engine.WorldLayout, definition: blueprint.Definition, instance: Instance, source: *const std.AutoHashMapUnmanaged(ChunkId, ChunkIndex), fulfillments: ?*const FulfillmentSet, replacing: ?u64, retained: ?*const State) !PreparedPublication {
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
        if (replacing) |old_id| {
            var target_slot: usize = 0;
            while (target_slot < index.targets.items.len) {
                const cell = index.targets.items[target_slot];
                if (index.lookup.get(cell).?.instance_id == old_id) {
                    _ = index.removeTarget(cell);
                } else target_slot += 1;
            }
            if (std.mem.indexOfScalar(u64, index.instances.items, old_id)) |old_slot| _ = index.instances.swapRemove(old_slot);
        }
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
        if (chunk.lookup.get(cell)) |old_target| {
            const old = if (retained) |state| state.instances.get(old_target.instance_id) else null;
            if (old == null or old.?.active or old.?.phase != .complete) return error.Overlap;
            _ = chunk.removeTarget(cell);
        }
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
    transfer: Transfer,
    complete: Completion,

    pub fn deinit(self: *Change, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .definition => |*value| value.deinit(allocator),
            .instance => |*value| value.deinit(allocator),
            .fulfill, .transfer, .complete => {},
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

/// Exact inverse of worldCell, including the unique wrapped-X image.
pub fn definitionIndex(layout: *const engine.WorldLayout, origin: Cell, size: blueprint.Size, rotation: u2, cell: Cell) ?u32 {
    if (!contains(layout, origin, size, rotation, cell)) return null;
    const x: u32 = @intCast((@as(u64, cell[0]) + layout.size_in_blocks[0] - origin[0]) % layout.size_in_blocks[0]);
    const y = cell[1] - origin[1];
    const xy: [2]u32 = switch (rotation) {
        0 => .{ x, y },
        1 => .{ size[0] - 1 - y, x },
        2 => .{ size[0] - 1 - x, size[1] - 1 - y },
        3 => .{ y, size[1] - 1 - x },
    };
    return @intCast(blueprint.linearIndex(size, .{ xy[0], xy[1], cell[2] - origin[2] }).?);
}

const Grouping = struct { groups: []TargetGroup, indices: []u32 };

fn prepareGroups(allocator: std.mem.Allocator, layout: *const engine.WorldLayout, definition: blueprint.Definition, origin: Cell, rotation: u2) !Grouping {
    var counts: std.AutoHashMapUnmanaged(ChunkId, u32) = .empty;
    defer counts.deinit(allocator);
    for (definition.cells, 0..) |material, index| {
        if (material == .none) continue;
        const cell = worldCell(layout, origin, definition.size, rotation, blueprint.cellAtIndex(definition.size, index)) orelse return error.InvalidFootprint;
        const entry = try counts.getOrPut(allocator, chunkId(layout, cell));
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    const groups = try allocator.alloc(TargetGroup, counts.count());
    errdefer allocator.free(groups);
    var keys = counts.keyIterator();
    var slot: usize = 0;
    while (keys.next()) |id| : (slot += 1) groups[slot] = .{ .chunk_id = id.*, .first = 0, .count = counts.get(id.*).? };
    const Order = struct {
        fn less(_: void, a: TargetGroup, b: TargetGroup) bool {
            return a.chunk_id < b.chunk_id;
        }
    };
    std.mem.sort(TargetGroup, groups, {}, Order.less);
    var total: u32 = 0;
    for (groups, 0..) |*group, group_slot| {
        group.first = total;
        total += group.count;
        // Reuse the count map as a chunk-to-group cursor directory.
        counts.getPtr(group.chunk_id).?.* = @intCast(group_slot);
    }
    const indices = try allocator.alloc(u32, total);
    errdefer allocator.free(indices);
    const cursors = try allocator.alloc(u32, groups.len);
    defer allocator.free(cursors);
    @memset(cursors, 0);
    for (definition.cells, 0..) |material, index| {
        if (material == .none) continue;
        const cell = worldCell(layout, origin, definition.size, rotation, blueprint.cellAtIndex(definition.size, index)).?;
        const group_slot = counts.get(chunkId(layout, cell)).?;
        indices[groups[group_slot].first + cursors[group_slot]] = @intCast(index);
        cursors[group_slot] += 1;
    }
    return .{ .groups = groups, .indices = indices };
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

/// Requested native capacity estimate, including hash metadata/alignment padding.
/// Allocator pages, allocator bookkeeping and process RSS are outside this policy.
pub fn estimatedMapBytes(comptime K: type, comptime V: type, capacity: usize) usize {
    return capacity *| (@sizeOf(K) + @sizeOf(V) + 1) +| (if (capacity == 0) @as(usize, 0) else 64);
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

    pub fn estimatedOwnedBytes(self: *const State) usize {
        var bytes = estimatedMapBytes(u64, SavedDefinition, self.definitions.capacity()) +|
            estimatedMapBytes(u64, Instance, self.instances.capacity()) +|
            estimatedMapBytes(ChunkId, ChunkIndex, self.chunks.capacity()) +|
            self.cleanup_queue.capacity *| @sizeOf(u64);
        var definitions = self.definitions.valueIterator();
        while (definitions.next()) |definition| bytes +|= definition.name.len +| definition.definition.cells.len;
        var instances = self.instances.valueIterator();
        while (instances.next()) |instance| bytes +|= instance.estimatedOwnedBytes();
        var chunks = self.chunks.valueIterator();
        while (chunks.next()) |chunk| bytes +|= chunk.estimatedOwnedBytes();
        return bytes;
    }

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

    pub const Member = struct { target: Target, fulfilled: bool, owner: StorageOwner };
    pub const Physical = union(enum) { unowned, unknown, material: rules.BlockType };

    /// Membership lasts through materialization and never depends on pending
    /// lookup entries. The chunk directory bounds candidate discovery.
    pub fn memberAt(self: *const State, cell: Cell) ?Member {
        const layout = self.layout orelse return null;
        const id = chunkId(layout, cell);
        for (self.chunkInstances(id)) |instance_id| {
            const instance = self.instances.get(instance_id) orelse continue;
            if (!instance.active) continue;
            const definition = self.definitions.get(instance.definition_id) orelse continue;
            const index = definitionIndex(layout, instance.origin, definition.definition.size, instance.rotation, cell) orelse continue;
            const material = definition.definition.cells[index];
            if (material == .none) continue;
            const transferred = if (instance.groupIndex(id)) |group_slot| instance.target_groups[group_slot].transferred else false;
            return .{ .target = .{ .instance_id = instance.id, .cell_index = index, .material = material }, .fulfilled = instance.isFulfilled(index), .owner = if (transferred) .world_data else .simulation };
        }
        return null;
    }

    /// A missing source behind discovery is unknown, never permission to use
    /// raw air. Transferred portions defer to the matching terrain snapshot.
    pub fn physicalAt(self: *const State, cell: Cell) Physical {
        const layout = self.layout orelse return .unowned;
        const id = chunkId(layout, cell);
        for (self.chunkInstances(id)) |instance_id| {
            const instance = self.instances.get(instance_id) orelse return .unknown;
            if (!instance.active) continue;
            const definition = self.definitions.get(instance.definition_id) orelse return .unknown;
            const index = definitionIndex(layout, instance.origin, definition.definition.size, instance.rotation, cell) orelse continue;
            const material = definition.definition.cells[index];
            if (material == .none) continue;
            const group_slot = instance.groupIndex(id) orelse return .unknown;
            if (instance.target_groups[group_slot].transferred) return .unowned;
            return .{ .material = if (instance.isFulfilled(index)) material else .none };
        }
        return .unowned;
    }

    /// Enumerators must include fulfilled simulation targets in addition to
    /// ordinary terrain provenance. Only target-bearing chunk groups are read.
    pub fn appendConstructed(self: *const State, allocator: std.mem.Allocator, id: ChunkId, out: *std.ArrayList(rules.Cell)) !void {
        const layout = self.layout orelse return;
        for (self.chunkInstances(id)) |instance_id| {
            const instance = self.instances.get(instance_id) orelse return error.UnknownConstruction;
            if (!instance.active) continue;
            const definition = self.definitions.get(instance.definition_id) orelse return error.UnknownDefinition;
            const group_slot = instance.groupIndex(id) orelse continue;
            const group = instance.target_groups[group_slot];
            if (group.transferred) continue;
            for (instance.targetsOfGroup(group)) |index| if (instance.isFulfilled(index)) {
                const cell = worldCell(layout, instance.origin, definition.definition.size, instance.rotation, blueprint.cellAtIndex(definition.definition.size, index)).?;
                try out.append(allocator, .{ cell[0], cell[1], cell[2] });
            };
        }
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
        errdefer allocator.free(bits);
        @memset(bits, 0);
        const grouping = try prepareGroups(allocator, layout, saved.definition, origin, rotation);
        return .{ .id = id, .definition_id = definition_id, .owner = owner, .origin = origin, .rotation = rotation, .fulfilled = bits, .remaining = saved.definition.target_count, .box_chunks = box_chunks, .lifetime = id, .target_groups = grouping.groups, .target_indices = grouping.indices, .remaining_groups = @intCast(grouping.groups.len) };
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

    /// Preparation retains ownership on failure. A newer snapshot for an
    /// existing lifetime may replace its derived pending indexes atomically.
    pub fn reserveSnapshotPublication(self: *State, allocator: std.mem.Allocator, layout: *const engine.WorldLayout, prepared: *const PreparedPublication) !void {
        const definition = self.definitions.get(prepared.instance.definition_id) orelse return error.UnknownDefinition;
        if (definition.owner != prepared.instance.owner) return error.ConflictingSnapshot;
        const old = self.instances.get(prepared.instance.id) orelse return self.reservePublication(allocator, layout, prepared);
        if (prepared.published or old.definition_id != prepared.instance.definition_id or old.owner != prepared.instance.owner or old.rotation != prepared.instance.rotation or !std.mem.eql(u32, &old.origin, &prepared.instance.origin) or old.lifetime != prepared.instance.lifetime or prepared.instance.revision <= old.revision) return error.ConflictingSnapshot;
        if (old.phase == .complete or @intFromEnum(prepared.instance.phase) < @intFromEnum(old.phase)) return error.ConflictingSnapshot;
        for (old.fulfilled, prepared.instance.fulfilled) |before, after| if (before & after != before) return error.ConflictingSnapshot;
        for (old.target_groups, prepared.instance.target_groups) |before, after| if (before.transferred and (!after.transferred or before.terrain_revision != after.terrain_revision)) return error.ConflictingSnapshot;
        self.layout = layout;
        try self.chunks.ensureUnusedCapacity(allocator, @intCast(prepared.chunks.count()));
        try self.cleanup_queue.ensureTotalCapacity(allocator, self.cleanup_queue.items.len + self.instances.count() + 1);
    }

    pub fn publishSnapshotPublication(self: *State, prepared: *PreparedPublication) void {
        if (self.instances.fetchRemove(prepared.instance.id)) |old| prepared.retired_instance = old.value;
        self.publishPublication(prepared);
        if (!prepared.instance.active) self.cleanup_queue.appendAssumeCapacity(prepared.instance.id);
    }

    /// No allocation, instance scan, or structural validation. Swap-removal keeps
    /// visible-chunk target traversal proportional to remaining miniatures.
    pub fn fulfill(self: *State, layout: *const engine.WorldLayout, value: Fulfill) bool {
        const instance = self.instances.getPtr(value.instance_id) orelse return false;
        if (!instance.active or instance.phase != .building or instance.revision == std.math.maxInt(u64)) return false;
        const saved = self.definitions.get(instance.definition_id) orelse return false;
        if (value.cell_index >= saved.definition.cells.len or saved.definition.cells[value.cell_index] == .none or instance.isFulfilled(value.cell_index)) return false;
        const cell = worldCell(layout, instance.origin, saved.definition.size, instance.rotation, blueprint.cellAtIndex(saved.definition.size, value.cell_index)) orelse return false;
        const chunk = self.chunks.getPtr(chunkId(layout, cell)).?;
        _ = chunk.removeTarget(cell) orelse return false;
        instance.fulfilled[value.cell_index / 8] |= @as(u8, 1) << @as(u3, @intCast(value.cell_index % 8));
        instance.remaining -= 1;
        if (instance.remaining == 0) {
            instance.phase = .materializing;
        }
        instance.revision += 1;
        self.revision +%= 1;
        return true;
    }

    /// Destination terrain and provenance must already be prepared. The caller
    /// commits this alongside that patch on the same executor without yielding.
    pub fn acceptTransfer(self: *State, value: Transfer) bool {
        const instance = self.instances.getPtr(value.instance_id) orelse return false;
        if (!instance.active or instance.phase != .materializing or instance.revision == std.math.maxInt(u64) or value.terrain_revision == 0) return false;
        const group_slot = instance.groupIndex(value.chunk_id) orelse return false;
        const group = &instance.target_groups[group_slot];
        if (group.transferred) return false;
        group.transferred = true;
        group.terrain_revision = value.terrain_revision;
        instance.remaining_groups -= 1;
        instance.revision += 1;
        self.revision +%= 1;
        return true;
    }

    /// Grass-initialization obligations/publication must be reserved before this
    /// transition. Client render retention has its own lifetime after retirement.
    pub fn complete(self: *State, instance_id: u64) bool {
        const instance = self.instances.getPtr(instance_id) orelse return false;
        if (!instance.active or instance.phase != .materializing or instance.remaining_groups != 0 or instance.revision == std.math.maxInt(u64)) return false;
        instance.phase = .complete;
        instance.active = false;
        instance.revision += 1;
        self.cleanup_queue.appendAssumeCapacity(instance.id);
        self.revision +%= 1;
        return true;
    }

    /// Return only soil-bearing target chunks using already prepared groups.
    /// Call before complete/cleanup to prepare world-data's persistent work.
    pub fn appendSoilGroups(self: *const State, allocator: std.mem.Allocator, instance_id: u64, out: *std.ArrayList(ChunkId)) !void {
        const instance = self.instances.get(instance_id) orelse return error.UnknownConstruction;
        const definition = self.definitions.get(instance.definition_id) orelse return error.UnknownDefinition;
        for (instance.target_groups) |group| {
            for (instance.targetsOfGroup(group)) |index| if (definition.definition.cells[index] == .dirt) {
                try out.append(allocator, group.chunk_id);
                break;
            };
        }
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
                    // Terminal client retirement can skip the final fills.
                    // Visit only this site's prepared group, and preserve any
                    // newer snapshot's target at the same cell. Authoritative
                    // completion already removed all pending entries.
                    if (instance.remaining != 0) if (instance.groupIndex(chunk_id)) |group_slot| {
                        const definition = self.definitions.get(instance.definition_id).?.definition;
                        for (instance.targetsOfGroup(instance.target_groups[group_slot])) |index| {
                            if (instance.isFulfilled(index)) continue;
                            const cell = worldCell(self.layout.?, instance.origin, definition.size, instance.rotation, blueprint.cellAtIndex(definition.size, index)).?;
                            const target = chunk.lookup.get(cell) orelse continue;
                            if (target.instance_id == id) _ = chunk.removeTarget(cell);
                        }
                    };
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

    /// CLIENT CACHE ONLY. The authoritative simulation must use complete and
    /// cleanup. The caller has released every subscription/gameplay dependency
    /// and keeps the lifetime unavailable until eviction and any resync finish.
    /// Return true when the cache record is gone; preserve immutable definitions
    /// and ID highwaters so eviction cannot revive an old authoritative lifetime.
    pub fn evictCachedInstance(self: *State, allocator: std.mem.Allocator, instance_id: u64, chunk_budget: usize) bool {
        const instance = self.instances.getPtr(instance_id) orelse return true;
        var budget = chunk_budget;
        while (budget != 0 and instance.cleanup_cursor < instance.box_chunks.len) : (budget -= 1) {
            const id = instance.box_chunks[instance.cleanup_cursor];
            if (self.chunks.getPtr(id)) |chunk| {
                var slot: usize = 0;
                while (slot < chunk.targets.items.len) {
                    const cell = chunk.targets.items[slot];
                    if (chunk.lookup.get(cell).?.instance_id == instance_id) {
                        _ = chunk.removeTarget(cell);
                    } else slot += 1;
                }
                if (std.mem.indexOfScalar(u64, chunk.instances.items, instance_id)) |position| _ = chunk.instances.swapRemove(position);
                if (chunk.instances.items.len == 0 and chunk.targets.items.len == 0) {
                    var removed = self.chunks.fetchRemove(id).?.value;
                    removed.deinit(allocator);
                }
            }
            instance.cleanup_cursor += 1;
            self.revision +%= 1;
        }
        if (instance.cleanup_cursor != instance.box_chunks.len) return false;
        var removed = self.instances.fetchRemove(instance_id).?.value;
        removed.deinit(allocator);
        return true;
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
                    const id = layout.encodeChunkCoords(coords);
                    for (self.chunkInstances(id)) |instance_id| {
                        const instance = self.instances.get(instance_id) orelse return error.UnknownConstruction;
                        if (!instance.active) continue;
                        const definition = self.definitions.get(instance.definition_id) orelse return error.UnknownDefinition;
                        const group_slot = instance.groupIndex(id) orelse continue;
                        const group = instance.target_groups[group_slot];
                        if (group.transferred) continue;
                        for (instance.targetsOfGroup(group)) |index| if (instance.isFulfilled(index)) {
                            const cell = worldCell(layout, instance.origin, definition.definition.size, instance.rotation, blueprint.cellAtIndex(definition.definition.size, index)).?;
                            const signed: rules.Cell = .{ cell[0], cell[1], cell[2] };
                            if (rules.distance(layout, signed, center) <= radius) try unique.put(allocator, signed, {});
                        };
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

test "target authority survives fulfillment and transfers independently by chunk" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var state: State = .{ .layout = &layout };
    defer state.deinit(a);
    try state.insertDefinition(a, .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Sparse"), .definition = .{ .size = .{ 3, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{ .dirt, .none, .planks }), .target_count = 2 } });
    const instance = try state.prepareInstance(a, &layout, 1, 1, 1, .{ 127, 10, 10 }, 0);
    try state.insertInstance(a, &layout, instance);
    try std.testing.expectEqual(@as(usize, 2), instance.target_groups.len);
    try std.testing.expectEqual(rules.BlockType.none, state.physicalAt(.{ 127, 10, 10 }).material);
    try std.testing.expect(state.memberAt(.{ 0, 10, 10 }) == null);
    const native_before = state.estimatedOwnedBytes();
    try std.testing.expect(instance.estimatedOwnedBytes() >= instance.fulfilled.len + instance.box_chunks.len * @sizeOf(ChunkId) + instance.target_groups.len * @sizeOf(TargetGroup) + instance.target_indices.len * @sizeOf(u32));
    try std.testing.expect(state.fulfill(&layout, .{ .instance_id = 1, .cell_index = 0 }));
    try std.testing.expectEqual(native_before, state.estimatedOwnedBytes());
    try std.testing.expect(!state.fulfill(&layout, .{ .instance_id = 1, .cell_index = 0 }));
    try std.testing.expect(state.targetAt(.{ 127, 10, 10 }) == null);
    try std.testing.expectEqual(rules.BlockType.dirt, state.physicalAt(.{ 127, 10, 10 }).material);
    try std.testing.expectEqual(StorageOwner.simulation, state.memberAt(.{ 127, 10, 10 }).?.owner);
    try std.testing.expect(state.fulfill(&layout, .{ .instance_id = 1, .cell_index = 2 }));
    try std.testing.expectEqual(Phase.materializing, state.instances.get(1).?.phase);
    try std.testing.expect(state.boxAt(&layout, .{ 0, 10, 10 }) != null);
    state.cleanup(a, 100);
    try std.testing.expect(state.instances.contains(1));
    var constructed: std.ArrayList(rules.Cell) = .empty;
    defer constructed.deinit(a);
    for (instance.target_groups) |group| try state.appendConstructed(a, group.chunk_id, &constructed);
    try std.testing.expectEqual(@as(usize, 2), constructed.items.len);
    const first = instance.target_groups[0];
    try std.testing.expect(state.acceptTransfer(.{ .instance_id = 1, .chunk_id = first.chunk_id, .terrain_revision = 7 }));
    try std.testing.expect(!state.acceptTransfer(.{ .instance_id = 1, .chunk_id = first.chunk_id, .terrain_revision = 7 }));
    try std.testing.expect(!state.complete(1));
    const second = instance.target_groups[1];
    try std.testing.expect(state.acceptTransfer(.{ .instance_id = 1, .chunk_id = second.chunk_id, .terrain_revision = 8 }));
    try std.testing.expectEqual(StorageOwner.world_data, state.memberAt(.{ 127, 10, 10 }).?.owner);
    try std.testing.expect(state.physicalAt(.{ 127, 10, 10 }) == .unowned);
    try std.testing.expect(state.boxAt(&layout, .{ 0, 10, 10 }) != null);
    var soil: std.ArrayList(ChunkId) = .empty;
    defer soil.deinit(a);
    try state.appendSoilGroups(a, 1, &soil);
    try std.testing.expectEqual(@as(usize, 1), soil.items.len);
    try std.testing.expect(state.complete(1));
    try std.testing.expect(!state.complete(1));
    try std.testing.expect(state.boxAt(&layout, .{ 0, 10, 10 }) == null);
    state.cleanup(a, 100);
    try std.testing.expect(!state.instances.contains(1));
    try std.testing.expectEqual(@as(u64, 1), state.max_instance_id);
}

test "retirement cleanup bounds missed progress removal to the retiring site's chunk groups" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 16, 8, 4 } });
    var state: State = .{ .layout = &layout };
    defer state.deinit(a);
    const cells = try a.alloc(rules.BlockType, 129);
    @memset(cells, .none);
    cells[0] = .planks;
    cells[128] = .planks;
    try state.insertDefinition(a, .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Retiring"), .definition = .{ .size = .{ 129, 1, 1 }, .cells = cells, .target_count = 2 } });
    try state.insertDefinition(a, .{ .id = 2, .owner = 1, .name = try a.dupe(u8, "Live"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{.planks}), .target_count = 1 } });
    const retired = try state.prepareInstance(a, &layout, 1, 1, 1, .{ 31, 10, 10 }, 0);
    try state.insertInstance(a, &layout, retired);
    const live = try state.prepareInstance(a, &layout, 2, 2, 1, .{ 30, 10, 10 }, 0);
    try state.insertInstance(a, &layout, live);
    // A client can receive terminal retirement after the final fills have left
    // server history. Its cached pending entries still need bounded removal.
    state.instances.getPtr(1).?.active = false;
    state.instances.getPtr(1).?.phase = .complete;
    state.cleanup_queue.appendAssumeCapacity(1);
    const revision = state.revision;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    state.cleanup(failing.allocator(), 0);
    try std.testing.expectEqual(revision, state.revision);
    state.cleanup(failing.allocator(), 1);
    try std.testing.expectEqual(revision + 1, state.revision);
    try std.testing.expectEqual(@as(usize, 1), state.instances.get(1).?.cleanup_cursor);
    try std.testing.expect(state.targetAt(retired.origin) == null);
    try std.testing.expectEqual(@as(u64, 1), state.targetAt(.{ 159, 10, 10 }).?.instance_id);
    const shared = state.chunks.get(live.box_chunks[0]).?;
    try std.testing.expectEqualSlices(u64, &.{2}, shared.instances.items);
    try std.testing.expectEqual(@as(usize, 1), shared.targets.items.len);
    try std.testing.expectEqual(@as(u64, 2), state.targetAt(live.origin).?.instance_id);
    state.cleanup(failing.allocator(), 3);
    try std.testing.expectEqual(@as(usize, 4), state.instances.get(1).?.cleanup_cursor);
    try std.testing.expect(state.targetAt(.{ 159, 10, 10 }) != null);
    state.cleanup(failing.allocator(), 1);
    try std.testing.expectEqual(revision + 5, state.revision);
    try std.testing.expect(!state.instances.contains(1));
    try std.testing.expect(state.targetAt(.{ 159, 10, 10 }) == null);
    try std.testing.expectEqual(@as(u32, 1), state.chunks.count());
    try std.testing.expectEqual(@as(u64, 2), state.targetAt(live.origin).?.instance_id);
    try std.testing.expectEqual(@as(usize, 0), state.cleanup_queue.items.len);
}

test "snapshot overlap only replaces pending entries belonging to a retained completed site" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var state: State = .{ .layout = &layout };
    defer state.deinit(a);
    const cell: Cell = .{ 10, 10, 10 };
    try state.insertDefinition(a, .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "One"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{.planks}), .target_count = 1 } });
    const definition = state.definitions.get(1).?.definition;
    const first = try state.prepareInstance(a, &layout, 1, 1, 1, cell, 0);
    try state.insertInstance(a, &layout, first);
    var second = try state.prepareInstance(a, &layout, 2, 1, 1, cell, 0);
    defer second.deinit(a);
    try std.testing.expectError(error.Overlap, buildSnapshotPublication(a, &layout, definition, second, &state));
    {
        const missing = state.instances.fetchRemove(1).?.value;
        defer state.instances.putAssumeCapacity(1, missing);
        try std.testing.expectError(error.Overlap, buildSnapshotPublication(a, &layout, definition, second, &state));
    }
    state.instances.getPtr(1).?.active = false;
    // Inactive alone is insufficient to replace an inconsistent owner.
    try std.testing.expectError(error.Overlap, buildSnapshotPublication(a, &layout, definition, second, &state));
    state.instances.getPtr(1).?.phase = .complete;
    state.cleanup_queue.appendAssumeCapacity(1);
    var copy = try second.clone(a);
    var prepared = buildSnapshotPublication(a, &layout, definition, copy, &state) catch |err| {
        copy.deinit(a);
        return err;
    };
    defer prepared.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), state.targetAt(cell).?.instance_id);
    try std.testing.expectEqual(@as(u64, 2), prepared.chunks.get(first.box_chunks[0]).?.lookup.get(cell).?.instance_id);
    try state.reserveSnapshotPublication(a, &layout, &prepared);
    state.publishSnapshotPublication(&prepared);
    try std.testing.expect(state.instances.contains(1));
    try std.testing.expectEqual(@as(u64, 2), state.targetAt(cell).?.instance_id);
    state.cleanup(a, 1);
    try std.testing.expect(!state.instances.contains(1));
    try std.testing.expectEqual(@as(u64, 2), state.targetAt(cell).?.instance_id);
}

test "definition lookup is exact for rotations wrapped images and missing sources" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const size: blueprint.Size = .{ 5, 3, 2 };
    for (0..4) |rotation_raw| {
        const rotation: u2 = @intCast(rotation_raw);
        for (0..30) |index| {
            const cell = worldCell(&layout, .{ 127, 10, 10 }, size, rotation, blueprint.cellAtIndex(size, index)).?;
            try std.testing.expectEqual(@as(u32, @intCast(index)), definitionIndex(&layout, .{ 127, 10, 10 }, size, rotation, cell).?);
        }
    }
    var state: State = .{ .layout = &layout };
    defer state.deinit(a);
    try state.insertDefinition(a, .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "One"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{.planks}), .target_count = 1 } });
    const instance = try state.prepareInstance(a, &layout, 1, 1, 1, .{ 5, 5, 5 }, 0);
    try state.insertInstance(a, &layout, instance);
    const missing = state.definitions.fetchRemove(1).?.value;
    try std.testing.expect(state.physicalAt(.{ 5, 5, 5 }) == .unknown);
    state.definitions.putAssumeCapacity(1, missing);
}

fn snapshotReplacementScenario(a: std.mem.Allocator) !void {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var state: State = .{ .layout = &layout };
    defer state.deinit(a);
    var saved: SavedDefinition = .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Snapshot"), .definition = undefined };
    var owns_name = true;
    errdefer if (owns_name) a.free(saved.name);
    saved.definition = .{ .size = .{ 2, 1, 1 }, .cells = try a.dupe(rules.BlockType, &.{ .planks, .planks }), .target_count = 2 };
    state.insertDefinition(a, saved) catch |err| {
        saved.definition.deinit(a);
        return err;
    };
    owns_name = false;
    const initial = try state.prepareInstance(a, &layout, 1, 1, 1, .{ 31, 10, 10 }, 0);
    state.insertInstance(a, &layout, initial) catch |err| {
        var cleanup = initial;
        cleanup.deinit(a);
        return err;
    };
    var snapshot = try initial.clone(a);
    snapshot.fulfilled[0] = 1;
    snapshot.remaining = 1;
    snapshot.revision = 1;
    var prepared = buildSnapshotPublication(a, &layout, saved.definition, snapshot, &state) catch |err| {
        snapshot.deinit(a);
        return err;
    };
    defer prepared.deinit(a);
    try state.reserveSnapshotPublication(a, &layout, &prepared);
    try std.testing.expectEqual(@as(u32, 2), state.instances.get(1).?.remaining);
    state.publishSnapshotPublication(&prepared);
    try std.testing.expectEqual(@as(u32, 1), state.instances.get(1).?.remaining);
    try std.testing.expect(state.targetAt(.{ 31, 10, 10 }) == null);
    try std.testing.expect(state.targetAt(.{ 32, 10, 10 }) != null);
    try std.testing.expectEqual(rules.BlockType.planks, state.physicalAt(.{ 31, 10, 10 }).material);
    var invalid = state.instances.get(1).?;
    invalid.remaining = 0;
    try std.testing.expectError(error.InvalidConstructionSnapshot, validateSnapshot(&layout, saved.definition, invalid));
}

test "full snapshot replacement retains sources and rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotReplacementScenario, .{});
}
