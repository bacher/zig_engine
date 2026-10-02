const std = @import("std");

const BlockType = @import("engine").voxel_chunk.BlockType;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const ChunkFlags = @import("./world_chunk_data.zig").ChunkFlags;
const world_generator = @import("./world_generator.zig");
const BlockPosition = @import("./consts.zig").BlockPosition;
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

/// What the chunk consists of. Uniform chunks don't store their blocks, so most of the world
/// (air above the terrain and rock below it) takes almost no memory.
pub const ChunkContent = union(enum) {
    /// Every block has this type. Nothing is allocated.
    uniform: BlockType,
    /// Every block is stored individually. Used for chunks crossing the terrain surface and for
    /// any chunk touched by an edit, even if the edit made it uniform.
    blocks: *WorldChunkData,

    pub fn deinit(self: ChunkContent, allocator: std.mem.Allocator) void {
        switch (self) {
            .blocks => |world_chunk_data| allocator.destroy(world_chunk_data),
            .uniform => {},
        }
    }

    pub fn toData(self: ChunkContent) WorldChunkData {
        return switch (self) {
            .uniform => |block_type| WorldChunkData.initFilled(block_type),
            .blocks => |world_chunk_data| world_chunk_data.*,
        };
    }

    pub fn getBlock(self: ChunkContent, local: [3]u5) BlockType {
        return switch (self) {
            .uniform => |block_type| block_type,
            .blocks => |world_chunk_data| world_chunk_data.blocks[local[2]][local[1]][local[0]],
        };
    }
};

/// A chunk is self-contained: its content and flags are everything needed to render and edit it.
pub const WorldChunk = struct {
    content: ChunkContent,
    flags: ChunkFlags,
    /// Number of modifications made by the player. 0 means the chunk is exactly as generated.
    /// New revisions are produced only by the main thread, which owns block modifications.
    revision: u32 = 0,

    pub fn initUniform(block_type: BlockType) WorldChunk {
        const is_solid = block_type != .none;
        return .{
            .content = .{ .uniform = block_type },
            .flags = .{
                .solid_left = is_solid,
                .solid_right = is_solid,
                .solid_front = is_solid,
                .solid_back = is_solid,
                .solid_bottom = is_solid,
                .solid_top = is_solid,
            },
        };
    }

    /// Takes ownership of the data.
    pub fn initBlocks(world_chunk_data: *WorldChunkData) WorldChunk {
        return .{
            .content = .{ .blocks = world_chunk_data },
            .flags = WorldChunkData.getMetaFlags(world_chunk_data),
        };
    }

    /// The chunk was modified by the player and can't be re-generated from the generator anymore.
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

/// Main thread copy of the chunks received from the world-data thread. It's the source of truth
/// for block modifications: they are applied here immediately and then sent to the world-data
/// thread as chunk snapshots (see `unsyncedChunks`).
pub const World = struct {
    allocator: std.mem.Allocator,
    /// Contains only the received chunks.
    chunks: ChunksHashMap,
    /// Chunks modified since the last `markChunksSynced` call.
    unsynced_chunks: std.AutoArrayHashMapUnmanaged(ChunkPosition, void),
    /// The latest revision produced for every chunk ever modified, including the chunks removed
    /// since. A received chunk with a lower revision is stale.
    latest_revisions: std.AutoHashMapUnmanaged(ChunkPosition, u32),

    pub fn init(allocator: std.mem.Allocator) World {
        return World{
            .allocator = allocator,
            .chunks = .empty,
            .unsynced_chunks = .empty,
            .latest_revisions = .empty,
        };
    }

    pub fn deinit(self: *World) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |chunk| {
            chunk.content.deinit(self.allocator);
        }
        self.chunks.deinit(self.allocator);
        self.unsynced_chunks.deinit(self.allocator);
        self.latest_revisions.deinit(self.allocator);
    }

    pub fn hasChunk(self: *const World, coords: [3]u30) bool {
        return self.chunks.contains(encodeChunkPositionArray(coords));
    }

    /// Takes ownership of the chunk data. If the chunk misses modifications already made on this
    /// thread, it's rejected and stays owned by the caller.
    pub fn insertChunk(self: *World, coords: [3]u30, chunk: WorldChunk) error{StaleChunk}!void {
        const position = encodeChunkPositionArray(coords);
        std.debug.assert(!self.chunks.contains(position));

        if (self.latest_revisions.get(position)) |latest_revision| {
            if (chunk.revision < latest_revision) {
                return error.StaleChunk;
            }
        }

        self.chunks.put(self.allocator, position, chunk) catch @panic("OOM");
    }

    /// Removes the chunk and frees its data. Its modifications must be synced first, otherwise
    /// they would be lost.
    pub fn removeChunk(self: *World, coords: [3]u30) void {
        const position = encodeChunkPositionArray(coords);
        std.debug.assert(!self.unsynced_chunks.contains(position));
        self.chunks.fetchRemove(position).?.value.content.deinit(self.allocator);
    }

    /// Returns the chunk, or null if it isn't received yet.
    /// Returned by value: inserting chunks may reallocate `chunks` and invalidate pointers into it.
    pub fn getChunk(self: *const World, coords: [3]u30) ?WorldChunk {
        std.debug.assert(coords[0] < WORLD_SIZE[0]);
        std.debug.assert(coords[1] < WORLD_SIZE[1]);
        std.debug.assert(coords[2] < WORLD_SIZE[2]);

        return self.chunks.get(encodeChunkPositionArray(coords));
    }

    /// Makes sure the chunk stores its blocks and returns them. The chunk must be received.
    pub fn ensureChunkData(self: *World, coords: [3]u30) *WorldChunkData {
        const chunk = self.chunks.getPtr(encodeChunkPositionArray(coords)).?;

        switch (chunk.content) {
            .blocks => |world_chunk_data| return world_chunk_data,
            .uniform => {
                const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");
                world_chunk_data.* = chunk.content.toData();
                chunk.content = .{ .blocks = world_chunk_data };
                return world_chunk_data;
            },
        }
    }

    pub fn isBlockSolid(self: *const World, block: [3]u32) ChunkNotReceivedError!bool {
        const chunk_coords, const local = splitBlockCoords(block);
        const chunk = self.getChunk(chunk_coords) orelse return error.ChunkNotReceived;
        return chunk.content.getBlock(local) != .none;
    }

    /// Sets the block and bumps the revision of its chunk. The chunk must be received.
    pub fn setBlock(self: *World, block: [3]u32, block_type: BlockType) void {
        const chunk_coords, const local = splitBlockCoords(block);
        const world_chunk_data = self.ensureChunkData(chunk_coords);
        world_chunk_data.blocks[local[2]][local[1]][local[0]] = block_type;

        const position = encodeChunkPositionArray(chunk_coords);
        const chunk = self.chunks.getPtr(position).?;
        chunk.flags = WorldChunkData.getMetaFlags(world_chunk_data);
        chunk.revision += 1;

        self.latest_revisions.put(self.allocator, position, chunk.revision) catch @panic("OOM");
        self.unsynced_chunks.put(self.allocator, position, {}) catch @panic("OOM");
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

    /// Chunks modified since the last `markChunksSynced` call. They always store their blocks.
    pub fn unsyncedChunks(self: *const World) []const ChunkPosition {
        return self.unsynced_chunks.keys();
    }

    pub fn markChunksSynced(self: *World) void {
        self.unsynced_chunks.clearRetainingCapacity();
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
    try std.testing.expect(world.getChunk(chunk_coords).?.isDirty());

    const placed = (try world.dropBlockInColumn(top, .dirt)).?;
    try std.testing.expectEqual(removed, placed);
    try std.testing.expect(try world.isBlockSolid(placed));
    try std.testing.expectEqual(2, world.getChunk(chunk_coords).?.revision);
    try std.testing.expectEqualSlices(ChunkPosition, &.{encodeChunkPositionArray(chunk_coords)}, world.unsyncedChunks());
}

test "editing a uniform chunk fills its data with its block type" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try insertGeneratedChunks(&world, .{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 }, 0, 1);

    try std.testing.expectEqual(WorldChunk.initUniform(.stone), world.getChunk(.{ 0, 0, 0 }).?);

    const removed = (try world.removeTopBlockInColumn(.{ 5, 5, CHUNK_SIZE - 1 })).?;
    try std.testing.expectEqual([3]u32{ 5, 5, CHUNK_SIZE - 1 }, removed);

    const chunk = world.getChunk(.{ 0, 0, 0 }).?;
    try std.testing.expect(chunk.content == .blocks);
    try std.testing.expect(chunk.isDirty());
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
    try std.testing.expectEqual(0, world.unsyncedChunks().len);
    try std.testing.expect(!world.getChunk(.{ 0, 0, WORLD_SIZE[2] - 1 }).?.isDirty());
}

test "chunk missing local modifications is rejected" {
    const generator = world_generator.WorldGenerator{ .terrain = .{ .seed = 12345 } };

    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try insertGeneratedChunks(&world, generator, .{ 0, 0 }, 0, 1);

    _ = (try world.removeTopBlockInColumn(.{ 5, 5, CHUNK_SIZE - 1 })).?;
    world.markChunksSynced();
    world.removeChunk(.{ 0, 0, 0 });

    const stale_chunk = world_generator.ColumnGenerator.init(generator, .{ 0, 0 }).generateChunk(std.testing.allocator, 0);
    defer stale_chunk.content.deinit(std.testing.allocator);
    try std.testing.expectError(error.StaleChunk, world.insertChunk(.{ 0, 0, 0 }, stale_chunk));
    try std.testing.expect(!world.hasChunk(.{ 0, 0, 0 }));
}
