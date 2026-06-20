@group(0) @binding(0) var depth_texture: texture_2d<f32>;
@group(0) @binding(1) var color_texture: texture_2d<f32>;
@group(0) @binding(2) var normal_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var depth_sampler: sampler;
@group(0) @binding(5) var<uniform> clip_to_view: mat4x4<f32>;

@fragment fn main(
    // @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    // TODO: start to use normal_texture
    // var color = textureSample(color_texture, texture_sampler, uv);
    // return sqrt(color);

    let normal = textureSampleLevel(normal_texture, depth_sampler, uv, 0);

    return vec4f(normal.rgb, 1);

    var depth = textureSampleLevel(depth_texture, depth_sampler, uv, 0).r;
    var view_pos = vec4f((uv * 2) - 1, depth, 1.0) * clip_to_view;
    view_pos = view_pos / view_pos.w;

    return vec4f(-view_pos.z / 256.0, 0, 0, 1);
    // return vec4f(sqrt(pos.xy), 0, 1);
    // return vec4f(sqrt(-pos.z), 0, 0, 1);

    // return vec4f(sqrt(pos).xyz, 1.0);
    // return vec4f(sqrt(sqrt((-pos.zzz))), 1.0);
    // let z = -pos.z;
    // return vec4f(z*z*z,z*z*z,z*z*z, 1.0);

    // to see depth texture:
    // let c = sqrt(sqrt(sqrt(1.0 - depth)));
    // return vec4f(c, 0, 0, 1.0);
}
