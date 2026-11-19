@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4f;
@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(1) @binding(0) var color_texture: texture_2d<f32>;
@group(1) @binding(1) var texture_sampler: sampler;
struct PackedShadowOutput {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) cell_position: vec3f,
    @location(2) @interpolate(flat) material_and_side: vec2u,
    @location(3) @interpolate(flat) kind: u32,
}
fn shadowOutput(input: PackedVertex) -> PackedShadowOutput {
    return PackedShadowOutput(clip_from_chunk * input.vertex.position, input.vertex.uv, input.cell_position, input.vertex.material_and_side, input.kind);
}
@vertex fn faces(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedShadowOutput { return shadowOutput(faceVertex(i, v)); }
@vertex fn models(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedShadowOutput { return shadowOutput(modelVertex(i, v)); }
@vertex fn packaging(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedShadowOutput { return shadowOutput(packagingVertex(i, v)); }
@vertex fn pallets(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedShadowOutput { return shadowOutput(loosePalletVertex(i, v)); }
@vertex fn markers(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedShadowOutput { return shadowOutput(markerVertex(i, v)); }
@fragment fn main(input: PackedShadowOutput) -> @location(0) f32 {
    let sampled = materialColor(input.material_and_side, textureSample(color_texture, texture_sampler, input.uv));
    if input.kind == 2u && !strapCoverage(input.cell_position, input.material_and_side.y) { discard; }
    if input.kind != 0u && input.kind != 2u && sampled.a < 0.25 { discard; }
    return input.position.z;
}
