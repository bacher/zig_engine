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
const BufferDescriptor = types.BufferDescriptor;
const WindowContext = @import("./glue.zig").WindowContext;
const Pipeline = @import("./pipeline.zig").Pipeline;
const basic_pipeline_module = @import("./pipelines/basic_pipeline.zig");
const skybox_pipeline_module = @import("./pipelines/skybox_pipeline.zig");
const skybox_cubemap_pipeline_module = @import("./pipelines/skybox_cubemap_pipeline.zig");
const window_box_pipeline_module = @import("./pipelines/window_box_pipeline.zig");
const primitive_colorized_pipeline_module = @import("./pipelines/primitive_colorized_pipeline.zig");
const BindGroupDefinition = @import("./bind_group.zig").BindGroupDefinition;
const PrimitiveColorizedBindGroupDefinition = @import("./bind_group_primitive.zig").PrimitiveColorizedBindGroupDefinition;
const DepthTexture = @import("./depth_texture.zig").DepthTexture;
const ModelDescriptor = @import("./display_object_descriptors/model_descriptor.zig").ModelDescriptor;
const WindowBoxDescriptor = @import("./display_object_descriptors/window_box_descriptor.zig").WindowBoxDescriptor;
const SkyBoxDescriptor = @import("./display_object_descriptors/skybox_descriptor.zig").SkyBoxDescriptor;
const SkyBoxCubemapDescriptor = @import("./display_object_descriptors/skybox_cubemap_descriptor.zig").SkyBoxCubemapDescriptor;
const Model = @import("./model.zig").Model;
const SkyBoxModel = @import("./model.zig").SkyBoxModel;
const SkyBoxCubemapModel = @import("./model.zig").SkyBoxCubemapModel;
const WindowBoxModel = @import("./model.zig").WindowBoxModel;
const PrimitiveModel = @import("./model.zig").PrimitiveModel;
const PrimitiveDescriptor = @import("./display_object_descriptors/primitive_descriptor.zig").PrimitiveDescriptor;
const GeometryData = @import("./shape_generation/geometry_data.zig").GeometryData;
const Scene = @import("./scene.zig").Scene;
const Camera = @import("./camera.zig").Camera;
const InputController = @import("./input_controller.zig").InputController;
const GameObject = @import("./game_object.zig").GameObject;

const GraphicsContextState = @typeInfo(@TypeOf(zgpu.GraphicsContext.present)).@"fn".return_type.?;

const xRotate = zmath.rotationX(0.5 * math.pi);

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
    allocator: std.mem.Allocator,
    window_context: WindowContext,
    callbacks: Callbacks,
    content_dir: []const u8,
    init_time: f64,
    time: f64,

    pipelines: struct {
        basic: Pipeline,
        skybox: Pipeline,
        skybox_cubemap: Pipeline,
        window_box: Pipeline,
        primitive_colorized: Pipeline,
    },
    bind_group_definition: BindGroupDefinition,
    bind_group_cubemap_definition: BindGroupDefinition,
    bind_group_primitive_colorized_definition: PrimitiveColorizedBindGroupDefinition,
    depth_texture: DepthTexture,
    texture_sampler: zgpu.SamplerHandle,

    models_hash: std.AutoHashMap(LoadedModelId, *Model),

    active_scene: ?*Scene,
    input_controller: *InputController,

    pub fn init(
        allocator: std.mem.Allocator,
        window_context: WindowContext,
        content_dir: []const u8,
        callbacks: Callbacks,
    ) !*Engine {
        if (Engine.is_instanced) {
            return error.EngineCanHaveOnlyOneInstance;
        }

        zstbi.init(allocator);

        const gctx = window_context.gctx;
        const init_time = gctx.stats.time;

        const bind_group_definition = BindGroupDefinition.init(gctx, .tvdim_2d);
        const bind_group_cubemap_definition = BindGroupDefinition.init(gctx, .tvdim_cube);
        const bind_group_primitive_colorized_definition = PrimitiveColorizedBindGroupDefinition.init(gctx);

        const basic_pipeline = try basic_pipeline_module.createBasicPipeline(
            gctx,
            bind_group_definition,
        );
        const skybox_pipeline = try skybox_pipeline_module.createSkyboxPipeline(
            gctx,
            bind_group_definition,
        );
        const skybox_cubemap_pipeline = try skybox_cubemap_pipeline_module.createSkyboxCubemapPipeline(
            gctx,
            bind_group_cubemap_definition,
        );
        const window_box_pipeline = try window_box_pipeline_module.createWindowBoxPipeline(
            gctx,
            bind_group_definition,
        );
        const primitive_colorized_pipeline = try primitive_colorized_pipeline_module.createPrimitiveColorizedPipeline(
            gctx,
            bind_group_primitive_colorized_definition,
        );

        const texture_sampler = gctx.createSampler(.{});

        const depth_texture = try DepthTexture.init(gctx);
        errdefer depth_texture.deinit();

        const input_controller = try InputController.init(allocator, window_context.window);
        input_controller.listenWindowEvents();
        errdefer input_controller.deinit();

        const content_dir_copied = try allocator.dupe(u8, content_dir);
        errdefer allocator.free(content_dir_copied);

        const engine = try allocator.create(Engine);
        engine.* = .{
            .allocator = allocator,
            .window_context = window_context,
            .callbacks = callbacks,
            .content_dir = content_dir_copied,
            .init_time = init_time,
            .time = 0,
            .gctx = gctx,
            .pipelines = .{
                .basic = basic_pipeline,
                .skybox = skybox_pipeline,
                .skybox_cubemap = skybox_cubemap_pipeline,
                .window_box = window_box_pipeline,
                .primitive_colorized = primitive_colorized_pipeline,
            },
            .bind_group_definition = bind_group_definition,
            .bind_group_cubemap_definition = bind_group_cubemap_definition,
            .bind_group_primitive_colorized_definition = bind_group_primitive_colorized_definition,
            .depth_texture = depth_texture,
            .texture_sampler = texture_sampler,
            .models_hash = std.AutoHashMap(LoadedModelId, *Model).init(allocator),
            .active_scene = null,
            .input_controller = input_controller,
        };
        Engine.is_instanced = true;
        return engine;
    }

    pub fn deinit(engine: *Engine) void {
        var iterator = engine.models_hash.iterator();
        while (iterator.next()) |entry| {
            const model_ptr = entry.value_ptr.*;
            model_ptr.deinit(engine.gctx);
            engine.allocator.destroy(model_ptr);
        }

        engine.models_hash.deinit();
        engine.bind_group_definition.deinit();
        engine.input_controller.deinit();
        engine.allocator.free(engine.content_dir);

        zstbi.deinit();
        engine.allocator.destroy(engine);
        Engine.is_instanced = false;
    }

    pub fn createScene(engine: *Engine) !*Scene {
        const scene = try Scene.init(
            engine,
            engine.allocator,
            engine.gctx.swapchain_descriptor.width,
            engine.gctx.swapchain_descriptor.height,
        );

        if (engine.active_scene == null) {
            engine.active_scene = scene;
        }

        return scene;
    }

    pub fn update(engine: *Engine) !void {
        engine.time = engine.gctx.stats.time - engine.init_time;

        try engine.input_controller.updateMouseState();

        if (engine.active_scene) |scene| {
            const swapchain = engine.gctx.swapchain_descriptor;
            scene.camera.updateTargetScreenSize(
                swapchain.width,
                swapchain.height,
            );

            scene.update(engine.time);
        }

        if (engine.callbacks.onUpdate) |callback| {
            callback(engine, engine.callbacks.argument);
        }
    }

    pub fn draw(engine: *Engine) GraphicsContextState {
        const gctx = engine.gctx;

        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

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
                    for (scene.game_objects.items) |game_object| {
                        engine.drawGameObject(pass, scene, game_object);
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

    fn drawGameObject(engine: *Engine, pass: wgpu.RenderPassEncoder, scene: *const Scene, game_object: *const GameObject) void {
        switch (game_object.model) {
            .regular_model => |model| {
                pass.setPipeline(engine.pipelines.basic.pipeline_gpu);

                const model_descriptor = model.model_descriptor;

                model_descriptor.position.applyVertexBuffer(pass, 0);
                model_descriptor.normal.applyVertexBuffer(pass, 1);
                model_descriptor.texcoord.applyVertexBuffer(pass, 2);
                model_descriptor.index.applyIndexBuffer(pass);
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

        var model_to_world = zmath.mul(
            zmath.mul(
                zmath.quatToMat(game_object.rotation),
                zmath.scaling(game_object.scale, game_object.scale, game_object.scale),
            ),
            zmath.translation(
                game_object.position[0],
                game_object.position[1],
                game_object.position[2],
            ),
        );

        // Is it correct order?
        model_to_world = zmath.mul(
            game_object.aggregated_matrix,
            model_to_world,
        );

        var flip_yz = false;
        switch (game_object.model) {
            .regular_model => |model| {
                flip_yz = model.model_descriptor.mesh_y_up;
            },
            else => {},
        }
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
                pass.setBindGroup(0, model.bind_group_descriptor.bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                pass.drawIndexed(model.model_descriptor.index.elements_count, 1, 0, 0, 0);
            },
            .window_box_model => |window_box_model| {
                pass.setBindGroup(0, window_box_model.bind_group_descriptor.bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                const elements_count = window_box_model.model_descriptor.position.elements_count;

                pass.draw(elements_count, 1, 0, 0);
            },
            .skybox_model => |skybox_model| {
                pass.setBindGroup(0, skybox_model.bind_group_descriptor.bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                pass.drawIndexed(skybox_model.model_descriptor.index.elements_count, 1, 0, 0, 0);
            },
            .skybox_cubemap_model => |skybox_cubemap_model| {
                pass.setBindGroup(0, skybox_cubemap_model.bind_group_descriptor.bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                });

                pass.drawIndexed(skybox_cubemap_model.model_descriptor.index.elements_count, 1, 0, 0, 0);
            },
            .primitive_colorized => |primitive_colorized_model| {
                const solid_color_uniform = engine.gctx.uniformsAllocate(zmath.Vec, 1);
                solid_color_uniform.slice[0] = game_object.debug.color;

                pass.setBindGroup(0, primitive_colorized_model.bind_group_descriptor.bind_group, &.{
                    object_to_clip_uniform.offset,
                    camera_position_in_model_space_uniform.offset,
                    solid_color_uniform.offset,
                });

                const elements_count = primitive_colorized_model.model_descriptor.position.elements_count;

                pass.draw(elements_count, 1, 0, 0);
            },
        }
    }

    pub fn initLoader(engine: *Engine, model_name: []const u8) !gltf_loader.GltfLoader {
        const model_filename = try std.fs.path.join(engine.allocator, &.{
            engine.content_dir,
            model_name,
        });
        defer engine.allocator.free(model_filename);

        return try gltf_loader.GltfLoader.init(engine.allocator, model_filename);
    }

    pub fn loadModel(
        engine: *Engine,
        loader: *const gltf_loader.GltfLoader,
        object: *const gltf_loader.SceneObject,
    ) !LoadedModelId {
        const model_descriptor = try ModelDescriptor.init(
            engine.gctx,
            engine.allocator,
            loader,
            object,
        );

        const bind_group_descriptor = try engine.bind_group_definition.createBindGroup(
            engine.texture_sampler,
            model_descriptor.color_texture,
        );

        const model = try engine.allocator.create(Model);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = model_descriptor,
            .bind_group_descriptor = bind_group_descriptor,
        };

        const loaded_model_id: LoadedModelId = @enumFromInt(Engine.next_loaded_model_id);
        try engine.models_hash.put(loaded_model_id, model);
        Engine.next_loaded_model_id += 1;

        return loaded_model_id;
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

        const bind_group_descriptor = try engine.bind_group_definition.createBindGroup(
            engine.texture_sampler,
            skybox_descriptor.color_texture,
        );

        const model = try engine.allocator.create(SkyBoxModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = skybox_descriptor,
            .bind_group_descriptor = bind_group_descriptor,
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

        const bind_group_descriptor = try engine.bind_group_cubemap_definition.createBindGroup(
            engine.texture_sampler,
            skybox_cubemap_descriptor.color_texture,
        );

        const model = try engine.allocator.create(SkyBoxCubemapModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = skybox_cubemap_descriptor,
            .bind_group_descriptor = bind_group_descriptor,
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

        const bind_group_descriptor = try engine.bind_group_definition.createBindGroup(
            engine.texture_sampler,
            window_box_descriptor.color_texture,
        );

        const model = try engine.allocator.create(WindowBoxModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = window_box_descriptor,
            .bind_group_descriptor = bind_group_descriptor,
        };

        return model;
    }

    pub fn loadPrimitive(engine: *Engine, positions: GeometryData) !*PrimitiveModel {
        const primitive_descriptor = try PrimitiveDescriptor.init(engine.gctx, positions);

        const bind_group_descriptor = try engine.bind_group_primitive_colorized_definition.createBindGroup();

        const model = try engine.allocator.create(PrimitiveModel);
        errdefer engine.allocator.destroy(model);
        model.* = .{
            .model_descriptor = primitive_descriptor,
            .bind_group_descriptor = bind_group_descriptor,
        };

        return model;
    }

    fn recreateDepthTexture(engine: *Engine) !void {
        // Release old depth texture.
        engine.depth_texture.deinit();
        // Create a new depth texture to match the new window size.
        engine.depth_texture = try DepthTexture.init(engine.gctx);
    }

    pub fn runLoop(engine: *Engine) !void {
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
                    try engine.recreateDepthTexture();
                },
            }

            engine.input_controller.flushQueue();
        }
    }
};

fn slowOperation() void {
    const end = std.time.milliTimestamp() + 500;
    while (std.time.milliTimestamp() < end) {
        // noop
    }
}
