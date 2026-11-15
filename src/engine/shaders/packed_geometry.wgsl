struct PackedFace { x: u32, y: u32, z: u32, material: u32, direction: u32, owner: u32, }
struct PackedInstance { x: u32, y: u32, z: u32, material: u32, owner: u32, }
struct PackedMarker { x: u32, y: u32, z: u32, material: u32, disabled: u32, owner: u32, }
@group(3) @binding(0) var<storage, read> packed_chunks: array<vec4i>;
@group(3) @binding(1) var<storage, read> packed_faces: array<PackedFace>;
@group(3) @binding(2) var<storage, read> packed_models: array<PackedInstance>;
@group(3) @binding(3) var<storage, read> packed_packaging: array<PackedInstance>;
@group(3) @binding(4) var<storage, read> packed_pallets: array<PackedInstance>;
@group(3) @binding(5) var<storage, read> packed_markers: array<PackedMarker>;

struct PackedVertex {
    vertex: VoxelVertex,
    cell_position: vec3f,
    // 0 cube coverage, 1 ordinary model/wood, 2 strap cutout, 3 marker.
    kind: u32,
    disabled: u32,
}

fn packedPosition(owner: u32, local: vec3u, vertex: vec3f) -> vec4f {
    return vec4f(chunkOffset(packed_chunks[owner].xyz, origin_chunk) + vec3f(local) + vertex, 1.0);
}

fn faceVertex(instance: u32, index: u32) -> PackedVertex {
    let face = packed_faces[instance];
    let p = vec3f(getPosition(face.direction, index));
    return PackedVertex(VoxelVertex(packedPosition(face.owner, vec3u(face.x, face.y, face.z), p),
        getNormal(face.direction), getUv(face.direction, index, face.material), vec2u(face.material, face.direction)), p, 0u, 0u);
}

fn modelVertex(instance: u32, index: u32) -> PackedVertex {
    let item = packed_models[instance];
    var vertex: VoxelVertex;
    if item.material == 23u {
        vertex = palletVertex(index);
        // Center the actual 1x1x0.2 model bounds in the cargo cell.
        vertex.position = vec4f(vec3f(0.5) + (vertex.position.xyz - vec3f(0.5, 0.5, 0.1)) * 0.9, 1.0);
    } else {
        vertex = blockVertex(min(index, ADAPTIVE_VERTEX_COUNT - 1u), 14u);
        // Shared max-vertex template: unused adaptive triangles are degenerate.
        if index >= ADAPTIVE_VERTEX_COUNT { vertex.position = vec4f(0.0, 0.0, 0.0, 1.0); }
    }
    let p = vertex.position.xyz;
    vertex.position = packedPosition(item.owner, vec3u(item.x, item.y, item.z), p);
    return PackedVertex(vertex, p, 1u, 0u);
}

fn packagingVertex(instance: u32, index: u32) -> PackedVertex {
    let item = packed_packaging[instance];
    var vertex: VoxelVertex;
    var kind = 1u;
    if index < PALLET_VERTEX_COUNT {
        vertex = palletVertex(index);
    } else {
        let side = (index - PALLET_VERTEX_COUNT) / 6u;
        let corner = index % 6u;
        vertex = VoxelVertex(vec4f(vec3f(getPosition(side, corner)), 1.0), getNormal(side),
            getUv(side, corner, 10u), vec2u(10u, side));
        kind = 2u;
    }
    let p = vertex.position.xyz;
    vertex.position = packedPosition(item.owner, vec3u(item.x, item.y, item.z), p);
    return PackedVertex(vertex, p, kind, 0u);
}

fn loosePalletVertex(instance: u32, index: u32) -> PackedVertex {
    let item = packed_pallets[instance];
    var vertex = palletVertex(index);
    let p = vertex.position.xyz;
    vertex.position = packedPosition(item.owner, vec3u(item.x, item.y, item.z), p);
    return PackedVertex(vertex, p, 1u, 0u);
}

fn markerVertex(instance: u32, index: u32) -> PackedVertex {
    let item = packed_markers[instance];
    let uv = vec3f(getPosition(5u, index));
    let p = vec3f(vec2f(1.0 / 3.0) + uv.xy / 3.0, 0.201);
    return PackedVertex(VoxelVertex(packedPosition(item.owner, vec3u(item.x, item.y, item.z), p),
        vec3f(0.0, 0.0, 1.0), getUv(5u, index, select(item.material, 10u, item.material == 23u)), vec2u(item.material, 5u)), uv, 3u, item.disabled);
}
