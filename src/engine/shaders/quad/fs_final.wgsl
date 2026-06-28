@group(0) @binding(0) var depth_texture: texture_2d<f32>;
@group(0) @binding(1) var color_texture: texture_2d<f32>;
@group(0) @binding(2) var view_space_normal_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var depth_sampler: sampler;
@group(0) @binding(5) var<uniform> clip_from_view: mat4x4<f32>;
@group(0) @binding(6) var<uniform> view_from_clip: mat4x4<f32>;
@group(0) @binding(7) var<uniform> settings: u32;
@group(0) @binding(8) var ssao_texture: texture_2d<f32>;

const SSAO_ENABLED_MASK = 0x1;
const DEBUG_SSAO_ENABLED_MASK = 0x2;

@fragment fn main(
    @builtin(position) frag_coord: vec4<f32>,
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    let color = textureSampleLevel(color_texture, texture_sampler, uv, 0);
    let occlusion = textureSampleLevel(ssao_texture, texture_sampler, uv, 0).r;

    // SSAO debug mode: display occlusion as color
    if ((settings & DEBUG_SSAO_ENABLED_MASK) != 0) {
        return vec4f(occlusion, occlusion, occlusion, 1);
    }

    // if SSAO is disabled, return original color
    if ((settings & SSAO_ENABLED_MASK) == 0) {
        return color;
    }

    return vec4f(color.rgb * occlusion, color.a);
}
