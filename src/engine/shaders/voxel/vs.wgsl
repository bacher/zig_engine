@group(0) @binding(1) var<uniform> view_from_world: mat4x4<f32>;
@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4<f32>;
@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(2) @binding(0) var<uniform> light_clip_from_chunk_array: array<mat4x4<f32>, 3>;
@group(3) @binding(0) var<storage, read> chunk_info_array: array<GPU_ChunkInfo>;
@group(3) @binding(1) var<storage, read> block_array: array<u32>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) texcoord: vec2<f32>,
    // --
    @location(2) position_light_clip_0: vec4<f32>,
    @location(3) position_light_clip_1: vec4<f32>,
    @location(4) position_light_clip_2: vec4<f32>,
}


@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @builtin(vertex_index) vertex_index: u32,
) -> VertexOut {
    let vertex = voxelVertex(instance_index, vertex_index);
    var output: VertexOut;
    output.position_clip = clip_from_chunk * vertex.position;
    output.normal = (view_from_world * vec4f(vertex.normal, 0)).xyz;
    output.texcoord = vertex.uv;
    output.position_light_clip_0 = light_clip_from_chunk_array[0] * vertex.position;
    output.position_light_clip_1 = light_clip_from_chunk_array[1] * vertex.position;
    output.position_light_clip_2 = light_clip_from_chunk_array[2] * vertex.position;
    return output;
}
