@group(0) @binding(1) var<uniform> view_from_world: mat4x4f;
@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4f;
@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(2) @binding(0) var<uniform> light_clip_from_chunk_array: array<mat4x4f, 3>;

struct PackedOutput {
    @builtin(position) position: vec4f,
    @location(0) normal: vec3f,
    @location(1) uv: vec2f,
    @location(2) light_0: vec4f,
    @location(3) light_1: vec4f,
    @location(4) light_2: vec4f,
    @location(5) @interpolate(flat) material_and_side: vec2u,
    @location(6) cell_position: vec3f,
    @location(7) @interpolate(flat) kind_and_disabled: vec2u,
}
fn packedOutput(input: PackedVertex) -> PackedOutput {
    return PackedOutput(clip_from_chunk * input.vertex.position,
        (view_from_world * vec4f(input.vertex.normal, 0.0)).xyz, input.vertex.uv,
        light_clip_from_chunk_array[0] * input.vertex.position,
        light_clip_from_chunk_array[1] * input.vertex.position,
        light_clip_from_chunk_array[2] * input.vertex.position,
        input.vertex.material_and_side, input.cell_position, vec2u(input.kind, input.disabled));
}
@vertex fn faces(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedOutput { return packedOutput(faceVertex(i, v)); }
@vertex fn models(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedOutput { return packedOutput(modelVertex(i, v)); }
@vertex fn packaging(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedOutput { return packedOutput(packagingVertex(i, v)); }
@vertex fn pallets(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedOutput { return packedOutput(loosePalletVertex(i, v)); }
@vertex fn markers(@builtin(instance_index) i: u32, @builtin(vertex_index) v: u32) -> PackedOutput { return packedOutput(markerVertex(i, v)); }
