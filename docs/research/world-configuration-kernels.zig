// Standalone compiler experiment for ../world-configuration-options.md.
// These isolated kernels are not integrated into the engine or its root build.
// Runtime sizes are assumed validated positive powers of two for the mask and
// reciprocal variants. Exported functions prevent compile-time specialization
// of their runtime parameters when inspecting ReleaseFast assembly.
const std = @import("std");

export fn delta_static(a: i32, b: i32) i64 {
    var delta = @mod(@as(i64, a), 512) - @mod(@as(i64, b), 512);
    if (delta > 256) delta -= 512;
    if (delta < -256) delta += 512;
    return delta;
}

export fn delta_runtime_mod(a: i32, b: i32, width: i64) i64 {
    var delta = @mod(@as(i64, a), width) - @mod(@as(i64, b), width);
    if (delta > @divTrunc(width, 2)) delta -= width;
    if (delta < -@divTrunc(width, 2)) delta += width;
    return delta;
}

export fn delta_runtime_mask(a: i32, b: i32, width: i64) i64 {
    const mask: u64 = @intCast(width - 1);
    const na: i64 = @intCast(@as(u64, @bitCast(@as(i64, a))) & mask);
    const nb: i64 = @intCast(@as(u64, @bitCast(@as(i64, b))) & mask);
    var delta = na - nb;
    if (delta > @divTrunc(width, 2)) delta -= width;
    if (delta < -@divTrunc(width, 2)) delta += width;
    return delta;
}

export fn id_static(x: u32, y: u32, z: u32) u32 {
    return x | (y << 9) | (z << 17);
}

export fn id_runtime(x: u32, y: u32, z: u32, shift_y: u8, shift_z: u8) u32 {
    return x | (y << @as(u5, @intCast(shift_y))) | (z << @as(u5, @intCast(shift_z)));
}

export fn chunk_static(x: f64) i32 {
    return @intFromFloat(@mod(@floor(x / 32) + 256, 512));
}

export fn chunk_runtime(x: f64, size: f64, origin: f64) i32 {
    return @intFromFloat(@mod(@floor(x / 32) + origin, size));
}

export fn chunk_runtime_power2(x: f64, size: f64, reciprocal: f64, origin: f64) i32 {
    const chunk = @floor(x / 32) + origin;
    return @intFromFloat(chunk - @floor(chunk * reciprocal) * size);
}

test "runtime integer mask retains signed normalization and half-period ties" {
    const cases = [_]i32{ std.math.minInt(i32), -1000001, -1025, -513, -512, -257, -256, -1, 0, 1, 255, 256, 257, 511, 512, 513, 1025, 1000001, std.math.maxInt(i32) };
    for ([_]i64{ 2, 8, 256, 512, 1024, 1 << 26 }) |width| {
        for (cases) |a| for (cases) |b| {
            try std.testing.expectEqual(delta_runtime_mod(a, b, width), delta_runtime_mask(a, b, width));
            if (width == 512) try std.testing.expectEqual(delta_static(a, b), delta_runtime_mask(a, b, width));
        };
    }
}

test "runtime power-of-two float normalization matches modulo for finite sample positions" {
    const positions = [_]f64{ -1.0e23, -1.0e14, -1000000000.125, -32768.125, -16384, -8192.125, -8192, -32.001, -32, -0.001, 0, 0.125, 31.999, 32, 8191.999, 8192, 16384, 1000000000.125, 1.0e14, 1.0e23 };
    for ([_]u32{ 2, 8, 256, 512, 1024, 1 << 26 }) |dimension| {
        const size: f64 = @floatFromInt(dimension);
        const origin = size / 2;
        for (positions) |position| {
            try std.testing.expectEqual(chunk_runtime(position, size, origin), chunk_runtime_power2(position, size, 1 / size, origin));
            if (dimension == 512) try std.testing.expectEqual(chunk_static(position), chunk_runtime_power2(position, size, 1 / size, origin));
        }
    }
}
