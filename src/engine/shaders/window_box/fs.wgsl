@group(0) @binding(1) var<uniform> camera_position: vec4<f32>;
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

@fragment fn main(
    @location(0) local_xy: vec2<f32>,
) -> @location(0) vec4<f32> {
    var dx1 = camera_position[0] - local_xy[0];
    var dy1 = camera_position[1];
    var a1 = dy1 / dx1;
    var b1 = -a1 * local_xy[0];

    var dx2 = camera_position[2];
    var dy2 = camera_position[0] - local_xy[1]; // should be camera_position[1 or 2] probably
    var a2 = dy2 / dx2;
    var b2 = -a2 * local_xy[1];

    // return textureSample(color_texture, texture_sampler, vec2(local_xy.x, 1 - local_xy.y));
    return textureSample(color_texture, texture_sampler, vec2(b1, b2));
    // return textureSample(color_texture, texture_sampler, vec2(b1, 1 - b2));
}
