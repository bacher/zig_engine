@group(0) @binding(0) var color_texture: texture_2d<f32>;
@group(0) @binding(1) var texture_sampler: sampler;

@fragment fn main(
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    let color = textureSample(color_texture, texture_sampler, uv);
    // return vec4f(color.rrr / 255.0, 1.0);
    return vec4f(1.0 - color.rrr, 1.0);
}
