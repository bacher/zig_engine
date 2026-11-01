struct BlueprintInstance { position: vec4f, scale: vec4f, material: vec4u }
@group(0) @binding(0) var<uniform> clip_from_chunk: mat4x4f;
@group(0) @binding(1) var<storage, read> instances: array<BlueprintInstance>;
@group(1) @binding(0) var atlas: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;
struct Vertex {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) normal: vec3f,
    @location(2) @interpolate(flat) material_side: vec2u,
    @location(3) @interpolate(flat) mode: u32,
    @location(4) stripe_position: vec3f,
}
@vertex fn vs(@builtin(vertex_index) index: u32, @builtin(instance_index) instance_index: u32) -> Vertex {
    let instance = instances[instance_index];
    let vertex = blockVertex(index, instance.material.x);
    let position = instance.position.xyz + vertex.position.xyz * instance.scale.xyz;
    return Vertex(clip_from_chunk * vec4f(position, 1), vertex.uv, vertex.normal, vertex.material_and_side, instance.material.y, position);
}
@fragment fn fs(input: Vertex) -> @location(0) vec4f {
    let sampled = textureSample(atlas, atlas_sampler, input.uv);
    let light = 0.6 + 0.4 * max(dot(input.normal, normalize(vec3f(-0.4, -0.3, 0.8))), 0.0);
    if input.mode == 1u {
        let stripe = fract((input.stripe_position.x + input.stripe_position.y + input.stripe_position.z) * 3.0);
        let color = select(vec3f(0.025), vec3f(1, 0.82, 0.02), stripe < 0.5);
        return vec4f(color * light, 1);
    }
    if input.mode == 2u { return vec4f(1, 0.08, 0.06, 1); }
    let color = materialColor(input.material_side, sampled);
    if color.a < 0.25 { discard; }
    return vec4f(color.rgb * light, 1);
}
