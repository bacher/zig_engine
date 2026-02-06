struct VertexOut {
    @builtin(position) position_clip: vec4<f32>,
    @location(0) texcoord: vec2<f32>,
}

const positions = array(
    vec2f(0, 0),
    vec2f(1, 0),
    vec2f(1, 1),
    vec2f(0, 0),
    vec2f(1, 1),
    vec2f(0, 1),
);

@vertex fn main(
    @builtin(vertex_index) vertex_index: u32,
) -> VertexOut {
    var output: VertexOut;

    let position = positions[vertex_index];

    output.position_clip = vec4f(position + vec2f(0, -1), 0.0, 1.0);
    output.texcoord = vec2f(position.x, 1.0 - position.y);
    return output;
}
