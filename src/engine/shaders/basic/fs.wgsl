// TODO: Should be texture f32 or u8 is also okay?
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

@fragment fn main(
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    return textureSample(color_texture, texture_sampler, uv);
}
