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

pub fn normalizeChunkPosition(x: anytype, y: anytype, z: anytype) [3]u32 {
    var normalized_x = x;
    var normalized_y = y;
    var normalized_z = z;

    if (x >= WORLD_SIZE[0]) {
        normalized_x = x - WORLD_SIZE[0];
    } else if (x < 0) {
        normalized_x = x + WORLD_SIZE[0];
    }
    if (y >= WORLD_SIZE[1]) {
        normalized_y = y - WORLD_SIZE[1];
    } else if (y < 0) {
        normalized_y = y + WORLD_SIZE[1];
    }
    if (z >= WORLD_SIZE[2]) {
        normalized_z = z - WORLD_SIZE[2];
    } else if (z < 0) {
        normalized_z = z + WORLD_SIZE[2];
    }

    return .{
        @intCast(normalized_x),
        @intCast(normalized_y),
        @intCast(normalized_z),
    };
}

pub fn encodeChunkPosition(x: anytype, y: anytype, z: anytype) ChunkPosition {
    return @as(ChunkPosition, @intCast(x)) | @as(ChunkPosition, @intCast(y)) << 12 | @as(ChunkPosition, @intCast(z)) << 20;
}

pub fn encodeChunkPositionArray(coords: anytype) ChunkPosition {
    return encodeChunkPosition(coords[0], coords[1], coords[2]);
}

pub fn decodeChunkPosition(position: ChunkPosition) [3]u32 {
    return .{
        @as(u32, @intCast(position & 0xfff)), //      first 12 bit
        @as(u32, @intCast(position >> 12 & 0xff)), // then 8 bit
        @as(u32, @intCast(position >> 20)), //        and rest (3/4 bit)
    };
}

const WorldChunkState = enum(u8) {
    empty,
    semi_solid,
    solid_loaded,
    solid_unloaded,
};

pub const WorldChunk = struct {
    state: WorldChunkState,
    flags: ChunkFlags,
    world_chunk_data: ?*WorldChunkData,
};

pub const ChunksHashMap = std.AutoHashMapUnmanaged(ChunkPosition, WorldChunk);

pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: ChunksHashMap,

    pub fn init(allocator: std.mem.Allocator) World {
        return World{
            .allocator = allocator,
            .chunks = .empty,
        };
    }

    pub fn deinit(self: *World) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.world_chunk_data) |world_chunk_data| {
                self.allocator.destroy(world_chunk_data);
            }
        }

        self.chunks.deinit(self.allocator);
    }

    pub fn initFlatWorld(self: *World) void {
        const center_z = WORLD_SIZE[2] / 2;

        for (0..WORLD_SIZE[2]) |z| {
            for (0..WORLD_SIZE[1]) |y| {
                for (0..WORLD_SIZE[0]) |x| {
                    var map_chunk: WorldChunk = undefined;

                    if (z == center_z - 1) {
                        const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");

                        world_chunk_data.* = WorldChunkData.initFlat();

                        map_chunk = .{
                            .state = .semi_solid,
                            .flags = WorldChunkData.getMetaFlags(world_chunk_data),
                            .world_chunk_data = world_chunk_data,
                        };
                    } else if (z == center_z - 2) {
                        // const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");
                        // world_chunk_data.* = WorldChunkData.initSolid();

                        map_chunk = .{
                            .state = .solid_unloaded,
                            // .world_chunk_data = world_chunk_data,
                            .flags = solid_chunk_flags,
                            .world_chunk_data = null,
                        };
                    } else if (z < center_z - 2) {
                        map_chunk = .{
                            .state = .solid_unloaded,
                            .flags = solid_chunk_flags,
                            .world_chunk_data = null,
                        };
                    } else {
                        map_chunk = .{
                            .state = .empty,
                            .flags = .{},
                            .world_chunk_data = null,
                        };
                    }

                    self.chunks.put(self.allocator, encodeChunkPosition(x, y, z), map_chunk) catch @panic("OOM");
                }
            }
        }
    }

    pub fn generateWorld(self: *World, seed: u64, params: WorldGenerationParams) void {
        std.debug.assert(params.noise_scale > 0.0 and std.math.isFinite(params.noise_scale));
        std.debug.assert(params.octaves > 0);
        std.debug.assert(params.lacunarity > 0.0 and std.math.isFinite(params.lacunarity));
        std.debug.assert(params.persistence >= 0.0 and std.math.isFinite(params.persistence));
        std.debug.assert(params.height_amplitude >= 0.0 and std.math.isFinite(params.height_amplitude));

        const noise = PerlinNoise.init(seed);

        for (0..WORLD_SIZE[1]) |chunk_y| {
            for (0..WORLD_SIZE[0]) |chunk_x| {
                var heights: [CHUNK_SIZE][CHUNK_SIZE]u32 = undefined;
                var minimum_height: u32 = WORLD_SIZE[2] * CHUNK_SIZE;
                var maximum_height: u32 = 0;

                for (0..CHUNK_SIZE) |local_y| {
                    for (0..CHUNK_SIZE) |local_x| {
                        const block_x = chunk_x * CHUNK_SIZE + local_x;
                        const block_y = chunk_y * CHUNK_SIZE + local_y;
                        const height = terrainHeight(noise, block_x, block_y, params);

                        heights[local_y][local_x] = height;
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
                            .state = .solid_unloaded,
                            .flags = solid_chunk_flags,
                            .world_chunk_data = null,
                        };
                    } else if (chunk_bottom >= maximum_height) {
                        map_chunk = .{
                            .state = .empty,
                            .flags = .{},
                            .world_chunk_data = null,
                        };
                    } else {
                        const world_chunk_data = self.allocator.create(WorldChunkData) catch @panic("OOM");
                        world_chunk_data.* = generateTerrainChunk(&heights, chunk_bottom, params.dirt_depth);

                        map_chunk = .{
                            .state = .semi_solid,
                            .flags = WorldChunkData.getMetaFlags(world_chunk_data),
                            .world_chunk_data = world_chunk_data,
                        };
                    }

                    self.chunks.put(
                        self.allocator,
                        encodeChunkPosition(chunk_x, chunk_y, chunk_z),
                        map_chunk,
                    ) catch @panic("OOM");
                }
            }
        }
    }

    fn clearChunks(self: *World) void {
        var iterator = self.chunks.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.world_chunk_data) |world_chunk_data| {
                self.allocator.destroy(world_chunk_data);
            }
        }
        self.chunks.clearRetainingCapacity();
    }
};

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
