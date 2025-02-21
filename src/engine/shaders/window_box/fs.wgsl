@group(0) @binding(1) var<uniform> camera_position: vec4<f32>;
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

fn isInBound(uv: vec2<f32>) -> bool {
    return uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1;
}

@fragment fn main(
    @location(0) local_xy: vec2<f32>,
) -> @location(0) vec4<f32> {
    let dx = camera_position.x - local_xy.x;
    let dy = camera_position.y;
    // local_xy.y is actually z axis in the space of window
    let dz = camera_position.z - local_xy.y;

    // Calculation of parameters needed for left and right walls
    let a_1_hor = dy / dx;
    let b_1_hor = -a_1_hor * local_xy.x;

    let a_1_ver = dy / dz;
    let b_1_ver = -a_1_ver * local_xy.y;

    let u_left = b_1_hor;
    let p_left = vec2(u_left, (u_left - b_1_ver) / a_1_ver);

    let u_right = a_1_hor + b_1_hor;
    let p_right = vec2(1 - u_right, (u_right - b_1_ver) / a_1_ver);

    // Calculation of parameters needed for ceiling and floor
    let a_2_hor = dy / dz;
    let b_2_hor = -a_2_hor * local_xy.y;

    let a_2_ver = dy / dx;
    let b_2_ver = -a_2_ver * local_xy.x;

    let u_bottom = b_2_hor;
    let p_bottom = vec2((u_bottom - b_2_ver) / a_2_ver, u_bottom);

    let u_top = a_2_hor + b_2_hor;
    let p_top = vec2((u_top - b_2_ver) / a_2_ver, 1 - u_top);

    var p = vec2(0.5, 0.5);

    if (isInBound(p_left)) {
        p = p_left;
    } else if (isInBound(p_right)) {
        p = p_right;
    } else if (isInBound(p_bottom)) {
        p = p_bottom;
    } else if (isInBound(p_top)) {
        p = p_top;
    }

    // return textureSample(color_texture, texture_sampler, vec2(local_xy.x, 1 - local_xy.y));
    return textureSample(color_texture, texture_sampler, vec2(p.x, 1 - p.y));
}
