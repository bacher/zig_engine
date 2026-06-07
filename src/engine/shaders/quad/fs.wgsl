@group(0) @binding(0) var color_texture: texture_2d<f32>;
@group(0) @binding(1) var normal_texture: texture_2d<f32>;
@group(0) @binding(2) var texture_sampler: sampler;

@fragment fn main(
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    // TODO: start to use normal_texture
    let color = textureSample(color_texture, texture_sampler, uv);
    return color * vec4f(2.0, 1.0, 1.0, 1.0);
}
