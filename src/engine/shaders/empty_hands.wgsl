struct EmptyHands {
    clip_from_hand: array<mat4x4f, 2>,
    view_from_hand: array<mat4x4f, 2>,
}
@group(0) @binding(0) var<uniform> hands: EmptyHands;
@group(1) @binding(0) var skin: texture_2d<f32>;
@group(1) @binding(1) var skin_sampler: sampler;

struct HandVertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) normal: vec3f,
}

fn armUv(side: u32, position: vec3f, hand: u32) -> vec2f {
    // Standard 64x64 skin: left arm at (32,48), right arm at (40,16).
    let origin = select(vec2f(32.0, 48.0), vec2f(40.0, 16.0), hand == 1u);
    var start = vec2f(0.0, 4.0);
    var size = vec2f(4.0, 12.0);
    var uv = vec2f(1.0 - position.y, position.z);
    switch side {
        case 0u: {}
        case 1u: { start.x = 8.0; uv.x = position.y; }
        case 2u: { start.x = 4.0; uv.x = position.x; }
        case 3u: { start.x = 12.0; uv.x = 1.0 - position.x; }
        // z=0 is the shoulder; z=1 is the fist at the end of the arm.
        case 4u: { start = vec2f(4.0, 0.0); size.y = 4.0; uv = vec2f(position.x, 1.0 - position.y); }
        default: { start = vec2f(8.0, 0.0); size.y = 4.0; uv = vec2f(position.x, position.y); }
    }
    return (origin + start + uv * size) / 64.0;
}

@vertex fn vs(@builtin(vertex_index) index: u32, @builtin(instance_index) hand: u32) -> HandVertex {
    let side = index / 6u;
    let position = vec3f(getPosition(side, index % 6u));
    return HandVertex(
        hands.clip_from_hand[hand] * vec4f(position, 1.0),
        armUv(side, position, hand),
        (hands.view_from_hand[hand] * vec4f(getNormal(side), 0.0)).xyz,
    );
}

@fragment fn fs(input: HandVertex) -> @location(0) vec4f {
    let color = textureSample(skin, skin_sampler, input.uv);
    let diffuse = max(dot(normalize(input.normal), normalize(vec3f(-0.4, 0.7, 0.6))), 0.0);
    return vec4f(color.rgb * (0.65 + 0.35 * diffuse), 1.0);
}
