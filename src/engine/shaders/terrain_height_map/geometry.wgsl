struct TerrainVertex {
    position: vec4f,
    uv: vec2f,
}

fn terrainVertex(vertex_index: u32) -> TerrainVertex {
    let side: u32 = 64;
    let side_inv: f32 = 1.0 / f32(side);
    let count: u32 = (side * 2 + 4) * 2;
    let count_2 = count / 2;

    let a: u32 = vertex_index / count;
    let b: u32 = vertex_index % count;
    let c = b % count_2;
    let d = b / count_2;

    let middle = f32(count_2 - 1) / 2.0;
    let near_end_1 = f32(count_2) - 1.5;
    let near_end_2 = f32(count_2 - 2);

    let x = max(0, min(f32(side), floor(middle - abs((f32(b) - near_end_1) / 2))));

    let y = f32(min(d + 1, (b + d + 1) % 2 + u32(step(near_end_2, f32(c))) + d) + a * 2);

    let uv = vec2f(x * side_inv, 1 - y * side_inv);
    let texture_size = textureDimensions(depth_texture);
    let depth_coord = vec2u(min(vec2f(texture_size - vec2u(1)), uv * vec2f(texture_size)));
    let depth = f32(textureLoad(depth_texture, depth_coord, 0).r) / 65535.0;

    let position4 = vec4(
        x * side_inv * 2 - 1,
        y * side_inv * 2 - 1,
        depth,
        1.0,
    );

    return TerrainVertex(position4, uv);
}
