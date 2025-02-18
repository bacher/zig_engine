@group(0) @binding(1) var<uniform> camera_position: vec4<f32>;
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

@fragment fn main(
    @location(0) local_xy: vec2<f32>,
) -> @location(0) vec4<f32> {
    var dx1 = camera_position.x - local_xy.x;
    var dy1 = camera_position.y;
    var a1 = dy1 / dx1;
    var b1 = -a1 * local_xy.x;

    // local_xy.y is actually z axis in the space of window
    var dz2 = camera_position.z - local_xy.y;
    var dy2 = camera_position.y;
    var a2 = dy2 / dz2;
    var b2 = -a2 * local_xy.y;

    var z2 = (b1 - b2) / a2;

    // return textureSample(color_texture, texture_sampler, vec2(local_xy.x, 1 - local_xy.y));
     return textureSample(color_texture, texture_sampler, vec2(b1, 1 - z2));
}
