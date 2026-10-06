// Matches ChunkTransform's 80-byte storage-buffer entry.
struct ChunkTransform {
    chunk_from_model: mat4x4<f32>,
    chunk: vec4i,
}

fn chunkOffset(chunk: vec3i, origin: vec3i) -> vec3f {
    // Normalize each x before subtracting, including negative spatial chunks.
    let chunk_x = ((chunk.x % WORLD_WIDTH) + WORLD_WIDTH) % WORLD_WIDTH;
    let origin_x = ((origin.x % WORLD_WIDTH) + WORLD_WIDTH) % WORLD_WIDTH;
    var dx = chunk_x - origin_x;
    if (dx > WORLD_WIDTH / 2) {
        dx -= WORLD_WIDTH;
    } else if (dx < -WORLD_WIDTH / 2) {
        dx += WORLD_WIDTH;
    }
    // Bias signed coordinates into ordered u32 values. Their unsigned distance
    // fits even when the signed difference exceeds i32. Subtract before f32
    // conversion so adjacent chunks retain precision at either signed limit.
    let a = bitcast<vec2u>(chunk.yz) ^ vec2u(0x80000000u);
    let b = bitcast<vec2u>(origin.yz) ^ vec2u(0x80000000u);
    let magnitude = max(a, b) - min(a, b);
    let dyz = vec2f(magnitude) * select(vec2f(1.0), vec2f(-1.0), chunk.yz < origin.yz);
    return vec3f(f32(dx), dyz) * CHUNK_SIZE;
}

fn relativePosition(instance: ChunkTransform, origin: vec3i, position: vec4f) -> vec4f {
    let local = instance.chunk_from_model * position;
    return vec4f(local.xyz + chunkOffset(instance.chunk.xyz, origin) * local.w, local.w);
}
