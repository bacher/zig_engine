const std = @import("std");
const hash = @import("generation_hash.zig");
const env = @import("world_environment.zig");

pub const unit: u32 = 65536;
pub const continent_limit = 5;
pub const bin_count = 32;
pub const neighbour_radius = 2;
pub const maximum_candidates = 2 * neighbour_radius + 1;
const macro_size = 128;

/// Immutable, independently seeded peaks. Each owner has at most one peak per
/// global Y bin, and every Y radius is less than two bins. Sampling visits only
/// the owning mainland's current bin and its two neighbours on either side.
pub const Mountains = struct {
    width: u32,
    height: u32,
    sea_level: u32,
    continent_count: u8,
    peaks: [continent_limit][bin_count]Peak = @splat(@splat(.{})),
    previous_bins: [continent_limit][bin_count]u8 = @splat(@splat(255)),
    next_bins: [continent_limit][bin_count]u8 = @splat(@splat(255)),
    /// A promoted summit is a real protected, fully unfaded mainland anchor.
    high_summit_bins: [continent_limit]?u8 = @splat(null),

    pub const PrepareInput = struct {
        seed: u64,
        width: u32,
        height: u32,
        depth: u32,
        sea_level: u32,
        continent_count: u8,
        core_seeds: [continent_limit][2]u32,
        owners: []const u8,
        coastal_distance: []const u16,
        climate: env.ClimateField,
    };

    /// One bounded ownership pass, followed by at most 160 descriptor and
    /// climate probes. No allocation, terrain census or retry loop is needed.
    pub fn preparationWorkBound(cells: usize) u64 {
        return @as(u64, cells) + continent_limit * bin_count * 4;
    }

    pub fn prepare(input: PrepareInput) Mountains {
        std.debug.assert(input.continent_count <= continent_limit);
        std.debug.assert(input.height >= bin_count);
        std.debug.assert(input.owners.len == input.coastal_distance.len);
        var self = Mountains{ .width = input.width, .height = input.height, .sea_level = input.sea_level, .continent_count = input.continent_count };
        var scores: [continent_limit][bin_count]u64 = @splat(@splat(std.math.maxInt(u64)));
        var coast_quality: [continent_limit][bin_count]u16 = @splat(@splat(0));
        var anchor_coasts: [continent_limit][bin_count]u16 = @splat(@splat(0));
        var preferred: [continent_limit][bin_count][2]u32 = undefined;
        const macro_width = input.width / macro_size;
        const spacing = input.height / bin_count;
        for (0..input.continent_count) |owner| for (0..bin_count) |bin| {
            const y: u32 = @intCast((@as(u64, bin) * input.height + input.height / 2) / bin_count);
            const range_seed = hash.mix(input.seed +% owner +% 0x52414e4745);
            const phase = hash.wrappedX(@as(i64, y) + @as(i64, @intCast(range_seed % input.height)), input.height);
            const winding = hash.periodic(range_seed, phase, input.height, 3);
            const core_x = input.core_seeds[owner][0] * macro_size + macro_size / 2;
            const range_width = input.width / @max(1, input.continent_count);
            const x = @as(i64, core_x) + @divTrunc(winding * range_width, 65536 * 10) + range_width / 7;
            preferred[owner][bin] = .{ hash.wrappedX(x, input.width), y };
        };
        for (input.owners, input.coastal_distance, 0..) |owner_id, coast, index| {
            if (owner_id == 0 or owner_id > input.continent_count) continue;
            const owner = owner_id - 1;
            const x: u32 = @intCast(index % macro_width * macro_size + macro_size / 2);
            const y: u32 = @intCast(index / macro_width * macro_size + macro_size / 2);
            const bin = self.binAt(y);
            // Prefer protected interior first. Beyond six macro cells, a
            // winding target chooses the range's course through broad interiors.
            const quality = @min(coast, 6);
            const target = preferred[owner][bin];
            const score = @abs(hash.distanceX(x, target[0], input.width)) + @abs(@as(i64, y) - target[1]);
            if (self.peaks[owner][bin].active and (quality < coast_quality[owner][bin] or (quality == coast_quality[owner][bin] and score >= scores[owner][bin]))) continue;
            self.peaks[owner][bin].active = true;
            self.peaks[owner][bin].center = .{ x, y };
            scores[owner][bin] = score;
            coast_quality[owner][bin] = quality;
            anchor_coasts[owner][bin] = coast;
        }
        const maximum_summit: u32 = @intCast(@as(u64, input.depth) * 95 / 100);
        const maximum_relief = maximum_summit -| input.sea_level;
        for (0..input.continent_count) |owner| {
            var highest_coast: u16 = 0;
            for (&self.peaks[owner], 0..) |*peak, bin| {
                if (!peak.active) continue;
                const seed = hash.at(hash.mix(input.seed ^ 0x5045414b53), @intCast(owner), @intCast(bin));
                const summit = input.sea_level + @as(u32, @intCast(@as(u64, maximum_relief) * (30 + seed % 61) / 100));
                peak.* = Peak.init(peak.center, summit, input.sea_level, maximum_relief, spacing, input.width, input.continent_count, seed);
                const coast = anchor_coasts[owner][bin];
                if (coast < 3 or coast <= highest_coast) continue;
                if (input.climate.sample(peak.center[0], peak.center[1]).mountain_fade != 65535) continue;
                highest_coast = coast;
                self.high_summit_bins[owner] = @intCast(bin);
            }
            if (self.high_summit_bins[owner]) |bin| {
                const seed = hash.at(hash.mix(input.seed ^ 0x5045414b53), @intCast(owner), bin);
                const center = self.peaks[owner][bin].center;
                self.peaks[owner][bin] = Peak.init(center, maximum_summit, input.sea_level, maximum_relief, spacing, input.width, input.continent_count, seed);
            }
        }
        self.rebuildIndex();
        return self;
    }

    /// Rebuild after explicitly constructing descriptor fixtures. Production
    /// preparation does this once; the indexes contain no independent state.
    pub fn rebuildIndex(self: *Mountains) void {
        for (0..self.continent_count) |owner| {
            var previous: u8 = 255;
            for (0..bin_count) |bin| {
                self.previous_bins[owner][bin] = previous;
                if (self.peaks[owner][bin].active) previous = @intCast(bin);
            }
            var next: u8 = 255;
            var bin: usize = bin_count;
            while (bin > 0) {
                bin -= 1;
                self.next_bins[owner][bin] = next;
                if (self.peaks[owner][bin].active) next = @intCast(bin);
            }
        }
    }

    pub fn binAt(self: *const Mountains, y: u32) usize {
        return @intCast(@min(bin_count - 1, @as(u64, y) * bin_count / self.height));
    }

    /// The caller supplies the ordinary climate/shore terrain, then applies
    /// cover from the returned grade. Height is a maximum of separate pointed
    /// bodies: overlapping feet connect ranges while gaps between summits form
    /// saddles. No continuous ridge uplift is added below the peaks.
    pub fn sample(self: *const Mountains, owner_id: u8, x: i64, y: u32, base_height: u32, coast_distance: u32, climate_fade: u16) Sample {
        var result = Sample{ .height = base_height };
        if (owner_id == 0 or owner_id > self.continent_count or coast_distance <= 16 or climate_fade == 0) return result;
        const coast_fade: u32 = @intCast(@min(unit, @as(u64, coast_distance - 16) * unit / 128));
        const fade: u32 = @intCast(@as(u64, coast_fade) * climate_fade / 65535);
        const bin = self.binAt(y);
        const start = bin -| neighbour_radius;
        const end = @min(bin_count, bin + neighbour_radius + 1);
        const track = self.trackAt(owner_id - 1, y);
        const period = @as(i64, self.width) * unit;
        const dx_q16 = @mod(@as(i64, hash.wrappedX(x, self.width)) * unit - track.x_q16 + @divTrunc(period, 2), period) - @divTrunc(period, 2);
        for (self.peaks[owner_id - 1][start..end], start..) |peak, index| {
            if (!peak.active or peak.summit_height <= base_height) continue;
            const shape = peak.shapeAtOffset(dx_q16, @as(i64, y) - peak.center[1], track.grade_q16);
            if (shape.influence_q16 == 0) continue;
            const influence: u32 = @intCast(@as(u64, shape.influence_q16) * fade / unit);
            const profile: u32 = @intCast(@as(u64, shape.profile_q16) * fade / unit);
            const relief = peak.summit_height - base_height;
            const uplift: u32 = @intCast((@as(u64, relief) * profile + unit / 2) / unit);
            const candidate_height = base_height + uplift;
            // Linear influence deliberately survives into the broad, gentle
            // foot; the convex rational elevation remains much lower there.
            result.strength = @max(result.strength, @as(u16, @intCast(@as(u64, influence) * 65535 / unit)));
            if (candidate_height < result.height or (candidate_height == result.height and profile <= result.shape_q16)) continue;
            result.height = candidate_height;
            result.shape_q16 = profile;
            result.grade_q16 = @intCast(@min(std.math.maxInt(u32), @as(u64, shape.grade_q16) * relief * fade / unit));
            result.peak_index = @intCast((owner_id - 1) * bin_count + index);
        }
        return result;
    }

    const Track = struct { x_q16: i64, grade_q16: i64 = 0 };

    /// A shared centreline bends each separate peak body through neighbouring
    /// prepared anchors. It connects their feet without adding a ridge height,
    /// increasing every peak's width, or scanning descriptors during a query.
    fn trackAt(self: *const Mountains, owner: usize, y: u32) Track {
        const bin = self.binAt(y);
        const current = self.peaks[owner][bin];
        const left_bin = if (current.active and y >= current.center[1]) @as(u8, @intCast(bin)) else self.previous_bins[owner][bin];
        const right_bin = if (current.active and y < current.center[1]) @as(u8, @intCast(bin)) else self.next_bins[owner][bin];
        if (left_bin == 255 and right_bin == 255) return .{ .x_q16 = 0 };
        if (left_bin == 255) return .{ .x_q16 = @as(i64, self.peaks[owner][right_bin].center[0]) * unit };
        const left = self.peaks[owner][left_bin];
        if (right_bin == 255) return .{ .x_q16 = @as(i64, left.center[0]) * unit };
        const right = self.peaks[owner][right_bin];
        const distance = hash.distanceX(right.center[0], left.center[0], self.width);
        const span = right.center[1] - left.center[1];
        const grade = @divTrunc(distance * unit, span);
        return .{ .x_q16 = @as(i64, left.center[0]) * unit + @divTrunc(distance * unit * (@as(i64, y) - left.center[1]), span), .grade_q16 = grade };
    }
};

pub const Sample = struct {
    height: u32,
    strength: u16 = 0,
    /// Rational elevation weight, including climate/coast fade; 65536 at apex.
    shape_q16: u32 = 0,
    /// Maximum absolute cardinal derivative, in blocks/block * 65536. The
    /// ordinary lowland's small derivative and taper derivatives are excluded.
    grade_q16: u32 = 0,
    peak_index: ?u16 = null,
};

pub const Peak = struct {
    active: bool = false,
    center: [2]u32 = .{ 0, 0 },
    summit_height: u32 = 0,
    /// Negative and positive sides of the skewed local X and world Y axes.
    radii_x: [2]u32 = .{ 1, 1 },
    radii_y: [2]u32 = .{ 1, 1 },
    /// The shape steepens towards its cusp. Per-axis values blend continuously
    /// with angle, so a narrow cliff face can oppose a broader gradual face.
    shape_x: [2]u8 = .{ 2, 2 },
    shape_y: [2]u8 = .{ 2, 2 },
    skew_q16: i32 = 0,

    fn init(center: [2]u32, summit: u32, sea: u32, maximum_relief: u32, spacing: u32, width: u32, continents: u8, seed: u64) Peak {
        const relief = summit -| sea;
        const radius_x = @max(24, @min(width / @max(1, continents) / 7, relief * 2 + spacing / 8));
        const radius_y: u32 = @intCast(@as(u64, spacing) * (160 + @as(u64, relief) * 12 / @max(1, maximum_relief)) / 100);
        const x_skew: u32 = @intCast(78 + (seed >> 8) % 45);
        const y_skew: u32 = @intCast(86 + (seed >> 16) % 29);
        var peak = Peak{
            .active = true,
            .center = center,
            .summit_height = summit,
            .radii_x = .{ @max(1, radius_x * x_skew / 100), @max(1, radius_x * (200 - x_skew) / 100) },
            .radii_y = .{ @max(1, radius_y * y_skew / 100), @max(1, radius_y * (200 - y_skew) / 100) },
            .shape_x = .{ @intCast(2 + (seed >> 24) % 5), @intCast(2 + (seed >> 32) % 5) },
            .shape_y = .{ @intCast(2 + (seed >> 40) % 5), @intCast(2 + (seed >> 48) % 5) },
            .skew_q16 = 0,
        };
        if (seed % 3 == 0) peak.shape_x[(seed >> 7) & 1] = @intCast(10 + (seed >> 56) % 7);
        return peak;
    }

    const Shape = struct { influence_q16: u32 = 0, profile_q16: u32 = 0, grade_q16: u32 = 0 };

    /// An octagonal norm avoids square roots and expensive noise queries. All
    /// arithmetic is integer; the skew and asymmetric radii remove cone symmetry.
    fn shapeAt(self: Peak, x: i64, y: u32, width: u32) Shape {
        const dy = @as(i64, y) - self.center[1];
        return self.shapeAtOffset(hash.distanceX(x, self.center[0], width) * unit, dy, 0);
    }

    fn shapeAtOffset(self: Peak, dx_q16: i64, dy: i64, track_grade_q16: i64) Shape {
        const sy: usize = @intFromBool(dy >= 0);
        if (@abs(dy) >= self.radii_y[sy]) return .{};
        const u = dx_q16 - @as(i64, self.skew_q16) * dy;
        const sx: usize = @intFromBool(u >= 0);
        if (@abs(u) >= @as(u64, self.radii_x[sx]) * unit) return .{};
        const a: i64 = @intCast(@abs(u) / self.radii_x[sx]);
        const b: i64 = @intCast(@abs(dy) * unit / self.radii_y[sy]);
        const r = @max(a, b) + @divTrunc(3 * @min(a, b), 8);
        if (r >= unit) return .{};
        const q = unit - r;
        const sum = a + b;
        const kx = @as(i64, self.shape_x[sx]) * unit;
        const ky = @as(i64, self.shape_y[sy]) * unit;
        const k = if (sum == 0) @max(kx, ky) else @divTrunc(kx * a + ky * b, sum);
        const denominator = unit + @divTrunc((k - unit) * r, unit);
        const profile = @divTrunc(q * q, denominator);
        if (sum == 0) {
            // A cusp has no single gradient. Use its steepest cardinal face.
            const gx = @max(@divTrunc((@as(i64, self.shape_x[0]) + 1) * unit, self.radii_x[0]), @divTrunc((@as(i64, self.shape_x[1]) + 1) * unit, self.radii_x[1]));
            const gy = @max(@divTrunc((@as(i64, self.shape_y[0]) + 1) * unit, self.radii_y[0]), @divTrunc((@as(i64, self.shape_y[1]) + 1) * unit, self.radii_y[1]));
            const skew_grade: i64 = @intCast(@abs(@as(i64, self.skew_q16) + track_grade_q16) * @as(u64, @intCast(gx)) / unit);
            return .{ .influence_q16 = unit, .profile_q16 = unit, .grade_q16 = @intCast(@max(gx, gy + skew_grade)) };
        }
        // f(r,k) = (1-r)^2 / (1+(k-1)r). Its radial derivative grows towards
        // the apex, unlike smoothstep's rounded, zero-slope summit. Include
        // the angular k derivative when computing the two cardinal grades.
        const denominator_squared = denominator * denominator;
        const fr = @divTrunc(q * (2 * denominator + @divTrunc((k - unit) * q, unit)) * unit, denominator_squared);
        const fk = @divTrunc(q * q * r, denominator_squared);
        const da = -@divTrunc(fr * @as(i64, if (a >= b) unit else unit * 3 / 8), unit) - @divTrunc(fk * (kx - k), sum);
        const db = -@divTrunc(fr * @as(i64, if (a >= b) unit * 3 / 8 else unit), unit) - @divTrunc(fk * (ky - k), sum);
        const gx = @divTrunc(da * @as(i64, if (u < 0) -1 else 1), self.radii_x[sx]);
        const gy = @divTrunc(db * @as(i64, if (dy < 0) -1 else 1), self.radii_y[sy]) - @divTrunc((@as(i64, self.skew_q16) + track_grade_q16) * gx, unit);
        return .{ .influence_q16 = @intCast(q), .profile_q16 = @intCast(profile), .grade_q16 = @intCast(@max(@abs(gx), @abs(gy))) };
    }
};

fn fixturePeak(center: [2]u32, summit: u32, radius_x: u32, radius_y: u32, k: u8) Peak {
    return .{ .active = true, .center = center, .summit_height = summit, .radii_x = @splat(radius_x), .radii_y = @splat(radius_y), .shape_x = @splat(k), .shape_y = @splat(k) };
}

test "mountain feet are gentle and upper slopes steepen into a pointed cusp" {
    var field = Mountains{ .width = 8192, .height = 4096, .sea_level = 512, .continent_count = 1 };
    const center = [2]u32{ 4096, 2048 };
    field.peaks[0][field.binAt(center[1])] = fixturePeak(center, 972, 1000, 180, 12);
    const foot = field.sample(1, 4996, 2048, 540, 512, 65535);
    const middle = field.sample(1, 4596, 2048, 540, 512, 65535);
    const upper = field.sample(1, 4146, 2048, 540, 512, 65535);
    const apex = field.sample(1, 4096, 2048, 540, 512, 65535);
    try std.testing.expect(foot.height <= 541);
    try std.testing.expect(foot.strength > 0 and foot.shape_q16 < 100);
    try std.testing.expect(foot.grade_q16 < middle.grade_q16 and middle.grade_q16 < upper.grade_q16 and upper.grade_q16 < apex.grade_q16);
    try std.testing.expect(apex.grade_q16 > 4 * unit);
    try std.testing.expectEqual(@as(u32, 972), apex.height);
    try std.testing.expect(field.sample(1, 4097, 2048, 540, 512, 65535).height < apex.height);
}

test "overlapping mountains form separate summits and a geometric saddle" {
    var field = Mountains{ .width = 8192, .height = 4096, .sea_level = 512, .continent_count = 1 };
    field.peaks[0][15] = fixturePeak(.{ 4096, 1984 }, 960, 800, 180, 2);
    field.peaks[0][16] = fixturePeak(.{ 4128, 2112 }, 900, 700, 180, 3);
    field.rebuildIndex();
    const first = field.sample(1, 4096, 1984, 540, 512, 65535);
    const saddle = field.sample(1, 4112, 2048, 540, 512, 65535);
    const second = field.sample(1, 4128, 2112, 540, 512, 65535);
    try std.testing.expect(first.height > saddle.height and second.height > saddle.height);
    try std.testing.expect(saddle.height > 540);
    try std.testing.expect(field.sample(1, 4612, 2048, 540, 512, 65535).height < saddle.height);
}

test "asymmetric mountain faces have continuous angular shape and analytic grades" {
    var peak = fixturePeak(.{ 4096, 2048 }, 972, 800, 180, 4);
    peak.radii_x = .{ 500, 1000 };
    peak.shape_x = .{ 14, 3 };
    peak.shape_y = .{ 2, 6 };
    peak.skew_q16 = 12000;
    try std.testing.expect(peak.shapeAt(4196, 2048, 8192).profile_q16 != peak.shapeAt(3996, 2048, 8192).profile_q16);
    for ([_][2]u32{ .{ 4150, 2080 }, .{ 3900, 1990 }, .{ 4250, 2090 } }) |point| {
        const shape = peak.shapeAt(point[0], point[1], 8192);
        const west = peak.shapeAt(point[0] - 1, point[1], 8192);
        const east = peak.shapeAt(point[0] + 1, point[1], 8192);
        const south = peak.shapeAt(point[0], point[1] - 1, 8192);
        const north = peak.shapeAt(point[0], point[1] + 1, 8192);
        const numerical = @max(@abs(@as(i64, east.profile_q16) - west.profile_q16), @abs(@as(i64, north.profile_q16) - south.profile_q16)) / 2;
        try std.testing.expect(@abs(@as(i64, shape.grade_q16) - @as(i64, @intCast(numerical))) <= 5);
    }
}

test "range centreline connects separate bodies across the wrapped X seam" {
    var field = Mountains{ .width = 8192, .height = 4096, .sea_level = 512, .continent_count = 1 };
    field.peaks[0][15] = fixturePeak(.{ 8000, 1984 }, 972, 400, 230, 3);
    field.peaks[0][16] = fixturePeak(.{ 192, 2112 }, 900, 350, 230, 4);
    field.rebuildIndex();
    try std.testing.expectEqual(@as(u32, 972), field.sample(1, 8000, 1984, 540, 512, 65535).height);
    try std.testing.expectEqual(@as(u32, 900), field.sample(1, 192, 2112, 540, 512, 65535).height);
    try std.testing.expectEqual(@as(i64, 8192) * unit, field.trackAt(0, 2048).x_q16);
    for (0..129) |step| {
        const x: i64 = @intCast(8000 + step * 3);
        const y: u32 = @intCast(1984 + step);
        const sample = field.sample(1, x, y, 540, 512, 65535);
        try std.testing.expect(sample.height > 540 and sample.strength >= 18000);
        try std.testing.expectEqualDeep(sample, field.sample(1, x - 8192, y, 540, 512, 65535));
    }
    // The centreline's lateral motion contributes to the world-Y derivative.
    const sample = field.sample(1, 8090, 2008, 540, 512, 65535);
    var numerical: u64 = 0;
    for ([_][2]i32{ .{ 1, 0 }, .{ 0, 1 } }) |axis| {
        const positive = field.sample(1, 8090 + axis[0], @intCast(2008 + axis[1]), 540, 512, 65535);
        const negative = field.sample(1, 8090 - axis[0], @intCast(2008 - axis[1]), 540, 512, 65535);
        const positive_peak = field.peaks[0][positive.peak_index.? % bin_count];
        const negative_peak = field.peaks[0][negative.peak_index.? % bin_count];
        const difference = @as(i64, positive_peak.summit_height - 540) * positive.shape_q16 - @as(i64, negative_peak.summit_height - 540) * negative.shape_q16;
        numerical = @max(numerical, @abs(difference) / 2);
    }
    try std.testing.expect(@abs(@as(i64, sample.grade_q16) - @as(i64, @intCast(numerical))) <= 1000);
}

test "prepared mountains are deterministic protected periodic and bounded to five neighbours" {
    const width = 8192;
    const height = 4096;
    const macro_width = width / macro_size;
    const macro_height = height / macro_size;
    var owners: [macro_width * macro_height]u8 = @splat(0);
    var coasts: [macro_width * macro_height]u16 = @splat(0);
    for (4..28) |y| for (16..48) |x| {
        owners[y * macro_width + x] = 1;
        coasts[y * macro_width + x] = @intCast(@min(x - 15, 48 - x, y - 3, 28 - y));
    };
    const input = Mountains.PrepareInput{ .seed = 12345, .width = width, .height = height, .depth = 1024, .sea_level = 512, .continent_count = 1, .core_seeds = @splat(.{ 32, 16 }), .owners = &owners, .coastal_distance = &coasts, .climate = .{ .seed = 12345, .width = width, .height = height, .displacement = 0 } };
    const field = Mountains.prepare(input);
    try std.testing.expectEqualDeep(field, Mountains.prepare(input));
    try std.testing.expectEqual(@as(usize, 5), maximum_candidates);
    const high = field.peaks[0][field.high_summit_bins[0].?];
    try std.testing.expectEqual(@as(u32, 972), field.sample(1, high.center[0], high.center[1], 540, 512, 65535).height);
    for (field.peaks[0], 0..) |peak, bin| {
        if (!peak.active) continue;
        try std.testing.expectEqual(bin, field.binAt(peak.center[1]));
        try std.testing.expectEqual(@as(u8, 1), owners[peak.center[1] / macro_size * macro_width + peak.center[0] / macro_size]);
        try std.testing.expect(@max(peak.radii_y[0], peak.radii_y[1]) < height / bin_count * 2);
        if (bin + 1 < bin_count and field.peaks[0][bin + 1].active) {
            const next = field.peaks[0][bin + 1];
            for (0..33) |step| {
                const x = @as(i64, peak.center[0]) + @divTrunc(hash.distanceX(next.center[0], peak.center[0], width) * @as(i64, @intCast(step)), 32);
                const y: u32 = @intCast(@as(i64, peak.center[1]) + @divTrunc((@as(i64, next.center[1]) - peak.center[1]) * @as(i64, @intCast(step)), 32));
                const connected = field.sample(1, x, y, 540, 512, 65535);
                try std.testing.expect(connected.height > 540 and connected.strength > 18000);
            }
        }
    }
    for (0..height / 17) |row| {
        const y: u32 = @intCast(row * 17);
        for (0..width / 47) |column| {
            const x: i64 = @intCast(column * 47);
            const actual = field.sample(1, x, y, 540, 512, 65535);
            try std.testing.expectEqualDeep(actual, field.sample(1, x - width, y, 540, 512, 65535));
            var exhaustive: u32 = 540;
            for (field.peaks[0]) |peak| {
                if (!peak.active) continue;
                const track = field.trackAt(0, y);
                const shape = peak.shapeAtOffset(x * unit - track.x_q16, @as(i64, y) - peak.center[1], track.grade_q16);
                exhaustive = @max(exhaustive, 540 + @as(u32, @intCast((@as(u64, peak.summit_height - 540) * shape.profile_q16 + unit / 2) / unit)));
            }
            try std.testing.expectEqual(exhaustive, actual.height);
        }
    }
    const active = field.peaks[0][16];
    try std.testing.expectEqual(@as(u16, 0), field.sample(1, active.center[0], active.center[1], 540, 512, 0).strength);
    try std.testing.expectEqual(@as(u16, 0), field.sample(1, active.center[0], active.center[1], 540, 16, 65535).strength);
    try std.testing.expectEqual(@as(u16, 0), field.sample(0, active.center[0], active.center[1], 540, 512, 65535).strength);
    try std.testing.expectEqual(@as(u16, 0), field.sample(128, active.center[0], active.center[1], 540, 512, 65535).strength);
}
