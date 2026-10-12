struct Outline {
    clip_from_block: mat4x4f,
    block_from_clip: mat4x4f,
    // xy: viewport, z: stroke width, w: camera-facing face bit mask.
    stroke: vec4f,
    color: vec4f,
    parameters: vec4f,
}
@group(0) @binding(0) var<uniform> outline: Outline;

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

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) @interpolate(flat) faces: u32,
}

@vertex fn vs(@builtin(vertex_index) index: u32) -> VertexOut {
    let edge = edges[index / 6u];
    let hidden = VertexOut(vec4f(0, 0, -1, 1), 0u);
    var faces = 0u;
    for (var axis = 0u; axis < 3u; axis++) {
        if (((edge.x ^ edge.y) & (1u << axis)) == 0u) {
            let face = 2u * axis + ((edge.x >> axis) & 1u);
            faces |= (u32(outline.stroke.w) & (1u << face));
        }
    }
    // Depth correction must never bring a hidden back edge onto the front face.
    if (faces == 0u) { return hidden; }
    var a = outline.clip_from_block * vec4f(corner(edge.x), 1);
    var b = outline.clip_from_block * vec4f(corner(edge.y), 1);
    // Clip to WebGPU's near plane before dividing by w or expanding the stroke.
    // Fully clipped and end-on edges emit a degenerate triangle outside the view.
    if (a.z < 0 && b.z < 0) { return hidden; }
    if (a.z < 0) { a = mix(a, b, a.z / (a.z - b.z)); }
    if (b.z < 0) { b = mix(b, a, b.z / (b.z - a.z)); }
    if (a.w <= 0 || b.w <= 0) { return hidden; }
    let delta = (b.xy / b.w - a.xy / a.w) * outline.stroke.xy;
    let edge_length = length(delta);
    if (edge_length < 0.001) { return hidden; }
    let tangent = delta / edge_length;
    let normal = vec2f(-tangent.y, tangent.x);
    let q = quad[index % 6u];
    var p = mix(a, b, q.x);
    // Square caps join corners; expansion in clip space keeps pixel width fixed.
    p = vec4f(p.xy + (normal * q.y + tangent * (2 * q.x - 1)) * outline.stroke.z / outline.stroke.xy * p.w, p.zw);
    return VertexOut(p, faces);
}

// The expanded stroke can cover a target face closer than the thin edge itself.
// Follow that surface's depth at each covered pixel, so the block cannot eat its
// own outline. Other geometry still participates in the ordinary depth test.
fn strokeDepth(pixel: vec2f, edge_depth: f32, faces: u32) -> f32 {
    let xy = vec2f(2 * pixel.x / outline.stroke.x - 1, 1 - 2 * pixel.y / outline.stroke.y);
    let near_h = outline.block_from_clip * vec4f(xy, 0, 1);
    let far_h = outline.block_from_clip * vec4f(xy, 1, 1);
    let origin = near_h.xyz / near_h.w;
    let direction = far_h.xyz / far_h.w - origin;
    var enter = 0.0;
    var exit = 1.0;
    var intersects = true;
    for (var axis = 0u; axis < 3u; axis++) {
        if (abs(direction[axis]) < 0.00000001) {
            if (origin[axis] < 0 || origin[axis] > 1) { intersects = false; }
        } else {
            let a = -origin[axis] / direction[axis];
            let b = (1 - origin[axis]) / direction[axis];
            enter = max(enter, min(a, b));
            exit = min(exit, max(a, b));
        }
    }
    var depth = edge_depth;
    if (intersects && enter <= exit) {
        let surface = outline.clip_from_block * vec4f(origin + direction * enter, 1);
        depth = min(depth, surface.z / surface.w);
    }
    // The outer half of the stroke can lie just beyond the target cell, on a
    // coplanar neighbor. Continue only this edge's visible adjacent face planes
    // into that narrow rasterized margin so flat walls/floors cannot trim it.
    for (var axis = 0u; axis < 3u; axis++) {
        if (abs(direction[axis]) < 0.00000001) { continue; }
        for (var side = 0u; side < 2u; side++) {
            if ((faces & (1u << (2u * axis + side))) == 0u) { continue; }
            let t = (f32(side) - origin[axis]) / direction[axis];
            if (t < 0 || t > 1) { continue; }
            let point = origin + direction * t;
            // A pixel-wide margin can reach metres away at grazing angles.
            // Limit extension to a quarter voxel around the face; otherwise
            // retain the target/edge depth so foreground blocks still hide it.
            const margin = 0.25;
            if (any(point < vec3f(-margin)) || any(point > vec3f(1 + margin))) { continue; }
            let plane = outline.clip_from_block * vec4f(point, 1);
            depth = min(depth, plane.z / plane.w);
        }
    }
    return depth;
}

struct FragmentOut {
    @location(0) color: vec4f,
    @builtin(frag_depth) depth: f32,
}

@fragment fn fs(input: VertexOut) -> FragmentOut {
    var output: FragmentOut;
    output.color = outline.color;
    var depth = input.position.z;
    if (outline.parameters.x != 0) {
        depth = strokeDepth(input.position.xy, depth, input.faces);
    }
    // Eight f32 epsilon units cover reconstruction/rasterization rounding only.
    output.depth = clamp(depth - 0.0000009536743164, 0, 1);
    return output;
}
