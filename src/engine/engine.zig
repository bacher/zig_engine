const std = @import("std");
const math = std.math;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");
const zmath = @import("zmath");

const wgsl_vs = @embedFile("../shaders/vs.wgsl");
const wgsl_fs = @embedFile("../shaders/fs.wgsl");

const Vertex = @import("./types.zig").Vertex;
const WindowContext = @import("./glue.zig").WindowContext;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    window_context: WindowContext,

    gctx: *zgpu.GraphicsContext,

    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,

    vertex_buffer: zgpu.BufferHandle,
    index_buffer: zgpu.BufferHandle,

    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,

    pub fn init(allocator: std.mem.Allocator, window_context: WindowContext) !*Engine {
        const gctx = window_context.gctx;

        // Create a bind group layout needed for our render pipeline.
        const bind_group_layout = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        });
        defer gctx.releaseResource(bind_group_layout);

        const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_layout});
        defer gctx.releaseResource(pipeline_layout);

        const pipeline = pipeline: {
            const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
            defer vs_module.release();

            const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
            defer fs_module.release();

            const color_targets = [_]wgpu.ColorTargetState{.{
                .format = zgpu.GraphicsContext.swapchain_format,
            }};

            const vertex_attributes = [_]wgpu.VertexAttribute{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x3, .offset = @offsetOf(Vertex, "color"), .shader_location = 1 },
            };
            const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
                .array_stride = @sizeOf(Vertex),
                .attribute_count = vertex_attributes.len,
                .attributes = &vertex_attributes,
            }};

            const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
                .vertex = wgpu.VertexState{
                    .module = vs_module,
                    .entry_point = "main",
                    .buffer_count = vertex_buffers.len,
                    .buffers = &vertex_buffers,
                },
                .primitive = wgpu.PrimitiveState{
                    .front_face = .ccw,
                    .cull_mode = .none,
                    .topology = .triangle_list,
                },
                .depth_stencil = &wgpu.DepthStencilState{
                    .format = .depth32_float,
                    .depth_write_enabled = true,
                    .depth_compare = .less,
                },
                .fragment = &wgpu.FragmentState{
                    .module = fs_module,
                    .entry_point = "main",
                    .target_count = color_targets.len,
                    .targets = &color_targets,
                },
            };
            break :pipeline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
        };

        const bind_group = gctx.createBindGroup(bind_group_layout, &.{
            .{
                .binding = 0,
                .buffer_handle = gctx.uniforms.buffer,
                .offset = 0,
                .size = @sizeOf(zmath.Mat),
            },
        });

        // Create a vertex buffer.
        const vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = 3 * @sizeOf(Vertex),
        });
        const vertex_data = [_]Vertex{
            .{ .position = [3]f32{ 0.0, 0.5, 0.0 }, .color = [3]f32{ 1.0, 0.0, 0.0 } },
            .{ .position = [3]f32{ -0.5, -0.5, 0.0 }, .color = [3]f32{ 0.0, 1.0, 0.0 } },
            .{ .position = [3]f32{ 0.5, -0.5, 0.0 }, .color = [3]f32{ 0.0, 0.0, 1.0 } },
        };
        gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, Vertex, vertex_data[0..]);

        // Create an index buffer.
        const index_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .index = true },
            .size = 3 * @sizeOf(u32),
        });
        const index_data = [_]u32{ 0, 1, 2 };
        gctx.queue.writeBuffer(gctx.lookupResource(index_buffer).?, 0, u32, index_data[0..]);

        // Create a depth texture and its 'view'.
        const depth = createDepthTexture(gctx);

        const engine = try allocator.create(Engine);
        engine.* = .{
            .allocator = allocator,
            .window_context = window_context,
            .gctx = gctx,
            .pipeline = pipeline,
            .bind_group = bind_group,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .depth_texture = depth.texture,
            .depth_texture_view = depth.view,
        };
        return engine;
    }

    pub fn update(engine: *Engine) void {
        _ = engine;
        // zgui.backend.newFrame(
        //     engine.gctx.swapchain_descriptor.width,
        //     engine.gctx.swapchain_descriptor.height,
        // );
        // zgui.showDemoWindow(null);
    }

    pub fn draw(engine: *Engine) void {
        const gctx = engine.gctx;

        const fb_width = gctx.swapchain_descriptor.width;
        const fb_height = gctx.swapchain_descriptor.height;
        const t = @as(f32, @floatCast(gctx.stats.time));

        const cam_world_to_view = zmath.lookAtLh(
            zmath.f32x4(3.0, 3.0, -3.0, 1.0),
            zmath.f32x4(0.0, 0.0, 0.0, 1.0),
            zmath.f32x4(0.0, 1.0, 0.0, 0.0),
        );
        const cam_view_to_clip = zmath.perspectiveFovLh(
            0.25 * math.pi,
            @as(f32, @floatFromInt(fb_width)) / @as(f32, @floatFromInt(fb_height)),
            0.01,
            200.0,
        );
        const cam_world_to_clip = zmath.mul(cam_world_to_view, cam_view_to_clip);

        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            pass: {
                const vb_info = gctx.lookupResourceInfo(engine.vertex_buffer) orelse break :pass;
                const ib_info = gctx.lookupResourceInfo(engine.index_buffer) orelse break :pass;
                const pipeline = gctx.lookupResource(engine.pipeline) orelse break :pass;
                const bind_group = gctx.lookupResource(engine.bind_group) orelse break :pass;
                const depth_view = gctx.lookupResource(engine.depth_texture_view) orelse break :pass;

                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .clear,
                    .store_op = .store,
                }};
                const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                    .view = depth_view,
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                    .depth_clear_value = 1.0,
                };
                const render_pass_info = wgpu.RenderPassDescriptor{
                    .color_attachment_count = color_attachments.len,
                    .color_attachments = &color_attachments,
                    .depth_stencil_attachment = &depth_attachment,
                };
                const pass = encoder.beginRenderPass(render_pass_info);
                defer {
                    pass.end();
                    pass.release();
                }

                pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
                pass.setIndexBuffer(ib_info.gpuobj.?, .uint32, 0, ib_info.size);

                pass.setPipeline(pipeline);

                // Draw triangle 1.
                {
                    const object_to_world = zmath.mul(zmath.rotationY(t), zmath.translation(-1.0, 0.0, 0.0));
                    const object_to_clip = zmath.mul(object_to_world, cam_world_to_clip);

                    const mem = gctx.uniformsAllocate(zmath.Mat, 1);
                    mem.slice[0] = zmath.transpose(object_to_clip);

                    pass.setBindGroup(0, bind_group, &.{mem.offset});
                    pass.drawIndexed(3, 1, 0, 0, 0);
                }

                // Draw triangle 2.
                {
                    const object_to_world = zmath.mul(zmath.rotationY(0.75 * t), zmath.translation(1.0, 0.0, 0.0));
                    const object_to_clip = zmath.mul(object_to_world, cam_world_to_clip);

                    const mem = gctx.uniformsAllocate(zmath.Mat, 1);
                    mem.slice[0] = zmath.transpose(object_to_clip);

                    pass.setBindGroup(0, bind_group, &.{mem.offset});
                    pass.drawIndexed(3, 1, 0, 0, 0);
                }
            }
            {
                const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                    .view = back_buffer_view,
                    .load_op = .load,
                    .store_op = .store,
                }};
                const render_pass_info = wgpu.RenderPassDescriptor{
                    .color_attachment_count = color_attachments.len,
                    .color_attachments = &color_attachments,
                };
                const pass = encoder.beginRenderPass(render_pass_info);
                defer {
                    pass.end();
                    pass.release();
                }

                // zgui.backend.draw(pass);
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});

        const gctx_state = gctx.present();

        switch (gctx_state) {
            .normal_execution => {},
            .swap_chain_resized => {
                // Release old depth texture.
                gctx.releaseResource(engine.depth_texture_view);
                gctx.destroyResource(engine.depth_texture);

                // Create a new depth texture to match the new window size.
                const depth = createDepthTexture(gctx);
                engine.depth_texture = depth.texture;
                engine.depth_texture_view = depth.view;
            },
        }
    }

    pub fn runLoop(engine: *Engine) void {
        const window = engine.window_context.window;

        while (!window.shouldClose() and window.getKey(.escape) != .press) {
            zglfw.pollEvents();
            engine.update();
            engine.draw();
        }
    }

    pub fn deinit(engine: *Engine) void {
        engine.allocator.destroy(engine);
    }
};

fn createDepthTexture(gctx: *zgpu.GraphicsContext) struct {
    texture: zgpu.TextureHandle,
    view: zgpu.TextureViewHandle,
} {
    const texture = gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });

    const view = gctx.createTextureView(texture, .{});

    return .{
        .texture = texture,
        .view = view,
    };
}
