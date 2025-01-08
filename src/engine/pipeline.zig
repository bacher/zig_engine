const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const BindGroupDefinition = @import("./bind_group.zig").BindGroupDefinition;

pub const Pipeline = struct {
    pipeline_handle: zgpu.RenderPipelineHandle,
    pipeline_gpu: wgpu.RenderPipeline,

    pub fn init(gctx: *zgpu.GraphicsContext, pipeline_handle: zgpu.RenderPipelineHandle) !Pipeline {
        if (gctx.lookupResource(pipeline_handle)) |pipeline_gpu| {
            return .{
                .pipeline_handle = pipeline_handle,
                .pipeline_gpu = pipeline_gpu,
            };
        } else {
            return error.PipelineNotReady;
        }
    }

    pub fn deinit(pipeline: Pipeline, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(pipeline.pipeline_handle);
    }
};

pub fn createBasicPipeline(
    gctx: *zgpu.GraphicsContext,
    bind_group_definition: BindGroupDefinition,
    wgsl_vs: [*:0]const u8,
    wgsl_fs: [*:0]const u8,
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
        // normal
        .{
            .array_stride = @sizeOf([3]f32),
            .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 1 }},
            .attribute_count = 1,
        },
        // texcoord
        .{
            .array_stride = @sizeOf([2]f32),
            .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 2 }},
            .attribute_count = 1,
        },
    };

    const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
        .primitive = wgpu.PrimitiveState{
            .front_face = .cw,
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
