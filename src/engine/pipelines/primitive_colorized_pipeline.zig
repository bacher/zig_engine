const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const wgsl_vs = @embedFile("../shaders/primitive_colorized/vs.wgsl");
const wgsl_fs = @embedFile("../shaders/primitive_colorized/fs.wgsl");

const Pipeline = @import("../pipeline.zig").Pipeline;
const PrimitiveColorizedBindGroupDefinition = @import("../bind_groups_defs/primitive_bind_group.zig").PrimitiveColorizedBindGroupDefinition;

pub fn createPrimitiveColorizedPipeline(
    gctx: *zgpu.GraphicsContext,
    bind_group_definition: PrimitiveColorizedBindGroupDefinition,
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

    const vertex_buffers = [_]wgpu.VertexBufferLayout{
        // position
        .{
            .array_stride = @sizeOf([3]f32),
            .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 0 }},
            .attribute_count = 1,
        },
    };

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
            .buffers = &vertex_buffers,
            .buffer_count = vertex_buffers.len,
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
