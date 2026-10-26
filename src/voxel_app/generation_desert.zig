const std = @import("std");
const hash = @import("generation_hash.zig");
const env = @import("world_environment.zig");

pub const unit: i64 = 65536;
pub const Sample = struct {
    biome: env.DesertBiome,
    elevation_q16: i64,
    /// Continuous dune contribution in [0,65536]; flats always report zero.
    dune_weight: u32,
};

const selector_scale = 1536;
const flat_warp_scale = 2048;
const flat_period = 1152;
const dune_period = 160;
const dune_warp_scale = 1024;

/// Pure column-local relief; callers apply their coast/climate envelopes and
/// quantize only after blending. At most three value-field probes, no allocation.
///
/// A sign-symmetric broad selector makes irregular, roughly equal dune/plain
/// patches without consulting chunks. Only the dune side blends continuously;
/// every column classified as a plain retains the gentle broad field alone.
/// Plains rise/fall by one block per about 36 blocks, with gently bent contours.
/// Dunes add up to 24 blocks in winding ridges rather than value-noise domes.
///
/// On supported world widths (>=2048), ideal per-axis derivative bounds are:
///   plains: (1 + 3*64/2048)/36 = 0.030382;
///   dunes: (48/160)*(1 + 3*48/1024) = 0.342188;
///   selector blend: 24*6/1536 = 0.09375.
/// Their sum is <0.467. Integer field/interpolation error contributes <0.024
/// across an adjacent pair, so the Q16 output changes by <0.491 blocks. This
/// includes biome transitions. Flooring the final result cannot create a
/// cardinal step above one, or a gain above one over any two-block interval.
pub fn sample(seed: u64, x: u32, y: u32, width: u32) Sample {
    const cx = x % width;
    const selector = hash.field2(hash.mix(seed ^ 0x4445534552545041), cx, y, width, selector_scale);
    const weight = std.math.clamp(selector * 2, 0, unit);
    const flat = flatElevation(seed, cx, y, width);
    const dunes = if (weight == 0) 0 else duneElevation(seed, cx, y, width);
    return .{
        .biome = if (selector >= 0) .dunes else .flats,
        .elevation_q16 = flat + @divFloor(weight * dunes, unit),
        .dune_weight = @intCast(weight),
    };
}

fn triangle(phase_q16: i64, period: i64, height: i64) i64 {
    const phase = @mod(phase_q16, period * unit);
    return @divFloor(@min(phase, period * unit - phase) * (2 * height), period);
}

fn flatElevation(seed: u64, x: u32, y: u32, width: u32) i64 {
    // Fold a seeded X coordinate to keep the broad diagonal contours periodic.
    // The fold is one-Lipschitz at its two turns, including the world seam.
    const centre: u32 = @intCast(hash.mix(seed ^ 0x464c415443454e54) % width);
    const folded_x: i64 = @intCast(@abs(hash.distanceX(x, centre, width)));
    const warp = hash.field2(hash.mix(seed ^ 0x464c415457415250), x, y, width, flat_warp_scale);
    const phase = (@as(i64, y) + folded_x) * unit + warp * 64;
    return 8 * unit + triangle(phase, flat_period, 16);
}

fn duneElevation(seed: u64, x: u32, y: u32, width: u32) i64 {
    // Whole ridge cycles fit every width. The resulting physical period is at
    // least 160 blocks, so width rounding can only make the ridges gentler.
    const cycles = @max(1, width / dune_period);
    const phase_x = @as(u64, x) * cycles % width;
    const phase: i64 = @intCast(phase_x * dune_period * unit / width);
    const warp = hash.field2(hash.mix(seed ^ 0x44554e4557415250), x, y, width, dune_warp_scale);
    return triangle(phase + warp * 48, dune_period, 24);
}

test "desert relief bounds adjacent and two-block grades through patch transitions" {
    var transition_samples: usize = 0;
    var flat_samples: usize = 0;
    for ([_]u32{ 2048, 32768, 65536, 131072 }) |width| {
        for (0..4) |seed| for (0..2048) |i| {
            const h = hash.at(seed, @intCast(i), 0);
            const x: u32 = @intCast(h % width);
            const y: u32 = @intCast((h >> 32) % 32768);
            const a = sample(seed, x, y, width);
            try std.testing.expect(a.elevation_q16 >= 8 * unit and a.elevation_q16 <= 48 * unit);
            try std.testing.expect(a.dune_weight <= unit);
            transition_samples += @intFromBool(a.dune_weight > 0 and a.dune_weight < unit);
            if (a.biome == .flats) {
                flat_samples += 1;
                try std.testing.expectEqual(@as(u32, 0), a.dune_weight);
                try std.testing.expectEqual(flatElevation(seed, x, y, width), a.elevation_q16);
            }
            for ([_][2]u32{ .{ (x + 1) % width, y }, .{ x, y + 1 } }, [_][2]u32{ .{ (x + 2) % width, y }, .{ x, y + 2 } }) |neighbor, twice| {
                const b = sample(seed, neighbor[0], neighbor[1], width);
                const c = sample(seed, twice[0], twice[1], width);
                try std.testing.expect(@abs(a.elevation_q16 - b.elevation_q16) < unit / 2);
                try std.testing.expect(@abs(@divFloor(a.elevation_q16, unit) - @divFloor(b.elevation_q16, unit)) <= 1);
                try std.testing.expect(@abs(@divFloor(a.elevation_q16, unit) - @divFloor(c.elevation_q16, unit)) <= 1);
            }
        };
    }
    try std.testing.expect(transition_samples > 1000);
    try std.testing.expect(flat_samples > 1000);
}

test "desert relief repeats exactly and joins the wrapped seam gently" {
    for ([_]u32{ 2048, 32768, 65536, 131072 }) |width| for (0..128) |i| {
        const y: u32 = @intCast(i * 131);
        const x: u32 = @intCast(i * 13);
        try std.testing.expectEqualDeep(sample(12345, x, y, width), sample(12345, x + width, y, width));
        const west = sample(12345, width - 1, y, width);
        const east = sample(12345, 0, y, width);
        try std.testing.expect(@abs(west.elevation_q16 - east.elevation_q16) < unit / 2);
    };
}

test "broad flat terrain has characteristic one-in-thirty-to-forty grades" {
    const width = 65536;
    for (0..8) |seed| {
        var steps_x: usize = 0;
        var steps_y: usize = 0;
        for (0..4096) |i| {
            const p: u32 = @intCast(i);
            const x = flatElevation(seed, p, 1234, width);
            const east = flatElevation(seed, p + 1, 1234, width);
            const y = flatElevation(seed, 1234, p, width);
            const north = flatElevation(seed, 1234, p + 1, width);
            try std.testing.expect(@abs(x - east) < unit / 32);
            try std.testing.expect(@abs(y - north) < unit / 32);
            steps_x += @intFromBool(@divFloor(x, unit) != @divFloor(east, unit));
            steps_y += @intFromBool(@divFloor(y, unit) != @divFloor(north, unit));
        }
        // Reversals occupy a few columns at broad crests and troughs.
        try std.testing.expect(steps_x >= 100 and steps_x <= 130);
        try std.testing.expect(steps_y >= 100 and steps_y <= 130);
    }
}

test "desert patches are roughly balanced irregular and cross chunk boundaries" {
    for ([_]u32{ 32768, 65536, 131072 }) |width| {
        const height = width / 2;
        var dunes: usize = 0;
        var count: usize = 0;
        var same_chunk_edge: usize = 0;
        var mixed_chunks: usize = 0;
        for (0..4) |seed| {
            for (0..128) |iy| for (0..256) |ix| {
                const x: u32 = @intCast(ix * width / 256);
                const y: u32 = @intCast(iy * height / 128);
                const a = sample(seed, x, y, width);
                dunes += @intFromBool(a.biome == .dunes);
                count += 1;
            };
            for (0..1024) |i| {
                const h = hash.at(seed, @intCast(i), 1);
                const x: u32 = @intCast(h % (width / 32) * 32);
                const y: u32 = @intCast((h >> 32) % (height / 32) * 32);
                const a = sample(seed, x, y, width);
                const west = sample(seed, (x + width - 1) % width, y, width);
                const far = sample(seed, x + 31, y + 31, width);
                same_chunk_edge += @intFromBool(a.biome == west.biome);
                mixed_chunks += @intFromBool(a.biome != far.biome);
            }
        }
        try std.testing.expect(dunes * 100 / count >= 40 and dunes * 100 / count <= 60);
        try std.testing.expect(same_chunk_edge > 4000);
        try std.testing.expect(mixed_chunks > 10);
    }
}
