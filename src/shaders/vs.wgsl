@group(0) @binding(0) var<uniform> object_to_clip: mat4x4<f32>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) color: vec3<f32>,
}

@vertex fn main(
    @location(0) position: vec3<f32>,
//    @location(1) color: vec3<f32>,
) -> VertexOut {
    var output: VertexOut;
    output.position_clip = vec4(position, 1.0) * object_to_clip;
    output.color = vec3(0.0, 1.0, 0.0);
    return output;
}
