const std = @import("std");

const BlockType = @import("engine").voxel_chunk.BlockType;
const PerlinNoise = @import("./perlin_noise.zig").PerlinNoise;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const WorldChunk = @import("./world.zig").WorldChunk;
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

pub const WorldGenerator = union(enum) {
    flat,
    terrain: struct {
        seed: u64,
        params: WorldGenerationParams = .{},
    },

    pub fn validate(self: WorldGenerator) void {
        switch (self) {
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
    }
};

const ColumnHeights = [CHUNK_SIZE][CHUNK_SIZE]u32;

/// Generates chunks of a single column. Doesn't depend on any shared state, so it's safe to use
/// from any thread. The column-wide part of the work (terrain heights) is done once in `init`,
/// so it's cheaper to generate several chunks of the same column with one generator.
pub const ColumnGenerator = struct {
    column: union(enum) {
        flat,
        terrain: TerrainColumn,
    },

    pub fn init(generator: WorldGenerator, coords: [2]u30) ColumnGenerator {
        std.debug.assert(coords[0] < WORLD_SIZE[0]);
        std.debug.assert(coords[1] < WORLD_SIZE[1]);

        return .{
            .column = switch (generator) {
                .flat => .flat,
                .terrain => |terrain| .{ .terrain = .init(coords, terrain.seed, terrain.params) },
            },
        };
    }

    /// The caller owns the block data of the returned chunk.
    pub fn generateChunk(self: *const ColumnGenerator, allocator: std.mem.Allocator, chunk_z: u30) WorldChunk {
        std.debug.assert(chunk_z < WORLD_SIZE[2]);

        return switch (self.column) {
            .flat => generateFlatChunk(allocator, chunk_z),
            .terrain => |*terrain| terrain.generateChunk(allocator, chunk_z),
        };
    }
};

fn generateFlatChunk(allocator: std.mem.Allocator, chunk_z: u30) WorldChunk {
    const center_z = WORLD_SIZE[2] / 2;

    if (chunk_z + 1 == center_z) {
        return allocateChunk(allocator, WorldChunkData.initFlat());
    }
    if (chunk_z + 2 <= center_z) {
        return WorldChunk.initUniform(.stone);
    }
    return WorldChunk.initUniform(.none);
}

const TerrainColumn = struct {
    heights: ColumnHeights,
    minimum_height: u32,
    maximum_height: u32,
    dirt_depth: u8,

    fn init(coords: [2]u30, seed: u64, params: WorldGenerationParams) TerrainColumn {
        const heights = terrainColumnHeights(coords[0], coords[1], seed, params);

        var minimum_height: u32 = WORLD_SIZE[2] * CHUNK_SIZE;
        var maximum_height: u32 = 0;
        for (heights) |row| {
            for (row) |height| {
                minimum_height = @min(minimum_height, height);
                maximum_height = @max(maximum_height, height);
            }
        }

        return .{
            .heights = heights,
            .minimum_height = minimum_height,
            .maximum_height = maximum_height,
            .dirt_depth = params.dirt_depth,
        };
    }

    fn generateChunk(self: *const TerrainColumn, allocator: std.mem.Allocator, chunk_z: u30) WorldChunk {
        const chunk_bottom = @as(u32, chunk_z) * CHUNK_SIZE;
        const chunk_top = chunk_bottom + CHUNK_SIZE;

        // Entirely above the surface.
        if (chunk_bottom >= self.maximum_height) {
            return WorldChunk.initUniform(.none);
        }
        // Entirely below the dirt layer.
        if (chunk_top + self.dirt_depth < self.minimum_height) {
            return WorldChunk.initUniform(.stone);
        }

        return allocateChunk(allocator, generateTerrainChunk(&self.heights, chunk_bottom, self.dirt_depth));
    }
};

fn allocateChunk(allocator: std.mem.Allocator, data: WorldChunkData) WorldChunk {
    const world_chunk_data = allocator.create(WorldChunkData) catch @panic("OOM");
    world_chunk_data.* = data;
    return WorldChunk.initBlocks(world_chunk_data);
}

fn terrainColumnHeights(
    chunk_x: u30,
    chunk_y: u30,
    seed: u64,
    params: WorldGenerationParams,
) ColumnHeights {
    const noise = PerlinNoise.init(seed);

    var heights: ColumnHeights = undefined;
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
    heights: *const ColumnHeights,
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

test "terrain generation is deterministic" {
    const generator = WorldGenerator{ .terrain = .{ .seed = 12345 } };
    const first = ColumnGenerator.init(generator, .{ 10, 20 });
    const second = ColumnGenerator.init(generator, .{ 10, 20 });

    for (0..WORLD_SIZE[2]) |z| {
        var a = first.generateChunk(std.testing.allocator, @intCast(z));
        defer a.content.deinit(std.testing.allocator);
        var b = second.generateChunk(std.testing.allocator, @intCast(z));
        defer b.content.deinit(std.testing.allocator);

        try std.testing.expectEqual(a.flags, b.flags);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&a.content.toData().blocks),
            std.mem.asBytes(&b.content.toData().blocks),
        );
    }
}

test "terrain column has surface chunks between stone and air" {
    const column_generator = ColumnGenerator.init(.{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 });

    const bottom = column_generator.generateChunk(std.testing.allocator, 0);
    try std.testing.expectEqual(WorldChunk.initUniform(.stone), bottom);
    const top = column_generator.generateChunk(std.testing.allocator, WORLD_SIZE[2] - 1);
    try std.testing.expectEqual(WorldChunk.initUniform(.none), top);

    var surface_chunk_count: usize = 0;
    for (0..WORLD_SIZE[2]) |z| {
        var chunk = column_generator.generateChunk(std.testing.allocator, @intCast(z));
        defer chunk.content.deinit(std.testing.allocator);
        if (chunk.content == .blocks) {
            surface_chunk_count += 1;
        }
    }
    try std.testing.expect(surface_chunk_count > 0);
}

test "uniform terrain chunks match the full generation" {
    const params = WorldGenerationParams{};
    const coords = [2]u30{ 7, 3 };
    const column_generator = ColumnGenerator.init(.{ .terrain = .{ .seed = 12345, .params = params } }, coords);
    const heights = terrainColumnHeights(coords[0], coords[1], 12345, params);

    for (0..WORLD_SIZE[2]) |z| {
        var chunk = column_generator.generateChunk(std.testing.allocator, @intCast(z));
        defer chunk.content.deinit(std.testing.allocator);

        const expected = generateTerrainChunk(&heights, @intCast(z * CHUNK_SIZE), params.dirt_depth);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&expected.blocks),
            std.mem.asBytes(&chunk.content.toData().blocks),
        );
    }
}
