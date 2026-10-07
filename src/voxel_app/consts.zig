const chunks = @import("engine").chunk_utils;
pub const CHUNK_SIZE = chunks.CHUNK_SIZE;
pub const ChunkId = chunks.ChunkId;
/// voxel_app always uses periodic x terrain.
pub const WORLD_SETTINGS: @import("engine").WorldSettings = .{
    .size_in_chunks = .{ 512, 256, 8 },
    .wrap_x = true,
};
