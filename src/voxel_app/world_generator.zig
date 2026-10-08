const ChunkCoords = @import("engine").ChunkCoords;
const std = @import("std");

const BlockType = @import("engine").voxel_chunk.BlockType;
const PerlinNoise = @import("./perlin_noise.zig").PerlinNoise;
const WorldChunkData = @import("./world_chunk_data.zig").WorldChunkData;
const WorldChunk = @import("./world.zig").WorldChunk;
const CHUNK_SIZE = @import("./consts.zig").CHUNK_SIZE;
const WorldLayout = @import("engine").WorldLayout;
const test_layout = @import("test_world.zig").layout;
const WORLD_SIZE = test_layout.size_in_chunks;

pub const WorldGenerationParams = struct {
    /// Width, in blocks, of the first noise octave's features.
    noise_scale: f64 = 192.0,
    /// Number of noise layers. More octaves add smaller terrain details.
    octaves: u8 = 4,
    /// Frequency multiplier applied to each successive octave.
    lacunarity: f64 = 2.0,
    /// Amplitude multiplier applied to each successive octave.
    persistence: f64 = 0.5,
    /// Average terrain height from the bottom; null uses half this world's height.
    base_height: ?u32 = null,
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

    pub const ValidationError = error{
        InvalidGenerationParameters,
        NoiseFrequencyOutOfRange,
        NoisePeriodOutOfRange,
        NoiseCoordinateOutOfRange,
        NoiseAmplitudeOutOfRange,
    };

    /// Validate the layout/settings combination and derive immutable octaves once.
    /// The caller owns the result; the borrowed layout must outlive its columns.
    pub fn prepare(self: WorldGenerator, allocator: std.mem.Allocator, layout: *const WorldLayout) (ValidationError || std.mem.Allocator.Error)!PreparedWorldGenerator {
        return .{
            .layout = layout,
            .kind = switch (self) {
                .flat => .flat,
                .terrain => |terrain| .{ .terrain = try PreparedTerrain.init(allocator, layout, terrain.seed, terrain.params) },
            },
        };
    }
};

pub const PreparedWorldGenerator = struct {
    layout: *const WorldLayout,
    kind: union(enum) {
        flat,
        terrain: PreparedTerrain,
    },

    pub fn deinit(self: *PreparedWorldGenerator, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .flat => {},
            .terrain => |terrain| allocator.free(terrain.octaves),
        }
    }
};

const PreparedTerrain = struct {
    const Octave = struct {
        frequency: f64,
        x_frequency: f64,
        x_period: i64,
        amplitude: f64,
    };

    noise: PerlinNoise,
    size_in_blocks: [3]u32,
    octaves: []const Octave,
    amplitude_sum: f64,
    base_height: f64,
    height_amplitude: f64,
    dirt_depth: u8,

    fn init(allocator: std.mem.Allocator, layout: *const WorldLayout, seed: u64, params: WorldGenerationParams) (WorldGenerator.ValidationError || std.mem.Allocator.Error)!PreparedTerrain {
        if (!(params.noise_scale > 0.0) or !std.math.isFinite(params.noise_scale) or
            params.octaves == 0 or
            !(params.lacunarity > 0.0) or !std.math.isFinite(params.lacunarity) or
            !(params.persistence >= 0.0) or !std.math.isFinite(params.persistence) or
            !(params.height_amplitude >= 0.0) or !std.math.isFinite(params.height_amplitude))
            return error.InvalidGenerationParameters;

        const octaves = try allocator.alloc(Octave, params.octaves);
        errdefer allocator.free(octaves);
        const width: f64 = @floatFromInt(layout.size_in_blocks[0]);
        const last_y: f64 = @floatFromInt(layout.size_in_blocks[1] - 1);
        var frequency = 1.0 / params.noise_scale;
        var amplitude: f64 = 1.0;
        var amplitude_sum: f64 = 0.0;
        for (octaves, 0..) |*octave, index| {
            if (!(frequency > 0.0) or !std.math.isFinite(frequency)) return error.NoiseFrequencyOutOfRange;
            // Use a whole number of lattice cells around the circumference.
            // 2^63 is exactly representable as f64; float(maxInt(i64)) rounds
            // up to it, so the conversion requires a strict upper bound.
            const requested_period = width * frequency;
            if (!std.math.isFinite(requested_period)) return error.NoisePeriodOutOfRange;
            const period = @max(1.0, @round(requested_period));
            if (period >= 0x1p63) return error.NoisePeriodOutOfRange;
            const x_frequency = period / width;
            // Every sampled lattice coordinate and its +1 neighbor must fit i64.
            // The largest f64 below 2^63 leaves more than one integer of headroom.
            if (!validLatticeCoordinate((width - 1.0) * x_frequency) or
                !validLatticeCoordinate(last_y * frequency)) return error.NoiseCoordinateOutOfRange;
            if (!(amplitude >= 0.0) or !std.math.isFinite(amplitude)) return error.NoiseAmplitudeOutOfRange;
            amplitude_sum += amplitude;
            if (!std.math.isFinite(amplitude_sum)) return error.NoiseAmplitudeOutOfRange;
            octave.* = .{
                .frequency = frequency,
                .x_frequency = x_frequency,
                .x_period = @intFromFloat(period),
                .amplitude = amplitude,
            };
            // Do not reject overflow in an unused octave after the last one.
            if (index + 1 < octaves.len) {
                frequency *= params.lacunarity;
                amplitude *= params.persistence;
            }
        }
        return .{
            .noise = PerlinNoise.init(seed),
            .size_in_blocks = layout.size_in_blocks,
            .octaves = octaves,
            .amplitude_sum = amplitude_sum,
            .base_height = @floatFromInt(params.base_height orelse layout.size_in_blocks[2] / 2),
            .height_amplitude = params.height_amplitude,
            .dirt_depth = params.dirt_depth,
        };
    }

    fn validLatticeCoordinate(value: f64) bool {
        return std.math.isFinite(value) and value >= 0.0 and value < 0x1p63;
    }

    fn height(self: *const PreparedTerrain, block_x: anytype, block_y: anytype) u32 {
        std.debug.assert(block_y >= 0 and block_y < self.size_in_blocks[1]);
        // Normalize before sampling, including repeated trips around x. This
        // keeps lattice coordinates within the range checked during preparation.
        // Validated world widths are powers of two, so no division is needed.
        const x: f64 = @floatFromInt(@as(u64, @bitCast(@as(i64, @intCast(block_x)))) & (self.size_in_blocks[0] - 1));
        const y: f64 = @floatFromInt(block_y);
        var value: f64 = 0.0;
        for (self.octaves) |octave| {
            value += self.noise.sample2DPeriodicX(x * octave.x_frequency, y * octave.frequency, octave.x_period) * octave.amplitude;
        }
        const normalized_noise = value / self.amplitude_sum;
        const generated_height = self.base_height + normalized_noise * self.height_amplitude;
        const world_height: f64 = @floatFromInt(self.size_in_blocks[2]);
        return @intFromFloat(std.math.clamp(@round(generated_height), 1.0, world_height));
    }
};

const ColumnHeights = [CHUNK_SIZE][CHUNK_SIZE]u32;

/// Generates chunks of a single column using immutable prepared settings. Construction
/// is safe from any thread; the layout must outlive the column. Terrain heights are
/// computed once in `init`, so generating several vertical chunks reuses that work.
pub const ColumnGenerator = struct {
    layout: *const WorldLayout,
    coords: @Vector(2, i32),
    column: union(enum) {
        flat,
        terrain: TerrainColumn,
    },

    pub fn init(generator: *const PreparedWorldGenerator, coords: @Vector(2, i32)) ColumnGenerator {
        const layout = generator.layout;
        std.debug.assert(coords[0] >= 0 and coords[0] < layout.size_in_chunks[0]);
        std.debug.assert(coords[1] >= 0 and coords[1] < layout.size_in_chunks[1]);

        return .{
            .layout = layout,
            .coords = coords,
            .column = switch (generator.kind) {
                .flat => .flat,
                .terrain => |*terrain| .{ .terrain = .init(layout, coords, terrain) },
            },
        };
    }

    /// The caller owns the block data of the returned chunk.
    pub fn generateChunk(self: *const ColumnGenerator, allocator: std.mem.Allocator, chunk_z: i32) WorldChunk {
        std.debug.assert(chunk_z >= 0 and chunk_z < self.layout.size_in_chunks[2]);

        var chunk = switch (self.column) {
            .flat => generateFlatChunk(self.layout, allocator, chunk_z),
            .terrain => |*terrain| terrain.generateChunk(allocator, chunk_z),
        };
        // Outer y/z faces have no neighboring wall. X is periodic.
        if (self.coords[1] > 0 and self.coords[1] + 1 < self.layout.size_in_chunks[1] and
            chunk_z > 0 and chunk_z + 1 < self.layout.size_in_chunks[2])
        {
            const chunk_top = (@as(u32, @intCast(chunk_z)) + 1) * CHUNK_SIZE;
            chunk.flags.is_unreachable = switch (self.column) {
                .flat => chunk_top < self.layout.size_in_blocks[2] / 2 - CHUNK_SIZE / 2,
                // The block immediately above the chunk must exist, whereas the four
                // horizontal strips need only cover the chunk's last block layer.
                .terrain => |*terrain| chunk_top < terrain.minimum_height and
                    chunk_top <= terrain.minimum_adjacent_height,
            };
        }
        return chunk;
    }
};

fn generateFlatChunk(layout: *const WorldLayout, allocator: std.mem.Allocator, chunk_z: i32) WorldChunk {
    const center_z = @divExact(layout.size_in_chunks[2], 2);

    if (chunk_z + 1 == center_z) {
        return allocateChunk(allocator, WorldChunkData.initFlat());
    }
    if (chunk_z + 2 <= center_z) {
        return allocateChunk(allocator, WorldChunkData.initSolid());
    }
    return WorldChunk.initEmpty();
}

const TerrainColumn = struct {
    heights: ColumnHeights,
    minimum_height: u32,
    maximum_height: u32,
    minimum_adjacent_height: u32,
    dirt_depth: u8,

    fn init(layout: *const WorldLayout, coords: @Vector(2, i32), terrain: *const PreparedTerrain) TerrainColumn {
        const heights = terrainColumnHeights(terrain, coords[0], coords[1]);

        var minimum_height: u32 = layout.size_in_blocks[2];
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
            .minimum_adjacent_height = terrainAdjacentMinimumHeight(layout, coords, terrain),
            .dirt_depth = terrain.dirt_depth,
        };
    }

    fn generateChunk(self: *const TerrainColumn, allocator: std.mem.Allocator, chunk_z: i32) WorldChunk {
        const chunk_bottom = @as(u32, @intCast(chunk_z)) * CHUNK_SIZE;
        const chunk_top = chunk_bottom + CHUNK_SIZE;

        // Entirely above the surface.
        if (chunk_bottom >= self.maximum_height) {
            return WorldChunk.initEmpty();
        }
        // Entirely below the dirt layer.
        if (chunk_top + self.dirt_depth < self.minimum_height) {
            return allocateChunk(allocator, WorldChunkData.initSolid());
        }

        return allocateChunk(allocator, generateTerrainChunk(&self.heights, chunk_bottom, self.dirt_depth));
    }
};

/// One block beyond each horizontal face is enough to certify the neighboring wall.
/// Diagonal corner columns do not touch a face and need not be sampled.
fn terrainAdjacentMinimumHeight(layout: *const WorldLayout, coords: @Vector(2, i32), terrain: *const PreparedTerrain) u32 {
    if (coords[1] == 0 or coords[1] + 1 == layout.size_in_chunks[1]) return 0;
    const x = @as(i64, coords[0]) * CHUNK_SIZE;
    const y = @as(u32, @intCast(coords[1])) * CHUNK_SIZE;
    const left: u32 = @intCast(@mod(x - 1, layout.size_in_blocks[0]));
    const right: u32 = @intCast(@mod(x + CHUNK_SIZE, layout.size_in_blocks[0]));
    var minimum: u32 = layout.size_in_blocks[2];
    for (0..CHUNK_SIZE) |offset| {
        const dx = @as(u32, @intCast(x)) + @as(u32, @intCast(offset));
        const dy = y + @as(u32, @intCast(offset));
        minimum = @min(minimum, terrain.height(left, dy));
        minimum = @min(minimum, terrain.height(right, dy));
        minimum = @min(minimum, terrain.height(dx, y - 1));
        minimum = @min(minimum, terrain.height(dx, y + CHUNK_SIZE));
    }
    return minimum;
}

fn allocateChunk(allocator: std.mem.Allocator, data: WorldChunkData) WorldChunk {
    const world_chunk_data = allocator.create(WorldChunkData) catch @panic("OOM");
    world_chunk_data.* = data;
    return WorldChunk.initBlocks(world_chunk_data);
}

fn terrainColumnHeights(
    terrain: *const PreparedTerrain,
    chunk_x: i32,
    chunk_y: i32,
) ColumnHeights {
    var heights: ColumnHeights = undefined;
    for (0..CHUNK_SIZE) |local_y| {
        for (0..CHUNK_SIZE) |local_x| {
            const block_x = @as(usize, @intCast(chunk_x)) * CHUNK_SIZE + local_x;
            const block_y = @as(usize, @intCast(chunk_y)) * CHUNK_SIZE + local_y;
            heights[local_y][local_x] = terrain.height(block_x, block_y);
        }
    }

    return heights;
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
    var prepared = try generator.prepare(std.testing.allocator, &test_layout);
    defer prepared.deinit(std.testing.allocator);
    const first = ColumnGenerator.init(&prepared, .{ 10, 20 });
    const second = ColumnGenerator.init(&prepared, .{ 10, 20 });

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
    var prepared = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 12345 } }, std.testing.allocator, &test_layout);
    defer prepared.deinit(std.testing.allocator);
    const column_generator = ColumnGenerator.init(&prepared, .{ 0, 0 });

    const bottom = column_generator.generateChunk(std.testing.allocator, 0);
    defer bottom.content.deinit(std.testing.allocator);
    try std.testing.expect(bottom.content == .blocks);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&WorldChunkData.initSolid().blocks),
        std.mem.asBytes(&bottom.content.blocks.blocks),
    );
    try std.testing.expectEqual(WorldChunkData.initSolid().getMetaFlags(), bottom.flags);

    const top = column_generator.generateChunk(std.testing.allocator, WORLD_SIZE[2] - 1);
    try std.testing.expectEqual(WorldChunk.initEmpty(), top);

    var surface_chunk_count: usize = 0;
    for (0..WORLD_SIZE[2]) |z| {
        var chunk = column_generator.generateChunk(std.testing.allocator, @intCast(z));
        defer chunk.content.deinit(std.testing.allocator);
        const data = chunk.content.toData();
        if (std.mem.indexOfScalar(BlockType, asFlatBlocks(&data), .grass) != null) {
            surface_chunk_count += 1;
        }
    }
    try std.testing.expect(surface_chunk_count > 0);
}

fn asFlatBlocks(data: *const WorldChunkData) []const BlockType {
    return @as(*const [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]BlockType, @ptrCast(&data.blocks));
}

test "flat world has the surface chunk in the middle, stone below and air above" {
    var prepared = try WorldGenerator.prepare(.flat, std.testing.allocator, &test_layout);
    defer prepared.deinit(std.testing.allocator);
    const column_generator = ColumnGenerator.init(&prepared, .{ WORLD_SIZE[0] - 1, WORLD_SIZE[1] - 1 });
    const surface_z = WORLD_SIZE[2] / 2 - 1;

    for (0..WORLD_SIZE[2]) |z| {
        var chunk = column_generator.generateChunk(std.testing.allocator, @intCast(z));
        defer chunk.content.deinit(std.testing.allocator);

        if (z == surface_z) {
            try std.testing.expect(chunk.content == .blocks);
            try std.testing.expectEqualSlices(
                u8,
                std.mem.asBytes(&WorldChunkData.initFlat().blocks),
                std.mem.asBytes(&chunk.content.blocks.blocks),
            );
        } else if (z < surface_z) {
            try std.testing.expect(chunk.content == .blocks);
            try std.testing.expectEqualSlices(
                u8,
                std.mem.asBytes(&WorldChunkData.initSolid().blocks),
                std.mem.asBytes(&chunk.content.blocks.blocks),
            );
        } else {
            try std.testing.expectEqual(WorldChunk.initEmpty(), chunk);
        }
    }
}

test "shortcut terrain chunks match the full generation, only chunks without blocks are empty" {
    const params = WorldGenerationParams{};
    const coords = @Vector(2, i32){ 7, 3 };
    var prepared = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 12345, .params = params } }, std.testing.allocator, &test_layout);
    defer prepared.deinit(std.testing.allocator);
    const column_generator = ColumnGenerator.init(&prepared, coords);
    const heights = terrainColumnHeights(&prepared.kind.terrain, coords[0], coords[1]);

    for (0..WORLD_SIZE[2]) |z| {
        var chunk = column_generator.generateChunk(std.testing.allocator, @intCast(z));
        defer chunk.content.deinit(std.testing.allocator);

        const expected = generateTerrainChunk(&heights, @intCast(z * CHUNK_SIZE), params.dirt_depth);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&expected.blocks),
            std.mem.asBytes(&chunk.content.toData().blocks),
        );
        // Reachability comes from neighboring columns, not this chunk's block contents.
        for (std.enums.values(@import("engine").voxel_chunk.Side)) |side| {
            try std.testing.expectEqual(expected.getMetaFlags().getSideSolidness(side), chunk.flags.getSideSolidness(side));
        }
        try std.testing.expectEqual(expected.countSolidBlocks(), chunk.solid_block_count);

        const has_blocks = std.mem.indexOfNone(BlockType, asFlatBlocks(&expected), &.{.none}) != null;
        try std.testing.expectEqual(!has_blocks, chunk.content == .empty);
    }
}

test "unreachable terrain requires a solid ceiling and one-block horizontal walls" {
    const top = 3 * CHUNK_SIZE;
    var column = ColumnGenerator{
        .layout = &test_layout,
        .coords = .{ 1, 1 },
        .column = .{ .terrain = .{
            .heights = @splat(@splat(top + 1)),
            .minimum_height = top + 1,
            .maximum_height = top + 1,
            .minimum_adjacent_height = top,
            .dirt_depth = 4,
        } },
    };
    var chunk = column.generateChunk(std.testing.allocator, 2);
    defer chunk.content.deinit(std.testing.allocator);
    try std.testing.expect(chunk.flags.is_unreachable);
    // This takes the layered generation path, rather than the all-stone shortcut.
    try std.testing.expectEqual(BlockType.dirt, chunk.content.getBlock(.{ 0, 0, CHUNK_SIZE - 1 }));

    column.column.terrain.minimum_adjacent_height = top - 1;
    const cliff_chunk = column.generateChunk(std.testing.allocator, 2);
    defer cliff_chunk.content.deinit(std.testing.allocator);
    try std.testing.expect(!cliff_chunk.flags.is_unreachable);

    column.column.terrain.minimum_adjacent_height = top;
    column.column.terrain.heights = @splat(@splat(top));
    column.column.terrain.minimum_height = top;
    column.column.terrain.maximum_height = top;
    const surface_chunk = column.generateChunk(std.testing.allocator, 2);
    defer surface_chunk.content.deinit(std.testing.allocator);
    try std.testing.expect(!surface_chunk.flags.is_unreachable);
}

test "generated unreachable flags agree with all six actual neighboring walls" {
    const world = @import("./world.zig");
    const generators = [_]WorldGenerator{
        .flat,
        .{ .terrain = .{ .seed = 12345 } },
        .{ .terrain = .{ .seed = 87, .params = .{ .noise_scale = 24, .height_amplitude = 96 } } },
    };
    const columns = [_]@Vector(2, i32){
        .{ 0, 1 }, .{ WORLD_SIZE[0] - 1, 1 }, .{ 7, 3 }, .{ 5, 0 }, .{ 5, WORLD_SIZE[1] - 1 },
    };
    var unreachable_count: usize = 0;
    for (generators) |generator| {
        var prepared = try generator.prepare(std.testing.allocator, &test_layout);
        defer prepared.deinit(std.testing.allocator);
        for (columns) |coords| {
            const column = ColumnGenerator.init(&prepared, coords);
            for (0..WORLD_SIZE[2]) |z| {
                const chunk_coords = ChunkCoords{ coords[0], coords[1], @intCast(z) };
                const chunk = column.generateChunk(std.testing.allocator, @intCast(z));
                defer chunk.content.deinit(std.testing.allocator);
                var enclosed = true;
                for (std.enums.values(@import("engine").voxel_chunk.Side)) |side| {
                    const neighbor_coords = world.adjacentChunk(&test_layout, chunk_coords, side) orelse {
                        enclosed = false;
                        break;
                    };
                    const neighbor_column = ColumnGenerator.init(&prepared, .{ neighbor_coords[0], neighbor_coords[1] });
                    const neighbor = neighbor_column.generateChunk(std.testing.allocator, neighbor_coords[2]);
                    defer neighbor.content.deinit(std.testing.allocator);
                    if (!neighbor.flags.getSideSolidness(side.getOpposite())) enclosed = false;
                }
                try std.testing.expectEqual(enclosed, chunk.flags.is_unreachable);
                if (chunk.flags.is_unreachable) unreachable_count += 1;
            }
        }
    }
    try std.testing.expect(unreachable_count > 0);
}

test "terrain midpoint, height bounds, and periodic x use each world's dimensions" {
    for ([_][3]u32{ .{ 128, 64, 16 }, .{ 256, 128, 4 } }) |size| {
        const layout = try WorldLayout.init(.{ .size_in_chunks = size });
        const params = WorldGenerationParams{ .height_amplitude = 0 };
        var midpoint = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 12345, .params = params } }, std.testing.allocator, &layout);
        defer midpoint.deinit(std.testing.allocator);
        try std.testing.expectEqual(layout.size_in_blocks[2] / 2, midpoint.kind.terrain.height(0, 0));
        const top_params = WorldGenerationParams{ .base_height = std.math.maxInt(u32), .height_amplitude = 0 };
        var top = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 12345, .params = top_params } }, std.testing.allocator, &layout);
        defer top.deinit(std.testing.allocator);
        try std.testing.expectEqual(layout.size_in_blocks[2], top.kind.terrain.height(0, 0));
        var terrain = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 12345 } }, std.testing.allocator, &layout);
        defer terrain.deinit(std.testing.allocator);
        for ([_]u32{ 0, 1, 31, 100, size[0] * CHUNK_SIZE - 1 }) |x| {
            try std.testing.expectEqual(terrain.kind.terrain.height(x, 53), terrain.kind.terrain.height(x + layout.size_in_blocks[0], 53));
        }
        var flat = try WorldGenerator.prepare(.flat, std.testing.allocator, &layout);
        defer flat.deinit(std.testing.allocator);
        const column = ColumnGenerator.init(&flat, .{ layout.size_in_chunks[0] - 1, layout.size_in_chunks[1] - 1 });
        const surface_z = @divExact(layout.size_in_chunks[2], 2) - 1;
        const surface = column.generateChunk(std.testing.allocator, surface_z);
        defer surface.content.deinit(std.testing.allocator);
        try std.testing.expectEqual(BlockType.stone, surface.content.getBlock(.{ 16, 16, 15 }));
        const above = column.generateChunk(std.testing.allocator, surface_z + 1);
        defer above.content.deinit(std.testing.allocator);
        try std.testing.expect(above.content == .empty);
        try std.testing.expect(!surface.flags.is_unreachable);
        try std.testing.expectEqual(ChunkCoords{ 0, 1, 1 }, @import("world.zig").adjacentChunk(&layout, .{ layout.size_in_chunks[0] - 1, 1, 1 }, .right).?);
    }
}

test "prepared terrain preserves default and custom generation from before octave preparation" {
    const fixtures = .{
        .{ WorldGenerator{ .terrain = .{ .seed = 12345 } }, "eaee1ddf7cdeed2c0f56ecfed35f4794c191c8bb3f464fb52f606fd704bf81dc" },
        .{ WorldGenerator{ .terrain = .{ .seed = 87, .params = .{ .noise_scale = 24, .height_amplitude = 96, .lacunarity = 1.7, .persistence = 0.7 } } }, "9c428baaf43b97bb40465fb93a48aa3b35ac49ab7dee8019fc403459137b3709" },
    };
    // Snapshots from PR head 927c7ec: four columns including both x seam sides
    // and a y boundary, with heights and enclosure bounds encoded little-endian.
    inline for (fixtures) |fixture| {
        var prepared = try fixture[0].prepare(std.testing.allocator, &test_layout);
        defer prepared.deinit(std.testing.allocator);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_]@Vector(2, i32){ .{ 0, 1 }, .{ 511, 1 }, .{ 7, 3 }, .{ 5, 255 } }) |coords| {
            const column = ColumnGenerator.init(&prepared, coords);
            var bytes: [4]u8 = undefined;
            for (column.column.terrain.heights) |row| for (row) |height| {
                std.mem.writeInt(u32, &bytes, height, .little);
                hash.update(&bytes);
            };
            for ([_]u32{ column.column.terrain.minimum_height, column.column.terrain.maximum_height, column.column.terrain.minimum_adjacent_height }) |height| {
                std.mem.writeInt(u32, &bytes, height, .little);
                hash.update(&bytes);
            }
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        try std.testing.expectEqualStrings(fixture[1], &std.fmt.bytesToHex(digest, .lower));
    }
}

test "large worlds prepare periods beyond u32 and generate both seam columns" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 1 << 26, 2, 2 } });
    var prepared = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 12345, .params = .{ .noise_scale = 4 } } }, std.testing.allocator, &layout);
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1) << 32, prepared.kind.terrain.octaves[3].x_period);
    for ([_]i32{ 0, layout.size_in_chunks[0] - 1 }) |x| {
        const column = ColumnGenerator.init(&prepared, .{ x, 1 });
        for (column.column.terrain.heights) |row| for (row) |height| {
            try std.testing.expect(height >= 1 and height <= layout.size_in_blocks[2]);
        };
        for (0..2) |z| {
            const chunk = column.generateChunk(std.testing.allocator, @intCast(z));
            defer chunk.content.deinit(std.testing.allocator);
        }
    }
    try std.testing.expectEqual(prepared.kind.terrain.height(-1, 63), prepared.kind.terrain.height(layout.size_in_blocks[0] - 1, 63));
    try std.testing.expectEqual(prepared.kind.terrain.height(1, 63), prepared.kind.terrain.height(@as(i64, layout.size_in_blocks[0]) * 100 + 1, 63));
}

test "preparation returns errors for invalid inputs and derived numerical limits" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    for ([_]WorldGenerationParams{
        .{ .noise_scale = 0 },
        .{ .noise_scale = -1 },
        .{ .noise_scale = std.math.nan(f64) },
        .{ .noise_scale = std.math.inf(f64) },
        .{ .octaves = 0 },
        .{ .lacunarity = 0 },
        .{ .lacunarity = std.math.inf(f64) },
        .{ .lacunarity = std.math.nan(f64) },
        .{ .persistence = -1 },
        .{ .persistence = std.math.inf(f64) },
        .{ .persistence = std.math.nan(f64) },
        .{ .height_amplitude = -1 },
        .{ .height_amplitude = std.math.inf(f64) },
        .{ .height_amplitude = std.math.nan(f64) },
    }) |params| {
        try std.testing.expectError(error.InvalidGenerationParameters, WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = params } }, std.testing.allocator, &layout));
    }
    for ([_]WorldGenerationParams{
        .{ .noise_scale = @as(f64, @bitCast(@as(u64, 1))) },
        .{ .noise_scale = 0.5, .lacunarity = std.math.floatMax(f64), .octaves = 2 },
        .{ .noise_scale = std.math.floatMax(f64), .lacunarity = 0x1p-1022, .octaves = 2 },
    }) |params| {
        try std.testing.expectError(error.NoiseFrequencyOutOfRange, WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = params } }, std.testing.allocator, &layout));
    }
    for ([_]WorldGenerationParams{
        .{ .noise_scale = 0x1p-57, .octaves = 1 }, // period = 2^63
        .{ .noise_scale = 0x1p-1022, .octaves = 1 }, // width * frequency = infinity
    }) |params| {
        try std.testing.expectError(error.NoisePeriodOutOfRange, WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = params } }, std.testing.allocator, &layout));
    }
    for ([_]WorldGenerationParams{
        .{ .persistence = 1e308, .octaves = 3 },
        .{ .persistence = std.math.pow(f64, 2.0, 1023.98 / 254.0), .octaves = 255, .lacunarity = 1 }, // finite amplitudes, overflowing sum
    }) |params| {
        try std.testing.expectError(error.NoiseAmplitudeOutOfRange, WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = params } }, std.testing.allocator, &layout));
    }

    const tall = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 1 << 26, 2 } });
    try std.testing.expectError(error.NoiseCoordinateOutOfRange, WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = .{ .noise_scale = 0x1p-33, .octaves = 1 } } }, std.testing.allocator, &tall));
    var near_y_limit = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = .{ .noise_scale = 0x1p-32, .octaves = 1 } } }, std.testing.allocator, &tall);
    defer near_y_limit.deinit(std.testing.allocator);
    const edge = ColumnGenerator.init(&near_y_limit, .{ 1, tall.size_in_chunks[1] - 1 });
    try std.testing.expect(edge.column.terrain.minimum_height >= 1);
}

test "preparation validates only used octaves and supports zero persistence" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    var single = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = .{
        .noise_scale = 0.5,
        .octaves = 1,
        .lacunarity = std.math.floatMax(f64),
        .persistence = std.math.floatMax(f64),
    } } }, std.testing.allocator, &layout);
    defer single.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 1), single.kind.terrain.amplitude_sum);
    var zero = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = .{ .persistence = 0 } } }, std.testing.allocator, &layout);
    defer zero.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 1), zero.kind.terrain.amplitude_sum);
    try std.testing.expectEqual(@as(f64, 0), zero.kind.terrain.octaves[3].amplitude);

    var large_period = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = .{ .noise_scale = 0x1p-56, .octaves = 1 } } }, std.testing.allocator, &layout);
    defer large_period.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1) << 62, large_period.kind.terrain.octaves[0].x_period);
    _ = ColumnGenerator.init(&large_period, .{ 1, 1 });
    var near_period_limit = try WorldGenerator.prepare(.{ .terrain = .{ .seed = 1, .params = .{ .noise_scale = 0x1.0000000000001p-57, .octaves = 1 } } }, std.testing.allocator, &layout);
    defer near_period_limit.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.math.maxInt(i64) - 2047, near_period_limit.kind.terrain.octaves[0].x_period);
    _ = ColumnGenerator.init(&near_period_limit, .{ 1, 1 });
}
