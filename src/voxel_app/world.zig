const ChunkCoords = @import("engine").ChunkCoords;
const std = @import("std");

const BlockType = @import("engine").voxel_chunk.BlockType;
const Side = @import("engine").voxel_chunk.Side;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const ChunkFlags = @import("./world_chunk_data.zig").ChunkFlags;
const world_generator = @import("./world_generator.zig");
const mutation_guard = @import("mutation_guard.zig");
const ChunkId = @import("./consts.zig").ChunkId;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const test_layout = @import("test_world.zig").layout;
const WORLD_SIZE = test_layout.size_in_chunks;
const boundary_mask = @import("./boundary_mask.zig");
const WorldLayout = @import("engine").WorldLayout;
const transformations = @import("block_transformations.zig");
const ChunkMetadata = @import("chunk_metadata.zig").Metadata;
const roads = @import("roads.zig");
pub const block_rules = @import("block_rules.zig");
const blueprint = @import("blueprint.zig");
pub const blueprint_runtime = @import("blueprint_runtime.zig");

/// Face neighbors wrap around x; missing y/z neighbors leave the world exposed.
pub fn adjacentChunk(layout: *const WorldLayout, coords: ChunkCoords, side: Side) ?ChunkCoords {
    std.debug.assert(@reduce(.And, coords >= @as(ChunkCoords, @splat(0))));
    std.debug.assert(@reduce(.And, coords < layout.size_in_chunks));
    return layout.normalizeChunkCoords(coords + side.getOffset());
}

/// What the chunk consists of. Empty chunks don't store their blocks, so the air above the
/// terrain takes almost no memory.
pub const ChunkContent = union(enum) {
    /// Every block is `.none`. Nothing is allocated and nothing is rendered.
    empty,
    /// Every block is stored individually. Used for any chunk with at least one solid block.
    blocks: *WorldChunkData,

    pub fn deinit(self: ChunkContent, allocator: std.mem.Allocator) void {
        switch (self) {
            .blocks => |world_chunk_data| allocator.destroy(world_chunk_data),
            .empty => {},
        }
    }

    pub fn toData(self: ChunkContent) WorldChunkData {
        return switch (self) {
            .empty => WorldChunkData.initEmpty(),
            .blocks => |world_chunk_data| world_chunk_data.*,
        };
    }

    pub fn getBlock(self: ChunkContent, local: [3]u5) BlockType {
        return switch (self) {
            .empty => .none,
            .blocks => |world_chunk_data| world_chunk_data.blocks[local[2]][local[1]][local[0]],
        };
    }
};

/// Authoritative block contents and flags. Meshing additionally consults face neighbors.
pub const WorldChunk = struct {
    content: ChunkContent,
    flags: ChunkFlags,
    /// Number of blocks of the content that aren't `.none`.
    solid_block_count: u16,
    /// Authoritative revision, advanced only by the world-data service for content or flag changes.
    /// Optimistic edits never change it. 0 means no edits have been committed yet.
    chunk_revision: u64 = 0,
    /// Client-cache stamp assigned by World, including optimistic edits and reloads.
    /// Independent of the service's authoritative chunk_revision.
    validation_revision: u64 = 0,
    /// Cached own boundary occupancy, including optimistic edits. Never sent to the GPU.
    boundaries: boundary_mask.BoundaryMasks = @splat(.{}),
    metadata: ChunkMetadata = .{},
    /// Not persisted: old holds are discarded on load. Clones carry this history.
    cell_changes: @import("cell_changes.zig").History = .{},

    pub fn initEmpty() WorldChunk {
        return .{
            .content = .empty,
            .flags = .{},
            .solid_block_count = 0,
        };
    }

    /// Takes ownership of the data.
    pub fn initBlocks(world_chunk_data: *WorldChunkData) WorldChunk {
        const boundaries = boundary_mask.extract(world_chunk_data);
        return .{
            .content = .{ .blocks = world_chunk_data },
            .flags = boundary_mask.getFlags(&boundaries),
            .solid_block_count = world_chunk_data.countSolidBlocks(),
            .boundaries = boundaries,
        };
    }

    pub fn tryClone(self: WorldChunk, allocator: std.mem.Allocator) !WorldChunk {
        var copy = self;
        copy.metadata = try self.metadata.tryClone(allocator);
        errdefer copy.metadata.deinit(allocator);
        if (self.content == .blocks) {
            const data = try allocator.create(WorldChunkData);
            data.* = self.content.blocks.*;
            copy.content = .{ .blocks = data };
        }
        return copy;
    }

    pub fn clone(self: WorldChunk, allocator: std.mem.Allocator) WorldChunk {
        return self.tryClone(allocator) catch @panic("OOM");
    }

    pub fn deinit(self: WorldChunk, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
        var metadata = self.metadata;
        metadata.deinit(allocator);
    }

    /// Material-only changes preserve occupancy and enclosure flags.
    pub fn changeType(self: *WorldChunk, local: [3]u5, block_type: BlockType) void {
        std.debug.assert(self.content.getBlock(local) != .none and block_type != .none);
        if (!mutation_guard.allowsMaterialChange(self.content.getBlock(local), block_type)) return;
        if (self.content.getBlock(local) == block_type) return;
        self.content.blocks.blocks[local[2]][local[1]][local[0]] = block_type;
        self.cell_changes.record(transformations.index(local));
    }

    pub fn ensureData(self: *WorldChunk, allocator: std.mem.Allocator) *WorldChunkData {
        return self.tryEnsureData(allocator) catch @panic("OOM");
    }

    pub fn tryEnsureData(self: *WorldChunk, allocator: std.mem.Allocator) !*WorldChunkData {
        if (self.content == .empty) {
            const data = try allocator.create(WorldChunkData);
            data.* = WorldChunkData.initEmpty();
            self.content = .{ .blocks = data };
        }
        return self.content.blocks;
    }

    /// Applies the same preconditions to authoritative commands and optimistic replay.
    /// Revision assignment belongs to the service, not this data manipulation helper.
    pub fn apply(self: *WorldChunk, allocator: std.mem.Allocator, local: [3]u5, action: BlockAction) OperationStatus {
        return self.tryApply(allocator, local, action) catch @panic("OOM");
    }

    pub fn tryApply(self: *WorldChunk, allocator: std.mem.Allocator, local: [3]u5, action: BlockAction) !OperationStatus {
        const status = try self.prepareApply(allocator, local, action);
        if (status != .success) return status;
        return self.applyPrepared(allocator, local, action);
    }

    /// Reserve every fallible resource before the first semantic write. Call on
    /// detached staging chunks when preparing an authoritative multi-chunk edit.
    pub fn prepareApply(self: *WorldChunk, allocator: std.mem.Allocator, local: [3]u5, action: BlockAction) !OperationStatus {
        const existing = self.content.getBlock(local);
        if (!mutation_guard.allowsMaterialChange(existing, if (action == .put) action.put else .none)) return .constraint_violation;
        switch (action) {
            .put => |material| {
                std.debug.assert(material != .none);
                if (existing != .none) return .already_exists;
                if (material == .custom or material == .country_road_adaptive)
                    try self.metadata.roads.ensureUnusedCapacity(allocator, 1);
            },
            .remove => {
                if (existing == .none) return .already_removed;
                if (existing.miningPolicy() == .forbidden) return .constraint_violation;
            },
        }
        _ = try self.tryEnsureData(allocator);
        return .success;
    }

    /// No allocation. The matching prepareApply must have succeeded without an
    /// intervening mutation; allocator is used only to release empty block storage.
    pub fn applyPrepared(self: *WorldChunk, allocator: std.mem.Allocator, local: [3]u5, action: BlockAction) OperationStatus {
        return self.applyPreparedPolicy(allocator, local, action, false);
    }

    fn applyPreparedPolicy(self: *WorldChunk, allocator: std.mem.Allocator, local: [3]u5, action: BlockAction, retain_empty: bool) OperationStatus {
        const existing = self.content.getBlock(local);
        if (!mutation_guard.allowsMaterialChange(existing, if (action == .put) action.put else .none)) return .constraint_violation;
        const block_type: BlockType = switch (action) {
            .put => |block_type| blk: {
                std.debug.assert(block_type != .none);
                if (existing != .none) return .already_exists;
                break :blk if (block_type == .country_road_adaptive) .custom else block_type;
            },
            .remove => blk: {
                if (existing == .none) return .already_removed;
                if (existing.miningPolicy() == .forbidden) return .constraint_violation;
                break :blk .none;
            },
        };
        std.debug.assert(self.content == .blocks);
        const data = self.content.blocks;
        const was_unreachable = self.flags.is_unreachable;
        data.blocks[local[2]][local[1]][local[0]] = block_type;
        self.cell_changes.record(transformations.index(local));
        boundary_mask.update(&self.boundaries, local, block_type.occludesFaces());
        if (block_type == .none) {
            self.metadata.remove(transformations.index(local));
            self.solid_block_count -= 1;
        } else {
            self.solid_block_count += 1;
            if (block_type == .custom) self.metadata.roads.appendAssumeCapacity(.{ .index = transformations.index(local) });
        }
        if (self.solid_block_count == 0) {
            if (!retain_empty) {
                self.content.deinit(allocator);
                self.content = .empty;
            }
            self.flags = .{};
        } else self.flags = boundary_mask.getFlags(&self.boundaries);
        // Face flags describe our blocks; reachability describes neighboring walls.
        self.flags.is_unreachable = was_unreachable;
        return .success;
    }

    /// The service has committed modifications that must be preserved.
    pub fn isDirty(self: WorldChunk) bool {
        return self.chunk_revision > 0;
    }
};

/// Splits global block coordinates into chunk coordinates and coordinates inside of the chunk.
pub fn splitBlockCoords(block: [3]u32) struct { ChunkCoords, [3]u5 } {
    return .{
        .{
            @intCast(block[0] / CHUNK_SIZE),
            @intCast(block[1] / CHUNK_SIZE),
            @intCast(block[2] / CHUNK_SIZE),
        },
        .{
            @intCast(block[0] % CHUNK_SIZE),
            @intCast(block[1] % CHUNK_SIZE),
            @intCast(block[2] % CHUNK_SIZE),
        },
    };
}

pub const ChunksHashMap = std.AutoHashMapUnmanaged(ChunkId, WorldChunk);

pub const ChunkNotReceivedError = error{ChunkNotReceived};

pub const BlockAction = union(enum) {
    put: BlockType,
    remove,
};

pub const OperationStatus = enum { success, already_exists, already_removed, constraint_violation, missing_data, resource_exhausted, inventory_mismatch, target_changed };
pub const EditResult = struct {
    status: OperationStatus,
    failure: ?block_rules.Failure = null,
    mined_type: ?BlockType = null,
};

/// Commands contain global block coordinates and intent, never chunk snapshots.
pub const BlockOperation = struct {
    block: [3]u32,
    action: BlockAction,
    /// Player transfers are checked by the authority; observer/NPC edits omit this.
    player: ?struct { id: u64, expected_sequence: u64 } = null,
    /// Frozen planned-target identity. An ordinary command must never silently
    /// become a fulfillment after a new site appears at its destination.
    blueprint: ?blueprint_runtime.Fulfill = null,

    pub fn validate(self: BlockOperation, layout: *const WorldLayout) void {
        for (0..3) |axis| std.debug.assert(self.block[axis] < layout.size_in_blocks[axis]);
        if (self.action == .put) std.debug.assert(self.action.put != .none);
    }
};

/// Sparse baseline for the one cell a command can change. Road transitions keep
/// their own section undo; together these restore materials AND metadata.
const CellState = struct {
    material: BlockType,
    road: ?@import("road_data.zig").Road,
    timed: ?transformations.Event,
    constructed: bool,
    cell_changes: @import("cell_changes.zig").History,

    fn capture(chunk: *const WorldChunk, local: [3]u5) CellState {
        const index = transformations.index(local);
        var timed: ?transformations.Event = null;
        for (chunk.metadata.timed.events.items) |event| if (event.block == index) {
            timed = event;
            break;
        };
        return .{
            .material = chunk.content.getBlock(local),
            .road = chunk.metadata.road(index),
            .timed = timed,
            .constructed = std.mem.indexOfScalar(transformations.BlockIndex, chunk.metadata.constructed.items, index) != null,
            .cell_changes = chunk.cell_changes,
        };
    }

    fn restore(self: CellState, allocator: std.mem.Allocator, chunk: *WorldChunk, local: [3]u5) void {
        const existing = chunk.content.getBlock(local);
        if (!mutation_guard.allowsMaterialChange(existing, self.material)) return;
        if (existing != self.material) {
            if (existing != .none) _ = chunk.applyPreparedPolicy(allocator, local, .remove, true);
            if (self.material != .none) _ = chunk.applyPreparedPolicy(allocator, local, .{
                .put = if (self.material == .custom) .country_road_adaptive else self.material,
            }, true);
        }
        const index = transformations.index(local);
        chunk.metadata.remove(index);
        if (self.road) |road| chunk.metadata.roads.appendAssumeCapacity(road);
        if (self.timed) |event| chunk.metadata.timed.scheduleAssumeCapacity(event);
        if (self.constructed) chunk.metadata.markConstructedAssumeCapacity(index);
        chunk.cell_changes = self.cell_changes;
    }
};

pub const PendingOperation = struct {
    operation: BlockOperation,
    cell_undo: ?CellState = null,
    mark_constructed: bool = false,
    road_undo: std.ArrayList(roads.Undo) = .empty,
    /// Chosen before later edits can introduce an ambiguous crossing. Unlike undo
    /// baselines, these ownership snapshots survive a rebase until acknowledged.
    road_formations: std.ArrayList(@import("road_data.zig").Slope) = .empty,
    /// Assigned when the command is submitted to the service.
    request_id: ?u64 = null,
    resolved_status: ?OperationStatus = null,
};

/// Includes absent chunks, clipped finite bounds, and deduplicated wrapped IDs.
const ValidationChunks = struct {
    ids: [27]ChunkId = undefined,
    count: usize = 0,
};

fn validationChunks(layout: *const WorldLayout, target: [3]u32) ValidationChunks {
    var result: ValidationChunks = .{};
    const center: block_rules.Cell = .{ target[0], target[1], target[2] };
    var low: ChunkCoords = undefined;
    var high: ChunkCoords = undefined;
    inline for (0..3) |axis| {
        low[axis] = @intCast(@divFloor(center[axis] - block_rules.Limits.support_radius, CHUNK_SIZE));
        high[axis] = @intCast(@divFloor(center[axis] + block_rules.Limits.support_radius, CHUNK_SIZE));
    }
    var z = low[2];
    while (z <= high[2]) : (z += 1) {
        var y = low[1];
        while (y <= high[1]) : (y += 1) {
            var x = low[0];
            while (x <= high[0]) : (x += 1) {
                const coords = layout.normalizeChunkCoords(.{ x, y, z }) orelse continue;
                const id = layout.encodeChunkCoords(coords);
                // A small wrapped world can map multiple coordinates to the same chunk.
                if (std.mem.indexOfScalar(ChunkId, result.ids[0..result.count], id) != null) continue;
                result.ids[result.count] = id;
                result.count += 1;
            }
        }
    }
    return result;
}

/// A conservative snapshot of all chunks the validator can consult for this edit.
/// Matching this bounded set costs at most 27 lookups and never evaluates support.
pub const ValidationWindow = struct {
    chunks: ValidationChunks,
    revisions: [27]?u64 = undefined,
    blueprint_revision: u64 = 0,

    pub fn isCurrent(self: *const ValidationWindow, world: *const World) bool {
        if (self.blueprint_revision != world.blueprints.revision) return false;
        for (self.chunks.ids[0..self.chunks.count], 0..) |id, i| {
            const revision = if (world.chunks.get(id)) |chunk| chunk.validation_revision else null;
            if (revision != self.revisions[i]) return false;
        }
        return true;
    }
};

/// Read construction indices only from chunks intersecting the target's fixed window.
/// This visits at most 27 chunk IDs, independently of retained edits elsewhere in the world.
pub fn collectConstructed(allocator: std.mem.Allocator, layout: *const WorldLayout, chunks: *const ChunksHashMap, target: [3]u32) []block_rules.Cell {
    return tryCollectConstructed(allocator, layout, chunks, target) catch @panic("OOM");
}

pub fn tryCollectConstructed(allocator: std.mem.Allocator, layout: *const WorldLayout, chunks: *const ChunksHashMap, target: [3]u32) ![]block_rules.Cell {
    var cells: std.ArrayList(block_rules.Cell) = .empty;
    errdefer cells.deinit(allocator);
    const center: block_rules.Cell = .{ target[0], target[1], target[2] };
    const window = validationChunks(layout, target);
    for (window.ids[0..window.count]) |id| {
        const chunk = chunks.get(id) orelse continue;
        const coords = layout.decodeChunkId(id);
        for (chunk.metadata.constructed.items) |index| {
            const local = transformations.coordinates(index);
            const cell: block_rules.Cell = .{
                @as(i64, coords[0]) * CHUNK_SIZE + local[0],
                @as(i64, coords[1]) * CHUNK_SIZE + local[1],
                @as(i64, coords[2]) * CHUNK_SIZE + local[2],
            };
            if (block_rules.distance(layout, cell, center) <= block_rules.Limits.support_radius)
                try cells.append(allocator, cell);
        }
    }
    const Order = struct {
        layout: *const WorldLayout,
        center: block_rules.Cell,

        fn lessThan(self: @This(), a: block_rules.Cell, b: block_rules.Cell) bool {
            const da = block_rules.displacement(self.layout, a, self.center);
            const db = block_rules.displacement(self.layout, b, self.center);
            inline for (.{ 2, 1, 0 }) |axis| if (da[axis] != db[axis]) return da[axis] < db[axis];
            return false;
        }
    };
    std.mem.sort(block_rules.Cell, cells.items, Order{ .layout = layout, .center = center }, Order.lessThan);
    return try cells.toOwnedSlice(allocator);
}

pub fn validateEdit(allocator: std.mem.Allocator, reader: block_rules.Reader, constructed: []const block_rules.Cell, operation: BlockOperation) EditResult {
    const cell: block_rules.Cell = .{ operation.block[0], operation.block[1], operation.block[2] };
    const replacement = if (operation.action == .put) operation.action.put else BlockType.none;
    if (mutation_guard.validateWrites(reader, &.{.{ .block = operation.block, .material = replacement }})) |failure|
        return .{ .status = .constraint_violation, .failure = failure };
    const existing = reader.get(cell) orelse return .{ .status = .missing_data, .failure = .{ .reason = .missing_data, .subject = cell } };
    const material: BlockType = switch (operation.action) {
        .put => |value| blk: {
            if (existing != .none) return .{ .status = .already_exists };
            break :blk value;
        },
        .remove => blk: {
            if (existing == .none) return .{ .status = .already_removed };
            if (existing.miningPolicy() == .forbidden) return .{ .status = .constraint_violation, .failure = .{ .reason = .mining_forbidden, .subject = cell } };
            if (existing.miningPolicy() == .yields and !existing.miningPolicy().yields.isPlaceable())
                return .{ .status = .constraint_violation, .failure = .{ .reason = .mining_forbidden, .subject = cell } };
            break :blk .none;
        },
    };
    var validator: block_rules.Validator = .{ .allocator = allocator, .reader = reader, .edit = .{ .cell = cell, .material = material } };
    defer validator.deinit();
    var failure = if (material != .none) validator.checkPlacement(cell, material) else null;
    if (failure == null) failure = validator.checkDependents(constructed, material == .none);
    if (validator.allocation_failed) return .{ .status = .resource_exhausted };
    if (failure) |reason| return .{ .status = if (reason.reason == .missing_data) .missing_data else .constraint_violation, .failure = reason };
    return .{ .status = .success, .mined_type = if (material == .none) existing.minedType() else null };
}

/// This path exits before dependent enumeration, ordinary validation, and roads.
/// The target occupancy/identity checks are separate from its <=5 support probes.
pub fn validateBlueprintFulfillment(physical: block_rules.Reader, state: *const blueprint_runtime.State, operation: BlockOperation) EditResult {
    const identity = operation.blueprint orelse return .{ .status = .target_changed };
    const target = state.targetAt(operation.block) orelse return .{ .status = .target_changed };
    if (target.instance_id != identity.instance_id or target.cell_index != identity.cell_index or operation.action != .put) return .{ .status = .target_changed };
    if (!operation.action.put.isPlaceable() or !blueprint.materialMatches(target.material, operation.action.put)) return .{ .status = .inventory_mismatch };
    const cell: block_rules.Cell = .{ operation.block[0], operation.block[1], operation.block[2] };
    if (physical.immutable_at) |immutable| if (immutable(physical.context, operation.block)) return .{ .status = .constraint_violation, .failure = .{ .reason = .immutable_cell, .subject = cell } };
    const actual = physical.get(cell) orelse return .{ .status = .missing_data };
    if (actual == .deeprock or operation.action.put == .deeprock) return .{ .status = .constraint_violation, .failure = .{ .reason = .immutable_cell, .subject = cell } };
    if (actual != .none) return .{ .status = .already_exists };
    const Probe = struct {
        physical: block_rules.Reader,
        missing: bool = false,
        fn read(context: *anyopaque, block: [3]u32) ?BlockType {
            const self: *@This() = @ptrCast(@alignCast(context));
            const material = self.physical.block_at(self.physical.context, block);
            if (material == null) self.missing = true;
            return material;
        }
    };
    var probe: Probe = .{ .physical = physical };
    var support = physical;
    support.context = &probe;
    support.block_at = Probe.read;
    if (!blueprint.checkFulfillment(support, cell, target.material)) return .{ .status = if (probe.missing) .missing_data else .constraint_violation, .failure = .{ .reason = if (probe.missing) .missing_data else .missing_foundation, .subject = cell } };
    return .{ .status = .success };
}

/// Shared client/authority dispatch: without sites, validate the physical world once.
/// Otherwise preserve the world with every pending target completed, while keeping
/// physical target approval independent so miniatures grant no support.
pub fn validateCompletedEdit(allocator: std.mem.Allocator, physical: block_rules.Reader, state: *const blueprint_runtime.State, constructed: []const block_rules.Cell, operation: BlockOperation) EditResult {
    if (operation.blueprint != null) return validateBlueprintFulfillment(physical, state, operation);
    if (state.instances.count() == 0) return validateEdit(allocator, physical, constructed, operation);
    if (state.targetAt(operation.block) != null) return .{ .status = .target_changed };
    const cell: block_rules.Cell = .{ operation.block[0], operation.block[1], operation.block[2] };
    if (operation.action == .remove and state.boxAt(physical.layout, operation.block) != null) return .{ .status = .constraint_violation, .failure = .{ .reason = .would_remove_support, .subject = cell } };
    const material = if (operation.action == .put) operation.action.put else BlockType.none;
    if (mutation_guard.validateWrites(physical, &.{.{ .block = operation.block, .material = material }})) |failure| return .{ .status = .constraint_violation, .failure = failure };
    const existing = physical.get(cell) orelse return .{ .status = .missing_data };
    if (operation.action == .put) {
        if (existing != .none) return .{ .status = .already_exists };
        var physical_validator: block_rules.Validator = .{ .allocator = allocator, .reader = physical, .edit = .{ .cell = cell, .material = material } };
        defer physical_validator.deinit();
        const failure = physical_validator.checkPlacement(cell, material);
        if (physical_validator.allocation_failed) return .{ .status = .resource_exhausted };
        if (failure) |reason| return .{ .status = if (reason.reason == .missing_data) .missing_data else .constraint_violation, .failure = reason };
    } else {
        if (existing == .none) return .{ .status = .already_removed };
        if (existing.miningPolicy() == .forbidden or (existing.miningPolicy() == .yields and !existing.miningPolicy().yields.isPlaceable())) return .{ .status = .constraint_violation, .failure = .{ .reason = .mining_forbidden, .subject = cell } };
    }
    var completed: blueprint_runtime.CompletedReader = .{ .physical = physical, .state = state };
    const affected = state.collectAffected(allocator, physical.layout, operation.block, constructed) catch return .{ .status = .resource_exhausted };
    defer allocator.free(affected);
    var validator: block_rules.Validator = .{ .allocator = allocator, .reader = completed.reader(), .edit = .{ .cell = cell, .material = material } };
    defer validator.deinit();
    var failure = if (operation.action == .put) validator.checkPlacement(cell, material) else null;
    if (failure == null) failure = validator.checkDependents(affected, operation.action == .remove);
    if (validator.allocation_failed) return .{ .status = .resource_exhausted };
    if (failure) |reason| return .{ .status = if (reason.reason == .missing_data) .missing_data else .constraint_violation, .failure = reason };
    return .{ .status = .success, .mined_type = if (operation.action == .remove) existing.minedType() else null };
}

/// Main-thread cache: authoritative snapshots with unacknowledged local operations replayed
/// on top. Receiving a failed operation's snapshot rolls it back without losing later edits.
pub const World = struct {
    layout: *const WorldLayout,
    allocator: std.mem.Allocator,
    chunks: ChunksHashMap = .empty,
    blueprints: blueprint_runtime.State = .{},
    pending_operations: std.ArrayList(PendingOperation) = .empty,
    pending_operation_limit: usize = 4096,
    pending_byte_limit: usize = 8 * 1024 * 1024,
    pending_accounted_count: usize = 0,
    pending_dynamic_bytes: usize = 0,
    simulation_tick: transformations.Tick = 0,
    immutable_floor: ?mutation_guard.CanonicalFloor = null,
    playable_y_inset: u32 = 0,
    last_edit_result: ?EditResult = null,
    /// Assigns distinct local stamps to chunk loads and optimistic block changes.
    validation_revision: u64 = 0,
    changed_road_chunks: std.ArrayList(u32) = .empty,
    /// Tests count actual evaluator calls without adding runtime instrumentation.
    preview_call_counter: if (@import("builtin").is_test) ?*usize else void = if (@import("builtin").is_test) null else {},
    ordinary_preview_counter: if (@import("builtin").is_test) ?*usize else void = if (@import("builtin").is_test) null else {},
    road_plan_counter: if (@import("builtin").is_test) ?*usize else void = if (@import("builtin").is_test) null else {},
    physical_read_counter: if (@import("builtin").is_test) ?*usize else void = if (@import("builtin").is_test) null else {},

    pub fn init(allocator: std.mem.Allocator, layout: *const WorldLayout) !World {
        const owned_layout = try allocator.create(WorldLayout);
        owned_layout.* = layout.*;
        return .{ .allocator = allocator, .layout = owned_layout, .blueprints = .{ .layout = owned_layout } };
    }

    pub fn deinit(self: *World) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.blueprints.deinit(self.allocator);
        for (self.pending_operations.items) |*pending| {
            pending.road_undo.deinit(self.allocator);
            pending.road_formations.deinit(self.allocator);
        }
        self.pending_operations.deinit(self.allocator);
        self.changed_road_chunks.deinit(self.allocator);
        self.allocator.destroy(@constCast(self.layout));
    }

    pub fn hasChunk(self: *const World, coords: ChunkCoords) bool {
        return self.chunks.contains(self.layout.encodeChunkCoords(coords));
    }

    /// Takes ownership on success. Subscription tokens must be checked by the caller first.
    /// Replaces the cache with authoritative data, then replays pending commands in order.
    pub fn insertChunk(self: *World, coords: ChunkCoords, chunk: WorldChunk) !void {
        const position = self.layout.encodeChunkCoords(coords);
        if (self.chunks.get(position)) |previous| {
            if (chunk.chunk_revision < previous.chunk_revision) return error.StaleChunk;
        }
        // Restore the baseline across ALL pending cells/sections, including chunks
        // other than this snapshot's. Later materials must not be visible when an
        // earlier command captures removal ownership or evaluates formation.
        try self.chunks.ensureUnusedCapacity(self.allocator, 1);
        try self.rollbackPending();
        self.retireResolved();
        var updated = chunk;
        if (self.chunks.getPtr(position)) |previous| {
            // An in-flight snapshot must never undo an optimistic reveal.
            updated.flags.is_unreachable = updated.flags.is_unreachable and previous.flags.is_unreachable;
            previous.deinit(self.allocator);
        }
        // Loads and neighboring snapshots can arrive in either order. Account for walls
        // already opened in the cache, including edits that haven't reached the service.
        for (std.enums.values(Side)) |side| {
            const neighbor_coords = adjacentChunk(self.layout, coords, side) orelse continue;
            const neighbor = self.getChunk(neighbor_coords) orelse continue;
            if (!neighbor.flags.getSideSolidness(side.getOpposite())) updated.flags.is_unreachable = false;
        }
        self.validation_revision +%= 1;
        updated.validation_revision = self.validation_revision;
        self.chunks.putAssumeCapacity(position, updated);
        self.revealNeighbors(coords, updated.flags);
        // A pending operation can affect sections outside the replaced chunk.
        self.replayPending();
    }

    /// Restore the current authoritative material/metadata baseline in reverse edit order.
    /// Undo records are regenerated after each snapshot, so none outlive the
    /// baseline they describe. Work is limited to sections changed by pending edits.
    fn rollbackPending(self: *World) !void {
        const Reserve = struct { roads: usize = 0, constructed: usize = 0, timers: usize = 0, blocks: bool = false };
        var required: std.AutoHashMapUnmanaged(u32, Reserve) = .empty;
        defer required.deinit(self.allocator);
        var undo_count: usize = 0;
        for (self.pending_operations.items) |pending| {
            undo_count += pending.road_undo.items.len;
            if (pending.cell_undo) |state| {
                const coords, _ = splitBlockCoords(pending.operation.block);
                const entry = try required.getOrPut(self.allocator, self.layout.encodeChunkCoords(coords));
                if (!entry.found_existing) entry.value_ptr.* = .{};
                entry.value_ptr.roads += @intFromBool(state.road != null);
                entry.value_ptr.constructed += @intFromBool(state.constructed);
                entry.value_ptr.timers += @intFromBool(state.timed != null);
                entry.value_ptr.blocks = entry.value_ptr.blocks or state.material != .none;
            }
        }
        try self.changed_road_chunks.ensureUnusedCapacity(self.allocator, undo_count);
        var reserves = required.iterator();
        while (reserves.next()) |entry| if (self.chunks.getPtr(entry.key_ptr.*)) |chunk| {
            const need = entry.value_ptr.*;
            try chunk.metadata.reserve(self.allocator, need.roads, need.constructed, need.timers);
            if (need.blocks) _ = try chunk.tryEnsureData(self.allocator);
        };

        var i = self.pending_operations.items.len;
        while (i > 0) {
            i -= 1;
            const pending = &self.pending_operations.items[i];
            for (pending.road_undo.items) |entry| {
                if (self.reader().isImmutable(.{ entry.block[0], entry.block[1], entry.block[2] })) continue;
                const coords, const local = splitBlockCoords(entry.block);
                const id = self.layout.encodeChunkCoords(coords);
                const chunk = self.chunks.getPtr(id) orelse continue;
                const road = chunk.metadata.roadPtr(transformations.index(local)) orelse continue;
                if (std.meta.eql(road.slope, entry.slope)) continue;
                road.slope = entry.slope;
                if (std.mem.indexOfScalar(u32, self.changed_road_chunks.items, id) == null)
                    self.changed_road_chunks.appendAssumeCapacity(id);
            }
            pending.road_undo.clearRetainingCapacity();
            if (pending.cell_undo) |state| {
                const coords, const local = splitBlockCoords(pending.operation.block);
                if (self.chunks.getPtr(self.layout.encodeChunkCoords(coords))) |chunk| {
                    if (!self.reader().isImmutable(.{ pending.operation.block[0], pending.operation.block[1], pending.operation.block[2] }))
                        state.restore(self.allocator, chunk, local);
                }
            }
            pending.cell_undo = null;
        }
    }

    fn replayPending(self: *World) void {
        for (self.pending_operations.items) |*pending| {
            if (pending.resolved_status != null) continue;
            self.tryApplyPending(pending, false) catch {
                self.last_edit_result = .{ .status = .resource_exhausted };
                break;
            };
        }
        self.stampRoadChanges();
        for (self.pending_operations.items) |pending| {
            const coords, _ = splitBlockCoords(pending.operation.block);
            self.releaseEmptyBacking(self.layout.encodeChunkCoords(coords));
        }
    }

    fn releaseEmptyBacking(self: *World, id: u32) void {
        if (self.chunks.getPtr(id)) |chunk| if (chunk.solid_block_count == 0 and chunk.content == .blocks) {
            chunk.content.deinit(self.allocator);
            chunk.content = .empty;
        };
    }

    fn retireResolved(self: *World) void {
        var i: usize = 0;
        while (i < self.pending_operations.items.len) {
            const pending = &self.pending_operations.items[i];
            if (pending.resolved_status == null) {
                i += 1;
                continue;
            }
            const coords, _ = splitBlockCoords(pending.operation.block);
            self.releaseEmptyBacking(self.layout.encodeChunkCoords(coords));
            pending.road_undo.deinit(self.allocator);
            pending.road_formations.deinit(self.allocator);
            _ = self.pending_operations.orderedRemove(i);
            self.pending_accounted_count = std.math.maxInt(usize);
        }
    }

    /// One ordered replay step: capture ownership, mutate material, then restore
    /// saved formations and evaluate the road transition against this exact state.
    fn tryApplyPending(self: *World, pending: *PendingOperation, stamp_material: bool) !void {
        if (pending.operation.blueprint != null) {
            const result = validateBlueprintFulfillment(self.reader(), &self.blueprints, pending.operation);
            if (result.status != .success) return;
            const coords, const local = splitBlockCoords(pending.operation.block);
            const chunk = self.chunks.getPtr(self.layout.encodeChunkCoords(coords)) orelse return;
            const before: CellState = .{ .material = .none, .road = null, .timed = null, .constructed = false, .cell_changes = chunk.cell_changes };
            try chunk.metadata.constructed.ensureUnusedCapacity(self.allocator, 1);
            const status = try chunk.prepareApply(self.allocator, local, pending.operation.action);
            if (status != .success) return;
            _ = chunk.applyPrepared(self.allocator, local, pending.operation.action);
            chunk.metadata.appendConstructedKnownEmptyAssumeCapacity(transformations.index(local));
            pending.cell_undo = before;
            if (stamp_material) {
                self.validation_revision +%= 1;
                chunk.validation_revision = self.validation_revision;
            }
            self.revealNeighbors(coords, chunk.flags);
            return;
        }
        if (!self.allowsOperation(pending.operation)) return;
        const coords, const local = splitBlockCoords(pending.operation.block);
        const chunk = self.chunks.getPtr(self.layout.encodeChunkCoords(coords)) orelse return;
        const before = CellState.capture(chunk, local);
        const can_apply = switch (pending.operation.action) {
            .put => before.material == .none,
            .remove => before.material != .none,
        };
        if (comptime @import("builtin").is_test) if (self.road_plan_counter) |counter| {
            counter.* += 1;
        };
        const context: roads.Context = .{ .allocator = self.allocator, .reader = self.reader(), .chunks = &self.chunks, .changed = &self.changed_road_chunks, .virtual_edit = if (can_apply) pending.operation else null, .max_plan_changes = self.pending_byte_limit / @sizeOf(roads.Undo) };
        var plan = try context.planReplay(pending.operation, before.road, pending.road_formations.items);
        defer plan.deinit(self.allocator);
        if (try roads.validateCompletedPlan(self.allocator, self.reader(), &self.blueprints, &self.chunks, plan, if (can_apply) pending.operation else null) != null) return;
        const undo_capacity = @max(pending.road_undo.capacity, plan.changes.len);
        const formed_capacity = pending.road_formations.items.len + @min(plan.changes.len, 20);
        const projected = self.pendingOperationBytes() - pending.road_undo.capacity * @sizeOf(roads.Undo) - pending.road_formations.capacity * @sizeOf(@import("road_data.zig").Slope) + undo_capacity * @sizeOf(roads.Undo) + @max(pending.road_formations.capacity, formed_capacity) * @sizeOf(@import("road_data.zig").Slope);
        if (projected > self.pending_byte_limit) return error.Capacity;
        defer self.pending_accounted_count = std.math.maxInt(usize);
        try pending.road_undo.ensureTotalCapacityPrecise(self.allocator, plan.changes.len);
        try pending.road_formations.ensureTotalCapacityPrecise(self.allocator, formed_capacity);
        try plan.reserveCommit(context);
        if (can_apply) {
            if (pending.mark_constructed and pending.operation.action == .put) try chunk.metadata.constructed.ensureUnusedCapacity(self.allocator, 1);
            _ = try chunk.prepareApply(self.allocator, local, pending.operation.action);
        }
        pending.road_undo.clearRetainingCapacity();
        for (plan.changes) |change| {
            const block: [3]u32 = .{ @intCast(change.cell[0]), @intCast(change.cell[1]), @intCast(change.cell[2]) };
            const changed_coords, const changed_local = splitBlockCoords(block);
            if (self.chunks.get(self.layout.encodeChunkCoords(changed_coords))) |changed_chunk| {
                if (changed_chunk.metadata.road(transformations.index(changed_local))) |road| pending.road_undo.appendAssumeCapacity(.{ .block = block, .slope = road.slope });
            }
            if (change.slope) |slope| {
                var seen = false;
                for (pending.road_formations.items) |formed| if (std.meta.eql(formed.high_endpoint, slope.high_endpoint) and formed.downhill == slope.downhill and formed.length == slope.length) {
                    seen = true;
                    break;
                };
                if (!seen) pending.road_formations.appendAssumeCapacity(slope);
            }
        }
        if (can_apply) {
            _ = chunk.applyPrepared(self.allocator, local, pending.operation.action);
            pending.cell_undo = before;
            if (pending.mark_constructed and pending.operation.action == .put) chunk.metadata.markConstructedAssumeCapacity(transformations.index(local));
            if (stamp_material) {
                self.validation_revision +%= 1;
                chunk.validation_revision = self.validation_revision;
            }
            self.revealNeighbors(coords, chunk.flags);
        }
        plan.applyPrepared(context);
    }

    fn stampRoadChanges(self: *World) void {
        for (self.changed_road_chunks.items) |id| if (self.chunks.getPtr(id)) |chunk| {
            self.validation_revision +%= 1;
            chunk.validation_revision = self.validation_revision;
        };
    }

    pub fn customShape(self: *const World, block: [3]u32) ?@import("engine").voxel_chunk.custom_block.Shape {
        const coords, const local = splitBlockCoords(block);
        const chunk = self.getChunk(coords) orelse return null;
        if (chunk.content.getBlock(local) != .custom) return null;
        const road = chunk.metadata.road(transformations.index(local)) orelse return null;
        return road.shape();
    }

    fn readShape(context: *anyopaque, block: [3]u32) ?@import("engine").voxel_chunk.custom_block.Shape {
        const self: *const World = @ptrCast(@alignCast(context));
        return self.customShape(block);
    }

    pub fn reader(self: *const World) block_rules.Reader {
        return .{ .layout = self.layout, .context = @constCast(self), .block_at = readBlock, .custom_shape_at = readShape, .immutable_at = immutableAt, .playable_y_inset = self.playable_y_inset };
    }

    /// Captures the merged local logical view without treating missing blocks as
    /// air. Optimistic real edits already live in chunks and are read once.
    pub fn plannedBlock(self: *const World, block: [3]u32) ?BlockType {
        const actual = readBlock(@constCast(self), block) orelse return null;
        if (actual != .none) return actual;
        return if (self.blueprints.targetAt(block)) |target| target.material else .none;
    }

    /// Borrowed package payload. Definitions/instances are cloned exactly once;
    /// fulfillment-only packages allocate nothing and never copy a bitmap.
    /// All fallible work is finished before any target/index publication.
    pub fn applyBlueprintChanges(self: *World, changes: []const blueprint_runtime.Change) !void {
        var definition_count: usize = 0;
        var instance_count: usize = 0;
        for (changes) |change| switch (change) {
            .definition => definition_count += 1,
            .instance => instance_count += 1,
            .fulfill => {},
        };
        if (definition_count == 0 and instance_count == 0) {
            for (changes) |change| _ = self.blueprints.fulfill(self.layout, change.fulfill);
            return;
        }
        const old_revision = self.blueprints.revision;
        const old_maximum = self.blueprints.max_definition_id;
        var definitions: std.ArrayList(u64) = .empty;
        defer definitions.deinit(self.allocator);
        try definitions.ensureTotalCapacity(self.allocator, definition_count);
        try self.blueprints.definitions.ensureUnusedCapacity(self.allocator, @intCast(definition_count));
        errdefer {
            for (definitions.items) |id| {
                var definition = self.blueprints.definitions.fetchRemove(id).?.value;
                definition.deinit(self.allocator);
            }
            self.blueprints.revision = old_revision;
            self.blueprints.max_definition_id = old_maximum;
        }
        // Temporarily staged definitions are visible only inside this main-thread
        // call. Failure removes them before the caller can observe the state.
        for (changes) |change| if (change == .definition) {
            const value = change.definition;
            if (self.blueprints.definitions.get(value.id)) |existing| {
                if (existing.owner != value.owner or !std.mem.eql(u8, existing.name, value.name) or !std.mem.eql(u32, &existing.definition.size, &value.definition.size) or !std.mem.eql(BlockType, existing.definition.cells, value.definition.cells)) return error.ConflictingBlueprintChange;
                continue;
            }
            const copy = try value.clone(self.allocator);
            self.blueprints.definitions.putAssumeCapacity(copy.id, copy);
            self.blueprints.max_definition_id = @max(self.blueprints.max_definition_id, copy.id);
            definitions.appendAssumeCapacity(copy.id);
        };
        const StagedPublication = struct { change_index: usize, publication: blueprint_runtime.PreparedPublication };
        var publications: std.ArrayList(StagedPublication) = .empty;
        defer {
            for (publications.items) |*staged| staged.publication.deinit(self.allocator);
            publications.deinit(self.allocator);
        }
        try publications.ensureTotalCapacity(self.allocator, instance_count);
        var staged_instances: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        defer staged_instances.deinit(self.allocator);
        try staged_instances.ensureTotalCapacity(self.allocator, @intCast(instance_count));
        var fulfillments: blueprint_runtime.FulfillmentSet = .empty;
        defer fulfillments.deinit(self.allocator);
        // Shallow borrowed footprint entries; each publication clones the entries
        // it extends. Earlier fulfillments filter only the next owned clones;
        // mutating these entries would change live state or an earlier snapshot.
        var shadow: std.AutoHashMapUnmanaged(ChunkId, blueprint_runtime.ChunkIndex) = .empty;
        defer shadow.deinit(self.allocator);
        var remaining_instances = instance_count;
        for (changes, 0..) |change, change_index| switch (change) {
            .definition => {},
            .instance => |value| {
                remaining_instances -= 1;
                if (self.blueprints.instances.get(value.id)) |existing| {
                    if (existing.definition_id != value.definition_id or existing.owner != value.owner or !std.mem.eql(u32, &existing.origin, &value.origin) or existing.rotation != value.rotation) return error.ConflictingBlueprintChange;
                    continue;
                }
                if (value.id <= self.blueprints.max_instance_id) continue; // Retired replay.
                if (staged_instances.contains(value.id)) return error.ConflictingBlueprintChange;
                const saved = self.blueprints.definitions.get(value.definition_id) orelse return error.UnknownDefinition;
                for (value.box_chunks) |id| if (!shadow.contains(id)) {
                    if (self.blueprints.chunks.get(id)) |index| try shadow.put(self.allocator, id, index);
                };
                var copy = try value.clone(self.allocator);
                const publication = blueprint_runtime.buildPublication(self.allocator, self.layout, saved.definition, copy, &shadow, &fulfillments) catch |err| {
                    copy.deinit(self.allocator);
                    return err;
                };
                staged_instances.putAssumeCapacity(value.id, publications.items.len);
                publications.appendAssumeCapacity(.{ .change_index = change_index, .publication = publication });
                var staged = publication.chunks.iterator();
                while (staged.next()) |entry| try shadow.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            },
            .fulfill => |value| {
                if (remaining_instances == 0 or fulfillments.contains(value)) continue;
                const instance = if (staged_instances.get(value.instance_id)) |slot|
                    publications.items[slot].publication.instance
                else
                    self.blueprints.instances.get(value.instance_id) orelse continue;
                if (!instance.active) continue;
                const saved = self.blueprints.definitions.get(instance.definition_id) orelse continue;
                if (value.cell_index >= saved.definition.cells.len or saved.definition.cells[value.cell_index] == .none or instance.isFulfilled(value.cell_index)) continue;
                const cell = blueprint_runtime.worldCell(self.layout, instance.origin, saved.definition.size, instance.rotation, blueprint.cellAtIndex(saved.definition.size, value.cell_index)) orelse continue;
                const coords, _ = splitBlockCoords(cell);
                const id = self.layout.encodeChunkCoords(coords);
                const index = shadow.get(id) orelse self.blueprints.chunks.get(id) orelse continue;
                const target = index.lookup.get(cell) orelse continue;
                if (target.instance_id != value.instance_id or target.cell_index != value.cell_index) continue;
                try fulfillments.put(self.allocator, value, {});
            },
        };
        try self.blueprints.instances.ensureUnusedCapacity(self.allocator, @intCast(publications.items.len));
        try self.blueprints.chunks.ensureUnusedCapacity(self.allocator, shadow.count());
        try self.blueprints.cleanup_queue.ensureTotalCapacity(self.allocator, self.blueprints.cleanup_queue.items.len + self.blueprints.instances.count() + publications.items.len);
        self.blueprints.layout = self.layout;
        // Commit the same order used to prepare immutable snapshots. In
        // particular, A's fulfillment must update A before B replaces its cell.
        var next_publication: usize = 0;
        for (changes, 0..) |change, change_index| switch (change) {
            .definition => {},
            .instance => {
                if (next_publication < publications.items.len and publications.items[next_publication].change_index == change_index) {
                    self.blueprints.publishPublication(&publications.items[next_publication].publication);
                    next_publication += 1;
                }
            },
            .fulfill => |value| _ = self.blueprints.fulfill(self.layout, value),
        };
        if (definitions.items.len != 0) self.blueprints.revision +%= 1;
    }

    fn immutableAt(context: *anyopaque, block: [3]u32) bool {
        const self: *const World = @ptrCast(@alignCast(context));
        return if (self.immutable_floor) |floor| floor.contains(block) else false;
    }

    fn allowsOperation(self: *const World, operation: BlockOperation) bool {
        const material = if (operation.action == .put) operation.action.put else BlockType.none;
        if (mutation_guard.validateWrites(self.reader(), &.{.{ .block = operation.block, .material = material }}) != null) return false;
        if (operation.action == .remove and self.blueprints.boxAt(self.layout, operation.block) != null) return false;
        if (self.blueprints.targetAt(operation.block)) |target| {
            const identity = operation.blueprint orelse return false;
            if (operation.action != .put or identity.instance_id != target.instance_id or identity.cell_index != target.cell_index) return false;
        } else if (operation.blueprint != null) return false;
        if (operation.action == .remove) {
            const existing = self.reader().get(.{ operation.block[0], operation.block[1], operation.block[2] }) orelse return false;
            if (existing != .none and existing.miningPolicy() == .forbidden) return false;
        }
        return true;
    }

    /// Only a performance hint changes locally. No command or revision is needed: the
    /// service independently reveals these neighbors when it commits the block operation.
    fn revealNeighbors(self: *World, coords: ChunkCoords, flags: ChunkFlags) void {
        for (std.enums.values(Side)) |side| {
            if (flags.getSideSolidness(side)) continue;
            const neighbor_coords = adjacentChunk(self.layout, coords, side) orelse continue;
            if (self.chunks.getPtr(self.layout.encodeChunkCoords(neighbor_coords))) |neighbor| {
                neighbor.flags.is_unreachable = false;
            }
        }
    }

    /// Retire both successful and failed commands before incorporating their snapshot.
    pub fn acknowledgeOperation(self: *World, request_id: u64) void {
        self.acknowledgeOperationResult(request_id, .success);
    }

    pub fn acknowledgeOperationResult(self: *World, request_id: u64, status: OperationStatus) void {
        for (self.pending_operations.items, 0..) |*pending, i| {
            if (pending.request_id == request_id) {
                if (status != .success) {
                    pending.resolved_status = status;
                    self.rollbackPending() catch {
                        self.last_edit_result = .{ .status = .resource_exhausted };
                        return;
                    };
                    const coords, _ = splitBlockCoords(pending.operation.block);
                    if (self.chunks.getPtr(self.layout.encodeChunkCoords(coords))) |chunk| {
                        self.validation_revision +%= 1;
                        chunk.validation_revision = self.validation_revision;
                    }
                }
                // The service acknowledges this client's commands in submission
                // order. An accepted prefix is the new baseline; later commands'
                // cell/section undo already includes its effects.
                pending.road_undo.deinit(self.allocator);
                pending.road_formations.deinit(self.allocator);
                _ = self.pending_operations.orderedRemove(i);
                self.pending_accounted_count = std.math.maxInt(usize);
                if (status != .success) self.replayPending();
                return;
            }
        }
    }

    /// Submitted operations survive eviction until acknowledged. Their results must never
    /// resurrect an evicted chunk; the subscription token decides whether to accept the data.
    pub fn removeChunk(self: *World, coords: ChunkCoords) void {
        self.chunks.fetchRemove(self.layout.encodeChunkCoords(coords)).?.value.deinit(self.allocator);
    }

    pub fn getChunk(self: *const World, coords: ChunkCoords) ?WorldChunk {
        inline for (0..3) |axis| std.debug.assert(coords[axis] >= 0 and coords[axis] < self.layout.size_in_chunks[axis]);
        return self.chunks.get(self.layout.encodeChunkCoords(coords));
    }

    pub fn ensureChunkData(self: *World, coords: ChunkCoords) *WorldChunkData {
        return self.chunks.getPtr(self.layout.encodeChunkCoords(coords)).?.ensureData(self.allocator);
    }

    pub fn isBlockSolid(self: *const World, block: [3]u32) ChunkNotReceivedError!bool {
        const coords, const local = splitBlockCoords(block);
        const chunk = self.getChunk(coords) orelse return error.ChunkNotReceived;
        return chunk.content.getBlock(local) != .none;
    }

    pub fn hasPendingMeshDependency(self: *const World, coords: ChunkCoords) bool {
        for (self.pending_operations.items) |pending| {
            for (pending.road_undo.items) |entry| {
                const road_coords, _ = splitBlockCoords(entry.block);
                if (@reduce(.And, road_coords == coords)) return true;
            }
            const changed, const local = splitBlockCoords(pending.operation.block);
            if (@reduce(.And, changed == coords)) return true;
            for (std.enums.values(Side)) |side| {
                const i = @intFromEnum(side);
                if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1)) continue;
                const neighbor = adjacentChunk(self.layout, changed, side) orelse continue;
                if (@reduce(.And, neighbor == coords)) return true;
            }
        }
        return false;
    }

    fn readBlock(context: *anyopaque, block: [3]u32) ?BlockType {
        const self: *const World = @ptrCast(@alignCast(context));
        if (comptime @import("builtin").is_test) if (self.physical_read_counter) |counter| {
            counter.* += 1;
        };
        const coords, const local = splitBlockCoords(block);
        const chunk = self.getChunk(coords) orelse return null;
        return chunk.content.getBlock(local);
    }

    pub fn previewOperation(self: *const World, operation: BlockOperation) EditResult {
        if (comptime @import("builtin").is_test) if (self.preview_call_counter) |counter| {
            counter.* += 1;
        };
        operation.validate(self.layout);
        if (operation.blueprint != null) return validateBlueprintFulfillment(self.reader(), &self.blueprints, operation);
        if (comptime @import("builtin").is_test) if (self.ordinary_preview_counter) |counter| {
            counter.* += 1;
        };
        const cells = tryCollectConstructed(self.allocator, self.layout, &self.chunks, operation.block) catch return .{ .status = .resource_exhausted };
        defer self.allocator.free(cells);
        const result = validateCompletedEdit(self.allocator, self.reader(), &self.blueprints, cells, operation);
        if (result.status != .success) return result;
        const coords, const local = splitBlockCoords(operation.block);
        const chunk = self.chunks.get(self.layout.encodeChunkCoords(coords)) orelse return .{ .status = .missing_data };
        var changed: std.ArrayList(u32) = .empty;
        defer changed.deinit(self.allocator);
        const context: roads.Context = .{ .allocator = self.allocator, .reader = self.reader(), .chunks = @constCast(&self.chunks), .changed = &changed, .virtual_edit = operation, .max_plan_changes = self.pending_byte_limit / @sizeOf(roads.Undo) };
        var plan = context.planAfterEdit(operation, chunk.metadata.road(transformations.index(local))) catch return .{ .status = .resource_exhausted };
        defer plan.deinit(self.allocator);
        const failure = roads.validateCompletedPlan(self.allocator, self.reader(), &self.blueprints, &self.chunks, plan, operation) catch return .{ .status = .resource_exhausted };
        if (failure) |reason| return .{ .status = if (reason.reason == .missing_data) .missing_data else .constraint_violation, .failure = reason };
        return result;
    }

    pub fn validationWindow(self: *const World, target: [3]u32) ValidationWindow {
        var window: ValidationWindow = .{ .chunks = validationChunks(self.layout, target), .blueprint_revision = self.blueprints.revision };
        for (window.chunks.ids[0..window.chunks.count], 0..) |id, i|
            window.revisions[i] = if (self.chunks.get(id)) |chunk| chunk.validation_revision else null;
        return window;
    }

    /// Gameplay entry point. Preview and authority use the same rules; unknown client
    /// dependencies produce missing_data rather than being interpreted as empty cells.
    pub fn pendingOperationBytes(self: *const World) usize {
        var dynamic = self.pending_dynamic_bytes;
        if (self.pending_accounted_count != self.pending_operations.items.len) {
            dynamic = 0;
            for (self.pending_operations.items) |pending| dynamic += pending.road_undo.capacity * @sizeOf(roads.Undo) + pending.road_formations.capacity * @sizeOf(@import("road_data.zig").Slope);
        }
        return self.pending_operations.capacity * @sizeOf(PendingOperation) + dynamic;
    }

    pub fn canQueueOperation(self: *World) bool {
        if (self.pending_accounted_count != self.pending_operations.items.len) {
            self.pending_dynamic_bytes = self.pendingOperationBytes() - self.pending_operations.capacity * @sizeOf(PendingOperation);
            self.pending_accounted_count = self.pending_operations.items.len;
        }
        return self.pending_operations.items.len < self.pending_operation_limit and self.pendingOperationBytes() < self.pending_byte_limit;
    }

    pub fn tryOperation(self: *World, operation: BlockOperation) EditResult {
        if (!self.canQueueOperation()) {
            const rejected: EditResult = .{ .status = .resource_exhausted };
            self.last_edit_result = rejected;
            return rejected;
        }
        const result = self.previewOperation(operation);
        self.last_edit_result = result;
        if (result.status != .success) return result;
        const status = self.enqueueOptimistic(operation, operation.action == .put) catch .resource_exhausted;
        if (status != .success) {
            const rejected: EditResult = .{ .status = status };
            self.last_edit_result = rejected;
            return rejected;
        }
        return result;
    }

    /// Prepare every allocation and road section change before mutating any
    /// optimistic block, metadata, flag, stamp, or pending command contents.
    fn enqueueOptimistic(self: *World, operation: BlockOperation, mark_constructed: bool) !OperationStatus {
        operation.validate(self.layout);
        if (operation.blueprint != null) return self.enqueueBlueprintFulfillment(operation);
        if (!self.allowsOperation(operation)) return .constraint_violation;
        if (!self.canQueueOperation()) return error.Capacity;
        const coords, const local = splitBlockCoords(operation.block);
        const id = self.layout.encodeChunkCoords(coords);
        const chunk = self.chunks.getPtr(id) orelse return .missing_data;
        const existing = chunk.content.getBlock(local);
        if (operation.action == .put and existing != .none) return .already_exists;
        if (operation.action == .remove and existing == .none) return .already_removed;
        const before = CellState.capture(chunk, local);
        if (comptime @import("builtin").is_test) if (self.road_plan_counter) |counter| {
            counter.* += 1;
        };
        const context: roads.Context = .{ .allocator = self.allocator, .reader = self.reader(), .chunks = &self.chunks, .changed = &self.changed_road_chunks, .virtual_edit = operation, .max_plan_changes = self.pending_byte_limit / @sizeOf(roads.Undo) };
        var plan = try context.planAfterEdit(operation, before.road);
        defer plan.deinit(self.allocator);
        if (try roads.validateCompletedPlan(self.allocator, self.reader(), &self.blueprints, &self.chunks, plan, operation)) |failure| {
            self.last_edit_result = .{ .status = if (failure.reason == .missing_data) .missing_data else .constraint_violation, .failure = failure };
            return self.last_edit_result.?.status;
        }
        const planned_pending_capacity = @max(self.pending_operations.capacity, self.pending_operations.items.len + 1);
        const predicted_bytes = self.pendingOperationBytes() - self.pending_operations.capacity * @sizeOf(PendingOperation) + planned_pending_capacity * @sizeOf(PendingOperation) + plan.changes.len * @sizeOf(roads.Undo) + @as(usize, @min(plan.changes.len, 20)) * @sizeOf(@import("road_data.zig").Slope);
        if (predicted_bytes > self.pending_byte_limit) return error.Capacity;
        var pending: PendingOperation = .{ .operation = operation, .cell_undo = before, .mark_constructed = mark_constructed };
        errdefer {
            pending.road_undo.deinit(self.allocator);
            pending.road_formations.deinit(self.allocator);
        }
        try pending.road_undo.ensureTotalCapacityPrecise(self.allocator, plan.changes.len);
        try pending.road_formations.ensureTotalCapacityPrecise(self.allocator, @min(plan.changes.len, 20));
        for (plan.changes) |change| {
            const block: [3]u32 = .{ @intCast(change.cell[0]), @intCast(change.cell[1]), @intCast(change.cell[2]) };
            const changed_coords, const changed_local = splitBlockCoords(block);
            if (self.chunks.get(self.layout.encodeChunkCoords(changed_coords))) |changed_chunk| {
                if (changed_chunk.metadata.road(transformations.index(changed_local))) |road|
                    pending.road_undo.appendAssumeCapacity(.{ .block = block, .slope = road.slope });
            }
            if (change.slope) |slope| {
                var seen = false;
                for (pending.road_formations.items) |formed| {
                    if (std.meta.eql(formed.high_endpoint, slope.high_endpoint) and formed.downhill == slope.downhill and formed.length == slope.length) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) pending.road_formations.appendAssumeCapacity(slope);
            }
        }
        const next_capacity = @max(self.pending_operations.capacity, self.pending_operations.items.len + 1);
        const retained = self.pendingOperationBytes() - self.pending_operations.capacity * @sizeOf(PendingOperation) + next_capacity * @sizeOf(PendingOperation) + pending.road_undo.capacity * @sizeOf(roads.Undo) + pending.road_formations.capacity * @sizeOf(@import("road_data.zig").Slope);
        if (retained > self.pending_byte_limit) return error.Capacity;
        try self.pending_operations.ensureTotalCapacityPrecise(self.allocator, self.pending_operations.items.len + 1);
        try plan.reserveCommit(context);
        if (mark_constructed) try chunk.metadata.constructed.ensureUnusedCapacity(self.allocator, 1);
        const status = try chunk.prepareApply(self.allocator, local, operation.action);
        std.debug.assert(status == .success);
        // All remaining operations are allocation-free.
        _ = chunk.applyPrepared(self.allocator, local, operation.action);
        if (mark_constructed) chunk.metadata.markConstructedAssumeCapacity(transformations.index(local));
        plan.applyPrepared(context);
        self.validation_revision +%= 1;
        chunk.validation_revision = self.validation_revision;
        self.revealNeighbors(coords, chunk.flags);
        self.pending_operations.appendAssumeCapacity(pending);
        self.pending_dynamic_bytes += pending.road_undo.capacity * @sizeOf(roads.Undo) + pending.road_formations.capacity * @sizeOf(@import("road_data.zig").Slope);
        self.pending_accounted_count = self.pending_operations.items.len;
        self.stampRoadChanges();
        return .success;
    }

    fn enqueueBlueprintFulfillment(self: *World, operation: BlockOperation) !OperationStatus {
        const coords, const local = splitBlockCoords(operation.block);
        const chunk = self.chunks.getPtr(self.layout.encodeChunkCoords(coords)) orelse return .missing_data;
        const before: CellState = .{ .material = .none, .road = null, .timed = null, .constructed = false, .cell_changes = chunk.cell_changes };
        const capacity = @max(self.pending_operations.capacity, self.pending_operations.items.len + 1);
        if (self.pendingOperationBytes() - self.pending_operations.capacity * @sizeOf(PendingOperation) + capacity * @sizeOf(PendingOperation) > self.pending_byte_limit) return error.Capacity;
        try self.pending_operations.ensureTotalCapacityPrecise(self.allocator, self.pending_operations.items.len + 1);
        try chunk.metadata.constructed.ensureUnusedCapacity(self.allocator, 1);
        const status = try chunk.prepareApply(self.allocator, local, operation.action);
        if (status != .success) return status;
        _ = chunk.applyPrepared(self.allocator, local, operation.action);
        chunk.metadata.appendConstructedKnownEmptyAssumeCapacity(transformations.index(local));
        self.pending_operations.appendAssumeCapacity(.{ .operation = operation, .cell_undo = before, .mark_constructed = true });
        self.pending_accounted_count = self.pending_operations.items.len;
        self.validation_revision +%= 1;
        chunk.validation_revision = self.validation_revision;
        self.revealNeighbors(coords, chunk.flags);
        return .success;
    }

    /// Low-level fixture/replay helper uses the same bounded failure-safe
    /// admission. Gameplay additionally performs placement validation.
    pub fn setBlockUnchecked(self: *World, block: [3]u32, block_type: BlockType) void {
        const operation: BlockOperation = .{ .block = block, .action = if (block_type == .none) .remove else .{ .put = block_type } };
        const status = self.enqueueOptimistic(operation, false) catch .resource_exhausted;
        if (status == .resource_exhausted) self.last_edit_result = .{ .status = status };
    }

    pub fn setBlock(self: *World, block: [3]u32, block_type: BlockType) EditResult {
        return self.tryOperation(.{ .block = block, .action = if (block_type == .none) .remove else .{ .put = block_type } });
    }
};

fn insertGeneratedChunks(
    world: *World,
    generator: world_generator.WorldGenerator,
    column: @Vector(2, i32),
    z_start: i32,
    z_end: i32,
) !void {
    var prepared = try generator.prepare(world.allocator, world.layout);
    defer prepared.deinit(world.allocator);
    const column_generator = world_generator.ColumnGenerator.init(&prepared, column);
    var z = z_start;
    while (z < z_end) : (z += 1) {
        try world.insertChunk(.{ column[0], column[1], z }, column_generator.generateChunk(world.allocator, z));
    }
}

test "normalized signed chunk coordinates round-trip through the shared storage ID" {
    const coords = test_layout.normalizeChunkCoords(.{ -1, 20, 3 }).?;
    const id = test_layout.encodeChunkCoords(coords);
    try std.testing.expectEqual(test_layout.encodeChunkId(WORLD_SIZE[0] - 1, 20, 3), id);
    try std.testing.expectEqual(coords, test_layout.decodeChunkId(id));
    try std.testing.expectEqual(ChunkCoords{ 0, 20, 3 }, adjacentChunk(&test_layout, coords, .right).?);
    try std.testing.expectEqual(null, adjacentChunk(&test_layout, .{ 0, 0, 0 }, .front));
    try std.testing.expectEqual(null, adjacentChunk(&test_layout, .{ 0, 0, 0 }, .bottom));
}

test "chunks are available only after they are inserted" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();

    try std.testing.expectEqual(null, world.getChunk(.{ 3, 7, 4 }));

    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 3, 7 }, 4, 5);
    try std.testing.expect(world.hasChunk(.{ 3, 7, 4 }));
    try std.testing.expectEqual(null, world.getChunk(.{ 3, 7, 3 }));

    world.removeChunk(.{ 3, 7, 4 });
    try std.testing.expectEqual(null, world.getChunk(.{ 3, 7, 4 }));
}

test "removing and replacing a supported block leaves authoritative revisions unchanged" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();

    const surface_chunk_z = WORLD_SIZE[2] / 2 - 1;
    try insertGeneratedChunks(&world, .flat, .{ 0, 0 }, surface_chunk_z, surface_chunk_z + 1);
    const block = [3]u32{ 10, 10, surface_chunk_z * CHUNK_SIZE + CHUNK_SIZE / 2 - 1 };

    try std.testing.expectEqual(OperationStatus.success, world.tryOperation(.{ .block = block, .action = .remove }).status);
    try std.testing.expect(!try world.isBlockSolid(block));
    try std.testing.expect(try world.isBlockSolid(.{ block[0], block[1], block[2] - 1 }));

    const chunk_coords, _ = splitBlockCoords(block);
    try std.testing.expect(!world.getChunk(chunk_coords).?.isDirty());

    try std.testing.expectEqual(OperationStatus.success, world.tryOperation(.{ .block = block, .action = .{ .put = .dirt } }).status);
    try std.testing.expect(try world.isBlockSolid(block));
    try std.testing.expectEqual(0, world.getChunk(chunk_coords).?.chunk_revision);
    try std.testing.expectEqual(2, world.pending_operations.items.len);
}

test "editing a generated stone chunk keeps the rest of its blocks" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 }, 0, 1);

    const block = [3]u32{ 5, 5, CHUNK_SIZE - 1 };
    try std.testing.expectEqual(OperationStatus.success, world.tryOperation(.{ .block = block, .action = .remove }).status);
    try std.testing.expect(!try world.isBlockSolid(block));

    const chunk = world.getChunk(.{ 0, 0, 0 }).?;
    try std.testing.expect(!chunk.isDirty());
    try std.testing.expect(!chunk.flags.solid_top);
    try std.testing.expect(chunk.flags.solid_bottom);
    try std.testing.expectEqual(BlockType.stone, chunk.content.blocks.blocks[0][0][0]);
}

test "editing rejects occupied placements and repeated removals without queueing them" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    try insertGeneratedChunks(&world, .flat, .{ 0, 0 }, 0, 1);

    const interior = [3]u32{ 0, 0, 4 };
    try std.testing.expectEqual(OperationStatus.already_exists, world.tryOperation(.{ .block = interior, .action = .{ .put = .dirt } }).status);
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    try std.testing.expectEqual(OperationStatus.success, world.tryOperation(.{ .block = interior, .action = .remove }).status);
    try std.testing.expectEqual(OperationStatus.already_removed, world.tryOperation(.{ .block = interior, .action = .remove }).status);
    try std.testing.expectEqual(1, world.pending_operations.items.len);
}

test "edits to unreceived chunks fail without queueing or changing cached chunks" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    // Cache the air at the top of the world, but not the chunk directly below it.
    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 }, WORLD_SIZE[2] - 1, WORLD_SIZE[2]);

    const block = [3]u32{ 5, 5, (WORLD_SIZE[2] - 1) * CHUNK_SIZE - 1 };
    try std.testing.expectEqual(OperationStatus.missing_data, world.tryOperation(.{ .block = block, .action = .remove }).status);
    try std.testing.expectEqual(OperationStatus.missing_data, world.tryOperation(.{ .block = block, .action = .{ .put = .dirt } }).status);
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    try std.testing.expect(!world.hasChunk(.{ 0, 0, WORLD_SIZE[2] - 2 }));
    try std.testing.expect(world.getChunk(.{ 0, 0, WORLD_SIZE[2] - 1 }).?.content == .empty);
    try std.testing.expect(!world.getChunk(.{ 0, 0, WORLD_SIZE[2] - 1 }).?.isDirty());
}

fn createSolidChunk(revision: u64) WorldChunk {
    const world_chunk_data = std.testing.allocator.create(WorldChunkData) catch @panic("OOM");
    world_chunk_data.* = WorldChunkData.initSolid();
    var chunk = WorldChunk.initBlocks(world_chunk_data);
    chunk.chunk_revision = revision;
    return chunk;
}

test "empty chunk has no solid blocks and no solid sides" {
    const empty = WorldChunk.initEmpty();

    inline for (std.meta.fields(ChunkFlags)) |field| {
        try std.testing.expect(!@field(empty.flags, field.name));
    }
    try std.testing.expectEqual(WorldChunkData.initEmpty().getMetaFlags(), empty.flags);
    try std.testing.expect(!empty.isDirty());

    try std.testing.expectEqual(BlockType.none, empty.content.getBlock(.{ 31, 0, 17 }));
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&WorldChunkData.initEmpty().blocks),
        std.mem.asBytes(&empty.content.toData().blocks),
    );
}

test "chunk content with blocks is indexed by local x, y, z" {
    var world_chunk_data = WorldChunkData.initEmpty();
    world_chunk_data.blocks[3][2][1] = .dirt;
    const chunk = WorldChunk.initBlocks(&world_chunk_data);

    try std.testing.expectEqual(BlockType.dirt, chunk.content.getBlock(.{ 1, 2, 3 }));
    try std.testing.expectEqual(BlockType.none, chunk.content.getBlock(.{ 3, 2, 1 }));
    try std.testing.expectEqual(world_chunk_data.getMetaFlags(), chunk.flags);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&world_chunk_data.blocks),
        std.mem.asBytes(&chunk.content.toData().blocks),
    );
}

test "materializing an empty chunk fills it with air and isn't a modification" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();

    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());

    const world_chunk_data = world.ensureChunkData(coords);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&WorldChunkData.initEmpty().blocks),
        std.mem.asBytes(&world_chunk_data.blocks),
    );
    try std.testing.expectEqual(world_chunk_data, world.ensureChunkData(coords));

    const chunk = world.getChunk(coords).?;
    try std.testing.expectEqual(world_chunk_data, chunk.content.blocks);
    try std.testing.expectEqual(WorldChunk.initEmpty().flags, chunk.flags);
    try std.testing.expect(!chunk.isDirty());
    try std.testing.expectEqual(0, world.pending_operations.items.len);

    world.removeChunk(coords);
}

test "edits on both sides of a chunk border preserve neighboring contents and revisions" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();

    const lower = ChunkCoords{ 0, 0, WORLD_SIZE[2] - 2 };
    const upper = ChunkCoords{ 0, 0, WORLD_SIZE[2] - 1 };
    try world.insertChunk(lower, createSolidChunk(0));
    try world.insertChunk(upper, WorldChunk.initEmpty());
    const original_upper = world.getChunk(upper).?;

    const lower_top = [3]u32{ 3, 4, upper[2] * CHUNK_SIZE - 1 };
    try std.testing.expectEqual(OperationStatus.success, world.tryOperation(.{ .block = lower_top, .action = .remove }).status);
    try std.testing.expect(!try world.isBlockSolid(lower_top));
    try std.testing.expectEqual(0, world.getChunk(lower).?.chunk_revision);
    try std.testing.expectEqual(original_upper, world.getChunk(upper).?);

    try std.testing.expectEqual(OperationStatus.success, world.tryOperation(.{ .block = lower_top, .action = .{ .put = .dirt } }).status);
    const upper_bottom = [3]u32{ 3, 4, upper[2] * CHUNK_SIZE };
    try std.testing.expectEqual(OperationStatus.success, world.tryOperation(.{ .block = upper_bottom, .action = .{ .put = .dirt } }).status);

    try std.testing.expectEqual(0, world.getChunk(lower).?.chunk_revision);
    const upper_chunk = world.getChunk(upper).?;
    try std.testing.expectEqual(0, upper_chunk.chunk_revision);
    try std.testing.expectEqual(BlockType.dirt, upper_chunk.content.getBlock(.{ 3, 4, 0 }));
    try std.testing.expectEqual(BlockType.none, upper_chunk.content.getBlock(.{ 3, 4, 1 }));
    try std.testing.expectEqual(3, world.pending_operations.items.len);
}

test "earth placement at the world bottom still needs its footprint" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());

    const result = world.tryOperation(.{ .block = .{ 7, 8, 0 }, .action = .{ .put = .dirt } });
    try std.testing.expectEqual(OperationStatus.constraint_violation, result.status);
    try std.testing.expectEqual(block_rules.Reason.earth_footprint, result.failure.?.reason);
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    try std.testing.expectEqual(0, world.getChunk(.{ 0, 0, 0 }).?.chunk_revision);
}

test "unconfigured resources reject mining before blocks metadata or pending edits change" {
    const a = std.testing.allocator;
    var world = try World.init(a, &test_layout);
    defer world.deinit();
    const data = try a.create(WorldChunkData);
    data.* = WorldChunkData.initEmpty();
    var source = WorldChunk.initBlocks(data);
    for ([_]BlockType{ .metal_ore, .limestone, .clay, .coal }) |resource| {
        data.blocks[3][2][1] = resource;
        try source.metadata.timed.trySchedule(a, .{ .block = transformations.index(.{ 1, 2, 3 }), .kind = .grow_grass, .due_tick = 99 });
        const result = validateEdit(a, .{ .layout = world.layout, .context = &source, .block_at = struct {
            fn read(context: *anyopaque, block: [3]u32) ?BlockType {
                const chunk: *WorldChunk = @ptrCast(@alignCast(context));
                return chunk.content.getBlock(splitBlockCoords(block)[1]);
            }
        }.read }, &.{}, .{ .block = .{ 1, 2, 3 }, .action = .remove });
        try std.testing.expectEqual(OperationStatus.constraint_violation, result.status);
        try std.testing.expectEqual(block_rules.Reason.mining_forbidden, result.failure.?.reason);
        try std.testing.expectEqual(resource, source.content.getBlock(.{ 1, 2, 3 }));
        try std.testing.expectEqual(@as(usize, 1), source.metadata.timed.events.items.len);
        try std.testing.expectEqual(@as(u64, 0), source.chunk_revision);
        try std.testing.expectEqual(@as(u64, 0), source.cell_changes.sequence);
        try std.testing.expectEqual(OperationStatus.constraint_violation, try source.tryApply(a, .{ 1, 2, 3 }, .remove));
    }
    source.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), world.pending_operations.items.len);
}

test "foliage removal succeeds with no item and ordinary optimistic retirement" {
    const a = std.testing.allocator;
    var world = try World.init(a, &test_layout);
    defer world.deinit();
    const data = try a.create(WorldChunkData);
    data.* = WorldChunkData.initEmpty();
    data.blocks[3][2][1] = .leaves;
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initBlocks(data));
    const result = world.tryOperation(.{ .block = .{ 1, 2, 3 }, .action = .remove });
    try std.testing.expectEqual(OperationStatus.success, result.status);
    try std.testing.expectEqual(@as(?BlockType, null), result.mined_type);
    try std.testing.expectEqual(@as(usize, 1), world.pending_operations.items.len);
    world.pending_operations.items[0].request_id = 7;
    world.acknowledgeOperation(7);
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    try std.testing.expectEqual(@as(usize, 0), world.pending_operations.items.len);
    try std.testing.expectEqual(BlockType.none, world.getChunk(.{ 0, 0, 0 }).?.content.getBlock(.{ 1, 2, 3 }));
}

test "deeprock guards low-level material changes debug writes and optimistic replay" {
    const a = std.testing.allocator;
    var world = try World.init(a, &test_layout);
    defer world.deinit();
    const data = try a.create(WorldChunkData);
    data.* = WorldChunkData.initEmpty();
    data.blocks[0][2][1] = .deeprock;
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initBlocks(data));
    const chunk = world.chunks.getPtr(world.layout.encodeChunkId(0, 0, 0)).?;
    const before = chunk.cell_changes.sequence;
    try std.testing.expectEqual(OperationStatus.constraint_violation, try chunk.tryApply(a, .{ 1, 2, 0 }, .remove));
    try std.testing.expectEqual(OperationStatus.constraint_violation, chunk.applyPrepared(a, .{ 1, 2, 0 }, .{ .put = .sand }));
    chunk.changeType(.{ 1, 2, 0 }, .stone);
    world.setBlockUnchecked(.{ 1, 2, 0 }, .none);
    try std.testing.expectEqual(BlockType.deeprock, data.blocks[0][2][1]);
    try std.testing.expectEqual(before, chunk.cell_changes.sequence);
    try std.testing.expectEqual(@as(usize, 0), world.pending_operations.items.len);

    // A pending edit from an older baseline must not overwrite newly authoritative floor.
    const target = [3]u32{ 7, 8, 2 };
    world.setBlockUnchecked(target, .snow);
    const snapshot_data = try a.create(WorldChunkData);
    snapshot_data.* = WorldChunkData.initEmpty();
    snapshot_data.blocks[2][8][7] = .deeprock;
    var snapshot = WorldChunk.initBlocks(snapshot_data);
    snapshot.chunk_revision = 1;
    try world.insertChunk(.{ 0, 0, 0 }, snapshot);
    try std.testing.expectEqual(BlockType.deeprock, world.getChunk(.{ 0, 0, 0 }).?.content.getBlock(.{ 7, 8, 2 }));
}

test "canonical floor rejects a complete mixed write set independently of loaded material" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    world.immutable_floor = .{ .context = &test_layout, .immutable_at = struct {
        fn contains(_: *const anyopaque, block: [3]u32) bool {
            return block[2] < 2;
        }
    }.contains };
    const writes = [_]mutation_guard.Write{
        .{ .block = .{ 3, 3, 8 }, .material = .none },
        .{ .block = .{ 3, 3, 1 }, .material = .sand },
    };
    const failure = mutation_guard.validateWrites(world.reader(), &writes).?;
    try std.testing.expectEqual(block_rules.Reason.immutable_cell, failure.reason);
    try std.testing.expectEqualDeep(block_rules.Cell{ 3, 3, 1 }, failure.subject);
    // Residency cannot turn a protected coordinate into a mutable one.
    try std.testing.expectEqual(OperationStatus.constraint_violation, world.previewOperation(.{ .block = .{ 3, 3, 1 }, .action = .remove }).status);
    try std.testing.expectEqual(@as(usize, 0), world.pending_operations.items.len);
}

test "the default editing API validates before queueing and preserves earth supports" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const data = try std.testing.allocator.create(WorldChunkData);
    data.* = WorldChunkData.initFlat();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initBlocks(data));
    const target = [3]u32{ 10, 10, 16 };
    try std.testing.expectEqual(OperationStatus.constraint_violation, world.setBlock(target, .stone).status);
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    try std.testing.expectEqual(OperationStatus.success, world.setBlock(target, .dirt).status);
    const support = [3]u32{ 9, 9, 15 };
    const refused = world.setBlock(support, .none);
    try std.testing.expectEqual(OperationStatus.constraint_violation, refused.status);
    try std.testing.expectEqual(block_rules.Reason.would_remove_support, refused.failure.?.reason);
    try std.testing.expectEqual(block_rules.Reason.earth_footprint, refused.failure.?.cause);
    try std.testing.expect(try world.isBlockSolid(support));
    try std.testing.expectEqual(1, world.pending_operations.items.len);
    const removed = world.setBlock(target, .none);
    try std.testing.expectEqual(OperationStatus.success, removed.status);
    try std.testing.expectEqual(BlockType.dirt, removed.mined_type.?);
}

test "placing a block into an empty chunk keeps the rest of it air" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());

    world.setBlockUnchecked(.{ 1, 2, 3 }, .dirt);

    var expected = WorldChunkData.initEmpty();
    expected.blocks[3][2][1] = .dirt;
    const chunk = world.getChunk(.{ 0, 0, 0 }).?;
    try std.testing.expect(chunk.content == .blocks);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.blocks), std.mem.asBytes(&chunk.content.blocks.blocks));
    try std.testing.expectEqual(expected.getMetaFlags(), chunk.flags);
    try std.testing.expectEqual(1, chunk.solid_block_count);
}

test "solid block count follows block edits" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();

    const coords = ChunkCoords{ 0, 0, 0 };
    const full_count = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
    try world.insertChunk(coords, createSolidChunk(0));
    try std.testing.expectEqual(full_count, world.getChunk(coords).?.solid_block_count);

    world.setBlockUnchecked(.{ 1, 2, 3 }, .none);
    try std.testing.expectEqual(full_count - 1, world.getChunk(coords).?.solid_block_count);
    world.setBlockUnchecked(.{ 1, 2, 3 }, .none);
    try std.testing.expectEqual(full_count - 1, world.getChunk(coords).?.solid_block_count);
    world.setBlockUnchecked(.{ 4, 5, 6 }, .dirt);
    try std.testing.expectEqual(full_count - 1, world.getChunk(coords).?.solid_block_count);
    world.setBlockUnchecked(.{ 1, 2, 3 }, .dirt);

    const chunk = world.getChunk(coords).?;
    try std.testing.expectEqual(full_count, chunk.solid_block_count);
    try std.testing.expectEqual(chunk.content.blocks.countSolidBlocks(), chunk.solid_block_count);
    try std.testing.expectEqual(0, chunk.chunk_revision);
}

test "removing the last solid block turns the chunk back into empty" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();

    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlockUnchecked(.{ 1, 2, 3 }, .dirt);
    world.setBlockUnchecked(.{ 4, 5, 6 }, .stone);

    world.setBlockUnchecked(.{ 1, 2, 3 }, .none);
    try std.testing.expect(world.getChunk(coords).?.content == .blocks);

    world.setBlockUnchecked(.{ 4, 5, 6 }, .none);
    const chunk = world.getChunk(coords).?;
    try std.testing.expect(chunk.content == .empty);
    try std.testing.expectEqual(WorldChunk.initEmpty().flags, chunk.flags);
    try std.testing.expectEqual(0, chunk.solid_block_count);
    // The service has not acknowledged these optimistic changes yet.
    try std.testing.expectEqual(0, chunk.chunk_revision);
}

test "setting air into an empty chunk keeps it empty" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();

    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlockUnchecked(.{ 1, 2, 3 }, .none);

    const chunk = world.getChunk(coords).?;
    try std.testing.expect(chunk.content == .empty);
    try std.testing.expectEqual(0, chunk.chunk_revision);
}

test "failed optimistic put restores authority while preserving later edits" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlockUnchecked(.{ 1, 2, 3 }, .dirt);
    world.pending_operations.items[0].request_id = 10;
    world.setBlockUnchecked(.{ 4, 5, 6 }, .grass);
    world.pending_operations.items[1].request_id = 11;

    // A worker won the race to the first block. Rebase the two pending commands on its push.
    var authority = WorldChunk.initEmpty();
    defer authority.deinit(std.testing.allocator);
    _ = authority.apply(std.testing.allocator, .{ 1, 2, 3 }, .{ .put = .stone });
    authority.chunk_revision = 1;
    try world.insertChunk(coords, authority.clone(std.testing.allocator));
    try std.testing.expectEqual(BlockType.stone, world.getChunk(coords).?.content.getBlock(.{ 1, 2, 3 }));
    try std.testing.expectEqual(BlockType.grass, world.getChunk(coords).?.content.getBlock(.{ 4, 5, 6 }));

    world.acknowledgeOperation(10); // already_exists, same authoritative revision
    try world.insertChunk(coords, authority.clone(std.testing.allocator));
    const reconciled = world.getChunk(coords).?;
    try std.testing.expectEqual(BlockType.stone, reconciled.content.getBlock(.{ 1, 2, 3 }));
    try std.testing.expectEqual(BlockType.grass, reconciled.content.getBlock(.{ 4, 5, 6 }));
    try std.testing.expectEqual(1, reconciled.chunk_revision);
    try std.testing.expectEqual(1, world.pending_operations.items.len);
}

test "acknowledging edits in order preserves pending remove and put on the same block" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlockUnchecked(.{ 1, 2, 3 }, .dirt);
    world.setBlockUnchecked(.{ 1, 2, 3 }, .none);
    world.setBlockUnchecked(.{ 1, 2, 3 }, .grass);
    for (world.pending_operations.items, 1..) |*pending, id| pending.request_id = id;
    var authority = WorldChunk.initEmpty();
    defer authority.deinit(std.testing.allocator);
    for ([_]BlockAction{ .{ .put = .dirt }, .remove, .{ .put = .grass } }, 1..) |action, id| {
        _ = authority.apply(std.testing.allocator, .{ 1, 2, 3 }, action);
        authority.chunk_revision = @intCast(id);
        world.acknowledgeOperation(id);
        try world.insertChunk(coords, authority.clone(std.testing.allocator));
        try std.testing.expectEqual(BlockType.grass, world.getChunk(coords).?.content.getBlock(.{ 1, 2, 3 }));
        try std.testing.expectEqual(id, world.getChunk(coords).?.chunk_revision);
    }
    try std.testing.expectEqual(0, world.pending_operations.items.len);
}

test "failed remove and unrelated worker edits survive reconciliation" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    var initial = WorldChunk.initEmpty();
    _ = initial.apply(std.testing.allocator, .{ 1, 2, 3 }, .{ .put = .dirt });
    try world.insertChunk(coords, initial);
    world.setBlockUnchecked(.{ 1, 2, 3 }, .none);
    world.pending_operations.items[0].request_id = 1;
    world.setBlockUnchecked(.{ 1, 2, 3 }, .grass);
    world.pending_operations.items[1].request_id = 2;

    var authority = WorldChunk.initEmpty();
    _ = authority.apply(std.testing.allocator, .{ 4, 5, 6 }, .{ .put = .stone });
    authority.chunk_revision = 3;
    world.acknowledgeOperation(1); // already_removed
    try world.insertChunk(coords, authority);
    const chunk = world.getChunk(coords).?;
    try std.testing.expectEqual(BlockType.grass, chunk.content.getBlock(.{ 1, 2, 3 }));
    try std.testing.expectEqual(BlockType.stone, chunk.content.getBlock(.{ 4, 5, 6 }));
    try std.testing.expectEqual(2, chunk.solid_block_count);
}

test "material rollback restores authoritative construction and ordered timers after repeated cell edits" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    const local = [3]u5{ 1, 2, 3 };
    const index = transformations.index(local);
    var authority = WorldChunk.initEmpty();
    defer authority.deinit(std.testing.allocator);
    _ = authority.apply(std.testing.allocator, local, .{ .put = .dirt });
    _ = authority.apply(std.testing.allocator, .{ 4, 5, 6 }, .{ .put = .dirt });
    authority.metadata.markConstructed(std.testing.allocator, index);
    authority.metadata.timed.schedule(std.testing.allocator, .{ .block = index, .kind = .compact_dirt, .due_tick = 30 });
    authority.metadata.timed.schedule(std.testing.allocator, .{ .block = transformations.index(.{ 4, 5, 6 }), .kind = .compact_dirt, .due_tick = 20 });
    try world.insertChunk(coords, authority.clone(std.testing.allocator));
    world.setBlockUnchecked(.{ 1, 2, 3 }, .none);
    world.pending_operations.items[0].request_id = 1;
    world.setBlockUnchecked(.{ 1, 2, 3 }, .snow);
    world.pending_operations.items[1].request_id = 2;

    // A newer baseline must replace every part of the removed cell's undo,
    // including its timer, while the later put remains visible during replay.
    authority.metadata.timed.schedule(std.testing.allocator, .{ .block = index, .kind = .grow_grass, .due_tick = 10 });
    authority.chunk_revision = 2;
    try world.insertChunk(coords, authority.clone(std.testing.allocator));
    try std.testing.expectEqual(BlockType.snow, world.getChunk(coords).?.content.getBlock(local));
    const window = world.validationWindow(.{ 1, 2, 3 });
    world.acknowledgeOperationResult(1, .constraint_violation);
    try std.testing.expect(!window.isCurrent(&world));
    world.acknowledgeOperationResult(2, .already_exists);
    const chunk = world.getChunk(coords).?;
    try std.testing.expectEqual(BlockType.dirt, chunk.content.getBlock(local));
    try std.testing.expectEqualSlices(transformations.BlockIndex, authority.metadata.constructed.items, chunk.metadata.constructed.items);
    try std.testing.expectEqualDeep(authority.metadata.timed.events.items, chunk.metadata.timed.events.items);
    try std.testing.expectEqualDeep(boundary_mask.extract(chunk.content.blocks), chunk.boundaries);
    try std.testing.expectEqual(chunk.content.blocks.countSolidBlocks(), chunk.solid_block_count);
}

test "older authoritative snapshots cannot undo a newer revision" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, createSolidChunk(3));
    const older = createSolidChunk(2);
    defer older.deinit(std.testing.allocator);
    try std.testing.expectError(error.StaleChunk, world.insertChunk(coords, older));
    try std.testing.expectEqual(3, world.getChunk(coords).?.chunk_revision);
}

test "local conflicts queue no command and do not change metadata" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    world.setBlockUnchecked(.{ 0, 0, 0 }, .none);
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    world.setBlockUnchecked(.{ 0, 0, 0 }, .dirt);
    world.setBlockUnchecked(.{ 0, 0, 0 }, .stone);
    try std.testing.expectEqual(1, world.pending_operations.items.len);
    const chunk = world.getChunk(.{ 0, 0, 0 }).?;
    try std.testing.expectEqual(BlockType.dirt, chunk.content.getBlock(.{ 0, 0, 0 }));
    try std.testing.expectEqual(1, chunk.solid_block_count);
    try std.testing.expectEqual(0, chunk.chunk_revision);
}

test "opening each solid face reveals only its cached neighbor without queuing metadata edits" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 3, 2 };
    var source = createSolidChunk(3);
    source.flags.is_unreachable = true;
    try world.insertChunk(coords, source);
    for (std.enums.values(Side)) |side| {
        var neighbor = createSolidChunk(4);
        neighbor.flags.is_unreachable = true;
        try world.insertChunk(adjacentChunk(&test_layout, coords, side).?, neighbor);
    }
    // Interior edits preserve the reachability flag and expose no neighbor.
    world.setBlockUnchecked(.{ 16, 3 * CHUNK_SIZE + 16, 2 * CHUNK_SIZE + 16 }, .none);
    try std.testing.expect(world.getChunk(coords).?.flags.is_unreachable);
    for (std.enums.values(Side)) |side| {
        try std.testing.expect(world.getChunk(adjacentChunk(&test_layout, coords, side).?).?.flags.is_unreachable);
    }
    for (std.enums.values(Side), 0..) |side, index| {
        var local = [3]u32{ 8, 8, 8 };
        local[index / 2] = if (index % 2 == 0) 0 else CHUNK_SIZE - 1;
        world.setBlockUnchecked(.{ @as(u32, @intCast(coords[0])) * CHUNK_SIZE + local[0], @as(u32, @intCast(coords[1])) * CHUNK_SIZE + local[1], @as(u32, @intCast(coords[2])) * CHUNK_SIZE + local[2] }, .none);
        for (std.enums.values(Side), 0..) |other_side, other_index| {
            const neighbor = world.getChunk(adjacentChunk(&test_layout, coords, other_side).?).?;
            try std.testing.expectEqual(other_index > index, neighbor.flags.is_unreachable);
            try std.testing.expectEqual(4, neighbor.chunk_revision);
            try std.testing.expectEqual(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, neighbor.solid_block_count);
        }
        try std.testing.expect(!world.getChunk(coords).?.flags.getSideSolidness(side));
    }
    try std.testing.expectEqual(7, world.pending_operations.items.len);
    try std.testing.expectEqual(3, world.getChunk(coords).?.chunk_revision);
}

test "optimistic reveals survive in-flight snapshots and failed-edit rollback" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const source_coords = ChunkCoords{ 1, 1, 2 };
    const target_coords = ChunkCoords{ 1, 1, 1 };
    const authority = createSolidChunk(0);
    defer authority.deinit(std.testing.allocator);
    var hidden = createSolidChunk(0);
    defer hidden.deinit(std.testing.allocator);
    hidden.flags.is_unreachable = true;
    try world.insertChunk(source_coords, authority.clone(std.testing.allocator));
    try world.insertChunk(target_coords, hidden.clone(std.testing.allocator));
    world.setBlockUnchecked(.{ CHUNK_SIZE + 8, CHUNK_SIZE + 8, 2 * CHUNK_SIZE }, .none);
    world.pending_operations.items[0].request_id = 1;
    try std.testing.expect(!world.getChunk(target_coords).?.flags.is_unreachable);
    try std.testing.expect(!world.getChunk(target_coords).?.isDirty());
    try world.insertChunk(target_coords, hidden.clone(std.testing.allocator));
    try std.testing.expect(!world.getChunk(target_coords).?.flags.is_unreachable);

    world.acknowledgeOperation(1);
    try world.insertChunk(source_coords, authority.clone(std.testing.allocator));
    try world.insertChunk(target_coords, hidden.clone(std.testing.allocator));
    try std.testing.expect(world.getChunk(source_coords).?.flags.solid_bottom);
    try std.testing.expect(!world.getChunk(target_coords).?.flags.is_unreachable);
    try std.testing.expectEqual(0, world.pending_operations.items.len);
}

test "loading an opened wall and hidden neighbor in either order reveals the neighbor" {
    for ([_]bool{ false, true }) |wall_first| {
        var world = try World.init(std.testing.allocator, &test_layout);
        defer world.deinit();
        var wall = createSolidChunk(1);
        _ = wall.apply(std.testing.allocator, .{ 0, 8, 8 }, .remove);
        var hidden = createSolidChunk(0);
        hidden.flags.is_unreachable = true;
        const target_coords = ChunkCoords{ WORLD_SIZE[0] - 1, 2, 1 };
        if (wall_first) {
            try world.insertChunk(.{ 0, 2, 1 }, wall);
            try world.insertChunk(target_coords, hidden);
        } else {
            try world.insertChunk(target_coords, hidden);
            try world.insertChunk(.{ 0, 2, 1 }, wall);
        }
        try std.testing.expect(!world.getChunk(target_coords).?.flags.is_unreachable);
        try std.testing.expectEqual(0, world.getChunk(target_coords).?.chunk_revision);
    }
}

test "cached boundary masks track generation edits clones and optimistic reconciliation" {
    const allocator = std.testing.allocator;
    const data = try allocator.create(WorldChunkData);
    data.* = WorldChunkData.initSolid();
    var chunk = WorldChunk.initBlocks(data);
    defer chunk.deinit(allocator);
    const edits = [_][3]u5{ .{ 8, 8, 8 }, .{ 0, 8, 8 }, .{ 31, 31, 8 }, .{ 0, 0, 0 }, .{ 31, 31, 31 } };
    for (edits) |local| {
        try std.testing.expectEqual(OperationStatus.success, chunk.apply(allocator, local, .remove));
        try std.testing.expectEqualDeep(boundary_mask.extract(chunk.content.blocks), chunk.boundaries);
        try std.testing.expectEqual(chunk.content.blocks.getMetaFlags(), chunk.flags);
    }
    const copy = chunk.clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expectEqualDeep(copy.boundaries, chunk.boundaries);

    var world = try World.init(allocator, &test_layout);
    defer world.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    const block = [3]u32{ CHUNK_SIZE, CHUNK_SIZE + 8, CHUNK_SIZE + 8 };
    world.setBlockUnchecked(block, .stone);
    world.pending_operations.items[0].request_id = 1;
    // Replaying the optimistic put over a fresh snapshot must rebuild its boundary bit.
    try world.insertChunk(coords, WorldChunk.initEmpty());
    try std.testing.expect(world.getChunk(coords).?.boundaries[0].contains(.left, .{ 0, 8, 8 }));
    world.acknowledgeOperation(1);
    try world.insertChunk(coords, WorldChunk.initEmpty());
    try std.testing.expect(!world.getChunk(coords).?.boundaries[0].contains(.left, .{ 0, 8, 8 }));
}

test "streaming incomplete constructions permits unrelated edits but protects affected supports" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    const data = try std.testing.allocator.create(WorldChunkData);
    data.* = WorldChunkData.initFlat();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initBlocks(data));
    const neighbor_data = try std.testing.allocator.create(WorldChunkData);
    neighbor_data.* = WorldChunkData.initFlat();
    try world.insertChunk(.{ 1, 0, 0 }, WorldChunk.initBlocks(neighbor_data));
    // Its footprint spans the neighboring chunk, which later leaves the block cache.
    try std.testing.expectEqual(OperationStatus.success, world.setBlock(.{ 31, 10, 16 }, .dirt).status);
    world.pending_operations.clearRetainingCapacity();
    try std.testing.expectEqual(OperationStatus.success, world.previewOperation(.{ .block = .{ 10, 10, 15 }, .action = .remove }).status);
    try std.testing.expectEqual(OperationStatus.constraint_violation, world.previewOperation(.{ .block = .{ 31, 10, 15 }, .action = .remove }).status);
    world.removeChunk(.{ 1, 0, 0 });
    try std.testing.expectEqual(OperationStatus.missing_data, world.tryOperation(.{ .block = .{ 31, 10, 15 }, .action = .remove }).status);
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    const result = world.tryOperation(.{ .block = .{ 10, 10, 15 }, .action = .remove });
    try std.testing.expectEqual(OperationStatus.success, result.status);
    try std.testing.expectEqual(1, world.pending_operations.items.len);
    try std.testing.expect(!try world.isBlockSolid(.{ 10, 10, 15 }));
}

test "validation window covers all 27 chunks and ignores changes outside the window" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var world = try World.init(std.testing.allocator, &layout);
    defer world.deinit();
    const target = [3]u32{ 80, 80, 80 };
    var window = world.validationWindow(target);
    try std.testing.expectEqual(27, window.chunks.count);
    try std.testing.expect(window.isCurrent(&world));
    for (1..4) |z| for (1..4) |y| {
        for (1..4) |x| {
            try world.insertChunk(.{ @intCast(x), @intCast(y), @intCast(z) }, WorldChunk.initEmpty());
            try std.testing.expect(!window.isCurrent(&world));
            window = world.validationWindow(target);
            try std.testing.expect(window.isCurrent(&world));
        }
    };
    // A changed cell on each face of the inclusive 28-cell boundary invalidates.
    for (0..3) |axis| for ([_]i32{ -28, 28 }) |offset| {
        var block = target;
        block[axis] = @intCast(@as(i64, target[axis]) + offset);
        world.setBlockUnchecked(block, .stone);
        try std.testing.expect(!window.isCurrent(&world));
        window = world.validationWindow(target);
    };
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    try std.testing.expect(window.isCurrent(&world));
    world.setBlockUnchecked(.{ 0, 0, 0 }, .stone);
    try std.testing.expect(window.isCurrent(&world));
    world.removeChunk(.{ 0, 0, 0 });
    try std.testing.expect(window.isCurrent(&world));
}

test "validation window tracks wrapped missing chunks and clips finite world bounds" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var world = try World.init(std.testing.allocator, &layout);
    defer world.deinit();
    const target = [3]u32{ 4, 0, 0 };
    var window = world.validationWindow(target);
    try std.testing.expectEqual(if (WorldLayout.wrap_x) @as(usize, 3) else 2, window.chunks.count);
    try world.insertChunk(.{ 7, 0, 0 }, WorldChunk.initEmpty());
    try std.testing.expectEqual(!WorldLayout.wrap_x, window.isCurrent(&world));
    window = world.validationWindow(target);
    try world.insertChunk(.{ 0, 1, 0 }, WorldChunk.initEmpty());
    try world.insertChunk(.{ 0, 0, 1 }, WorldChunk.initEmpty());
    try std.testing.expect(window.isCurrent(&world));
    try world.insertChunk(.{ 1, 0, 0 }, WorldChunk.initEmpty()); // x=32 is exactly 28 cells away.
    try std.testing.expect(!window.isCurrent(&world));

    const small_layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    var small = try World.init(std.testing.allocator, &small_layout);
    defer small.deinit();
    const small_window = small.validationWindow(.{ 4, 32, 32 });
    try std.testing.expectEqual(8, small_window.chunks.count);
    for (small_window.chunks.ids[0..small_window.chunks.count], 0..) |id, i|
        try std.testing.expect(std.mem.indexOfScalar(ChunkId, small_window.chunks.ids[0..i], id) == null);
}

test "construction collection includes the 28-cell boundary with translation-independent ordering" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    const offsets = [_]block_rules.Cell{
        .{ 0, 0, -28 }, .{ -28, -3, 0 }, .{ 28, 1, 0 },
        .{ 0, -28, 1 }, .{ 0, 28, 1 },   .{ 0, 0, 28 },
    };
    for ([_]block_rules.Cell{ .{ 80, 80, 80 }, .{ 95, 95, 95 }, .{ 252, 128, 128 } }) |center| {
        var world = try World.init(std.testing.allocator, &layout);
        defer world.deinit();
        const reader: block_rules.Reader = .{ .layout = world.layout, .context = &world, .block_at = World.readBlock };
        // Deliberately insert in reverse order so hash-map and metadata order cannot
        // affect which dependent is reported first.
        const additional = [_]block_rules.Cell{ .{ 29, 0, 0 }, .{ -29, 0, 0 }, .{ 0, 29, 0 }, .{ 0, 0, 29 }, .{ 70, 70, 70 } };
        const inserted = offsets ++ additional;
        var i = inserted.len;
        while (i > 0) {
            i -= 1;
            const cell = reader.normalize(center + inserted[i]).?;
            const coords, const local = splitBlockCoords(.{ @intCast(cell[0]), @intCast(cell[1]), @intCast(cell[2]) });
            if (!world.hasChunk(coords)) try world.insertChunk(coords, WorldChunk.initEmpty());
            world.chunks.getPtr(layout.encodeChunkCoords(coords)).?.metadata.markConstructed(std.testing.allocator, transformations.index(local));
        }
        const cells = collectConstructed(std.testing.allocator, world.layout, &world.chunks, .{ @intCast(center[0]), @intCast(center[1]), @intCast(center[2]) });
        defer std.testing.allocator.free(cells);
        try std.testing.expectEqual(offsets.len, cells.len);
        for (cells, offsets) |cell, expected| try std.testing.expectEqualDeep(expected, block_rules.displacement(&layout, cell, center));
    }
}

test "construction collection deduplicates chunks in the smallest wrapped world" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    var world = try World.init(std.testing.allocator, &layout);
    defer world.deinit();
    for ([_]ChunkCoords{ .{ 0, 1, 1 }, .{ 1, 1, 1 } }) |coords| {
        var chunk = WorldChunk.initEmpty();
        chunk.metadata.markConstructed(std.testing.allocator, transformations.index(.{ 0, 1, 1 }));
        try world.insertChunk(coords, chunk);
    }
    // The window crosses three signed x chunk coordinates, two of which normalize
    // to the same stored chunk. Each constructed cell must occur exactly once.
    const cells = collectConstructed(std.testing.allocator, &layout, &world.chunks, .{ 4, 32, 32 });
    defer std.testing.allocator.free(cells);
    try std.testing.expectEqual(2, cells.len);
    try std.testing.expectEqualDeep(block_rules.Cell{ 0, 33, 33 }, cells[0]);
    try std.testing.expectEqualDeep(block_rules.Cell{ 32, 33, 33 }, cells[1]);
}

fn exerciseFallibleChunkPreparation(allocator: std.mem.Allocator) !void {
    var source = WorldChunk.initEmpty();
    defer source.deinit(allocator);
    try std.testing.expectEqual(OperationStatus.success, try source.tryApply(allocator, .{ 1, 2, 3 }, .{ .put = .country_road_adaptive }));
    const cell = transformations.index(.{ 1, 2, 3 });
    try source.metadata.tryMarkConstructed(allocator, cell);
    try source.metadata.timed.trySchedule(allocator, .{ .block = cell, .kind = .grow_grass, .due_tick = 44 });
    var staged = try source.tryClone(allocator);
    defer staged.deinit(allocator);
    try staged.metadata.reserve(allocator, 0, 1, 1);
    try std.testing.expectEqual(OperationStatus.success, try staged.prepareApply(allocator, .{ 1, 2, 3 }, .remove));
    try std.testing.expectEqual(OperationStatus.success, staged.applyPrepared(allocator, .{ 1, 2, 3 }, .remove));
    try std.testing.expectEqual(BlockType.custom, source.content.getBlock(.{ 1, 2, 3 }));
    try std.testing.expectEqual(@as(usize, 1), source.metadata.roads.items.len);
    try std.testing.expectEqual(@as(usize, 0), staged.metadata.roads.items.len);
    try std.testing.expectEqual(BlockType.none, staged.content.getBlock(.{ 1, 2, 3 }));
}
test "fallible chunk staging preserves source through every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFallibleChunkPreparation, .{});
}

test {
    _ = @import("timer_kernel.zig");
}

fn exerciseOptimisticAdmission(allocator: std.mem.Allocator) !void {
    var client = try World.init(allocator, &test_layout);
    defer client.deinit();
    try client.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    client.allocator = allocator;
    const before_stamp = client.validation_revision;
    const result = client.enqueueOptimistic(.{ .block = .{ 1, 1, 1 }, .action = .{ .put = .country_road_adaptive } }, true) catch |err| {
        const source = client.getChunk(.{ 0, 0, 0 }).?;
        try std.testing.expectEqual(BlockType.none, source.content.getBlock(.{ 1, 1, 1 }));
        try std.testing.expectEqual(@as(usize, 0), source.metadata.roads.items.len);
        try std.testing.expectEqual(@as(usize, 0), source.metadata.constructed.items.len);
        try std.testing.expectEqual(@as(usize, 0), client.pending_operations.items.len);
        try std.testing.expectEqual(before_stamp, client.validation_revision);
        return err;
    };
    try std.testing.expectEqual(OperationStatus.success, result);
    try std.testing.expectEqual(@as(usize, 1), client.pending_operations.items.len);
    try std.testing.expect(client.pendingOperationBytes() <= client.pending_byte_limit);
}
test "optimistic admission prepares every allocation before changing client state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOptimisticAdmission, .{});
}
test "full optimistic count or byte budget rejects before mutation or validation" {
    var client = try World.init(std.testing.allocator, &test_layout);
    defer client.deinit();
    try client.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    var calls: usize = 0;
    client.preview_call_counter = &calls;
    client.pending_operation_limit = 0;
    const op: BlockOperation = .{ .block = .{ 1, 1, 1 }, .action = .{ .put = .dirt } };
    try std.testing.expectEqual(OperationStatus.resource_exhausted, client.tryOperation(op).status);
    try std.testing.expectEqual(@as(usize, 0), calls);
    client.pending_operation_limit = 1;
    client.pending_byte_limit = 1;
    client.setBlockUnchecked(op.block, .dirt);
    try std.testing.expectEqual(OperationStatus.resource_exhausted, client.last_edit_result.?.status);
    try std.testing.expectEqual(BlockType.none, client.getChunk(.{ 0, 0, 0 }).?.content.getBlock(.{ 1, 1, 1 }));
    try std.testing.expectEqual(@as(usize, 0), client.pending_operations.items.len);
}

test "snapshot rollback allocates before mutating optimistic state" {
    // Only fail the rollback preflight; replay intentionally reports deferred
    // pressure as resource_exhausted rather than discarding received authority.
    var client = try World.init(std.testing.allocator, &test_layout);
    defer client.deinit();
    try client.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    client.setBlockUnchecked(.{ 1, 1, 1 }, .dirt);
    const stamp = client.validation_revision;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    client.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, client.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty()));
    try std.testing.expectEqual(BlockType.dirt, client.getChunk(.{ 0, 0, 0 }).?.content.getBlock(.{ 1, 1, 1 }));
    try std.testing.expectEqual(stamp, client.validation_revision);
    try std.testing.expectEqual(@as(usize, 1), client.pending_operations.items.len);
}
test "rejected optimistic command survives resource pressure then retires on safe rebase" {
    var client = try World.init(std.testing.allocator, &test_layout);
    defer client.deinit();
    try client.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    client.setBlockUnchecked(.{ 1, 1, 1 }, .dirt);
    client.pending_operations.items[0].request_id = 1;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    client.allocator = failing.allocator();
    client.acknowledgeOperationResult(1, .constraint_violation);
    try std.testing.expectEqual(@as(usize, 1), client.pending_operations.items.len);
    try std.testing.expectEqual(OperationStatus.constraint_violation, client.pending_operations.items[0].resolved_status.?);
    client.allocator = std.testing.allocator;
    try client.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    try std.testing.expectEqual(@as(usize, 0), client.pending_operations.items.len);
    try std.testing.expectEqual(BlockType.none, client.getChunk(.{ 0, 0, 0 }).?.content.getBlock(.{ 1, 1, 1 }));
}

fn insertTestBlueprint(world: *World, id: u64, origin: [3]u32, size: blueprint.Size, cells: []const BlockType) !void {
    var count: u32 = 0;
    for (cells) |material| if (material != .none) {
        count += 1;
    };
    var saved: blueprint_runtime.SavedDefinition = .{ .id = id, .owner = 1, .name = try world.allocator.dupe(u8, "Fixture"), .definition = .{ .size = size, .cells = try world.allocator.dupe(BlockType, cells), .target_count = count } };
    world.blueprints.insertDefinition(world.allocator, saved) catch |err| {
        saved.deinit(world.allocator);
        return err;
    };
    var instance = try world.blueprints.prepareInstance(world.allocator, world.layout, id, id, 1, origin, 0);
    world.blueprints.insertInstance(world.allocator, world.layout, instance) catch |err| {
        instance.deinit(world.allocator);
        return err;
    };
}
fn setTestPhysical(world: *World, cell: [3]u32, material: BlockType) !void {
    const coords, const local = splitBlockCoords(cell);
    if (!world.hasChunk(coords)) try world.insertChunk(coords, WorldChunk.initEmpty());
    const chunk = world.chunks.getPtr(world.layout.encodeChunkCoords(coords)).?;
    try std.testing.expectEqual(OperationStatus.success, try chunk.tryApply(world.allocator, local, .{ .put = material }));
}
test "blueprint optimistic fulfillment uses at most five support reads and no ordinary or road work" {
    var client = try World.init(std.testing.allocator, &test_layout);
    defer client.deinit();
    const cell: [3]u32 = .{ 10, 10, 10 };
    try client.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    try insertTestBlueprint(&client, 1, cell, .{ 2, 1, 1 }, &.{ .planks, .planks });
    const operation: BlockOperation = .{ .block = cell, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } };
    var reads: usize = 0;
    var ordinary: usize = 0;
    var roads_count: usize = 0;
    client.physical_read_counter = &reads;
    client.ordinary_preview_counter = &ordinary;
    client.road_plan_counter = &roads_count;
    // The neighboring miniature does not provide real support.
    try std.testing.expectEqual(OperationStatus.constraint_violation, client.tryOperation(operation).status);
    try std.testing.expectEqual(@as(usize, 6), reads); // One occupancy read plus five support reads.
    try std.testing.expectEqual(@as(usize, 0), ordinary);
    try std.testing.expectEqual(@as(usize, 0), roads_count);
    try setTestPhysical(&client, .{ 10, 10, 9 }, .sand);
    reads = 0;
    try std.testing.expectEqual(OperationStatus.success, client.tryOperation(operation).status);
    try std.testing.expectEqual(@as(usize, 2), reads); // Target and any actual block below.
    try std.testing.expectEqual(@as(usize, 0), ordinary);
    try std.testing.expectEqual(@as(usize, 0), roads_count);
    try std.testing.expectEqual(@as(u32, 2), client.blueprints.instances.get(1).?.remaining);
    try std.testing.expect(!client.blueprints.instances.get(1).?.isFulfilled(0));
    try std.testing.expectEqual(BlockType.planks, client.plannedBlock(cell).?);
    client.pending_operations.items[0].request_id = 4;
    client.acknowledgeOperationResult(4, .constraint_violation);
    try std.testing.expectEqual(BlockType.none, client.reader().get(.{ 10, 10, 10 }).?);
    try std.testing.expect(client.blueprints.targetAt(cell) != null);
    try std.testing.expectEqual(@as(u32, 2), client.blueprints.instances.get(1).?.remaining);
    // A repeated optimistic fill can be rebased without changing authoritative progress.
    try std.testing.expectEqual(OperationStatus.success, client.tryOperation(operation).status);
    client.pending_operations.items[0].request_id = 5;
    var baseline = WorldChunk.initEmpty();
    _ = try baseline.tryApply(std.testing.allocator, .{ 10, 10, 9 }, .{ .put = .sand });
    try client.insertChunk(.{ 0, 0, 0 }, baseline);
    try std.testing.expectEqual(BlockType.planks, client.reader().get(.{ 10, 10, 10 }).?);
    try std.testing.expectEqual(@as(u32, 2), client.blueprints.instances.get(1).?.remaining);
    try std.testing.expectEqual(@as(usize, 0), roads_count);
    try client.applyBlueprintChanges(&.{.{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } }});
    client.acknowledgeOperationResult(5, .success);
    try std.testing.expectEqual(@as(u32, 1), client.blueprints.instances.get(1).?.remaining);
    try std.testing.expect(client.blueprints.targetAt(cell) == null);
}

test "blueprint target identity, unknown capture data, and whole-box extraction restrictions" {
    var client = try World.init(std.testing.allocator, &test_layout);
    defer client.deinit();
    try insertTestBlueprint(&client, 1, .{ 30, 10, 10 }, .{ 3, 1, 1 }, &.{ .planks, .none, .planks });
    try std.testing.expectEqual(@as(?BlockType, null), client.plannedBlock(.{ 32, 10, 10 }));
    try client.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    try std.testing.expectEqual(BlockType.planks, client.plannedBlock(.{ 30, 10, 10 }).?);
    const stale: BlockOperation = .{ .block = .{ 30, 10, 10 }, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 9, .cell_index = 0 } };
    try std.testing.expectEqual(OperationStatus.target_changed, client.previewOperation(stale).status);
    const wrong: BlockOperation = .{ .block = .{ 30, 10, 10 }, .action = .{ .put = .dirt }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } };
    try std.testing.expectEqual(OperationStatus.inventory_mismatch, client.previewOperation(wrong).status);
    try insertTestBlueprint(&client, 2, .{ 20, 10, 10 }, .{ 1, 1, 1 }, &.{.dirt});
    for ([_]BlockType{ .grass, .packed_dirt }) |unplaceable| {
        const invalid: BlockOperation = .{ .block = .{ 20, 10, 10 }, .action = .{ .put = unplaceable }, .blueprint = .{ .instance_id = 2, .cell_index = 0 } };
        try std.testing.expectEqual(OperationStatus.inventory_mismatch, client.previewOperation(invalid).status);
    }
    try std.testing.expectEqual(OperationStatus.target_changed, client.previewOperation(.{ .block = .{ 30, 10, 10 }, .action = .{ .put = .planks } }).status);
    try setTestPhysical(&client, .{ 31, 10, 10 }, .stone);
    try std.testing.expectEqual(OperationStatus.constraint_violation, client.previewOperation(.{ .block = .{ 31, 10, 10 }, .action = .remove }).status);
}

test "ordinary bridge placement validates its completed target above pending crushed column" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var client = try World.init(std.testing.allocator, &layout);
    defer client.deinit();
    for (1..3) |z| for (1..3) |y| for (1..3) |x| try client.insertChunk(.{ @intCast(x), @intCast(y), @intCast(z) }, WorldChunk.initEmpty());
    try insertTestBlueprint(&client, 1, .{ 64, 64, 60 }, .{ 1, 1, 6 }, &([_]BlockType{.crushed_stone} ** 6));
    for (57..60) |z| for (63..66) |y| for (63..66) |x| try setTestPhysical(&client, .{ @intCast(x), @intCast(y), @intCast(z) }, .stone);
    for ([_]u32{ 63, 65 }) |x| {
        try setTestPhysical(&client, .{ x, 64, 65 }, .stone);
        try setTestPhysical(&client, .{ x, 64, 66 }, .stone);
    }
    const operation: BlockOperation = .{ .block = .{ 64, 64, 66 }, .action = .{ .put = .crushed_stone } };
    try std.testing.expectEqual(OperationStatus.success, validateEdit(std.testing.allocator, client.reader(), &.{}, operation).status);
    const rejected = client.previewOperation(operation);
    try std.testing.expectEqual(OperationStatus.constraint_violation, rejected.status);
    try std.testing.expectEqual(block_rules.Reason.crushed_column, rejected.failure.?.reason);
    try std.testing.expectEqual(BlockType.none, client.reader().get(.{ 64, 64, 66 }).?);
    try std.testing.expectEqual(@as(u32, 6), client.blueprints.instances.get(1).?.remaining);
    try std.testing.expectEqual(OperationStatus.target_changed, client.previewOperation(.{ .block = .{ 64, 64, 61 }, .action = .{ .put = .planks } }).status);
}

test "neighboring sites retain a global completion order after safe external support removal" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var client = try World.init(std.testing.allocator, &layout);
    defer client.deinit();
    for (1..3) |z| for (1..3) |y| for (1..3) |x| try client.insertChunk(.{ @intCast(x), @intCast(y), @intCast(z) }, WorldChunk.initEmpty());
    try insertTestBlueprint(&client, 1, .{ 64, 64, 64 }, .{ 1, 1, 1 }, &.{.planks});
    try insertTestBlueprint(&client, 2, .{ 65, 64, 64 }, .{ 1, 1, 1 }, &.{.planks});
    try setTestPhysical(&client, .{ 64, 64, 63 }, .stone);
    try setTestPhysical(&client, .{ 65, 64, 63 }, .stone);
    // A may rely on completed B, but removing their final real support is invalid.
    try std.testing.expectEqual(OperationStatus.success, client.tryOperation(.{ .block = .{ 64, 64, 63 }, .action = .remove }).status);
    try std.testing.expectEqual(OperationStatus.constraint_violation, client.previewOperation(.{ .block = .{ 65, 64, 63 }, .action = .remove }).status);
    const first: BlockOperation = .{ .block = .{ 64, 64, 64 }, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } };
    const second: BlockOperation = .{ .block = .{ 65, 64, 64 }, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 2, .cell_index = 0 } };
    try std.testing.expectEqual(OperationStatus.constraint_violation, client.previewOperation(first).status);
    try std.testing.expectEqual(OperationStatus.success, client.tryOperation(second).status);
    try std.testing.expectEqual(OperationStatus.success, client.tryOperation(first).status);
    try client.applyBlueprintChanges(&.{ .{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } }, .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } } });
    try std.testing.expect(!client.blueprints.instances.get(1).?.active);
    try std.testing.expect(!client.blueprints.instances.get(2).?.active);
    var ordinary: block_rules.Validator = .{ .allocator = std.testing.allocator, .reader = client.reader() };
    defer ordinary.deinit();
    try std.testing.expect(ordinary.checkExisting(.{ 64, 64, 64 }) == null);
    try std.testing.expect(ordinary.checkExisting(.{ 65, 64, 64 }) == null);
}

fn blueprintPackageAllocationScenario(a: std.mem.Allocator) !void {
    var client = try World.init(a, &test_layout);
    defer client.deinit();
    var source: blueprint_runtime.State = .{ .layout = client.layout };
    defer source.deinit(a);
    const name = try a.dupe(u8, "Batch");
    const cells = a.dupe(BlockType, &.{ .planks, .planks }) catch |err| {
        a.free(name);
        return err;
    };
    var definition: blueprint_runtime.SavedDefinition = .{ .id = 1, .owner = 1, .name = name, .definition = .{ .size = .{ 2, 1, 1 }, .cells = cells, .target_count = 2 } };
    source.insertDefinition(a, definition) catch |err| {
        definition.deinit(a);
        return err;
    };
    var first = try source.prepareInstance(a, client.layout, 1, 1, 1, .{ 2, 2, 2 }, 0);
    defer first.deinit(a);
    var second = try source.prepareInstance(a, client.layout, 2, 1, 1, .{ 5, 2, 2 }, 0);
    defer second.deinit(a);
    const changes = [_]blueprint_runtime.Change{ .{ .definition = source.definitions.get(1).? }, .{ .instance = first }, .{ .instance = second }, .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } } };
    client.applyBlueprintChanges(&changes) catch |err| {
        try std.testing.expectEqual(@as(u32, 0), client.blueprints.definitions.count());
        try std.testing.expectEqual(@as(u32, 0), client.blueprints.instances.count());
        try std.testing.expectEqual(@as(u32, 0), client.blueprints.chunks.count());
        return err;
    };
    try std.testing.expectEqual(@as(u32, 2), client.blueprints.instances.count());
    try std.testing.expect(client.blueprints.targetAt(.{ 2, 2, 2 }) == null);
    try std.testing.expect(client.blueprints.targetAt(.{ 3, 2, 2 }) != null);
    try std.testing.expect(client.blueprints.targetAt(.{ 5, 2, 2 }) != null);
    try client.applyBlueprintChanges(&changes); // Idempotent replay cannot reset progress.
    try std.testing.expectEqual(@as(u32, 1), client.blueprints.instances.get(1).?.remaining);
}
test "client blueprint package preflight is atomic across all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, blueprintPackageAllocationScenario, .{});
}

test "ordinary completed validation matches physical validation work without instances" {
    const a = std.testing.allocator;
    var world = try World.init(a, &test_layout);
    defer world.deinit();
    try setTestPhysical(&world, .{ 10, 10, 8 }, .stone);
    for (9..13) |z| try setTestPhysical(&world, .{ 10, 10, @intCast(z) }, .planks);
    try setTestPhysical(&world, .{ 11, 10, 11 }, .planks);
    const constructed = [_]block_rules.Cell{
        .{ 10, 10, 9 }, .{ 10, 10, 10 }, .{ 10, 10, 11 }, .{ 11, 10, 11 }, .{ 10, 10, 12 },
    };
    const cases = [_]struct { operation: BlockOperation, status: OperationStatus }{
        .{ .operation = .{ .block = .{ 11, 10, 10 }, .action = .{ .put = .planks } }, .status = .success },
        .{ .operation = .{ .block = .{ 10, 10, 9 }, .action = .remove }, .status = .constraint_violation },
        .{ .operation = .{ .block = .{ 11, 10, 11 }, .action = .remove }, .status = .success },
    };
    var reads: usize = 0;
    world.physical_read_counter = &reads;
    for ([_]bool{ false, true }) |library_only| {
        if (library_only) {
            var saved: blueprint_runtime.SavedDefinition = .{ .id = 1, .owner = 1, .name = try a.dupe(u8, "Unused"), .definition = .{ .size = .{ 1, 1, 1 }, .cells = try a.dupe(BlockType, &.{.planks}), .target_count = 1 } };
            defer saved.deinit(a);
            try world.applyBlueprintChanges(&.{.{ .definition = saved }});
        }
        for (cases) |case| {
            reads = 0;
            var ordinary = std.testing.FailingAllocator.init(a, .{});
            const expected = validateEdit(ordinary.allocator(), world.reader(), &constructed, case.operation);
            try std.testing.expectEqual(case.status, expected.status);
            const ordinary_reads = reads;
            try std.testing.expect(ordinary_reads > 2);
            try std.testing.expect(ordinary.allocations > 0);
            reads = 0;
            var shared = std.testing.FailingAllocator.init(a, .{});
            const actual = validateCompletedEdit(shared.allocator(), world.reader(), &world.blueprints, &constructed, case.operation);
            try std.testing.expectEqualDeep(expected, actual);
            try std.testing.expectEqual(ordinary_reads, reads);
            try std.testing.expectEqual(ordinary.allocations, shared.allocations);
            try std.testing.expectEqual(ordinary.allocated_bytes, shared.allocated_bytes);
        }
    }
}

test "orphan blueprint identity rejects before ordinary work in an empty world" {
    var world = try World.init(std.testing.allocator, &test_layout);
    defer world.deinit();
    var reads: usize = 0;
    world.physical_read_counter = &reads;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const operation: BlockOperation = .{ .block = .{ 10, 10, 10 }, .action = .{ .put = .planks }, .blueprint = .{ .instance_id = 1, .cell_index = 0 } };
    const result = validateCompletedEdit(failing.allocator(), world.reader(), &world.blueprints, &.{}, operation);
    try std.testing.expectEqual(OperationStatus.target_changed, result.status);
    try std.testing.expectEqual(@as(usize, 0), reads);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

fn expectOrderedBlueprintReplacementTargets(client: *const World) !void {
    const expected = [_]struct { cell: [3]u32, instance_id: u64, cell_index: u32 }{
        .{ .cell = .{ 31, 12, 10 }, .instance_id = 1, .cell_index = 0 },
        .{ .cell = .{ 32, 12, 10 }, .instance_id = 1, .cell_index = 1 },
        .{ .cell = .{ 31, 10, 10 }, .instance_id = 3, .cell_index = 0 },
        .{ .cell = .{ 32, 10, 10 }, .instance_id = 3, .cell_index = 1 },
    };
    for (expected) |value| {
        const target = client.blueprints.targetAt(value.cell).?;
        try std.testing.expectEqual(value.instance_id, target.instance_id);
        try std.testing.expectEqual(value.cell_index, target.cell_index);
        try std.testing.expectEqual(BlockType.planks, target.material);
    }
    for ([_]ChunkCoords{ .{ 0, 0, 0 }, .{ 1, 0, 0 } }) |coords| {
        const chunk = client.blueprints.chunks.get(client.layout.encodeChunkCoords(coords)).?;
        try std.testing.expectEqual(@as(usize, 2), chunk.targets.items.len);
        try std.testing.expectEqual(@as(u32, 2), chunk.lookup.count());
        for (chunk.targets.items, 0..) |cell, slot| try std.testing.expectEqual(slot, chunk.lookup.get(cell).?.chunk_slot);
    }
    for ([_]u64{ 1, 3 }) |id| {
        const instance = client.blueprints.instances.get(id).?;
        try std.testing.expect(instance.active);
        try std.testing.expectEqual(@as(u32, 2), instance.remaining);
        try std.testing.expect(!instance.isFulfilled(0));
        try std.testing.expect(!instance.isFulfilled(1));
    }
}

// Fail only package application, keeping setup outside the failure sweep. The
// testing allocator owns both fixtures and staged allocations and checks leaks.
fn orderedBlueprintReplacementScenario(existing_instance: bool, fail_index: ?usize) !bool {
    const a = std.testing.allocator;
    var client = try World.init(a, &test_layout);
    defer client.deinit();
    // An unrelated instance shares both footprint chunks with A and B.
    try insertTestBlueprint(&client, 1, .{ 31, 12, 10 }, .{ 2, 1, 1 }, &.{ .planks, .planks });
    var source = try World.init(a, &test_layout);
    defer source.deinit();
    try insertTestBlueprint(&source, 2, .{ 31, 10, 10 }, .{ 2, 1, 1 }, &.{ .planks, .planks });
    const saved = source.blueprints.definitions.get(2).?;
    const first = source.blueprints.instances.get(2).?;
    var replacement = try source.blueprints.prepareInstance(a, client.layout, 3, 2, 1, first.origin, 0);
    defer replacement.deinit(a);
    if (existing_instance) {
        try client.applyBlueprintChanges(&.{ .{ .definition = saved }, .{ .instance = first }, .{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } } });
    }
    const package = [_]blueprint_runtime.Change{
        .{ .definition = saved },
        .{ .instance = first },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 1 } },
        .{ .instance = replacement },
        // Late duplicates must not remove B's targets at the same cells.
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 1 } },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 99 } },
    };
    const changes: []const blueprint_runtime.Change = if (existing_instance) package[3..] else &package;
    const old_revision = client.blueprints.revision;
    const old_max_definition = client.blueprints.max_definition_id;
    const old_max_instance = client.blueprints.max_instance_id;
    const observed_cells = [_][3]u32{ .{ 31, 12, 10 }, .{ 32, 12, 10 }, .{ 31, 10, 10 }, .{ 32, 10, 10 } };
    var old_targets: [observed_cells.len]?blueprint_runtime.Target = undefined;
    for (observed_cells, &old_targets) |cell, *target| target.* = client.blueprints.targetAt(cell);
    if (existing_instance and fail_index == null) {
        try std.testing.expectError(error.Overlap, client.applyBlueprintChanges(&.{ changes[1], changes[0] }));
        try std.testing.expectEqual(old_revision, client.blueprints.revision);
        for (observed_cells, old_targets) |cell, target| try std.testing.expectEqualDeep(target, client.blueprints.targetAt(cell));
    }
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index orelse std.math.maxInt(usize) });
    client.allocator = failing.allocator();
    const applied = client.applyBlueprintChanges(changes);
    client.allocator = a;
    if (applied) |_| {
        try std.testing.expect(!failing.has_induced_failure);
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(old_revision, client.blueprints.revision);
        try std.testing.expectEqual(old_max_definition, client.blueprints.max_definition_id);
        try std.testing.expectEqual(old_max_instance, client.blueprints.max_instance_id);
        try std.testing.expectEqual(@as(u32, if (existing_instance) 2 else 1), client.blueprints.definitions.count());
        try std.testing.expectEqual(@as(u32, if (existing_instance) 2 else 1), client.blueprints.instances.count());
        try std.testing.expectEqual(@as(u32, 2), client.blueprints.chunks.count());
        try std.testing.expectEqual(@as(usize, 0), client.blueprints.cleanup_queue.items.len);
        try std.testing.expectEqual(@as(usize, 0), client.blueprints.cleanup_head);
        for (observed_cells, old_targets) |cell, target| try std.testing.expectEqualDeep(target, client.blueprints.targetAt(cell));
        if (existing_instance) {
            const unchanged = client.blueprints.instances.get(2).?;
            try std.testing.expect(unchanged.active);
            try std.testing.expectEqual(@as(u32, 1), unchanged.remaining);
            try std.testing.expect(unchanged.isFulfilled(0));
            try std.testing.expect(!unchanged.isFulfilled(1));
        }
        // Every failed preflight must leave the package retryable.
        try client.applyBlueprintChanges(changes);
    }
    try expectOrderedBlueprintReplacementTargets(&client);
    const completed = client.blueprints.instances.get(2).?;
    try std.testing.expect(!completed.active);
    try std.testing.expectEqual(@as(u32, 0), completed.remaining);
    try std.testing.expect(completed.isFulfilled(0));
    try std.testing.expect(completed.isFulfilled(1));
    try std.testing.expectEqualSlices(u64, &.{2}, client.blueprints.cleanup_queue.items);
    try std.testing.expectEqual(@as(u64, 2), client.blueprints.max_definition_id);
    try std.testing.expectEqual(@as(u64, 3), client.blueprints.max_instance_id);
    // Borrowed authoritative payloads and saved library cells stay immutable.
    try std.testing.expectEqualSlices(BlockType, &.{ .planks, .planks }, saved.definition.cells);
    try std.testing.expectEqualSlices(BlockType, saved.definition.cells, client.blueprints.definitions.get(2).?.definition.cells);
    try std.testing.expectEqualSlices(u8, &.{0}, first.fulfilled);
    try std.testing.expectEqualSlices(u8, &.{0}, replacement.fulfilled);
    try std.testing.expectEqual(@as(u32, 2), first.remaining);
    try std.testing.expectEqual(@as(u32, 2), replacement.remaining);
    const applied_revision = client.blueprints.revision;
    try client.applyBlueprintChanges(changes);
    try std.testing.expectEqual(applied_revision, client.blueprints.revision);
    try expectOrderedBlueprintReplacementTargets(&client);
    // Retiring A must preserve B and unrelated targets in both shared chunks.
    client.blueprints.cleanup(a, 2);
    try std.testing.expect(!client.blueprints.instances.contains(2));
    try expectOrderedBlueprintReplacementTargets(&client);
    const cleaned_revision = client.blueprints.revision;
    try client.applyBlueprintChanges(changes);
    try std.testing.expectEqual(cleaned_revision, client.blueprints.revision);
    try expectOrderedBlueprintReplacementTargets(&client);
    return failing.has_induced_failure;
}

test "client blueprint package fulfills an existing site before replacing its footprint" {
    try std.testing.expect(!try orderedBlueprintReplacementScenario(true, null));
}

test "client blueprint package creates completes and replaces a site in order" {
    try std.testing.expect(!try orderedBlueprintReplacementScenario(false, null));
}

test "ordered blueprint replacement rolls back every allocation failure and retries" {
    for ([_]bool{ true, false }) |existing_instance| {
        var fail_index: usize = 0;
        while (try orderedBlueprintReplacementScenario(existing_instance, fail_index)) : (fail_index += 1) {}
        try std.testing.expect(fail_index > 0);
    }
}

test "client fulfillment-only packages allocate nothing including completion and duplicates" {
    const a = std.testing.allocator;
    var client = try World.init(a, &test_layout);
    defer client.deinit();
    try insertTestBlueprint(&client, 1, .{ 31, 10, 10 }, .{ 2, 1, 1 }, &.{ .planks, .planks });
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    client.allocator = failing.allocator();
    const applied = client.applyBlueprintChanges(&.{
        .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } },
        .{ .fulfill = .{ .instance_id = 1, .cell_index = 0 } },
        .{ .fulfill = .{ .instance_id = 99, .cell_index = 0 } },
        .{ .fulfill = .{ .instance_id = 1, .cell_index = 99 } },
        .{ .fulfill = .{ .instance_id = 1, .cell_index = 1 } },
        .{ .fulfill = .{ .instance_id = 1, .cell_index = 1 } },
    });
    client.allocator = a;
    try applied;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(!client.blueprints.instances.get(1).?.active);
    try std.testing.expectEqual(@as(u32, 0), client.blueprints.instances.get(1).?.remaining);
    try std.testing.expect(client.blueprints.targetAt(.{ 31, 10, 10 }) == null);
    try std.testing.expect(client.blueprints.targetAt(.{ 32, 10, 10 }) == null);
    try std.testing.expectEqualSlices(u64, &.{1}, client.blueprints.cleanup_queue.items);
}

test "client blueprint package ignores fulfillment before a future instance appears" {
    const a = std.testing.allocator;
    var client = try World.init(a, &test_layout);
    defer client.deinit();
    try insertTestBlueprint(&client, 1, .{ 20, 12, 10 }, .{ 2, 1, 1 }, &.{ .planks, .planks });
    var future = try client.blueprints.prepareInstance(a, client.layout, 2, 1, 1, .{ 31, 10, 10 }, 0);
    defer future.deinit(a);
    const revision = client.blueprints.revision;
    try client.applyBlueprintChanges(&.{
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } },
        .{ .instance = future },
    });
    const instance = client.blueprints.instances.get(2).?;
    try std.testing.expect(instance.active);
    try std.testing.expectEqual(@as(u32, 2), instance.remaining);
    try std.testing.expect(!instance.isFulfilled(0));
    try std.testing.expect(!instance.isFulfilled(1));
    try std.testing.expectEqual(@as(u64, 2), client.blueprints.targetAt(.{ 31, 10, 10 }).?.instance_id);
    try std.testing.expectEqual(@as(u64, 2), client.blueprints.targetAt(.{ 32, 10, 10 }).?.instance_id);
    try std.testing.expectEqual(@as(usize, 0), client.blueprints.cleanup_queue.items.len);
    try std.testing.expectEqual(revision +% 1, client.blueprints.revision);
}

test "ordered blueprint replacements preserve shared sparse wrapped chunk snapshots" {
    const a = std.testing.allocator;
    var client = try World.init(a, &test_layout);
    defer client.deinit();
    try insertTestBlueprint(&client, 1, .{ 5, 12, 10 }, .{ 1, 1, 1 }, &.{.planks});
    var source = try World.init(a, &test_layout);
    defer source.deinit();
    const edge: u32 = @intCast(client.layout.size_in_blocks[0] - 1);
    try insertTestBlueprint(&source, 2, .{ edge, 10, 10 }, .{ 3, 1, 1 }, &.{ .planks, .none, .planks });
    const saved = source.blueprints.definitions.get(2).?;
    const first = source.blueprints.instances.get(2).?;
    var disjoint = try source.blueprints.prepareInstance(a, client.layout, 3, 2, 1, .{ edge, 12, 10 }, 0);
    defer disjoint.deinit(a);
    var second = try source.blueprints.prepareInstance(a, client.layout, 4, 2, 1, first.origin, 0);
    defer second.deinit(a);
    var third = try source.blueprints.prepareInstance(a, client.layout, 5, 2, 1, first.origin, 0);
    defer third.deinit(a);
    const changes = [_]blueprint_runtime.Change{
        .{ .definition = saved },
        .{ .instance = first },
        .{ .instance = disjoint },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 1 } }, // Sparse air is not a target.
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 2 } },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 2 } },
        .{ .instance = second },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 0 } },
        .{ .fulfill = .{ .instance_id = 4, .cell_index = 0 } },
        .{ .fulfill = .{ .instance_id = 4, .cell_index = 2 } },
        .{ .fulfill = .{ .instance_id = 4, .cell_index = 2 } },
        .{ .instance = third },
        .{ .fulfill = .{ .instance_id = 2, .cell_index = 2 } },
        .{ .fulfill = .{ .instance_id = 4, .cell_index = 0 } },
    };
    try client.applyBlueprintChanges(&changes);
    try std.testing.expectEqualSlices(u64, &.{ 2, 4 }, client.blueprints.cleanup_queue.items);
    for ([_]u64{ 2, 4 }) |id| {
        const completed = client.blueprints.instances.get(id).?;
        try std.testing.expect(!completed.active);
        try std.testing.expectEqual(@as(u32, 0), completed.remaining);
        try std.testing.expectEqualSlices(u8, &.{5}, completed.fulfilled);
    }
    // Check the original result, its replay, and replay after both retirements.
    for (0..3) |pass| {
        if (pass == 2) {
            client.blueprints.cleanup(a, 4);
            try std.testing.expect(!client.blueprints.instances.contains(2));
            try std.testing.expect(!client.blueprints.instances.contains(4));
            try std.testing.expectEqual(@as(usize, 0), client.blueprints.cleanup_queue.items.len);
        }
        if (pass != 0) {
            const revision = client.blueprints.revision;
            try client.applyBlueprintChanges(&changes);
            try std.testing.expectEqual(revision, client.blueprints.revision);
        }
        const expected = [_]struct { cell: [3]u32, instance_id: u64, cell_index: u32 }{
            .{ .cell = .{ 5, 12, 10 }, .instance_id = 1, .cell_index = 0 },
            .{ .cell = .{ edge, 12, 10 }, .instance_id = 3, .cell_index = 0 },
            .{ .cell = .{ 1, 12, 10 }, .instance_id = 3, .cell_index = 2 },
            .{ .cell = .{ edge, 10, 10 }, .instance_id = 5, .cell_index = 0 },
            .{ .cell = .{ 1, 10, 10 }, .instance_id = 5, .cell_index = 2 },
        };
        for (expected) |value| {
            const target = client.blueprints.targetAt(value.cell).?;
            try std.testing.expectEqual(value.instance_id, target.instance_id);
            try std.testing.expectEqual(value.cell_index, target.cell_index);
        }
        try std.testing.expect(client.blueprints.targetAt(.{ 0, 10, 10 }) == null);
        try std.testing.expect(client.blueprints.targetAt(.{ 0, 12, 10 }) == null);
        try std.testing.expectEqual(@as(u64, 5), client.blueprints.boxAt(client.layout, .{ 0, 10, 10 }).?);
        try std.testing.expectEqual(@as(u32, 2), client.blueprints.chunks.count());
        var target_count: usize = 0;
        var chunks = client.blueprints.chunks.valueIterator();
        while (chunks.next()) |chunk| {
            try std.testing.expectEqual(chunk.targets.items.len, chunk.lookup.count());
            for (chunk.targets.items, 0..) |cell, slot| try std.testing.expectEqual(slot, chunk.lookup.get(cell).?.chunk_slot);
            target_count += chunk.targets.items.len;
        }
        try std.testing.expectEqual(@as(usize, 5), target_count);
        try std.testing.expect(client.blueprints.instances.get(1).?.active);
        try std.testing.expectEqual(@as(u32, 1), client.blueprints.instances.get(1).?.remaining);
        for ([_]u64{ 3, 5 }) |id| {
            const active = client.blueprints.instances.get(id).?;
            try std.testing.expect(active.active);
            try std.testing.expectEqual(@as(u32, 2), active.remaining);
            try std.testing.expectEqualSlices(u8, &.{0}, active.fulfilled);
        }
    }
    try std.testing.expectEqualSlices(BlockType, &.{ .planks, .none, .planks }, saved.definition.cells);
    for ([_]blueprint_runtime.Instance{ first, disjoint, second, third }) |borrowed| {
        try std.testing.expectEqualSlices(u8, &.{0}, borrowed.fulfilled);
        try std.testing.expectEqual(@as(u32, 2), borrowed.remaining);
    }
}
