@group(0) @binding(0) var depth_texture: texture_2d<f32>;
@group(0) @binding(1) var color_texture: texture_2d<f32>;
@group(0) @binding(2) var view_space_normal_texture: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var depth_sampler: sampler;
@group(0) @binding(5) var<uniform> clip_from_view: mat4x4<f32>;
@group(0) @binding(6) var<uniform> view_from_clip: mat4x4<f32>;
@group(0) @binding(7) var<uniform> settings: u32;

const SSAO_RADIUS = 0.5;
const SSAO_BIAS = 0.025;

const SSAO_ENABLED_MASK = 0x1;
const DEBUG_SSAO_ENABLED_MASK = 0x2;

// const SSAO_KERNEL_SIZE = 1;
// const SSAO_KERNEL = array<vec3f, 1>(
//     vec3f(0, 0, 1),
// );

const SSAO_KERNEL_SIZE = 32;
const SSAO_KERNEL = array<vec3f, 32>(
  vec3f(-0.09555241442495643, 0.02948006269226752, 0.0008136345748281673),
  vec3f(-0.09050782102145659, -0.0063360277235050815, 0.04409923823413788),
  vec3f(0.06563689164074234, 0.020736388676619533, 0.07731290487062455),
  vec3f(-0.03159548717563423, -0.08752147328198008, 0.05464722066661207),
  vec3f(-0.04652914930259321, 0.06436448853140825, 0.08186882671394044),
  vec3f(-0.08427580973393195, -0.04517958063077787, 0.07572134613434844),
  vec3f(-0.0747258828004649, -0.010715737438193092, 0.10784465476432997),
  vec3f(-0.044377191621185634, 0.016326000700054966, 0.13502637950507454),
  vec3f(0.04491348206547165, 0.06435321772974423, 0.13511293423126702),
  vec3f(0.0004323601631414793, 0.043445811799083814, 0.16558614699201277),
  vec3f(0.016371390670303163, -0.18157155300746208, 0.04546026472502475),
  vec3f(-0.04105078916189706, 0.13897634082786056, 0.14690052634062273),
  vec3f(-0.13498240364760378, 0.004591542991284537, 0.18190446625832074),
  vec3f(-0.11295966311566995, 0.05073372416653277, 0.21548997107336676),
  vec3f(-0.1985124980336821, 0.1246343980000296, 0.13851940483642797),
  vec3f(0.24204801653244232, -0.17008023773519018, 0.03380619930997096),
  vec3f(-0.20223536218136023, -0.2201301125724173, 0.12754839012009894),
  vec3f(0.031233197209311257, -0.15349113774410852, 0.3174645234768165),
  vec3f(-0.1263676188516512, 0.2950101291686231, 0.21223768462579104),
  vec3f(-0.2964335476017894, -0.25244025537797254, 0.1500932075328815),
  vec3f(0.41638242772370687, 0.13275700390570203, 0.11362193099548815),
  vec3f(0.4050858734426146, -0.18289192405899735, 0.20051796336419636),
  vec3f(-0.24639230041248664, -0.40824017573527244, 0.22060394840294104),
  vec3f(-0.5525282510459538, -0.11363278858808061, 0.030966330901859494),
  vec3f(0.4285368861113333, 0.1980422254361793, 0.3803609820766158),
  vec3f(0.4635206333749995, 0.4445973534366234, 0.09536042773710986),
  vec3f(0.15298724615510706, 0.38942336609257155, 0.5538732271290951),
  vec3f(0.27116351729806915, -0.2630604280370025, 0.6371339039555064),
  vec3f(-0.37758927065289516, -0.5714090546530163, 0.3918388238225137),
  vec3f(0.21479823939456172, 0.5163533511821707, 0.6256442287062695),
  vec3f(0.6718165091032104, 0.5851769609090887, 0.011804512345682517),
  vec3f(0.774802160687627, -0.5343406425546507, 0.08053235394013397),
);

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

    let randomVec = vec3f(0, 0, -1);

    let tangent = normalize(randomVec - view_space_normal * dot(randomVec, view_space_normal));
    let bitangent = cross(view_space_normal, tangent);

    let TBN = mat3x3f(
        tangent,
        bitangent,
        view_space_normal,
    );

    var occlusion = 0.0;

    for (var i = 0; i < SSAO_KERNEL_SIZE; i += 1) {
        // let view_space_sample_pos: vec3f = view_space_pos + TBN * SSAO_KERNEL[i] * SSAO_RADIUS * 0.3;
        let view_space_sample_pos: vec3f = view_space_pos + (view_space_normal * SSAO_RADIUS * 0.3); // -- using just direction toward normal

        var clip_space_offset = clip_from_view * vec4f(view_space_sample_pos, 1.0);
        clip_space_offset = clip_space_offset / clip_space_offset.w;

        var sample_uv = clipSpaceToUv(clip_space_offset.xy);
        let sample_depth = textureSampleLevel(depth_texture, depth_sampler, sample_uv, 0).r;

        let view_space_real_pos = reconstructViewSpacePosition(clip_space_offset.xy, sample_depth);

        let delta = view_space_real_pos.z - view_space_sample_pos.z;

        if (delta > SSAO_BIAS && delta < 1.0) {
        // if (delta > SSAO_BIAS) {
            occlusion += 1.0;
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
