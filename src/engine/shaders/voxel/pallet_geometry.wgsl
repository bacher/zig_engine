// Eight real wooden cuboids. Shared by loose pallets, pallet cargo and packaging.
const PALLET_VERTEX_COUNT = 288u;

fn palletVertex(index: u32) -> VoxelVertex {
    let board = index / 36u;
    let side = (index % 36u) / 6u;
    let corner = index % 6u;
    var origin: vec3f;
    var size: vec3f;
    if board < 5u {
        origin = vec3f(0.0, f32(board) * 0.21, 0.14);
        size = vec3f(1.0, 0.16, 0.06);
    } else {
        origin = vec3f(0.05 + f32(board - 5u) * 0.4, 0.0, 0.0);
        size = vec3f(0.10, 1.0, 0.14);
    }
    return VoxelVertex(vec4f(origin + vec3f(getPosition(side, corner)) * size, 1.0),
        getNormal(side), getUv(side, corner, 10u), vec2u(10u, side));
}
