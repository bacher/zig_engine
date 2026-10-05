@group(0) @binding(5) var<uniform> origin_chunk: vec3i;
@group(0) @binding(4) var<uniform> clip_from_chunk: mat4x4<f32>;
@group(0) @binding(2) var<storage, read> instances: array<ChunkTransform>;

struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
}

@vertex fn main(
    @builtin(instance_index) instance_index: u32,
    @location(0) position: vec3<f32>,
) -> VertexOut {
    var output: VertexOut;
    output.position_clip = clip_from_chunk * relativePosition(instances[instance_index], origin_chunk, vec4(position, 1.0));
    return output;
}
