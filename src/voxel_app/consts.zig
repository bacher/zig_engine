const std = @import("std");

pub const CHUNK_SIZE = 32;
pub const WORLD_SIZE = [_]u32{
    std.math.pow(u32, 2, 12), // 4096 chunks (131072 blocks)
    std.math.pow(u32, 2, 8), //   256 chunks (  8192 blocks)
    std.math.pow(u32, 2, 3), //     8 chunks (   256 blocks)
};

pub const ChunkPosition = u32; // 12 bit x, 8 bit y, 3 bit z
pub const BlockPosition = u64; // 30 bit x, 30 bit y, 4 bit z
