const std = @import("std");
const hash = @import("generation_hash.zig");

pub const ClimateId = enum(u8) { frozen, steppe, temperate, desert };
pub const ReliefId = enum(u8) { lowland, mountain };
pub const VegetationId = enum(u8) { barren, meadow, forest, sparse };
pub const GeologyId = enum(u8) { sedimentary, rocky };
pub const SurfaceCover = enum(u8) { soil, sand, rock };
pub const DesertBiome = enum(u8) { dunes, flats };
pub const TemperateLandform = enum(u8) { flatland, rolling_hills, hilly };
pub const ClimateMap = [32][32]ClimateId;
pub const ClimateSample = struct {
    id: ClimateId,
    mountain_fade: u16,
    /// Full desert relief inside the belt, tapered into a temperate collar.
    /// This changes terrain continuously without blending climate/material IDs.
    desert_terrain: u16 = 0,
    /// New soil relief fades in well inside temperate belts, leaving the desert
    /// collar and adjoining climates on the same continuous ordinary baseline.
    temperate_terrain: u16 = 0,
};

pub const WorkRules = struct {
    farming_allowed: bool,
    clothing_required: bool,
    additional_water_required: bool,
    increased_food_cost: bool,
};

pub fn rules(climate: ClimateId) WorkRules {
    return .{
        .farming_allowed = climate != .frozen,
        .clothing_required = climate == .frozen,
        .additional_water_required = climate == .desert,
        .increased_food_cost = climate == .frozen,
    };
}

pub const ColumnEnvironment = struct {
    climate: ClimateId,
    terrain_height: u32,
    sea_level: u32,
    water_present: bool,
    relief: ReliefId,
    mountain_strength: u16,
    vegetation: VegetationId,
    geology: GeologyId,
    surface_cover: SurfaceCover,
    /// Zero denotes ocean, 1..5 mainland, 128..159 detached islands.
    landmass_id: u8,
    /// Approximate generated-shore proximity for relief and beaches, independent
    /// of player edits. This is not a distance query against current water.
    coast_distance: u32,
    desert_biome: ?DesertBiome = null,
    temperate_landform: ?TemperateLandform = null,

    pub fn workRules(self: ColumnEnvironment) WorkRules {
        return rules(self.climate);
    }
};

pub const ClimateField = struct {
    seed: u64,
    width: u32,
    height: u32,
    displacement: u32,

    /// Pair opposite lattice nodes with opposite signs, so every octave has
    /// f(x + width / 2) = -f(x). World widths are even, making the integer column
    /// mean exactly zero without a scan or retained noise tables.
    fn periodicBoundary(seed: u64, x: u32, width: u32, comptime cells: u16) i64 {
        const scaled = @as(u64, x) * cells * 65536 / width + (seed & 65535) * cells;
        const cell: u16 = @intCast((scaled >> 16) % cells);
        const next = (cell + 1) % cells;
        const t: i64 = @intCast(scaled & 65535);
        const smooth = @divTrunc(t * t * (3 * 65536 - 2 * t), 65536 * 65536);
        const half = cells / 2;
        const a = (@as(i64, @intCast(hash.at(seed, cell % half, 0) & 65535)) * 2 - 65535) * @as(i64, if (cell < half) 1 else -1);
        const b = (@as(i64, @intCast(hash.at(seed, next % half, 0) & 65535)) * 2 - 65535) * @as(i64, if (next < half) 1 else -1);
        return a + @divTrunc((b - a) * smooth, 65536);
    }

    /// Boundaries ascend from the storage-south edge to storage-north.
    /// Equality belongs to the belt north of a boundary.
    pub fn boundaries(self: ClimateField, x: i64) [6]u32 {
        const canonical = hash.wrappedX(x, self.width);
        const shares = [_]u32{ 10, 20, 45, 55, 80, 90 };
        var out: [6]u32 = undefined;
        inline for (shares, 0..) |share, i| {
            const seed = hash.mix(self.seed +% i);
            var layered: i64 = 0;
            inline for ([_]u16{ 6, 14, 30 }, [_]i64{ 2, 3, 1 }, 0..) |cells, weight, octave| {
                layered += weight * periodicBoundary(hash.mix(seed +% octave), canonical, self.width, cells);
            }
            const noise = @divTrunc(layered, 6);
            const nominal: i64 = @intCast(@as(u64, self.height) * share / 100);
            out[i] = @intCast(nominal + @divTrunc(noise * self.displacement, 65536));
        }
        return out;
    }

    pub fn sample(self: ClimateField, x: i64, y: u32) ClimateSample {
        std.debug.assert(y < self.height);
        const b = self.boundaries(x);
        const sequence = [_]ClimateId{ .frozen, .steppe, .temperate, .desert, .temperate, .steppe, .frozen };
        var climate: ClimateId = .frozen;
        for (b, 0..) |boundary, i| {
            if (y < boundary) {
                climate = sequence[i];
                break;
            }
        }
        if (climate == .frozen) return .{ .id = climate, .mountain_fade = 0 };
        // The same displaced boundaries classify climate and taper uplift.
        // Reach zero on both nonfrozen border rows, before entering frozen land.
        const distance = @min(y - b[0], b[5] - 1 - y);
        const fade_width = @max(128, @min(1024, self.height / 32));
        const desert_distance = if (y < b[2]) b[2] - y else if (y >= b[3]) y - b[3] + 1 else 0;
        const temperate_distance = if (climate != .temperate) 0 else if (y < b[2]) @min(y - b[1], b[2] - 1 - y) else @min(y - b[3], b[4] - 1 - y);
        return .{
            .id = climate,
            .mountain_fade = @intCast(@min(65535, @as(u64, distance) * 65535 / fade_width)),
            .desert_terrain = if (climate == .desert) 65535 else if (climate == .temperate)
                @intCast(@as(u64, 256 - @min(256, desert_distance)) * 65535 / 256)
            else
                0,
            .temperate_terrain = @intCast(@as(u64, @min(1536, temperate_distance -| 256)) * 65535 / 1536),
        };
    }

    pub fn at(self: ClimateField, x: i64, y: u32) ClimateId {
        return self.sample(x, y).id;
    }
};

test "mountain climate fade reaches zero before both displaced frozen boundaries" {
    const field = ClimateField{ .seed = hash.stream(12345, .climate, 0), .width = 65536, .height = 32768, .displacement = 96 };
    for ([_]i64{ 0, 1, 11647, 32768, 65535 }) |x| {
        const b = field.boundaries(x);
        for ([_]u32{ b[0] - 1, b[0], b[5] - 1, b[5] }) |y| {
            try std.testing.expectEqual(@as(u16, 0), field.sample(x, y).mountain_fade);
            try std.testing.expectEqualDeep(field.sample(x, y), field.sample(x - field.width, y));
        }
        for (0..1025) |offset| {
            const d: u32 = @intCast(offset);
            const south = field.sample(x, b[0] + d);
            const north = field.sample(x, b[5] - 1 - d);
            try std.testing.expectEqual(south.mountain_fade, north.mountain_fade);
            try std.testing.expectEqual(@as(u16, @intCast(@min(65535, offset * 65535 / 1024))), south.mountain_fade);
        }
    }
}

test "climate fields wrap, preserve ordered polar widths, and expose future work rules" {
    const field = ClimateField{ .seed = 12345, .width = 65536, .height = 32768, .displacement = 96 };
    for (0..1024) |i| {
        const x: i64 = @intCast(i * 64);
        const b = field.boundaries(x);
        try std.testing.expect(b[0] >= 128 and field.height - b[5] >= 128);
        for (0..5) |j| try std.testing.expect(b[j] < b[j + 1]);
        try std.testing.expectEqual(field.at(x, b[2]), field.at(x - field.width, b[2]));
        try std.testing.expectEqual(ClimateId.desert, field.at(x, b[2]));
    }
    try std.testing.expect(!rules(.frozen).farming_allowed);
    try std.testing.expect(rules(.frozen).clothing_required);
    try std.testing.expect(rules(.frozen).increased_food_cost);
    try std.testing.expect(rules(.desert).additional_water_required);
}

test "layered climate boundaries keep exact whole-world belt areas" {
    const settings = @import("generation_settings.zig").NaturalSettings{};
    const width = 65536;
    const height = 32768;
    const shares = [_]u32{ 10, 20, 45, 55, 80, 90 };
    for (0..8) |seed| {
        const field = ClimateField{ .seed = hash.stream(12345 + seed, .climate, 0), .width = width, .height = height, .displacement = settings.climateDisplacement(height) };
        var totals: [6]u64 = @splat(0);
        for (0..width) |x| {
            const b = field.boundaries(@intCast(x));
            for (b, 0..) |boundary, i| totals[i] += boundary;
        }
        for (shares, totals) |share, total| {
            try std.testing.expectEqual(@as(u64, height * share / 100) * width, total);
        }
    }
}

test "automatic climate curves stay visible ordered polar and periodic across seeds and layouts" {
    const settings = @import("generation_settings.zig").NaturalSettings{};
    for ([_][2]u32{ .{ 2048, 2048 }, .{ 4096, 3072 }, .{ 65536, 32768 }, .{ 2048, 8388608 } }) |size| {
        for (0..64) |seed| {
            const field = ClimateField{ .seed = hash.stream(12345 + seed, .climate, 0), .width = size[0], .height = size[1], .displacement = settings.climateDisplacement(size[1]) };
            for (0..128) |sample| {
                const x: i64 = @intCast(@as(u64, size[0]) * sample / 128);
                const b = field.boundaries(x);
                try std.testing.expect(b[0] >= 128 and field.height - b[5] >= 128);
                for (0..5) |i| try std.testing.expect(b[i] < b[i + 1]);
                try std.testing.expectEqualDeep(b, field.boundaries(x - field.width));
                try std.testing.expectEqualDeep(b, field.boundaries(x + field.width));
            }
        }
    }

    const field = ClimateField{ .seed = hash.stream(12345, .climate, 0), .width = 65536, .height = 32768, .displacement = settings.climateDisplacement(32768) };
    var lows: [6]u32 = @splat(field.height);
    var highs: [6]u32 = @splat(0);
    for (0..1024) |sample| {
        for (field.boundaries(@intCast(sample * 64)), 0..) |boundary, i| {
            lows[i] = @min(lows[i], boundary);
            highs[i] = @max(highs[i], boundary);
        }
    }
    var greatest_range: u32 = 0;
    for (lows, highs) |low, high| greatest_range = @max(greatest_range, high - low);
    try std.testing.expect(greatest_range >= field.height / 32);
    const west = field.boundaries(field.width - 1);
    const east = field.boundaries(0);
    for (west, east) |a, b| try std.testing.expect(@max(a, b) - @min(a, b) <= 1);
}
