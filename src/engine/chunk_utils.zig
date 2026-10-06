const std = @import("std");
const Position = @import("world_math.zig").Position;
const ChunkCoords = @import("world_math.zig").ChunkCoords;

/// Shared by engine rendering, generated WGSL, and game-side terrain storage.
pub const CHUNK_SIZE = 32;
pub const ChunkId = u32;

/// Positive base-2 exponents of the world dimensions in chunks, and bits per ID coordinate.
pub const WORLD_SIZE_LOG2: [3]u5 = .{ 9, 8, 3 };

pub const WORLD_SIZE: ChunkCoords = size: {
    const total_bits = @as(u32, WORLD_SIZE_LOG2[0]) + WORLD_SIZE_LOG2[1] + WORLD_SIZE_LOG2[2];
    if (total_bits > @bitSizeOf(ChunkId)) {
        @compileError("World chunk coordinates must fit in a 32-bit ChunkId");
    }

    var dimensions: ChunkCoords = undefined;
    for (WORLD_SIZE_LOG2, 0..) |bits, axis| {
        if (bits == 0) {
            @compileError("World dimension exponents must be positive");
        }
        if (bits >= @bitSizeOf(i32) - 1) {
            @compileError("World chunk dimensions must fit in positive i32 coordinates");
        }
        dimensions[axis] = @as(i32, 1) << bits;
        if (@as(u64, @intCast(dimensions[axis])) * CHUNK_SIZE > std.math.maxInt(u32)) {
            @compileError("World block dimensions must fit in u32 storage coordinates");
        }
    }
    break :size dimensions;
};

const CHUNK_ID_SHIFTS: [3]u5 = .{
    0,
    WORLD_SIZE_LOG2[0],
    WORLD_SIZE_LOG2[0] + WORLD_SIZE_LOG2[1],
};
const CHUNK_ID_MASKS: [3]ChunkId = .{
    WORLD_SIZE[0] - 1,
    WORLD_SIZE[1] - 1,
    WORLD_SIZE[2] - 1,
};

pub const WORLD_ORIGIN_CHUNK: ChunkCoords = @divFloor(WORLD_SIZE, @as(ChunkCoords, @splat(2)));
pub const WORLD_SIZE_IN_BLOCKS: [3]u32 = @as(@Vector(3, u32), @intCast(WORLD_SIZE)) *
    @as(@Vector(3, u32), @splat(CHUNK_SIZE));

/// Pack validated storage coordinates; signed spatial coordinates must be normalized first.
pub fn encodeChunkId(x: anytype, y: anytype, z: anytype) ChunkId {
    var id: ChunkId = 0;
    inline for (.{ x, y, z }, 0..) |coordinate, axis| {
        std.debug.assert(coordinate >= 0 and coordinate < WORLD_SIZE[axis]);
        id |= @as(ChunkId, @intCast(coordinate)) << CHUNK_ID_SHIFTS[axis];
    }
    return id;
}

pub fn encodeChunkCoords(coords: ChunkCoords) ChunkId {
    return encodeChunkId(coords[0], coords[1], coords[2]);
}

pub fn decodeChunkId(id: ChunkId) ChunkCoords {
    var coords: ChunkCoords = undefined;
    inline for (0..3) |axis| {
        coords[axis] = @intCast((id >> CHUNK_ID_SHIFTS[axis]) & CHUNK_ID_MASKS[axis]);
    }
    return coords;
}

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

test "chunk IDs use contiguous fields derived from the world dimensions" {
    const maximum = WORLD_SIZE - @as(ChunkCoords, @splat(1));
    try std.testing.expectEqual(@as(ChunkId, 0), encodeChunkId(0, 0, 0));
    try std.testing.expectEqual(ChunkCoords{ 0, 0, 0 }, decodeChunkId(0));
    const chunk_count = @as(u64, @intCast(WORLD_SIZE[0])) *
        @as(u64, @intCast(WORLD_SIZE[1])) * @as(u64, @intCast(WORLD_SIZE[2]));
    try std.testing.expectEqual(@as(ChunkId, @intCast(chunk_count - 1)), encodeChunkCoords(maximum));
    try std.testing.expectEqual(maximum, decodeChunkId(encodeChunkCoords(maximum)));

    // Every coordinate bit must occupy a distinct bit in the packed ID.
    inline for (0..3) |axis| {
        for (0..WORLD_SIZE_LOG2[axis]) |bit| {
            var coords: ChunkCoords = @splat(0);
            coords[axis] = @as(i32, 1) << @as(u5, @intCast(bit));
            const id = encodeChunkCoords(coords);
            try std.testing.expectEqual(@as(usize, 1), @popCount(id));
            try std.testing.expectEqual(coords, decodeChunkId(id));
        }
    }

    // Exercise every combination of zero and maximum axis coordinates.
    for (0..8) |corner| {
        var coords: ChunkCoords = @splat(0);
        inline for (0..3) |axis| {
            if (corner & (@as(usize, 1) << axis) != 0) coords[axis] = maximum[axis];
        }
        try std.testing.expectEqual(coords, decodeChunkId(encodeChunkCoords(coords)));
    }
}
