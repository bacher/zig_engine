// TODO: Should be texture f32 or u8 is also okay?
@group(0) @binding(2) var color_texture: texture_cube<f32>;
@group(0) @binding(3) var texture_sampler: sampler;

fn if_nan(x: f32) -> bool {
  let highVal = 1000000.0;
  return min(x, highVal) == highVal;
}

@fragment fn main(
  @location(0) frag_position: vec3f,
) -> @location(0) vec4<f32> {
    return textureSample(color_texture, texture_sampler, frag_position);
}
