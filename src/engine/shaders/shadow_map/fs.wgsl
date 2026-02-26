@fragment fn main(
    @builtin(position) position_clip: vec4<f32>,
) -> @location(0) f32 {
    // TODO: This is correct?
    // return position_clip.z;
    return position_clip.z / position_clip.w;
}
