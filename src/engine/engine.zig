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
const Pipelines = @import("./pipelines.zig").Pipelines;
const COLOR_OUTPUT_FORMAT = @import("./pipelines/_first_pass_color_targets.zig").COLOR_OUTPUT_FORMAT;
const NORMAL_OUTPUT_FORMAT = @import("./pipelines/_first_pass_color_targets.zig").NORMAL_OUTPUT_FORMAT;
const SSAO_OUTPUT_FORMAT = @import("./pipelines/_first_pass_color_targets.zig").SSAO_OUTPUT_FORMAT;
// -- bind groups --
const BindGroupLayouts = @import("./bind_group_layouts.zig").BindGroupLayouts;
const BindGroup = @import("./bind_group.zig").BindGroup;
// -- textures --
const DepthTexture = @import("./textures/depth_texture.zig").DepthTexture;
const ShadowMapTexture = @import("./textures/shadow_map_texture.zig").ShadowMapTexture;
const ScreenTexture = @import("./textures/screen_texture.zig").ScreenTexture;
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
const InstanceBufferEntry = @import("./scene.zig").InstanceBufferEntry;
const Camera = @import("./camera.zig").Camera;
const InputController = @import("./input_controller.zig").InputController;
const KeyParams = @import("./input_controller.zig").KeyParams;
const GameObject = @import("./game_object.zig").GameObject;
const xRotate = @import("./game_object.zig").xRotate;
const DirectionalLight = @import("./light.zig").DirectionalLight;
const DirectionalLightCascade = @import("./light.zig").DirectionalLightCascade;
const SceneShaderRuntimeSettings = @import("./bind_group_layouts/scene.zig").SceneShaderRuntimeSettings;
const PostEffectShaderRuntimeSettings = @import("./bind_group_layouts/final_pass.zig").PostEffectShaderRuntimeSettings;

const DEBUG_INTERNAL_TEXTURE = false;
const DEBUG_SHOW_WIREFRAME_OBJECTS = false;

const GraphicsContextState = @typeInfo(@TypeOf(zgpu.GraphicsContext.present)).@"fn".return_type.?;

const billboard_normalization_matrix = utils.matMul(
    zmath.matFromQuat(
        zmath.quatFromNormAxisAngle(.{ 0, 0, 1, 1 }, 1 * math.pi),
    ),
    zmath.matFromQuat(
        zmath.quatFromNormAxisAngle(.{ 1, 0, 0, 1 }, 0.5 * math.pi),
    ),
);

const EngineState = struct {
    ssao_enabled: bool = true,
    debug_ssao_enabled: bool = false,
};

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

    state: EngineState = .{},

    // ---
    pipelines: Pipelines,
    bind_group_layouts: BindGroupLayouts,

    // ---
    bind_group_debug_shadow_map_texture: BindGroup,
    bind_group_shadow_map: BindGroup,
    bind_group_lines: BindGroup,
    bind_group_ssao_pass: BindGroup,
    bind_group_final_pass: BindGroup,

    models_hash: std.AutoHashMap(LoadedModelId, *Model),

    // -- textures --
    depth_texture: DepthTexture,
    shadow_map_texture: ShadowMapTexture,
    shadow_map_depth_texture: DepthTexture,
    first_pass_color_output_texture: ScreenTexture,
    first_pass_normal_output_texture: ScreenTexture,
    ssao_output_texture: ScreenTexture,

    // -- special textures (mostly for debug purposes) --
    uv_test_texture: types.TextureDescriptor,

    // -- samplers --
    texture_sampler: zgpu.SamplerHandle,
    texture_repeat_sampler: zgpu.SamplerHandle,
    texture_mirror_sampler: zgpu.SamplerHandle,

    identity_joint_matrix_buffer: SkeletalAnimation.JointMatrixBuffer,

    active_scene: ?*Scene,
    input_controller: *InputController(Engine),

    frame_stats: struct {
        game_objects_drawn_count: u32 = 0,
        shadow_map_pass_time_taken: f32 = 0,
        main_pass_time_taken: f32 = 0,

        // ---
        active_space_nodes_count: u32 = 0,
        find_objects_sub_invocations_count: u32 = 0,
        instances_written_count: u32 = 0,
    } = .{},

    // -- built-in models --
    cube_wireframe_model: *CubeWireframeModel,

    // -- temporary buffers --
    temp_buffers: struct {
        visible_objects_lists: std.ArrayList(*GameObject) = undefined,
        visible_objects_lists_chunks: std.ArrayList(u16) = undefined,
        visible_objects_current_chunk_index: u16 = 0,
        visible_objects_current_offset: usize = 0,

        regular_objects: std.ArrayList(*GameObject) = undefined,
        skinned_objects: std.ArrayList(*GameObject) = undefined,
        wireframe_objects: std.ArrayList(*GameObject) = undefined,
        rest_objects: std.ArrayList(*GameObject) = undefined,

        fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .visible_objects_lists = std.ArrayList(*GameObject).initCapacity(allocator, 4096) catch @panic("Failed to initialize visible objects lists buffer"),
                .visible_objects_lists_chunks = std.ArrayList(u16).initCapacity(allocator, 128) catch @panic("Failed to initialize visible objects lists chunks buffer"),

                .regular_objects = std.ArrayList(*GameObject).initCapacity(allocator, 1024) catch @panic("Failed to initialize regular objects buffer"),
                .skinned_objects = std.ArrayList(*GameObject).initCapacity(allocator, 1024) catch @panic("Failed to initialize skinned objects buffer"),
                .wireframe_objects = std.ArrayList(*GameObject).initCapacity(allocator, 1024) catch @panic("Failed to initialize wireframe objects buffer"),
                .rest_objects = std.ArrayList(*GameObject).initCapacity(allocator, 1024) catch @panic("Failed to initialize rest objects buffer"),
            };
        }

        fn deinit(buffers: *@This(), allocator: std.mem.Allocator) void {
            buffers.visible_objects_lists.deinit(allocator);
            buffers.visible_objects_lists_chunks.deinit(allocator);

            buffers.regular_objects.deinit(allocator);
            buffers.skinned_objects.deinit(allocator);
            buffers.wireframe_objects.deinit(allocator);
            buffers.rest_objects.deinit(allocator);
        }

        fn resetVisibleObjectsLists(buffers: *@This()) void {
            buffers.visible_objects_lists.clearRetainingCapacity();
            buffers.visible_objects_lists_chunks.clearRetainingCapacity();
            buffers.visible_objects_current_chunk_index = 0;
            buffers.visible_objects_current_offset = 0;
        }

        fn resetDrawingLists(buffers: *@This()) void {
            buffers.regular_objects.clearRetainingCapacity();
            buffers.skinned_objects.clearRetainingCapacity();
            buffers.wireframe_objects.clearRetainingCapacity();
            buffers.rest_objects.clearRetainingCapacity();
        }

        fn writeVisibleObjectsList(buffers: *@This(), visible_objects: []const *GameObject) void {
            buffers.visible_objects_lists_chunks.appendAssumeCapacity(@intCast(visible_objects.len));
            const slice = buffers.visible_objects_lists.addManyAsSliceAssumeCapacity(visible_objects.len);
            @memcpy(slice, visible_objects);
        }

        fn getNextVisibleObjectsChunk(buffers: *@This()) []const *GameObject {
            const size = buffers.visible_objects_lists_chunks.items[buffers.visible_objects_current_chunk_index];
            const items = buffers.visible_objects_lists.items[buffers.visible_objects_current_offset .. buffers.visible_objects_current_offset + size];
            buffers.visible_objects_current_chunk_index += 1;
            buffers.visible_objects_current_offset += size;
            return items;
        }
    },

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        window_context: WindowContext,
        content_dir: []const u8,
        callbacks: Callbacks,
    ) *Engine {
        if (Engine.is_instanced) {
            @panic("Engine is already initialized");
        }

        zstbi.init(io, allocator);

        const gctx = window_context.gctx;
        const init_time = gctx.stats.time;

        // -- textures --
        const w = gctx.swapchain_descriptor.width;
        const h = gctx.swapchain_descriptor.height;

        const depth_texture = DepthTexture.init(gctx, w, h);
        const first_pass_color_output_texture = ScreenTexture.init(gctx, w, h, COLOR_OUTPUT_FORMAT);
        const first_pass_normal_output_texture = ScreenTexture.init(gctx, w, h, NORMAL_OUTPUT_FORMAT);
        const ssao_output_texture = ScreenTexture.init(gctx, w, h, SSAO_OUTPUT_FORMAT);
        const shadow_map_texture = ShadowMapTexture.init(gctx, .{ .layers_count = 3 });
        const shadow_map_depth_texture = DepthTexture.init(gctx, 1024, 1024);

        // -- samplers --
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
        // bind group layouts
        // ---
        const bind_group_layouts = BindGroupLayouts.init(gctx);

        // ---
        // bind groups
        // ---
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

        const bind_group_ssao_pass = bind_group_layouts.ssao_pass.createBindGroup(
            gctx,
            texture_sampler,
            depth_texture.view_handle,
            // first_pass_color_output_texture.view_handle,
            first_pass_normal_output_texture.view_handle,
        );

        const bind_group_final_pass = bind_group_layouts.final_pass.createBindGroup(
            gctx,
            texture_sampler,
            depth_texture.view_handle,
            first_pass_color_output_texture.view_handle,
            first_pass_normal_output_texture.view_handle,
            ssao_output_texture.view_handle,
        );

        // ---
        // pipelines
        // ---
        const pipelines = Pipelines.init(gctx, &bind_group_layouts);

        const engine = allocator.create(Engine) catch @panic("Failed to create engine");

        const input_controller = InputController(Engine).init(allocator, window_context.window, .{
            .context = engine,
            .on_key_press = onKeyPress,
        }) catch @panic("InputController can't be initialized");
        input_controller.listenWindowEvents();

        const content_dir_copied = allocator.dupe(u8, content_dir) catch @panic("Can't dupe");

        var uv_test_image = gltf_loader.StbiWrapper.loadTextureData(
            allocator,
            "content/uv-test.png",
            .{},
        ) catch @panic("uv-test texture can't be loaded");
        defer uv_test_image.deinit();

        const uv_test_texture = load_texture.loadTextureIntoGpu(
            gctx,
            allocator,
            uv_test_image,
            .{ .generate_mipmaps = false }, // TODO: set true, maybe???
        ) catch @panic("uv-test texture can't be loaded");

        const identity_joint_matrix_buffer = SkeletalAnimation.createIdentityJointMatrixBuffer(gctx) catch @panic("SkeletalAnimation buffer can't be created");

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
            .pipelines = pipelines,
            .bind_group_layouts = bind_group_layouts,

            .bind_group_shadow_map = bind_group_shadow_map,
            .bind_group_debug_shadow_map_texture = bind_group_debug_shadow_map_texture,
            .bind_group_lines = bind_group_lines,
            .bind_group_ssao_pass = bind_group_ssao_pass,
            .bind_group_final_pass = bind_group_final_pass,

            // -- textures --
            .depth_texture = depth_texture,
            .first_pass_color_output_texture = first_pass_color_output_texture,
            .first_pass_normal_output_texture = first_pass_normal_output_texture,
            .ssao_output_texture = ssao_output_texture,
            .shadow_map_texture = shadow_map_texture,
            .shadow_map_depth_texture = shadow_map_depth_texture,
            .uv_test_texture = uv_test_texture,

            // -- samplers --
            .texture_sampler = texture_sampler,
            .texture_repeat_sampler = texture_repeat_sampler,
            .texture_mirror_sampler = texture_mirror_sampler,

            // rest
            .models_hash = std.AutoHashMap(LoadedModelId, *Model).init(allocator),

            .identity_joint_matrix_buffer = identity_joint_matrix_buffer,

            .active_scene = null,
            .input_controller = input_controller,

            // built-in models
            .cube_wireframe_model = undefined,

            .temp_buffers = .init(allocator),
        };

        engine.cube_wireframe_model = engine.loadCubeWireframeModel() catch @panic("Wireframe model can't be loaded");

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
        engine.pipelines.deinit(engine.gctx);

        zstbi.deinit();
        engine.allocator.destroy(engine);
        Engine.is_instanced = false;
    }

    fn onKeyPress(engine: *Engine, key_params: KeyParams) void {
        switch (key_params.key) {
            .e => {
                if (engine.state.debug_ssao_enabled) {
                    engine.state.ssao_enabled = true;
                    engine.state.debug_ssao_enabled = false;
                } else {
                    engine.state.ssao_enabled = !engine.state.ssao_enabled;
                }
                std.debug.print("SSAO = {}\n", .{engine.state.ssao_enabled});
            },
            .r => {
                if (!engine.state.debug_ssao_enabled) {
                    engine.state.ssao_enabled = true;
                    engine.state.debug_ssao_enabled = true;
                } else {
                    engine.state.debug_ssao_enabled = false;
                }
                std.debug.print("Debug SSAO = {}\n", .{engine.state.debug_ssao_enabled});
            },
            else => {},
        }
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
        var outdate_instances_range: struct {
            min: u32 = std.math.maxInt(u32),
            max: u32 = 0,

            fn update(self: *@This(), scene: *Scene, game_object: *const GameObject) void {
                if (game_object.instance_index) |instance_index| {
                    if (scene.instance_buffer.outdated_indices.isSet(instance_index)) {
                        scene.instance_buffer.outdated_indices.unset(instance_index);

                        self.min = @min(self.min, instance_index);
                        self.max = @max(self.max, instance_index);

                        scene.instance_buffer.buffer[instance_index] = .{
                            .model_matrix = game_object.getModelMatrix(),
                        };
                    }
                }
            }
        } = .{};

        engine.temp_buffers.resetVisibleObjectsLists();

        if (engine.active_scene) |scene| {
            for (scene.lights.items) |light| {
                for (&light.cascades) |*cascade| {
                    light.applyCameraFrustum(cascade, scene.camera);

                    const cascade_view_bound_box = cascade.getLightViewBoundBox();
                    const visible_objects = scene.space_tree.getObjectsInBoundBox(
                        cascade_view_bound_box,
                    );

                    for (visible_objects) |game_object| {
                        outdate_instances_range.update(scene, game_object);
                    }

                    engine.temp_buffers.writeVisibleObjectsList(visible_objects);
                }
            }

            const camera_view_bound_box = scene.camera.getCameraViewBoundBox();
            const visible_objects = scene.space_tree.getObjectsInBoundBox(
                camera_view_bound_box,
            );

            for (visible_objects) |game_object| {
                outdate_instances_range.update(scene, game_object);
            }

            engine.temp_buffers.writeVisibleObjectsList(visible_objects);

            // Instance buffer update (if needed)

            if (outdate_instances_range.min <= outdate_instances_range.max) {
                scene.engine.gctx.queue.writeBuffer(
                    scene.instance_buffer.gpu_buffer,
                    outdate_instances_range.min * @sizeOf(InstanceBufferEntry),
                    InstanceBufferEntry,
                    scene.instance_buffer.buffer[outdate_instances_range.min .. outdate_instances_range.max + 1],
                );

                engine.frame_stats.instances_written_count = outdate_instances_range.max - outdate_instances_range.min + 1;
            }
        }

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

                            const potentially_visible_game_objects = engine.temp_buffers.getNextVisibleObjectsChunk();

                            const clip_from_world_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                            clip_from_world_uniform.slice[0] = cascade.clip_from_world;

                            const settings_uniform = engine.gctx.uniformsAllocate(SceneShaderRuntimeSettings, 1);
                            settings_uniform.slice[0] = .{
                                .ssao_enabled = engine.state.ssao_enabled,
                            };

                            shadow_map_pass.setBindGroup(0, scene.scene_bind_group.wgpu_bind_group, &.{
                                clip_from_world_uniform.offset,
                                clip_from_world_uniform.offset, // Is it okay to use the same buffer for both uniforms?
                                settings_uniform.offset,
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

                            engine.temp_buffers.resetDrawingLists();
                        }
                    }
                }
            }

            // forward rendering pass
            {
                const color_attachments = [_]wgpu.RenderPassColorAttachment{
                    .{
                        .view = engine.first_pass_color_output_texture.view,
                        .load_op = .clear,
                        .store_op = .store,
                    },
                    .{
                        .view = engine.first_pass_normal_output_texture.view,
                        .load_op = .clear,
                        .store_op = .store,
                    },
                };
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
                    const timer = std.Io.Timestamp.now(engine.io, .awake);

                    // debug start
                    const stats = scene.space_tree.getLastGetObjectsInBoundBoxStats();
                    engine.frame_stats.active_space_nodes_count = stats.active_space_nodes_count;
                    engine.frame_stats.find_objects_sub_invocations_count = stats.invocations_count;
                    // debug end

                    const clip_from_world_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                    clip_from_world_uniform.slice[0] = scene.camera.clip_from_world;
                    const view_from_world_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                    view_from_world_uniform.slice[0] = scene.camera.view_from_world;
                    const settings_uniform = engine.gctx.uniformsAllocate(SceneShaderRuntimeSettings, 1);
                    settings_uniform.slice[0] = .{
                        .ssao_enabled = engine.state.ssao_enabled,
                    };

                    pass.setBindGroup(0, scene.scene_bind_group.wgpu_bind_group, &.{
                        clip_from_world_uniform.offset,
                        view_from_world_uniform.offset,
                        settings_uniform.offset,
                    });

                    // TODO: WHY IT DOES NOT WORK HERE, BUT WORKS IF IN SPACE TREE?
                    if (scene.skybox_object) |skybox_object| {
                        engine.drawGameObject(pass, scene, skybox_object);
                    }

                    const potentially_visible_game_objects_for_camera = engine.temp_buffers.getNextVisibleObjectsChunk();

                    // _ = potentially_visible_game_objects_for_camera;
                    // for (scene.game_objects.items) |game_object| {
                    for (potentially_visible_game_objects_for_camera) |game_object| {
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

                    engine.temp_buffers.resetDrawingLists();

                    engine.frame_stats.game_objects_drawn_count += @intCast(potentially_visible_game_objects_for_camera.len);

                    const duration = timer.untilNow(engine.io, .awake);
                    engine.frame_stats.main_pass_time_taken = @as(f32, @floatFromInt(duration.nanoseconds)) * 0.000001;

                    if (DEBUG_INTERNAL_TEXTURE) {
                        engine.drawTextureDebugScreen(pass);
                    }
                }
            }

            // SSAO pass
            {
                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = engine.ssao_output_texture.view,
                    .load_op = .clear,
                    .store_op = .store,
                }};
                const render_pass_info = wgpu.RenderPassDescriptor{
                    .color_attachments = &color_attachments,
                    .color_attachment_count = color_attachments.len,
                    .depth_stencil_attachment = null,
                };
                const pass = encoder.beginRenderPass(render_pass_info);
                defer {
                    pass.end();
                    pass.release();
                }

                // TODO: remove duplication with the final pass:
                const clip_from_view_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                const view_from_clip_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                const shader_run_time_settings_uniform = engine.gctx.uniformsAllocate(PostEffectShaderRuntimeSettings, 1);
                shader_run_time_settings_uniform.slice[0] = .{
                    .ssao_enabled = engine.state.ssao_enabled,
                    .debug_ssao_enabled = engine.state.debug_ssao_enabled,
                };

                if (engine.active_scene) |scene| {
                    clip_from_view_uniform.slice[0] = scene.camera.clip_from_view;
                    view_from_clip_uniform.slice[0] = scene.camera.view_from_clip;
                }

                // render
                pass.setPipeline(engine.pipelines.ssao_pipeline.pipeline_gpu);
                pass.setBindGroup(0, engine.bind_group_ssao_pass.wgpu_bind_group, &.{
                    clip_from_view_uniform.offset,
                    view_from_clip_uniform.offset,
                    shader_run_time_settings_uniform.offset,
                });
                pass.draw(6, 1, 0, 0);
            }

            // render to screen pass (final)
            {
                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .clear,
                    .store_op = .store,
                }};
                // const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                //     .view = engine.depth_texture.view,
                //     .depth_load_op = .clear,
                //     .depth_store_op = .store,
                //     .depth_clear_value = 1.0,
                // };
                const render_pass_info = wgpu.RenderPassDescriptor{
                    .color_attachments = &color_attachments,
                    .color_attachment_count = color_attachments.len,
                    .depth_stencil_attachment = null,
                };
                const pass = encoder.beginRenderPass(render_pass_info);
                defer {
                    pass.end();
                    pass.release();
                }

                const clip_from_view_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                const view_from_clip_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
                const shader_run_time_settings_uniform = engine.gctx.uniformsAllocate(PostEffectShaderRuntimeSettings, 1);
                shader_run_time_settings_uniform.slice[0] = .{
                    .ssao_enabled = engine.state.ssao_enabled,
                    .debug_ssao_enabled = engine.state.debug_ssao_enabled,
                };

                if (engine.active_scene) |scene| {
                    clip_from_view_uniform.slice[0] = scene.camera.clip_from_view;
                    view_from_clip_uniform.slice[0] = scene.camera.view_from_clip;
                }

                // render
                pass.setPipeline(engine.pipelines.screen_quad_pipeline.pipeline_gpu);
                pass.setBindGroup(0, engine.bind_group_final_pass.wgpu_bind_group, &.{
                    clip_from_view_uniform.offset,
                    view_from_clip_uniform.offset,
                    shader_run_time_settings_uniform.offset,
                });
                pass.draw(6, 1, 0, 0);
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

        var world_from_model = game_object.aggregated_matrix;

        if (billboard_mode != .none) {
            const scale_vec = zmath.util.getScaleVec(game_object.aggregated_matrix);
            const position = game_object.aggregated_matrix[3];

            const billboard_rotation_matrix = if (billboard_mode == .spherical) utils.matMul(
                // inverse is needed because lookAtRh returns matrix which rotates world to camera,
                // but we need to rotate the object in the world space.
                zmath.inverse(
                    zmath.lookAtRh(
                        .{ 0, 0, 0, 1 },
                        zmath.loadArr3(scene.camera.position) - position,
                        .{ 0, 0, 1, 0 },
                    ),
                ),
                billboard_normalization_matrix,
            ) else cylindric_rotation_matrix: {
                const direction = zmath.loadArr3(scene.camera.position) - position;
                const angle = math.atan2(direction[1], direction[0]);

                break :cylindric_rotation_matrix zmath.matFromNormAxisAngle(
                    .{ 0, 0, 1, 1 },
                    angle + 0.5 * math.pi,
                );
            };

            world_from_model = utils.matMul(
                zmath.translationV(position),
                utils.matMul(
                    // instead of inner rotate, we apply billboard rotation matrix
                    billboard_rotation_matrix,
                    zmath.scalingV(scale_vec),
                ),
            );
        }

        const flip_yz = switch (game_object.model) {
            .regular_model => |model| model.model_descriptor.options.mesh_y_up,
            else => false,
        };
        if (flip_yz) {
            // NOTE: converting from Y-up to Z-up coordinate system,
            // should be done only for models which is made with Y-up logic.
            world_from_model = utils.matMul(world_from_model, xRotate);
        }

        var clip_from_object = utils.matMul(scene.camera.clip_from_world, world_from_model);
        if (game_object.model == .skybox_model or game_object.model == .skybox_cubemap_model) {
            clip_from_object = utils.matMul(
                scene.camera.clip_from_view,
                scene.camera.view_from_camera,
            );
            if (game_object.model == .skybox_cubemap_model) {
                clip_from_object = utils.matMul(clip_from_object, xRotate);
            }
        }

        const clip_from_object_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
        clip_from_object_uniform.slice[0] = clip_from_object;

        // TODO: support multiple lights
        const light_clip_from_object_array_uniform = getLightClipMatrixArray(
            engine.gctx,
            scene.lights.items[0],
            world_from_model,
        );

        const camera_position_in_model_space_uniform = engine.gctx.uniformsAllocate(zmath.Vec, 1);

        switch (game_object.model) {
            .regular_model => |model| {
                pass.setBindGroup(1, model.bind_group.wgpu_bind_group, &.{});

                pass.setBindGroup(2, engine.bind_group_shadow_map.wgpu_bind_group, &.{
                    light_clip_from_object_array_uniform.offset,
                });

                if (game_object.joints_bind_group) |joints_bind_group| {
                    pass.setBindGroup(3, joints_bind_group.wgpu_bind_group, &.{});
                }

                pass.drawIndexed(model.model_descriptor.index.elements_count, 1, 0, 0, game_object.instance_index orelse 0);
            },
            .terrain_height_map_model => |model| {
                const time_uniform = engine.gctx.uniformsAllocate(u32, 1);
                time_uniform.slice[0] = @intFromFloat(engine.time * 1000);

                pass.setBindGroup(0, model.bind_group.wgpu_bind_group, &.{
                    clip_from_object_uniform.offset,
                    time_uniform.offset,
                });
                pass.setBindGroup(1, engine.bind_group_shadow_map.wgpu_bind_group, &.{
                    light_clip_from_object_array_uniform.offset,
                });

                // TODO: make customizable
                pass.draw(getTerrainHeightMapElementsCountForSide(64), 1, 0, 0);
            },
            .window_box_model => |window_box_model| {
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
                const model_from_world = zmath.inverse(world_from_model);
                const camera_position_in_model_space = utils.matApply(
                    model_from_world,
                    camera_position,
                );

                camera_position_in_model_space_uniform.slice[0] = camera_position_in_model_space;

                pass.setBindGroup(0, window_box_model.bind_group.wgpu_bind_group, &.{
                    clip_from_object_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                const elements_count = window_box_model.model_descriptor.position.elements_count;

                pass.draw(elements_count, 1, 0, 0);
            },
            .skybox_model => |skybox_model| {
                pass.setBindGroup(1, skybox_model.bind_group.wgpu_bind_group, &.{
                    clip_from_object_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                pass.drawIndexed(skybox_model.model_descriptor.index.elements_count, 1, 0, 0, 0);
            },
            .skybox_cubemap_model => |skybox_cubemap_model| {
                pass.setBindGroup(1, skybox_cubemap_model.bind_group.wgpu_bind_group, &.{
                    clip_from_object_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                pass.drawIndexed(skybox_cubemap_model.model_descriptor.index.elements_count, 1, 0, 0, 0);
            },
            .primitive_colorized => |primitive_colorized_model| {
                const solid_color_uniform = engine.gctx.uniformsAllocate(zmath.Vec, 1);
                solid_color_uniform.slice[0] = game_object.debug.color;

                pass.setBindGroup(0, primitive_colorized_model.bind_group.wgpu_bind_group, &.{
                    clip_from_object_uniform.offset,
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
        const bound_center = utils.matApply1(game_object.aggregated_matrix, bounds.offset);
        const scale = zmath.util.getScaleVec(game_object.aggregated_matrix);
        const radius = bounds.radius * scale[0];

        const world_from_model =
            utils.matMul(
                // Ignoring rotation since box should be always axis-aligned.
                zmath.translationV(bound_center),
                zmath.scaling(radius, radius, radius),
            );

        const clip_from_object = utils.matMul(scene.camera.clip_from_world, world_from_model);
        const clip_from_object_uniform = engine.gctx.uniformsAllocate(zmath.Mat, 1);
        clip_from_object_uniform.slice[0] = clip_from_object;

        const color_uniform = engine.gctx.uniformsAllocate(zmath.Vec, 1);
        color_uniform.slice[0] = .{ 0.0, 1.0, 0.0, 1.0 };

        pass.setBindGroup(0, engine.bind_group_lines.wgpu_bind_group, &.{
            clip_from_object_uniform.offset,
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
        _ = cascade;
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

                if (game_object.joints_bind_group) |joints_bind_group| {
                    pass.setBindGroup(1, joints_bind_group.wgpu_bind_group, &.{});
                }
                pass.drawIndexed(model.model_descriptor.index.elements_count, 1, 0, 0, game_object.instance_index orelse 0);
            },
            .terrain_height_map_model => {
                // nothing to do
                // TODO: can't be rendered because shadow map relies on vertex data
                // pass.draw(getTerrainHeightMapElementsCountForSide(64), 1, 0, 0);
                return;
            },
            .window_box_model => |window_box_model| {
                const model_descriptor = window_box_model.model_descriptor;
                model_descriptor.position.applyVertexBuffer(pass, 0);
                pass.draw(window_box_model.model_descriptor.position.elements_count, 1, 0, game_object.instance_index orelse 0);
            },
            .primitive_colorized => |primitive_colorized_model| {
                const model_descriptor = primitive_colorized_model.model_descriptor;
                model_descriptor.position.applyVertexBuffer(pass, 0);
                pass.draw(primitive_colorized_model.model_descriptor.position.elements_count, 1, 0, game_object.instance_index orelse 0);
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

        const bind_group = engine.bind_group_layouts.cubemap.createBindGroup(
            engine.gctx,
            engine.texture_sampler,
            skybox_cubemap_descriptor.color_texture,
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

    fn recreateScreenDependantTextures(engine: *Engine) void {
        const gctx = engine.gctx;

        // Cleanup old textures
        engine.depth_texture.deinit(gctx);
        engine.first_pass_color_output_texture.deinit(gctx);
        engine.first_pass_normal_output_texture.deinit(gctx);
        engine.ssao_output_texture.deinit(gctx);
        // Re-create textures
        const w = gctx.swapchain_descriptor.width;
        const h = gctx.swapchain_descriptor.height;

        engine.depth_texture = .init(gctx, w, h);
        engine.first_pass_color_output_texture = .init(gctx, w, h, COLOR_OUTPUT_FORMAT);
        engine.first_pass_normal_output_texture = .init(gctx, w, h, NORMAL_OUTPUT_FORMAT);
        engine.ssao_output_texture = .init(gctx, w, h, SSAO_OUTPUT_FORMAT);
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
                    engine.recreateScreenDependantTextures();
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

fn getLightClipMatrixArray(gctx: *zgpu.GraphicsContext, light: *const DirectionalLight, world_from_model: zmath.Mat) struct { slice: []zmath.Mat, offset: u32 } {
    const uniform = gctx.uniformsAllocate(zmath.Mat, 3);

    for (&light.cascades, 0..) |*cascade, i| {
        const light_clip_from_object = utils.matMul(
            cascade.clip_from_world,
            world_from_model,
        );
        uniform.slice[i] = light_clip_from_object;
    }

    // Have to recreated the struct even though uniform and resulting struct
    // have the same underlaying types.
    // Zig can't understand that they are the same and will complain about it.
    return .{ .slice = uniform.slice, .offset = uniform.offset };
}

fn getTerrainHeightMapElementsCountForSide(side: u32) u32 {
    return (side * 2 + 4) * side;
}
