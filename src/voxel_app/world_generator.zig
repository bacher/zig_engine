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
/// from any thread. The immutable layout must outlive the column. Terrain heights are
/// computed once in `init`, so generating several vertical chunks reuses that work.
pub const ColumnGenerator = struct {
    layout: *const WorldLayout,
    coords: @Vector(2, i32),
    column: union(enum) {
        flat,
        terrain: TerrainColumn,
    },

    pub fn init(layout: *const WorldLayout, generator: WorldGenerator, coords: @Vector(2, i32)) ColumnGenerator {
        std.debug.assert(layout.wrap_x);
        std.debug.assert(coords[0] >= 0 and coords[0] < layout.size_in_chunks[0]);
        std.debug.assert(coords[1] >= 0 and coords[1] < layout.size_in_chunks[1]);

        return .{
            .layout = layout,
            .coords = coords,
            .column = switch (generator) {
                .flat => .flat,
                .terrain => |terrain| .{ .terrain = .init(layout, coords, terrain.seed, terrain.params) },
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

    fn init(layout: *const WorldLayout, coords: @Vector(2, i32), seed: u64, params: WorldGenerationParams) TerrainColumn {
        const heights = terrainColumnHeights(layout, coords[0], coords[1], seed, params);

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
            .minimum_adjacent_height = terrainAdjacentMinimumHeight(layout, coords, seed, params),
            .dirt_depth = params.dirt_depth,
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
fn terrainAdjacentMinimumHeight(layout: *const WorldLayout, coords: @Vector(2, i32), seed: u64, params: WorldGenerationParams) u32 {
    if (coords[1] == 0 or coords[1] + 1 == layout.size_in_chunks[1]) return 0;
    const noise = PerlinNoise.init(seed);
    const x = @as(i64, coords[0]) * CHUNK_SIZE;
    const y = @as(u32, @intCast(coords[1])) * CHUNK_SIZE;
    const left: u32 = @intCast(@mod(x - 1, layout.size_in_blocks[0]));
    const right: u32 = @intCast(@mod(x + CHUNK_SIZE, layout.size_in_blocks[0]));
    var minimum: u32 = layout.size_in_blocks[2];
    for (0..CHUNK_SIZE) |offset| {
        const dx = @as(u32, @intCast(x)) + @as(u32, @intCast(offset));
        const dy = y + @as(u32, @intCast(offset));
        minimum = @min(minimum, terrainHeight(layout, noise, left, dy, params));
        minimum = @min(minimum, terrainHeight(layout, noise, right, dy, params));
        minimum = @min(minimum, terrainHeight(layout, noise, dx, y - 1, params));
        minimum = @min(minimum, terrainHeight(layout, noise, dx, y + CHUNK_SIZE, params));
    }
    return minimum;
}

fn allocateChunk(allocator: std.mem.Allocator, data: WorldChunkData) WorldChunk {
    const world_chunk_data = allocator.create(WorldChunkData) catch @panic("OOM");
    world_chunk_data.* = data;
    return WorldChunk.initBlocks(world_chunk_data);
}

fn terrainColumnHeights(
    layout: *const WorldLayout,
    chunk_x: i32,
    chunk_y: i32,
    seed: u64,
    params: WorldGenerationParams,
) ColumnHeights {
    const noise = PerlinNoise.init(seed);

    var heights: ColumnHeights = undefined;
    for (0..CHUNK_SIZE) |local_y| {
        for (0..CHUNK_SIZE) |local_x| {
            const block_x = @as(usize, @intCast(chunk_x)) * CHUNK_SIZE + local_x;
            const block_y = @as(usize, @intCast(chunk_y)) * CHUNK_SIZE + local_y;
            heights[local_y][local_x] = terrainHeight(layout, noise, block_x, block_y, params);
        }
    }

    return heights;
}

fn terrainHeight(layout: *const WorldLayout, noise: PerlinNoise, block_x: anytype, block_y: anytype, params: WorldGenerationParams) u32 {
    var value: f64 = 0.0;
    var amplitude: f64 = 1.0;
    var amplitude_sum: f64 = 0.0;
    var frequency = 1.0 / params.noise_scale;
    const world_width_blocks = layout.size_in_blocks[0];
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
    const generated_height = @as(f64, @floatFromInt(params.base_height orelse layout.size_in_blocks[2] / 2)) +
        normalized_noise * params.height_amplitude;
    const world_height: f64 = @floatFromInt(layout.size_in_blocks[2]);
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
    const first = ColumnGenerator.init(&test_layout, generator, .{ 10, 20 });
    const second = ColumnGenerator.init(&test_layout, generator, .{ 10, 20 });

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
    const column_generator = ColumnGenerator.init(&test_layout, .{ .terrain = .{ .seed = 12345 } }, .{ 0, 0 });

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
    const column_generator = ColumnGenerator.init(&test_layout, .flat, .{ WORLD_SIZE[0] - 1, WORLD_SIZE[1] - 1 });
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
    const column_generator = ColumnGenerator.init(&test_layout, .{ .terrain = .{ .seed = 12345, .params = params } }, coords);
    const heights = terrainColumnHeights(&test_layout, coords[0], coords[1], 12345, params);

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
        for (columns) |coords| {
            const column = ColumnGenerator.init(&test_layout, generator, coords);
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
                    const neighbor_column = ColumnGenerator.init(&test_layout, generator, .{ neighbor_coords[0], neighbor_coords[1] });
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
        const layout = try WorldLayout.init(.{ .size_in_chunks = size, .wrap_x = true });
        const noise = PerlinNoise.init(12345);
        const params = WorldGenerationParams{ .height_amplitude = 0 };
        try std.testing.expectEqual(layout.size_in_blocks[2] / 2, terrainHeight(&layout, noise, 0, 0, params));
        const top_params = WorldGenerationParams{ .base_height = std.math.maxInt(u32), .height_amplitude = 0 };
        try std.testing.expectEqual(layout.size_in_blocks[2], terrainHeight(&layout, noise, 0, 0, top_params));
        for ([_]u32{ 0, 1, 31, 100, size[0] * CHUNK_SIZE - 1 }) |x| {
            try std.testing.expectEqual(terrainHeight(&layout, noise, x, 53, .{}), terrainHeight(&layout, noise, x + layout.size_in_blocks[0], 53, .{}));
        }
        const column = ColumnGenerator.init(&layout, .flat, .{ layout.size_in_chunks[0] - 1, layout.size_in_chunks[1] - 1 });
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
