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
        const relief_color: [3]u8 = if (e.water_present) water else if (e.relief == .mountain) .{ 128 + @as(u8, @intCast(e.mountain_strength / 1024)), 116, 104 } else if (e.desert_biome) |biome| switch (biome) {
            .dunes => .{ 224, 171, 82 },
            .flats => .{ 211, 201, 159 },
        } else if (e.vegetation == .forest) .{ 40, 103, 58 } else .{ 132, 169, 88 };
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
        const start_boundaries = prepared.kind.natural.climate.boundaries(start[0]);
        const belt_index: usize = if (start[1] < start_boundaries[2]) 1 else 3;
        const start_climate = .{
            .climate = prepared.climateAt(start[0], start[1]),
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
        const line = try std.json.Stringify.valueAlloc(a, .{ .seed = seed, .status = "accepted", .profile = profile, .mountains = mountain_report, .preparation = report, .preparation_ns = preparation_ns, .coarse_mainland = coarse_mainland, .first_start = start, .first_start_climate = start_climate, .sample_grid = .{ 512, 256 }, .sample_pass0 = sample0, .sample_pass1 = sample1, .desert_biome_order = "dunes,flats", .land_percent_pass0 = sample0.landPercent(), .land_percent_pass1 = sample1.landPercent(), .sample_disagreement_percentage_points = @abs(sample0.landPercent() - sample1.landPercent()), .resource_order = "metal_ore,limestone,clay,coal,sand", .size_order = "large,small,starter", .deposit_populations = populations, .exact_effective_blocks = effective_blocks, .estimated_resource_distribution_pass0 = resourceDistribution(&prepared, 0), .estimated_resource_distribution_pass1 = resourceDistribution(&prepared, 1), .distribution_axes = "resource,relief(lowland/mountain),geology(sedimentary/rocky)", .eligible_host_volume_estimator = "sample.host_depth_by_relief_geology * world_horizontal_area / sample.samples", .effective_centers = center_effective, .mountain_deposit_centers = mountains, .sedimentary_deposit_centers = sedimentary }, .{});
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
