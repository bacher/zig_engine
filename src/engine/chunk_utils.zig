const std = @import("std");
const Position = @import("world_math.zig").Position;
const ChunkCoords = @import("world_math.zig").ChunkCoords;

/// Shared by engine rendering, generated WGSL, and game-side terrain storage.
pub const CHUNK_SIZE = 32;
pub const WORLD_SIZE: ChunkCoords = .{
    512, // 2^9 chunks = 16384 blocks
    256, // 2^8 chunks = 8192 blocks
    8, //   2^3 chunks = 256 blocks
};
pub const WORLD_ORIGIN_CHUNK: ChunkCoords = @divFloor(WORLD_SIZE, @as(ChunkCoords, @splat(2)));
pub const WORLD_SIZE_IN_BLOCKS: [3]u32 = @as(@Vector(3, u32), @intCast(WORLD_SIZE)) *
    @as(@Vector(3, u32), @splat(CHUNK_SIZE));

pub fn getChunkCoords(position: Position) ChunkCoords {
    var chunk = @divFloor(position, @as(Position, @splat(CHUNK_SIZE))) +
        @as(Position, @floatFromInt(WORLD_ORIGIN_CHUNK));
    // Wrap x before narrowing to i32, so repeated trips around the world do not
    // overflow the GPU chunk coordinate. Unwrapped y/z must fit signed i32.
    chunk[0] = @mod(chunk[0], WORLD_SIZE[0]);
    return @intFromFloat(chunk);
}

/// Remove the chunk origin in f64, then narrow the bounded local coordinates.
pub fn getLocalPosition(position: Position) @Vector(3, f32) {
    return @floatCast(@mod(position, @as(Position, @splat(CHUNK_SIZE))));
}

/// Subtract integer coordinates before converting to meters. Only x wraps.
pub fn getChunkDelta(chunk: ChunkCoords, origin: ChunkCoords) @Vector(3, i64) {
    // Two valid i32 coordinates can have a difference outside the i32 range.
    var delta = @as(@Vector(3, i64), chunk) - @as(@Vector(3, i64), origin);
    const width: i64 = WORLD_SIZE[0];
    delta[0] = @mod(chunk[0], width) - @mod(origin[0], width);
    if (delta[0] > width / 2) delta[0] -= width;
    if (delta[0] < -width / 2) delta[0] += width;
    return delta;
}

// Shared by the mesh, voxel, and shadow shaders, with the same constants as the CPU.
pub const wgsl = std.fmt.comptimePrint(
    "const CHUNK_SIZE: f32 = {d}.0;\nconst WORLD_WIDTH: i32 = {d};\n",
    .{ @as(u32, CHUNK_SIZE), WORLD_SIZE[0] },
) ++ @embedFile("shaders/chunk_relative.wgsl");
