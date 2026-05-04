// TODO: Should be texture f32 or u8 is also okay?
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

@group(0) @binding(5) var mixing_texture: texture_2d<f32>;
@group(0) @binding(6) var color_texture_2: texture_2d<f32>;
@group(0) @binding(7) var<uniform> time_ms: u32;

// shadow map bind group
@group(1) @binding(1) var shadow_map_texture: texture_2d_array<f32>;
@group(1) @binding(2) var shadow_map_texture_sampler: sampler;

// const bayer_pattern = array(
//     array(0.0, 8.0, 2.0, 10.0),
//     array(12.0, 4.0, 14.0, 6.0),
//     array(3.0, 11.0, 1.0, 9.0),
//     array(15.0, 7.0, 13.0, 5.0),
// ) + 1 / 17.0; => 
const bayer_pattern = array(
    array(0.058823529411764705, 0.5294117647058824, 0.17647058823529413, 0.6470588235294118),
    array(0.7647058823529411, 0.29411764705882354, 0.8823529411764706, 0.4117647058823529),
    array(0.23529411764705882, 0.7058823529411765, 0.11764705882352941, 0.5882352941176471),
    array(0.9411764705882353, 0.47058823529411764, 0.8235294117647058, 0.35294117647058826),
);

const bayer_size = vec2(4, 4);

@fragment fn main(
    @location(0) uv: vec2<f32>,
    @location(1) position_light_clip_0: vec4<f32>,
    @location(2) position_light_clip_1: vec4<f32>,
    @location(3) position_light_clip_2: vec4<f32>,
    @builtin(position) frag_coord: vec4<f32>,
) -> @location(0) vec4<f32> {
    let pixel = vec2u(floor(frag_coord.xy)); // integer pixel index
    let bayer = pixel % bayer_size;
    let bayer_value = bayer_pattern[bayer.x][bayer.y];
    
    var mask = textureSample(mixing_texture, texture_sampler, uv);

    let dx = dpdx(uv);
    let dy = dpdy(uv);

    var color: vec4<f32>;
    if (mask.r > bayer_value) {
        color = textureSampleGrad(color_texture_2, texture_sampler, uv, dx, dy);
    } else {
        color = textureSampleGrad(color_texture, texture_sampler, uv, dx, dy);
    }

    // Then the same as in `basic/fs.wgsl`:
    // TODO: think about deduplication of the code - modularization?

    let shadow_map_uv_0 = clipToUv(position_light_clip_0);
    let shadow_map_uv_1 = clipToUv(position_light_clip_1);
    let shadow_map_uv_2 = clipToUv(position_light_clip_2);

    let shadow_map_layer_0_depth = textureSample(
        shadow_map_texture,
        shadow_map_texture_sampler,
        shadow_map_uv_0,
        0,
    ).r;
    let shadow_map_layer_1_depth = textureSample(
        shadow_map_texture,
        shadow_map_texture_sampler,
        shadow_map_uv_1,
        1,
    ).r;
    let shadow_map_layer_2_depth = textureSample(
        shadow_map_texture,
        shadow_map_texture_sampler,
        shadow_map_uv_2,
        2,
    ).r;

    if (color.a < 0.25) {
        discard;
    }

    // if (shadow_map_depth + 0.002 < position_light_clip.z / position_light_clip.w) {
    // vs
    // if (shadow_map_depth - 0.002 < position_light_clip.z) {

    if (
        position_light_clip_2.x >= -1 && position_light_clip_2.x <= 1 &&
        position_light_clip_2.y >= -1 && position_light_clip_2.y <= 1 &&
        position_light_clip_2.z >= 0 && position_light_clip_2.z <= 1
    ) {
        var modifier = 1.0;
        if (shadow_map_layer_2_depth + 0.002 < position_light_clip_2.z / position_light_clip_2.w) {
            modifier = 0.5;
        }
        return vec4f(color.rgb * modifier, color.a);
    }

    if (
        position_light_clip_1.x >= -1 && position_light_clip_1.x <= 1 &&
        position_light_clip_1.y >= -1 && position_light_clip_1.y <= 1 &&
        position_light_clip_1.z >= 0 && position_light_clip_1.z <= 1
    ) {
        var modifier = 1.0;
        if (shadow_map_layer_1_depth + 0.008 < position_light_clip_1.z / position_light_clip_1.w) {
            modifier = 0.5;
        }
        return vec4f(color.rgb * modifier, color.a);
    }

    // TODO: This condition is redundant, because the last layer of shadow map is always
    // fully includes the camera frustum, so the point should always be in the shadow map's
    // clip space.
    // if (
    //     position_light_clip_0.x >= -1 && position_light_clip_0.x <= 1 &&
    //     position_light_clip_0.y >= -1 && position_light_clip_0.y <= 1
    //     // should we check for z of last layer as well?
    //     // position_light_clip_0.z >= 0 && position_light_clip_0.z <= 1
    // ) {
        var modifier = 1.0;
        if (shadow_map_layer_0_depth + 0.02 < position_light_clip_0.z / position_light_clip_0.w) {
            modifier = 0.5;
        }
        return vec4f(color.rgb * modifier, color.a);
    // }

    // return vec4f(color.rgb * 0.05, color.a);
}

fn clipToUv(light_clip_pos: vec4<f32>) -> vec2<f32> {
    return vec2f(
        (light_clip_pos.x + 1.0) * 0.5,
        1.0 - (light_clip_pos.y + 1.0) * 0.5,
    );
}