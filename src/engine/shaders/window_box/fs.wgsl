@group(0) @binding(1) var<uniform> camera_position: vec4<f32>;
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

fn isInBound(uv: vec2<f32>) -> bool {
    return uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1;
}

@fragment fn main(
    @location(0) local_xy: vec2<f32>,
) -> @location(0) vec4<f32> {
    var dx = camera_position.x - local_xy.x;
    var dy = camera_position.y;
    var a1 = dy / dx;
    var b1 = -a1 * local_xy.x;

    // local_xy.y is actually z axis in the space of window
    var dz = camera_position.z - local_xy.y;
    var a2 = dy / dz;
    var b2 = -a2 * local_xy.y;

    var u1 = b1;
    var p1 = vec2(u1, (u1 - b2) / a2);

    var u2 = a1 + b1;
    var p2 = vec2(1 - u2, (u2 - b2) / a2);

    var p = vec2(0.5, 0.5);

    if (isInBound(p1)) {
        p = p1;
    } else if (isInBound(p2)) {
        p = p2;
    }

    // return textureSample(color_texture, texture_sampler, vec2(local_xy.x, 1 - local_xy.y));
     return textureSample(color_texture, texture_sampler, vec2(p.x, 1 - p.y));
}
