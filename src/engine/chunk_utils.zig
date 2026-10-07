const Position = @import("world_math.zig").Position;

/// Chunk-local storage and GPU layouts remain fixed across worlds.
pub const CHUNK_SIZE = 32;
pub const ChunkId = u32;

/// Remove the chunk origin in f64, then narrow the bounded local coordinates.
pub fn getLocalPosition(position: Position) @Vector(3, f32) {
    return @floatCast(@mod(position, @as(Position, @splat(CHUNK_SIZE))));
}
