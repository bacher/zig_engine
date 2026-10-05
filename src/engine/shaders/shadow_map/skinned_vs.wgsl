@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4<f32>;
@group(0) @binding(2) var<storage, read> instances: array<ChunkTransform>;
@group(1) @binding(0) var<uniform> joint_matrices: array<mat4x4<f32>, 64>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
}

fn skinPosition(position: vec3<f32>, joints: vec4<u32>, weights: vec4<f32>) -> vec4<f32> {
    let position4 = vec4(position, 1.0);

    return (
        (joint_matrices[joints.x] * position4) * weights.x +
        (joint_matrices[joints.y] * position4) * weights.y +
        (joint_matrices[joints.z] * position4) * weights.z +
        (joint_matrices[joints.w] * position4) * weights.w
    );
}

@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @location(0) position: vec3<f32>,
    @location(3) joints: vec4<u32>,
    @location(4) weights: vec4<f32>,
) -> VertexOut {
    var output: VertexOut;
    output.position_clip = clip_from_chunk * relativePosition(instances[instance_index], origin_chunk, skinPosition(position, joints, weights));
    return output;
}
