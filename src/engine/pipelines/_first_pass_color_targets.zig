const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const COLOR_OUTPUT_FORMAT = wgpu.TextureFormat.rgba8_unorm;
pub const NORMAL_OUTPUT_FORMAT = wgpu.TextureFormat.rgb10_a2_unorm;

// TODO: Why I can't use `wgpu.TextureFormat.rgba8_snorm` for normals?
// error: [zgpu] Validation: The texture usage (TextureUsage::(TextureBinding|RenderAttachment)) includes TextureUsage::RenderAttachment, which is incompatible with the non-renderable format (TextureFormat::RGBA8Snorm).
//  - While validating [TextureDescriptor].
//  - While calling [Device].CreateTexture([TextureDescriptor]).

pub const first_pass_color_targets = [_]wgpu.ColorTargetState{
    // color
    .{
        .format = COLOR_OUTPUT_FORMAT,
    },
    // normal
    .{
        .format = NORMAL_OUTPUT_FORMAT,
        .write_mask = .{}, // .{} = disabled mask (0x00000000)
    },
};

pub const first_pass_color_with_normals_targets = [_]wgpu.ColorTargetState{
    // color
    .{
        .format = COLOR_OUTPUT_FORMAT,
    },
    // normal
    .{
        .format = NORMAL_OUTPUT_FORMAT,
    },
};
