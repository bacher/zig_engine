struct VoxelVertex {
    position: vec4f,
    normal: vec3f,
    uv: vec2f,
    material_and_side: vec2u,
}

// Four patches along each edge; opposite profiles match for rows in either axis.
// Heights are visual only: the adaptive collision surface remains z = 1.
const ADAPTIVE_VERTEX_COUNT = 198u; // 16 top + 16 side + 1 bottom quads.
const ADAPTIVE_TOP_HEIGHT = 0.75;
const ADAPTIVE_RELIEF = 0.0625;
const ADAPTIVE_HEIGHTS = array<u32, 16>(
    0u, 2u, 2u, 0u,
    0u, 2u, 2u, 0u,
    0u, 0u, 0u, 0u,
    2u, 0u, 1u, 2u,
);

fn adaptiveHeight(point: vec2u) -> f32 {
    return ADAPTIVE_TOP_HEIGHT + (f32(ADAPTIVE_HEIGHTS[(point.y % 4u) * 4u + point.x % 4u]) - 1.0) * ADAPTIVE_RELIEF;
}

fn adaptiveTop(point: vec2u) -> vec3f {
    return vec3f(vec2f(point) / 4.0, adaptiveHeight(point));
}

fn adaptiveVertex(vertex_index: u32) -> VoxelVertex {
    let quad = vertex_index / 6u;
    let corner = vertex_index % 6u;
    var local: vec3f;
    var normal: vec3f;
    var uv: vec2f;
    var material_side = 5u;
    if (quad < 16u) {
        let cell = vec2u(quad % 4u, quad / 4u);
        let offset = getPosition(5u, corner).xy;
        local = adaptiveTop(cell + offset);
        // Flat normals for each actual triangle keep the raised edges faceted.
        let a = adaptiveTop(cell);
        let b = adaptiveTop(cell + vec2u(1u, 1u));
        if (corner < 3u) {
            normal = normalize(cross(b - a, adaptiveTop(cell + vec2u(0u, 1u)) - a));
        } else {
            normal = normalize(cross(adaptiveTop(cell + vec2u(1u, 0u)) - a, b - a));
        }
        uv = vec2f(local.x, 1.0 - local.y);
    } else if (quad < 32u) {
        let side = (quad - 16u) / 4u;
        material_side = side;
        let segment = (quad - 16u) % 4u;
        let cube = getPosition(side, corner);
        var point = cube.xy * 4u;
        if (side < 2u) {
            point.y = segment + cube.y;
        } else {
            point.x = segment + cube.x;
        }
        local = vec3f(vec2f(point) / 4.0, f32(cube.z) * adaptiveHeight(point));
        normal = getNormal(side);
        // Use one atlas tile across the whole face, including the raised rim.
        let along = select(local.x, local.y, side < 2u);
        uv = vec2f(select(1.0 - along, along, side == 0u || side == 3u),
                   1.0 - local.z / (ADAPTIVE_TOP_HEIGHT + ADAPTIVE_RELIEF));
    } else {
        local = vec3f(getPosition(4u, corner));
        normal = getNormal(4u);
        return VoxelVertex(vec4f(local, 1.0), normal, getUv(4u, corner, 14u), vec2u(14u, 4u));
    }
    return VoxelVertex(vec4f(local, 1.0), normal, (vec2f(4.0, 0.0) + uv) * ATLAS_SLOT, vec2u(14u, material_side));
}

// Local material geometry shared by world blocks and camera-held previews.
fn blockVertex(vertex_index: u32, material: u32) -> VoxelVertex {
    if (material == 14u || material == 255u) {
        return adaptiveVertex(vertex_index);
    }
    let side = vertex_index / 6u;
    let corner = vertex_index % 6u;
    return VoxelVertex(vec4f(vec3f(getPosition(side, corner)), 1.0),
                       getNormal(side), getUv(side, corner, material), vec2u(material, side));
}
