const std = @import("std");

pub const CHUNK_SIZE = 32.0;
// TODO: dedupe
const WORLD_ORIGIN_CHUNK = [_]i32{ 256, 128, 4 };
const WORLD_SIZE = [_]u32{
    std.math.pow(u32, 2, 9), //   512 chunks ( 16384 blocks)
    std.math.pow(u32, 2, 8), //   256 chunks (  8192 blocks)
    std.math.pow(u32, 2, 3), //     8 chunks (   256 blocks)
};

pub fn getChunkCoords(position: [3]f32) [3]i32 {
    // TODO: refactor to use integer and bitwise shift operations instead of float operations
    return .{
        @mod(@as(i32, @intFromFloat(@divFloor(position[0], CHUNK_SIZE))) + WORLD_ORIGIN_CHUNK[0], WORLD_SIZE[0]),
        @as(i32, @intFromFloat(@divFloor(position[1], CHUNK_SIZE))) + WORLD_ORIGIN_CHUNK[1],
        @as(i32, @intFromFloat(@divFloor(position[2], CHUNK_SIZE))) + WORLD_ORIGIN_CHUNK[2],
    };
}
