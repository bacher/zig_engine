@group(0) @binding(0) var<uniform> object_to_clip: mat4x4<f32>;
@group(1) @binding(0) var<uniform> object_to_light_clip_array: array<mat4x4<f32>, 3>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) texcoord: vec2<f32>,
    @location(1) position_light_clip_0: vec4<f32>,
    @location(2) position_light_clip_1: vec4<f32>,
    @location(3) position_light_clip_2: vec4<f32>,
}

/*
const positions = array(
    vec2f(0, 1),
    vec2f(0, 0),
    vec2f(1, 1),
    vec2f(1, 0),
    vec2f(2, 1),
    vec2f(2, 0),
    vec2f(3, 1),
    vec2f(3, 0),
    vec2f(4, 1),
    vec2f(4, 0),
    //
    vec2f(4, 1),
    vec2f(4, 2),
    vec2f(3, 1),
    vec2f(3, 2),
    vec2f(2, 1),
    vec2f(2, 2),
    vec2f(1, 1),
    vec2f(1, 2),
    vec2f(0, 1),
    vec2f(0, 2),
    vec2f(0, 2),
    vec2f(0, 2),
);
*/

@vertex fn main(
    @builtin(vertex_index) vertex_index: u32,
) -> VertexOut {
    let a: u32 = vertex_index / 22;
    let b: u32 = vertex_index % 22;

    let center = abs(f32(b) - 9.5);
    let x = max(4 - floor(center * 0.5), 0);
    let y = min(floor(center) % 2 + floor(f32(b) * 0.1), 2) + f32(a * 2);

    let position4 = vec4(
        x * 0.5 - 1,
        y * 0.5 - 1,
        0.0,
        1.0,
    );

    var output: VertexOut;
    output.position_clip = position4 * object_to_clip;
    output.position_light_clip_0 = position4 * object_to_light_clip_array[0];
    output.position_light_clip_1 = position4 * object_to_light_clip_array[1];
    output.position_light_clip_2 = position4 * object_to_light_clip_array[2];
    output.texcoord = vec2f(x * 0.25, 1 - y * 0.25);
    return output;
}
