const std = @import("std");

const BlockType = @import("engine").voxel_chunk.BlockType;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const ChunkFlags = @import("./world_chunk_data.zig").ChunkFlags;
const world_generator = @import("./world_generator.zig");
const ChunkPosition = @import("./consts.zig").ChunkPosition;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WORLD_SIZE = @import("./consts.zig").WORLD_SIZE;

pub fn normalizeChunkPosition(x: anytype, y: anytype, z: anytype) [3]u30 {
    var normalized_x = x;

    // only x wraps, y and z are not wrapped
    if (x >= WORLD_SIZE[0]) {
        normalized_x = x - WORLD_SIZE[0];
    } else if (x < 0) {
        normalized_x = x + WORLD_SIZE[0];
    }
    // if (y >= WORLD_SIZE[1]) {
    //     normalized_y = y - WORLD_SIZE[1];
    // } else if (y < 0) {
    //     normalized_y = y + WORLD_SIZE[1];
    // }
    // if (z >= WORLD_SIZE[2]) {
    //     normalized_z = z - WORLD_SIZE[2];
    // } else if (z < 0) {
    //     normalized_z = z + WORLD_SIZE[2];
    // }

    std.debug.assert(y >= 0 and y < WORLD_SIZE[1]);
    std.debug.assert(z >= 0 and z < WORLD_SIZE[2]);

    return .{
        @intCast(normalized_x),
        @intCast(y),
        @intCast(z),
    };
}

pub fn encodeChunkPosition(x: anytype, y: anytype, z: anytype) ChunkPosition {
    return @as(ChunkPosition, @intCast(x)) |
        @as(ChunkPosition, @intCast(y)) << 12 |
        @as(ChunkPosition, @intCast(z)) << 20;
}

pub fn encodeChunkPositionArray(coords: anytype) ChunkPosition {
    return encodeChunkPosition(coords[0], coords[1], coords[2]);
}

pub fn decodeChunkPosition(position: ChunkPosition) [3]u30 {
    return .{
        @as(u30, @intCast(position & 0xfff)), //      first 12 bit
        @as(u30, @intCast(position >> 12 & 0xff)), // then 8 bit
        @as(u30, @intCast(position >> 20)), //        and rest (3/4 bit)
    };
}

pub fn decodeChunkPositionVec(position: ChunkPosition) @Vector(4, i32) {
    return .{
        @as(i32, @intCast(position & 0xfff)), //      first 12 bit
        @as(i32, @intCast(position >> 12 & 0xff)), // then 8 bit
        @as(i32, @intCast(position >> 20)), //        and rest (3/4 bit)
        0,
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

/// A chunk is self-contained: its content and flags are everything needed to render and edit it.
pub const WorldChunk = struct {
    content: ChunkContent,
    flags: ChunkFlags,
    /// Number of blocks of the content that aren't `.none`.
    solid_block_count: u16,
    /// Authoritative revision, advanced only by the world-data service after a successful edit.
    /// Optimistic edits never change it. 0 means no edits have been committed yet.
    revision: u32 = 0,

    pub fn initEmpty() WorldChunk {
        return .{
            .content = .empty,
            .flags = .{},
            .solid_block_count = 0,
        };
    }

    /// Takes ownership of the data.
    pub fn initBlocks(world_chunk_data: *WorldChunkData) WorldChunk {
        return .{
            .content = .{ .blocks = world_chunk_data },
            .flags = WorldChunkData.getMetaFlags(world_chunk_data),
            .solid_block_count = world_chunk_data.countSolidBlocks(),
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
        data.blocks[local[2]][local[1]][local[0]] = block_type;
        if (block_type == .none) {
            self.solid_block_count -= 1;
        } else {
            self.solid_block_count += 1;
        }
        if (self.solid_block_count == 0) {
            self.content.deinit(allocator);
            self.content = .empty;
            self.flags = .{};
        } else {
            self.flags = data.getMetaFlags();
        }
        return .success;
    }

    /// The service has committed modifications that must be preserved.
    pub fn isDirty(self: WorldChunk) bool {
        return self.revision > 0;
    }
};

/// Splits global block coordinates into chunk coordinates and coordinates inside of the chunk.
pub fn splitBlockCoords(block: [3]u32) struct { [3]u30, [3]u5 } {
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

    pub fn hasChunk(self: *const World, coords: [3]u30) bool {
        return self.chunks.contains(encodeChunkPositionArray(coords));
    }

    /// Takes ownership on success. Subscription tokens must be checked by the caller first.
    /// Replaces the cache with authoritative data, then replays pending commands in order.
    pub fn insertChunk(self: *World, coords: [3]u30, chunk: WorldChunk) error{StaleChunk}!void {
        const position = encodeChunkPositionArray(coords);
        if (self.chunks.getPtr(position)) |previous| {
            if (chunk.revision < previous.revision) return error.StaleChunk;
            previous.content.deinit(self.allocator);
        }
        var updated = chunk;
        for (self.pending_operations.items) |pending| {
            const pending_coords, const local = splitBlockCoords(pending.operation.block);
            if (encodeChunkPositionArray(pending_coords) == position) {
                _ = updated.apply(self.allocator, local, pending.operation.action);
            }
        }
        self.chunks.put(self.allocator, position, updated) catch @panic("OOM");
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
    pub fn removeChunk(self: *World, coords: [3]u30) void {
        self.chunks.fetchRemove(encodeChunkPositionArray(coords)).?.value.content.deinit(self.allocator);
    }

    pub fn getChunk(self: *const World, coords: [3]u30) ?WorldChunk {
        for (0..3) |axis| std.debug.assert(coords[axis] < WORLD_SIZE[axis]);
        return self.chunks.get(encodeChunkPositionArray(coords));
    }

    pub fn ensureChunkData(self: *World, coords: [3]u30) *WorldChunkData {
        return self.chunks.getPtr(encodeChunkPositionArray(coords)).?.ensureData(self.allocator);
    }

    pub fn isBlockSolid(self: *const World, block: [3]u32) ChunkNotReceivedError!bool {
        const coords, const local = splitBlockCoords(block);
        const chunk = self.getChunk(coords) orelse return error.ChunkNotReceived;
        return chunk.content.getBlock(local) != .none;
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
        const chunk = self.chunks.getPtr(encodeChunkPositionArray(coords)).?;
        if (chunk.apply(self.allocator, local, operation.action) != .success) return;
        self.pending_operations.append(self.allocator, .{ .operation = operation }) catch @panic("OOM");
    }

    /// Removes the topmost solid block at or below `top`.
    /// Returns the removed block, or null if there is nothing to remove. Fails without changing
    /// anything if it has to look into a chunk that isn't received.
    pub fn removeTopBlockInColumn(self: *World, top: [3]u32) ChunkNotReceivedError!?[3]u32 {
        var block = top;
        while (true) : (block[2] -= 1) {
            if (try self.isBlockSolid(block)) {
                self.setBlock(block, .none);
                return block;
            }
            if (block[2] == 0) {
                return null;
            }
        }
    }

    /// Drops the block down the column starting at `top`, placing it on the first solid block
    /// (or on the bottom of the world).
    /// Returns the placed block, or null if `top` is occupied. Fails without changing anything
    /// if it has to look into a chunk that isn't received.
    pub fn dropBlockInColumn(self: *World, top: [3]u32, block_type: BlockType) ChunkNotReceivedError!?[3]u32 {
        if (try self.isBlockSolid(top)) {
            return null;
        }

        var block = top;
        while (block[2] > 0 and !try self.isBlockSolid(.{ block[0], block[1], block[2] - 1 })) {
            block[2] -= 1;
        }

        self.setBlock(block, block_type);
        return block;
    }
};

fn insertGeneratedChunks(
    world: *World,
    generator: world_generator.WorldGenerator,
    column: [2]u30,
    z_start: u30,
    z_end: u30,
) !void {
    const column_generator = world_generator.ColumnGenerator.init(generator, column);
    var z = z_start;
    while (z < z_end) : (z += 1) {
        try world.insertChunk(.{ column[0], column[1], z }, column_generator.generateChunk(world.allocator, z));
    }
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

    const removed = (try world.removeTopBlockInColumn(top)).?;
    try std.testing.expect(!try world.isBlockSolid(removed));
    try std.testing.expect(try world.isBlockSolid(.{ removed[0], removed[1], removed[2] - 1 }));

    const chunk_coords, _ = splitBlockCoords(removed);
    try std.testing.expect(!world.getChunk(chunk_coords).?.isDirty());

    const placed = (try world.dropBlockInColumn(top, .dirt)).?;
    try std.testing.expectEqual(removed, placed);
    try std.testing.expect(try world.isBlockSolid(placed));
    try std.testing.expectEqual(0, world.getChunk(chunk_coords).?.revision);
}

test "editing a generated stone chunk keeps the rest of its blocks" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 }, 0, 1);

    const removed = (try world.removeTopBlockInColumn(.{ 5, 5, CHUNK_SIZE - 1 })).?;
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
    try std.testing.expectEqual(null, try world.dropBlockInColumn(bottom, .dirt));
    try std.testing.expectEqual(bottom, (try world.removeTopBlockInColumn(bottom)).?);
    try std.testing.expectEqual(null, try world.removeTopBlockInColumn(bottom));
}

test "column operations fail without changes when they reach a chunk that isn't received" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    // Only the air at the top of the column.
    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 }, WORLD_SIZE[2] - 1, WORLD_SIZE[2]);

    const top = [3]u32{ 5, 5, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    try std.testing.expectError(error.ChunkNotReceived, world.removeTopBlockInColumn(top));
    try std.testing.expectError(error.ChunkNotReceived, world.dropBlockInColumn(top, .dirt));
    try std.testing.expectEqual(0, world.pending_operations.items.len);
    try std.testing.expect(!world.getChunk(.{ 0, 0, WORLD_SIZE[2] - 1 }).?.isDirty());
}

fn createSolidChunk(revision: u32) WorldChunk {
    const world_chunk_data = std.testing.allocator.create(WorldChunkData) catch @panic("OOM");
    world_chunk_data.* = WorldChunkData.initSolid();
    var chunk = WorldChunk.initBlocks(world_chunk_data);
    chunk.revision = revision;
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

    const coords = [3]u30{ 0, 0, 0 };
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

    const lower = [3]u30{ 0, 0, WORLD_SIZE[2] - 2 };
    const upper = [3]u30{ 0, 0, WORLD_SIZE[2] - 1 };
    try world.insertChunk(lower, createSolidChunk(0));
    try world.insertChunk(upper, WorldChunk.initEmpty());

    const top = [3]u32{ 3, 4, WORLD_SIZE[2] * CHUNK_SIZE - 1 };
    const lower_top = [3]u32{ 3, 4, upper[2] * CHUNK_SIZE - 1 };
    try std.testing.expectEqual(lower_top, (try world.removeTopBlockInColumn(top)).?);
    try std.testing.expectEqual(0, world.getChunk(lower).?.revision);
    try std.testing.expectEqual(WorldChunk.initEmpty(), world.getChunk(upper).?);

    try std.testing.expectEqual(lower_top, (try world.dropBlockInColumn(top, .dirt)).?);
    const upper_bottom = [3]u32{ 3, 4, upper[2] * CHUNK_SIZE };
    try std.testing.expectEqual(upper_bottom, (try world.dropBlockInColumn(top, .dirt)).?);

    try std.testing.expectEqual(0, world.getChunk(lower).?.revision);
    const upper_chunk = world.getChunk(upper).?;
    try std.testing.expectEqual(0, upper_chunk.revision);
    try std.testing.expectEqual(BlockType.dirt, upper_chunk.content.getBlock(.{ 3, 4, 0 }));
}

test "dropped block falls to the bottom of the world" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try world.insertChunk(.{ 0, 0, 0 }, WorldChunk.initEmpty());

    try std.testing.expectEqual([3]u32{ 7, 8, 0 }, (try world.dropBlockInColumn(.{ 7, 8, CHUNK_SIZE - 1 }, .dirt)).?);
    try std.testing.expectEqual(0, world.getChunk(.{ 0, 0, 0 }).?.revision);
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

    const coords = [3]u30{ 0, 0, 0 };
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
    try std.testing.expectEqual(0, chunk.revision);
}

test "removing the last solid block turns the chunk back into empty" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const coords = [3]u30{ 0, 0, 0 };
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
    try std.testing.expectEqual(0, chunk.revision);
}

test "setting air into an empty chunk keeps it empty" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const coords = [3]u30{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 1, 2, 3 }, .none);

    const chunk = world.getChunk(coords).?;
    try std.testing.expect(chunk.content == .empty);
    try std.testing.expectEqual(0, chunk.revision);
}

test "failed optimistic put restores authority while preserving later edits" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const coords = [3]u30{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 1, 2, 3 }, .dirt);
    world.pending_operations.items[0].request_id = 10;
    world.setBlock(.{ 4, 5, 6 }, .grass);
    world.pending_operations.items[1].request_id = 11;

    // A worker won the race to the first block. Rebase the two pending commands on its push.
    var authority = WorldChunk.initEmpty();
    defer authority.content.deinit(std.testing.allocator);
    _ = authority.apply(std.testing.allocator, .{ 1, 2, 3 }, .{ .put = .stone });
    authority.revision = 1;
    try world.insertChunk(coords, authority.clone(std.testing.allocator));
    try std.testing.expectEqual(BlockType.stone, world.getChunk(coords).?.content.getBlock(.{ 1, 2, 3 }));
    try std.testing.expectEqual(BlockType.grass, world.getChunk(coords).?.content.getBlock(.{ 4, 5, 6 }));

    world.acknowledgeOperation(10); // already_exists, same authoritative revision
    try world.insertChunk(coords, authority.clone(std.testing.allocator));
    const reconciled = world.getChunk(coords).?;
    try std.testing.expectEqual(BlockType.stone, reconciled.content.getBlock(.{ 1, 2, 3 }));
    try std.testing.expectEqual(BlockType.grass, reconciled.content.getBlock(.{ 4, 5, 6 }));
    try std.testing.expectEqual(1, reconciled.revision);
    try std.testing.expectEqual(1, world.pending_operations.items.len);
}

test "acknowledging edits in order preserves pending remove and put on the same block" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const coords = [3]u30{ 0, 0, 0 };
    try world.insertChunk(coords, WorldChunk.initEmpty());
    world.setBlock(.{ 1, 2, 3 }, .dirt);
    world.setBlock(.{ 1, 2, 3 }, .none);
    world.setBlock(.{ 1, 2, 3 }, .grass);
    for (world.pending_operations.items, 1..) |*pending, id| pending.request_id = id;
    var authority = WorldChunk.initEmpty();
    defer authority.content.deinit(std.testing.allocator);
    for ([_]BlockAction{ .{ .put = .dirt }, .remove, .{ .put = .grass } }, 1..) |action, id| {
        _ = authority.apply(std.testing.allocator, .{ 1, 2, 3 }, action);
        authority.revision = @intCast(id);
        world.acknowledgeOperation(id);
        try world.insertChunk(coords, authority.clone(std.testing.allocator));
        try std.testing.expectEqual(BlockType.grass, world.getChunk(coords).?.content.getBlock(.{ 1, 2, 3 }));
        try std.testing.expectEqual(id, world.getChunk(coords).?.revision);
    }
    try std.testing.expectEqual(0, world.pending_operations.items.len);
}

test "failed remove and unrelated worker edits survive reconciliation" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const coords = [3]u30{ 0, 0, 0 };
    var initial = WorldChunk.initEmpty();
    _ = initial.apply(std.testing.allocator, .{ 1, 2, 3 }, .{ .put = .dirt });
    try world.insertChunk(coords, initial);
    world.setBlock(.{ 1, 2, 3 }, .none);
    world.pending_operations.items[0].request_id = 1;
    world.setBlock(.{ 1, 2, 3 }, .grass);
    world.pending_operations.items[1].request_id = 2;

    var authority = WorldChunk.initEmpty();
    _ = authority.apply(std.testing.allocator, .{ 4, 5, 6 }, .{ .put = .stone });
    authority.revision = 3;
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
    const coords = [3]u30{ 0, 0, 0 };
    try world.insertChunk(coords, createSolidChunk(3));
    const older = createSolidChunk(2);
    defer older.content.deinit(std.testing.allocator);
    try std.testing.expectError(error.StaleChunk, world.insertChunk(coords, older));
    try std.testing.expectEqual(3, world.getChunk(coords).?.revision);
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
    try std.testing.expectEqual(0, chunk.revision);
}
