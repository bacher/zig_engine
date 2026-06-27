const SSAO_KERNEL_SIZE = 16;

@group(0) @binding(0) var depth_texture: texture_2d<f32>;
@group(0) @binding(1) var color_texture: texture_2d<f32>;
@group(0) @binding(2) var view_space_normal_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var depth_sampler: sampler;
@group(0) @binding(5) var<uniform> clip_from_view: mat4x4<f32>;
@group(0) @binding(6) var<uniform> view_from_clip: mat4x4<f32>;
@group(0) @binding(7) var<uniform> settings: u32;
@group(0) @binding(8) var<storage, read> ssao_kernel: array<vec3f, SSAO_KERNEL_SIZE>;

const NOISE_VECTORS = array<vec2f, 16>(
    vec2f(-0.7522673109163377,   0.658858021827694),
    vec2f(-0.406561663132687,    0.9136233436546942),
    vec2f(-0.6058867822895615,   0.7955508827515695),
    vec2f( 0.5900196794141315,   0.8073888641194189),
    vec2f(-0.9993966302936446,   0.034732914615797514),
    vec2f(-0.19997339442560727, -0.979801327577127),
    vec2f( 0.5906710419426898,   0.8069124613056469),
    vec2f( 0.22808847069883675, -0.9736404107956211),
    vec2f( 0.1396678315580476,   0.9901984128586921),
    vec2f( 0.17516184299346685,  0.9845396532182602),
    vec2f( 0.6675832326174399,   0.7445351754806815),
    vec2f(-0.9296517732480357,  -0.36843938510531515),
    vec2f( 0.4622709410139219,   0.8867387310217724),
    vec2f(-0.9537578153151433,   0.3005761629359273),
    vec2f(-0.8344127230243967,   0.5511400980286332),
    vec2f( 0.46230915296333175,  0.8867188094803937),
);

const SSAO_RADIUS = 0.5;
const SSAO_BIAS = 0.025;

const SSAO_ENABLED_MASK = 0x1;
const DEBUG_SSAO_ENABLED_MASK = 0x2;


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
    @builtin(position) frag_coord: vec4<f32>,
    @location(0) uv: vec2<f32>,
) -> @location(0) vec4<f32> {
    let color = textureSample(color_texture, texture_sampler, uv);

    // if SSAO is disabled, return original color
    if ((settings & SSAO_ENABLED_MASK) == 0 && (settings & DEBUG_SSAO_ENABLED_MASK) == 0) {
        return color;
    }

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

    let noise_x = u32(frag_coord.x) % 4;
    let noise_y = u32(frag_coord.y) % 4;
    let random_vec = vec3f(NOISE_VECTORS[noise_y * 4 + noise_x], 0);
    // or just use some fixed random vector:
    // let random_vec = vec3f(0, 0, -1);

    let tangent = normalize(random_vec - view_space_normal * dot(random_vec, view_space_normal));
    let bitangent = cross(view_space_normal, tangent);

    let TBN = mat3x3f(
        tangent,
        bitangent,
        view_space_normal,
    );

    var occlusion = 0.0;

    for (var i = 0; i < SSAO_KERNEL_SIZE; i += 1) {
        let view_space_sample_pos: vec3f = view_space_pos + TBN * ssao_kernel[i] * SSAO_RADIUS;
        // let view_space_sample_pos: vec3f = view_space_pos + (view_space_normal * SSAO_RADIUS * 0.3); // -- using just direction toward normal

        var clip_space_offset = clip_from_view * vec4f(view_space_sample_pos, 1.0);
        clip_space_offset = clip_space_offset / clip_space_offset.w;

        var sample_uv = clipSpaceToUv(clip_space_offset.xy);
        let sample_depth = textureSampleLevel(depth_texture, depth_sampler, sample_uv, 0).r;

        let view_space_real_pos = reconstructViewSpacePosition(clip_space_offset.xy, sample_depth);

        let delta = view_space_real_pos.z - view_space_sample_pos.z;

        // More lightweight version, but with almost the same result:
        // if (delta > SSAO_BIAS && delta < SSAO_RADIUS) {
        //     occlusion += 1;
        // }

        // More accurate version, but with more computational cost:
        if (delta > SSAO_BIAS) {
            occlusion += smoothstep(0, 1, SSAO_RADIUS / abs(view_space_pos.z - view_space_real_pos.z));
        }
    }

    occlusion = 1.0 - occlusion / SSAO_KERNEL_SIZE;

    // (debug) to see occlusion:
    if ((settings & DEBUG_SSAO_ENABLED_MASK) != 0) {
        return vec4f(occlusion, occlusion, occlusion, 1.0);
    }

    // debug version (using pure green if occlusion is less than 0.5):
    // if (occlusion < 0.5) {
    //     return vec4f(0.0, 1.0, 0.0, 1.0);
    // } else {
    //     return color;
    // }

    return vec4f(color.rgb * (0.5 + occlusion * 0.5), 1.0);
}
