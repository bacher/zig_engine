fn strapCoverage(p: vec3f, side: u32) -> bool {
    // Two perpendicular closed bands follow the complete unit-cell boundary.
    if side < 2u { return abs(p.y - 0.5) < 0.035; }
    if side < 4u { return abs(p.x - 0.5) < 0.035; }
    return abs(p.x - 0.5) < 0.035 || abs(p.y - 0.5) < 0.035;
}
fn palletCoverage(p: vec3f, side: u32) -> bool {
    if side == 4u { return true; }
    if side == 5u || p.z > 0.2 { return false; }
    let across = select(p.x, p.y, side < 2u);
    // Opaque cube artwork; gaps reveal the material beneath the packaging.
    return p.z >= 0.14 || (p.z < 0.14 && (abs(across - 0.1) < 0.05 || abs(across - 0.5) < 0.05 || abs(across - 0.9) < 0.05));
}
fn packagingColor(p: vec3f, side: u32, kind: u32, base: vec4f, wood: vec4f) -> vec4f {
    if kind == 2u {
        if !strapCoverage(p, side) { discard; }
        return vec4f(0.11, 0.14, 0.16, 1.0);
    }
    if kind == 0u {
        if strapCoverage(p, side) { return vec4f(0.11, 0.14, 0.16, 1.0); }
        if palletCoverage(p, side) { return vec4f(wood.rgb, 1.0); }
        return vec4f(base.rgb, 1.0);
    }
    return base;
}
