const std = @import("std");

const BlockType = @import("engine").voxel_chunk.BlockType;
const PerlinNoise = @import("./perlin_noise.zig").PerlinNoise;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const ChunkFlags = @import("./world_chunk_data.zig").ChunkFlags;
const BlockPosition = @import("./consts.zig").BlockPosition;
const ChunkPosition = @import("./consts.zig").ChunkPosition;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WORLD_SIZE = @import("./consts.zig").WORLD_SIZE;

pub const WorldGenerationParams = struct {
    /// Width, in blocks, of the first noise octave's features.
    noise_scale: f64 = 192.0,
    /// Number of noise layers. More octaves add smaller terrain details.
    octaves: u8 = 4,
    /// Frequency multiplier applied to each successive octave.
    lacunarity: f64 = 2.0,
    /// Amplitude multiplier applied to each successive octave.
    persistence: f64 = 0.5,
    /// Average terrain height measured in blocks from the bottom of the world.
    base_height: u32 = WORLD_SIZE[2] * CHUNK_SIZE / 2,
    /// Maximum vertical displacement from base_height.
    height_amplitude: f64 = 48.0,
    /// Number of dirt blocks below each grass surface block.
    dirt_depth: u8 = 4,
};

const solid_chunk_flags = ChunkFlags{
    .solid_top = true,
    .solid_bottom = true,
    .solid_front = true,
    .solid_back = true,
    .solid_left = true,
    .solid_right = true,
};

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
    /// Every block is `.none`. Nothing is allocated.
    empty,
    /// Every block is solid. Nothing is allocated, the exact block types are known only to the
    /// generator and are produced by `World.ensureChunkData` when they are needed.
    solid,
    /// Every block is stored individually. Used for chunks crossing the terrain surface and for
    /// any chunk touched by an edit, even if the edit made it fully empty or fully solid.
    blocks: *WorldChunkData,
};

pub const WorldChunk = struct {
    content: ChunkContent,
    flags: ChunkFlags,
    /// The chunk was modified by the player and can't be re-generated from the generator anymore.
    is_dirty: bool = false,
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

pub const WorldGenerator = union(enum) {
    flat,
    terrain: struct {
        seed: u64,
        params: WorldGenerationParams = .{},
    },
};

pub const World = struct {
    allocator: std.mem.Allocator,
    generator: WorldGenerator,
    /// Contains only chunks of the columns generated so far.
    chunks: ChunksHashMap,

    pub fn init(allocator: std.mem.Allocator, generator: WorldGenerator) World {
        switch (generator) {
            .flat => {},
            .terrain => |terrain| {
                const params = terrain.params;
                std.debug.assert(params.noise_scale > 0.0 and std.math.isFinite(params.noise_scale));
                std.debug.assert(params.octaves > 0);
                std.debug.assert(params.lacunarity > 0.0 and std.math.isFinite(params.lacunarity));
                std.debug.assert(params.persistence >= 0.0 and std.math.isFinite(params.persistence));
                std.debug.assert(params.height_amplitude >= 0.0 and std.math.isFinite(params.height_amplitude));
            },
        }

        return World{
            .allocator = allocator,
            .generator = generator,
            .chunks = .empty,
        };
    }

    pub fn deinit(self: *World) void {
        self.destroyChunksData();
        self.chunks.deinit(self.allocator);
    }

    /// Returns the chunk at `coords`, generating its whole column on first access.
    /// Returned by value: generating other chunks may reallocate `chunks` and
    /// invalidate pointers into it.
    pub fn getChunk(self: *World, coords: [3]u30) WorldChunk {
        std.debug.assert(coords[0] < WORLD_SIZE[0]);
        std.debug.assert(coords[1] < WORLD_SIZE[1]);
        std.debug.assert(coords[2] < WORLD_SIZE[2]);

        const position = encodeChunkPositionArray(coords);
        if (self.chunks.get(position)) |chunk| {
            return chunk;
        }

        self.generateColumn(coords[0], coords[1]);
        return self.chunks.get(position).?;
    }

    /// Makes sure the chunk stores its blocks, generating them if needed, and returns them.
    pub fn ensureChunkData(self: *World, coords: [3]u30) *WorldChunkData {
        _ = self.getChunk(coords);
        const chunk = self.chunks.getPtr(encodeChunkPositionArray(coords)).?;

        const generated_data = switch (chunk.content) {
            .blocks => |world_chunk_data| return world_chunk_data,
            .empty => WorldChunkData.initEmpty(),
            .solid => self.generateSolidChunkData(coords),
        };

        const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");
        world_chunk_data.* = generated_data;
        chunk.content = .{ .blocks = world_chunk_data };

        return world_chunk_data;
    }

    pub fn isBlockSolid(self: *World, block: [3]u32) bool {
        const chunk_coords, const local = splitBlockCoords(block);

        return switch (self.getChunk(chunk_coords).content) {
            .empty => false,
            .solid => true,
            .blocks => |world_chunk_data| world_chunk_data.blocks[local[2]][local[1]][local[0]] != .none,
        };
    }

    /// Sets the block and marks its chunk as dirty.
    pub fn setBlock(self: *World, block: [3]u32, block_type: BlockType) void {
        const chunk_coords, const local = splitBlockCoords(block);
        const world_chunk_data = self.ensureChunkData(chunk_coords);
        world_chunk_data.blocks[local[2]][local[1]][local[0]] = block_type;

        const chunk = self.chunks.getPtr(encodeChunkPositionArray(chunk_coords)).?;
        chunk.flags = WorldChunkData.getMetaFlags(world_chunk_data);
        chunk.is_dirty = true;
    }

    /// Removes the topmost solid block at or below `top`.
    /// Returns the removed block, or null if there is nothing to remove.
    pub fn removeTopBlockInColumn(self: *World, top: [3]u32) ?[3]u32 {
        var block = top;
        while (true) : (block[2] -= 1) {
            if (self.isBlockSolid(block)) {
                self.setBlock(block, .none);
                return block;
            }
            if (block[2] == 0) {
                return null;
            }
        }
    }

    /// Drops the block down the column starting at `top`, placing it on the first solid block
    /// (or on the bottom of the world). Returns the placed block, or null if `top` is occupied.
    pub fn dropBlockInColumn(self: *World, top: [3]u32, block_type: BlockType) ?[3]u32 {
        if (self.isBlockSolid(top)) {
            return null;
        }

        var block = top;
        while (block[2] > 0 and !self.isBlockSolid(.{ block[0], block[1], block[2] - 1 })) {
            block[2] -= 1;
        }

        self.setBlock(block, block_type);
        return block;
    }

    fn generateSolidChunkData(self: *World, coords: [3]u30) WorldChunkData {
        return switch (self.generator) {
            .flat => WorldChunkData.initSolid(),
            .terrain => |terrain| data: {
                const heights = terrainColumnHeights(coords[0], coords[1], terrain.seed, terrain.params);
                break :data generateTerrainChunk(&heights, @as(u32, coords[2]) * CHUNK_SIZE, terrain.params.dirt_depth);
            },
        };
    }

    fn generateColumn(self: *World, chunk_x: u30, chunk_y: u30) void {
        self.chunks.ensureUnusedCapacity(self.allocator, WORLD_SIZE[2]) catch @panic("OOM");

        switch (self.generator) {
            .flat => self.generateFlatColumn(chunk_x, chunk_y),
            .terrain => |terrain| self.generateTerrainColumn(chunk_x, chunk_y, terrain.seed, terrain.params),
        }
    }

    fn generateFlatColumn(self: *World, chunk_x: u30, chunk_y: u30) void {
        const center_z = WORLD_SIZE[2] / 2;

        for (0..WORLD_SIZE[2]) |z| {
            var map_chunk: WorldChunk = undefined;

            if (z == center_z - 1) {
                const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");

                world_chunk_data.* = WorldChunkData.initFlat();

                map_chunk = .{
                    .content = .{ .blocks = world_chunk_data },
                    .flags = WorldChunkData.getMetaFlags(world_chunk_data),
                };
            } else if (z == center_z - 2) {
                // const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");
                // world_chunk_data.* = WorldChunkData.initSolid();

                map_chunk = .{
                    // .content = .{ .blocks = world_chunk_data },
                    .content = .solid,
                    .flags = solid_chunk_flags,
                };
            } else if (z < center_z - 2) {
                map_chunk = .{
                    .content = .solid,
                    .flags = solid_chunk_flags,
                };
            } else {
                map_chunk = .{
                    .content = .empty,
                    .flags = .{},
                };
            }

            self.chunks.putAssumeCapacity(encodeChunkPosition(chunk_x, chunk_y, z), map_chunk);
        }
    }

    fn generateTerrainColumn(
        self: *World,
        chunk_x: u30,
        chunk_y: u30,
        seed: u64,
        params: WorldGenerationParams,
    ) void {
        const heights = terrainColumnHeights(chunk_x, chunk_y, seed, params);

        var minimum_height: u32 = WORLD_SIZE[2] * CHUNK_SIZE;
        var maximum_height: u32 = 0;

        for (heights) |row| {
            for (row) |height| {
                minimum_height = @min(minimum_height, height);
                maximum_height = @max(maximum_height, height);
            }
        }

        for (0..WORLD_SIZE[2]) |chunk_z| {
            const chunk_bottom: u32 = @intCast(chunk_z * CHUNK_SIZE);
            const chunk_top = chunk_bottom + CHUNK_SIZE;
            var map_chunk: WorldChunk = undefined;

            if (chunk_top <= minimum_height) {
                map_chunk = .{
                    .content = .solid,
                    .flags = solid_chunk_flags,
                };
            } else if (chunk_bottom >= maximum_height) {
                map_chunk = .{
                    .content = .empty,
                    .flags = .{},
                };
            } else {
                const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");
                world_chunk_data.* = generateTerrainChunk(&heights, chunk_bottom, params.dirt_depth);

                map_chunk = .{
                    .content = .{ .blocks = world_chunk_data },
                    .flags = WorldChunkData.getMetaFlags(world_chunk_data),
                };
            }

            self.chunks.putAssumeCapacity(encodeChunkPosition(chunk_x, chunk_y, chunk_z), map_chunk);
        }
    }

    fn clearChunks(self: *World) void {
        self.destroyChunksData();
        self.chunks.clearRetainingCapacity();
    }

    fn destroyChunksData(self: *World) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |entry| {
            switch (entry.content) {
                .blocks => |world_chunk_data| self.allocator.destroy(world_chunk_data),
                .empty, .solid => {},
            }
        }
    }
};

fn terrainColumnHeights(
    chunk_x: u30,
    chunk_y: u30,
    seed: u64,
    params: WorldGenerationParams,
) [CHUNK_SIZE][CHUNK_SIZE]u32 {
    const noise = PerlinNoise.init(seed);

    var heights: [CHUNK_SIZE][CHUNK_SIZE]u32 = undefined;
    for (0..CHUNK_SIZE) |local_y| {
        for (0..CHUNK_SIZE) |local_x| {
            const block_x = @as(usize, chunk_x) * CHUNK_SIZE + local_x;
            const block_y = @as(usize, chunk_y) * CHUNK_SIZE + local_y;
            heights[local_y][local_x] = terrainHeight(noise, block_x, block_y, params);
        }
    }

    return heights;
}

fn terrainHeight(noise: PerlinNoise, block_x: anytype, block_y: anytype, params: WorldGenerationParams) u32 {
    var value: f64 = 0.0;
    var amplitude: f64 = 1.0;
    var amplitude_sum: f64 = 0.0;
    var frequency = 1.0 / params.noise_scale;
    const world_width_blocks = WORLD_SIZE[0] * CHUNK_SIZE;
    const world_width: f64 = @floatFromInt(world_width_blocks);

    for (0..params.octaves) |_| {
        // Use a whole number of noise cells around the world's circumference.
        // Wrapping lattice gradients then makes x=world_width meet x=0 with
        // matching values and slopes, regardless of the requested noise scale.
        const x_period: u32 = @intFromFloat(@max(1.0, @round(world_width * frequency)));
        const periodic_x = @as(f64, @floatFromInt(block_x)) *
            @as(f64, @floatFromInt(x_period)) / world_width;

        value += noise.sample2DPeriodicX(
            periodic_x,
            @as(f64, @floatFromInt(block_y)) * frequency,
            x_period,
        ) * amplitude;
        amplitude_sum += amplitude;
        frequency *= params.lacunarity;
        amplitude *= params.persistence;
    }

    const normalized_noise = value / amplitude_sum;
    const generated_height = @as(f64, @floatFromInt(params.base_height)) +
        normalized_noise * params.height_amplitude;
    const world_height: f64 = @floatFromInt(WORLD_SIZE[2] * CHUNK_SIZE);
    const bounded_height = std.math.clamp(@round(generated_height), 1.0, world_height);

    return @intFromFloat(bounded_height);
}

fn generateTerrainChunk(
    heights: *const [CHUNK_SIZE][CHUNK_SIZE]u32,
    chunk_bottom: u32,
    dirt_depth: u8,
) WorldChunkData {
    var chunk = WorldChunkData.initUninitialized();

    for (0..CHUNK_SIZE) |local_z| {
        const block_z = chunk_bottom + local_z;

        for (0..CHUNK_SIZE) |local_y| {
            for (0..CHUNK_SIZE) |local_x| {
                const height = heights[local_y][local_x];
                const depth_below_surface = height -| (block_z + 1);

                chunk.blocks[local_z][local_y][local_x] = if (block_z >= height)
                    BlockType.none
                else if (depth_below_surface == 0)
                    BlockType.grass
                else if (depth_below_surface <= dirt_depth)
                    BlockType.dirt
                else
                    BlockType.stone;
            }
        }
    }

    return chunk;
}

test "getChunk generates only the requested column" {
    var world = World.init(std.testing.allocator, .{ .terrain = .{ .seed = 12345 } });
    defer world.deinit();

    _ = world.getChunk(.{ 3, 7, 0 });
    try std.testing.expectEqual(WORLD_SIZE[2], world.chunks.count());

    _ = world.getChunk(.{ 3, 7, WORLD_SIZE[2] - 1 });
    try std.testing.expectEqual(WORLD_SIZE[2], world.chunks.count());

    _ = world.getChunk(.{ 4, 7, 0 });
    try std.testing.expectEqual(2 * WORLD_SIZE[2], world.chunks.count());
}

test "terrain generation is deterministic and independent of access order" {
    var first = World.init(std.testing.allocator, .{ .terrain = .{ .seed = 12345 } });
    defer first.deinit();
    var second = World.init(std.testing.allocator, .{ .terrain = .{ .seed = 12345 } });
    defer second.deinit();

    _ = second.getChunk(.{ WORLD_SIZE[0] - 1, 0, 0 });
    _ = second.getChunk(.{ 10, 20, 0 });

    for (0..WORLD_SIZE[2]) |z| {
        const coords = [3]u30{ 10, 20, @intCast(z) };
        const a = first.getChunk(coords);
        const b = second.getChunk(coords);

        try std.testing.expectEqual(std.meta.activeTag(a.content), std.meta.activeTag(b.content));
        try std.testing.expectEqual(a.flags, b.flags);
        if (a.content == .blocks) {
            try std.testing.expectEqualSlices(
                u8,
                std.mem.asBytes(&a.content.blocks.blocks),
                std.mem.asBytes(&b.content.blocks.blocks),
            );
        }
    }
}

test "terrain column has a surface chunk between solid and empty chunks" {
    var world = World.init(std.testing.allocator, .{ .terrain = .{ .seed = 12345 } });
    defer world.deinit();

    try std.testing.expect(world.getChunk(.{ 0, 0, 0 }).content == .solid);
    try std.testing.expect(world.getChunk(.{ 0, 0, WORLD_SIZE[2] - 1 }).content == .empty);

    var surface_chunk_count: usize = 0;
    for (0..WORLD_SIZE[2]) |z| {
        if (world.getChunk(.{ 0, 0, @intCast(z) }).content == .blocks) {
            surface_chunk_count += 1;
        }
    }
    try std.testing.expect(surface_chunk_count > 0);
}

test "removing and dropping a block in a column are inverse operations" {
    var world = World.init(std.testing.allocator, .{ .terrain = .{ .seed = 12345 } });
    defer world.deinit();

    const top = [3]u32{ 100, 200, WORLD_SIZE[2] * CHUNK_SIZE - 1 };

    const removed = world.removeTopBlockInColumn(top).?;
    try std.testing.expect(!world.isBlockSolid(removed));
    try std.testing.expect(world.isBlockSolid(.{ removed[0], removed[1], removed[2] - 1 }));

    const chunk_coords, _ = splitBlockCoords(removed);
    try std.testing.expect(world.getChunk(chunk_coords).is_dirty);

    const placed = world.dropBlockInColumn(top, .dirt).?;
    try std.testing.expectEqual(removed, placed);
    try std.testing.expect(world.isBlockSolid(placed));
}

test "editing a solid chunk generates its data from the generator" {
    var world = World.init(std.testing.allocator, .{ .terrain = .{ .seed = 12345 } });
    defer world.deinit();

    try std.testing.expect(world.getChunk(.{ 0, 0, 0 }).content == .solid);

    const removed = world.removeTopBlockInColumn(.{ 5, 5, CHUNK_SIZE - 1 }).?;
    try std.testing.expectEqual([3]u32{ 5, 5, CHUNK_SIZE - 1 }, removed);

    const chunk = world.getChunk(.{ 0, 0, 0 });
    try std.testing.expect(chunk.content == .blocks);
    try std.testing.expect(chunk.is_dirty);
    try std.testing.expect(!chunk.flags.solid_top);
    try std.testing.expect(chunk.flags.solid_bottom);
    try std.testing.expectEqual(BlockType.stone, chunk.content.blocks.blocks[0][0][0]);
}

test "column operations do nothing when there is no room" {
    var world = World.init(std.testing.allocator, .{ .flat = {} });
    defer world.deinit();

    const bottom = [3]u32{ 0, 0, 0 };
    try std.testing.expectEqual(null, world.dropBlockInColumn(bottom, .dirt));
    try std.testing.expectEqual(bottom, world.removeTopBlockInColumn(bottom).?);
    try std.testing.expectEqual(null, world.removeTopBlockInColumn(bottom));
}
