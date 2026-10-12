//! Headless rendering/readback of the production outline shader and pipeline.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const outline = @import("block_outline.zig");
const layouts_module = @import("bind_group_layouts.zig");
const callbacks = @import("world_coordinate_readback.zig");

pub const Mapping = struct {
    done: bool = false,
    status: wgpu.BufferMapAsyncStatus = .unknown,

    fn callback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Mapping = @ptrCast(@alignCast(userdata));
        self.status = status;
        self.done = true;
    }
};

pub fn check(device: wgpu.Device, mapping: *Mapping) !void {
    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = device;
    inline for (.{ "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" }) |name| {
        @field(gctx, name) = .{ .pool = try @TypeOf(@field(gctx, name).pool).initCapacity(std.testing.allocator, 8) };
    }
    defer inline for (.{ "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" }) |name| @field(gctx, name).pool.deinit();
    var layouts: layouts_module.BindGroupLayouts = undefined;
    layouts.lines = .init(&gctx);
    defer layouts.lines.deinit(&gctx);
    const pipeline = outline.createPipeline(&gctx, &layouts, .rgba8_unorm);
    defer pipeline.deinit(&gctx);
    const uniforms = device.createBuffer(.{ .size = 512, .usage = .{ .uniform = true, .copy_dst = true } });
    defer uniforms.release();
    const entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .buffer = uniforms, .size = @sizeOf(zmath.Mat) },
        .{ .binding = 1, .buffer = uniforms, .size = @sizeOf(zmath.Vec) },
    };
    const bind_group = device.createBindGroup(.{
        .layout = gctx.lookupResource(layouts.lines.bind_group_layout_handle).?,
        .entries = &entries,
        .entry_count = entries.len,
    });
    defer bind_group.release();
    const queue = device.getQueue();
    defer queue.release();
    for ([_]u32{ 128, 256 }) |side| {
        const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
        const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
        defer color.release();
        const color_view = color.createView(.{});
        defer color_view.release();
        const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true, .copy_src = true } });
        defer depth.release();
        const depth_view = depth.createView(.{});
        defer depth_view.release();
        const image_size: u64 = side * side * 4;
        const readback = device.createBuffer(.{ .size = image_size * 2, .usage = .{ .copy_dst = true, .map_read = true } });
        defer readback.release();
        const stroke = zmath.Vec{ @floatFromInt(side), @floatFromInt(side), outline.width_pixels, 0 };
        queue.writeBuffer(uniforms, 256, zmath.Vec, &.{stroke});
        for ([_]enum { visible, distant, occluded, near_clipped, perspective_near, behind }{ .visible, .distant, .occluded, .near_clipped, .perspective_near, .behind }) |case| {
            var transform = zmath.identity();
            transform[2][2] = 0.1;
            transform[3] = .{ -0.5, -0.5, switch (case) {
                .visible, .distant, .occluded => 0.5,
                .near_clipped, .perspective_near => -0.05,
                .behind => -1,
            }, 1 };
            if (case == .distant) {
                transform[0][0] = 0.5;
                transform[1][1] = 0.5;
                transform[3][0] = -0.25;
                transform[3][1] = -0.25;
            }
            if (case == .perspective_near) {
                transform = @import("utils.zig").matMul(zmath.perspectiveFovRh(std.math.pi / 2.0, 1, 0.1, 10), zmath.translation(-0.1, -0.1, -0.3));
            }
            queue.writeBuffer(uniforms, 0, zmath.Mat, &.{transform});
            const clear_depth: f32 = if (case == .occluded) 0.25 else if (case == .perspective_near) 1 else 0.5;
            const encoder = device.createCommandEncoder(null);
            defer encoder.release();
            const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = color_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }};
            const pass = encoder.beginRenderPass(.{
                .color_attachments = &attachments,
                .color_attachment_count = attachments.len,
                .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = clear_depth },
            });
            defer pass.release();
            pass.setPipeline(pipeline.pipeline_gpu);
            pass.setBindGroup(0, bind_group, &.{ 0, 256 });
            pass.draw(outline.vertex_count, 1, 0, 0);
            pass.end();
            encoder.copyTextureToBuffer(.{ .texture = color }, .{ .buffer = readback, .layout = .{ .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
            encoder.copyTextureToBuffer(.{ .texture = depth, .aspect = .depth_only }, .{ .buffer = readback, .layout = .{ .offset = image_size, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
            const command = encoder.finish(null);
            defer command.release();
            queue.submit(&.{command});
            mapping.* = .{};
            readback.mapAsync(.{ .read = true }, 0, image_size * 2, Mapping.callback, mapping);
            defer readback.unmap();
            try callbacks.waitForCallback(device, &mapping.done);
            try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
            const pixels = readback.getConstMappedRange([4]u8, 0, side * side) orelse return error.NoMappedGpuResults;
            const depths = readback.getConstMappedRange(f32, image_size, side * side) orelse return error.NoMappedGpuResults;
            var green_count: usize = 0;
            for (pixels, depths) |pixel, stored_depth| {
                try std.testing.expectEqual(clear_depth, stored_depth);
                if (pixel[1] != 0) {
                    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel);
                    green_count += 1;
                }
            }
            if (case == .occluded or case == .behind) {
                try std.testing.expectEqual(0, green_count);
            } else {
                try std.testing.expect(green_count > 0);
                try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixels[(side / 2) * side + side / 2]);
                var left_width: usize = 0;
                for (pixels[(side / 2) * side ..][0 .. side / 2]) |pixel| {
                    if (pixel[1] != 0) left_width += 1;
                }
                // Rasterization's edge rule can include either boundary sample.
                try std.testing.expect(left_width >= 2 and left_width <= 4);
            }
        }
    }
}
