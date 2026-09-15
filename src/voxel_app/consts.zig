const std = @import("std");

pub const CHUNK_SIZE = 32;
// it's safe to use only u30, because we still needs to be able to convert it to i32 on the GPU
// and make sure it works a little bit outside of the chunk bounds.
pub const WORLD_SIZE = [_]u30{
    // std.math.pow(u30, 2, 12), // 4096 chunks (131072 blocks) (ideally)
    std.math.pow(u30, 2, 9), //   512 chunks ( 16384 blocks)
    std.math.pow(u30, 2, 8), //   256 chunks (  8192 blocks)
    std.math.pow(u30, 2, 3), //     8 chunks (   256 blocks)
};

pub const ChunkPosition = u32; // 12 bit x, 8 bit y, 3 bit z
pub const BlockPosition = u64; // 30 bit x, 30 bit y, 4 bit z

pub const WORLD_ORIGIN = [_]u30{
    WORLD_SIZE[0] / 2,
    WORLD_SIZE[1] / 2,
    WORLD_SIZE[2] / 2,
};
