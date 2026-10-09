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
    @location(0) normal: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) position_light_clip_0: vec4<f32>,
    @location(3) position_light_clip_1: vec4<f32>,
    @location(4) position_light_clip_2: vec4<f32>,
) -> FragmentOut {
    let normal_rgb_encoded = vec4f((normalize(normal) + 1.0) * 0.5, 0); // [-1..1] -> [0..1] encoding
    let color = textureSample(color_texture, texture_sampler, uv);

    if (color.a < 0.25) {
        discard;
    }

    let modifier = shadowFactor(
        shadow_map_texture,
        shadow_map_texture_sampler,
        position_light_clip_0,
        position_light_clip_1,
        position_light_clip_2,
    );

    return FragmentOut(
        vec4f(color.rgb * modifier, color.a),
        normal_rgb_encoded,
    );
}
