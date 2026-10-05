// Matches ChunkTransform's 80-byte storage-buffer entry.
struct ChunkTransform {
    chunk_from_model: mat4x4<f32>,
    chunk: vec4i,
}

fn chunkOffset(chunk: vec3i, origin: vec3i) -> vec3f {
    var delta = chunk - origin;
    if (delta.x > WORLD_WIDTH / 2) {
        delta.x -= WORLD_WIDTH;
    } else if (delta.x < -WORLD_WIDTH / 2) {
        delta.x += WORLD_WIDTH;
    }
    return vec3f(delta) * CHUNK_SIZE;
}

fn relativePosition(instance: ChunkTransform, origin: vec3i, position: vec4f) -> vec4f {
    let local = instance.chunk_from_model * position;
    return vec4f(local.xyz + chunkOffset(instance.chunk.xyz, origin) * local.w, local.w);
}
