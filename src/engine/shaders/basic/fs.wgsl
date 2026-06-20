// TODO: Should be texture f32 or u8 is also okay?
@group(1) @binding(0) var color_texture: texture_2d<f32>;
@group(1) @binding(1) var texture_sampler: sampler;

// shadow map bind group
@group(2) @binding(1) var shadow_map_texture: texture_2d_array<f32>;
@group(2) @binding(2) var shadow_map_texture_sampler: sampler;

struct FragmentOut {
    @location(0) color: vec4<f32>,
    @location(1) normal: vec4<f32>,
}

@fragment fn main(
    @location(0) normal_float: vec4<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) position_light_clip_0: vec4<f32>,
    @location(3) position_light_clip_1: vec4<f32>,
    @location(4) position_light_clip_2: vec4<f32>,
) -> FragmentOut {
    let normal = (normal_float + 1) * 0.5;
    var color = textureSample(color_texture, texture_sampler, uv);

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
        return FragmentOut(
            vec4f(color.rgb * modifier, color.a),
            normal,
        );
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
        return FragmentOut(
            vec4f(color.rgb * modifier, color.a),
            normal,
        );
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
        return FragmentOut(
            vec4f(color.rgb * modifier, color.a),
            normal,
        );
    // }

    // return vec4f(color.rgb * 0.05, color.a);
}

fn clipToUv(light_clip_pos: vec4<f32>) -> vec2<f32> {
    return vec2f(
        (light_clip_pos.x + 1.0) * 0.5,
        1.0 - (light_clip_pos.y + 1.0) * 0.5,
    );
}