const std = @import("std");

pub const CHUNK_SIZE = 32.0;
// TODO: dedupe
pub const WORLD_ORIGIN_CHUNK = [_]i32{ 256, 128, 4 };
pub const WORLD_SIZE = [_]u32{
    std.math.pow(u32, 2, 9), //   512 chunks ( 16384 blocks)
    std.math.pow(u32, 2, 8), //   256 chunks (  8192 blocks)
    std.math.pow(u32, 2, 3), //     8 chunks (   256 blocks)
};

pub fn getChunkCoords(position: [3]f64) @Vector(4, i32) {
    // Wrap x before narrowing to i32, so repeated trips around the world do not
    // overflow the GPU chunk coordinate. Unwrapped y/z must fit signed i32.
    return .{
        @intFromFloat(@mod(@divFloor(position[0], CHUNK_SIZE) + WORLD_ORIGIN_CHUNK[0], WORLD_SIZE[0])),
        @as(i32, @intFromFloat(@divFloor(position[1], CHUNK_SIZE))) + WORLD_ORIGIN_CHUNK[1],
        @as(i32, @intFromFloat(@divFloor(position[2], CHUNK_SIZE))) + WORLD_ORIGIN_CHUNK[2],
        0,
    };
}

/// Remove the chunk origin in f64, then narrow the bounded local coordinates.
pub fn getLocalPosition(position: [3]f64) [3]f32 {
    return .{ @floatCast(@mod(position[0], CHUNK_SIZE)), @floatCast(@mod(position[1], CHUNK_SIZE)), @floatCast(@mod(position[2], CHUNK_SIZE)) };
}

/// Subtract integer coordinates before converting to meters. Only x wraps.
pub fn getChunkDelta(chunk: @Vector(4, i32), origin: @Vector(4, i32)) @Vector(4, i32) {
    var delta = chunk - origin;
    const width: i32 = WORLD_SIZE[0];
    if (delta[0] > width / 2) delta[0] -= width;
    if (delta[0] < -width / 2) delta[0] += width;
    return delta;
}

// Shared by the mesh, voxel, and shadow shaders, with the same constants as the CPU.
pub const wgsl = std.fmt.comptimePrint(
    "const CHUNK_SIZE: f32 = {d}.0;\nconst WORLD_WIDTH: i32 = {d};\n",
    .{ @as(u32, CHUNK_SIZE), WORLD_SIZE[0] },
) ++ @embedFile("shaders/chunk_relative.wgsl");
