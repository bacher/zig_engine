@group(0) @binding(0) var depth_texture: texture_2d<f32>;
@group(0) @binding(1) var color_texture: texture_2d<f32>;
@group(0) @binding(2) var normal_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var depth_sampler: sampler;

@fragment fn main(
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    // TODO: start to use normal_texture
    // var color = textureSample(color_texture, texture_sampler, uv);
    // return sqrt(color);

    // to see depth texture:
    var depth = textureSampleLevel(depth_texture, depth_sampler, uv, 0).r;
    let c = sqrt(sqrt(sqrt(1.0 - depth)));
    return vec4f(c, 0, 0, 1.0);
}
