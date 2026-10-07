// Matches ChunkTransform's 80-byte storage-buffer entry.
struct ChunkTransform {
    chunk_from_model: mat4x4<f32>,
    chunk: vec4i,
}

fn relativePosition(instance: ChunkTransform, origin: vec3i, position: vec4f) -> vec4f {
    let local = instance.chunk_from_model * position;
    return vec4f(local.xyz + chunkOffset(instance.chunk.xyz, origin) * local.w, local.w);
}
