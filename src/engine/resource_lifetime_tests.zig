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
    try checkSceneMutation(engine, id);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkMutationFailures, .{ engine, id });
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

fn checkSceneMutation(engine: *Engine, id: Engine.LoadedModelId) !void {
    const baseline = counts(engine.gctx);
    const model = engine.models_hash.get(id).?;
    {
        const scene = try engine.createScene(.{ .size_in_chunks = .{ 8, 8, 8 } });
        defer scene.deinit();
        engine.active_scene = scene;
        try scene.addDirectionalLight(.{ .direction = .{ 0.5, 0.5, -1, 0 }, .color = .{ 1, 1, 1, 1 }, .intensity = 1 });
        const first = try scene.addObject(.{ .model_id = id, .position = .{ 10, 20, 30 }, .parent = null });
        engine.prepareSceneObjects();
        const old_buffer = scene.instance_buffer.handle;
        const old_binding = scene.scene_bind_group.bind_group_handle;
        // Grow past both the initial capacity and the previous hardcoded cap.
        for (1..4097) |i| {
            _ = try scene.addObject(.{ .model_id = id, .position = .{ @floatFromInt(i), 0, 0 }, .parent = null });
        }
        try std.testing.expect(scene.instance_buffer.buffer.len >= 4097);
        try std.testing.expect(!engine.gctx.isResourceValid(old_buffer));
        try std.testing.expect(!engine.gctx.isResourceValid(old_binding));
        try std.testing.expect(engine.gctx.isResourceValid(scene.scene_bind_group.bind_group_handle));
        engine.prepareSceneObjects();
        try std.testing.expectEqual(@as(usize, 4), engine.temp_buffers.visible_objects_lists_chunks.items.len);
        for (engine.temp_buffers.visible_objects_lists_chunks.items) |count| try std.testing.expectEqual(@as(usize, 4097), count);
        // The first transform is clean: growing storage must preserve it anyway.
        try expectGpuTransforms(scene, &.{ 0, 4096 });
        const removed = scene.game_objects.items[2048];
        try scene.removeObject(removed);
        first.setPosition(.{ 17, 18, 19 });
        const replacement = try scene.addObject(.{ .model_id = id, .position = .{ -100, 2, 3 }, .parent = null });
        try std.testing.expectEqual(@as(u32, 2048), replacement.instance_index.?);
        engine.prepareSceneObjects();
        try expectGpuTransforms(scene, &.{ 0, 2048, 4096 });
        try std.testing.expectEqual(@as(usize, 4097), scene.space_tree.objects.items.len);

        // Failed animation construction rolls back hierarchy, visibility and slot state.
        const group = try scene.addGroup();
        const before_failure = counts(engine.gctx);
        try std.testing.expectError(error.AnimationNotLoaded, scene.addObject(.{
            .model_id = id,
            .position = .{ 0, 0, 0 },
            .parent = group,
            .animation_name = "missing-scene-mutation-animation",
        }));
        try std.testing.expectEqual(@as(usize, 0), group.children.items.len);
        try std.testing.expectEqual(@as(usize, 4097), scene.game_objects.items.len);
        try std.testing.expectEqual(@as(usize, 4097), scene.space_tree.objects.items.len);
        try std.testing.expectEqualDeep(before_failure, counts(engine.gctx));
        const child = try group.addGroup();
        _ = try scene.addObject(.{ .model_id = id, .position = .{ 0, 0, 0 }, .parent = child, .animation_name = "walkLikeMan" });
        try scene.removeGroup(group);
        try std.testing.expectEqualDeep(before_failure, counts(engine.gctx));
        try std.testing.expectEqual(@as(usize, 0), scene.groups.items.len);
        try std.testing.expect(engine.gctx.isResourceValid(model.model_descriptor.position.handle));
    }
    try std.testing.expectEqualDeep(baseline, counts(engine.gctx));
}

/// Inject failures into both scene storage and the engine's draw scratch lists.
/// Every failed addition must preserve the already live hierarchy and instances.
fn checkMutationFailures(allocator: std.mem.Allocator, engine: *Engine, id: Engine.LoadedModelId) !void {
    const baseline = counts(engine.gctx);
    defer std.debug.assert(std.meta.eql(baseline, counts(engine.gctx)));
    const saved_allocator = engine.allocator;
    const saved_buffers = engine.temp_buffers;
    engine.allocator = allocator;
    engine.temp_buffers = .{
        .visible_objects_lists = .empty,
        .visible_objects_lists_chunks = .empty,
        .regular_objects = .empty,
        .skinned_objects = .empty,
        .wireframe_objects = .empty,
        .rest_objects = .empty,
    };
    defer {
        inline for (.{ "visible_objects_lists", "visible_objects_lists_chunks", "regular_objects", "skinned_objects", "wireframe_objects", "rest_objects" }) |name| {
            @field(engine.temp_buffers, name).deinit(allocator);
        }
        engine.temp_buffers = saved_buffers;
        engine.allocator = saved_allocator;
    }
    const scene = try Scene.init(engine, allocator, .{ .size_in_chunks = .{ 8, 8, 8 } });
    defer scene.deinit();
    const group = try scene.addGroup();
    const child = try group.addGroup();
    for (0..65) |i| {
        const handles = counts(engine.gctx);
        _ = scene.addObject(.{
            .model_id = id,
            .position = .{ @floatFromInt(i), 0, 0 },
            .parent = child,
            .animation_name = if (i == 0) "walkLikeMan" else null,
        }) catch |err| {
            try std.testing.expectEqual(i, scene.game_objects.items.len);
            try std.testing.expectEqual(i, scene.space_tree.objects.items.len);
            try std.testing.expectEqual(i, child.children.items.len);
            try std.testing.expectEqual(i, scene.instance_buffer.next_index - scene.instance_buffer.free_indices.items.len);
            try std.testing.expectEqualDeep(handles, counts(engine.gctx));
            return err;
        };
    }
    try scene.removeGroup(group);
    try std.testing.expectEqual(@as(usize, 0), scene.game_objects.items.len);
    try std.testing.expectEqual(@as(usize, 0), scene.groups.items.len);
    const reused = try scene.addObject(.{ .model_id = id, .position = .{ 0, 0, 0 }, .parent = null });
    try std.testing.expect(reused.instance_index.? < 65);
}

const MutationMap = struct {
    done: bool = false,
    status: wgpu.BufferMapAsyncStatus = .unknown,

    fn callback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
        const self: *MutationMap = @ptrCast(@alignCast(userdata));
        self.status = status;
        self.done = true;
    }
};

fn expectGpuTransforms(scene: *Scene, indices: []const u32) !void {
    const Entry = @import("scene.zig").InstanceBufferEntry;
    const device = scene.engine.gctx.device;
    const size = indices.len * @sizeOf(Entry);
    const readback = device.createBuffer(.{ .usage = .{ .copy_dst = true, .map_read = true }, .size = size });
    defer readback.release();
    const encoder = device.createCommandEncoder(null);
    defer encoder.release();
    for (indices, 0..) |index, i| {
        encoder.copyBufferToBuffer(scene.instance_buffer.gpu_buffer, @as(usize, index) * @sizeOf(Entry), readback, i * @sizeOf(Entry), @sizeOf(Entry));
    }
    const commands = encoder.finish(null);
    defer commands.release();
    scene.engine.gctx.queue.submit(&.{commands});
    var mapping: MutationMap = .{};
    readback.mapAsync(.{ .read = true }, 0, size, MutationMap.callback, &mapping);
    // Keep callback state alive after cancellation as well as successful mapping.
    defer {
        readback.unmap();
        while (!mapping.done) device.tick();
    }
    try @import("world_coordinate_readback.zig").waitForCallback(device, &mapping.done);
    try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
    const results = readback.getConstMappedRange(Entry, 0, indices.len) orelse return error.NoMappedGpuResults;
    for (indices, results) |index, entry| {
        try std.testing.expectEqualDeep(scene.instance_buffer.buffer[index], entry);
    }
}

fn checkSceneFailures(allocator: std.mem.Allocator, engine: *Engine) !void {
    const baseline = counts(engine.gctx);
    defer std.debug.assert(std.meta.eql(baseline, counts(engine.gctx)));
    const live_scenes = engine.live_scene_count;
    defer std.debug.assert(engine.live_scene_count == live_scenes);
    const scene = try Scene.init(engine, allocator, .{ .size_in_chunks = .{ 8, 8, 8 } });
    defer scene.deinit();
    try std.testing.expect(scene.directional_light == null);
    try scene.addDirectionalLight(.{ .direction = .{ 0.5, 0.5, -1, 0 }, .color = .{ 1, 1, 1, 1 }, .intensity = 1 });
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
