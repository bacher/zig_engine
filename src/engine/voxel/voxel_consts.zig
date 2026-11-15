pub const VOXEL_GRID_SLOT_SIZE = 1024;
pub const VOXEL_GRID_SLOT_COUNT = 4 * 1024;
pub const VOXEL_GRID_BUFFER_SIZE = VOXEL_GRID_SLOT_COUNT * VOXEL_GRID_SLOT_SIZE;

// A culled opaque 32³ chunk can expose 98,304 faces (384 slots). The
// allocator joins up to eight ordinary 64-slot spans for one 512-slot block.
pub const MAX_SPAN_SIZE_EXPONENT = 9;
