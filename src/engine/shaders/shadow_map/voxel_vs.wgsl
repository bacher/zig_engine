@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4<f32>;
@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(1) @binding(0) var<storage, read> chunk_info_array: array<GPU_ChunkInfo>;
@group(1) @binding(1) var<storage, read> block_array: array<u32>;

@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @builtin(vertex_index) vertex_index: u32,
) -> @builtin(position) vec4f {
    return clip_from_chunk * voxelVertex(instance_index, vertex_index).position;
}
