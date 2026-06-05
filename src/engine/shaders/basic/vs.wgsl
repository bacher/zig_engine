@group(0) @binding(0) var<uniform> world_to_clip: mat4x4<f32>;
@group(0) @binding(1) var<storage, read> instances: array<mat4x4<f32>>;
@group(2) @binding(0) var<uniform> object_to_light_clip_array: array<mat4x4<f32>, 3>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) texcoord: vec2<f32>,
    @location(1) position_light_clip_0: vec4<f32>,
    @location(2) position_light_clip_1: vec4<f32>,
    @location(3) position_light_clip_2: vec4<f32>,
}

@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) texcoord: vec2<f32>,
) -> VertexOut {
    _ = normal;

    let position4 = vec4(position, 1.0);

    var output: VertexOut;
    output.position_clip = position4 * instances[instance_index] * world_to_clip;
    output.position_light_clip_0 = position4 * object_to_light_clip_array[0];
    output.position_light_clip_1 = position4 * object_to_light_clip_array[1];
    output.position_light_clip_2 = position4 * object_to_light_clip_array[2];
    output.texcoord = texcoord;
    return output;
}
