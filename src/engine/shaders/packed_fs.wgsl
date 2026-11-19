@group(1) @binding(0) var color_texture: texture_2d<f32>;
@group(1) @binding(1) var texture_sampler: sampler;
@group(2) @binding(1) var shadow_map_texture: texture_2d_array<f32>;
@group(2) @binding(2) var shadow_map_texture_sampler: sampler;
struct FragmentOut { @location(0) color: vec4f, @location(1) normal: vec4f, }

@fragment fn main(input: PackedOutput, @builtin(front_facing) front: bool) -> FragmentOut {
    let sampled = materialColor(input.material_and_side, textureSample(color_texture, texture_sampler, input.uv));
    let side = input.material_and_side.y;
    // Derivatives are evaluated uniformly before coverage decisions.
    let wood = textureSample(color_texture, texture_sampler, (vec2f(4.0, 0.0) + input.cell_position.xy) * ATLAS_SLOT);
    let modifier = shadowFactor(shadow_map_texture, shadow_map_texture_sampler, input.light_0, input.light_1, input.light_2);
    var color = packagingColor(input.cell_position, side, input.kind_and_disabled.x, sampled, wood);
    if input.kind_and_disabled.x == 3u && input.kind_and_disabled.y != 0u {
        let p = input.cell_position.xy;
        if abs(p.x - p.y) >= 0.12 && abs(p.x + p.y - 1.0) >= 0.12 { discard; }
        color = vec4f(0.85, 0.035, 0.025, 1.0);
    }
    if color.a < 0.25 { discard; }
    let normal = normalize(select(-input.normal, input.normal, front));
    return FragmentOut(vec4f(color.rgb * modifier, 1.0), vec4f((normal + 1.0) * 0.5, 0.0));
}
