/// SplitMix64 finalizer, pinned to generator 2/version 1. Wrapping arithmetic
/// and explicit unsigned coordinate encoding make streams platform independent.
pub fn mix(input: u64) u64 {
    var z = input +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

pub const Tag = enum(u64) {
    climate = 0x434c494d41544501,
    deeprock = 0x44454550524f434b,
    continents = 0x434f4e54494e454e,
    islands = 0x49534c414e445301,
    relief = 0x52454c4945460001,
    geology = 0x47454f4c4f475901,
    deposits = 0x4445504f53495401,
    vegetation = 0x5645474554415401,
    trees = 0x5452454553000001,
};

pub fn stream(seed: u64, tag: Tag, attempt: u8) u64 {
    return mix(seed ^ @intFromEnum(tag) ^ mix(attempt));
}

pub fn at(seed: u64, x: i64, y: i64) u64 {
    return mix(seed ^ mix(@bitCast(x)) ^ (mix(@bitCast(y)) *% 0xd6e8feb86659fd93));
}

pub fn wrappedX(x: i64, width: u32) u32 {
    return @intCast(@mod(x, @as(i64, width)));
}

/// Canonical immutable floor shared by both playable profiles and every overlay.
pub fn deeprockThickness(seed: u64, x: i64, y: u32, width: u32) u32 {
    return 1 + @as(u32, @intCast(at(stream(seed, .deeprock, 0), wrappedX(x, width), y) % 3));
}

pub fn distanceX(a: i64, b: i64, width: u32) i64 {
    return @mod(a - b + @divTrunc(@as(i64, width), 2), @as(i64, width)) - @divTrunc(@as(i64, width), 2);
}

/// Periodic, bounded integer cubic value field. Range [-65535,65535].
/// Only integer arithmetic is used, including interpolation and tie-breaking.
pub fn periodic(seed: u64, x: u32, width: u32, cells: u16) i64 {
    const scaled = @as(u64, x) * cells * 65536 / width;
    const cell: i64 = @intCast(scaled >> 16);
    const t: i64 = @intCast(scaled & 65535);
    const smooth = @divTrunc(t * t * (3 * 65536 - 2 * t), 65536 * 65536);
    const a = @as(i64, @intCast(at(seed, cell, 0) & 65535)) * 2 - 65535;
    const b = @as(i64, @intCast(at(seed, @mod(cell + 1, cells), 0) & 65535)) * 2 - 65535;
    return a + @divTrunc((b - a) * smooth, 65536);
}

pub fn field2(seed: u64, x: u32, y: u32, width: u32, scale: u32) i64 {
    const cells: u16 = @intCast(@min(65535, @max(1, width / scale)));
    const cell_y: i64 = @intCast(y / scale);
    const t: i64 = @intCast(@as(u64, y % scale) * 65536 / scale);
    const smooth = @divTrunc(t * t * (3 * 65536 - 2 * t), 65536 * 65536);
    const a = periodic(at(seed, cell_y, 0), x, width, cells);
    const b = periodic(at(seed, cell_y + 1, 0), x, width, cells);
    return a + @divTrunc((b - a) * smooth, 65536);
}
