//! Headless resource checks invoked by world_shader_tests.zig.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zstbi = @import("zstbi");
const Engine = @import("engine.zig").Engine;
const InputController = @import("input_controller.zig").InputController(Engine);
const types = @import("types.zig");
const Scene = @import("scene.zig").Scene;
const layouts_module = @import("bind_group_layouts.zig");
const Pipelines = @import("pipelines.zig").Pipelines;
const DepthTexture = @import("textures/depth_texture.zig").DepthTexture;
const ScreenTexture = @import("textures/screen_texture.zig").ScreenTexture;
const ShadowMapTexture = @import("textures/shadow_map_texture.zig").ShadowMapTexture;
const SkeletalAnimation = @import("skeletal_animation.zig");
const GltfLoader = @import("gltf_loader").GltfLoader;

const pool_names = .{
    "buffer_pool",          "texture_pool",          "texture_view_pool", "sampler_pool",
    "render_pipeline_pool", "compute_pipeline_pool", "bind_group_pool",   "bind_group_layout_pool",
    "pipeline_layout_pool",
};
const Counts = [pool_names.len]usize;

fn counts(gctx: *zgpu.GraphicsContext) Counts {
    var result: Counts = undefined;
    inline for (pool_names, 0..) |name, i| result[i] = @field(gctx, name).pool.liveHandleCount();
    return result;
}

fn texture(gctx: *zgpu.GraphicsContext, format: wgpu.TextureFormat) types.TextureDescriptor {
    const handle = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .size = .{ .width = 1, .height = 1 },
        .format = format,
    });
    const view = gctx.createTextureView(handle, .{});
    return .{ .texture_handle = handle, .texture = gctx.lookupResource(handle).?, .view_handle = view, .view = gctx.lookupResource(view).? };
}

/// Exercise the real Engine.deinit with real GPU resources, without GLFW or a swapchain.
/// The input controller has no installed callback, and its window is never accessed.
fn createEngine(gctx: *zgpu.GraphicsContext) !*Engine {
    const allocator = std.testing.allocator;
    const engine = try allocator.create(Engine);
    errdefer allocator.destroy(engine);
    const input = try allocator.create(InputController);
    errdefer allocator.destroy(input);
    const content_dir = try allocator.dupe(u8, "content");
    input.* = .{
        .allocator = allocator,
        .window = undefined,
        .callbacks = .{ .context = engine },
        .pressed_keys = .init(allocator),
        .release_queue = .init(allocator),
        .cursor_position = .{ 0, 0 },
    };
    engine.* = undefined;
    engine.allocator = allocator;
    engine.io = std.testing.io;
    engine.gctx = gctx;
    engine.input_controller = input;
    engine.content_dir = content_dir;
    engine.aspect_ratio = 1;
    engine.time = 0;
    engine.active_scene = null;
    engine.live_scene_count = 0;
    engine.models_hash = .init(allocator);
    engine.special_models = .empty;
    engine.temp_buffers = .{
        .visible_objects_lists = .empty,
        .visible_objects_lists_chunks = .empty,
        .regular_objects = .empty,
        .skinned_objects = .empty,
        .wireframe_objects = .empty,
        .rest_objects = .empty,
    };
    engine.world_pipeline_cache = .init(allocator, gctx);
    engine.bind_group_layouts = layouts_module.BindGroupLayouts.init(gctx);
    engine.pipelines = Pipelines.init(gctx, &engine.bind_group_layouts);
    engine.texture_sampler = gctx.createSampler(.{});
    engine.texture_repeat_sampler = gctx.createSampler(.{ .address_mode_u = .repeat });
    engine.texture_mirror_sampler = gctx.createSampler(.{ .address_mode_u = .mirror_repeat });
    engine.depth_texture = DepthTexture.init(gctx, 8, 8);
    engine.shadow_map_depth_texture = DepthTexture.init(gctx, 1024, 1024);
    engine.shadow_map_texture = ShadowMapTexture.init(gctx, .{ .layers_count = 3 });
    engine.first_pass_color_output_texture = ScreenTexture.init(gctx, 8, 8, .rgba16_float);
    engine.first_pass_normal_output_texture = ScreenTexture.init(gctx, 8, 8, .rgba16_float);
    engine.ssao_output_texture = ScreenTexture.init(gctx, 8, 8, .r16_float);
    engine.uv_test_texture = texture(gctx, .rgba8_unorm);
    engine.minecraft_texture = texture(gctx, .rgba8_unorm);
    const layouts = engine.bind_group_layouts;
    engine.bind_group_debug_shadow_map_texture = layouts.debug_texture.createBindGroup(gctx, engine.texture_sampler, engine.shadow_map_texture.array_view.view_handle);
    engine.bind_group_shadow_map = layouts.shadow_map.createBindGroup(gctx, engine.texture_sampler, engine.shadow_map_texture.array_view.view_handle);
    engine.bind_group_lines = layouts.lines.createBindGroup(gctx);
    engine.bind_group_ssao_pass = layouts.ssao_pass.createBindGroup(gctx, engine.texture_sampler, engine.depth_texture.view_handle, engine.first_pass_normal_output_texture.view_handle);
    engine.bind_group_final_pass = layouts.final_pass.createBindGroup(gctx, engine.texture_sampler, engine.depth_texture.view_handle, engine.first_pass_color_output_texture.view_handle, engine.first_pass_normal_output_texture.view_handle, engine.ssao_output_texture.view_handle);
    engine.bind_group_debug_regular = layouts.regular.createBindGroup(gctx, engine.texture_repeat_sampler, engine.uv_test_texture);
    engine.bind_group_minecraft_texture = layouts.regular.createBindGroup(gctx, engine.texture_repeat_sampler, engine.minecraft_texture);
    engine.identity_joint_matrix_buffer = try SkeletalAnimation.createIdentityJointMatrixBuffer(gctx);
    engine.cube_wireframe_model = try engine.loadCubeWireframeModel();
    zstbi.init(std.testing.io, allocator);
    return engine;
}

pub fn check(device: wgpu.Device) !void {
    const allocator = std.testing.allocator;
    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = device;
    gctx.queue = device.getQueue();
    defer gctx.queue.release();
    gctx.uniforms = .{};
    gctx.stats = .{};
    gctx.window_provider = .{ .window = undefined, .fn_getTime = fakeTime, .fn_getFramebufferSize = undefined };
    gctx.mipgens = .init(allocator);
    defer gctx.mipgens.deinit();
    inline for (pool_names) |name| @field(gctx, name) = .{ .pool = try @TypeOf(@field(gctx, name).pool).initCapacity(allocator, 256) };
    defer inline for (pool_names) |name| @field(gctx, name).pool.deinit();
    gctx.uniforms.buffer = gctx.createBuffer(.{ .usage = .{ .uniform = true, .copy_dst = true }, .size = 4 * 1024 * 1024 });
    defer gctx.destroyResource(gctx.uniforms.buffer);
    var staging: [8]zgpu.BufferHandle = undefined;
    for (&staging, 0..) |*handle, i| {
        handle.* = gctx.createBuffer(.{ .usage = .{ .copy_src = true, .map_write = true }, .size = 4 * 1024 * 1024, .mapped_at_creation = .true });
        const buffer = gctx.lookupResource(handle.*).?;
        gctx.uniforms.stage.buffers[i] = .{ .buffer = buffer, .slice = buffer.getMappedRange(u8, 0, 4 * 1024 * 1024).? };
    }
    gctx.uniforms.stage.num = 8;
    defer {
        // Outstanding submissions and map callbacks reference this graphics context.
        while (gctx.stats.cpu_frame_number != gctx.stats.gpu_frame_number or !allMapped(&gctx)) device.tick();
        for (staging) |handle| gctx.destroyResource(handle);
        var it = gctx.mipgens.valueIterator();
        while (it.next()) |mipgen| {
            gctx.releaseResource(mipgen.pipeline);
            gctx.releaseResource(mipgen.bind_group_layout);
            for (mipgen.scratch_texture_views) |view| gctx.releaseResource(view);
            gctx.destroyResource(mipgen.scratch_texture);
        }
    }
    // Mipmap scratch resources belong to the graphics context and are retained across engines.
    // Warm the cache before measuring engine-owned resources or injecting allocation failures.
    {
        zstbi.init(std.testing.io, allocator);
        defer zstbi.deinit();
        var image = try @import("texture_loader.zig").loadTextureData(allocator, "content/window-block/wb-texture.png");
        defer image.deinit();
        const uploaded = try @import("load_texture.zig").loadTextureIntoGpu(&gctx, allocator, image, .{ .generate_mipmaps = true });
        uploaded.deinit(&gctx);
    }
    const context_baseline = counts(&gctx);

    // Context stays alive across complete engine teardown and recreation.
    for (0..2) |iteration| {
        {
            const height_texture = texture(&gctx, .r16_uint);
            defer height_texture.deinit(&gctx);
            {
                const engine = try createEngine(&gctx);
                defer engine.deinit();
                const params: Engine.CreateTerrainHeightMapDescriptorParams = .{
                    .layers = .{ engine.uv_test_texture, engine.uv_test_texture },
                    .mixing_texture = engine.uv_test_texture,
                    .depth_map_texture = height_texture,
                };
                try checkScenes(engine, params);
                try checkBorrowedFallbackAndLoadErrors(engine);
                try std.testing.expectEqual(@as(usize, 0), engine.live_scene_count);
                try std.testing.expect(engine.active_scene == null);
                if (iteration == 0) {
                    try std.testing.checkAllAllocationFailures(allocator, checkSceneFailures, .{engine});
                    const loader = try engine.initLoader("man/man.gltf");
                    defer loader.deinit();
                    inline for (std.meta.tags(ModelKind)) |kind| {
                        try std.testing.checkAllAllocationFailures(allocator, checkModelFailures, .{ engine, params, &loader, kind });
                    }
                }
            }
            try std.testing.expect(gctx.isResourceValid(height_texture.texture_handle));
        }
        try std.testing.expectEqualDeep(context_baseline, counts(&gctx));
    }
}

fn checkScenes(engine: *Engine, params: Engine.CreateTerrainHeightMapDescriptorParams) !void {
    const terrain = try engine.createTerrainHeightMapModel(params);
    const loader = try engine.initLoader("man/man.gltf");
    defer loader.deinit();
    const id = try engine.loadModel(&loader, loader.findFirstObjectWithMesh().?, .{ .animations = &.{"walkLikeMan"} });
    const model = engine.models_hash.get(id).?;
    const baseline = counts(engine.gctx);
    {
        const first = try engine.createScene(.{ .size_in_chunks = .{ 8, 8, 8 } });
        var first_alive = true;
        defer if (first_alive) first.deinit();
        const second = try engine.createScene(.{ .size_in_chunks = .{ 8, 8, 8 } });
        defer second.deinit();
        const group = try first.addGroup();
        const child = try group.addGroup();
        _ = try first.addTerrainHeightMapObject(.{ .model = terrain, .position = .{ 0, 0, 0 }, .parent = child });
        _ = try first.addTerrainHeightMapObject(.{ .model = terrain, .position = .{ 1, 0, 0 }, .parent = group });
        _ = try second.addTerrainHeightMapObject(.{ .model = terrain, .position = .{ 2, 0, 0 } });
        _ = try first.addObject(.{ .model_id = id, .position = .{ 0, 0, 0 }, .parent = child, .animation_name = "walkLikeMan" });
        _ = try second.addObject(.{ .model_id = id, .position = .{ 1, 0, 0 }, .parent = null, .animation_name = "walkLikeMan" });
        try std.testing.expectEqual(@as(usize, 2), engine.live_scene_count);
        first.deinit();
        first_alive = false;
        try std.testing.expect(engine.active_scene == null);
        try std.testing.expectEqual(@as(usize, 1), engine.live_scene_count);
        try std.testing.expect(engine.gctx.isResourceValid(terrain.bind_group.bind_group_handle));
        try std.testing.expect(engine.gctx.isResourceValid(model.model_descriptor.position.handle));
        engine.active_scene = second;
    }
    try std.testing.expectEqualDeep(baseline, counts(engine.gctx));
}

fn checkSceneFailures(allocator: std.mem.Allocator, engine: *Engine) !void {
    const baseline = counts(engine.gctx);
    defer std.debug.assert(std.meta.eql(baseline, counts(engine.gctx)));
    const live_scenes = engine.live_scene_count;
    defer std.debug.assert(engine.live_scene_count == live_scenes);
    const scene = try Scene.init(engine, allocator, .{ .size_in_chunks = .{ 8, 8, 8 } });
    defer scene.deinit();
    _ = try scene.addGroup();
}

fn releaseModels(engine: *Engine) void {
    var it = engine.models_hash.valueIterator();
    while (it.next()) |model| {
        model.*.deinit(engine.gctx);
        engine.allocator.destroy(model.*);
    }
    engine.models_hash.deinit();
    for (engine.special_models.items) |model| switch (model) {
        inline else => |pointer| {
            pointer.deinit(engine.gctx);
            engine.allocator.destroy(pointer);
        },
    };
    engine.special_models.deinit(engine.allocator);
}

const ModelKind = enum { wireframe, terrain, primitive, window_box, skybox, cubemap, regular, animated };

fn checkModelFailures(allocator: std.mem.Allocator, engine: *Engine, params: Engine.CreateTerrainHeightMapDescriptorParams, loader: *const GltfLoader, kind: ModelKind) !void {
    const baseline = counts(engine.gctx);
    defer std.debug.assert(std.meta.eql(baseline, counts(engine.gctx)));
    var scratch = engine.*;
    scratch.allocator = allocator;
    scratch.models_hash = .init(allocator);
    scratch.special_models = .empty;
    defer releaseModels(&scratch);
    switch (kind) {
        .wireframe => _ = try scratch.loadCubeWireframeModel(),
        .terrain => _ = try scratch.createTerrainHeightMapModel(params),
        .primitive => {
            var geometry = try @import("shape_generation/quad.zig").initCenteredQuad(allocator);
            defer geometry.deinit(allocator);
            _ = try scratch.loadPrimitive(geometry);
        },
        .window_box => _ = try scratch.loadWindowBoxModel("window-block/wb-texture.png"),
        .skybox => _ = try scratch.loadSkyBoxModel("skybox/cubemaps_skybox.png"),
        .cubemap => _ = try scratch.loadSkyBoxCubemapModel(.{
            "skybox/skybox/right.jpg",  "skybox/skybox/left.jpg",  "skybox/skybox/top.jpg",
            "skybox/skybox/bottom.jpg", "skybox/skybox/front.jpg", "skybox/skybox/back.jpg",
        }),
        .regular, .animated => _ = try scratch.loadModel(loader, loader.findFirstObjectWithMesh().?, .{
            .animations = if (kind == .animated) &.{"walkLikeMan"} else &.{},
        }),
    }
}

fn fakeTime() f64 {
    return 1;
}

fn allMapped(gctx: *zgpu.GraphicsContext) bool {
    for (gctx.uniforms.stage.buffers[0..gctx.uniforms.stage.num]) |buffer| if (buffer.slice == null) return false;
    return true;
}

fn checkBorrowedFallbackAndLoadErrors(engine: *Engine) !void {
    const allocator = std.testing.allocator;
    const loader = try engine.initLoader("man/man.gltf");
    defer loader.deinit();
    const object = loader.findFirstObjectWithMesh().?;
    const baseline = counts(engine.gctx);
    try std.testing.expectError(error.AnimationNotFound, engine.loadModel(&loader, object, .{ .animations = &.{"missing-lifetime-test-animation"} }));
    try std.testing.expectEqualDeep(baseline, counts(engine.gctx));
    try std.testing.expectError(error.ImageInitFailed, engine.loadSkyBoxCubemapModel(.{
        "skybox/skybox/right.jpg",  "skybox/skybox/left.jpg",  "skybox/skybox/top.jpg",
        "skybox/skybox/bottom.jpg", "skybox/skybox/front.jpg", "missing-lifetime-test-image.jpg",
    }));
    try std.testing.expectEqualDeep(baseline, counts(engine.gctx));

    // Reuse the real mesh with its material texture removed, forcing a borrowed fallback.
    var wrapper = loader.gltf_wrapper.*;
    const materials = try allocator.dupe(@TypeOf(wrapper.gltf_root.materials[0]), wrapper.gltf_root.materials);
    defer allocator.free(materials);
    for (materials) |*material| material.pbrMetallicRoughness.baseColorTexture = null;
    wrapper.gltf_root.materials = materials;
    var fallback_loader = loader;
    fallback_loader.gltf_wrapper = &wrapper;
    {
        var scratch = engine.*;
        scratch.models_hash = .init(allocator);
        scratch.special_models = .empty;
        defer releaseModels(&scratch);
        const id = try scratch.loadModel(&fallback_loader, object, .{});
        const model = scratch.models_hash.get(id).?;
        try std.testing.expect(!model.model_descriptor.owns_color_texture);
        try std.testing.expectEqual(engine.uv_test_texture.texture_handle, model.model_descriptor.color_texture.texture_handle);
    }
    try std.testing.expect(engine.gctx.isResourceValid(engine.uv_test_texture.texture_handle));
    try std.testing.expectEqualDeep(baseline, counts(engine.gctx));
}
