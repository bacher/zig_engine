@group(0) @binding(0) var<uniform> clip_from_object: mat4x4<f32>;
@group(0) @binding(3) var depth_texture: texture_2d<u32>;

@vertex fn main(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4f {
    return clip_from_object * terrainVertex(vertex_index).position;
}
