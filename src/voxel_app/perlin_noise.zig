const std = @import("std");

/// Seeded, deterministic two-dimensional Perlin gradient noise.
pub const PerlinNoise = struct {
    seed: u64,

    pub fn init(seed: u64) PerlinNoise {
        return .{ .seed = seed };
    }

    /// Returns a smoothly varying value in the range [-1, 1].
    pub fn sample2D(self: PerlinNoise, x: f64, y: f64) f64 {
        const x0: i64 = @intFromFloat(@floor(x));
        const y0: i64 = @intFromFloat(@floor(y));
        const local_x = x - @as(f64, @floatFromInt(x0));
        const local_y = y - @as(f64, @floatFromInt(y0));

        const bottom_left = gradientDot(self.seed, x0, y0, local_x, local_y);
        const bottom_right = gradientDot(self.seed, x0 + 1, y0, local_x - 1.0, local_y);
        const top_left = gradientDot(self.seed, x0, y0 + 1, local_x, local_y - 1.0);
        const top_right = gradientDot(self.seed, x0 + 1, y0 + 1, local_x - 1.0, local_y - 1.0);

        const u = fade(local_x);
        const v = fade(local_y);
        const bottom = lerp(bottom_left, bottom_right, u);
        const top = lerp(top_left, top_right, u);

        // The largest dot products from the normalized gradients are about
        // 1 / sqrt(2); scale them to make most of the available range useful.
        return std.math.clamp(lerp(bottom, top, v) * std.math.sqrt2, -1.0, 1.0);
    }
};

fn fade(value: f64) f64 {
    // Perlin's quintic smoothing curve: 6t^5 - 15t^4 + 10t^3.
    return value * value * value * (value * (value * 6.0 - 15.0) + 10.0);
}

fn lerp(a: f64, b: f64, amount: f64) f64 {
    return a + amount * (b - a);
}

fn gradientDot(seed: u64, x: i64, y: i64, offset_x: f64, offset_y: f64) f64 {
    const diagonal = 1.0 / std.math.sqrt2;
    const gradient: [2]f64 = switch (hashCoordinates(seed, x, y) & 7) {
        0 => .{ 1.0, 0.0 },
        1 => .{ -1.0, 0.0 },
        2 => .{ 0.0, 1.0 },
        3 => .{ 0.0, -1.0 },
        4 => .{ diagonal, diagonal },
        5 => .{ -diagonal, diagonal },
        6 => .{ diagonal, -diagonal },
        else => .{ -diagonal, -diagonal },
    };

    return gradient[0] * offset_x + gradient[1] * offset_y;
}

fn hashCoordinates(seed: u64, x: i64, y: i64) u64 {
    var hash = seed;
    hash ^= @as(u64, @bitCast(x)) *% 0x9e3779b185ebca87;
    hash ^= @as(u64, @bitCast(y)) *% 0xc2b2ae3d27d4eb4f;

    // SplitMix64's finalizer gives neighboring lattice points unrelated
    // gradients without requiring a seed-specific permutation allocation.
    hash ^= hash >> 30;
    hash *%= 0xbf58476d1ce4e5b9;
    hash ^= hash >> 27;
    hash *%= 0x94d049bb133111eb;
    hash ^= hash >> 31;
    return hash;
}

test "same seed and coordinates produce the same value" {
    const first = PerlinNoise.init(12345);
    const second = PerlinNoise.init(12345);

    try std.testing.expectEqual(first.sample2D(17.25, -8.75), second.sample2D(17.25, -8.75));
}

test "different seeds produce different noise" {
    const first = PerlinNoise.init(1).sample2D(12.25, 9.5);
    const second = PerlinNoise.init(2).sample2D(12.25, 9.5);

    try std.testing.expect(first != second);
}

test "noise is continuous and bounded" {
    const noise = PerlinNoise.init(9876);
    const first = noise.sample2D(5.0, 3.125);
    const nearby = noise.sample2D(5.0001, 3.125);

    try std.testing.expect(first >= -1.0 and first <= 1.0);
    try std.testing.expect(nearby >= -1.0 and nearby <= 1.0);
    try std.testing.expectApproxEqAbs(first, nearby, 0.001);
}
