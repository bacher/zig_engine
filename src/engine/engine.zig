const std = @import("std");
const math = std.math;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");
const zmath = @import("zmath");
const zstbi = @import("zstbi");
const gltf_loader = @import("gltf_loader");

const debug = @import("debug");
const types = @import("./types.zig");
const load_texture = @import("./load_texture.zig");
const BufferDescriptor = types.BufferDescriptor;
const WindowContext = @import("./glue.zig").WindowContext;
const utils = @import("./utils.zig");
// -- pipelines --
const Pipeline = @import("./pipeline.zig").Pipeline;
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
// -- bind groups --
const BindGroupLayouts = @import("./bind_group_layouts.zig").BindGroupLayouts;
const BindGroup = @import("./bind_group.zig").BindGroup;
// -- depth texture --
const DepthTexture = @import("./depth_texture.zig").DepthTexture;
const ShadowMapTexture = @import("./shadow_map_texture.zig").ShadowMapTexture;
// -- display object descriptors --
const ModelDescriptor = @import("./display_object_descriptors/model_descriptor.zig").ModelDescriptor;
const BillboardMode = @import("./display_object_descriptors/model_descriptor.zig").BillboardMode;
const WindowBoxDescriptor = @import("./display_object_descriptors/window_box_descriptor.zig").WindowBoxDescriptor;
const SkyBoxDescriptor = @import("./display_object_descriptors/skybox_descriptor.zig").SkyBoxDescriptor;
const SkyBoxCubemapDescriptor = @import("./display_object_descriptors/skybox_cubemap_descriptor.zig").SkyBoxCubemapDescriptor;
const CubeWireframeDescriptor = @import("./display_object_descriptors/cube_wireframe_descriptor.zig").CubeWireframeDescriptor;
// -- models types --
const Model = @import("./model.zig").Model;
const SkyBoxModel = @import("./model.zig").SkyBoxModel;
const SkyBoxCubemapModel = @import("./model.zig").SkyBoxCubemapModel;
const WindowBoxModel = @import("./model.zig").WindowBoxModel;
const PrimitiveModel = @import("./model.zig").PrimitiveModel;
const CubeWireframeModel = @import("./model.zig").CubeWireframeModel;
const TerrainHeightMapModel = @import("./model.zig").TerrainHeightMapModel;
const SkeletalAnimation = @import("./skeletal_animation.zig");
// -- other --
const PrimitiveDescriptor = @import("./display_object_descriptors/primitive_descriptor.zig").PrimitiveDescriptor;
const GeometryData = @import("./shape_generation/geometry_data.zig").GeometryData;
const Scene = @import("./scene.zig").Scene;
const Camera = @import("./camera.zig").Camera;
const InputController = @import("./input_controller.zig").InputController;
const GameObject = @import("./game_object.zig").GameObject;
const xRotate = @import("./game_object.zig").xRotate;
const DirectionalLight = @import("./light.zig").DirectionalLight;
const DirectionalLightCascade = @import("./light.zig").DirectionalLightCascade;

const DEBUG_INTERNAL_TEXTURE = false;
const DEBUG_SHOW_WIREFRAME_OBJECTS = true;

const GraphicsContextState = @typeInfo(@TypeOf(zgpu.GraphicsContext.present)).@"fn".return_type.?;

const billboard_normalization_matrix = zmath.mul(
    zmath.matFromQuat(
        zmath.quatFromNormAxisAngle(.{ 1, 0, 0, 1 }, 0.5 * math.pi),
    ),
    zmath.matFromQuat(
        zmath.quatFromNormAxisAngle(.{ 0, 0, 1, 1 }, 1 * math.pi),
    ),
);

pub const Engine = struct {
    pub const LoadedModelId = enum(u32) { _ };

    var is_instanced: bool = false;
    var next_loaded_model_id: u32 = 0;

    const Callbacks = struct {
        argument: *anyopaque,
        onUpdate: ?*const fn (engine: *Engine, argument: *anyopaque) void,
        onRender: ?*const fn (engine: *Engine, pass: wgpu.RenderPassEncoder, argument: *anyopaque) void,
    };

    gctx: *zgpu.GraphicsContext,
    io: std.Io,
    allocator: std.mem.Allocator,
    aspect_ratio: f32,
    window_context: WindowContext,
    callbacks: Callbacks,
    content_dir: []const u8,
    init_time: f64,
    time: f64,

    pipelines: struct {
        basic: Pipeline,
        basic_skinned: Pipeline,
        skybox: Pipeline,
        skybox_cubemap: Pipeline,
        window_box: Pipeline,
        primitive_colorized: Pipeline,
        terrain_height_map: Pipeline,
        // ---
        shadow_map: Pipeline,
        shadow_map_skinned: Pipeline,
        // ---
        lines: Pipeline,
        debug_texture: Pipeline,
    },

    bind_group_layouts: BindGroupLayouts,

    // ---
    bind_group_shadow_map_pass: BindGroup,
    bind_group_debug_shadow_map_texture: BindGroup,
    bind_group_shadow_map: BindGroup,
    bind_group_lines: BindGroup,

    depth_texture: DepthTexture,
    texture_sampler: zgpu.SamplerHandle,
    texture_repeat_sampler: zgpu.SamplerHandle,
    texture_mirror_sampler: zgpu.SamplerHandle,

    models_hash: std.AutoHashMap(LoadedModelId, *Model),
    shadow_map_texture: ShadowMapTexture,
    shadow_map_depth_texture: DepthTexture,

    uv_test_texture: types.TextureDescriptor,
    identity_joint_matrix_buffer: SkeletalAnimation.JointMatrixBuffer,

    active_scene: ?*Scene,
    input_controller: *InputController,

    frame_stats: struct {
        game_objects_drawn_count: u32 = 0,
        shadow_map_pass_time_taken: f32 = 0,
        main_pass_time_taken: f32 = 0,

        // ---
        active_space_nodes_count: u32 = 0,
        find_objects_sub_invocations_count: u32 = 0,
    } = .{},

    // -- built-in models --
    cube_wireframe_model: *CubeWireframeModel,

    // -- temporary buffers --
    temp_buffers: struct {
        regular_objects: std.ArrayList(*GameObject) = undefined,
        skinned_objects: std.ArrayList(*GameObject) = undefined,
        wireframe_objects: std.ArrayList(*GameObject) = undefined,
        rest_objects: std.ArrayList(*GameObject) = undefined,

        fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .regular_objects = std.ArrayList(*GameObject).initCapacity(allocator, 1024) catch @panic("Failed to initialize regular objects buffer"),
                .skinned_objects = std.ArrayList(*GameObject).initCapacity(allocator, 1024) catch @panic("Failed to initialize skinned objects buffer"),
                .wireframe_objects = std.ArrayList(*GameObject).initCapacity(allocator, 1024) catch @panic("Failed to initialize wireframe objects buffer"),
                .rest_objects = std.ArrayList(*GameObject).initCapacity(allocator, 1024) catch @panic("Failed to initialize rest objects buffer"),
            };
        }

        fn deinit(buffers: *@This(), allocator: std.mem.Allocator) void {
            buffers.regular_objects.deinit(allocator);
            buffers.skinned_objects.deinit(allocator);
            buffers.wireframe_objects.deinit(allocator);
            buffers.rest_objects.deinit(allocator);
        }

        fn reset(buffers: *@This()) void {
            buffers.regular_objects.clearRetainingCapacity();
            buffers.skinned_objects.clearRetainingCapacity();
            buffers.wireframe_objects.clearRetainingCapacity();
            buffers.rest_objects.clearRetainingCapacity();
        }
    },

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        window_context: WindowContext,
        content_dir: []const u8,
        callbacks: Callbacks,
    ) !*Engine {
        if (Engine.is_instanced) {
            return error.EngineCanHaveOnlyOneInstance;
        }

        zstbi.init(io, allocator);

        const gctx = window_context.gctx;
        const init_time = gctx.stats.time;

        const shadow_map_texture = try ShadowMapTexture.init(gctx, .{ .layers_count = 3 });
        errdefer shadow_map_texture.deinit();

        const shadow_map_depth_texture = try DepthTexture.init(gctx, 1024, 1024);
        errdefer shadow_map_depth_texture.deinit(gctx);

        const texture_sampler = gctx.createSampler(.{});
        const texture_repeat_sampler = gctx.createSampler(.{
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
        });
        const texture_mirror_sampler = gctx.createSampler(.{
            .address_mode_u = .mirror_repeat,
            .address_mode_v = .mirror_repeat,
        });

        // ---
        // bind group definitions
        // ---
        const bind_group_layouts = BindGroupLayouts.init(gctx);

        // ---
        // bind groups
        // ---
        const bind_group_shadow_map_pass = bind_group_layouts.shadow_map_pass.createBindGroup(gctx);
        const bind_group_debug_shadow_map_texture = bind_group_layouts.debug_texture.createBindGroup(
            gctx,
            texture_sampler,
            shadow_map_texture.array_view.view_handle,
        );
        const bind_group_shadow_map = bind_group_layouts.shadow_map.createBindGroup(
            gctx,
            texture_sampler,
            shadow_map_texture.array_view.view_handle,
        );
        const bind_group_lines = bind_group_layouts.lines.createBindGroup(gctx);

        // ---
        // pipelines
        // ---
        const basic_pipeline = try basic_pipeline_module.createBasicPipeline(
            gctx,
            bind_group_layouts.scene,
            bind_group_layouts.regular,
            bind_group_layouts.shadow_map,
            bind_group_layouts.instances_buffer,
        );
        const basic_skinned_pipeline = try basic_skinned_pipeline_module.createBasicSkinnedPipeline(
            gctx,
            bind_group_layouts.regular,
            bind_group_layouts.shadow_map,
            bind_group_layouts.joints,
        );
        const skybox_pipeline = try skybox_pipeline_module.createSkyboxPipeline(
            gctx,
            bind_group_layouts.regular,
        );
        const skybox_cubemap_pipeline = try skybox_cubemap_pipeline_module.createSkyboxCubemapPipeline(
            gctx,
            bind_group_layouts.cubemap,
        );
        const window_box_pipeline = try window_box_pipeline_module.createWindowBoxPipeline(
            gctx,
            bind_group_layouts.regular,
        );
        const primitive_colorized_pipeline = try primitive_colorized_pipeline_module.createPrimitiveColorizedPipeline(
            gctx,
            bind_group_layouts.primitive_colorized,
        );
        const terrain_height_map_pipeline = try terrain_height_map_pipeline_module.createTerrainHeightMapPipeline(
            gctx,
            bind_group_layouts.terrain_height_map,
            bind_group_layouts.shadow_map,
        );
        const shadow_map_pipeline = try shadow_map_pipeline_module.createShadowMapPipeline(
            gctx,
            bind_group_layouts.scene,
            bind_group_layouts.instances_buffer,
        );
        const shadow_map_skinned_pipeline = try shadow_map_skinned_pipeline_module.createShadowMapSkinnedPipeline(
            gctx,
            bind_group_layouts.shadow_map_pass,
            bind_group_layouts.joints,
        );
        const lines_pipeline = try lines_pipeline_module.createLinesPipeline(
            gctx,
            bind_group_layouts.lines,
        );
        const debug_texture_pipeline = try debug_texture_pipeline_module.createDebugTexturePipeline(
            gctx,
            bind_group_layouts.debug_texture,
        );

        const depth_texture = try DepthTexture.init(
            gctx,
            gctx.swapchain_descriptor.width,
            gctx.swapchain_descriptor.height,
        );
        errdefer depth_texture.deinit(gctx);

        const input_controller = try InputController.init(allocator, window_context.window);
        input_controller.listenWindowEvents();
        errdefer input_controller.deinit();

        const content_dir_copied = try allocator.dupe(u8, content_dir);
        errdefer allocator.free(content_dir_copied);

        var uv_test_image = try gltf_loader.StbiWrapper.loadTextureData(
            allocator,
            "content/uv-test.png",
            .{},
        );
        defer uv_test_image.deinit();

        const uv_test_texture = try load_texture.loadTextureIntoGpu(
            gctx,
            allocator,
            uv_test_image,
            .{ .generate_mipmaps = false }, // TODO: set true, maybe???
        );

        const identity_joint_matrix_buffer = try SkeletalAnimation.createIdentityJointMatrixBuffer(gctx);

        const engine = try allocator.create(Engine);
        engine.* = .{
            .allocator = allocator,
            .io = io,
            .aspect_ratio = getAspectRatio(gctx),
            .window_context = window_context,
            .callbacks = callbacks,
            .content_dir = content_dir_copied,
            .init_time = init_time,
            .time = 0,
            .gctx = gctx,
            .pipelines = .{
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
            },
            .bind_group_layouts = bind_group_layouts,

            // shadow map pass uses singleton bind group descriptor for all objects
            .bind_group_shadow_map_pass = bind_group_shadow_map_pass,
            .bind_group_shadow_map = bind_group_shadow_map,
            .bind_group_debug_shadow_map_texture = bind_group_debug_shadow_map_texture,
            .bind_group_lines = bind_group_lines,

            .depth_texture = depth_texture,
            .texture_sampler = texture_sampler,
            .texture_repeat_sampler = texture_repeat_sampler,
            .texture_mirror_sampler = texture_mirror_sampler,
            .models_hash = std.AutoHashMap(LoadedModelId, *Model).init(allocator),
            .shadow_map_texture = shadow_map_texture,
            .shadow_map_depth_texture = shadow_map_depth_texture,

            .uv_test_texture = uv_test_texture,
            .identity_joint_matrix_buffer = identity_joint_matrix_buffer,

            .active_scene = null,
            .input_controller = input_controller,

            // built-in models
            .cube_wireframe_model = undefined,

            .temp_buffers = .init(allocator),
        };
        errdefer engine.temp_buffers.deinit(allocator);

        engine.cube_wireframe_model = try engine.loadCubeWireframeModel();
        errdefer engine.cube_wireframe_model.deinit(engine.gctx);

        Engine.is_instanced = true;
        return engine;
    }

    pub fn deinit(engine: *Engine) void {
        engine.temp_buffers.deinit(engine.allocator);

        var iterator = engine.models_hash.iterator();
        while (iterator.next()) |entry| {
            const model_ptr = entry.value_ptr.*;
            model_ptr.deinit(engine.gctx);
            engine.allocator.destroy(model_ptr);
        }

        engine.models_hash.deinit();
        engine.identity_joint_matrix_buffer.deinit(engine.gctx);
        engine.bind_group_layouts.deinit(engine.gctx);
        engine.input_controller.deinit();
        engine.allocator.free(engine.content_dir);
        engine.allocator.destroy(engine.cube_wireframe_model);

        zstbi.deinit();
        engine.allocator.destroy(engine);
        Engine.is_instanced = false;
    }

    pub fn createScene(engine: *Engine) !*Scene {
        const scene = try Scene.init(
            engine,
            engine.allocator,
        );

        if (engine.active_scene == null) {
            engine.active_scene = scene;
        }

        return scene;
    }

    pub fn update(engine: *Engine) !void {
        engine.time = engine.gctx.stats.time - engine.init_time;

        // resetting frame stats before each frame
        engine.frame_stats = .{};

        try engine.input_controller.updateMouseState();

        if (engine.active_scene) |scene| {
            scene.camera.updateTargetScreenSize(engine.aspect_ratio);
            scene.update(engine.time);
        }

        if (engine.callbacks.onUpdate) |callback| {
            callback(engine, engine.callbacks.argument);
        }
    }

    pub fn draw(engine: *Engine) GraphicsContextState {
        const gctx = engine.gctx;
        const allocator = engine.allocator;

        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            // shadow map pass
            {
                if (engine.active_scene) |scene| {
                    const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                        .view = engine.shadow_map_depth_texture.view,
                        .depth_load_op = .clear,
                        .depth_store_op = .store,
                        .depth_clear_value = 1.0,
                    };

                    // var timer = std.time.Timer.start() catch @panic("Failed to start timer");
                    // defer engine.frame_stats.shadow_map_pass_time_taken = @as(f32, @floatFromInt(timer.read())) * 0.000001;
                    const timer = std.Io.Timestamp.now(engine.io, .awake);
                    defer {
                        const duration = timer.untilNow(engine.io, .awake);
                        engine.frame_stats.shadow_map_pass_time_taken = @as(f32, @floatFromInt(duration.nanoseconds)) * 0.000001;
                    }

                    for (scene.lights.items) |light| {
                        for (&light.cascades) |*cascade| {
                            const shadow_map_view = engine.shadow_map_texture.layers_views[@intFromEnum(cascade.layer)].view;

                            const shadow_map_attachments = [_]wgpu.RenderPassColorAttachment{.{
                                .view = shadow_map_view,
                                .load_op = .clear,
                                .store_op = .store,
                                .clear_value = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                            }};

                            const shadow_map_render_pass_info = wgpu.RenderPassDescriptor{
                                .color_attachments = &shadow_map_attachments,
                                .color_attachment_count = shadow_map_attachments.len,
                                .depth_stencil_attachment = &depth_attachment,
                            };

                            const shadow_map_pass = encoder.beginRenderPass(shadow_map_render_pass_info);
                            defer {
                                shadow_map_pass.end();
                                shadow_map_pass.release();
                            }

                            shadow_map_pass.setPipeline(engine.pipelines.shadow_map.pipeline_gpu);

                            light.applyCameraFrustum(cascade, scene.camera);

                            const cascade_view_bound_box = cascade.getLightViewBoundBox();
                            const potentially_visible_game_objects = scene.space_tree.getObjectsInBoundBox(
                                cascade_view_bound_box,
                            );

                            const world_to_clip_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                            world_to_clip_uniform.slice[0] = zmath.transpose(cascade.world_to_clip);
                            shadow_map_pass.setBindGroup(0, scene.scene_bind_group.wgpu_bind_group, &.{
                                world_to_clip_uniform.offset,
                            });

                            for (potentially_visible_game_objects) |game_object| {
                                const target_buffer = switch (game_object.model) {
                                    // if (game_object.joints_bind_group != null) { ???
                                    .regular_model => |model| if (model.model_descriptor.has_skin)
                                        &engine.temp_buffers.skinned_objects
                                    else
                                        &engine.temp_buffers.regular_objects,
                                    .primitive_colorized => &engine.temp_buffers.regular_objects,
                                    .window_box_model => &engine.temp_buffers.regular_objects,
                                    else => &engine.temp_buffers.rest_objects,
                                };
                                target_buffer.append(allocator, game_object) catch @panic("Failed to grow draw buffer");
                            }

                            shadow_map_pass.setPipeline(engine.pipelines.shadow_map.pipeline_gpu);
                            shadow_map_pass.setBindGroup(1, scene.instance_buffer.bind_group.wgpu_bind_group, &.{});

                            for (engine.temp_buffers.regular_objects.items) |game_object| {
                                engine.drawGameObjectToShadowMap(shadow_map_pass, scene, light, cascade, game_object);
                            }

                            if (engine.temp_buffers.skinned_objects.items.len > 0) {
                                shadow_map_pass.setPipeline(engine.pipelines.shadow_map_skinned.pipeline_gpu);
                                for (engine.temp_buffers.skinned_objects.items) |game_object| {
                                    engine.drawGameObjectToShadowMap(shadow_map_pass, scene, light, cascade, game_object);
                                }
                            }

                            for (engine.temp_buffers.rest_objects.items) |game_object| {
                                engine.drawGameObjectToShadowMap(shadow_map_pass, scene, light, cascade, game_object);
                            }

                            engine.temp_buffers.reset();
                        }
                    }
                }
            }

            // main pass
            {
                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .clear,
                    .store_op = .store,
                }};
                const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                    .view = engine.depth_texture.view,
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                    .depth_clear_value = 1.0,
                };
                const render_pass_info = wgpu.RenderPassDescriptor{
                    .color_attachments = &color_attachments,
                    .color_attachment_count = color_attachments.len,
                    .depth_stencil_attachment = &depth_attachment,
                };
                const pass = encoder.beginRenderPass(render_pass_info);
                defer {
                    pass.end();
                    pass.release();
                }

                if (engine.active_scene) |scene| {
                    const camera_view_bound_box = scene.camera.getCameraViewBoundBox();

                    const timer = std.Io.Timestamp.now(engine.io, .awake);

                    const potentially_visible_game_objects = scene.space_tree.getObjectsInBoundBox(
                        camera_view_bound_box,
                    );

                    // debug start
                    const stats = scene.space_tree.getLastGetObjectsInBoundBoxStats();
                    engine.frame_stats.active_space_nodes_count = stats.active_space_nodes_count;
                    engine.frame_stats.find_objects_sub_invocations_count = stats.invocations_count;
                    // debug end

                    const world_to_clip_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                    world_to_clip_uniform.slice[0] = zmath.transpose(scene.camera.world_to_clip);

                    pass.setBindGroup(3, scene.scene_bind_group.wgpu_bind_group, &.{
                        world_to_clip_uniform.offset,
                    });

                    // _ = potentially_visible_game_objects;
                    // for (scene.game_objects.items) |game_object| {
                    for (potentially_visible_game_objects) |game_object| {
                        const target_buffer = switch (game_object.model) {
                            .regular_model => |model| if (model.model_descriptor.has_skin)
                                &engine.temp_buffers.skinned_objects
                            else
                                &engine.temp_buffers.regular_objects,
                            else => &engine.temp_buffers.rest_objects,
                        };
                        target_buffer.append(allocator, game_object) catch @panic("Failed to grow draw buffer");

                        if (DEBUG_SHOW_WIREFRAME_OBJECTS) {
                            if (switch (game_object.model) {
                                .regular_model => true,
                                .window_box_model => true,
                                // Don't show bounding box for coordinates (they uses colorized primitives)
                                // .primitive_colorized => true,
                                else => false,
                            }) {
                                engine.temp_buffers.wireframe_objects.append(allocator, game_object) catch @panic("Failed to grow draw buffer");
                            }
                        }
                    }

                    pass.setPipeline(engine.pipelines.basic.pipeline_gpu);
                    for (engine.temp_buffers.regular_objects.items) |game_object| {
                        engine.drawGameObject(pass, scene, game_object);
                    }

                    if (engine.temp_buffers.skinned_objects.items.len > 0) {
                        pass.setPipeline(engine.pipelines.basic_skinned.pipeline_gpu);
                        for (engine.temp_buffers.skinned_objects.items) |game_object| {
                            engine.drawGameObject(pass, scene, game_object);
                        }
                    }

                    for (engine.temp_buffers.rest_objects.items) |game_object| {
                        engine.drawGameObject(pass, scene, game_object);
                    }

                    if (DEBUG_SHOW_WIREFRAME_OBJECTS) {
                        pass.setPipeline(engine.pipelines.lines.pipeline_gpu);
                        for (engine.temp_buffers.wireframe_objects.items) |game_object| {
                            engine.drawCubeWireframe(pass, scene, game_object);
                        }
                    }

                    engine.temp_buffers.reset();

                    engine.frame_stats.game_objects_drawn_count += @intCast(potentially_visible_game_objects.len);

                    const duration = timer.untilNow(engine.io, .awake);
                    engine.frame_stats.main_pass_time_taken = @as(f32, @floatFromInt(duration.nanoseconds)) * 0.000001;

                    if (DEBUG_INTERNAL_TEXTURE) {
                        engine.drawTextureDebugScreen(pass);
                    }
                }
            }

            if (engine.callbacks.onRender) |onRender| {
                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .load,
                    .store_op = .store,
                }};
                const render_pass_info = wgpu.RenderPassDescriptor{
                    .color_attachments = &color_attachments,
                    .color_attachment_count = color_attachments.len,
                };
                const pass = encoder.beginRenderPass(render_pass_info);
                defer {
                    pass.end();
                    pass.release();
                }

                onRender(engine, pass, engine.callbacks.argument);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});

        const gctx_state = gctx.present();

        return gctx_state;
    }

    fn drawGameObject(
        engine: *Engine,
        pass: wgpu.RenderPassEncoder,
        scene: *const Scene,
        game_object: *GameObject,
    ) void {
        switch (game_object.model) {
            .regular_model => |model| {
                const model_descriptor = model.model_descriptor;

                model_descriptor.position.applyVertexBuffer(pass, 0);
                model_descriptor.normal.applyVertexBuffer(pass, 1);
                model_descriptor.texcoord.applyVertexBuffer(pass, 2);
                if (model_descriptor.has_skin) {
                    model_descriptor.joints.applyVertexBuffer(pass, 3);
                    model_descriptor.weights.applyVertexBuffer(pass, 4);

                    game_object.updateAnimation(engine.gctx, @floatCast(engine.time));
                }
                model_descriptor.index.applyIndexBuffer(pass);
            },
            .terrain_height_map_model => {
                pass.setPipeline(engine.pipelines.terrain_height_map.pipeline_gpu);
            },
            .window_box_model => |window_box_model| {
                pass.setPipeline(engine.pipelines.window_box.pipeline_gpu);

                const model_descriptor = window_box_model.model_descriptor;
                model_descriptor.position.applyVertexBuffer(pass, 0);
            },
            .primitive_colorized => |primitive_colorized_model| {
                pass.setPipeline(engine.pipelines.primitive_colorized.pipeline_gpu);

                const model_descriptor = primitive_colorized_model.model_descriptor;
                model_descriptor.position.applyVertexBuffer(pass, 0);
            },
            .skybox_model => |skybox_model| {
                pass.setPipeline(engine.pipelines.skybox.pipeline_gpu);

                const model_descriptor = skybox_model.model_descriptor;
                model_descriptor.position.applyVertexBuffer(pass, 0);
                model_descriptor.uvs.applyVertexBuffer(pass, 1);
                model_descriptor.index.applyIndexBuffer(pass);
            },
            .skybox_cubemap_model => |skybox_cubemap_model| {
                pass.setPipeline(engine.pipelines.skybox_cubemap.pipeline_gpu);

                const model_descriptor = skybox_cubemap_model.model_descriptor;
                model_descriptor.position.applyVertexBuffer(pass, 0);
                model_descriptor.index.applyIndexBuffer(pass);
            },
        }

        const billboard_mode = switch (game_object.model) {
            .regular_model => |model| model.model_descriptor.options.billboard_mode,
            else => .none,
        };

        var model_to_world = game_object.aggregated_matrix;

        if (billboard_mode != .none) {
            const scale_vec = zmath.util.getScaleVec(game_object.aggregated_matrix);
            const position = game_object.aggregated_matrix[3];

            const billboard_rotation_matrix = if (billboard_mode == .spherical) zmath.mul(
                billboard_normalization_matrix,
                // inverse is needed because lookAtRh returns matrix which rotates world to camera,
                // but we need to rotate the object in the world space.
                zmath.inverse(
                    zmath.lookAtRh(
                        .{ 0, 0, 0, 1 },
                        zmath.loadArr3(scene.camera.position) - position,
                        .{ 0, 0, 1, 0 },
                    ),
                ),
            ) else cylindric_rotation_matrix: {
                const direction = zmath.loadArr3(scene.camera.position) - position;
                const angle = math.atan2(direction[1], direction[0]);

                break :cylindric_rotation_matrix zmath.matFromNormAxisAngle(
                    .{ 0, 0, 1, 1 },
                    angle + 0.5 * math.pi,
                );
            };

            model_to_world = zmath.mul(
                zmath.mul(
                    zmath.scalingV(scale_vec),
                    // instead of inner rotate, we apply billboard rotation matrix
                    billboard_rotation_matrix,
                ),
                zmath.translationV(position),
            );
        }

        const flip_yz = switch (game_object.model) {
            .regular_model => |model| model.model_descriptor.options.mesh_y_up,
            else => false,
        };
        if (flip_yz) {
            // NOTE: converting from Y-up to Z-up coordinate system,
            // should be done only for models which is made with Y-up logic.
            model_to_world = zmath.mul(xRotate, model_to_world);
        }

        var object_to_clip = zmath.mul(model_to_world, scene.camera.world_to_clip);
        if (game_object.model == .skybox_model or game_object.model == .skybox_cubemap_model) {
            object_to_clip = zmath.mul(
                scene.camera.camera_to_view,
                scene.camera.view_to_clip,
            );
            if (game_object.model == .skybox_cubemap_model) {
                object_to_clip = zmath.mul(xRotate, object_to_clip);
            }
        }

        const object_to_clip_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
        object_to_clip_uniform.slice[0] = zmath.transpose(object_to_clip);

        // TODO: support multiple lights
        const object_to_light_clip_array_uniform = getLightClipMatrixArray(
            engine.gctx,
            scene.lights.items[0],
            model_to_world,
        );

        const camera_position_in_model_space_uniform = engine.gctx.uniformsAllocate(zmath.Vec, 1);
        if (game_object.model == .window_box_model) {
            const camera_position = zmath.Vec{
                // TODO: how it can be simplified?
                scene.camera.position[0],
                scene.camera.position[1],
                scene.camera.position[2],
                1,
            };

            // TODO:
            // Instead of inverse it will be better to just apply transposed
            // rotation matrix and negative position shift (and scale if needed).
            // inverse is much more compute intensive than listed below operations.
            const model_to_world_inversed = zmath.inverse(model_to_world);
            const camera_position_in_model_space = zmath.mul(
                camera_position,
                model_to_world_inversed,
            );

            camera_position_in_model_space_uniform.slice[0] = camera_position_in_model_space;
        }

        switch (game_object.model) {
            .regular_model => |model| {
                pass.setBindGroup(0, model.bind_group.wgpu_bind_group, &.{
                    object_to_clip_uniform.offset, // TODO: is not used in basic (non-skinned) pipeline
                    camera_position_in_model_space_uniform.offset, // TODO: is not used in basic pipeline
                });

                pass.setBindGroup(1, engine.bind_group_shadow_map.wgpu_bind_group, &.{
                    object_to_light_clip_array_uniform.offset,
                });
                if (game_object.joints_bind_group) |joints_bind_group| {
                    pass.setBindGroup(2, joints_bind_group.wgpu_bind_group, &.{});
                } else {
                    pass.setBindGroup(2, scene.instance_buffer.bind_group.wgpu_bind_group, &.{});
                }

                if (model.model_descriptor.has_skin) {
                    pass.drawIndexed(model.model_descriptor.index.elements_count, 1, 0, 0, 0);
                } else {
                    pass.drawIndexed(model.model_descriptor.index.elements_count, 1, 0, 0, game_object.instance_index);
                }
            },
            .terrain_height_map_model => |model| {
                const time_uniform = engine.gctx.uniformsAllocate(u32, 1);
                time_uniform.slice[0] = @intFromFloat(engine.time * 1000);

                pass.setBindGroup(0, model.bind_group.wgpu_bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                    time_uniform.offset,
                });
                pass.setBindGroup(1, engine.bind_group_shadow_map.wgpu_bind_group, &.{
                    object_to_light_clip_array_uniform.offset,
                });

                // TODO: make customizable
                pass.draw(getTerrainHeightMapElementsCountForSide(64), 1, 0, 0);
            },
            .window_box_model => |window_box_model| {
                pass.setBindGroup(0, window_box_model.bind_group.wgpu_bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                const elements_count = window_box_model.model_descriptor.position.elements_count;

                pass.draw(elements_count, 1, 0, 0);
            },
            .skybox_model => |skybox_model| {
                pass.setBindGroup(0, skybox_model.bind_group.wgpu_bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                pass.drawIndexed(skybox_model.model_descriptor.index.elements_count, 1, 0, 0, 0);
            },
            .skybox_cubemap_model => |skybox_cubemap_model| {
                pass.setBindGroup(0, skybox_cubemap_model.bind_group.wgpu_bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                pass.drawIndexed(skybox_cubemap_model.model_descriptor.index.elements_count, 1, 0, 0, 0);
            },
            .primitive_colorized => |primitive_colorized_model| {
                const solid_color_uniform = engine.gctx.uniformsAllocate(zmath.Vec, 1);
                solid_color_uniform.slice[0] = game_object.debug.color;

                pass.setBindGroup(0, primitive_colorized_model.bind_group.wgpu_bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                    solid_color_uniform.offset,
                });

                const elements_count = primitive_colorized_model.model_descriptor.position.elements_count;

                pass.draw(elements_count, 1, 0, 0);
            },
        }
    }

    fn drawCubeWireframe(engine: *Engine, pass: wgpu.RenderPassEncoder, scene: *const Scene, game_object: *const GameObject) void {
        const model_descriptor = engine.cube_wireframe_model.model_descriptor;
        model_descriptor.position.applyVertexBuffer(pass, 0);

        const bounds = game_object.model.getBounds();
        const bound_center = utils.applyMat(bounds.offset, game_object.aggregated_matrix);
        const scale = zmath.util.getScaleVec(game_object.aggregated_matrix);
        const radius = bounds.radius * scale[0];

        const model_to_world =
            zmath.mul(
                // Ignoring rotation since box should be always axis-aligned.
                zmath.scaling(radius, radius, radius),
                zmath.translationV(bound_center),
            );

        const object_to_clip = zmath.mul(model_to_world, scene.camera.world_to_clip);
        // const object_to_clip = scene.camera.world_to_clip;
        const object_to_clip_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
        object_to_clip_uniform.slice[0] = zmath.transpose(object_to_clip);

        const color_uniform = engine.gctx.uniformsAllocate(zmath.Vec, 1);
        color_uniform.slice[0] = .{ 0.0, 1.0, 0.0, 1.0 };

        pass.setBindGroup(0, engine.bind_group_lines.wgpu_bind_group, &.{
            object_to_clip_uniform.offset,
            color_uniform.offset,
        });

        pass.draw(model_descriptor.position.elements_count, 1, 0, 0);
    }

    pub fn drawGameObjectToShadowMap(
        engine: *Engine,
        pass: wgpu.RenderPassEncoder,
        scene: *const Scene,
        light: *const DirectionalLight,
        cascade: *const DirectionalLightCascade,
        game_object: *GameObject,
    ) void {
        _ = scene;
        // TODO:
        _ = light;

        switch (game_object.model) {
            .regular_model => |model| {
                const model_descriptor = model.model_descriptor;

                model_descriptor.position.applyVertexBuffer(pass, 0);
                if (model_descriptor.has_skin) {
                    model_descriptor.joints.applyVertexBuffer(pass, 1);
                    model_descriptor.weights.applyVertexBuffer(pass, 2);

                    game_object.updateAnimation(engine.gctx, @floatCast(engine.time));
                }
                model_descriptor.index.applyIndexBuffer(pass);
            },
            .terrain_height_map_model => {
                // nothing to do
                // TODO: can't be rendered because shadow map relies on vertex data
                return;
            },
            .window_box_model => |window_box_model| {
                const model_descriptor = window_box_model.model_descriptor;
                model_descriptor.position.applyVertexBuffer(pass, 0);
            },
            .primitive_colorized => |primitive_colorized_model| {
                const model_descriptor = primitive_colorized_model.model_descriptor;
                model_descriptor.position.applyVertexBuffer(pass, 0);
            },
            .skybox_model,
            .skybox_cubemap_model,
            => {
                return;
            },
        }

        var model_to_world = game_object.aggregated_matrix;

        const flip_yz = switch (game_object.model) {
            .regular_model => |model| model.model_descriptor.options.mesh_y_up,
            else => false,
        };
        if (flip_yz) {
            // NOTE: converting from Y-up to Z-up coordinate system,
            // should be done only for models which is made with Y-up logic.
            model_to_world = zmath.mul(xRotate, model_to_world);
        }

        const object_to_clip = zmath.mul(model_to_world, cascade.world_to_clip);

        const object_to_clip_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
        object_to_clip_uniform.slice[0] = zmath.transpose(object_to_clip);

        switch (game_object.model) {
            .regular_model => |model| {
                if (game_object.joints_bind_group) |joints_bind_group| {
                    pass.setBindGroup(0, engine.bind_group_shadow_map_pass.wgpu_bind_group, &.{
                        object_to_clip_uniform.offset,
                    });
                    pass.setBindGroup(1, joints_bind_group.wgpu_bind_group, &.{});

                    pass.drawIndexed(model.model_descriptor.index.elements_count, 1, 0, 0, 0);
                } else {
                    pass.drawIndexed(model.model_descriptor.index.elements_count, 1, 0, 0, game_object.instance_index);
                }
            },
            .terrain_height_map_model => {
                // TODO: make customizable
                pass.draw(getTerrainHeightMapElementsCountForSide(64), 1, 0, 0);
            },
            .window_box_model => |window_box_model| {
                pass.draw(window_box_model.model_descriptor.position.elements_count, 1, 0, game_object.instance_index);
            },
            .primitive_colorized => |primitive_colorized_model| {
                pass.draw(primitive_colorized_model.model_descriptor.position.elements_count, 1, 0, game_object.instance_index);
            },
            .skybox_model,
            .skybox_cubemap_model,
            => {
                return;
            },
        }
    }

    pub fn drawTextureDebugScreen(engine: *Engine, pass: wgpu.RenderPassEncoder) void {
        pass.setPipeline(engine.pipelines.debug_texture.pipeline_gpu);

        const aspect_ratio_uniform = engine.gctx.uniformsAllocate(f32, 1);

        aspect_ratio_uniform.slice[0] = engine.aspect_ratio;

        pass.setBindGroup(0, engine.bind_group_debug_shadow_map_texture.wgpu_bind_group, &.{
            aspect_ratio_uniform.offset,
        });

        // drawing 6 vertices for fullscreen quad
        pass.draw(6, 1, 0, 0);
    }

    pub fn initLoader(engine: *Engine, model_name: []const u8) !gltf_loader.GltfLoader {
        const model_filename = try std.fs.path.join(engine.allocator, &.{
            engine.content_dir,
            model_name,
        });
        defer engine.allocator.free(model_filename);

        return try gltf_loader.GltfLoader.init(engine.io, engine.allocator, model_filename);
    }

    pub const LoadModelOptions = struct {
        mesh_y_up: bool = false,
        animations: []const []const u8 = &.{},
        billboard_mode: BillboardMode = .none,
        color_texture_fallback: ?*const types.TextureDescriptor = null,
    };

    pub fn loadModel(
        engine: *Engine,
        loader: *const gltf_loader.GltfLoader,
        object: *const gltf_loader.SceneObject,
        options: LoadModelOptions,
    ) !LoadedModelId {
        const model_descriptor = try ModelDescriptor.init(
            engine.gctx,
            engine.allocator,
            loader,
            object,
            .{
                .billboard_mode = options.billboard_mode,
                .mesh_y_up = options.mesh_y_up,
                .color_texture_fallback = options.color_texture_fallback orelse &engine.uv_test_texture,
            },
        );

        const skeletal_animation_data = try SkeletalAnimation.SkeletalAnimationData.init(
            engine.allocator,
            loader,
            object,
            options.animations,
        );
        errdefer if (skeletal_animation_data) |data| {
            data.deinit();
        };

        const bind_group = engine.bind_group_layouts.regular.createBindGroup(
            engine.gctx,
            engine.texture_repeat_sampler,
            model_descriptor.color_texture,
            engine.identity_joint_matrix_buffer.handle,
        );

        const model = try engine.allocator.create(Model);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = model_descriptor,
            .bind_group = bind_group,
            .skeletal_animation_data = skeletal_animation_data,
        };

        const loaded_model_id: LoadedModelId = @enumFromInt(Engine.next_loaded_model_id);
        try engine.models_hash.put(loaded_model_id, model);
        Engine.next_loaded_model_id += 1;

        return loaded_model_id;
    }

    pub const LoadTextureOptions = struct {
        forced_num_components: u32 = 4,
        generate_mipmaps: bool = false,
        format: ?wgpu.TextureFormat = null,
    };

    pub fn loadTexture(engine: *Engine, filename: []const u8, options: LoadTextureOptions) !types.TextureDescriptor {
        var imageData = try gltf_loader.StbiWrapper.loadTextureData(
            engine.allocator,
            filename,
            .{ .forced_num_components = options.forced_num_components },
        );
        defer imageData.deinit();

        return try load_texture.loadTextureIntoGpu(
            engine.gctx,
            engine.allocator,
            imageData,
            .{
                .generate_mipmaps = options.generate_mipmaps,
                .format = options.format,
            },
        );
    }

    pub const CreateTerrainHeightMapDescriptorParams = struct {
        layers: [2]types.TextureDescriptor,
        mixing_texture: types.TextureDescriptor,
        depth_map_texture: types.TextureDescriptor,
    };

    pub fn createTerrainHeightMapModel(
        engine: *const Engine,
        options: CreateTerrainHeightMapDescriptorParams,
    ) !*TerrainHeightMapModel {
        const terrain_height_map_model = try engine.allocator.create(TerrainHeightMapModel);
        errdefer engine.allocator.destroy(terrain_height_map_model);

        const terrain_height_map_bind_group = engine.bind_group_layouts.terrain_height_map.createBindGroup(
            engine.gctx,
            engine.texture_repeat_sampler,
            options.layers[0],
            options.depth_map_texture,
            options.mixing_texture,
            options.layers[1],
        );

        terrain_height_map_model.* = .{
            .bind_group = terrain_height_map_bind_group,
        };
        return terrain_height_map_model;
    }

    pub fn loadSkyBoxModel(engine: *Engine, texture_filename: []const u8) !*SkyBoxModel {
        const texture_full_filename = try std.fs.path.join(engine.allocator, &.{
            engine.content_dir,
            texture_filename,
        });
        defer engine.allocator.free(texture_full_filename);

        const skybox_descriptor = try SkyBoxDescriptor.init(
            engine.gctx,
            engine.allocator,
            texture_full_filename,
        );

        const bind_group = try engine.bind_group_layouts.regular.createBindGroup(
            engine.texture_sampler,
            skybox_descriptor.color_texture,
            engine.identity_joint_matrix_buffer.handle,
        );

        const model = try engine.allocator.create(SkyBoxModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = skybox_descriptor,
            .bind_group = bind_group,
        };

        return model;
    }

    pub fn loadSkyBoxCubemapModel(engine: *Engine, texture_filenames: [6][]const u8) !*SkyBoxCubemapModel {
        var texture_full_filenames: [6][]const u8 = undefined;

        for (0..6) |i| {
            texture_full_filenames[i] = try std.fs.path.join(engine.allocator, &.{
                engine.content_dir,
                texture_filenames[i],
            });
            errdefer {
                // free all previously allocated texture full filenames
                for (0..i - i) |j| {
                    engine.allocator.free(texture_full_filenames[j]);
                }
            }
        }
        defer {
            for (0..6) |i| {
                engine.allocator.free(texture_full_filenames[i]);
            }
        }

        const skybox_cubemap_descriptor = try SkyBoxCubemapDescriptor.init(
            engine.gctx,
            engine.allocator,
            texture_full_filenames,
        );

        const bind_group = try engine.bind_group_layouts.cubemap.createBindGroup(
            engine.texture_sampler,
            skybox_cubemap_descriptor.color_texture,
            engine.identity_joint_matrix_buffer.handle,
        );

        const model = try engine.allocator.create(SkyBoxCubemapModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = skybox_cubemap_descriptor,
            .bind_group = bind_group,
        };

        return model;
    }

    pub fn loadCubeWireframeModel(engine: *Engine) !*CubeWireframeModel {
        const cube_wireframe_descriptor = try CubeWireframeDescriptor.init(
            engine.gctx,
        );

        const model = try engine.allocator.create(CubeWireframeModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = cube_wireframe_descriptor,
            .bind_group = engine.bind_group_lines,
        };

        return model;
    }

    pub fn loadWindowBoxModel(engine: *Engine, texture_filename: []const u8) !*WindowBoxModel {
        const texture_full_filename = try std.fs.path.join(engine.allocator, &.{
            engine.content_dir,
            texture_filename,
        });
        defer engine.allocator.free(texture_full_filename);

        const window_box_descriptor = try WindowBoxDescriptor.init(
            engine.gctx,
            engine.allocator,
            texture_full_filename,
        );

        const bind_group = engine.bind_group_layouts.regular.createBindGroup(
            engine.gctx,
            engine.texture_sampler,
            window_box_descriptor.color_texture,
            engine.identity_joint_matrix_buffer.handle,
        );

        const model = try engine.allocator.create(WindowBoxModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = window_box_descriptor,
            .bind_group = bind_group,
        };

        return model;
    }

    pub fn loadPrimitive(engine: *Engine, positions: GeometryData) !*PrimitiveModel {
        const primitive_descriptor = try PrimitiveDescriptor.init(engine.gctx, positions);

        const bind_group = engine.bind_group_layouts.primitive_colorized.createBindGroup(engine.gctx);

        const model = try engine.allocator.create(PrimitiveModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = primitive_descriptor,
            .bind_group = bind_group,
        };

        return model;
    }

    fn recreateDepthTexture(engine: *Engine) !void {
        // Release old depth texture.
        engine.depth_texture.deinit(engine.gctx);
        // Create a new depth texture to match the new window size.
        engine.depth_texture = try DepthTexture.init(
            engine.gctx,
            engine.gctx.swapchain_descriptor.width,
            engine.gctx.swapchain_descriptor.height,
        );
    }

    pub fn runLoop(engine: *Engine) !void {
        if (engine.active_scene) |scene| {
            try scene.prepareForRendering();
        }

        const window = engine.window_context.window;

        while (true) {
            zglfw.pollEvents();

            if (window.shouldClose() or engine.input_controller.isKeyPressed(.escape)) {
                break;
            }

            // slowOperation();

            try engine.update();
            const gctx_state = engine.draw();

            switch (gctx_state) {
                .normal_execution => {},
                .swap_chain_resized => {
                    engine.aspect_ratio = getAspectRatio(engine.gctx);
                    try engine.recreateDepthTexture();
                },
            }

            engine.input_controller.flushQueue();
            // return;
        }
    }
};

fn slowOperation() void {
    const end = std.time.milliTimestamp() + 500;
    while (std.time.milliTimestamp() < end) {
        // noop
    }
}

fn getAspectRatio(gctx: *const zgpu.GraphicsContext) f32 {
    return @as(f32, @floatFromInt(gctx.swapchain_descriptor.width)) /
        @as(f32, @floatFromInt(gctx.swapchain_descriptor.height));
}

fn getLightClipMatrixArray(gctx: *zgpu.GraphicsContext, light: *const DirectionalLight, model_to_world: zmath.Mat) struct { slice: []zmath.Mat, offset: u32 } {
    const uniform = gctx.uniformsAllocate(zmath.Mat, 3);

    for (&light.cascades, 0..) |*cascade, i| {
        const object_to_light_clip = zmath.mul(
            model_to_world,
            cascade.world_to_clip,
        );
        uniform.slice[i] = zmath.transpose(object_to_light_clip);
    }

    // Have to recreated the struct even though uniform and resulting struct
    // have the same underlaying types.
    // Zig can't understand that they are the same and will complain about it.
    return .{ .slice = uniform.slice, .offset = uniform.offset };
}

fn getTerrainHeightMapElementsCountForSide(side: u32) u32 {
    return (side * 2 + 4) * side;
}
