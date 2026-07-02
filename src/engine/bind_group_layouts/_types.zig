pub const PostEffectShaderRuntimeSettings = packed struct {
    ssao_enabled: bool,
    debug_ssao_enabled: bool,
    ssao_blur_enabled: bool,

    _padding: u29 = 0,
};
