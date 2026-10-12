@group(0) @binding(0) var<uniform> clip_from_block: mat4x4f;
// xy: viewport in pixels, z: full stroke width in pixels.
@group(0) @binding(1) var<uniform> stroke: vec4f;

const edges = array<vec2u, 12>(
    vec2u(0, 1), vec2u(2, 3), vec2u(4, 5), vec2u(6, 7),
    vec2u(0, 2), vec2u(1, 3), vec2u(4, 6), vec2u(5, 7),
    vec2u(0, 4), vec2u(1, 5), vec2u(2, 6), vec2u(3, 7),
);
const quad = array<vec2f, 6>(
    vec2f(0, -1), vec2f(1, -1), vec2f(0, 1),
    vec2f(0, 1), vec2f(1, -1), vec2f(1, 1),
);

fn corner(index: u32) -> vec3f {
    return vec3f(f32(index & 1u), f32((index >> 1u) & 1u), f32((index >> 2u) & 1u));
}

@vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    let edge = edges[index / 6u];
    var a = clip_from_block * vec4f(corner(edge.x), 1);
    var b = clip_from_block * vec4f(corner(edge.y), 1);
    // Clip to WebGPU's near plane before dividing by w or expanding the stroke.
    // Fully clipped and end-on edges emit a degenerate triangle outside the view.
    let hidden = vec4f(0, 0, -1, 1);
    if (a.z < 0 && b.z < 0) { return hidden; }
    if (a.z < 0) { a = mix(a, b, a.z / (a.z - b.z)); }
    if (b.z < 0) { b = mix(b, a, b.z / (b.z - a.z)); }
    if (a.w <= 0 || b.w <= 0) { return hidden; }
    let delta = (b.xy / b.w - a.xy / a.w) * stroke.xy;
    let edge_length = length(delta);
    if (edge_length < 0.001) { return hidden; }
    let tangent = delta / edge_length;
    let normal = vec2f(-tangent.y, tangent.x);
    let q = quad[index % 6u];
    var p = mix(a, b, q.x);
    // Square caps join corners; expansion in clip space keeps pixel width fixed.
    p = vec4f(p.xy + (normal * q.y + tangent * (2 * q.x - 1)) * stroke.z / stroke.xy * p.w, p.zw);
    return p;
}

@fragment fn fs() -> @location(0) vec4f {
    return vec4f(0, 1, 0, 1);
}
