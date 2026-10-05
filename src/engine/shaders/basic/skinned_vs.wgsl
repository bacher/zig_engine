@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4<f32>;
@group(0) @binding(1) var<uniform> view_from_world: mat4x4<f32>;
@group(0) @binding(2) var<storage, read> instances: array<ChunkTransform>;
@group(2) @binding(0) var<uniform> light_clip_from_chunk_array: array<mat4x4<f32>, 3>;
@group(3) @binding(0) var<uniform> joint_matrices: array<mat4x4<f32>, 64>;

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
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) texcoord: vec2<f32>,
    @location(3) joints: vec4<u32>,
    @location(4) weights: vec4<f32>,
) -> VertexOut {
    let position4 = skinPosition(position, joints, weights);

    let relative_position = relativePosition(instances[instance_index], origin_chunk, position4);
    var output: VertexOut;
    output.position_clip = clip_from_chunk * relative_position;
    output.normal = (view_from_world * (instances[instance_index].chunk_from_model * vec4f(normal, 0))).xyz;
    output.position_light_clip_0 = light_clip_from_chunk_array[0] * relative_position;
    output.position_light_clip_1 = light_clip_from_chunk_array[1] * relative_position;
    output.position_light_clip_2 = light_clip_from_chunk_array[2] * relative_position;
    output.texcoord = texcoord;
    return output;
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
