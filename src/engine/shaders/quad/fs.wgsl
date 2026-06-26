@group(0) @binding(0) var depth_texture: texture_2d<f32>;
@group(0) @binding(1) var color_texture: texture_2d<f32>;
@group(0) @binding(2) var view_space_normal_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var depth_sampler: sampler;
@group(0) @binding(5) var<uniform> clip_from_view: mat4x4<f32>;
@group(0) @binding(6) var<uniform> view_from_clip: mat4x4<f32>;

const KERNEL_SIZE = 32;
const RADIUS = 0.5;
const BIAS = 0.025;

fn uvToClipSpacePos(uv: vec2f) -> vec2f {
    return (uv - 0.5) * vec2f(2.0, -2.0);
}

fn clipSpaceToUv(clip_space_xy_pos: vec2f) -> vec2f {
    return clip_space_xy_pos * vec2f(0.5, -0.5) + 0.5;
}

fn reconstructViewSpacePosition(clip_space_xy_pos: vec2f, depth: f32) -> vec3f {
    var view_space_pos = view_from_clip * vec4f(clip_space_xy_pos, depth, 1.0);
    view_space_pos = view_space_pos / view_space_pos.w;
    return view_space_pos.xyz;
}

@fragment fn main(
    // @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    let color = textureSample(color_texture, texture_sampler, uv);

    var view_space_normal = textureSampleLevel(view_space_normal_texture, depth_sampler, uv, 0).xyz;
    // (debug) Display normals
    // return vec4f(view_space_normal, 1);

    // rgb [0..1] -> normal [-1..1] decoding
    view_space_normal = (view_space_normal - 0.5) * 2.0; // => [0, 1, 0]

    var depth = textureSampleLevel(depth_texture, depth_sampler, uv, 0).r;
    let view_space_pos = reconstructViewSpacePosition(uvToClipSpacePos(uv), depth);

    // (debug) to see depth texture:
    // let c = sqrt(sqrt(sqrt(1.0 - depth)));
    // return vec4f(c, 0, 0, 1.0);

    // (debug) to see view space position z:
    // return vec4f(-view_space_pos.z / 256.0, 0, 0, 1);

    /*
    let randomVec = vec3f(0, 0, -1);

    let tangent = normalize(randomVec - view_space_normal * dot(randomVec, view_space_normal));
    let bitangent = cross(view_space_normal, tangent);

    let TBN = mat3x3f(
        tangent,
        bitangent,
        view_space_normal,
    );
     */

    var occlusion = 0.0;

    // for (var i = 0; i < KERNEL_SIZE; i += 1) {
    // let view_space_sample_pos: vec3f = view_space_pos + TBN * kernel[i] * RADIUS;
    // TODO: From which side matrix should be?
    // let view_space_sample_pos: vec3f = view_space_pos + TBN * vec3f(0, 0, -1) * RADIUS;
    // let view_space_sample_pos: vec3f = view_space_pos + (vec3f(0, 0, -1) * RADIUS) * TBN;
    let view_space_sample_pos: vec3f = view_space_pos + (view_space_normal * RADIUS * 0.3); // -- using just direction toward normal

    var clip_space_offset = clip_from_view * vec4f(view_space_sample_pos, 1.0);
    clip_space_offset = clip_space_offset / clip_space_offset.w;

    var sample_uv = clipSpaceToUv(clip_space_offset.xy);
    let sample_depth = textureSampleLevel(depth_texture, depth_sampler, sample_uv, 0).r;

    let view_space_real_pos = reconstructViewSpacePosition(clip_space_offset.xy, sample_depth);

    let delta = view_space_real_pos.z - view_space_sample_pos.z;

    if (delta > BIAS && delta < 1.0) {
        occlusion += 1.0;
    }
    // }

    occlusion = 1.0 - occlusion;

    // (debug) to see occlusion:
    // return vec4f(occlusion, occlusion, occlusion, 1.0);

    // debug:
    if (occlusion < 0.5) {
        return vec4f(0.0, 1.0, 0.0, 1.0);
    } else {
        return color;
    }

    return vec4f(color.rgb * (0.5 + occlusion * 0.5), 1.0);
}
