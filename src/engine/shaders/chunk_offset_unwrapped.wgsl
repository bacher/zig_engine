fn chunkOffset(chunk: vec3i, origin: vec3i) -> vec3f {
    // Unsigned magnitudes preserve full-i32 differences without signed overflow.
    let a = bitcast<vec3u>(chunk) ^ vec3u(0x80000000u);
    let b = bitcast<vec3u>(origin) ^ vec3u(0x80000000u);
    let magnitude = max(a, b) - min(a, b);
    return vec3f(magnitude) * select(vec3f(1.0), vec3f(-1.0), chunk < origin) * CHUNK_SIZE;
}
