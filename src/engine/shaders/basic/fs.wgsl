// TODO: Should be texture f32 or u8 is also okay?
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

// shadow map bind group
@group(1) @binding(1) var shadow_map_texture: texture_2d<f32>;
@group(1) @binding(2) var shadow_map_texture_sampler: sampler;

@fragment fn main(
    @location(0) position_light_clip: vec4<f32>,
    @location(1) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    var color = textureSample(color_texture, texture_sampler, uv);

    let shadow_map_uv = vec2f(
        (position_light_clip.x + 1.0) * 0.5,
        1.0 - (position_light_clip.y + 1.0) * 0.5,
    );

    let shadow_map_depth = textureSample(
        shadow_map_texture,
        shadow_map_texture_sampler,
        shadow_map_uv,
    ).r;

    if (color.a < 0.5) {
        discard;
    }

    if (shadow_map_uv.x < 0 || shadow_map_uv.x > 1 || shadow_map_uv.y < 0 || shadow_map_uv.y > 1) {
        return vec4f(color.rgb * 0.05, color.a);
    }

    if (shadow_map_depth + 0.01 < position_light_clip.z / position_light_clip.w) {
    // if (shadow_map_depth - 0.01 < position_light_clip.z) {
        color = vec4f(color.rgb * 0.5, color.a);
    }

    return color;
}
