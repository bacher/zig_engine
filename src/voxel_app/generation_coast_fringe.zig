const hash = @import("generation_hash.zig");

/// Canonical 8–24-block erosion fringe shared by land refinement and coast bounds.
/// Preserve the seed, scale and integer rounding together when tuning the coast.
pub fn sample(seed: u64, width: u32, x: u32, y: u32) u32 {
    const n = hash.field2(hash.mix(seed ^ 0x434f415354), x % width, y, width, 256);
    return @intCast(8 + @divTrunc((n + 65535) * 16, 131070));
}
