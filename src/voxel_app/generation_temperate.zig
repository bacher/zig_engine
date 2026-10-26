const std = @import("std");
const hash = @import("generation_hash.zig");
const env = @import("world_environment.zig");

pub const unit: i64 = 65536;
pub const selector_scale = 5120;
pub const rolling_scale = 1536;
pub const short_scale = 384;
pub const hilly_threshold: i64 = 26624;
const transition_width: i64 = 16384;
const default_depth: i64 = 1024;
const selector_tag = 0x54454d505245474e;
const rolling_tag = 0x54454d50534c4f57;
const short_tag = 0x54454d5053484f52;

/// Maximum adjacent Q16 difference, including conservative rounding error.
/// Shore, climate and mountain modifiers belong to the caller's slope budget.
pub const adjacent_bound_q16: i64 = unit * 64 / 100;

pub const Sample = struct {
    landform: env.TemperateLandform,
    elevation_q16: i64,
    /// Flatland, rolling hills, hilly, in enum order. Always sums to unit.
    weights_q16: [3]u32,
    /// Unmixed, depth-scaled profiles, useful for maps and local diagnostics.
    profiles_q16: [3]i64,
};

/// Pure, allocation-free relief from exactly three periodic integer fields.
/// Default-depth profiles have an eight-block floor and peak-to-trough ranges
/// of 6, 72 and 32 blocks. Vertical relief scales down with depth, never up.
/// Smoothstep remapping flattens the crests/troughs without pointed peaks.
/// The selector's zero and calibrated 26624 thresholds target a soft 50/30/20
/// ensemble mix. No per-world coverage pass, quota or rejection is needed.
///
/// Cardinal slope proof, before integer rounding:
/// A cubic value field of full range 2 has derivative <= 3 / lattice_spacing.
/// Mapping to [0,1] and applying smoothstep adds a factor 1/2 * 1.5, so a
/// profile of relief R has derivative <= 2.25 * R / spacing. The largest is
/// hilly relief: 2.25 * 32 / 384 = 0.1875. The two selector transitions do not
/// overlap, have width 1/4 of the signed field, and use smoothstep. Thus their
/// weight derivative is <= 6 * 3 / 5120. Profile differences are <= 72, giving
/// a selector contribution <= 72 * 18 / 5120 = 0.253125. Sum: <= 0.440625.
/// X periods round upwards in width/scale, making them no steeper; a one-cell
/// periodic X field is constant. These bounds therefore include the X seam.
///
/// Rounding proof: field2 differs from the ideal field by <12 raw units: each
/// axis contributes <3 from phase rounding, <2 from cubic rounding and <1
/// from interpolation. Profile normalization adds <1 Q16 unit and its remap
/// adds <1, giving <11.502 Q16 units, or <0.01264 blocks after relief <=72.
/// A selector transition multiplies raw units by four exactly, then remaps:
/// its weight error is <1.5 * (12 * 4) + 1 = 73 Q16 units. Multiplying by a
/// profile difference <=72 adds <0.08021 blocks. Blend/depth rounding adds
/// <2 Q16 units. Twice the total point error plus the ideal cardinal bound is
/// <0.627 blocks, strictly below the declared 0.64 bound. Depth scaling <=1
/// cannot increase it. Flooring the final composed height is left to callers.
pub fn sample(seed: u64, x: u32, y: u32, width: u32, depth: u32) Sample {
    const cx = x % width;
    const selector = hash.field2(hash.mix(seed ^ selector_tag), cx, y, width, selector_scale);
    const slow = hash.field2(hash.mix(seed ^ rolling_tag), cx, y, width, rolling_scale);
    const short = hash.field2(hash.mix(seed ^ short_tag), cx, y, width, short_scale);
    const a = transition(selector, 0);
    const b = transition(selector, hilly_threshold);
    const short_profile = rounded(short);
    const profiles = [3]i64{
        8 * unit + 6 * short_profile,
        8 * unit + 72 * rounded(slow),
        8 * unit + 32 * short_profile,
    };
    const height = profiles[0] + @divFloor((profiles[1] - profiles[0]) * a, unit) + @divFloor((profiles[2] - profiles[1]) * b, unit);
    const depth_scale: i64 = @min(depth, default_depth);
    var scaled_profiles: [3]i64 = undefined;
    for (profiles, &scaled_profiles) |profile, *scaled| scaled.* = @divFloor(profile * depth_scale, default_depth);
    return .{
        .landform = if (selector < 0) .flatland else if (selector < hilly_threshold) .rolling_hills else .hilly,
        .elevation_q16 = @divFloor(height * depth_scale, default_depth),
        .weights_q16 = .{ @intCast(unit - a), @intCast(a - b), @intCast(b) },
        .profiles_q16 = scaled_profiles,
    };
}

fn smoothstep(t: i64) i64 {
    return @divFloor(t * t * (3 * unit - 2 * t), unit * unit);
}

fn rounded(value: i64) i64 {
    return smoothstep(@divFloor((value + 65535) * unit, 131070));
}

fn transition(selector: i64, centre: i64) i64 {
    const t = std.math.clamp(@divFloor((selector - centre + transition_width / 2) * unit, transition_width), 0, unit);
    return smoothstep(t);
}

test "temperate profiles have bounded relief and broad rounded crests" {
    try std.testing.expectEqual(@as(i64, 0), rounded(-65535));
    try std.testing.expectEqual(unit, rounded(65535));
    // The upper tenth of raw values is remapped into the upper three percent.
    // This flattens broad crests while leaving the profile continuous.
    try std.testing.expect(rounded(52428) >= unit * 97 / 100);
    try std.testing.expect(rounded(-52428) <= unit * 3 / 100);
    for ([_]u32{ 128, 512, 1024, 2048 }) |depth| {
        const scale: i64 = @min(depth, 1024);
        for (0..1024) |i| {
            const h = hash.at(12345, @intCast(i), 0);
            const result = sample(12345, @intCast(h % 65536), @intCast((h >> 32) % 32768), 65536, depth);
            const low = @divFloor(8 * unit * scale, 1024);
            const high = @divFloor(80 * unit * scale, 1024);
            try std.testing.expect(result.elevation_q16 >= low and result.elevation_q16 <= high);
            for (result.profiles_q16, [_]i64{ 6, 72, 32 }) |profile, relief| {
                try std.testing.expect(profile >= low and profile <= @divFloor((8 + relief) * unit * scale, 1024));
            }
            try std.testing.expectEqual(@as(u32, @intCast(unit)), result.weights_q16[0] + result.weights_q16[1] + result.weights_q16[2]);
        }
    }
}

test "temperate fields are pure periodic and join the X seam gently" {
    for ([_]u32{ 2048, 32768, 65536, 131072 }) |width| {
        for (0..128) |i| {
            const y: u32 = @intCast(i * 131);
            const x: u32 = @intCast(i * 13);
            const a = sample(87, x, y, width, 1024);
            try std.testing.expectEqualDeep(a, sample(87, x + width, y, width, 1024));
            const west = sample(87, width - 1, y, width, 1024);
            const east = sample(87, 0, y, width, 1024);
            try std.testing.expect(@abs(west.elevation_q16 - east.elevation_q16) < adjacent_bound_q16);
            // Intervening unrelated probes cannot change an earlier sample.
            _ = sample(12345, y % width, x, width, 512);
            try std.testing.expectEqualDeep(a, sample(87, x, y, width, 1024));
        }
    }
}

test "temperate grades remain bounded through both selector transitions" {
    var transition_counts = [_]usize{ 0, 0 };
    var landform_counts = [_]usize{ 0, 0, 0 };
    for ([_]u32{ 2048, 32768, 65536, 131072 }) |width| {
        for (0..8) |seed| for (0..2048) |i| {
            const h = hash.at(seed, @intCast(i), 0);
            const x: u32 = @intCast(h % width);
            const y: u32 = @intCast((h >> 32) % 65536);
            const a = sample(seed, x, y, width, 1024);
            landform_counts[@intFromEnum(a.landform)] += 1;
            transition_counts[0] += @intFromBool(a.weights_q16[0] > 0 and a.weights_q16[0] < unit);
            transition_counts[1] += @intFromBool(a.weights_q16[2] > 0 and a.weights_q16[2] < unit);
            for ([_][2]u32{ .{ (x + 1) % width, y }, .{ x, y + 1 } }) |point| {
                const b = sample(seed, point[0], point[1], width, 1024);
                try std.testing.expect(@abs(a.elevation_q16 - b.elevation_q16) < adjacent_bound_q16);
                try std.testing.expect(@abs(@divFloor(a.elevation_q16, unit) - @divFloor(b.elevation_q16, unit)) <= 1);
            }
        };
    }
    for (transition_counts) |count| try std.testing.expect(count > 1000);
    for (landform_counts) |count| try std.testing.expect(count > 1000);
}

test "temperate selector targets a soft fifty thirty twenty ensemble mix" {
    // Offline calibration only. Runtime preparation never counts terrain area.
    // Uniformly sample physical space across all three named world profiles.
    for ([_]u32{ 32768, 65536, 131072 }) |width| {
        var counts = [_]usize{ 0, 0, 0 };
        for (0..32) |seed| for (0..32) |iy| for (0..64) |ix| {
            const x: u32 = @intCast(ix * width / 64 + 17);
            const y: u32 = @intCast(iy * (width / 2) / 32 + 29);
            const result = sample(seed, x, y, width, 1024);
            counts[@intFromEnum(result.landform)] += 1;
        };
        const count = 32 * 32 * 64;
        for (counts, [_]usize{ 50, 30, 20 }) |actual, target| {
            try std.testing.expect(actual * 100 >= count * (target - 5));
            try std.testing.expect(actual * 100 <= count * (target + 5));
        }
    }
}
