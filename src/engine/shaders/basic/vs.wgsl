@group(0) @binding(0) var<uniform> clip_from_world: mat4x4<f32>;
@group(0) @binding(1) var<uniform> view_from_world: mat4x4<f32>;
@group(0) @binding(2) var<storage, read> instances: array<mat4x4<f32>>;
@group(2) @binding(0) var<uniform> light_clip_from_object_array: array<mat4x4<f32>, 3>;

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
) -> VertexOut {
    let position4 = vec4(position, 1.0);

    var output: VertexOut;
    output.position_clip = clip_from_world * (instances[instance_index] * position4);
    output.normal = (view_from_world * (instances[instance_index] * vec4f(normal, 0))).xyz;
    output.texcoord = texcoord;
    output.position_light_clip_0 = light_clip_from_object_array[0] * position4;
    output.position_light_clip_1 = light_clip_from_object_array[1] * position4;
    output.position_light_clip_2 = light_clip_from_object_array[2] * position4;
    return output;
}
