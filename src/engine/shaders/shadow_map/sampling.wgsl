// Shared by the mesh, skinned mesh, voxel, and height-map fragment shaders.
// Texture parameters keep this independent of each pipeline's bind group index.
fn shadowFactor(
    shadow_texture: texture_2d_array<f32>,
    shadow_sampler: sampler,
    position_light_clip_0: vec4<f32>,
    position_light_clip_1: vec4<f32>,
    position_light_clip_2: vec4<f32>,
) -> f32 {
    // Sample before any cascade-dependent branches so implicit derivatives are
    // evaluated in uniform control flow. Call this before alpha discard as well.
    let shadow_map_layer_0_depth = textureSample(
        shadow_texture,
        shadow_sampler,
        shadowClipToUv(position_light_clip_0),
        0,
    ).r;
    let shadow_map_layer_1_depth = textureSample(
        shadow_texture,
        shadow_sampler,
        shadowClipToUv(position_light_clip_1),
        1,
    ).r;
    let shadow_map_layer_2_depth = textureSample(
        shadow_texture,
        shadow_sampler,
        shadowClipToUv(position_light_clip_2),
        2,
    ).r;

    // if (shadow_map_depth + 0.002 < position_light_clip.z / position_light_clip.w) {
    // vs
    // if (shadow_map_depth - 0.002 < position_light_clip.z) {

    if (
        position_light_clip_2.x >= -1 && position_light_clip_2.x <= 1 &&
        position_light_clip_2.y >= -1 && position_light_clip_2.y <= 1 &&
        position_light_clip_2.z >= 0 && position_light_clip_2.z <= 1
    ) {
        return select(1.0, 0.5, shadow_map_layer_2_depth + 0.002 < position_light_clip_2.z / position_light_clip_2.w);
    }

    if (
        position_light_clip_1.x >= -1 && position_light_clip_1.x <= 1 &&
        position_light_clip_1.y >= -1 && position_light_clip_1.y <= 1 &&
        position_light_clip_1.z >= 0 && position_light_clip_1.z <= 1
    ) {
        return select(1.0, 0.5, shadow_map_layer_1_depth + 0.008 < position_light_clip_1.z / position_light_clip_1.w);
    }

    // The widest cascade covers the camera frustum and is the fallback.
    // but maybe it still makes sense to check the position_light_clip_0.z to be in (0,1) interval.
    return select(1.0, 0.5, shadow_map_layer_0_depth + 0.02 < position_light_clip_0.z / position_light_clip_0.w);
}

// Light projections are orthographic, so x/y are already in clip-space bounds.
fn shadowClipToUv(light_clip_pos: vec4<f32>) -> vec2<f32> {
    return vec2f(
        (light_clip_pos.x + 1.0) * 0.5,
        1.0 - (light_clip_pos.y + 1.0) * 0.5,
    );
}
