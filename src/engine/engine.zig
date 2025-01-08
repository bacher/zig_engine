const std = @import("std");
const math = std.math;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");
const zmath = @import("zmath");
const zstbi = @import("zstbi");
const gltf_loader = @import("gltf_loader");

const types = @import("./types.zig");
const BufferDescriptor = types.BufferDescriptor;
const WindowContext = @import("./glue.zig").WindowContext;
const Pipeline = @import("./pipeline.zig").Pipeline;
const basic_pipeline = @import("./pipelines/basic_pipeline.zig");
const BindGroupDefinition = @import("./bind_group.zig").BindGroupDefinition;
const DepthTexture = @import("./depth_texture.zig").DepthTexture;
const ModelDescriptor = @import("./model_descriptor.zig").ModelDescriptor;
const Model = @import("./model.zig").Model;
const Scene = @import("./scene.zig").Scene;
const Camera = @import("./camera.zig").Camera;
const InputController = @import("./input_controller.zig").InputController;

const GraphicsContextState = @typeInfo(@TypeOf(zgpu.GraphicsContext.present)).@"fn".return_type.?;

pub const Engine = struct {
    pub const LoadedModelId = enum(u32) { _ };

    var is_instanced: bool = false;
    var next_loaded_model_id: u32 = 0;

    const Callbacks = struct {
        onUpdate: ?*const fn (engine: *Engine) void,
        onRender: ?*const fn (engine: *Engine, pass: wgpu.RenderPassEncoder) void,
    };

    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    window_context: WindowContext,
    callbacks: Callbacks,
    content_dir: []const u8,
    init_time: f64,
    time: f64,

    pipeline: Pipeline,
    bind_group_definition: BindGroupDefinition,
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

        const bind_group_definition = BindGroupDefinition.init(gctx);

        const pipeline = try basic_pipeline.createBasicPipeline(
            gctx,
            bind_group_definition,
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
            .pipeline = pipeline,
            .bind_group_definition = bind_group_definition,
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

    pub fn update(engine: *Engine) void {
        engine.time = engine.gctx.stats.time - engine.init_time;

        engine.input_controller.updateMouseState();

        if (engine.active_scene) |scene| {
            const swapchain = engine.gctx.swapchain_descriptor;
            scene.camera.updateTargetScreenSize(
                swapchain.width,
                swapchain.height,
            );

            scene.update(engine.time);
        }

        if (engine.callbacks.onUpdate) |callback| {
            callback(engine);
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

                // TODO: choose pipeline depending on model type
                pass.setPipeline(engine.pipeline.pipeline_gpu);

                if (engine.active_scene) |scene| {
                    for (scene.game_objects.items) |game_object| {
                        const model = game_object.model;
                        const model_descriptor = model.model_descriptor;

                        model_descriptor.position.applyVertexBuffer(pass, 0);
                        model_descriptor.normal.applyVertexBuffer(pass, 1);
                        model_descriptor.texcoord.applyVertexBuffer(pass, 2);
                        model_descriptor.index.applyIndexBuffer(pass);

                        const world_position_mat = zmath.translation(
                            game_object.position[0],
                            game_object.position[1],
                            game_object.position[2],
                        );

                        const object_to_world =
                            zmath.mul(
                            // NOTE: converting from Y-up to Z-up coordinate system.
                            //       should be the opposite of "camera_to_normalized_view" from camera.zig.
                            zmath.rotationX(0.5 * math.pi),
                            zmath.mul(
                                zmath.rotationZ(@floatCast(engine.time)),
                                world_position_mat,
                            ),
                        );

                        // const object_to_world = world_position_mat;

                        const object_to_clip = zmath.mul(object_to_world, scene.camera.world_to_clip);

                        const mem = gctx.uniformsAllocate(zmath.Mat, 1);
                        mem.slice[0] = zmath.transpose(object_to_clip);

                        pass.setBindGroup(0, model.bind_group_descriptor.bind_group, &.{mem.offset});
                        pass.drawIndexed(model_descriptor.index.elements_count * 3, 1, 0, 0, 0);
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

                onRender(engine, pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});

        const gctx_state = gctx.present();

        return gctx_state;
    }

    pub fn loadModel(engine: *Engine, model_name: []const u8) !LoadedModelId {
        const gctx = engine.gctx;

        const model_filename = try std.fs.path.join(engine.allocator, &.{
            engine.content_dir,
            model_name,
        });
        defer engine.allocator.free(model_filename);

        const model_descriptor = try ModelDescriptor.init(gctx, engine.allocator, model_filename);

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

            engine.update();
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
