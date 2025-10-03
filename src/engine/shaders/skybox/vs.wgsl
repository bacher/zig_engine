@group(0) @binding(0) var<uniform> object_to_clip: mat4x4<f32>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) texcoord: vec2<f32>,
}

@vertex fn main(
    @location(0) position: vec3<f32>,
    // @location(1) normal: vec3<f32>,
    @location(1) texcoord: vec2<f32>,
) -> VertexOut {
    var output: VertexOut;
    output.position_clip = vec4(position, 1.0) * object_to_clip;
    output.texcoord = texcoord;
    return output;
}
