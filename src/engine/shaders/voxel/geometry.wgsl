struct GPU_ChunkInfo {
    view_side_data_indices: array<array<u32, 3>, 8>,
    chunk_origin: vec3i,
    slot_index: u32,
}

// Keep in sync with voxel/voxel_consts.zig.
const BLOCKS_PER_SLOT = 256;

struct VoxelVertex {
    position: vec4f,
    normal: vec3f,
    uv: vec2f,
}

fn voxelVertex(
    instance_index: u32,
    vertex_index: u32,
) -> VoxelVertex {
    let chunk_index = instance_index >> 3;
    let view_index = instance_index & 0x7u;

    let chunk_info = chunk_info_array[chunk_index];
    let views = chunk_info.view_side_data_indices[view_index];

    let face_index = vertex_index / 6;

    var face_indirect_index = 0u;
    var chunk_side = 0u;
    if (face_index < (views[0] & 0xffffu)) { // 16 bits
        face_indirect_index = face_index + (views[0] >> 16u);
        // maps INDEXES mapping from voxel_grid.zig
        // for first 4 views it's 0, otherwise it's 1
        chunk_side = view_index >> 2;
    } else if (face_index < (views[1] & 0xffffu)) { // 16 bits
        face_indirect_index = face_index + (views[1] >> 16u);
        // maps INDEXES mapping from voxel_grid.zig
        // if pre-last bit is 0 it's 2, otherwise it's 3
        chunk_side = 2 + ((view_index & 0x2u) >> 1);
    } else {
        face_indirect_index = face_index + (views[2] >> 16u);
        // maps INDEXES mapping from voxel_grid.zig
        // if last bit is 0 (even number) it's 4, otherwise it's 5
        chunk_side = 4 + (view_index & 0x1u);
    }

    let chunk_origin = chunkOffset(chunk_info.chunk_origin, origin_chunk);

    let global_block_index =
        chunk_info.slot_index * BLOCKS_PER_SLOT +
        face_indirect_index;

    let block = block_array[global_block_index];
    let block_origin = vec3(
        block & 0xffu,
        (block >> 8) & 0xffu,
        (block >> 16) & 0xffu,
    );
    let block_type = (block >> 24) & 0xffu;

    let side_vertex_index = vertex_index % 6;

    let block_vertex = getPosition(chunk_side, side_vertex_index);
    let uv = getUv(chunk_side, side_vertex_index, block_type);
    let normal = getNormal(chunk_side);

    let position4 = vec4f(chunk_origin + vec3f(block_origin + block_vertex), 1.0);

    return VoxelVertex(position4, normal, uv);
}
