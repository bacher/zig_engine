const zgpu = @import("zgpu");

const Pipeline = @import("./pipeline.zig").Pipeline;
const BindGroupLayouts = @import("./bind_group_layouts.zig").BindGroupLayouts;

const basic_pipeline_module = @import("./pipelines/basic_pipeline.zig");
const basic_skinned_pipeline_module = @import("./pipelines/basic_skinned_pipeline.zig");
const skybox_pipeline_module = @import("./pipelines/skybox_pipeline.zig");
const skybox_cubemap_pipeline_module = @import("./pipelines/skybox_cubemap_pipeline.zig");
const window_box_pipeline_module = @import("./pipelines/window_box_pipeline.zig");
const primitive_colorized_pipeline_module = @import("./pipelines/primitive_colorized_pipeline.zig");
const terrain_height_map_pipeline_module = @import("./pipelines/terrain_height_map_pipeline.zig");
const shadow_map_pipeline_module = @import("./pipelines/shadow_map_pipeline.zig");
const shadow_map_skinned_pipeline_module = @import("./pipelines/shadow_map_skinned_pipeline.zig");
const lines_pipeline_module = @import("./pipelines/lines_pipeline.zig");
const debug_texture_pipeline_module = @import("./pipelines/debug_texture_pipeline.zig");

pub const Pipelines = struct {
    // -- basic pipelines --
    basic: Pipeline,
    basic_skinned: Pipeline,
    skybox: Pipeline,
    skybox_cubemap: Pipeline,
    window_box: Pipeline,
    primitive_colorized: Pipeline,
    terrain_height_map: Pipeline,
    // -- shadow pipelines --
    shadow_map: Pipeline,
    shadow_map_skinned: Pipeline,
    // -- debug pipelines --
    lines: Pipeline,
    debug_texture: Pipeline,

    pub fn init(gctx: *zgpu.GraphicsContext, bind_group_layouts: *const BindGroupLayouts) Pipelines {
        const basic_pipeline = basic_pipeline_module.createBasicPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const basic_skinned_pipeline = basic_skinned_pipeline_module.createBasicSkinnedPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const skybox_pipeline = skybox_pipeline_module.createSkyboxPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const skybox_cubemap_pipeline = skybox_cubemap_pipeline_module.createSkyboxCubemapPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const window_box_pipeline = window_box_pipeline_module.createWindowBoxPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const primitive_colorized_pipeline = primitive_colorized_pipeline_module.createPrimitiveColorizedPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const terrain_height_map_pipeline = terrain_height_map_pipeline_module.createTerrainHeightMapPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const shadow_map_pipeline = shadow_map_pipeline_module.createShadowMapPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const shadow_map_skinned_pipeline = shadow_map_skinned_pipeline_module.createShadowMapSkinnedPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const lines_pipeline = lines_pipeline_module.createLinesPipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        const debug_texture_pipeline = debug_texture_pipeline_module.createDebugTexturePipeline(
            gctx,
            bind_group_layouts,
        ) catch @panic("Pipeline initialization failure");

        return .{
            .basic = basic_pipeline,
            .basic_skinned = basic_skinned_pipeline,
            .skybox = skybox_pipeline,
            .skybox_cubemap = skybox_cubemap_pipeline,
            .window_box = window_box_pipeline,
            .primitive_colorized = primitive_colorized_pipeline,
            .terrain_height_map = terrain_height_map_pipeline,
            .shadow_map = shadow_map_pipeline,
            .shadow_map_skinned = shadow_map_skinned_pipeline,
            .lines = lines_pipeline,
            .debug_texture = debug_texture_pipeline,
        };
    }

    pub fn deinit(pipelines: *Pipelines, gctx: *zgpu.GraphicsContext) void {
        pipelines.basic.deinit(gctx);
        pipelines.basic_skinned.deinit(gctx);
        pipelines.skybox.deinit(gctx);
        pipelines.skybox_cubemap.deinit(gctx);
        pipelines.window_box.deinit(gctx);
        pipelines.primitive_colorized.deinit(gctx);
        pipelines.terrain_height_map.deinit(gctx);
        pipelines.shadow_map.deinit(gctx);
        pipelines.shadow_map_skinned.deinit(gctx);
        pipelines.lines.deinit(gctx);
        pipelines.debug_texture.deinit(gctx);
    }
};
