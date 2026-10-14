@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4f;
@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(1) @binding(2) var<storage, read> custom_blocks: array<GPU_CustomBlock>;

@vertex fn main(@builtin(instance_index) instance_index: u32, @builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4f {
    return clip_from_chunk * customVertex(instance_index, vertex_index).position;
}
