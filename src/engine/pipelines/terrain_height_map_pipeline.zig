const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const wgsl_vs = @embedFile("../shaders/terrain_height_map/vs.wgsl");
const wgsl_fs = @embedFile("../shaders/terrain_height_map/fs.wgsl");

const Pipeline = @import("../pipeline.zig").Pipeline;
const BindGroupLayouts = @import("../bind_group_layouts.zig").BindGroupLayouts;

pub fn createTerrainHeightMapPipeline(
    gctx: *zgpu.GraphicsContext,
    bind_group_layouts: *const BindGroupLayouts,
) !Pipeline {
    const pipeline_layout_handle = gctx.createPipelineLayout(&.{
        bind_group_layouts.terrain_height_map.bind_group_layout_handle,
        bind_group_layouts.shadow_map.bind_group_layout_handle,
    });
    defer gctx.releaseResource(pipeline_layout_handle);

    const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
    defer vs_module.release();

    const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
    defer fs_module.release();

    const color_targets = [_]wgpu.ColorTargetState{.{
        .format = zgpu.GraphicsContext.swapchain_format,
    }};

    const vertex_buffers = [_]wgpu.VertexBufferLayout{};

    const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
        .label = "terrain_height_map_pipeline",
        .primitive = wgpu.PrimitiveState{
            .front_face = .ccw,
            .cull_mode = .back,
            // .cull_mode = .none,
            .topology = .triangle_strip,
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
