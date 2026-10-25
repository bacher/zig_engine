const std = @import("std");
const engine = @import("engine");
const diagnostics = @import("generation_diagnostics.zig");
const generator = @import("world_generator.zig");
const hash = @import("generation_hash.zig");
const Geography = @import("generation_geography.zig").Geography;
const NaturalWorld = @import("natural_generator.zig").NaturalWorld;
const preparation = @import("generation_preparation.zig");
const environment = @import("world_environment.zig");

test "desert lowlands retain bounded steps at shores islands macro joins and the X seam" {
    const width = 4096;
    const height = 2048;
    var owners: [32 * 16]u8 = @splat(0);
    var distances: [32 * 16]u16 = @splat(0);
    for (2..14) |my| for (0..32) |mx| {
        if (mx >= 8 and mx < 24) continue;
        owners[my * 32 + mx] = 1;
        distances[my * 32 + mx] = @intCast(@min(@min(my - 1, 14 - my), if (mx < 8) 8 - mx else mx - 23));
    };
    var g = Geography{ .seed = 12345, .width = width, .height = height, .depth = 1024, .sea_level = 384, .continent_count = 1, .island_count = 2, .macro_width = 32, .macro_height = 16, .owners = &owners, .coastal_distance = &distances };
    // Keep the mountain influence away from the fixed shoreline/seam probes.
    g.core_seeds[0] = .{ 16, 8 };
    g.islands[0] = .{ .id = 128, .x = 2048, .y = 512, .radius_x = 128, .radius_y = 32 };
    g.islands[1] = .{ .id = 129, .x = 0, .y = 96, .radius_x = 128, .radius_y = 32 };
    try g.prepareCoast(std.testing.allocator);
    defer g.coast_field.deinit(std.testing.allocator);
    var checked: usize = 0;
    var shores: usize = 0;
    var islands: usize = 0;
    var seams: usize = 0;
    for (0..height / 7) |row| {
        const y: u32 = @intCast(row * 7);
        for (0..width / 11) |column| {
            const x: i64 = @intCast(column * 11);
            try expectDesertNeighbors(&g, x, y, &checked, &shores, &islands);
        }
        try expectDesertNeighbors(&g, width - 1, y, &checked, &shores, &islands);
        const a = g.at(.desert, width - 1, y);
        if (!a.water_present) seams += 1;
        try std.testing.expectEqualDeep(a, g.at(.desert, -1, y));
    }
    // Exhaust the most elongated permitted island profile, including its narrow tips.
    for (64..129) |y| for (0..257) |dx| {
        const x: i64 = @as(i64, @intCast(dx)) - 128;
        try expectDesertNeighbors(&g, x, @intCast(y), &checked, &shores, &islands);
    };
    try std.testing.expect(checked > 10000 and shores > 100 and islands > 100 and seams > 100);

    const climate = environment.ClimateField{ .seed = hash.stream(12345, .climate, 0), .width = width, .height = height, .displacement = 76 };
    for (0..16) |column| {
        const x: i64 = @intCast(column * 32);
        const boundaries = climate.boundaries(x);
        for ([_]u32{ boundaries[2], boundaries[3] }) |boundary| {
            const before = g.atWithClimate(climate, x, boundary - 1);
            const after = g.atWithClimate(climate, x, boundary);
            try std.testing.expect(!before.water_present and !after.water_present);
            try std.testing.expectEqual(@as(u16, 0), before.mountain_strength);
            try std.testing.expectEqual(@as(u16, 0), after.mountain_strength);
            try std.testing.expect(@abs(@as(i64, before.terrain_height) - after.terrain_height) <= 1);
        }
    }
}

fn expectDesertNeighbors(g: *const Geography, x: i64, y: u32, checked: *usize, shores: *usize, islands: *usize) !void {
    const a = g.at(.desert, x, y);
    if (a.water_present or a.mountain_strength != 0) {
        try std.testing.expectEqual(@as(?environment.DesertBiome, null), a.desert_biome);
        return;
    }
    try std.testing.expect(a.desert_biome != null);
    try std.testing.expectEqual(environment.SurfaceCover.sand, a.surface_cover);
    for ([_][2]u32{ .{ 1, 0 }, .{ 0, 1 } }) |offset| {
        if (y + offset[1] >= g.height) continue;
        const b = g.at(.desert, x + offset[0], y + offset[1]);
        if (b.water_present or b.mountain_strength != 0) continue;
        try std.testing.expect(@abs(@as(i64, a.terrain_height) - b.terrain_height) <= 1);
        checked.* += 1;
        shores.* += @intFromBool(a.coast_distance < 96);
        islands.* += @intFromBool(a.landmass_id >= 128);
    }
}

test "generated desert upper mountains expose rock while lowlands and gentle feet retain sand" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    var prepared = try (generator.WorldGenerator{ .natural = .{ .seed = 12345 } }).prepare(std.testing.allocator, &layout);
    defer prepared.deinit(std.testing.allocator);
    const g = &prepared.kind.natural.geography;
    var biomes: [2]bool = @splat(false);
    var rock_seen = false;
    for (g.owners, 0..) |owner, i| {
        if (owner == 0) continue;
        const x: u32 = @intCast(i % g.macro_width * 128 + 64);
        const y: u32 = @intCast(i / g.macro_width * 128 + 64);
        const e = prepared.columnEnvironmentAt(x, y);
        if (e.climate != .desert or e.water_present) {
            try std.testing.expectEqual(@as(?environment.DesertBiome, null), e.desert_biome);
            continue;
        }
        if (e.surface_cover == .rock) {
            try std.testing.expectEqual(@as(?environment.DesertBiome, null), e.desert_biome);
            const top = prepared.referenceMaterialAt(x, y, e.terrain_height - 1);
            try std.testing.expect(top != .sand and !top.isEarth());
            rock_seen = rock_seen or top == .stone;
        } else if (e.desert_biome) |biome| {
            biomes[@intFromEnum(biome)] = true;
            try std.testing.expectEqual(environment.SurfaceCover.sand, e.surface_cover);
            try std.testing.expectEqual(engine.voxel_chunk.BlockType.sand, prepared.referenceMaterialAt(x, y, e.terrain_height - 1));
        }
        if (rock_seen and biomes[0] and biomes[1]) break;
    }
    try std.testing.expect(rock_seen and biomes[0] and biomes[1]);
}

const Fixture = struct {
    const width = 16;
    const height = 10;
    columns: [width * height]diagnostics.Column = @splat(.{ .terrain_height = 3, .sea_level = 4 }),
    fn put(self: *Fixture, x: usize, y: usize, owner: u8, core: bool) void {
        self.columns[y * width + x] = .{ .terrain_height = 5, .sea_level = 4, .owner = owner, .core = core };
    }
    fn grid(self: *const Fixture) diagnostics.TopologyGrid {
        return .{ .width = width, .height = height, .columns = &self.columns };
    }
};

test "final-column graph rejects diagonal-only lobes and unchanged-owner orphan fragments" {
    var f: Fixture = .{};
    f.put(3, 3, 1, true);
    f.put(4, 4, 1, false);
    try std.testing.expectError(error.DisconnectedOwner, diagnostics.validateTopology(std.testing.allocator, f.grid()));
    f.put(4, 3, 1, false);
    _ = try diagnostics.validateTopology(std.testing.allocator, f.grid());
    f.columns[3 * Fixture.width + 4].terrain_height = 3;
    try std.testing.expectError(error.DisconnectedOwner, diagnostics.validateTopology(std.testing.allocator, f.grid()));
}

test "minimum neck retains its protected cardinal path under maximal coast erosion" {
    var f: Fixture = .{};
    for (2..6) |y| for (2..5) |x| f.put(x, y, 1, x == 2 and y == 2);
    for (2..6) |y| for (10..13) |x| f.put(x, y, 1, false);
    for (5..10) |x| for (3..5) |y| f.put(x, y, 1, false);
    // Maximal allowed displacement removes one coastal row; the reserved row survives.
    for (5..10) |x| f.columns[4 * Fixture.width + x].terrain_height = 3;
    _ = try diagnostics.validateTopology(std.testing.allocator, f.grid());
    // A displacement that cuts the protected row must fail with owner labels intact.
    f.columns[3 * Fixture.width + 7].terrain_height = 3;
    try std.testing.expectError(error.DisconnectedOwner, diagnostics.validateTopology(std.testing.allocator, f.grid()));
}

test "a seam-crossing island counts once while opposite Y edges remain disconnected" {
    var f: Fixture = .{};
    f.put(15, 4, 128, false);
    f.put(0, 4, 128, false);
    f.put(1, 4, 128, false);
    const report = try diagnostics.validateTopology(std.testing.allocator, f.grid());
    try std.testing.expectEqual(@as(usize, 1), report.islands);
    try std.testing.expectEqual(@as(usize, 1), report.components);
    f.put(8, 0, 129, false);
    f.put(8, 9, 129, false);
    try std.testing.expectError(error.DisconnectedOwner, diagnostics.validateTopology(std.testing.allocator, f.grid()));
}

test "two protected mainland gaps reject diagonal clearance loss forced bridges and island chains" {
    var f: Fixture = .{};
    f.put(2, 4, 1, true);
    f.put(12, 4, 2, true);
    f.put(7, 4, 128, false);
    const control = try diagnostics.validateTopology(std.testing.allocator, f.grid());
    try std.testing.expectEqual(@as(usize, 2), control.mainlands);
    try std.testing.expectEqual(@as(usize, 1), control.islands);
    var diagonal = f;
    diagonal.put(3, 5, 129, false);
    try std.testing.expectError(error.WaterGapBreached, diagnostics.validateTopology(std.testing.allocator, diagonal.grid()));
    var bridge = f;
    for (3..12) |x| bridge.put(x, 4, 128, false);
    try std.testing.expectError(error.MergedOwners, diagnostics.validateTopology(std.testing.allocator, bridge.grid()));
    var chain = f;
    chain.put(8, 4, 129, false);
    try std.testing.expectError(error.MergedOwners, diagnostics.validateTopology(std.testing.allocator, chain.grid()));
    var protected = f;
    protected.columns[4 * Fixture.width + 8].protected_water = true;
    protected.put(8, 4, 128, false);
    protected.columns[4 * Fixture.width + 8].protected_water = true;
    try std.testing.expectError(error.ProtectedWaterLost, diagnostics.validateTopology(std.testing.allocator, protected.grid()));
}

test "actual refined geography columns retain protected core and seam-island membership" {
    const a = std.testing.allocator;
    const width = 512;
    const height = 512;
    var owners = [_]u8{0} ** 16;
    var coast = [_]u16{0} ** 16;
    owners[1 * 4 + 1] = 1;
    owners[1 * 4 + 2] = 1;
    owners[2 * 4 + 1] = 1;
    owners[2 * 4 + 2] = 1;
    for (owners, 0..) |owner, i| coast[i] = if (owner == 0) 0 else 1;
    var geography: Geography = .{ .seed = 12345, .width = width, .height = height, .depth = 128, .sea_level = 48, .continent_count = 1, .island_count = 1, .macro_width = 4, .macro_height = 4, .owners = &owners, .coastal_distance = &coast };
    try geography.prepareCoast(a);
    defer geography.coast_field.deinit(a);
    geography.core_seeds[0] = .{ 1, 1 };
    geography.islands[0] = .{ .id = 128, .x = 0, .y = 64, .radius_x = 24, .radius_y = 20 };
    const columns = try a.alloc(diagnostics.Column, width * height);
    defer a.free(columns);
    for (0..height) |y| for (0..width) |x| {
        const e = geography.at(.temperate, @intCast(x), @intCast(y));
        columns[y * width + x] = .{
            .terrain_height = e.terrain_height,
            .sea_level = e.sea_level,
            .owner = if (e.landmass_id >= 128) e.landmass_id else owners[(y / 128) * 4 + x / 128],
            .core = x == 192 and y == 192,
        };
        try std.testing.expectEqualDeep(e, geography.at(.temperate, @as(i64, @intCast(x)) - width, @intCast(y)));
    };
    const report = try diagnostics.validateTopology(a, .{ .width = width, .height = height, .columns = columns });
    try std.testing.expectEqual(@as(usize, 1), report.mainlands);
    try std.testing.expectEqual(@as(usize, 1), report.islands);
    // Refinement may not relabel a detached mainland piece as another island.
    for (128..384) |y| columns[y * width + 256].terrain_height = 47;
    try std.testing.expectError(error.DisconnectedOwner, diagnostics.validateTopology(a, .{ .width = width, .height = height, .columns = columns }));
}

test "seeded coarse growth retains every final column in its protected component" {
    const a = std.testing.allocator;
    const width = 2048;
    const height = 2048;
    const columns = try a.alloc(diagnostics.Column, width * height);
    defer a.free(columns);
    for ([_]u64{ 12345, 87 }) |seed| {
        var geography: ?Geography = null;
        for (0..8) |attempt| {
            geography = Geography.init(a, hash.stream(seed, .continents, @intCast(attempt)), .{ width, height, 128 }, .{ .island_count = 1 }) catch |err| switch (err) {
                error.TopologyConflict, error.RequiredFeaturePlacement => continue,
                error.OutOfMemory => return err,
            };
            break;
        }
        try std.testing.expect(geography != null);
        defer geography.?.deinit(a);
        const g = &geography.?;
        for (0..height) |y| for (0..width) |x| {
            const land = g.landAt(@intCast(x), @intCast(y));
            const macro_owner = g.owners[(y / 128) * g.macro_width + x / 128];
            const owner = if (land.id >= 128) land.id else macro_owner;
            const core = if (owner > 0 and owner < 128) g.core_seeds[owner - 1] else [2]u32{ width, height };
            columns[y * width + x] = .{
                .terrain_height = if (land.id != 0) 5 else 3,
                .sea_level = 4,
                .owner = owner,
                .core = x == core[0] * 128 + 64 and y == core[1] * 128 + 64,
            };
        };
        const report = try diagnostics.validateTopology(a, .{ .width = width, .height = height, .columns = columns });
        try std.testing.expectEqual(@as(usize, g.continent_count), report.mainlands);
        try std.testing.expectEqual(@as(usize, 1), report.islands);
    }
}

test "invalid natural settings precede allocation and never consume candidate attempts" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var report: generator.PreparationReport = .{};
    try std.testing.expectError(error.InvalidLayout, generator.WorldGenerator.prepareWithReport(.{ .natural = .{ .seed = 12345 } }, failing.allocator(), &layout, &report));
    try std.testing.expectEqual(@as(u8, 0), report.attempts_started);
    try std.testing.expectEqual(.invalid_configuration, report.category);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "geography accounting matches exact allocation peak retained bytes and request count" {
    const dimensions = [3]u32{ 2048, 1024, 32 };
    const cells = Geography.macroCellCount(dimensions);
    const peak = comptime Geography.preparationPeakBytes(Geography.macroCellCount(dimensions));
    var storage: [peak]u8 align(@alignOf(u32)) = undefined;
    var short = std.heap.FixedBufferAllocator.init(storage[0 .. storage.len - 1]);
    const seed = hash.stream(12345, .continents, 0);
    const size = [3]u32{ 65536, 32768, 1024 };
    try std.testing.expectError(error.OutOfMemory, Geography.init(short.allocator(), seed, size, .{}));

    var exact = std.heap.FixedBufferAllocator.init(&storage);
    var counted = std.testing.FailingAllocator.init(exact.allocator(), .{});
    var geography = try Geography.init(counted.allocator(), seed, size, .{});
    try std.testing.expectEqual(Geography.preparation_allocation_count, counted.alloc_index);
    try std.testing.expectEqual(Geography.retainedBytes(cells), counted.allocated_bytes - counted.freed_bytes);
    try std.testing.expectEqual(Geography.retainedBytes(cells), exact.end_index);
    try std.testing.expectEqual(@as(u64, cells) * 134 + @import("generation_mountains.zig").Mountains.preparationWorkBound(cells), Geography.preparationWorkBound(cells));
    geography.deinit(counted.allocator());
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test "direct and wrapped natural preflight have identical reports before allocation" {
    const Case = struct {
        dimensions: [3]u32 = .{ 2048, 1024, 32 },
        settings: generator.NaturalSettings = .{},
        expected: anyerror,
        reason: preparation.FailureReason,
    };
    for ([_]Case{
        .{ .dimensions = .{ 4, 4, 4 }, .expected = error.InvalidLayout, .reason = .invalid_layout },
        .{ .settings = .{ .climate_displacement = 4096 }, .expected = error.InvalidClimateWidths, .reason = .invalid_climate_widths },
        .{ .settings = .{ .island_count = 0 }, .expected = error.InvalidCoastBounds, .reason = .invalid_coast_bounds },
        .{ .settings = .{ .feature_index_capacity = 0 }, .expected = error.InfeasibleCapacity, .reason = .infeasible_capacity },
        .{ .dimensions = .{ 8192, 4096, 4 }, .expected = error.InfeasibleCapacity, .reason = .infeasible_capacity },
        .{ .expected = error.MemoryBudgetExceeded, .reason = .memory_budget_exceeded },
    }) |case| {
        const layout = try engine.WorldLayout.init(.{ .size_in_chunks = case.dimensions });
        const seed = 98765;
        const natural = generator.WorldGenerator{ .natural = .{ .seed = seed, .settings = case.settings } };
        var direct_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var wrapped_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var direct: generator.PreparationReport = .{ .profile = .flat, .seed = 1, .attempts_started = 8, .selected_attempt = 7, .category = .seed_rejected };
        var wrapped = direct;
        // Invalid settings retain precedence over a simultaneously exhausted budget.
        const options: generator.PrepareOptions = .{ .memory_budget = 0 };
        try std.testing.expectError(case.expected, NaturalWorld.initWithOptions(direct_allocator.allocator(), &layout, seed, case.settings, &direct, options));
        try std.testing.expectError(case.expected, natural.prepareWithReportOptions(wrapped_allocator.allocator(), &layout, &wrapped, options));
        try std.testing.expectEqualDeep(direct, wrapped);
        try std.testing.expectEqual(case.reason, direct.reason);
        try std.testing.expectEqual(seed, direct.seed);
        try std.testing.expectEqual(.natural, direct.profile);
        try std.testing.expectEqual(.preflight, direct.stage);
        try std.testing.expectEqual(@as(u8, 0), direct.attempts_started);
        try std.testing.expectEqual(@as(?u8, null), direct.selected_attempt);
        try std.testing.expectEqual(@as(usize, 0), direct_allocator.alloc_index);
        try std.testing.expectEqual(@as(usize, 0), wrapped_allocator.alloc_index);
        if (case.expected == error.MemoryBudgetExceeded) {
            try std.testing.expectEqual(.preparation_aborted, direct.category);
            try std.testing.expectEqual(@sizeOf(NaturalWorld) + Geography.preparationPeakBytes(Geography.macroCellCount(case.dimensions)), direct.peak_owned_bytes);
            try std.testing.expectEqual(direct.peak_owned_bytes, direct.observed);
            try std.testing.expectEqual(@as(u64, 0), direct.limit);
        } else {
            try std.testing.expectEqual(.invalid_configuration, direct.category);
            try std.testing.expectEqual(@as(usize, 0), direct.peak_owned_bytes);
        }
    }
}

test "direct and wrapped natural candidate failures retain identical attempts and cleanup" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    const seed = 12345;
    const natural = generator.WorldGenerator{ .natural = .{ .seed = seed } };
    const Case = struct { options: generator.PrepareOptions, expected: anyerror };
    for ([_]Case{
        .{ .options = .{ .is_cancelled = &cancelled }, .expected = error.Cancelled },
        .{ .options = .{ .work_budget = 0 }, .expected = error.WorkBudgetExceeded },
        .{ .options = .{ .reject_first_candidates = 8, .injected_rejection = .deposit_validity }, .expected = error.SeedRejected },
        .{ .options = .{ .reject_first_candidates = 2, .abort_at_attempt = 2, .injected_abort = .internal_invariant_failure }, .expected = error.InternalInvariantFailure },
    }) |case| {
        var direct: generator.PreparationReport = .{};
        var wrapped: generator.PreparationReport = .{};
        try std.testing.expectError(case.expected, NaturalWorld.initWithOptions(std.testing.allocator, &layout, seed, .{}, &direct, case.options));
        try std.testing.expectError(case.expected, natural.prepareWithReportOptions(std.testing.allocator, &layout, &wrapped, case.options));
        try std.testing.expectEqualDeep(direct, wrapped);
    }
    // Fail every Geography allocation, offsetting the wrapper's owned object.
    for (0..Geography.preparation_allocation_count) |allocation| {
        var direct_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = allocation });
        var wrapped_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = allocation + 1 });
        var direct: generator.PreparationReport = .{};
        var wrapped: generator.PreparationReport = .{};
        try std.testing.expectError(error.OutOfMemory, NaturalWorld.initWithOptions(direct_allocator.allocator(), &layout, seed, .{}, &direct, .{}));
        try std.testing.expectError(error.OutOfMemory, natural.prepareWithReportOptions(wrapped_allocator.allocator(), &layout, &wrapped, .{}));
        try std.testing.expectEqualDeep(direct, wrapped);
        try std.testing.expectEqual(.allocation_failed, direct.reason);
        try std.testing.expectEqual(.geography, direct.stage);
        try std.testing.expectEqual(@as(u8, 1), direct.attempts_started);
        try std.testing.expectEqual(direct_allocator.allocated_bytes, direct_allocator.freed_bytes);
        try std.testing.expectEqual(wrapped_allocator.allocated_bytes, wrapped_allocator.freed_bytes);
    }
}

test "direct and wrapped natural worlds reject one byte below the peak before allocation" {
    const dimensions = [3]u32{ 2048, 1024, 32 };
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = dimensions });
    const peak = @sizeOf(NaturalWorld) + Geography.preparationPeakBytes(Geography.macroCellCount(dimensions));
    const options: generator.PrepareOptions = .{ .memory_budget = peak - 1 };
    const seed = 12365;
    var direct_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var wrapped_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var direct: generator.PreparationReport = .{};
    var wrapped: generator.PreparationReport = .{};
    try std.testing.expectError(error.MemoryBudgetExceeded, NaturalWorld.initWithOptions(direct_allocator.allocator(), &layout, seed, .{}, &direct, options));
    try std.testing.expectError(error.MemoryBudgetExceeded, generator.WorldGenerator.prepareWithReportOptions(.{ .natural = .{ .seed = seed } }, wrapped_allocator.allocator(), &layout, &wrapped, options));
    try std.testing.expectEqualDeep(direct, wrapped);
    try std.testing.expectEqual(.memory_budget_exceeded, direct.reason);
    try std.testing.expectEqual(peak, direct.peak_owned_bytes);
    try std.testing.expectEqual(peak, direct.observed);
    try std.testing.expectEqual(options.memory_budget, direct.limit);
    try std.testing.expectEqual(@as(u8, 0), direct.attempts_started);
    try std.testing.expectEqual(@as(usize, 0), direct_allocator.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), wrapped_allocator.alloc_index);
}

test "direct and wrapped accepted natural worlds publish identical reports and fingerprints" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    const seed = 12365;
    const options: generator.PrepareOptions = .{ .memory_budget = @sizeOf(NaturalWorld) + Geography.preparationPeakBytes(Geography.macroCellCount(.{ 2048, 1024, 32 })), .reject_first_candidates = 1 };
    var direct_report: generator.PreparationReport = .{};
    var wrapped_report: generator.PreparationReport = .{};
    var direct = try NaturalWorld.initWithOptions(a, &layout, seed, .{}, &direct_report, options);
    defer direct.deinit(a);
    var wrapped = try generator.WorldGenerator.prepareWithReportOptions(.{ .natural = .{ .seed = seed } }, a, &layout, &wrapped_report, options);
    defer wrapped.deinit(a);
    try std.testing.expectEqualDeep(direct_report, wrapped_report);
    try std.testing.expectEqualDeep(direct_report, direct.report);
    try std.testing.expectEqualDeep(wrapped_report, wrapped.kind.natural.report);
    try std.testing.expectEqual(.complete, direct_report.stage);
    try std.testing.expectEqual(options.memory_budget, direct_report.peak_owned_bytes);
    try std.testing.expect(direct_report.candidates_rejected > 0);
    try std.testing.expectEqualSlices(u8, &direct.fingerprint(), &wrapped.kind.natural.fingerprint());
}

test "playable floor hash uses canonical X and independent seeded layer streams" {
    for (0..1024) |i| {
        const x: i64 = @intCast(i);
        try std.testing.expectEqual(hash.deeprockThickness(12345, x, 999, 65536), hash.deeprockThickness(12345, x - 65536, 999, 65536));
    }
}

test "vanished island is detected from intended ownership even without a protected mainland core" {
    var f: Fixture = .{};
    f.put(3, 3, 128, false);
    _ = try diagnostics.validateTopology(std.testing.allocator, f.grid());
    f.columns[3 * Fixture.width + 3].terrain_height = 3;
    try std.testing.expectError(error.MissingOwner, diagnostics.validateTopology(std.testing.allocator, f.grid()));
}

fn cancelled(_: ?*anyopaque) bool {
    return true;
}

test "preparation classifies terminal bounds cancellation and allocation without retry" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    const natural = generator.WorldGenerator{ .natural = .{ .seed = 12345 } };
    var report: generator.PreparationReport = .{};
    try std.testing.expectError(error.MemoryBudgetExceeded, natural.prepareWithReportOptions(a, &layout, &report, .{ .memory_budget = 1 }));
    try std.testing.expectEqual(.preparation_aborted, report.category);
    try std.testing.expectEqual(.memory_budget_exceeded, report.reason);
    try std.testing.expectEqual(@as(u8, 0), report.attempts_started);
    try std.testing.expect(report.observed > report.limit);
    var no_memory = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.MemoryBudgetExceeded, natural.prepareWithReportOptions(no_memory.allocator(), &layout, &report, .{ .memory_budget = 1 }));
    try std.testing.expectEqual(@as(usize, 0), no_memory.alloc_index);
    try std.testing.expectError(error.WorkBudgetExceeded, natural.prepareWithReportOptions(a, &layout, &report, .{ .work_budget = 0 }));
    try std.testing.expectEqual(.work_budget_exceeded, report.reason);
    try std.testing.expectEqual(@as(u8, 1), report.attempts_started);
    try std.testing.expectEqual(@as(u8, 0), report.candidates_rejected);
    try std.testing.expect(report.observed > report.limit);
    try std.testing.expectError(error.Cancelled, natural.prepareWithReportOptions(a, &layout, &report, .{ .is_cancelled = &cancelled }));
    try std.testing.expectEqual(.cancelled, report.reason);
    try std.testing.expectEqual(@as(u8, 0), report.attempts_started);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, natural.prepareWithReport(failing.allocator(), &layout, &report));
    try std.testing.expectEqual(.allocation_failed, report.reason);
    try std.testing.expectEqual(.preparation_aborted, report.category);
    try std.testing.expectEqual(@as(u8, 0), report.attempts_started);
    try std.testing.expectEqual(@as(u64, 12345), report.seed);
    try std.testing.expectEqual(@as(u32, 2), report.generator_id);
    try std.testing.expectEqual(@as(u32, 1), report.generator_version);
    try std.testing.expectEqual(@sizeOf(NaturalWorld) + Geography.preparationPeakBytes(Geography.macroCellCount(.{ 2048, 1024, 32 })), report.peak_owned_bytes);
}

test "candidate rejection consumes at most eight deterministic attempts and terminal injection stops immediately" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    const natural = generator.WorldGenerator{ .natural = .{ .seed = 12345 } };
    var first: generator.PreparationReport = .{};
    var second: generator.PreparationReport = .{};
    const options = generator.PrepareOptions{ .reject_first_candidates = 8, .injected_rejection = .deposit_validity };
    try std.testing.expectError(error.SeedRejected, natural.prepareWithReportOptions(a, &layout, &first, options));
    try std.testing.expectError(error.SeedRejected, natural.prepareWithReportOptions(a, &layout, &second, options));
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectEqual(@as(u8, 8), first.attempts_started);
    try std.testing.expectEqual(@as(u8, 8), first.candidates_rejected);
    try std.testing.expect(first.work_units <= options.work_budget);
    try std.testing.expectEqual(.seed_rejected, first.category);
    try std.testing.expectEqual(.deposit_validity, first.reason);
    try std.testing.expectEqual(@as(?u8, null), first.selected_attempt);
    for (first.rejections) |reason| try std.testing.expectEqual(.deposit_validity, reason);
    try std.testing.expectError(error.InternalInvariantFailure, natural.prepareWithReportOptions(a, &layout, &first, .{ .reject_first_candidates = 2, .abort_at_attempt = 2, .injected_abort = .internal_invariant_failure }));
    try std.testing.expectEqual(@as(u8, 3), first.attempts_started);
    try std.testing.expectEqual(@as(u8, 2), first.candidates_rejected);
    try std.testing.expectEqual(.preparation_aborted, first.category);
    try std.testing.expectEqual(.internal_invariant_failure, first.reason);
    try std.testing.expectEqual(.geography, first.stage);
}

fn expectReference(prepared: *const generator.PreparedWorldGenerator, coords: @Vector(2, i32), z: i32) !void {
    const column = generator.ColumnGenerator.init(prepared, coords);
    var actual = try column.tryGenerateChunk(std.testing.allocator, z);
    defer actual.deinit(std.testing.allocator);
    const data = actual.content.toData();
    var reference = @import("world_chunk_data.zig").WorldChunkData.initEmpty();
    for (0..32) |y| for (0..32) |x| for (0..32) |local_z| {
        const wx = @as(i64, coords[0]) * 32 + @as(i64, @intCast(x));
        const wy = @as(u32, @intCast(coords[1])) * 32 + @as(u32, @intCast(y));
        const wz = @as(u32, @intCast(z)) * 32 + @as(u32, @intCast(local_z));
        reference.blocks[local_z][y][x] = prepared.referenceMaterialAt(wx, wy, wz);
        try std.testing.expectEqual(reference.blocks[local_z][y][x], prepared.referenceMaterialAt(wx - prepared.layout.size_in_blocks[0], wy, wz));
    };
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&reference.blocks), std.mem.asBytes(&data.blocks));
    try std.testing.expectEqualDeep(@import("boundary_mask.zig").extract(&reference), actual.boundaries);
    try std.testing.expectEqual(reference.countSolidBlocks(), actual.solid_block_count);
}

test "accepted natural climate maps material oracle and regenerated derived data agree at world features" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    var report: generator.PreparationReport = .{};
    var prepared = try generator.WorldGenerator.prepareWithReport(.{ .natural = .{ .seed = 12345 } }, a, &layout, &report);
    defer prepared.deinit(a);
    try std.testing.expectEqual(.complete, report.stage);
    try std.testing.expectEqual(.none, report.category);
    try std.testing.expect(report.attempts_started <= 8);
    const natural = prepared.kind.natural;
    var transition_seen = false;
    for (natural.climate.boundaries(16)) |boundary| {
        const coords = @Vector(2, i32){ 0, @intCast(boundary / 32) };
        var map: @import("world_environment.zig").ClimateMap = undefined;
        prepared.fillClimateMap(coords, &map);
        for (0..32) |y| for (0..32) |x| {
            const wx: i64 = @intCast(x);
            const wy: u32 = @as(u32, @intCast(coords[1])) * 32 + @as(u32, @intCast(y));
            try std.testing.expectEqual(prepared.climateAt(wx, wy), map[y][x]);
            try std.testing.expectEqual(prepared.climateAt(wx - layout.size_in_blocks[0], wy), map[y][x]);
            if (map[y][x] != map[0][0]) transition_seen = true;
        };
    }
    try std.testing.expect(transition_seen);
    const start = prepared.firstStart().?;
    const island = natural.geography.islands[0];
    const deposit = natural.deposits.items[0];
    var forest: ?[2]u32 = null;
    for (natural.geography.owners, 0..) |owner, index| {
        if (owner == 0) continue;
        const point = [2]u32{ @intCast(index % natural.geography.macro_width * 128 + 64), @intCast(index / natural.geography.macro_width * 128 + 64) };
        if (prepared.columnEnvironmentAt(point[0], point[1]).vegetation != .forest) continue;
        const column = generator.ColumnGenerator.init(&prepared, .{ @intCast(point[0] / 32), @intCast(point[1] / 32) });
        if (column.column.natural.tree_count == 0) continue;
        forest = point;
        break;
    }
    try std.testing.expect(forest != null);
    const sites = [_][2]u32{ .{ start[0], start[1] }, .{ @intCast(island.x), island.y }, .{ 0, 0 }, .{ layout.size_in_blocks[0] - 1, layout.size_in_blocks[1] / 2 }, .{ deposit.center[0], deposit.center[1] }, forest.? };
    try expectReference(&prepared, .{ @intCast(deposit.center[0] / 32), @intCast(deposit.center[1] / 32) }, @intCast(deposit.center[2] / 32));
    var hashes: [sites.len][32]u8 = undefined;
    const benchmark = @import("generation_benchmark.zig");
    for (sites, 0..) |site, i| {
        const coords = @Vector(2, i32){ @intCast(site[0] / 32), @intCast(site[1] / 32) };
        const e = prepared.columnEnvironmentAt(site[0], site[1]);
        const surface_z: i32 = @intCast(@max(e.terrain_height, e.sea_level) / 32);
        try expectReference(&prepared, coords, 0);
        try expectReference(&prepared, coords, surface_z);
        const column = generator.ColumnGenerator.init(&prepared, coords);
        hashes[i] = (try benchmark.snapshot(a, &column, surface_z, true)).digest;
    }
    var reopened = try generator.WorldGenerator.prepare(.{ .natural = .{ .seed = 12345 } }, a, &layout);
    defer reopened.deinit(a);
    try std.testing.expectEqualSlices(u8, &natural.fingerprint(), &reopened.kind.natural.fingerprint());
    var i: usize = sites.len;
    while (i > 0) {
        i -= 1;
        const site = sites[i];
        const coords = @Vector(2, i32){ @intCast(site[0] / 32), @intCast(site[1] / 32) };
        const e = reopened.columnEnvironmentAt(site[0], site[1]);
        const surface_z: i32 = @intCast(@max(e.terrain_height, e.sea_level) / 32);
        const column = generator.ColumnGenerator.init(&reopened, coords);
        try std.testing.expectEqualSlices(u8, &hashes[i], &(try benchmark.snapshot(a, &column, surface_z, true)).digest);
    }
}

test "fixed seed mountain summits passes and gorges survive oracle generation and restart in all supported profiles" {
    const a = std.testing.allocator;
    const benchmark = @import("generation_benchmark.zig");
    for ([_][]const u8{ "half", "default", "double" }) |profile| {
        const dimensions = try diagnostics.profileDimensions(profile);
        const layout = try engine.WorldLayout.init(.{ .size_in_chunks = dimensions });
        for ([_]u64{ 12345, 0, 87 }) |seed| {
            var prepared = try generator.WorldGenerator.prepare(.{ .natural = .{ .seed = seed } }, a, &layout);
            defer prepared.deinit(a);
            const report = diagnostics.sampleMountains(&prepared);
            try std.testing.expectEqual(layout.size_in_blocks[2] / 2, report.sea_level);
            try std.testing.expectEqual(@as(u32, @intCast(@as(u64, layout.size_in_blocks[2]) * 95 / 100)), report.max_summit_height.?);
            try std.testing.expect(report.high_summits_at_95_percent > 0 and report.rock_summits > 0);
            try std.testing.expect(report.pointed_summits > 0 and report.asymmetric_peaks > 0);
            try std.testing.expect(report.max_width_blocks.? > report.min_width_blocks.?);
            try std.testing.expect(report.connected_passes > 0);
            try std.testing.expect(report.pass != null and report.gorge != null);
            try std.testing.expect(report.pass.?.connected and report.gorge.?.connected);
            try std.testing.expect(report.pass.?.wall_relief > 0 and report.gorge.?.wall_relief > 0);
            try std.testing.expect(report.column_probes < 130000);
            const sites = [_]diagnostics.MountainSite{ report.summit.?, report.pass.?.site, report.gorge.?.site };
            var digests: [sites.len][32]u8 = undefined;
            for (sites, 0..) |site, i| {
                const e = prepared.columnEnvironmentAt(site.block[0], site.block[1]);
                try std.testing.expectEqual(report.sea_level, e.sea_level);
                try std.testing.expect(!e.water_present and e.mountain_strength > 0);
                try std.testing.expectEqualDeep(e, prepared.columnEnvironmentAt(@as(i64, site.block[0]) - layout.size_in_blocks[0], site.block[1]));
                const coords = @Vector(2, i32){ @intCast(site.block[0] / 32), @intCast(site.block[1] / 32) };
                const surface_z: i32 = @intCast((e.terrain_height - 1) / 32);
                try expectReference(&prepared, coords, surface_z);
                if (e.terrain_height % 32 == 0) try expectReference(&prepared, coords, surface_z + 1);
                const column = generator.ColumnGenerator.init(&prepared, coords);
                digests[i] = (try benchmark.snapshot(a, &column, surface_z, true)).digest;
            }
            var reopened = try generator.WorldGenerator.prepare(.{ .natural = .{ .seed = seed } }, a, &layout);
            defer reopened.deinit(a);
            try std.testing.expectEqualDeep(report, diagnostics.sampleMountains(&reopened));
            try std.testing.expectEqualSlices(u8, &prepared.kind.natural.fingerprint(), &reopened.kind.natural.fingerprint());
            var i: usize = sites.len;
            while (i > 0) {
                i -= 1;
                const site = sites[i];
                const column = generator.ColumnGenerator.init(&reopened, .{ @intCast(site.block[0] / 32), @intCast(site.block[1] / 32) });
                const z: i32 = @intCast((site.height - 1) / 32);
                try std.testing.expectEqualSlices(u8, &digests[i], &(try benchmark.snapshot(a, &column, z, true)).digest);
            }
        }
    }
}

fn suitableBeachSite(prepared: *const generator.PreparedWorldGenerator, site: [2]u32) bool {
    const shore = prepared.columnEnvironmentAt(site[0], site[1]);
    if (shore.water_present or shore.surface_cover != .soil or shore.coast_distance > 3 or shore.terrain_height > shore.sea_level + 3) return false;
    for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |offset| {
        const near = prepared.columnEnvironmentAt(@as(i64, site[0]) + offset[0], @intCast(@as(i64, site[1]) + offset[1]));
        if (@abs(@as(i64, near.terrain_height) - shore.terrain_height) > 2) return false;
    }
    return true;
}

test "optional beaches replace shallow shore cover without changing geography climate or starter sand" {
    const a = std.testing.allocator;
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2048, 1024, 32 } });
    var plain = try generator.WorldGenerator.prepare(.{ .natural = .{ .seed = 12345 } }, a, &layout);
    defer plain.deinit(a);
    var beach = try generator.WorldGenerator.prepare(.{ .natural = .{ .seed = 12345, .settings = .{ .beaches = true } } }, a, &layout);
    defer beach.deinit(a);
    try std.testing.expectEqualDeep(plain.firstStart(), beach.firstStart());
    try std.testing.expectEqualSlices(u8, plain.kind.natural.geography.owners, beach.kind.natural.geography.owners);
    const geography = &plain.kind.natural.geography;
    var mainland_site: ?[2]u32 = null;
    mainland: for (geography.owners, 0..) |owner, i| {
        if (owner == 0 or geography.coastal_distance[i] != 1) continue;
        const x: u32 = @intCast(i % geography.macro_width * 128);
        const y: u32 = @intCast(i / geography.macro_width * 128);
        // The bounded erosion fringe is 8–24 blocks wide. Search actual shore
        // edges so land-growth tuning cannot move this overlay fixture inland.
        for (0..32) |offset| {
            const d: u32 = @intCast(offset);
            for ([_][2]u32{ .{ x + d, y + 64 }, .{ x + 127 - d, y + 64 }, .{ x + 64, y + d }, .{ x + 64, y + 127 - d } }) |site| {
                if (!suitableBeachSite(&plain, site)) continue;
                mainland_site = site;
                break :mainland;
            }
        }
    }
    var island_site: ?[2]u32 = null;
    islands: for (geography.islands[0..geography.island_count]) |island| {
        for (2..5) |inset| for ([_]i64{ -1, 1 }) |side| {
            const site = [2]u32{ hash.wrappedX(@as(i64, island.x) + side * @as(i64, @intCast(island.radius_x - inset)), layout.size_in_blocks[0]), island.y };
            if (!suitableBeachSite(&plain, site)) continue;
            island_site = site;
            break :islands;
        };
    }
    try std.testing.expect(mainland_site != null and island_site != null);
    const sites = [_][2]u32{ mainland_site.?, island_site.? };
    for (sites) |site| {
        const before = plain.columnEnvironmentAt(site[0], site[1]);
        const after = beach.columnEnvironmentAt(site[0], site[1]);
        try std.testing.expectEqual(@import("world_environment.zig").SurfaceCover.soil, before.surface_cover);
        try std.testing.expectEqual(@import("world_environment.zig").SurfaceCover.sand, after.surface_cover);
        try std.testing.expectEqual(engine.voxel_chunk.BlockType.sand, beach.referenceMaterialAt(site[0], site[1], after.terrain_height - 1));
        try std.testing.expectEqualDeep(after, beach.columnEnvironmentAt(@as(i64, site[0]) - layout.size_in_blocks[0], site[1]));
        const coords = @Vector(2, i32){ @intCast(site[0] / 32), @intCast(site[1] / 32) };
        try expectReference(&beach, coords, @intCast(after.terrain_height / 32));
    }
    // Inspect a strip through the X seam and through each actual shore.
    for ([_][2]u32{ sites[0], sites[1], .{ 0, layout.size_in_blocks[1] / 2 } }) |site| {
        for (0..64) |offset| {
            const x = @as(i64, site[0]) + @as(i64, @intCast(offset)) - 32;
            const before = plain.columnEnvironmentAt(x, site[1]);
            var after = beach.columnEnvironmentAt(x, site[1]);
            after.surface_cover = before.surface_cover;
            try std.testing.expectEqualDeep(before, after);
        }
    }
    var starter_sand = false;
    for (plain.kind.natural.deposits.items[0..plain.kind.natural.deposits.count]) |deposit| {
        if (deposit.resource != .sand or deposit.size_class != .starter) continue;
        starter_sand = true;
        try std.testing.expectEqual(engine.voxel_chunk.BlockType.sand, plain.referenceMaterialAt(deposit.center[0], deposit.center[1], deposit.center[2]));
        try std.testing.expectEqual(engine.voxel_chunk.BlockType.sand, beach.referenceMaterialAt(deposit.center[0], deposit.center[1], deposit.center[2]));
    }
    try std.testing.expect(starter_sand);
}
