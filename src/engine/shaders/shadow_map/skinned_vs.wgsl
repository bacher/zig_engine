@group(0) @binding(0) var<uniform> world_to_clip: mat4x4<f32>;
@group(0) @binding(1) var<storage, read> instances: array<mat4x4<f32>>;
@group(1) @binding(0) var<uniform> joint_matrices: array<mat4x4<f32>, 64>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
}

fn skinPosition(position: vec3<f32>, joints: vec4<u32>, weights: vec4<f32>) -> vec4<f32> {
    let position4 = vec4(position, 1.0);

    return
        (position4 * joint_matrices[joints.x]) * weights.x +
        (position4 * joint_matrices[joints.y]) * weights.y +
        (position4 * joint_matrices[joints.z]) * weights.z +
        (position4 * joint_matrices[joints.w]) * weights.w;
}

@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @location(0) position: vec3<f32>,
    @location(3) joints: vec4<u32>,
    @location(4) weights: vec4<f32>,
) -> VertexOut {
    var output: VertexOut;
    output.position_clip = skinPosition(position, joints, weights) * instances[instance_index] * world_to_clip;
    return output;
}
