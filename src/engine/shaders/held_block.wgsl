struct HeldBlock {
    clip_from_block: mat4x4f,
    view_from_block: mat4x4f,
    material: vec4u,
}
@group(0) @binding(0) var<uniform> held: HeldBlock;
@group(1) @binding(0) var atlas: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

struct HeldVertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) normal: vec3f,
}

@vertex fn vs(@builtin(vertex_index) index: u32) -> HeldVertex {
    let vertex = blockVertex(index, held.material.x);
    return HeldVertex(
        held.clip_from_block * vertex.position,
        vertex.uv,
        (held.view_from_block * vec4f(vertex.normal, 0.0)).xyz,
    );
}

@fragment fn fs(input: HeldVertex) -> @location(0) vec4f {
    let color = textureSample(atlas, atlas_sampler, input.uv);
    if color.a < 0.25 { discard; }
    // A steady light above and to the left keeps the held material readable.
    let diffuse = max(dot(normalize(input.normal), normalize(vec3f(-0.4, 0.7, 0.6))), 0.0);
    return vec4f(color.rgb * (0.65 + 0.35 * diffuse), 1.0);
}
