@group(0) @binding(0) var<uniform> object_to_clip: mat4x4<f32>;
@group(0) @binding(4) var depth_texture: texture_2d<f32>;
@group(0) @binding(5) var depth_texture_sampler: sampler;

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

/*
const positions = array(
    /* 0  */ vec2f(0, 1),
    /* 1  */ vec2f(0, 0),
    /* 2  */ vec2f(1, 1),
    /* 3  */ vec2f(1, 0),
    /* 4  */ vec2f(2, 1),
    /* 5  */ vec2f(2, 0),
    /* 6  */ vec2f(3, 1),
    /* 7  */ vec2f(3, 0),
    /* 8  */ vec2f(4, 1),
    /* 9  */ vec2f(4, 0),
    /* 10 */ vec2f(4, 1),
    /* 11 */ vec2f(4, 1),
    // --
    /* 12 */ vec2f(4, 1),
    /* 13 */ vec2f(4, 2),
    /* 14 */ vec2f(3, 1),
    /* 15 */ vec2f(3, 2),
    /* 16 */ vec2f(2, 1),
    /* 17 */ vec2f(2, 2),
    /* 18 */ vec2f(1, 1),
    /* 19 */ vec2f(1, 2),
    /* 20 */ vec2f(0, 1),
    /* 21 */ vec2f(0, 2),
    /* 22 */ vec2f(0, 2),
    /* 23 */ vec2f(0, 2),
);
*/

@vertex fn main(
    @builtin(vertex_index) vertex_index: u32,
) -> VertexOut {
    let a: u32 = vertex_index / 24;
    let b: u32 = vertex_index % 24;
    let c = b % 12;
    let d = b / 12;

    // let center = abs(f32(b) - 9.5);
    // let x = max(4 - floor(center * 0.5), 0);
    // let y = min(floor(center) % 2 + floor(f32(b) * 0.1), 2) + f32(a * 2);

    let x = max(0, min(4, floor(5.25 - abs((f32(b) - 10.5) / 2))));
    
    // There're two ways:
    // 1. to do all math in f32
    // 2. to do all math in u32 but with converstion for step function,
    //    since it supports only floating point numbers
    // which one is more performant?

    // let y = min(f32(d + 1), f32((b + d + 1) % 2) + step(10.0, f32(c)) + f32(d)) + f32(a * 2);
    let y = f32(min(d + 1, (b + d + 1) % 2 + u32(step(10.0, f32(c))) + d) + a * 2);

    // let x = positions[b].x;
    // let y = positions[b].y + f32(a * 2);

    // -- z --
    let uv = vec2f(x * 0.25, 1 - y * 0.25);
    let depth = textureSampleLevel(depth_texture, depth_texture_sampler, uv, 0).r;

    let position4 = vec4(
        x * 0.5 - 1,
        y * 0.5 - 1,
        depth,
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
