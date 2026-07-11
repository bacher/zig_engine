const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const wgsl_vs = @embedFile("../shaders/voxel/vs.wgsl");
const wgsl_fs = @embedFile("../shaders/voxel/fs.wgsl");

const Pipeline = @import("../pipeline.zig").Pipeline;
const BindGroupLayouts = @import("../bind_group_layouts.zig").BindGroupLayouts;
const first_pass_color_with_normals_targets = @import("./_first_pass_color_targets.zig").first_pass_color_with_normals_targets;

pub fn createVoxelPipeline(
    gctx: *zgpu.GraphicsContext,
    bind_group_layouts: *const BindGroupLayouts,
) Pipeline {
    const pipeline_layout_handle = gctx.createPipelineLayout(&.{
        bind_group_layouts.scene.bind_group_layout_handle,
        bind_group_layouts.regular.bind_group_layout_handle,
        bind_group_layouts.shadow_map.bind_group_layout_handle,
        bind_group_layouts.voxel.bind_group_layout_handle,
    });
    defer gctx.releaseResource(pipeline_layout_handle);

    const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
    defer vs_module.release();

    const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
    defer fs_module.release();

    const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
        .label = "basic_pipeline",
        .primitive = wgpu.PrimitiveState{
            .front_face = .ccw,
            .cull_mode = .back,
            // .cull_mode = .none,
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
            .targets = &first_pass_color_with_normals_targets,
            .target_count = first_pass_color_with_normals_targets.len,
        },
    };

    const pipeline_handle = gctx.createRenderPipeline(
        pipeline_layout_handle,
        pipeline_descriptor,
    );

    return Pipeline.init(gctx, pipeline_handle);
}
