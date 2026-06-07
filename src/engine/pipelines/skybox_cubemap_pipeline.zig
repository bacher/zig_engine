const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const wgsl_vs = @embedFile("../shaders/skybox_cubemap/vs.wgsl");
const wgsl_fs = @embedFile("../shaders/skybox_cubemap/fs.wgsl");

const Pipeline = @import("../pipeline.zig").Pipeline;
const BindGroupLayouts = @import("../bind_group_layouts.zig").BindGroupLayouts;
const first_pass_color_targets = @import("./_first_pass_color_targets.zig").first_pass_color_targets;

pub fn createSkyboxCubemapPipeline(
    gctx: *zgpu.GraphicsContext,
    bind_group_layouts: *const BindGroupLayouts,
) Pipeline {
    const pipeline_layout_handle = gctx.createPipelineLayout(&.{
        bind_group_layouts.scene.bind_group_layout_handle,
        bind_group_layouts.cubemap.bind_group_layout_handle,
    });
    defer gctx.releaseResource(pipeline_layout_handle);

    const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
    defer vs_module.release();

    const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
    defer fs_module.release();

    const vertex_buffers = [_]wgpu.VertexBufferLayout{
        // position
        .{
            .array_stride = @sizeOf([3]f32),
            .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 0 }},
            .attribute_count = 1,
        },
        // Skybox doesn't have normal
        // normal
        // .{
        //     .array_stride = @sizeOf([3]f32),
        //     .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 1 }},
        //     .attribute_count = 1,
        // },
        // texcoord
        // .{
        //     .array_stride = @sizeOf([2]f32),
        //     .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 2 }},
        //     .attribute_count = 1,
        // },
    };

    const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
        .label = "skybox_cubemap_pipeline",
        .primitive = wgpu.PrimitiveState{
            .front_face = .ccw,
            .cull_mode = .back,
            .topology = .triangle_list,
        },
        // Even though skybox does not have depth, we need to declare it to avoid
        // incompatibility with [RenderPassEncoder] format.
        .depth_stencil = &wgpu.DepthStencilState{
            .format = .depth32_float,
            .depth_write_enabled = false,
            .depth_compare = .always,
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
            .targets = &first_pass_color_targets,
            .target_count = first_pass_color_targets.len,
        },
    };

    const pipeline_handle = gctx.createRenderPipeline(
        pipeline_layout_handle,
        pipeline_descriptor,
    );

    return Pipeline.init(gctx, pipeline_handle);
}
