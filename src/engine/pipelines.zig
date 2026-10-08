const std = @import("std");
const WorldLayout = @import("world_layout.zig").WorldLayout;
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
const voxel_pipeline_module = @import("./pipelines/voxel_pipeline.zig");
const shadow_map_pipeline_module = @import("./pipelines/shadow_map_pipeline.zig");
const shadow_map_skinned_pipeline_module = @import("./pipelines/shadow_map_skinned_pipeline.zig");
const lines_pipeline_module = @import("./pipelines/lines_pipeline.zig");
const debug_texture_pipeline_module = @import("./pipelines/debug_texture_pipeline.zig");
const screen_quad_pipeline_module = @import("./pipelines/screen_quad_pipeline.zig");
const ssao_pipeline_module = @import("./pipelines/ssao_pipeline.zig");

const shadow_map_voxel_pipeline_module = @import("./pipelines/shadow_map_voxel_pipeline.zig");

const shadow_map_terrain_pipeline_module = @import("./pipelines/shadow_map_terrain_pipeline.zig");

pub const Pipelines = struct {
    // -- basic pipelines --
    skybox: Pipeline,
    skybox_cubemap: Pipeline,
    window_box: Pipeline,
    primitive_colorized: Pipeline,
    terrain_height_map: Pipeline,
    // -- shadow pipelines --
    shadow_map_terrain: Pipeline,
    // -- debug pipelines --
    lines: Pipeline,
    debug_texture: Pipeline,
    // -- rest --
    ssao_pipeline: Pipeline,
    screen_quad_pipeline: Pipeline,

    pub fn init(gctx: *zgpu.GraphicsContext, bind_group_layouts: *const BindGroupLayouts) Pipelines {
        const skybox_pipeline = skybox_pipeline_module.createSkyboxPipeline(
            gctx,
            bind_group_layouts,
        );

        const skybox_cubemap_pipeline = skybox_cubemap_pipeline_module.createSkyboxCubemapPipeline(
            gctx,
            bind_group_layouts,
        );

        const window_box_pipeline = window_box_pipeline_module.createWindowBoxPipeline(
            gctx,
            bind_group_layouts,
        );

        const primitive_colorized_pipeline = primitive_colorized_pipeline_module.createPrimitiveColorizedPipeline(
            gctx,
            bind_group_layouts,
        );

        const terrain_height_map_pipeline = terrain_height_map_pipeline_module.createTerrainHeightMapPipeline(
            gctx,
            bind_group_layouts,
        );

        const lines_pipeline = lines_pipeline_module.createLinesPipeline(
            gctx,
            bind_group_layouts,
        );

        const debug_texture_pipeline = debug_texture_pipeline_module.createDebugTexturePipeline(
            gctx,
            bind_group_layouts,
        );

        const ssao_pipeline = ssao_pipeline_module.createSsaoPipeline(
            gctx,
            bind_group_layouts,
        );

        const screen_quad_pipeline = screen_quad_pipeline_module.createScreenQuadPipeline(
            gctx,
            bind_group_layouts,
            zgpu.GraphicsContext.swapchain_format,
        );

        return .{
            .skybox = skybox_pipeline,
            .skybox_cubemap = skybox_cubemap_pipeline,
            .window_box = window_box_pipeline,
            .primitive_colorized = primitive_colorized_pipeline,
            .terrain_height_map = terrain_height_map_pipeline,
            .shadow_map_terrain = shadow_map_terrain_pipeline_module.createShadowMapTerrainPipeline(gctx, bind_group_layouts),
            .lines = lines_pipeline,
            .debug_texture = debug_texture_pipeline,
            .ssao_pipeline = ssao_pipeline,
            .screen_quad_pipeline = screen_quad_pipeline,
        };
    }

    pub fn deinit(pipelines: *Pipelines, gctx: *zgpu.GraphicsContext) void {
        pipelines.skybox.deinit(gctx);
        pipelines.skybox_cubemap.deinit(gctx);
        pipelines.window_box.deinit(gctx);
        pipelines.primitive_colorized.deinit(gctx);
        pipelines.terrain_height_map.deinit(gctx);
        pipelines.shadow_map_terrain.deinit(gctx);
        pipelines.lines.deinit(gctx);
        pipelines.debug_texture.deinit(gctx);
        pipelines.ssao_pipeline.deinit(gctx);
        pipelines.screen_quad_pipeline.deinit(gctx);
    }
};

/// Six specialized pipelines shared through the engine's WorldPipelineCache.
pub const WorldPipelines = struct {
    basic: Pipeline,
    basic_skinned: Pipeline,
    voxel_pipeline: Pipeline,
    shadow_map: Pipeline,
    shadow_map_skinned: Pipeline,
    shadow_map_voxel: Pipeline,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, bind_group_layouts: *const BindGroupLayouts, layout: *const WorldLayout) !WorldPipelines {
        const basic_source = try layout.shaderSource(allocator, basic_pipeline_module.shader_body);
        defer allocator.free(basic_source);
        var basic = basic_pipeline_module.createBasicPipeline(gctx, bind_group_layouts, basic_source);
        errdefer basic.deinit(gctx);
        const basic_skinned_source = try layout.shaderSource(allocator, basic_skinned_pipeline_module.shader_body);
        defer allocator.free(basic_skinned_source);
        var basic_skinned = basic_skinned_pipeline_module.createBasicSkinnedPipeline(gctx, bind_group_layouts, basic_skinned_source);
        errdefer basic_skinned.deinit(gctx);
        const voxel_source = try layout.shaderSource(allocator, voxel_pipeline_module.shader_body);
        defer allocator.free(voxel_source);
        var voxel = voxel_pipeline_module.createVoxelPipeline(gctx, bind_group_layouts, voxel_source);
        errdefer voxel.deinit(gctx);
        const shadow_map_source = try layout.shaderSource(allocator, shadow_map_pipeline_module.shader_body);
        defer allocator.free(shadow_map_source);
        var shadow_map = shadow_map_pipeline_module.createShadowMapPipeline(gctx, bind_group_layouts, shadow_map_source);
        errdefer shadow_map.deinit(gctx);
        const shadow_map_skinned_source = try layout.shaderSource(allocator, shadow_map_skinned_pipeline_module.shader_body);
        defer allocator.free(shadow_map_skinned_source);
        var shadow_map_skinned = shadow_map_skinned_pipeline_module.createShadowMapSkinnedPipeline(gctx, bind_group_layouts, shadow_map_skinned_source);
        errdefer shadow_map_skinned.deinit(gctx);
        const shadow_map_voxel_source = try layout.shaderSource(allocator, shadow_map_voxel_pipeline_module.shader_body);
        defer allocator.free(shadow_map_voxel_source);
        var shadow_map_voxel = shadow_map_voxel_pipeline_module.createShadowMapVoxelPipeline(gctx, bind_group_layouts, shadow_map_voxel_source);
        errdefer shadow_map_voxel.deinit(gctx);
        return .{
            .basic = basic,
            .basic_skinned = basic_skinned,
            .voxel_pipeline = voxel,
            .shadow_map = shadow_map,
            .shadow_map_skinned = shadow_map_skinned,
            .shadow_map_voxel = shadow_map_voxel,
        };
    }

    pub fn deinit(self: *WorldPipelines, gctx: *zgpu.GraphicsContext) void {
        self.basic.deinit(gctx);
        self.basic_skinned.deinit(gctx);
        self.voxel_pipeline.deinit(gctx);
        self.shadow_map.deinit(gctx);
        self.shadow_map_skinned.deinit(gctx);
        self.shadow_map_voxel.deinit(gctx);
    }
};
