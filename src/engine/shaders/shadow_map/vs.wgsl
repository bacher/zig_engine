@group(0) @binding(0) var<uniform> world_to_clip: mat4x4<f32>;
@group(0) @binding(2) var<storage, read> instances: array<mat4x4<f32>>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
}

@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @location(0) position: vec3<f32>,
) -> VertexOut {
    var output: VertexOut;
    output.position_clip = vec4(position, 1.0) * instances[instance_index] * world_to_clip;
    return output;
}
