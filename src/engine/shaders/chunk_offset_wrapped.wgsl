fn chunkOffset(chunk: vec3i, origin: vec3i) -> vec3f {
    // A power-of-two mask normalizes signed chunks without integer division.
    let chunk_x = i32(bitcast<u32>(chunk.x) & WORLD_X_MASK);
    let origin_x = i32(bitcast<u32>(origin.x) & WORLD_X_MASK);
    var dx = chunk_x - origin_x;
    if (dx > WORLD_WIDTH / 2) {
        dx -= WORLD_WIDTH;
    } else if (dx < -WORLD_WIDTH / 2) {
        dx += WORLD_WIDTH;
    }
    let a = bitcast<vec2u>(chunk.yz) ^ vec2u(0x80000000u);
    let b = bitcast<vec2u>(origin.yz) ^ vec2u(0x80000000u);
    let magnitude = max(a, b) - min(a, b);
    let dyz = vec2f(magnitude) * select(vec2f(1.0), vec2f(-1.0), chunk.yz < origin.yz);
    return vec3f(f32(dx), dyz) * CHUNK_SIZE;
}
