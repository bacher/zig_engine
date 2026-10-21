struct GPU_CustomBlock {
    chunk_origin: vec3i,
    direction: u32,
    local_origin: vec3f,
    adaptive: u32,
    high: f32,
    low: f32,
    padding: vec2u,
}

fn customVertex(instance_index: u32, vertex_index: u32) -> VoxelVertex {
    let block = custom_blocks[instance_index];
    if (block.adaptive != 0u) {
        var vertex = adaptiveVertex(vertex_index);
        vertex.position = vec4f(chunkOffset(block.chunk_origin, origin_chunk) + block.local_origin + vertex.position.xyz, 1.0);
        return vertex;
    }
    let side = vertex_index / 6u;
    let corner = vertex_index % 6u;
    var local = vec3f(getPosition(side, corner));
    var normal = getNormal(side);
    {
        var along = local.x;
        var gradient = vec2f(block.low - block.high, 0.0);
        switch block.direction {
            case 1u: { along = 1.0 - local.x; gradient = vec2f(block.high - block.low, 0.0); }
            case 2u: { along = local.y; gradient = vec2f(0.0, block.low - block.high); }
            case 3u: { along = 1.0 - local.y; gradient = vec2f(0.0, block.high - block.low); }
            default: {}
        }
        local.z *= mix(block.high, block.low, along);
        if (side == 5u) { normal = normalize(vec3f(-gradient, 1.0)); }
    }
    let position = chunkOffset(block.chunk_origin, origin_chunk) + block.local_origin + local;
    return VoxelVertex(vec4f(position, 1.0), normal, getUv(side, corner, select(13u, 14u, block.adaptive != 0u)));
}
