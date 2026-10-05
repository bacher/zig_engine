@group(0) @binding(0) var<uniform> clip_from_object: mat4x4<f32>;
@group(0) @binding(3) var depth_texture: texture_2d<u32>;
@group(1) @binding(0) var<uniform> light_clip_from_object_array: array<mat4x4<f32>, 3>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) texcoord: vec2<f32>,
    @location(1) position_light_clip_0: vec4<f32>,
    @location(2) position_light_clip_1: vec4<f32>,
    @location(3) position_light_clip_2: vec4<f32>,
}

@vertex fn main(@builtin(vertex_index) vertex_index: u32) -> VertexOut {
    let vertex = terrainVertex(vertex_index);
    var output: VertexOut;
    output.position_clip = clip_from_object * vertex.position;
    output.position_light_clip_0 = light_clip_from_object_array[0] * vertex.position;
    output.position_light_clip_1 = light_clip_from_object_array[1] * vertex.position;
    output.position_light_clip_2 = light_clip_from_object_array[2] * vertex.position;
    output.texcoord = vertex.uv;
    return output;
}
