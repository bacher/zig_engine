@fragment fn main(
    @builtin(position) position_clip: vec4<f32>,
) -> @location(0) f32 {
    return position_clip.z / position_clip.w;
}
