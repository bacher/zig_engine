// Shared by world faces and held previews. Water and leaves ignore atlas alpha.
fn materialColor(material_and_side: vec2u, sampled: vec4f) -> vec4f {
    let material = material_and_side.x;
    switch material {
        case 4u: { return vec4f(0.075, 0.30, 0.73, 1.0); }
        case 15u: { return vec4f(0.16, 0.42, 0.10, 1.0); }
        case 16u: { return vec4f(sampled.rgb * vec3f(0.72, 0.48, 0.31), 1.0); }
        case 17u: { return vec4f(sampled.rgb * vec3f(1.12, 1.08, 0.91), 1.0); }
        case 18u: { return vec4f(sampled.rgb * vec3f(0.90, 0.55, 0.39), 1.0); }
        case 19u: { return vec4f(sampled.rgb * 0.25, 1.0); }
        case 20u: { return vec4f(sampled.rgb * vec3f(0.28, 0.30, 0.34), 1.0); }
        case 21u: {
            if (material_and_side.y == 5u) {
                let brightness = dot(sampled.rgb, vec3f(0.299, 0.587, 0.114));
                return vec4f(brightness * vec3f(1.22, 1.04, 0.38), sampled.a);
            }
        }
        default: {}
    }
    return sampled;
}
