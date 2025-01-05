const std = @import("std");
const math = std.math;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");
const zmath = @import("zmath");
const zstbi = @import("zstbi");
const gltf_loader = @import("gltf_loader");

const wgsl_vs = @embedFile("../shaders/vs.wgsl");
const wgsl_fs = @embedFile("../shaders/fs.wgsl");

const types = @import("./types.zig");
const BufferDescriptor = types.BufferDescriptor;
const WindowContext = @import("./glue.zig").WindowContext;
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
    init_time: f64,
    time: f64,

    pipeline: zgpu.RenderPipelineHandle,
    bind_group_def: BindGroupDefinition,
    depth_texture: DepthTexture,
    texture_sampler: zgpu.SamplerHandle,

    models_hash: std.AutoHashMap(LoadedModelId, *Model),

    active_scene: ?*Scene,
    input_controller: *InputController,

    pub fn init(
        allocator: std.mem.Allocator,
        window_context: WindowContext,
        callbacks: Callbacks,
    ) !*Engine {
        if (Engine.is_instanced) {
            return error.EngineCanHaveOnlyOneInstance;
        }

        zstbi.init(allocator);

        const gctx = window_context.gctx;
        const init_time = gctx.stats.time;

        const bind_group_def = BindGroupDefinition.init(gctx);

        const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_def.bind_group_layout});
        defer gctx.releaseResource(pipeline_layout);

        const pipeline = pipeline: {
            const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
            defer vs_module.release();

            const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
            defer fs_module.release();

            const color_targets = [_]wgpu.ColorTargetState{.{
                .format = zgpu.GraphicsContext.swapchain_format,
            }};

            const vertex_buffers = [_]wgpu.VertexBufferLayout{
                // position
                .{
                    .array_stride = @sizeOf([3]f32),
                    .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 0 }},
                    .attribute_count = 1,
                },
                // normal
                .{
                    .array_stride = @sizeOf([3]f32),
                    .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 1 }},
                    .attribute_count = 1,
                },
                // texcoord
                .{
                    .array_stride = @sizeOf([2]f32),
                    .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 2 }},
                    .attribute_count = 1,
                },
            };

            const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
                .primitive = wgpu.PrimitiveState{
                    .front_face = .cw,
                    .cull_mode = .back,
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
            break :pipeline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
        };

        const texture_sampler = gctx.createSampler(.{});

        const depth_texture = try DepthTexture.init(gctx);
        errdefer depth_texture.deinit();

        const input_controller = try InputController.init(allocator, window_context.window);
        input_controller.listenWindowEvents();
        errdefer input_controller.deinit();

        const engine = try allocator.create(Engine);
        engine.* = .{
            .allocator = allocator,
            .window_context = window_context,
            .callbacks = callbacks,
            .init_time = init_time,
            .time = 0,
            .gctx = gctx,
            .pipeline = pipeline,
            .bind_group_def = bind_group_def,
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
        engine.bind_group_def.deinit();
        engine.input_controller.deinit();

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

            pass: {
                const pipeline = gctx.lookupResource(engine.pipeline) orelse break :pass;

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

                pass.setPipeline(pipeline);

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

        const model_descriptor = try ModelDescriptor.init(gctx, engine.allocator, model_name);

        const bind_group_descriptor = try engine.bind_group_def.createBindGroup(
            engine.texture_sampler,
            model_descriptor.color_texture,
        );

        const model = try engine.allocator.create(Model);
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
