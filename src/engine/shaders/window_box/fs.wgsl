@group(0) @binding(1) var<uniform> camera_position_in_model_space: vec4<f32>;
@group(0) @binding(2) var color_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

const t3: f32 = 1.0 / 3.0;

fn isInBound(uv: vec2<f32>) -> bool {
    return uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1;
}

@fragment fn main(
    @location(0) _local_xy: vec2<f32>,
) -> @location(0) vec4<f32> {
    // all formulas assume that quad starts at point (0,0), but underlying mesh is
    // quad with coordinates (-0.5, -0.5), (0.5, 0.5), so we have to make
    // correction by shifting everything by 0.5 in each direction.
    let local_xy = _local_xy + vec2(0.5, 0.5);
    let camera_position = camera_position_in_model_space + vec4(0.5, 0.5, 0, 0);

    let dx = camera_position.x - local_xy.x;
    let dy = camera_position.y - local_xy.y;
    let dz = -camera_position.z; // negated because XZY was changed by XYZ at some point

    // Calculation of parameters needed for left and right walls
    let a_xz_hor = dz / dx;
    let b_xz_hor = -a_xz_hor * local_xy.x;

    let a_xz_ver = dz / dy;
    let b_xz_ver = -a_xz_ver * local_xy.y;

    let u_left = b_xz_hor;
    let p_left = vec2(u_left, (u_left - b_xz_ver) / a_xz_ver);

    // Calculation of parameters needed for ceiling and floor
    let a_yz_hor = dz / dy;
    let b_yz_hor = -a_yz_hor * local_xy.y;

    let a_yz_ver = dz / dx;
    let b_yz_ver = -a_yz_ver * local_xy.x;

    var p = vec2(0.5, 0.5);

    if (isInBound(p_left)) {
        p = vec2(p_left.x, 1 + p_left.y);
    } else {
        let u_right = a_xz_hor + b_xz_hor;
        let p_right = vec2(1 - u_right, (u_right - b_xz_ver) / a_xz_ver);
        if (isInBound(p_right)) {
            p = vec2(2 + p_right.x, 1 + p_right.y);
        } else {
            let u_bottom = b_yz_hor;
            let p_bottom = vec2((u_bottom - b_yz_ver) / a_yz_ver, u_bottom);
            if (isInBound(p_bottom)) {
                p = vec2(1 + p_bottom.x, p_bottom.y);
            } else {
                let u_top = a_yz_hor + b_yz_hor;
                let p_top = vec2((u_top - b_yz_ver) / a_yz_ver, 1 - u_top);
                if (isInBound(p_top)) {
                    p = vec2(1 + p_top.x, 2 + p_top.y);
                } else {
                    let p_far = vec2((1 - b_xz_hor) / a_xz_hor, (1 - b_yz_hor) / a_yz_hor);
                    p = vec2(1 + p_far.x, 1 + p_far.y);
                }
            }
        }
    }

    var color = textureSample(color_texture, texture_sampler, vec2(t3 * p.x, 1 - t3 * p.y));

    let p_middle = vec2((0.5 - b_xz_hor) / a_xz_hor, (0.5 - b_yz_hor) / a_yz_hor);
    let middle_color = textureSample(color_texture, texture_sampler, vec2(p_middle.x * t3, 1 - (2 + p_middle.y) * t3));
    if (isInBound(p_middle)) {
        color = mix(color, middle_color, middle_color.a);
    }

    let front_color = textureSample(color_texture, texture_sampler, vec2(t3 * local_xy.x, 1 - t3 * local_xy.y));
    return mix(color, front_color, front_color.a);
}
