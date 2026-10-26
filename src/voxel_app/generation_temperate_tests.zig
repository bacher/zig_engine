const std = @import("std");
const env = @import("world_environment.zig");
const hash = @import("generation_hash.zig");
const Geography = @import("generation_geography.zig").Geography;
const Settings = @import("generation_settings.zig").NaturalSettings;

const profiles = [_][3]u32{
    .{ 32768, 16384, 512 },
    .{ 65536, 32768, 1024 },
    .{ 131072, 65536, 2048 },
};

/// A wrapped mainland with a wide ocean channel and two detached islands.
/// Its exact macro Manhattan distances avoid procedural-world preparation,
/// while exercising the real refinement, coast index and terrain composition.
const Fixture = struct {
    geography: Geography,

    fn init(size: [3]u32) !Fixture {
        const allocator = std.testing.allocator;
        const mw = size[0] / 128;
        const mh = size[1] / 128;
        const count = @as(usize, mw) * mh;
        const owners = try allocator.alloc(u8, count);
        errdefer allocator.free(owners);
        const distances = try allocator.alloc(u16, count);
        errdefer allocator.free(distances);
        for (0..mh) |my| for (0..mw) |mx| {
            const dry = my > 0 and my + 1 < mh and (mx < mw / 4 or mx >= 3 * mw / 4);
            owners[my * mw + mx] = if (dry) 1 else 0;
            distances[my * mw + mx] = if (dry)
                @intCast(@min(my, mh - 1 - my, if (mx < mw / 4) mw / 4 - mx else mx - 3 * mw / 4 + 1))
            else
                0;
        };
        var geography = Geography{
            .seed = hash.stream(12345, .continents, 0),
            .width = size[0],
            .height = size[1],
            .depth = size[2],
            .sea_level = size[2] / 2,
            .continent_count = 1,
            .island_count = 2,
            .macro_width = mw,
            .macro_height = mh,
            .owners = owners,
            .coastal_distance = distances,
        };
        geography.islands[0] = .{ .id = 128, .x = size[0] / 2, .y = size[1] / 4, .radius_x = 128, .radius_y = 32 };
        geography.islands[1] = .{ .id = 129, .x = 0, .y = 96, .radius_x = 128, .radius_y = 32 };
        try geography.prepareCoast(allocator);
        return .{ .geography = geography };
    }

    fn deinit(self: *Fixture) void {
        self.geography.deinit(std.testing.allocator);
    }
};

fn climateField(seed: u64, size: [3]u32, displacement: u32) env.ClimateField {
    return .{ .seed = hash.stream(seed, .climate, 0), .width = size[0], .height = size[1], .displacement = displacement };
}

test "temperate integration climate masks and displaced boundaries preserve their budgets" {
    // For named 2:1 layouts, each octave's X phase advances by an exact Q16
    // integer. Cubic/interpolation rounding costs <3 raw units per octave;
    // weighted averaging costs <1 more. Thus boundary-noise adjacent delta
    // is <42*65535/width + 8. At valid displacement <=width/40 this becomes
    // <1.15, 1.25, 1.45 blocks for the three widths. Final monotone truncation
    // therefore changes an integer climate boundary by at most two blocks.
    for (profiles) |size| {
        const maximum: u16 = @intCast((size[1] / 10 - 2) / 2);
        try (Settings{ .climate_displacement = maximum }).validate(.{ size[0] / 32, size[1] / 32, size[2] / 32 });
        for ([_]u32{ (Settings{}).climateDisplacement(size[1]), maximum }) |displacement| {
            for ([_]u64{ 0, 87, 12345 }) |seed| {
                const climate = climateField(seed, size, displacement);
                var complete_fades: usize = 0;
                for (0..1024) |i| {
                    const x: u32 = if (i == 0) size[0] - 1 else @intCast(hash.at(seed, @intCast(i), 0) % size[0]);
                    const boundaries = climate.boundaries(x);
                    const next = climate.boundaries(@as(i64, x) + 1);
                    try std.testing.expectEqualDeep(boundaries, climate.boundaries(@as(i64, x) - size[0]));
                    for (boundaries, next) |a, b| try std.testing.expect(@abs(@as(i64, a) - b) <= 2);
                    for ([_][2]u32{ .{ boundaries[1], boundaries[2] }, .{ boundaries[3], boundaries[4] } }) |belt| {
                        try std.testing.expectEqual(@as(u16, 0), climate.sample(x, belt[0] - 1).temperate_terrain);
                        try std.testing.expectEqual(@as(u16, 0), climate.sample(x, belt[0] + 256).temperate_terrain);
                        try std.testing.expectEqual(@as(u16, 0), climate.sample(x, belt[1] - 1 - 256).temperate_terrain);
                        if (belt[1] - belt[0] > 3584) {
                            complete_fades += 1;
                            const before = climate.sample(x, belt[0] + 1791);
                            const full = climate.sample(x, belt[0] + 1792);
                            try std.testing.expect(before.temperate_terrain < 65535);
                            try std.testing.expectEqual(@as(u16, 65535), full.temperate_terrain);
                            try std.testing.expectEqual(@as(u16, 65535), climate.sample(x, belt[1] - 1 - 1792).temperate_terrain);
                        }
                        const a = climate.sample(x, belt[0] + 257);
                        const b = climate.sample(@as(i64, x) + 1, belt[0] + 257);
                        try std.testing.expect(a.temperate_terrain > 0);
                        try std.testing.expect(@abs(@as(i64, a.temperate_terrain) - b.temperate_terrain) <= 86);
                    }
                }
                try std.testing.expect(complete_fades > 0);
            }
        }
    }
}

const Coverage = struct {
    dry: usize = 0,
    shore: usize = 0,
    island: usize = 0,
    selector: usize = 0,
};

fn expectNeighbors(g: *const Geography, climate: ?env.ClimateField, x: i64, y: u32, counts: *Coverage) !void {
    const a = if (climate) |field| g.atWithClimate(field, x, y) else g.at(.temperate, x, y);
    const classified = !a.water_present and a.climate == .temperate and a.mountain_strength == 0;
    try std.testing.expectEqual(classified, a.temperate_landform != null);
    if (a.water_present or a.mountain_strength != 0) return;
    try std.testing.expectEqual(env.GeologyId.sedimentary, a.geology);
    if (a.climate != .desert) try std.testing.expectEqual(env.SurfaceCover.soil, a.surface_cover);
    counts.dry += 1;
    counts.shore += @intFromBool(a.coast_distance <= 32);
    counts.island += @intFromBool(a.landmass_id >= 128);
    for ([_][2]i64{ .{ x + 1, y }, .{ x, @as(i64, y) + 1 } }) |point| {
        if (point[1] >= g.height) continue;
        const b = if (climate) |field| g.atWithClimate(field, point[0], @intCast(point[1])) else g.at(.temperate, point[0], @intCast(point[1]));
        if (b.water_present or b.mountain_strength != 0) continue;
        try std.testing.expect(@abs(@as(i64, a.terrain_height) - b.terrain_height) <= 1);
        if (a.temperate_landform != null and b.temperate_landform != null and a.temperate_landform != b.temperate_landform) counts.selector += 1;
    }
}

test "temperate integration dry grades survive coast islands climate collars and the seam" {
    // Composite proof for the named profiles: the ordinary Q16 field has
    // adjacent delta <0.101, including rounding, and range [-1,51]. The pure
    // temperate field has delta <0.64 and range [8,80]. A displaced climate
    // edge moves <=2, so the 1536-block ramp changes its u16 weight by <=86.
    // Convex blending costs <0.64 + 81*86/65535 + 2/65536 <0.747 blocks.
    // Temperate weight is zero throughout the separate 256-block desert
    // collar. There the desert field's <0.491 bound, difference <=49 from
    // ordinary terrain and weight delta <=512 give <0.874 blocks. Mainland
    // shore caps change <=0.5; island /32 caps are gentler. Min/max/clamp and
    // final flooring preserve the one-block integer limit. Mountain influence
    // and submerged ocean-bottom transitions deliberately have other bounds.
    for (profiles) |size| {
        var fixture = try Fixture.init(size);
        defer fixture.deinit();
        const g = &fixture.geography;
        var counts: Coverage = .{};
        const maximum = (size[1] / 10 - 2) / 2;
        for ([_]u32{ (Settings{}).climateDisplacement(size[1]), maximum }) |displacement| {
            const climate = climateField(12345, size, displacement);
            for (0..64) |i| {
                const x: i64 = if (i == 0) size[0] - 1 else @intCast(i * size[0] / 64);
                const boundaries = climate.boundaries(x);
                for ([_][2]u32{ .{ boundaries[1], boundaries[2] }, .{ boundaries[3], boundaries[4] } }) |belt| {
                    for ([_]u32{ 0, 1, 254, 255, 256, 257, 258, 1790, 1791, 1792, 1793 }) |distance| {
                        if (distance >= belt[1] - belt[0]) continue;
                        try expectNeighbors(g, climate, x, belt[0] + distance, &counts);
                        try expectNeighbors(g, climate, x, belt[1] - 1 - distance, &counts);
                    }
                    try expectNeighbors(g, climate, x, belt[0] - 1, &counts);
                    try expectNeighbors(g, climate, x, belt[1], &counts);
                }
            }
        }
        // Sample the actual refined mainland edge, including macro corners.
        for (0..32) |row| for (0..128) |dx| {
            const y: u32 = @intCast(128 + row * (size[1] - 256) / 32);
            try expectNeighbors(g, null, @as(i64, size[0] / 4) - 128 + @as(i64, @intCast(dx)), y, &counts);
            try expectNeighbors(g, null, @as(i64, size[0] * 3 / 4) + @as(i64, @intCast(dx)), y, &counts);
        };
        for (0..128) |row| {
            const y: u32 = @intCast(128 + row * (size[1] - 256) / 128);
            try expectNeighbors(g, null, size[0] - 1, y, &counts);
            try std.testing.expectEqualDeep(g.at(.temperate, -1, y), g.at(.temperate, size[0] - 1, y));
        }
        // Exhaust both elongated island footprints and their narrow tips.
        for (g.islands[0..g.island_count]) |island| {
            for (0..65) |oy| for (0..257) |ox| {
                const x = @as(i64, island.x) + @as(i64, @intCast(ox)) - 128;
                const y: u32 = @intCast(@as(i64, island.y) + @as(i64, @intCast(oy)) - 32);
                try expectNeighbors(g, null, x, y, &counts);
            };
        }
        try std.testing.expect(counts.dry > 10000 and counts.shore > 1000 and counts.island > 1000);
    }
}

test "temperate integration forests cross landforms and mountain classification takes precedence" {
    var fixture = try Fixture.init(profiles[1]);
    defer fixture.deinit();
    const g = &fixture.geography;
    var forest = [_]usize{ 0, 0, 0 };
    var meadow = [_]usize{ 0, 0, 0 };
    var forest_crossings: usize = 0;
    var boundary_counts: Coverage = .{};
    for (0..64) |row| for (0..512) |column| {
        const x: i64 = @intCast(column * g.width / 512);
        const y: u32 = @intCast(256 + row * (g.height - 512) / 64);
        const a = g.at(.temperate, x, y);
        const landform = a.temperate_landform orelse continue;
        switch (a.vegetation) {
            .forest => forest[@intFromEnum(landform)] += 1,
            .meadow => meadow[@intFromEnum(landform)] += 1,
            else => return error.UnexpectedTemperateVegetation,
        }
        const b = g.at(.temperate, x + 128, y);
        if (b.temperate_landform == null or b.temperate_landform == a.temperate_landform) continue;
        // Locate an actual adjacent classification change, rather than merely
        // comparing two far-apart terrain labels with coincidental forests.
        var left = x;
        var right = x + 128;
        while (right - left > 1) {
            const middle = left + @divTrunc(right - left, 2);
            if (g.at(.temperate, middle, y).temperate_landform == a.temperate_landform) left = middle else right = middle;
        }
        const before = g.at(.temperate, left, y);
        const after = g.at(.temperate, right, y);
        try std.testing.expect(before.temperate_landform != null and after.temperate_landform != null and before.temperate_landform != after.temperate_landform);
        try expectNeighbors(g, null, left, y, &boundary_counts);
        forest_crossings += @intFromBool(before.vegetation == .forest and after.vegetation == .forest);
    };
    for (forest, meadow) |f, m| try std.testing.expect(f > 20 and m > 20);
    try std.testing.expect(forest_crossings > 5 and boundary_counts.selector > 10);
    try std.testing.expect(g.at(.temperate, g.width / 2, g.height / 2).temperate_landform == null);
    for ([_]env.ClimateId{ .steppe, .desert, .frozen }) |climate| try std.testing.expect(g.at(climate, g.width / 8, g.height / 3).temperate_landform == null);

    const centre = [2]u32{ g.width / 8, g.height / 3 };
    g.mountains = .{ .width = g.width, .height = g.height, .sea_level = g.sea_level, .continent_count = 1 };
    g.mountains.peaks[0][g.mountains.binAt(centre[1])] = .{
        .active = true,
        .center = centre,
        .summit_height = 972,
        .radii_x = .{ 400, 400 },
        .radii_y = .{ 48, 48 },
        .shape_x = .{ 4, 12 },
        .shape_y = .{ 4, 4 },
    };
    g.mountains.rebuildIndex();
    const summit = g.at(.temperate, centre[0], centre[1]);
    try std.testing.expectEqual(@as(u32, 972), summit.terrain_height);
    try std.testing.expectEqual(env.ReliefId.mountain, summit.relief);
    try std.testing.expectEqual(env.SurfaceCover.rock, summit.surface_cover);
    try std.testing.expectEqual(env.GeologyId.rocky, summit.geology);
    try std.testing.expect(summit.temperate_landform == null);
    const foot = g.at(.temperate, centre[0] + 338, centre[1]);
    try std.testing.expect(foot.mountain_strength > 0 and foot.temperate_landform == null);
    try std.testing.expectEqual(env.SurfaceCover.soil, foot.surface_cover);
    const frozen = g.at(.frozen, centre[0], centre[1]);
    try std.testing.expectEqual(@as(u16, 0), frozen.mountain_strength);
}
