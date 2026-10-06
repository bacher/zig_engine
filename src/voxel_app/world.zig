const ChunkCoords = @import("engine").ChunkCoords;
const std = @import("std");

const BlockType = @import("engine").voxel_chunk.BlockType;
const Side = @import("engine").voxel_chunk.Side;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const ChunkFlags = @import("./world_chunk_data.zig").ChunkFlags;
const world_generator = @import("./world_generator.zig");
const ChunkPosition = @import("./consts.zig").ChunkPosition;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WORLD_SIZE = @import("./consts.zig").WORLD_SIZE;
const boundary_mask = @import("./boundary_mask.zig");

/// Map a spatial coordinate to stored terrain: x wraps, y/z are bounded.
pub fn normalizeChunkCoords(coords: ChunkCoords) ?ChunkCoords {
    if (coords[1] < 0 or coords[1] >= WORLD_SIZE[1] or
        coords[2] < 0 or coords[2] >= WORLD_SIZE[2]) return null;
    var normalized = coords;
    normalized[0] = @mod(coords[0], WORLD_SIZE[0]);
    return normalized;
}

/// Pack validated storage coordinates; signed spatial coordinates must be normalized first.
pub fn encodeChunkPosition(x: anytype, y: anytype, z: anytype) ChunkPosition {
    std.debug.assert(x >= 0 and x < WORLD_SIZE[0]);
    std.debug.assert(y >= 0 and y < WORLD_SIZE[1]);
    std.debug.assert(z >= 0 and z < WORLD_SIZE[2]);
    return @as(ChunkPosition, @intCast(x)) |
        @as(ChunkPosition, @intCast(y)) << 12 |
        @as(ChunkPosition, @intCast(z)) << 20;
}

pub fn encodeChunkCoords(coords: ChunkCoords) ChunkPosition {
    return encodeChunkPosition(coords[0], coords[1], coords[2]);
}

/// Face neighbors wrap around x; missing neighbors beyond y/z leave the world exposed.
pub fn adjacentChunk(coords: ChunkCoords, side: Side) ?ChunkCoords {
    std.debug.assert(@reduce(.And, coords >= @as(ChunkCoords, @splat(0))));
    std.debug.assert(@reduce(.And, coords < WORLD_SIZE));
    return normalizeChunkCoords(coords + side.getOffset());
}

pub fn decodeChunkPosition(position: ChunkPosition) ChunkCoords {
    return .{
        @as(i32, @intCast(position & 0xfff)), //      first 12 bit
        @as(i32, @intCast(position >> 12 & 0xff)), // then 8 bit
        @as(i32, @intCast(position >> 20)), //        and rest (3/4 bit)
    };
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
    chunk_revision: u32 = 0,
    /// Cached own boundary occupancy, including optimistic edits. Never sent to the GPU.
    boundaries: boundary_mask.BoundaryMasks = @splat(.{}),

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

    pub fn clone(self: WorldChunk, allocator: std.mem.Allocator) WorldChunk {
        var copy = self;
        if (self.content == .blocks) {
            const data = allocator.create(WorldChunkData) catch @panic("OOM");
            data.* = self.content.blocks.*;
            copy.content = .{ .blocks = data };
        }
        return copy;
    }

    pub fn ensureData(self: *WorldChunk, allocator: std.mem.Allocator) *WorldChunkData {
        if (self.content == .empty) {
            const data = allocator.create(WorldChunkData) catch @panic("OOM");
            data.* = WorldChunkData.initEmpty();
            self.content = .{ .blocks = data };
        }
        return self.content.blocks;
    }

    /// Applies the same preconditions to authoritative commands and optimistic replay.
    /// Revision assignment belongs to the service, not this data manipulation helper.
    pub fn apply(self: *WorldChunk, allocator: std.mem.Allocator, local: [3]u5, action: BlockAction) OperationStatus {
        const existing = self.content.getBlock(local);
        const block_type: BlockType = switch (action) {
            .put => |block_type| blk: {
                std.debug.assert(block_type != .none);
                if (existing != .none) return .already_exists;
                break :blk block_type;
            },
            .remove => blk: {
                if (existing == .none) return .already_removed;
                break :blk .none;
            },
        };
        const data = self.ensureData(allocator);
        const was_unreachable = self.flags.is_unreachable;
        data.blocks[local[2]][local[1]][local[0]] = block_type;
        boundary_mask.update(&self.boundaries, local, block_type != .none);
        if (block_type == .none) {
            self.solid_block_count -= 1;
        } else {
            self.solid_block_count += 1;
        }
        if (self.solid_block_count == 0) {
            self.content.deinit(allocator);
            self.content = .empty;
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

pub const ChunksHashMap = std.AutoHashMapUnmanaged(ChunkPosition, WorldChunk);

pub const ChunkNotReceivedError = error{ChunkNotReceived};

pub const BlockAction = union(enum) {
    put: BlockType,
    remove,
};

pub const OperationStatus = enum { success, already_exists, already_removed };

/// Commands contain global block coordinates and intent, never chunk snapshots.
pub const BlockOperation = struct {
    block: [3]u32,
    action: BlockAction,

    pub fn validate(self: BlockOperation) void {
        for (0..3) |axis| std.debug.assert(self.block[axis] < WORLD_SIZE[axis] * CHUNK_SIZE);
        if (self.action == .put) std.debug.assert(self.action.put != .none);
    }
};

pub const PendingOperation = struct {
    operation: BlockOperation,
    /// Assigned when the command is submitted to the service.
    request_id: ?u64 = null,
};

/// Main-thread cache: authoritative snapshots with unacknowledged local operations replayed
/// on top. Receiving a failed operation's snapshot rolls it back without losing later edits.
pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: ChunksHashMap = .empty,
    pending_operations: std.ArrayList(PendingOperation) = .empty,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *World) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |chunk| chunk.content.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.pending_operations.deinit(self.allocator);
    }

    pub fn hasChunk(self: *const World, coords: ChunkCoords) bool {
        return self.chunks.contains(encodeChunkCoords(coords));
    }

    /// Takes ownership on success. Subscription tokens must be checked by the caller first.
    /// Replaces the cache with authoritative data, then replays pending commands in order.
    pub fn insertChunk(self: *World, coords: ChunkCoords, chunk: WorldChunk) error{StaleChunk}!void {
        const position = encodeChunkCoords(coords);
        var updated = chunk;
        if (self.chunks.getPtr(position)) |previous| {
            if (chunk.chunk_revision < previous.chunk_revision) return error.StaleChunk;
            // An in-flight snapshot must never undo an optimistic reveal.
            updated.flags.is_unreachable = updated.flags.is_unreachable and previous.flags.is_unreachable;
            previous.content.deinit(self.allocator);
        }
        for (self.pending_operations.items) |pending| {
            const pending_coords, const local = splitBlockCoords(pending.operation.block);
            if (encodeChunkCoords(pending_coords) == position) {
                _ = updated.apply(self.allocator, local, pending.operation.action);
            }
        }
        // Loads and neighboring snapshots can arrive in either order. Account for walls
        // already opened in the cache, including edits that haven't reached the service.
        for (std.enums.values(Side)) |side| {
            const neighbor_coords = adjacentChunk(coords, side) orelse continue;
            const neighbor = self.getChunk(neighbor_coords) orelse continue;
            if (!neighbor.flags.getSideSolidness(side.getOpposite())) updated.flags.is_unreachable = false;
        }
        self.chunks.put(self.allocator, position, updated) catch @panic("OOM");
        self.revealNeighbors(coords, updated.flags);
    }

    /// Only a performance hint changes locally. No command or revision is needed: the
    /// service independently reveals these neighbors when it commits the block operation.
    fn revealNeighbors(self: *World, coords: ChunkCoords, flags: ChunkFlags) void {
        for (std.enums.values(Side)) |side| {
            if (flags.getSideSolidness(side)) continue;
            const neighbor_coords = adjacentChunk(coords, side) orelse continue;
            if (self.chunks.getPtr(encodeChunkCoords(neighbor_coords))) |neighbor| {
                neighbor.flags.is_unreachable = false;
            }
        }
    }

    /// Retire both successful and failed commands before incorporating their snapshot.
    pub fn acknowledgeOperation(self: *World, request_id: u64) void {
        for (self.pending_operations.items, 0..) |pending, i| {
            if (pending.request_id == request_id) {
                _ = self.pending_operations.orderedRemove(i);
                return;
            }
        }
    }

    /// Submitted operations survive eviction until acknowledged. Their results must never
    /// resurrect an evicted chunk; the subscription token decides whether to accept the data.
    pub fn removeChunk(self: *World, coords: ChunkCoords) void {
        self.chunks.fetchRemove(encodeChunkCoords(coords)).?.value.content.deinit(self.allocator);
    }

    pub fn getChunk(self: *const World, coords: ChunkCoords) ?WorldChunk {
        inline for (0..3) |axis| std.debug.assert(coords[axis] >= 0 and coords[axis] < WORLD_SIZE[axis]);
        return self.chunks.get(encodeChunkCoords(coords));
    }

    pub fn ensureChunkData(self: *World, coords: ChunkCoords) *WorldChunkData {
        return self.chunks.getPtr(encodeChunkCoords(coords)).?.ensureData(self.allocator);
    }

    pub fn isBlockSolid(self: *const World, block: [3]u32) ChunkNotReceivedError!bool {
        const coords, const local = splitBlockCoords(block);
        const chunk = self.getChunk(coords) orelse return error.ChunkNotReceived;
        return chunk.content.getBlock(local) != .none;
    }

    pub fn hasPendingMeshDependency(self: *const World, coords: ChunkCoords) bool {
        for (self.pending_operations.items) |pending| {
            const changed, const local = splitBlockCoords(pending.operation.block);
            if (@reduce(.And, changed == coords)) return true;
            for (std.enums.values(Side)) |side| {
                const i = @intFromEnum(side);
                if (local[i / 2] != (if (i % 2 == 0) @as(u5, 0) else CHUNK_SIZE - 1)) continue;
                const neighbor = adjacentChunk(changed, side) orelse continue;
                if (@reduce(.And, neighbor == coords)) return true;
            }
        }
        return false;
    }

    /// Apply immediately and queue intent for the next flush. A locally conflicting edit is
    /// a no-op; the service independently checks every command that does get submitted.
    pub fn setBlock(self: *World, block: [3]u32, block_type: BlockType) void {
        const operation = BlockOperation{
            .block = block,
            .action = if (block_type == .none) .remove else .{ .put = block_type },
        };
        operation.validate();
        const coords, const local = splitBlockCoords(block);
        const chunk = self.chunks.getPtr(encodeChunkCoords(coords)).?;
        if (chunk.apply(self.allocator, local, operation.action) != .success) return;
        self.revealNeighbors(coords, chunk.flags);
        self.pending_operations.append(self.allocator, .{ .operation = operation }) catch @panic("OOM");
    }

    /// Removes the topmost solid block in the inclusive range [minimum_z, top.z].
    /// Returns the removed block, or null if there is nothing to remove. Fails without changing
    /// anything if it has to look into a chunk that isn't received.
    pub fn removeTopBlockInColumn(self: *World, top: [3]u32, minimum_z: u32) ChunkNotReceivedError!?[3]u32 {
        if (minimum_z > top[2]) return null;
        var block = top;
        while (true) : (block[2] -= 1) {
            if (try self.isBlockSolid(block)) {
                self.setBlock(block, .none);
                return block;
            }
            if (block[2] == minimum_z) return null;
        }
    }

    /// Searches the inclusive range [minimum_z, top.z], placing above the first solid block
    /// (or on the world bottom when minimum_z is zero). No support means no placement.
    /// Returns the placed block, or null if `top` is occupied. Fails without changing anything
    /// if it has to look into a chunk that isn't received.
    pub fn dropBlockInColumn(self: *World, top: [3]u32, block_type: BlockType, minimum_z: u32) ChunkNotReceivedError!?[3]u32 {
        if (minimum_z > top[2]) return null;
        if (try self.isBlockSolid(top)) {
            return null;
        }

        var block = top;
        while (block[2] > minimum_z and !try self.isBlockSolid(.{ block[0], block[1], block[2] - 1 })) {
            block[2] -= 1;
        }

        // No support was found within reach; do not create a floating block at the limit.
        if (block[2] == minimum_z and minimum_z != 0) return null;
        self.setBlock(block, block_type);
        return block;
    }
};

fn insertGeneratedChunks(
    world: *World,
    generator: world_generator.WorldGenerator,
    column: @Vector(2, i32),
    z_start: i32,
    z_end: i32,
) !void {
    const column_generator = world_generator.ColumnGenerator.init(generator, column);
    var z = z_start;
    while (z < z_end) : (z += 1) {
        try world.insertChunk(.{ column[0], column[1], z }, column_generator.generateChunk(world.allocator, z));
    }
}

test "normalized signed chunk coordinates preserve the packed storage ID format" {
    const coords = normalizeChunkCoords(.{ -1, 20, 3 }).?;
    const id = encodeChunkCoords(coords);
    try std.testing.expectEqual(@as(u32, (WORLD_SIZE[0] - 1) | (20 << 12) | (3 << 20)), id);
    try std.testing.expectEqual(coords, decodeChunkPosition(id));
    try std.testing.expectEqual(ChunkCoords{ 0, 20, 3 }, adjacentChunk(coords, .right).?);
    try std.testing.expectEqual(null, adjacentChunk(.{ 0, 0, 0 }, .front));
    try std.testing.expectEqual(null, adjacentChunk(.{ 0, 0, 0 }, .bottom));
}

test "chunks are available only after they are inserted" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    try std.testing.expectEqual(null, world.getChunk(.{ 3, 7, 4 }));

    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 3, 7 }, 4, 5);
    try std.testing.expect(world.hasChunk(.{ 3, 7, 4 }));
    try std.testing.expectEqual(null, world.getChunk(.{ 3, 7, 3 }));

    world.removeChunk(.{ 3, 7, 4 });
    try std.testing.expectEqual(null, world.getChunk(.{ 3, 7, 4 }));
}

test "removing and dropping a block in a column are inverse operations" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const top = [3]u32{ 100, 200, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    const column, _ = splitBlockCoords(top);
    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ column[0], column[1] }, 0, WORLD_SIZE[2]);

    const removed = (try world.removeTopBlockInColumn(top, 0)).?;
    try std.testing.expect(!try world.isBlockSolid(removed));
    try std.testing.expect(try world.isBlockSolid(.{ removed[0], removed[1], removed[2] - 1 }));

    const chunk_coords, _ = splitBlockCoords(removed);
    try std.testing.expect(!world.getChunk(chunk_coords).?.isDirty());

    const placed = (try world.dropBlockInColumn(top, .dirt, 0)).?;
    try std.testing.expectEqual(removed, placed);
    try std.testing.expect(try world.isBlockSolid(placed));
    try std.testing.expectEqual(0, world.getChunk(chunk_coords).?.chunk_revision);
}

test "editing a generated stone chunk keeps the rest of its blocks" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 }, 0, 1);

    const removed = (try world.removeTopBlockInColumn(.{ 5, 5, CHUNK_SIZE - 1 }, 0)).?;
    try std.testing.expectEqual([3]u32{ 5, 5, CHUNK_SIZE - 1 }, removed);

    const chunk = world.getChunk(.{ 0, 0, 0 }).?;
    try std.testing.expect(!chunk.isDirty());
    try std.testing.expect(!chunk.flags.solid_top);
    try std.testing.expect(chunk.flags.solid_bottom);
    try std.testing.expectEqual(BlockType.stone, chunk.content.blocks.blocks[0][0][0]);
}

test "column operations do nothing when there is no room" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try insertGeneratedChunks(&world, .flat, .{ 0, 0 }, 0, 1);

    const bottom = [3]u32{ 0, 0, 0 };
    try std.testing.expectEqual(null, try world.dropBlockInColumn(bottom, .dirt, 0));
    try std.testing.expectEqual(bottom, (try world.removeTopBlockInColumn(bottom, 0)).?);
    try std.testing.expectEqual(null, try world.removeTopBlockInColumn(bottom, 0));
}

test "column operations fail without changes when they reach a chunk that isn't received" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    // Only the air at the top of the column.
    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 }, WORLD_SIZE[2] - 1, WORLD_SIZE[2]);

    const top = [3]u32{ 5, 5, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    try std.testing.expectError(error.ChunkNotReceived, world.removeTopBlockInColumn(top, 0));
    try std.testing.expectError(error.ChunkNotReceived, world.dropBlockInColumn(top, .dirt, 0));
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    try std.testing.expect(!world.getChunk(.{ 0, 0, WORLD_SIZE[2] - 1 }).?.isDirty());
}

fn createSolidChunk(revision: u32) WorldChunk {
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
    var world = World.init(std.testing.allocator);
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

test "column operations modify the chunk below when they cross a chunk border" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const lower = ChunkCoords{ 0, 0, WORLD_SIZE[2] - 2 };
    const upper = ChunkCoords{ 0, 0, WORLD_SIZE[2] - 1 };
    try world.insertChunk(lower, createSolidChunk(0));
    try world.insertChunk(upper, WorldChunk.initEmpty());

    const top = [3]u32{ 3, 4, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    const lower_top = [3]u32{ 3, 4, upper[2] * CHUNK_SIZE - 1 };
    try std.testing.expectEqual(lower_top, (try world.removeTopBlockInColumn(top, 0)).?);
    try std.testing.expectEqual(0, world.getChunk(lower).?.chunk_revision);
    try std.testing.expectEqual(WorldChunk.initEmpty(), world.getChunk(upper).?);

    try std.testing.expectEqual(lower_top, (try world.dropBlockInColumn(top, .dirt, 0)).?);
    const upper_bottom = [3]u32{ 3, 4, upper[2] * CHUNK_SIZE };
    try std.testing.expectEqual(upper_bottom, (try world.dropBlockInColumn(top, .dirt, 0)).?);

    try std.testing.expectEqual(0, world.getChunk(lower).?.chunk_revision);
    const upper_chunk = world.getChunk(upper).?;
    try std.testing.expectEqual(0, upper_chunk.chunk_revision);
    try std.testing.expectEqual(BlockType.dirt, upper_chunk.content.getBlock(.{ 3, 4, 0 }));
}

test "dropped block falls to the bottom of the world" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());

    try std.testing.expectEqual([3]u32{ 7, 8, 0 }, (try world.dropBlockInColumn(.{ 7, 8, CHUNK_SIZE - 1 }, .dirt, 0)).?);
    try std.testing.expectEqual(0, world.getChunk(.{ 0, 0, 0 }).?.chunk_revision);
}

test "placing a block into an empty chunk keeps the rest of it air" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());

    world.setBlock(.{ 1, 2, 3 }, .dirt);

    var expected = WorldChunkData.initEmpty();
    expected.blocks[3][2][1] = .dirt;
    const chunk = world.getChunk(.{ 0, 0, 0 }).?;
    try std.testing.expect(chunk.content == .blocks);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected.blocks), std.mem.asBytes(&chunk.content.blocks.blocks));
    try std.testing.expectEqual(expected.getMetaFlags(), chunk.flags);
    try std.testing.expectEqual(1, chunk.solid_block_count);
}

test "solid block count follows block edits" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const coords = ChunkCoords{ 0, 0, 0 };
    const full_count = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
    try world.insertChunk(coords, createSolidChunk(0));
    try std.testing.expectEqual(full_count, world.getChunk(coords).?.solid_block_count);

    world.setBlock(.{ 1, 2, 3 }, .none);
    try std.testing.expectEqual(full_count - 1, world.getChunk(coords).?.solid_block_count);
    world.setBlock(.{ 1, 2, 3 }, .none);
    try std.testing.expectEqual(full_count - 1, world.getChunk(coords).?.solid_block_count);
    world.setBlock(.{ 4, 5, 6 }, .dirt);
    try std.testing.expectEqual(full_count - 1, world.getChunk(coords).?.solid_block_count);
    world.setBlock(.{ 1, 2, 3 }, .dirt);

    const chunk = world.getChunk(coords).?;
    try std.testing.expectEqual(full_count, chunk.solid_block_count);
    try std.testing.expectEqual(chunk.content.blocks.countSolidBlocks(), chunk.solid_block_count);
    try std.testing.expectEqual(0, chunk.chunk_revision);
}

test "removing the last solid block turns the chunk back into empty" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 1, 2, 3 }, .dirt);
    world.setBlock(.{ 4, 5, 6 }, .stone);

    world.setBlock(.{ 1, 2, 3 }, .none);
    try std.testing.expect(world.getChunk(coords).?.content == .blocks);

    world.setBlock(.{ 4, 5, 6 }, .none);
    const chunk = world.getChunk(coords).?;
    try std.testing.expect(chunk.content == .empty);
    try std.testing.expectEqual(WorldChunk.initEmpty().flags, chunk.flags);
    try std.testing.expectEqual(0, chunk.solid_block_count);
    // The service has not acknowledged these optimistic changes yet.
    try std.testing.expectEqual(0, chunk.chunk_revision);
}

test "setting air into an empty chunk keeps it empty" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 1, 2, 3 }, .none);

    const chunk = world.getChunk(coords).?;
    try std.testing.expect(chunk.content == .empty);
    try std.testing.expectEqual(0, chunk.chunk_revision);
}

test "failed optimistic put restores authority while preserving later edits" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 1, 2, 3 }, .dirt);
    world.pending_operations.items[0].request_id = 10;
    world.setBlock(.{ 4, 5, 6 }, .grass);
    world.pending_operations.items[1].request_id = 11;

    // A worker won the race to the first block. Rebase the two pending commands on its push.
    var authority = WorldChunk.initEmpty();
    defer authority.content.deinit(std.testing.allocator);
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
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 1, 2, 3 }, .dirt);
    world.setBlock(.{ 1, 2, 3 }, .none);
    world.setBlock(.{ 1, 2, 3 }, .grass);
    for (world.pending_operations.items, 1..) |*pending, id| pending.request_id = id;
    var authority = WorldChunk.initEmpty();
    defer authority.content.deinit(std.testing.allocator);
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
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    var initial = WorldChunk.initEmpty();
    _ = initial.apply(std.testing.allocator, .{ 1, 2, 3 }, .{ .put = .dirt });
    try world.insertChunk(coords, initial);
    world.setBlock(.{ 1, 2, 3 }, .none);
    world.pending_operations.items[0].request_id = 1;
    world.setBlock(.{ 1, 2, 3 }, .grass);
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

test "older authoritative snapshots cannot undo a newer revision" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 0, 0 };
    try world.insertChunk(coords, createSolidChunk(3));
    const older = createSolidChunk(2);
    defer older.content.deinit(std.testing.allocator);
    try std.testing.expectError(error.StaleChunk, world.insertChunk(coords, older));
    try std.testing.expectEqual(3, world.getChunk(coords).?.chunk_revision);
}

test "local conflicts queue no command and do not change metadata" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());
    world.setBlock(.{ 0, 0, 0 }, .none);
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    world.setBlock(.{ 0, 0, 0 }, .dirt);
    world.setBlock(.{ 0, 0, 0 }, .stone);
    try std.testing.expectEqual(1, world.pending_operations.items.len);
    const chunk = world.getChunk(.{ 0, 0, 0 }).?;
    try std.testing.expectEqual(BlockType.dirt, chunk.content.getBlock(.{ 0, 0, 0 }));
    try std.testing.expectEqual(1, chunk.solid_block_count);
    try std.testing.expectEqual(0, chunk.chunk_revision);
}

test "opening each solid face reveals only its cached neighbor without queuing metadata edits" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const coords = ChunkCoords{ 0, 3, 2 };
    var source = createSolidChunk(3);
    source.flags.is_unreachable = true;
    try world.insertChunk(coords, source);
    for (std.enums.values(Side)) |side| {
        var neighbor = createSolidChunk(4);
        neighbor.flags.is_unreachable = true;
        try world.insertChunk(adjacentChunk(coords, side).?, neighbor);
    }
    // Interior edits preserve the reachability flag and expose no neighbor.
    world.setBlock(.{ 16, 3 * CHUNK_SIZE + 16, 2 * CHUNK_SIZE + 16 }, .none);
    try std.testing.expect(world.getChunk(coords).?.flags.is_unreachable);
    for (std.enums.values(Side)) |side| {
        try std.testing.expect(world.getChunk(adjacentChunk(coords, side).?).?.flags.is_unreachable);
    }
    for (std.enums.values(Side), 0..) |side, index| {
        var local = [3]u32{ 8, 8, 8 };
        local[index / 2] = if (index % 2 == 0) 0 else CHUNK_SIZE - 1;
        world.setBlock(.{ @as(u32, @intCast(coords[0])) * CHUNK_SIZE + local[0], @as(u32, @intCast(coords[1])) * CHUNK_SIZE + local[1], @as(u32, @intCast(coords[2])) * CHUNK_SIZE + local[2] }, .none);
        for (std.enums.values(Side), 0..) |other_side, other_index| {
            const neighbor = world.getChunk(adjacentChunk(coords, other_side).?).?;
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
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const source_coords = ChunkCoords{ 1, 1, 2 };
    const target_coords = ChunkCoords{ 1, 1, 1 };
    const authority = createSolidChunk(0);
    defer authority.content.deinit(std.testing.allocator);
    var hidden = createSolidChunk(0);
    defer hidden.content.deinit(std.testing.allocator);
    hidden.flags.is_unreachable = true;
    try world.insertChunk(source_coords, authority.clone(std.testing.allocator));
    try world.insertChunk(target_coords, hidden.clone(std.testing.allocator));
    world.setBlock(.{ CHUNK_SIZE + 8, CHUNK_SIZE + 8, 2 * CHUNK_SIZE }, .none);
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
        var world = World.init(std.testing.allocator);
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
    defer chunk.content.deinit(allocator);
    const edits = [_][3]u5{ .{ 8, 8, 8 }, .{ 0, 8, 8 }, .{ 31, 31, 8 }, .{ 0, 0, 0 }, .{ 31, 31, 31 } };
    for (edits) |local| {
        try std.testing.expectEqual(OperationStatus.success, chunk.apply(allocator, local, .remove));
        try std.testing.expectEqualDeep(boundary_mask.extract(chunk.content.blocks), chunk.boundaries);
        try std.testing.expectEqual(chunk.content.blocks.getMetaFlags(), chunk.flags);
    }
    const copy = chunk.clone(allocator);
    defer copy.content.deinit(allocator);
    try std.testing.expectEqualDeep(copy.boundaries, chunk.boundaries);

    var world = World.init(allocator);
    defer world.deinit();
    const coords = ChunkCoords{ 1, 1, 1 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    const block = [3]u32{ CHUNK_SIZE, CHUNK_SIZE + 8, CHUNK_SIZE + 8 };
    world.setBlock(block, .stone);
    world.pending_operations.items[0].request_id = 1;
    // Replaying the optimistic put over a fresh snapshot must rebuild its boundary bit.
    try world.insertChunk(coords, WorldChunk.initEmpty());
    try std.testing.expect(world.getChunk(coords).?.boundaries[0].contains(.left, .{ 0, 8, 8 }));
    world.acknowledgeOperation(1);
    try world.insertChunk(coords, WorldChunk.initEmpty());
    try std.testing.expect(!world.getChunk(coords).?.boundaries[0].contains(.left, .{ 0, 8, 8 }));
}
