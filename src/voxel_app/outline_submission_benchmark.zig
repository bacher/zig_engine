//! Headless CPU command-encoding comparison; commands are never submitted to the GPU.
const std = @import("std");
const outline = @import("engine").block_outline;
const zgpu = @import("engine").zgpu;
const wgpu = zgpu.wgpu;

extern fn dniCreate() ?*anyopaque;
extern fn dniDestroy(instance: ?*anyopaque) void;
extern fn dniGetWgpuInstance(instance: ?*anyopaque) ?wgpu.Instance;
extern fn dnGetProcs() ?*anyopaque;
extern fn dawnProcSetProcs(procs: ?*anyopaque) void;

const AdapterResponse = struct {
    adapter: ?wgpu.Adapter = null,
    fn callback(status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, _: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        const self: *AdapterResponse = @ptrCast(@alignCast(userdata));
        if (status == .success) self.adapter = adapter;
    }
};
const DeviceResponse = struct {
    device: ?wgpu.Device = null,
    fn callback(status: wgpu.RequestDeviceStatus, device: wgpu.Device, _: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
        const self: *DeviceResponse = @ptrCast(@alignCast(userdata));
        if (status == .success) self.device = device;
    }
};

pub fn run(init: std.process.Init) !void {
    dawnProcSetProcs(dnGetProcs());
    const native = dniCreate() orelse return error.NoGraphicsAdapter;
    defer dniDestroy(native);
    const instance = dniGetWgpuInstance(native) orelse return error.NoGraphicsAdapter;
    var adapter_response: AdapterResponse = .{};
    instance.requestAdapter(.{ .power_preference = .high_performance, .backend_type = if (@import("builtin").os.tag == .macos) .metal else .undef }, AdapterResponse.callback, &adapter_response);
    const adapter = adapter_response.adapter orelse return error.NoGraphicsAdapter;
    defer adapter.release();
    var properties: wgpu.AdapterProperties = undefined;
    properties.next_in_chain = null;
    adapter.getProperties(&properties);
    if (properties.backend_type == .nul) return error.NoGraphicsAdapter;
    var device_response: DeviceResponse = .{};
    adapter.requestDevice(.{}, DeviceResponse.callback, &device_response);
    const device = device_response.device orelse return error.NoGraphicsAdapter;
    defer device.release();
    defer device.destroy();
    std.debug.print("outline command encoding: {s} ({s})\n", .{ properties.name, @tagName(properties.backend_type) });

    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = device;
    inline for (.{ "buffer_pool", "bind_group_pool", "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" }) |name| {
        @field(gctx, name) = .{ .pool = try @TypeOf(@field(gctx, name).pool).initCapacity(init.gpa, 8) };
    }
    defer inline for (.{ "buffer_pool", "bind_group_pool", "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" }) |name| @field(gctx, name).pool.deinit();
    const layout = outline.BindGroupLayout.init(&gctx);
    defer layout.deinit(&gctx);
    const visible = outline.createPipeline(&gctx, layout, .rgba8_unorm);
    defer visible.deinit(&gctx);
    const hidden = outline.createOccludedPipeline(&gctx, layout, .rgba8_unorm);
    defer hidden.deinit(&gctx);
    const batched = layout.createBindGroup(&gctx);
    defer batched.deinit(&gctx);

    // Match the old per-cell dynamic binding stride; shader and pipelines are
    // shared so this isolates command encoding, not uniform-versus-storage access.
    const stride = 256;
    const individual_buffer = device.createBuffer(.{ .size = stride * outline.instance_capacity, .usage = .{ .storage = true } });
    defer individual_buffer.release();
    const entries = [_]wgpu.BindGroupEntry{.{ .binding = 0, .buffer = individual_buffer, .size = @sizeOf(outline.Instance) }};
    const individual = device.createBindGroup(.{ .layout = gctx.lookupResource(layout.bind_group_layout_handle).?, .entries = &entries, .entry_count = entries.len });
    defer individual.release();
    const extent = wgpu.Extent3D{ .width = 128, .height = 128, .depth_or_array_layers = 1 };
    const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true } });
    defer color.release();
    const color_view = color.createView(.{});
    defer color_view.release();
    const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true } });
    defer depth.release();
    const depth_view = depth.createView(.{});
    defer depth_view.release();
    const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = color_view, .load_op = .clear, .store_op = .store }};
    const descriptor = wgpu.RenderPassDescriptor{ .color_attachments = &attachments, .color_attachment_count = attachments.len, .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = 1 } };
    const frames_per_sample = 1000;
    for ([_]u32{ 1, 20, 34, 64 }) |count| {
        var samples: [2][11]u64 = undefined;
        // Alternate paths to reduce bias from warmup and clock changes.
        for (0..12) |sample| for ([_]bool{ false, true }, 0..) |instanced, path_index| {
            const start = std.Io.Clock.awake.now(init.io);
            for (0..frames_per_sample) |_| {
                const encoder = device.createCommandEncoder(null);
                const pass = encoder.beginRenderPass(descriptor);
                if (instanced) {
                    outline.drawBatch(pass, hidden.pipeline_gpu, visible.pipeline_gpu, batched.wgpu_bind_group, 0, if (count == 1) 0 else count, count);
                } else {
                    if (count != 1) {
                        pass.setPipeline(hidden.pipeline_gpu);
                        for (0..count) |index| {
                            pass.setBindGroup(0, individual, &.{@as(u32, @intCast(index)) * stride});
                            pass.draw(outline.vertex_count, 1, 0, 0);
                        }
                    }
                    pass.setPipeline(visible.pipeline_gpu);
                    for (0..count) |index| {
                        pass.setBindGroup(0, individual, &.{@as(u32, @intCast(index)) * stride});
                        pass.draw(outline.vertex_count, 1, 0, 0);
                    }
                }
                pass.end();
                pass.release();
                const command = encoder.finish(null);
                command.release();
                encoder.release();
            }
            const elapsed: u64 = @intCast(start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
            if (sample != 0) samples[path_index][sample - 1] = elapsed;
        };
        for (&samples) |*path| std.mem.sort(u64, path, {}, std.sort.asc(u64));
        std.debug.print("{d} cells: individual {d:.3} us/frame, instanced {d:.3} us/frame (median of 11 x {d} frames, {s}; includes encoder/pass creation, finish and release; excludes preparation, uploads, queue submission and GPU execution)\n", .{
            count,
            @as(f64, @floatFromInt(samples[0][5])) / (frames_per_sample * std.time.ns_per_us),
            @as(f64, @floatFromInt(samples[1][5])) / (frames_per_sample * std.time.ns_per_us),
            frames_per_sample,
            @tagName(@import("builtin").mode),
        });
    }
}
