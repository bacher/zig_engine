@group(0) @binding(1) var<uniform> view_from_world: mat4x4f;
@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4f;
@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(2) @binding(0) var<uniform> light_clip_from_chunk_array: array<mat4x4f, 3>;
@group(3) @binding(2) var<storage, read> custom_blocks: array<GPU_CustomBlock>;

struct VertexOut {
    @builtin(position) position_clip: vec4f,
    @location(0) normal: vec3f,
    @location(1) texcoord: vec2f,
    @location(2) position_light_clip_0: vec4f,
    @location(3) position_light_clip_1: vec4f,
    @location(4) position_light_clip_2: vec4f,
    @location(5) @interpolate(flat) material_and_side: vec2u,
}

@vertex fn main(@builtin(instance_index) instance_index: u32, @builtin(vertex_index) vertex_index: u32) -> VertexOut {
    let vertex = customVertex(instance_index, vertex_index);
    return VertexOut(clip_from_chunk * vertex.position,
        (view_from_world * vec4f(vertex.normal, 0.0)).xyz, vertex.uv,
        light_clip_from_chunk_array[0] * vertex.position,
        light_clip_from_chunk_array[1] * vertex.position,
        light_clip_from_chunk_array[2] * vertex.position, vertex.material_and_side);
}
