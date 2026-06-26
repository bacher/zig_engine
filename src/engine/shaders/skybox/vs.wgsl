@group(1) @binding(0) var<uniform> clip_from_object: mat4x4<f32>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) texcoord: vec2<f32>,
}

@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @location(0) position: vec3<f32>,
    // @location(1) normal: vec3<f32>,
    @location(1) texcoord: vec2<f32>,
) -> VertexOut {
    var output: VertexOut;
    output.position_clip = clip_from_object * vec4(position, 1.0);
    output.texcoord = texcoord;
    return output;
}
