@group(0) @binding(2) var<uniform> solid_color: vec4<f32>;

@fragment fn main() -> @location(0) vec4<f32> {
    return solid_color;
}
