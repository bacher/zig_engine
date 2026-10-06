const chunks = @import("engine").chunk_utils;

pub const CHUNK_SIZE = chunks.CHUNK_SIZE;
pub const WORLD_SIZE = chunks.WORLD_SIZE;
pub const WORLD_SIZE_IN_BLOCKS = chunks.WORLD_SIZE_IN_BLOCKS;
pub const WORLD_ORIGIN_CHUNK = chunks.WORLD_ORIGIN_CHUNK;

pub const ChunkPosition = u32; // 12 bit x, 8 bit y, 3 bit z
