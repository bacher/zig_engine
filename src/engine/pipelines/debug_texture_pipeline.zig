const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const wgsl_vs = @embedFile("../shaders/debug_texture/vs.wgsl");
const wgsl_fs = @embedFile("../shaders/debug_texture/fs.wgsl");

const Pipeline = @import("../pipeline.zig").Pipeline;
const DebugTextureBindGroupDefinition = @import("../bind_groups_defs/debug_texture_bind_group.zig").DebugTextureBindGroupDefinition;

pub fn createDebugTexturePipeline(
    gctx: *zgpu.GraphicsContext,
    bind_group_definition: DebugTextureBindGroupDefinition,
) !Pipeline {
    const pipeline_layout_handle = gctx.createPipelineLayout(&.{
        bind_group_definition.bind_group_layout_handle,
    });
    defer gctx.releaseResource(pipeline_layout_handle);

    const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
    defer vs_module.release();

    const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
    defer fs_module.release();

    const color_targets = [_]wgpu.ColorTargetState{.{
        .format = zgpu.GraphicsContext.swapchain_format,
    }};

    const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
        .primitive = wgpu.PrimitiveState{
            .front_face = .ccw,
            .cull_mode = .back,
            .topology = .triangle_list,
        },
        .depth_stencil = &wgpu.DepthStencilState{
            .format = .depth32_float,
            .depth_write_enabled = true,
            .depth_compare = .less,
        },
        .vertex = wgpu.VertexState{
            .module = vs_module,
            .entry_point = "main",
            .buffers = &.{},
            .buffer_count = 0,
        },
        .fragment = &wgpu.FragmentState{
            .module = fs_module,
            .entry_point = "main",
            .targets = &color_targets,
            .target_count = color_targets.len,
        },
    };

    const pipeline_handle = gctx.createRenderPipeline(
        pipeline_layout_handle,
        pipeline_descriptor,
    );

    return try Pipeline.init(gctx, pipeline_handle);
}
