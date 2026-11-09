struct BlueprintTransform {
    clip_from_chunk: mat4x4f,
    origin_chunk: vec4i,
    camera_chunk: vec4i,
    origin_local_and_width: vec4u,
    size_and_rotation: vec4u,
}
@group(0) @binding(0) var<uniform> transform: BlueprintTransform;
// Dynamic instances occupy three words; cached local cells occupy one.
@group(0) @binding(1) var<storage, read> instances: array<vec4u>;
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
    let base = instance_index * 3u;
    let instance_position = bitcast<vec4f>(instances[base]);
    let instance_scale = bitcast<vec4f>(instances[base + 1u]);
    let instance_material = instances[base + 2u];
    let vertex = blockVertex(index, instance_material.x);
    let position = instance_position.xyz + vertex.position.xyz * instance_scale.xyz;
    return Vertex(transform.clip_from_chunk * vec4f(position, 1), vertex.uv, vertex.normal, vertex.material_and_side, instance_material.y, position);
}
fn previewCell(cell: vec3u) -> vec3u {
    let size = transform.size_and_rotation.xyz;
    switch transform.size_and_rotation.w {
        case 1u: { return vec3u(cell.y, size.x - 1u - cell.x, cell.z); }
        case 2u: { return vec3u(size.x - 1u - cell.x, size.y - 1u - cell.y, cell.z); }
        case 3u: { return vec3u(size.y - 1u - cell.y, cell.x, cell.z); }
        default: { return cell; }
    }
}
fn previewChunkOffset(chunk: vec3i, camera: vec3i) -> vec3f {
    // Signed chunk differences can span the complete u32 range. Convert their
    // unsigned magnitude after reduction, matching the world shader helpers.
    let a = bitcast<vec3u>(chunk) ^ vec3u(0x80000000u);
    let b = bitcast<vec3u>(camera) ^ vec3u(0x80000000u);
    let magnitude = max(a, b) - min(a, b);
    var delta = vec3f(magnitude) * select(vec3f(1.0), vec3f(-1.0), chunk < camera);
    if BLUEPRINT_WRAP_X {
        let width = i32(transform.origin_local_and_width.w);
        let mask = transform.origin_local_and_width.w - 1u;
        let cell_x = i32(bitcast<u32>(chunk.x) & mask);
        let camera_x = i32(bitcast<u32>(camera.x) & mask);
        var dx = cell_x - camera_x;
        // Normalize the final cell chunk BEFORE these strict antipode ties.
        if dx > width / 2 { dx -= width; }
        else if dx < -width / 2 { dx += width; }
        delta.x = f32(dx);
    }
    return delta * 32.0;
}
@vertex fn vs_preview(@builtin(vertex_index) index: u32, @builtin(instance_index) instance_index: u32) -> Vertex {
    let source = instances[instance_index];
    let offset = previewCell(source.xyz);
    // Split first so even full-u32 sparse extents cannot overflow local addition.
    let local_cell = transform.origin_local_and_width.xyz + offset % vec3u(32u);
    let carry = offset / vec3u(32u) + local_cell / vec3u(32u);
    let chunk = transform.origin_chunk.xyz + vec3i(carry);
    let local = local_cell % vec3u(32u);
    let cell_position = previewChunkOffset(chunk, transform.camera_chunk.xyz) + vec3f(local);
    // Rotate cells only: cube geometry, texture orientation and lighting retain
    // the world axes used by the dynamic reference renderer.
    let vertex = blockVertex(index, source.w);
    let position = cell_position + vertex.position.xyz;
    return Vertex(transform.clip_from_chunk * vec4f(position, 1), vertex.uv, vertex.normal, vertex.material_and_side, 0u, position);
}
@vertex fn vs_miniature(@builtin(vertex_index) index: u32, @builtin(instance_index) instance_index: u32) -> Vertex {
    let source = instances[instance_index];
    let cell_position = previewChunkOffset(transform.origin_chunk.xyz, transform.camera_chunk.xyz) + vec3f(source.xyz);
    let instance_position = cell_position + vec3f(0.375);
    let vertex = blockVertex(index, source.w);
    let position = instance_position + vertex.position.xyz * vec3f(0.25);
    return Vertex(transform.clip_from_chunk * vec4f(position, 1), vertex.uv, vertex.normal, vertex.material_and_side, 0u, position);
}
fn surfaceLight(normal: vec3f) -> f32 {
    return 0.6 + 0.4 * max(dot(normal, normalize(vec3f(-0.4, -0.3, 0.8))), 0.0);
}
fn frameColor(input: Vertex) -> vec3f {
    let stripe = fract((input.stripe_position.x + input.stripe_position.y + input.stripe_position.z) * 3.0);
    let color = select(vec3f(0.025), vec3f(1, 0.82, 0.02), stripe < 0.5);
    return color * surfaceLight(input.normal);
}
@fragment fn fs_occluded(input: Vertex) -> @location(0) vec4f {
    return vec4f(frameColor(input), 0.25);
}
@fragment fn fs(input: Vertex) -> @location(0) vec4f {
    let sampled = textureSample(atlas, atlas_sampler, input.uv);
    let light = surfaceLight(input.normal);
    if input.mode == 1u { return vec4f(frameColor(input), 1); }
    if input.mode == 2u { return vec4f(1, 0.08, 0.06, 1); }
    let color = materialColor(input.material_side, sampled);
    if color.a < 0.25 { discard; }
    return vec4f(color.rgb * light, 1);
}
