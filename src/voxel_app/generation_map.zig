//! `zig build generation-map -Doptimize=ReleaseFast -- /absolute/map.ppm [seed] [seed-count] [half|default|double]`.
//! Four overview panels: continents, climate, relief/vegetation, resource centres.
//! JSONL measurements use two independent reproducible jittered grids, not a census.
const std = @import("std");
const engine = @import("engine");
const generation = @import("world_generator.zig");
const diagnostics = @import("generation_diagnostics.zig");
const deposits = @import("generation_deposits.zig");
const hash = @import("generation_hash.zig");
const env = @import("world_environment.zig");
const desert = @import("generation_desert.zig");
const temperate = @import("generation_temperate.zig");

const width = 1024;
const height = 512;
const water = [3]u8{ 38, 94, 151 };
const resource_colors = [_][3]u8{ .{ 203, 75, 60 }, .{ 227, 223, 196 }, .{ 179, 101, 69 }, .{ 42, 38, 37 }, .{ 235, 203, 118 } };

fn resourceDistribution(prepared: *const generation.PreparedWorldGenerator, pass: u64) struct { blocks: [5][2][2]f64, accepted_samples: [5]u32, total_samples: u32 } {
    var result: @typeInfo(@TypeOf(resourceDistribution)).@"fn".return_type.? = .{ .blocks = @splat(@splat(@splat(0))), .accepted_samples = @splat(0), .total_samples = 0 };
    const size = prepared.layout.size_in_blocks;
    for (prepared.kind.natural.deposits.items[0..prepared.kind.natural.deposits.count]) |deposit| {
        var counts: [2][2]u32 = @splat(@splat(0));
        var accepted: u32 = 0;
        for (0..512) |i| {
            const h = hash.mix(prepared.seed() ^ (@as(u64, deposit.id) << 32) ^ (@as(u64, @intCast(i)) << 1) ^ pass);
            const x = hash.wrappedX(@as(i64, deposit.center[0]) - deposit.radii[0] + @as(i64, @intCast(h % (deposit.radii[0] * 2 + 1))), size[0]);
            const y = deposit.center[1] - deposit.radii[1] + @as(u32, @intCast((h >> 21) % (deposit.radii[1] * 2 + 1)));
            const z = deposit.center[2] - deposit.radii[2] + @as(u32, @intCast((h >> 42) % (deposit.radii[2] * 2 + 1)));
            result.total_samples += 1;
            if (!deposit.contains(x, y, z, size[0])) continue;
            if (prepared.referenceMaterialAt(x, y, z) != deposits.definitions[@intFromEnum(deposit.resource)].block) continue;
            const e = prepared.columnEnvironmentAt(x, y);
            counts[@intFromEnum(e.relief)][@intFromEnum(e.geology)] += 1;
            accepted += 1;
        }
        const r = @intFromEnum(deposit.resource);
        result.accepted_samples[r] += accepted;
        if (accepted == 0) continue;
        for (0..2) |relief| for (0..2) |geology| {
            result.blocks[r][relief][geology] += @as(f64, @floatFromInt(deposit.effective_blocks)) * @as(f64, @floatFromInt(counts[relief][geology])) / @as(f64, @floatFromInt(accepted));
        };
    }
    return result;
}

fn exportMap(init: std.process.Init, path: []const u8, prepared: *const generation.PreparedWorldGenerator) !void {
    const header = "P6\n1024 2048\n255\n";
    const bytes = try init.arena.allocator().alloc(u8, header.len + width * height * 3 * 4);
    @memcpy(bytes[0..header.len], header);
    const size = prepared.layout.size_in_blocks;
    for (0..height) |py| for (0..width) |px| {
        const x: i64 = @intCast((px * 2 + 1) * size[0] / (width * 2));
        const y: u32 = size[1] - 1 - @as(u32, @intCast((py * 2 + 1) * size[1] / (height * 2)));
        const e = prepared.columnEnvironmentAt(x, y);
        const colors = [_][3]u8{ .{ 205, 220, 232 }, .{ 185, 169, 83 }, .{ 85, 150, 76 }, .{ 219, 184, 113 } };
        const land_color: [3]u8 = if (e.water_present) water else if (e.landmass_id >= 128) .{ 232, 210, 116 } else .{ 82 + e.landmass_id * 17, 143 + e.landmass_id * 8, 76 };
        var climate_color = colors[@intFromEnum(e.climate)];
        if (e.water_present) {
            for (&climate_color, water) |*component, blue| component.* = @intCast((@as(u16, component.*) + blue) / 2);
        }
        var relief_color: [3]u8 = if (e.water_present) water else if (e.relief == .mountain) .{ 128 + @as(u8, @intCast(e.mountain_strength / 1024)), 116, 104 } else if (e.desert_biome) |biome| switch (biome) {
            .dunes => .{ 224, 171, 82 },
            .flats => .{ 211, 201, 159 },
        } else if (e.temperate_landform) |landform| switch (landform) {
            .flatland => .{ 155, 191, 109 },
            .rolling_hills => .{ 194, 174, 107 },
            .hilly => .{ 175, 133, 93 },
        } else if (e.vegetation == .forest) .{ 40, 103, 58 } else .{ 132, 169, 88 };
        if (e.temperate_landform != null and e.vegetation == .forest) for (&relief_color) |*component| {
            component.* = @intCast(@as(u16, component.*) * 2 / 3);
        };
        const resource_background: [3]u8 = if (e.water_present) .{ 40, 73, 99 } else .{ 125, 139, 111 };
        for ([_][3]u8{ land_color, climate_color, relief_color, resource_background }, 0..) |color, panel| {
            const offset = header.len + ((panel * height + py) * width + px) * 3;
            @memcpy(bytes[offset..][0..3], &color);
        }
    };
    const natural = prepared.kind.natural;
    for (natural.deposits.items[0..natural.deposits.count]) |deposit| {
        const px: i64 = @intCast(@as(u64, deposit.center[0]) * width / size[0]);
        const py: i64 = height - 1 - @as(i64, @intCast(@as(u64, deposit.center[1]) * height / size[1]));
        const radius: i64 = if (deposit.size_class == .large) 3 else 1;
        var dy = -radius;
        while (dy <= radius) : (dy += 1) {
            if (py + dy < 0 or py + dy >= height) continue;
            var dx = -radius;
            while (dx <= radius) : (dx += 1) {
                const offset = header.len + ((3 * height + @as(usize, @intCast(py + dy))) * width + @as(usize, @intCast(@mod(px + dx, width)))) * 3;
                @memcpy(bytes[offset..][0..3], &resource_colors[@intFromEnum(deposit.resource)]);
            }
        }
    }
    const start = prepared.firstStart().?;
    const sx: usize = @intCast(@as(u64, start[0]) * width / size[0]);
    const sy: usize = height - 1 - @as(usize, @intCast(@as(u64, start[1]) * height / size[1]));
    for (0..4) |panel| {
        for (0..9) |d| {
            const px = (sx + width + d - 4) % width;
            const py = @as(i64, @intCast(sy)) + @as(i64, @intCast(d)) - 4;
            @memcpy(bytes[header.len + ((panel * height + sy) * width + px) * 3 ..][0..3], &[_]u8{ 255, 20, 190 });
            if (py >= 0 and py < height) @memcpy(bytes[header.len + ((panel * height + @as(usize, @intCast(py))) * width + sx) * 3 ..][0..3], &[_]u8{ 255, 20, 190 });
        }
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
}

const DesertDetailTile = struct {
    biome: env.DesertBiome,
    found: bool = false,
    center: ?[2]u32 = null,
    min_height: ?u32 = null,
    max_height: ?u32 = null,
    horizontal_profile: []const u32 = &.{},
    vertical_profile: []const u32 = &.{},
};

fn pureDesertDetailColumn(prepared: *const generation.PreparedWorldGenerator, biome: env.DesertBiome, x: i64, y: u32) bool {
    const e = prepared.columnEnvironmentAt(x, y);
    if (e.water_present or e.climate != .desert or e.mountain_strength != 0 or e.desert_biome != biome) return false;
    const terrain = desert.sample(prepared.kind.natural.geography.seed, hash.wrappedX(x, prepared.layout.size_in_blocks[0]), y, prepared.layout.size_in_blocks[0]);
    return if (biome == .dunes) terrain.dune_weight == desert.unit else terrain.dune_weight == 0;
}

fn findDesertDetailTile(prepared: *const generation.PreparedWorldGenerator, biome: env.DesertBiome, side: u32, heights: []u32) ?[2]u32 {
    const geography = &prepared.kind.natural.geography;
    const half = side / 2;
    candidates: for (geography.owners, 0..) |owner, i| {
        if (owner == 0) continue;
        const center = [2]u32{ @intCast(i % geography.macro_width * 128 + 64), @intCast(i / geography.macro_width * 128 + 64) };
        if (center[1] < half or center[1] + half > prepared.layout.size_in_blocks[1]) continue;
        const e = prepared.columnEnvironmentAt(center[0], center[1]);
        if (e.coast_distance < 512 or e.desert_biome != biome) continue;
        const x0 = @as(i64, center[0]) - half;
        const y0 = center[1] - half;
        // Reject unsuitable candidates cheaply before validating every column.
        for ([_]u32{ 0, half, side - 1 }) |dy| for ([_]u32{ 0, half, side - 1 }) |dx| {
            if (!pureDesertDetailColumn(prepared, biome, x0 + dx, y0 + dy)) continue :candidates;
        };
        for (0..side) |dy| for (0..side) |dx| {
            const x = x0 + @as(i64, @intCast(dx));
            const y = y0 + @as(u32, @intCast(dy));
            if (!pureDesertDetailColumn(prepared, biome, x, y)) continue :candidates;
            heights[dy * side + dx] = prepared.columnEnvironmentAt(x, y).terrain_height;
        };
        return center;
    }
    return null;
}

/// First-seed block-scale views of actual integrated terrain, with exact
/// midpoint profiles and one shared grayscale height scale for both biomes.
fn exportDesertDetail(init: std.process.Init, path: []const u8, prepared: *const generation.PreparedWorldGenerator) !void {
    const a = init.arena.allocator();
    const heights = try a.alloc(u32, 2 * 512 * 512);
    var side: u32 = 512;
    var tiles = [_]DesertDetailTile{ .{ .biome = .dunes }, .{ .biome = .flats } };
    while (true) {
        for (&tiles, 0..) |*tile, i| tile.center = findDesertDetailTile(prepared, tile.biome, side, heights[i * side * side ..][0 .. side * side]);
        if ((tiles[0].center != null and tiles[1].center != null) or side == 256) break;
        side = 256;
    }
    var minimum: u32 = std.math.maxInt(u32);
    var maximum: u32 = 0;
    for (&tiles, 0..) |*tile, i| {
        tile.found = tile.center != null;
        if (!tile.found) continue;
        const tile_heights = heights[i * side * side ..][0 .. side * side];
        tile.min_height = std.mem.min(u32, tile_heights);
        tile.max_height = std.mem.max(u32, tile_heights);
        minimum = @min(minimum, tile.min_height.?);
        maximum = @max(maximum, tile.max_height.?);
        tile.horizontal_profile = tile_heights[side / 2 * side ..][0..side];
        const vertical = try a.alloc(u32, side);
        for (vertical, 0..) |*value, y| value.* = tile_heights[y * side + side / 2];
        tile.vertical_profile = vertical;
    }
    const missing = !tiles[0].found or !tiles[1].found;
    if (!tiles[0].found and !tiles[1].found) minimum = 0;
    const header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ side * 2, side });
    const bytes = try a.alloc(u8, header.len + side * side * 2 * 3);
    @memcpy(bytes[0..header.len], header);
    for (tiles, 0..) |tile, i| for (0..side) |y| for (0..side) |x| {
        const value: u8 = if (tile.found) @intCast((heights[i * side * side + y * side + x] - minimum) * 255 / @max(1, maximum - minimum)) else 0;
        const color = if (tile.found) [3]u8{ value, value, value } else [3]u8{ 255, 0, 255 };
        const offset = header.len + (y * side * 2 + i * side + x) * 3;
        @memcpy(bytes[offset..][0..3], &color);
    };
    const image_path = try std.fmt.allocPrint(a, "{s}.desert.ppm", .{path});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = image_path, .data = bytes });
    const json = try std.json.Stringify.valueAlloc(a, .{
        .seed = prepared.seed(),
        .missing = missing,
        .tile_side_blocks = side,
        .blocks_per_pixel = 1,
        .tile_order = "dunes,flats",
        .row_direction = "increasing world Y; center is pixel (side/2,side/2); X wraps",
        .height_grayscale_min = minimum,
        .height_grayscale_max = maximum,
        .selection = "all tile columns: dry desert, zero mountain uplift, pure biome blend; center coast distance >=512",
        .tiles = tiles,
    }, .{});
    const metadata_path = try std.fmt.allocPrint(a, "{s}.desert.json", .{path});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = metadata_path, .data = json });
    std.debug.print("desert_detail side={d} missing={any} image={s} metadata={s}\n", .{ side, missing, image_path, metadata_path });
}

const TemperateProfile = struct {
    origin: [2]u32,
    step_blocks: [2]u32,
    terrain_heights: []const u32,
    vegetation: []const env.VegetationId,
    landforms: []const ?env.TemperateLandform,
    weights_q16: []const [3]u32,
    water_present: []const bool,
    coast_distance: []const u32,
    mountain_strength: []const u16,
    temperate_terrain: []const u16,
    temperate_boundary_distance: []const u32,
};

const TemperateDetailTile = struct {
    landform: env.TemperateLandform,
    extent_blocks: u32,
    center: ?[2]u32 = null,
    origin: ?[2]i64 = null,
    center_temperate_boundary_distance: ?u32 = null,
    center_temperate_terrain: ?u16 = null,
    center_weights_q16: ?[3]u32 = null,
    center_coast_distance: ?u32 = null,
    selection_probes: u32 = 0,
    selection_eligible_probes: u32 = 0,
    selection_target_probes: u32 = 0,
    selection_full_interior_probes: u32 = 0,
    selection_unclipped_full_interior_probes: u32 = 0,
    sampled_columns: u32 = 0,
    sampled_landforms: [3]u32 = @splat(0),
    sampled_water_columns: u32 = 0,
    sampled_mountain_columns: u32 = 0,
    sampled_full_temperate_interior_columns: u32 = 0,
    sampled_forest_columns: u32 = 0,
    min_temperate_terrain: ?u16 = null,
    max_temperate_terrain: ?u16 = null,
    min_coast_distance: ?u32 = null,
    min_height: ?u32 = null,
    max_height: ?u32 = null,
    horizontal_profile: ?TemperateProfile = null,
    vertical_profile: ?TemperateProfile = null,
};

fn temperateBoundaryDistance(prepared: *const generation.PreparedWorldGenerator, x: i64, y: u32) u32 {
    const b = prepared.kind.natural.climate.boundaries(x);
    if (y >= b[1] and y < b[2]) return @min(y - b[1], b[2] - 1 - y);
    if (y >= b[3] and y < b[4]) return @min(y - b[3], b[4] - 1 - y);
    return 0;
}

/// Select among a fixed 64x32 jittered grid, with 25 actual world probes per
/// eligible candidate. Prefer eligible columns, full unclipped interior
/// coverage, then the requested class. Final exports report their own samples;
/// this selection grid does not establish that a window is pure.
fn findTemperateDetailTiles(prepared: *const generation.PreparedWorldGenerator, tiles: *[3]TemperateDetailTile, only: ?env.TemperateLandform) u32 {
    const size = prepared.layout.size_in_blocks;
    var best_scores: [3]u32 = @splat(0);
    var probes: u32 = 0;
    for (0..32) |py| for (0..64) |px| {
        const h = hash.at(hash.mix(prepared.seed() ^ 0x74656d7065726174), @intCast(px), @intCast(py));
        const x: u32 = @intCast((@as(u64, @intCast(px)) * size[0] + h % size[0]) / 64);
        const y: u32 = @intCast((@as(u64, @intCast(py)) * size[1] + (h >> 32) % size[1]) / 32);
        const e = prepared.columnEnvironmentAt(x, y);
        probes += 1;
        const landform = e.temperate_landform orelse continue;
        if (only) |wanted| if (landform != wanted) continue;
        const index = @intFromEnum(landform);
        const tile = &tiles[index];
        const half = tile.extent_blocks / 2;
        if (y < half or y + half > size[1]) continue;
        const origin = [2]i64{ @as(i64, x) - half, @as(i64, y) - half };
        var eligible: u32 = 0;
        var target: u32 = 0;
        var interior: u32 = 0;
        var unclipped: u32 = 0;
        for (0..5) |dy| for (0..5) |dx| {
            const at_x = origin[0] + @as(i64, @intCast(dx * (tile.extent_blocks - 1) / 4));
            const at_y: u32 = @intCast(origin[1] + @as(i64, @intCast(dy * (tile.extent_blocks - 1) / 4)));
            const at = prepared.columnEnvironmentAt(at_x, at_y);
            probes += 1;
            eligible += @intFromBool(at.temperate_landform != null);
            target += @intFromBool(at.temperate_landform == landform);
            const full_interior = at.temperate_landform != null and temperateBoundaryDistance(prepared, at_x, at_y) >= 1792;
            interior += @intFromBool(full_interior);
            unclipped += @intFromBool(full_interior and at.landmass_id < 128 and at.coast_distance >= 512);
        };
        const score = eligible * 100000000 + unclipped * 1000000 + interior * 10000 + target;
        if (tile.center != null and score <= best_scores[index]) continue;
        best_scores[index] = score;
        tile.center = .{ x, y };
        tile.origin = origin;
        tile.center_temperate_boundary_distance = temperateBoundaryDistance(prepared, x, y);
        tile.center_temperate_terrain = prepared.kind.natural.climate.sample(x, y).temperate_terrain;
        tile.center_weights_q16 = temperate.sample(prepared.kind.natural.geography.seed, x, y, size[0], size[2]).weights_q16;
        tile.center_coast_distance = e.coast_distance;
        tile.selection_probes = 25;
        tile.selection_eligible_probes = eligible;
        tile.selection_target_probes = target;
        tile.selection_full_interior_probes = interior;
        tile.selection_unclipped_full_interior_probes = unclipped;
    };
    return probes;
}

fn temperateProfile(a: std.mem.Allocator, prepared: *const generation.PreparedWorldGenerator, origin: [2]i64, step: [2]u32, length: u32) !TemperateProfile {
    const heights = try a.alloc(u32, length);
    const vegetation = try a.alloc(env.VegetationId, length);
    const landforms = try a.alloc(?env.TemperateLandform, length);
    const weights = try a.alloc([3]u32, length);
    const water_present = try a.alloc(bool, length);
    const coast_distance = try a.alloc(u32, length);
    const mountain_strength = try a.alloc(u16, length);
    const temperate_terrain = try a.alloc(u16, length);
    const boundary_distance = try a.alloc(u32, length);
    for (0..length) |i| {
        const x = origin[0] + @as(i64, @intCast(i * step[0]));
        const y: u32 = @intCast(origin[1] + @as(i64, @intCast(i * step[1])));
        const e = prepared.columnEnvironmentAt(x, y);
        heights[i] = e.terrain_height;
        vegetation[i] = e.vegetation;
        landforms[i] = e.temperate_landform;
        weights[i] = temperate.sample(prepared.kind.natural.geography.seed, hash.wrappedX(x, prepared.layout.size_in_blocks[0]), y, prepared.layout.size_in_blocks[0], prepared.layout.size_in_blocks[2]).weights_q16;
        water_present[i] = e.water_present;
        coast_distance[i] = e.coast_distance;
        mountain_strength[i] = e.mountain_strength;
        temperate_terrain[i] = prepared.kind.natural.climate.sample(x, y).temperate_terrain;
        boundary_distance[i] = temperateBoundaryDistance(prepared, x, y);
    }
    return .{
        .origin = .{ hash.wrappedX(origin[0], prepared.layout.size_in_blocks[0]), @intCast(origin[1]) },
        .step_blocks = step,
        .terrain_heights = heights,
        .vegetation = vegetation,
        .landforms = landforms,
        .weights_q16 = weights,
        .water_present = water_present,
        .coast_distance = coast_distance,
        .mountain_strength = mountain_strength,
        .temperate_terrain = temperate_terrain,
        .temperate_boundary_distance = boundary_distance,
    };
}

/// Actual integrated terrain at the spatial scales of each landform. The three
/// 256-square windows cover 512, 1024..4096 and 512 blocks respectively. Profiles
/// retain every block along both midlines, including any boundary crossings.
fn exportTemperateDetail(init: std.process.Init, path: []const u8, prepared: *const generation.PreparedWorldGenerator) !void {
    const a = init.arena.allocator();
    const side: usize = 256;
    var tiles = [_]TemperateDetailTile{
        .{ .landform = .flatland, .extent_blocks = 512 },
        .{ .landform = .rolling_hills, .extent_blocks = 4096 },
        .{ .landform = .hilly, .extent_blocks = 512 },
    };
    var selection_probes = findTemperateDetailTiles(prepared, &tiles, null);
    while (tiles[1].selection_eligible_probes < 25 and tiles[1].extent_blocks > 1024) {
        const extent = tiles[1].extent_blocks / 2;
        tiles[1] = .{ .landform = .rolling_hills, .extent_blocks = extent };
        selection_probes += findTemperateDetailTiles(prepared, &tiles, .rolling_hills);
    }
    const heights = try a.alloc(u32, tiles.len * side * side);
    const vegetation = try a.alloc(env.VegetationId, heights.len);
    const submerged = try a.alloc(bool, heights.len);
    var minimum: u32 = std.math.maxInt(u32);
    var maximum: u32 = 0;
    var missing = false;
    for (&tiles, 0..) |*tile, panel| {
        const origin = tile.origin orelse {
            missing = true;
            continue;
        };
        for (0..side) |py| for (0..side) |px| {
            const x = origin[0] + @as(i64, @intCast((px * 2 + 1) * tile.extent_blocks / (side * 2)));
            const y: u32 = @intCast(origin[1] + @as(i64, @intCast((py * 2 + 1) * tile.extent_blocks / (side * 2))));
            const e = prepared.columnEnvironmentAt(x, y);
            const index = panel * side * side + py * side + px;
            heights[index] = e.terrain_height;
            vegetation[index] = e.vegetation;
            submerged[index] = e.water_present;
            tile.sampled_columns += 1;
            if (e.temperate_landform) |landform| tile.sampled_landforms[@intFromEnum(landform)] += 1;
            tile.sampled_water_columns += @intFromBool(e.water_present);
            tile.sampled_mountain_columns += @intFromBool(e.mountain_strength != 0);
            tile.sampled_full_temperate_interior_columns += @intFromBool(e.temperate_landform != null and temperateBoundaryDistance(prepared, x, y) >= 1792);
            tile.sampled_forest_columns += @intFromBool(e.vegetation == .forest);
            const influence = prepared.kind.natural.climate.sample(x, y).temperate_terrain;
            tile.min_temperate_terrain = @min(tile.min_temperate_terrain orelse influence, influence);
            tile.max_temperate_terrain = @max(tile.max_temperate_terrain orelse influence, influence);
            tile.min_coast_distance = @min(tile.min_coast_distance orelse e.coast_distance, e.coast_distance);
            tile.min_height = @min(tile.min_height orelse e.terrain_height, e.terrain_height);
            tile.max_height = @max(tile.max_height orelse e.terrain_height, e.terrain_height);
        };
        minimum = @min(minimum, tile.min_height.?);
        maximum = @max(maximum, tile.max_height.?);
        tile.horizontal_profile = try temperateProfile(a, prepared, .{ origin[0], tile.center.?[1] }, .{ 1, 0 }, tile.extent_blocks);
        tile.vertical_profile = try temperateProfile(a, prepared, .{ tile.center.?[0], origin[1] }, .{ 0, 1 }, tile.extent_blocks);
    }
    if (minimum == std.math.maxInt(u32)) minimum = 0;
    const header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ side * tiles.len, side * 2 });
    const image = try a.alloc(u8, header.len + side * side * tiles.len * 2 * 3);
    @memcpy(image[0..header.len], header);
    const height_header = try std.fmt.allocPrint(a, "P5\n{d} {d}\n{d}\n", .{ side * tiles.len, side, prepared.layout.size_in_blocks[2] - 1 });
    const height_image = try a.alloc(u8, height_header.len + heights.len * 2);
    @memcpy(height_image[0..height_header.len], height_header);
    const forest_header = try std.fmt.allocPrint(a, "P5\n{d} {d}\n255\n", .{ side * tiles.len, side });
    const forest_image = try a.alloc(u8, forest_header.len + heights.len);
    @memcpy(forest_image[0..forest_header.len], forest_header);
    for (tiles, 0..) |tile, panel| for (0..side) |py| for (0..side) |px| {
        const sample_index = panel * side * side + py * side + px;
        const pixel = py * side * tiles.len + panel * side + px;
        const found = tile.center != null;
        const value: u8 = if (found) @intCast(@as(u64, heights[sample_index] - minimum) * 255 / @max(1, maximum - minimum)) else 0;
        const color: [3]u8 = if (!found) .{ 255, 0, 255 } else if (submerged[sample_index]) water else .{ value, value, value };
        const forest = found and vegetation[sample_index] == .forest;
        const overlay: [3]u8 = if (forest) .{ value / 3, 70 + value / 2, value / 4 } else color;
        @memcpy(image[header.len + pixel * 3 ..][0..3], &color);
        @memcpy(image[header.len + (side * side * tiles.len + pixel) * 3 ..][0..3], &overlay);
        std.mem.writeInt(u16, height_image[height_header.len + pixel * 2 ..][0..2], if (found) @intCast(heights[sample_index]) else 0, .big);
        forest_image[forest_header.len + pixel] = if (forest) 255 else 0;
    };
    const image_path = try std.fmt.allocPrint(a, "{s}.temperate.ppm", .{path});
    const height_path = try std.fmt.allocPrint(a, "{s}.temperate.height.pgm", .{path});
    const forest_path = try std.fmt.allocPrint(a, "{s}.temperate.forest.pgm", .{path});
    const metadata_path = try std.fmt.allocPrint(a, "{s}.temperate.json", .{path});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = image_path, .data = image });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = height_path, .data = height_image });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = forest_path, .data = forest_image });
    const metadata = try std.json.Stringify.valueAlloc(a, .{
        .seed = prepared.seed(),
        .dimensions_blocks = prepared.layout.size_in_blocks,
        .missing = missing,
        .tile_order = "flatland,rolling_hills,hilly; top row shared-scale heights, bottom row forest overlay",
        .top_down_tile_pixels = side,
        .blocks_per_pixel = .{ tiles[0].extent_blocks / side, tiles[1].extent_blocks / side, tiles[2].extent_blocks / side },
        .row_direction = "increasing world Y; X wraps; pixel centers sampled, no filtering",
        .height_pgm = "big-endian 16-bit actual sampled terrain heights, maxval=world depth-1; missing panels zero",
        .forest_pgm = "255=actual forest vegetation, 0=other vegetation or missing; consult tile.center for availability",
        .display_grayscale_min = minimum,
        .display_grayscale_max = maximum,
        .selection = "fixed 64x32 jittered candidates; 25 probes per candidate whose center has a temperate landform; prefer eligible columns, full temperate mainland interior >=512 blocks inland, full climate influence, then requested class; not a purity guarantee",
        .rolling_window_selection = "try 4096,2048,1024 blocks in order, retaining the largest with all 25 selection probes eligible (dry temperate, zero mountain); if none qualifies, report the best 1024-block candidate with actual sample counts",
        .selection_column_probes = selection_probes,
        .full_temperate_interior = "at least 1792 blocks from either temperate belt boundary; zero mountain influence and dry",
        .temperate_terrain_scale = "0..65535 climate blend influence; 65535=full temperate terrain, profiles and tiles retain actual influence",
        .weights_q16_scale = "flatland,rolling_hills,hilly selector weights sum to 65536; separate from climate influence and coast capping; terrain heights always come from actual integrated columns",
        .profile_sampling = "one block per entry along each complete midpoint row/column; all heights from columnEnvironmentAt; boundary crossings retained",
        .tiles = tiles,
    }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = metadata_path, .data = metadata });
    std.debug.print("temperate_detail missing={any} selection_probes={d} image={s} heights={s} forest={s} metadata={s}\n", .{ missing, selection_probes, image_path, height_path, forest_path, metadata_path });
}

const MountainDetailTile = struct {
    label: []const u8,
    center: [2]u32,
    origin: [2]i64,
    extent_blocks: [2]u32,
    section_endpoints: [2][2]u32,
    section_heights: []const u32 = &.{},
    min_height: u32 = std.math.maxInt(u32),
    max_height: u32 = 0,
};

fn mountainTile(prepared: *const generation.PreparedWorldGenerator, label: []const u8, site: diagnostics.MountainSite, pair: ?diagnostics.MountainPass) MountainDetailTile {
    const field = &prepared.kind.natural.geography.mountains;
    const peak = field.peaks[site.owner - 1][field.binAt(site.block[1])];
    const half_x = @max(256, @max(peak.radii_x[0], peak.radii_x[1]) * 6 / 5);
    const half_y = @max(256, @max(peak.radii_y[0], peak.radii_y[1]) * 6 / 5);
    var a = [2]u32{ hash.wrappedX(@as(i64, site.block[0]) - half_x, field.width), site.block[1] };
    var b = [2]u32{ hash.wrappedX(@as(i64, site.block[0]) + half_x, field.width), site.block[1] };
    if (pair) |pass| {
        a = pass.endpoints[0].block;
        b = pass.endpoints[1].block;
    }
    const dx = hash.distanceX(b[0], a[0], field.width);
    const ax: i64 = a[0];
    const bx = ax + dx;
    const x0 = @min(ax, bx) - half_x / 3;
    const y0 = @max(0, @as(i64, @min(a[1], b[1])) - half_y / 2);
    const x1 = @max(ax, bx) + half_x / 3;
    const y1 = @min(@as(i64, field.height), @as(i64, @max(a[1], b[1])) + half_y / 2 + 1);
    return .{ .label = label, .center = site.block, .origin = .{ x0, y0 }, .extent_blocks = .{ @intCast(x1 - x0 + 1), @intCast(y1 - y0) }, .section_endpoints = .{ a, b } };
}

/// Bounded views of final integrated heights, plus one-block cross-sections.
/// PGM preserves sampled block heights as 16-bit values. PPM uses a shared
/// sea..95%-depth grayscale, with submerged terrain shown blue.
fn exportMountainDetail(init: std.process.Init, path: []const u8, prepared: *const generation.PreparedWorldGenerator, report: diagnostics.MountainReport) !void {
    if (report.summit == null or report.pass == null or report.gorge == null) return error.MissingMountainDetailSite;
    const a = init.arena.allocator();
    const size = prepared.layout.size_in_blocks;
    const side: usize = 768;
    var tiles = [_]MountainDetailTile{
        mountainTile(prepared, "summit", report.summit.?, null),
        mountainTile(prepared, "pass", report.pass.?.site, report.pass),
        mountainTile(prepared, "gorge", report.gorge.?.site, report.gorge),
    };
    const header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ side * tiles.len, side });
    const image = try a.alloc(u8, header.len + side * side * tiles.len * 3);
    @memcpy(image[0..header.len], header);
    const height_header = try std.fmt.allocPrint(a, "P5\n{d} {d}\n{d}\n", .{ side * tiles.len, side, size[2] - 1 });
    const height_image = try a.alloc(u8, height_header.len + side * side * tiles.len * 2);
    @memcpy(height_image[0..height_header.len], height_header);
    for (&tiles, 0..) |*tile, panel| {
        for (0..side) |py| for (0..side) |px| {
            const x = tile.origin[0] + @as(i64, @intCast((px * 2 + 1) * tile.extent_blocks[0] / (side * 2)));
            const y: u32 = @intCast(tile.origin[1] + @as(i64, @intCast((py * 2 + 1) * tile.extent_blocks[1] / (side * 2))));
            const e = prepared.columnEnvironmentAt(x, y);
            tile.min_height = @min(tile.min_height, e.terrain_height);
            tile.max_height = @max(tile.max_height, e.terrain_height);
            const value: u8 = @intCast(@min(255, @as(u64, e.terrain_height -| report.sea_level) * 255 / @max(1, report.height_limit - report.sea_level)));
            const color = if (e.water_present) water else [3]u8{ value, value, value };
            const pixel = py * side * tiles.len + panel * side + px;
            @memcpy(image[header.len + pixel * 3 ..][0..3], &color);
            std.mem.writeInt(u16, height_image[height_header.len + pixel * 2 ..][0..2], @intCast(e.terrain_height), .big);
        };
        const p0 = tile.section_endpoints[0];
        const p1 = tile.section_endpoints[1];
        const length: u32 = @intCast(@max(@abs(hash.distanceX(p1[0], p0[0], size[0])), @abs(@as(i64, p1[1]) - p0[1])));
        if (length == 0 or length > 32768) return error.InvalidMountainSection;
        const heights = try a.alloc(u32, length + 1);
        for (heights, 0..) |*h, i| {
            const point = diagnostics.mountainPathPoint(p0, p1, @intCast(i), length, size[0]);
            h.* = prepared.columnEnvironmentAt(point[0], point[1]).terrain_height;
        }
        tile.section_heights = heights;
    }
    const section_width: usize = 1536;
    const section_height: usize = 512;
    const section_header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ section_width, section_height * tiles.len });
    const sections = try a.alloc(u8, section_header.len + section_width * section_height * tiles.len * 3);
    @memcpy(sections[0..section_header.len], section_header);
    for (tiles, 0..) |tile, panel| for (0..section_height) |py| for (0..section_width) |px| {
        const z: u32 = @intCast((section_height - 1 - py) * size[2] / section_height);
        const height_index = px * (tile.section_heights.len - 1) / (section_width - 1);
        const h = tile.section_heights[height_index];
        const sea_row = (section_height - 1 - py) * size[2] / section_height <= report.sea_level and (section_height - py) * size[2] / section_height > report.sea_level;
        const color: [3]u8 = if (sea_row) .{ 35, 125, 230 } else if (z < h) .{ 110, 105, 98 } else if (z < report.sea_level) water else .{ 239, 244, 249 };
        const pixel = (panel * section_height + py) * section_width + px;
        @memcpy(sections[section_header.len + pixel * 3 ..][0..3], &color);
    };
    const image_path = try std.fmt.allocPrint(a, "{s}.mountains.ppm", .{path});
    const height_path = try std.fmt.allocPrint(a, "{s}.mountains.height.pgm", .{path});
    const sections_path = try std.fmt.allocPrint(a, "{s}.mountains.sections.ppm", .{path});
    const metadata_path = try std.fmt.allocPrint(a, "{s}.mountains.json", .{path});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = image_path, .data = image });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = height_path, .data = height_image });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = sections_path, .data = sections });
    const metadata = try std.json.Stringify.valueAlloc(a, .{
        .seed = prepared.seed(),
        .dimensions_blocks = size,
        .tile_order = "summit,pass,gorge; top-down panels left to right, cross-sections top to bottom",
        .row_direction = "increasing world Y; X wraps",
        .top_down_tile_pixels = side,
        .height_pgm = "big-endian 16-bit actual sampled terrain heights, maxval=world depth-1",
        .display_grayscale_min = report.sea_level,
        .display_grayscale_max = report.height_limit,
        .section_z_min = 0,
        .section_z_max_exclusive = size[2],
        .section_sampling = "one block along the dominant horizontal axis; exact heights retained in section_heights",
        .pass_selection = "highest connected centerline saddle between adjacent active summit bins",
        .gorge_selection = "greatest two-wall relief among centerline and parallel quarter-width-offset corridors; geometric depression, no carved river",
        .connectivity_sampling = "257 equally spaced probes per corridor; sampled influence connectivity, not an exhaustive connected-component proof",
        .range_separation = "coasts, owner boundaries and frozen climate taper may separate exposed ranges between consecutive prepared summit bins",
        .diagnostics = report,
        .tiles = tiles,
    }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = metadata_path, .data = metadata });
    std.debug.print("mountain_detail image={s} heights={s} sections={s} metadata={s}\n", .{ image_path, height_path, sections_path, metadata_path });
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = if (args.len > 1) args[1] else "/private/tmp/world-generation.ppm";
    const first_seed = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 12345;
    const seed_count = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 1;
    if (seed_count == 0 or seed_count > 1024) return error.InvalidSeedCount;
    const profile = if (args.len > 4) args[4] else "default";
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = try diagnostics.profileDimensions(profile) });
    var lines: std.ArrayList(u8) = .empty;
    var accepted: usize = 0;
    var rejected: usize = 0;
    const land_estimates = try a.alloc(f64, seed_count);
    for (0..seed_count) |index| {
        const seed = first_seed +% index;
        var report: generation.PreparationReport = .{};
        const beginning = std.Io.Clock.awake.now(init.io);
        var prepared = generation.WorldGenerator.prepareWithReport(.{ .natural = .{ .seed = seed } }, init.gpa, &layout, &report) catch |err| {
            rejected += 1;
            const line = try std.json.Stringify.valueAlloc(a, .{ .seed = seed, .profile = profile, .status = @errorName(err), .preparation = report }, .{});
            try lines.appendSlice(a, line);
            try lines.append(a, '\n');
            std.debug.print("seed={d} status={s} attempts={d} reason={s}\n", .{ seed, @errorName(err), report.attempts_started, @tagName(report.reason) });
            continue;
        };
        defer prepared.deinit(init.gpa);
        const preparation_ns = beginning.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        const sample0 = diagnostics.sampleEnvironment(&prepared, 512, 256, 0);
        const sample1 = diagnostics.sampleEnvironment(&prepared, 512, 256, 1);
        const mountain_report = diagnostics.sampleMountains(&prepared);
        const land_estimate = (sample0.landPercent() + sample1.landPercent()) / 2;
        var coarse_mainland_cells: usize = 0;
        const geography = &prepared.kind.natural.geography;
        for (geography.owners) |owner| coarse_mainland_cells += @intFromBool(owner != 0);
        const coarse_mainland = .{
            .land_cells = coarse_mainland_cells,
            .total_cells = geography.owners.len,
            .land_percent = @as(f64, @floatFromInt(coarse_mainland_cells)) * 100 / @as(f64, @floatFromInt(geography.owners.len)),
            .scope = "mainland macro ownership before coast refinement; excludes islands",
        };
        const start = prepared.firstStart().?;
        const start_environment = prepared.columnEnvironmentAt(start[0], start[1]);
        const start_boundaries = prepared.kind.natural.climate.boundaries(start[0]);
        const belt_index: usize = if (start[1] < start_boundaries[2]) 1 else 3;
        const start_climate = .{
            .climate = prepared.climateAt(start[0], start[1]),
            .landform = start_environment.temperate_landform,
            .vegetation = start_environment.vegetation,
            .belt_min_y = start_boundaries[belt_index],
            .belt_max_y_exclusive = start_boundaries[belt_index + 1],
            .distance_to_lower_edge = start[1] - start_boundaries[belt_index],
            .distance_to_upper_edge = start_boundaries[belt_index + 1] - 1 - start[1],
        };
        var populations: [5][3]u32 = @splat(@splat(0));
        var effective_blocks: [5][3]u64 = @splat(@splat(0));
        var center_effective: [5][3]u32 = @splat(@splat(0));
        var mountains: [5]u32 = @splat(0);
        var sedimentary: [5]u32 = @splat(0);
        for (prepared.kind.natural.deposits.items[0..prepared.kind.natural.deposits.count]) |deposit| {
            const r = @intFromEnum(deposit.resource);
            const s = @intFromEnum(deposit.size_class);
            populations[r][s] += 1;
            effective_blocks[r][s] += deposit.effective_blocks;
            if (prepared.referenceMaterialAt(deposit.center[0], deposit.center[1], deposit.center[2]) == deposits.definitions[r].block) center_effective[r][s] += 1;
            const e = prepared.columnEnvironmentAt(deposit.center[0], deposit.center[1]);
            mountains[r] += @intFromBool(e.relief == .mountain);
            sedimentary[r] += @intFromBool(e.geology == .sedimentary);
        }
        const line = try std.json.Stringify.valueAlloc(a, .{ .seed = seed, .status = "accepted", .profile = profile, .mountains = mountain_report, .preparation = report, .preparation_ns = preparation_ns, .coarse_mainland = coarse_mainland, .first_start = start, .first_start_climate = start_climate, .sample_grid = .{ 512, 256 }, .sample_pass0 = sample0, .sample_pass1 = sample1, .desert_biome_order = "dunes,flats", .temperate_landform_order = "flatland,rolling_hills,hilly", .temperate_landform_vegetation_axes = "landform,vegetation(meadow,forest)", .temperate_landform_scope = "dry temperate columns with zero mountain influence; shared two-pass area estimator; nominal soft mix 50/30/20", .land_percent_pass0 = sample0.landPercent(), .land_percent_pass1 = sample1.landPercent(), .sample_disagreement_percentage_points = @abs(sample0.landPercent() - sample1.landPercent()), .resource_order = "metal_ore,limestone,clay,coal,sand", .size_order = "large,small,starter", .deposit_populations = populations, .exact_effective_blocks = effective_blocks, .estimated_resource_distribution_pass0 = resourceDistribution(&prepared, 0), .estimated_resource_distribution_pass1 = resourceDistribution(&prepared, 1), .distribution_axes = "resource,relief(lowland/mountain),geology(sedimentary/rocky)", .eligible_host_volume_estimator = "sample.host_depth_by_relief_geology * world_horizontal_area / sample.samples", .effective_centers = center_effective, .mountain_deposit_centers = mountains, .sedimentary_deposit_centers = sedimentary }, .{});
        try lines.appendSlice(a, line);
        try lines.append(a, '\n');
        land_estimates[accepted] = land_estimate;
        accepted += 1;
        std.debug.print("seed={d} accepted attempt={d} land={d:.3}% disagreement_pp={d:.4} prep_ms={d:.3} peak_owned={d}\n", .{ seed, report.selected_attempt.?, (sample0.landPercent() + sample1.landPercent()) / 2, @abs(sample0.landPercent() - sample1.landPercent()), @as(f64, @floatFromInt(preparation_ns)) / std.time.ns_per_ms, report.peak_owned_bytes });
        if (index < 4) {
            const map_path = if (index == 0) path else try std.fmt.allocPrint(a, "{s}.seed-{d}.ppm", .{ path, seed });
            try exportMap(init, map_path, &prepared);
            if (index == 0) {
                try exportDesertDetail(init, path, &prepared);
                try exportTemperateDetail(init, path, &prepared);
                try exportMountainDetail(init, path, &prepared, mountain_report);
            }
        }
    }
    const report_path = try std.fmt.allocPrint(a, "{s}.jsonl", .{path});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = report_path, .data = lines.items });
    const coverage = diagnostics.summarizeLandCoverage(land_estimates[0..accepted]);
    const summary = try std.json.Stringify.valueAlloc(a, .{
        .first_seed = first_seed,
        .profile = profile,
        .dimensions_in_chunks = layout.size_in_chunks,
        .requested_seeds = seed_count,
        .accepted_seeds = accepted,
        .rejected_seeds = rejected,
        .coverage_informational_only = true,
        .nominal_land_percent = 35,
        .soft_envelope_percent = .{ 25, 45 },
        .soft_envelope_desired_seed_fraction = 0.95,
        .coverage_estimator = "per-seed mean of two reproducible jittered 512x256 grids over all horizontal world area, including oceans and polar strips",
        .percentile_method = "empirical linear interpolation at (n-1)*p over successfully prepared seeds; descriptive, not confidence bounds or seed acceptance criteria",
        .land_coverage = coverage,
    }, .{});
    const summary_path = try std.fmt.allocPrint(a, "{s}.summary.json", .{path});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = summary_path, .data = summary });
    std.debug.print("suite first_seed={d} count={d} accepted={d} rejected={d} mean_land_percent={d:.3} report={s} summary={s}\n", .{ first_seed, seed_count, accepted, rejected, coverage.mean_percent orelse 0, report_path, summary_path });
    std.debug.print("suite informational land coverage: {s}\n", .{summary});
}
