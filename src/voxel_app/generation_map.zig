//! `zig build generation-map -Doptimize=ReleaseFast -- /absolute/map.ppm [seed] [seed-count]`.
//! Four overview panels: continents, climate, relief/vegetation, resource centres.
//! JSONL measurements use two independent reproducible jittered grids, not a census.
const std = @import("std");
const engine = @import("engine");
const generation = @import("world_generator.zig");
const diagnostics = @import("generation_diagnostics.zig");
const deposits = @import("generation_deposits.zig");
const hash = @import("generation_hash.zig");

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
        const relief_color: [3]u8 = if (e.water_present) water else if (e.relief == .mountain) .{ 128 + @as(u8, @intCast(e.mountain_strength / 1024)), 116, 104 } else if (e.vegetation == .forest) .{ 40, 103, 58 } else .{ 132, 169, 88 };
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

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const path = if (args.len > 1) args[1] else "/private/tmp/world-generation.ppm";
    const first_seed = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 12345;
    const seed_count = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 1;
    if (seed_count == 0 or seed_count > 1024) return error.InvalidSeedCount;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
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
            const line = try std.json.Stringify.valueAlloc(a, .{ .seed = seed, .status = @errorName(err), .preparation = report }, .{});
            try lines.appendSlice(a, line);
            try lines.append(a, '\n');
            std.debug.print("seed={d} status={s} attempts={d} reason={s}\n", .{ seed, @errorName(err), report.attempts_started, @tagName(report.reason) });
            continue;
        };
        defer prepared.deinit(init.gpa);
        const preparation_ns = beginning.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        const sample0 = diagnostics.sampleEnvironment(&prepared, 512, 256, 0);
        const sample1 = diagnostics.sampleEnvironment(&prepared, 512, 256, 1);
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
        const line = try std.json.Stringify.valueAlloc(a, .{ .seed = seed, .status = "accepted", .preparation = report, .preparation_ns = preparation_ns, .coarse_mainland = coarse_mainland, .first_start = start, .first_start_climate = start_climate, .sample_grid = .{ 512, 256 }, .sample_pass0 = sample0, .sample_pass1 = sample1, .land_percent_pass0 = sample0.landPercent(), .land_percent_pass1 = sample1.landPercent(), .sample_disagreement_percentage_points = @abs(sample0.landPercent() - sample1.landPercent()), .resource_order = "metal_ore,limestone,clay,coal,sand", .size_order = "large,small,starter", .deposit_populations = populations, .exact_effective_blocks = effective_blocks, .estimated_resource_distribution_pass0 = resourceDistribution(&prepared, 0), .estimated_resource_distribution_pass1 = resourceDistribution(&prepared, 1), .distribution_axes = "resource,relief(lowland/mountain),geology(sedimentary/rocky)", .eligible_host_volume_estimator = "sample.host_depth_by_relief_geology * world_horizontal_area / sample.samples", .effective_centers = center_effective, .mountain_deposit_centers = mountains, .sedimentary_deposit_centers = sedimentary }, .{});
        try lines.appendSlice(a, line);
        try lines.append(a, '\n');
        land_estimates[accepted] = land_estimate;
        accepted += 1;
        std.debug.print("seed={d} accepted attempt={d} land={d:.3}% disagreement_pp={d:.4} prep_ms={d:.3} peak_owned={d}\n", .{ seed, report.selected_attempt.?, (sample0.landPercent() + sample1.landPercent()) / 2, @abs(sample0.landPercent() - sample1.landPercent()), @as(f64, @floatFromInt(preparation_ns)) / std.time.ns_per_ms, report.peak_owned_bytes });
        if (index < 4) {
            const map_path = if (index == 0) path else try std.fmt.allocPrint(a, "{s}.seed-{d}.ppm", .{ path, seed });
            try exportMap(init, map_path, &prepared);
        }
    }
    const report_path = try std.fmt.allocPrint(a, "{s}.jsonl", .{path});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = report_path, .data = lines.items });
    const coverage = diagnostics.summarizeLandCoverage(land_estimates[0..accepted]);
    const summary = try std.json.Stringify.valueAlloc(a, .{
        .first_seed = first_seed,
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
