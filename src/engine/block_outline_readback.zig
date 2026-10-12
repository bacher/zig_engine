//! Headless rendering/readback of the production outline shader and pipeline.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const outline = @import("block_outline.zig");
const layouts_module = @import("bind_group_layouts.zig");
const callbacks = @import("world_coordinate_readback.zig");
const utils = @import("utils.zig");

// Dynamic storage-buffer bindings are aligned to 256 bytes.
const instance_offsets = struct {
    const stride = 256;
    const target = 0;
    const foreground = stride;
    const coplanar = [_]u32{ 2 * stride, 3 * stride, 4 * stride };
    const partial = 5 * stride;
    const buffer_size = partial + stride;
};

const RenderCase = enum {
    depth_free,
    target_only,
    foreground_occluder,
    coplanar_x,
    coplanar_y,
    coplanar_z,
    partial_occluder,

    fn pixels(case: RenderCase, images: []const [4]u8, image_pixels: usize) []const [4]u8 {
        const start = @intFromEnum(case) * image_pixels;
        return images[start..][0..image_pixels];
    }
};
const render_cases = std.enums.values(RenderCase);
const coplanar_cases = [_]RenderCase{ .coplanar_x, .coplanar_y, .coplanar_z };

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
    inline for (.{ "buffer_pool", "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" }) |name| {
        @field(gctx, name) = .{ .pool = try @TypeOf(@field(gctx, name).pool).initCapacity(std.testing.allocator, 8) };
    }
    defer inline for (.{ "buffer_pool", "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" }) |name| @field(gctx, name).pool.deinit();
    var layouts: layouts_module.BindGroupLayouts = undefined;
    layouts.block_outline = .init(&gctx);
    defer layouts.block_outline.deinit(&gctx);
    const pipeline = outline.createPipeline(&gctx, layouts.block_outline, .rgba8_unorm);
    defer pipeline.deinit(&gctx);
    const instance_buffer = device.createBuffer(.{ .size = instance_offsets.buffer_size, .usage = .{ .storage = true, .copy_dst = true } });
    defer instance_buffer.release();
    const entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .buffer = instance_buffer, .size = @sizeOf(outline.Instance) },
    };
    const bind_group = device.createBindGroup(.{
        .layout = gctx.lookupResource(layouts.block_outline.bind_group_layout_handle).?,
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
        const stroke = zmath.Vec{ @floatFromInt(side), @floatFromInt(side), outline.width_pixels, 63 };
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
            const data = outline.Instance{ .clip_from_block = transform, .block_from_clip = zmath.inverse(transform), .stroke = stroke };
            queue.writeBuffer(instance_buffer, instance_offsets.target, outline.Instance, &.{data});
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
            pass.setBindGroup(0, bind_group, &.{instance_offsets.target});
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
    try checkOblique(&gctx, &layouts, pipeline.pipeline_gpu, bind_group, instance_buffer, mapping, false);
    try checkOblique(&gctx, &layouts, pipeline.pipeline_gpu, bind_group, instance_buffer, mapping, true);
    try checkHints(&gctx, &layouts, pipeline.pipeline_gpu, instance_buffer, mapping);
    try checkInstancedBatch(&gctx, layouts.block_outline, pipeline.pipeline_gpu, mapping);
}

/// Compare full images against individual draws of the same instance records.
/// The final record acts like green focus: visible only, after all diagnostics.
fn checkInstancedBatch(gctx: *zgpu.GraphicsContext, layout: outline.BindGroupLayout, visible_pipeline: wgpu.RenderPipeline, mapping: *Mapping) !void {
    const device = gctx.device;
    const hidden_pipeline = outline.createOccludedPipeline(gctx, layout, .rgba8_unorm);
    defer hidden_pipeline.deinit(gctx);
    const queue = device.getQueue();
    defer queue.release();
    const storage = device.createBuffer(.{ .size = outline.instance_capacity * @sizeOf(outline.Instance), .usage = .{ .storage = true, .copy_dst = true } });
    defer storage.release();
    const entries = [_]wgpu.BindGroupEntry{.{ .binding = 0, .buffer = storage, .size = outline.instance_capacity * @sizeOf(outline.Instance) }};
    const bind_group = device.createBindGroup(.{ .layout = gctx.lookupResource(layout.bind_group_layout_handle).?, .entries = &entries, .entry_count = entries.len });
    defer bind_group.release();
    const side = 128;
    const image_size = side * side * 4;
    const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
    const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer color.release();
    const color_view = color.createView(.{});
    defer color_view.release();
    const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer depth.release();
    const depth_view = depth.createView(.{});
    defer depth_view.release();
    const readback = device.createBuffer(.{ .size = image_size * 4, .usage = .{ .copy_dst = true, .map_read = true } });
    defer readback.release();
    var instances: [outline.instance_capacity]outline.Instance = undefined;
    for (&instances, 0..) |*instance, index| {
        var transform = zmath.identity();
        transform[0][0] = 0.13;
        transform[1][1] = 0.13;
        transform[2] = .{ 0.025, 0.025, 0.1, 0 };
        transform[3] = .{ -0.85 + @as(f32, @floatFromInt(index % 8)) * 0.2, -0.85 + @as(f32, @floatFromInt(index / 8)) * 0.2, if (index % 3 == 0) 0.8 else 0.3, 1 };
        instance.* = .{
            .clip_from_block = transform,
            .block_from_clip = zmath.inverse(transform),
            .stroke = .{ side, side, outline.width_pixels, 63 },
            .color = if (index % 2 == 0) .{ 1, 0.5, 0, 0.65 } else .{ 0, 1, 1, 0.5 },
            .parameters = if (index % 2 == 0) .{ 1, 16, 0, 0 } else @splat(0),
        };
    }
    for ([_]u32{ 20, 34, outline.instance_capacity }) |count| for ([_]bool{ false, true }) |focus_hidden| {
        const last = instances[count - 1];
        instances[count - 1].color = .{ 0, 1, 0, 1 };
        instances[count - 1].clip_from_block[3][2] = if (focus_hidden) 0.8 else 0.3;
        instances[count - 1].block_from_clip = zmath.inverse(instances[count - 1].clip_from_block);
        queue.writeBuffer(storage, 0, outline.Instance, instances[0..count]);
        instances[count - 1] = last;
        for ([_]bool{ false, true }, 0..) |batched, image_index| {
            const encoder = device.createCommandEncoder(null);
            defer encoder.release();
            const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = color_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }};
            const pass = encoder.beginRenderPass(.{ .color_attachments = &attachments, .color_attachment_count = attachments.len, .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = 0.65 } });
            defer pass.release();
            if (batched) {
                outline.drawBatch(pass, hidden_pipeline.pipeline_gpu, visible_pipeline, bind_group, 0, count - 1, count);
            } else {
                pass.setBindGroup(0, bind_group, &.{0});
                pass.setPipeline(hidden_pipeline.pipeline_gpu);
                for (0..count - 1) |index| pass.draw(outline.vertex_count, 1, 0, @intCast(index));
                pass.setPipeline(visible_pipeline);
                for (0..count) |index| pass.draw(outline.vertex_count, 1, 0, @intCast(index));
            }
            pass.end();
            encoder.copyTextureToBuffer(.{ .texture = color }, .{ .buffer = readback, .layout = .{ .offset = image_index * image_size, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
            encoder.copyTextureToBuffer(.{ .texture = depth, .aspect = .depth_only }, .{ .buffer = readback, .layout = .{ .offset = (2 + image_index) * image_size, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
            const command = encoder.finish(null);
            defer command.release();
            queue.submit(&.{command});
        }
        mapping.* = .{};
        readback.mapAsync(.{ .read = true }, 0, image_size * 4, Mapping.callback, mapping);
        defer readback.unmap();
        try callbacks.waitForCallback(device, &mapping.done);
        try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
        const pixels = readback.getConstMappedRange([4]u8, 0, 2 * side * side) orelse return error.NoMappedGpuResults;
        const depths = readback.getConstMappedRange(f32, 2 * image_size, 2 * side * side) orelse return error.NoMappedGpuResults;
        try std.testing.expectEqualSlices([4]u8, pixels[0 .. side * side], pixels[side * side ..]);
        var colored: usize = 0;
        var green: usize = 0;
        for (pixels[0 .. side * side]) |pixel| {
            if (pixel[0] != 0 or pixel[1] != 0) colored += 1;
            if (std.meta.eql(pixel, [4]u8{ 0, 255, 0, 255 })) green += 1;
        }
        try std.testing.expect(colored > count * 10);
        try std.testing.expectEqual(!focus_hidden, green > 0);
        for (depths) |stored| try std.testing.expectEqual(@as(f32, 0.65), stored);
    };
}

/// Exercise two differently colored, translucent full-cube hints and the occluded pass.
fn checkHints(gctx: *zgpu.GraphicsContext, layouts: *const layouts_module.BindGroupLayouts, visible_pipeline: wgpu.RenderPipeline, instance_buffer: wgpu.Buffer, mapping: *Mapping) !void {
    const device = gctx.device;
    const hidden_pipeline = outline.createOccludedPipeline(gctx, layouts.block_outline, .rgba8_unorm);
    defer hidden_pipeline.deinit(gctx);
    const queue = device.getQueue();
    defer queue.release();
    const entries = [_]wgpu.BindGroupEntry{.{ .binding = 0, .buffer = instance_buffer, .size = 2 * @sizeOf(outline.Instance) }};
    const bind_group = device.createBindGroup(.{ .layout = gctx.lookupResource(layouts.block_outline.bind_group_layout_handle).?, .entries = &entries, .entry_count = entries.len });
    defer bind_group.release();
    const side = 128;
    const image_size = side * side * 4;
    const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
    const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer color.release();
    const color_view = color.createView(.{});
    defer color_view.release();
    const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer depth.release();
    const depth_view = depth.createView(.{});
    defer depth_view.release();
    const readback = device.createBuffer(.{ .size = image_size * 2, .usage = .{ .copy_dst = true, .map_read = true } });
    defer readback.release();
    for ([_]enum { visible, hidden, overlap_visible_first, overlap_hidden_first }{ .visible, .hidden, .overlap_visible_first, .overlap_hidden_first }) |case| {
        const overlap = case == .overlap_visible_first or case == .overlap_hidden_first;
        const clear_depth: f32 = if (overlap) 0.65 else if (case == .visible) 1 else 0.25;
        const encoder = device.createCommandEncoder(null);
        defer encoder.release();
        const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = color_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0.2, .g = 0.4, .b = 0.6, .a = 1 } }};
        const pass = encoder.beginRenderPass(.{
            .color_attachments = &attachments,
            .color_attachment_count = attachments.len,
            .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = clear_depth },
        });
        defer pass.release();
        var instances: [2]outline.Instance = undefined;
        for (0..2) |index| {
            var transform = zmath.identity();
            transform[0][0] = 0.5;
            transform[1][1] = 0.5;
            transform[2] = .{ 0.1, 0.1, 0.1, 0 };
            transform[3] = .{ if (index == 0 or overlap) -0.7 else 0.1, -0.3, if (index == 1 and overlap) 0.8 else 0.5, 1 };
            instances[index] = .{
                .clip_from_block = transform,
                .block_from_clip = zmath.inverse(transform),
                .stroke = .{ side, side, outline.width_pixels, 63 },
                .color = if (index == 0) .{ 1, 0.5, 0, 0.5 } else .{ 0, 1, 1, 0.5 },
                .parameters = @splat(0),
            };
        }
        if (case == .overlap_hidden_first) std.mem.swap(outline.Instance, &instances[0], &instances[1]);
        queue.writeBuffer(instance_buffer, 0, outline.Instance, &instances);
        outline.drawBatch(pass, hidden_pipeline.pipeline_gpu, visible_pipeline, bind_group, 0, 2, 2);
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
        for (depths) |stored_depth| try std.testing.expectEqual(clear_depth, stored_depth);
        // The overlap probe must blend faint cyan BEFORE bright orange, regardless
        // of cell order. Interleaved draws produce a different, cyan-tinted stroke.
        const expected = if (overlap) [_][4]u8{ .{ 149, 126, 84, 255 }, .{ 51, 102, 153, 255 } } else if (clear_depth == 1) [_][4]u8{ .{ 153, 115, 77, 255 }, .{ 26, 179, 204, 255 } } else [_][4]u8{ .{ 82, 106, 130, 255 }, .{ 43, 125, 168, 255 } };
        for ([_]usize{ 19, 70 }, expected) |x, pixel| {
            inline for (0..4) |channel| {
                try std.testing.expect(@abs(@as(i16, pixels[64 * side + x][channel]) - pixel[channel]) <= 1);
            }
        }
        try std.testing.expectEqual([4]u8{ 51, 102, 153, 255 }, pixels[114 * side + 64]);
    }
}

const edges = [_][2]u3{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 }, .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 }, .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 } };

fn corner(index: u3) zmath.Vec {
    return .{ @floatFromInt(index & 1), @floatFromInt((index >> 1) & 1), @floatFromInt((index >> 2) & 1), 1 };
}

// Render actual cube surfaces before the outline: a cleared constant depth alone
// cannot expose the self-occlusion caused by screen-space stroke expansion.
fn checkOblique(gctx: *zgpu.GraphicsContext, layouts: *const layouts_module.BindGroupLayouts, pipeline: wgpu.RenderPipeline, bind_group: wgpu.BindGroup, instance_buffer: wgpu.Buffer, mapping: *Mapping, occupied_overlay: bool) !void {
    const device = gctx.device;
    const hidden_pipeline = if (occupied_overlay) outline.createOccludedPipeline(gctx, layouts.block_outline, .rgba8_unorm) else null;
    defer if (hidden_pipeline) |hidden| hidden.deinit(gctx);
    const cube_source =
        \\@group(0) @binding(0) var<storage, read> clip_from_cube: mat4x4f;
        \\const vertices = array<u32, 36>(
        \\    0,2,4, 2,6,4, 1,5,3, 3,5,7,
        \\    0,4,1, 1,4,5, 2,3,6, 3,7,6,
        \\    0,1,2, 1,3,2, 4,6,5, 5,6,7,
        \\);
        \\@vertex fn main(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
        \\    let c = vertices[index];
        \\    return clip_from_cube * vec4f(f32(c & 1u), f32((c >> 1u) & 1u), f32((c >> 2u) & 1u), 1);
        \\}
    ;
    const module = zgpu.createWgslShaderModule(device, cube_source, "outline_test_cube");
    defer module.release();
    const cube_layouts = [_]wgpu.BindGroupLayout{gctx.lookupResource(layouts.block_outline.bind_group_layout_handle).?};
    const cube_layout = device.createPipelineLayout(.{ .bind_group_layouts = &cube_layouts, .bind_group_layout_count = cube_layouts.len });
    defer cube_layout.release();
    const cube = device.createRenderPipeline(.{
        .layout = cube_layout,
        .primitive = .{ .topology = .triangle_list, .cull_mode = .none },
        .vertex = .{ .module = module, .entry_point = "main" },
        .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less },
    });
    defer cube.release();
    const queue = device.getQueue();
    defer queue.release();
    const views = [_]struct {
        eye: zmath.Vec,
        focus: zmath.Vec = .{ 0.5, 0.5, 0.5, 1 },
        fov: f32 = std.math.pi / 2.0,
        far: f32 = 1000,
        grazing: bool = false,
    }{
        .{ .eye = .{ 2.5, -3, 2, 1 } },
        .{ .eye = .{ 3, 0.5, 2, 1 } },
        .{ .eye = .{ -2, 2, -1.5, 1 } },
        .{ .eye = .{ 0.6, -0.5, 3.5, 1 } },
        .{ .eye = .{ 1.01, -3, 0.5, 1 }, .focus = .{ 1, 0.5, 0.5, 1 }, .fov = std.math.pi / 4.0, .far = 200, .grazing = true },
    };
    for ([_]u32{ 128, 256 }) |side| {
        const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
        const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
        defer color.release();
        const color_view = color.createView(.{});
        defer color_view.release();
        const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true } });
        defer depth.release();
        const depth_view = depth.createView(.{});
        defer depth_view.release();
        const image_size: u64 = side * side * 4;
        const readback = device.createBuffer(.{ .size = image_size * render_cases.len, .usage = .{ .copy_dst = true, .map_read = true } });
        defer readback.release();
        for (views, 0..) |view, view_index| {
            const eye = view.eye;
            const transform = utils.matMul(zmath.perspectiveFovRh(view.fov, 1, 0.01, view.far), zmath.lookAtRh(eye, view.focus, .{ 0, 0, 1, 0 }));
            const mask = outline.faceMask(.{ eye[0], eye[1], eye[2] });
            const data = outline.Instance{
                .clip_from_block = transform,
                .block_from_clip = zmath.inverse(transform),
                .stroke = .{ @floatFromInt(side), @floatFromInt(side), outline.width_pixels, @floatFromInt(if (occupied_overlay) @as(u32, 63) else mask) },
                .color = if (occupied_overlay) .{ 1, 0.65, 0.1, 0.65 } else .{ 0, 1, 0, 1 },
                .parameters = .{ 1, @floatFromInt(mask), 0, 0 },
            };
            queue.writeBuffer(instance_buffer, instance_offsets.target, outline.Instance, &.{data});
            // A larger cube halfway to the eye must still occlude the corrected
            // outline. It uses a second dynamic storage-buffer region, not target data.
            const center = (eye + zmath.Vec{ 0.5, 0.5, 0.5, 1 }) * @as(zmath.Vec, @splat(0.5));
            var foreground = data;
            const model = utils.matMul(zmath.translation(center[0] - 1, center[1] - 1, center[2] - 1), zmath.scaling(2, 2, 2));
            foreground.clip_from_block = utils.matMul(transform, model);
            queue.writeBuffer(instance_buffer, instance_offsets.foreground, outline.Instance, &.{foreground});
            // This adjacent voxel covers only part of the target at grazing
            // angles; its nearer y=-1 face must hide the outline beneath it.
            var partial = data;
            partial.clip_from_block = utils.matMul(transform, zmath.translation(0, -1, 0));
            queue.writeBuffer(instance_buffer, instance_offsets.partial, outline.Instance, &.{partial});
            // Surround the target with coplanar neighbors along each axis,
            // covering walls, floors, and ceilings from the oblique viewpoints.
            inline for (0..3) |axis| {
                var wall_scale: @Vector(3, f32) = @splat(3);
                var wall_shift: @Vector(3, f32) = @splat(-1);
                wall_scale[axis] = 1;
                wall_shift[axis] = 0;
                var wall = data;
                const wall_model = utils.matMul(zmath.translation(wall_shift[0], wall_shift[1], wall_shift[2]), zmath.scaling(wall_scale[0], wall_scale[1], wall_scale[2]));
                wall.clip_from_block = utils.matMul(transform, wall_model);
                queue.writeBuffer(instance_buffer, instance_offsets.coplanar[axis], outline.Instance, &.{wall});
            }
            for (render_cases) |case| {
                const encoder = device.createCommandEncoder(null);
                defer encoder.release();
                const scene = encoder.beginRenderPass(.{
                    .color_attachments = null,
                    .color_attachment_count = 0,
                    .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = 1 },
                });
                defer scene.release();
                if (case != .depth_free) {
                    scene.setPipeline(cube);
                    scene.setBindGroup(0, bind_group, &.{instance_offsets.target});
                    scene.draw(36, 1, 0, 0);
                    const occluder: ?u32 = switch (case) {
                        .depth_free, .target_only => null,
                        .foreground_occluder => instance_offsets.foreground,
                        .coplanar_x => instance_offsets.coplanar[0],
                        .coplanar_y => instance_offsets.coplanar[1],
                        .coplanar_z => instance_offsets.coplanar[2],
                        .partial_occluder => instance_offsets.partial,
                    };
                    if (occluder) |offset| {
                        scene.setBindGroup(0, bind_group, &.{offset});
                        scene.draw(36, 1, 0, 0);
                    }
                }
                scene.end();
                const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = color_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }};
                const pass = encoder.beginRenderPass(.{
                    .color_attachments = &attachments,
                    .color_attachment_count = attachments.len,
                    .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .load, .depth_store_op = .store },
                });
                defer pass.release();
                if (hidden_pipeline) |hidden| {
                    pass.setPipeline(hidden.pipeline_gpu);
                    pass.setBindGroup(0, bind_group, &.{instance_offsets.target});
                    pass.draw(outline.vertex_count, 1, 0, 0);
                }
                pass.setPipeline(pipeline);
                pass.setBindGroup(0, bind_group, &.{instance_offsets.target});
                pass.draw(outline.vertex_count, 1, 0, 0);
                pass.end();
                encoder.copyTextureToBuffer(.{ .texture = color }, .{ .buffer = readback, .layout = .{ .offset = @intFromEnum(case) * image_size, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
                const command = encoder.finish(null);
                defer command.release();
                queue.submit(&.{command});
            }
            mapping.* = .{};
            readback.mapAsync(.{ .read = true }, 0, image_size * render_cases.len, Mapping.callback, mapping);
            defer readback.unmap();
            try callbacks.waitForCallback(device, &mapping.done);
            try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
            const pixels = readback.getConstMappedRange([4]u8, 0, side * side * render_cases.len) orelse return error.NoMappedGpuResults;
            const baseline = RenderCase.depth_free.pixels(pixels, side * side);
            const actual = RenderCase.target_only.pixels(pixels, side * side);
            const occluded = RenderCase.foreground_occluder.pixels(pixels, side * side);
            for (occluded) |pixel| try std.testing.expect(!isBright(pixel, occupied_overlay));
            if (view.grazing) try checkPartialOcclusion(RenderCase.partial_occluder.pixels(pixels, side * side), actual, data.block_from_clip, side, occupied_overlay);
            if (view_index == 0) {
                // This back edge projects into the face interior, clear of the
                // visible strokes. Depth correction must not reveal it there.
                const hidden = utils.matApply(transform, .{ 0, 1, 0.5, 1 });
                const half: f32 = @as(f32, @floatFromInt(side)) / 2;
                const x: usize = @intFromFloat(@floor((1 + hidden[0] / hidden[3]) * half));
                const y: usize = @intFromFloat(@floor((1 - hidden[1] / hidden[3]) * half));
                if (occupied_overlay) {
                    try std.testing.expect(isBright(baseline[y * side + x], true));
                    // Rear edges remain at their actual depth, visible only in the
                    // faint pass. Surface correction must never promote them.
                    try std.testing.expect(@abs(@as(i16, actual[y * side + x][0]) - 50) <= 1);
                } else {
                    try std.testing.expectEqual(@as(u8, 0), baseline[y * side + x][1]);
                    try std.testing.expectEqual(@as(u8, 0), actual[y * side + x][1]);
                }
            }
            var probes: usize = 0;
            var missing: usize = 0;
            var missing_coplanar: usize = 0;
            for (edges) |edge| {
                const a = corner(edge[0]);
                const b = corner(edge[1]);
                var visible = false;
                var wall_faces: [3]bool = @splat(false);
                inline for (0..3) |axis| {
                    wall_faces[axis] = a[axis] == b[axis] and (if (a[axis] == 0) eye[axis] < 0 else eye[axis] > 1);
                    visible = visible or wall_faces[axis];
                }
                if (!visible) continue;
                const clip_a = utils.matApply(transform, a);
                const clip_b = utils.matApply(transform, b);
                const scale: @Vector(2, f32) = @splat(@as(f32, @floatFromInt(side)) / 2);
                const pa = @Vector(2, f32){ 1 + clip_a[0] / clip_a[3], 1 - clip_a[1] / clip_a[3] } * scale;
                const pb = @Vector(2, f32){ 1 + clip_b[0] / clip_b[3], 1 - clip_b[1] / clip_b[3] } * scale;
                const delta = pb - pa;
                const length_squared = @reduce(.Add, delta * delta);
                if (length_squared < 1) continue;
                for (0..side) |y| for (0..side) |x| {
                    const point = @Vector(2, f32){ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                    const t = @reduce(.Add, (point - pa) * delta) / length_squared;
                    if (t < 0.2 or t > 0.8) continue;
                    const offset = point - (pa + delta * @as(@Vector(2, f32), @splat(t)));
                    if (@reduce(.Add, offset * offset) > 1.25 * 1.25) continue;
                    const index = y * side + x;
                    try std.testing.expect(isBright(baseline[index], occupied_overlay));
                    probes += 1;
                    if (!isBright(actual[index], occupied_overlay)) missing += 1;
                    // Nearly edge-on coplanar strokes may reach the world-space
                    // continuation limit; full width is checked at ordinary
                    // oblique views, and target self-occlusion at every view.
                    inline for (0..3) |axis| {
                        const wall_pixels = coplanar_cases[axis].pixels(pixels, side * side);
                        if (!view.grazing and wall_faces[axis] and !isBright(wall_pixels[index], occupied_overlay)) missing_coplanar += 1;
                    }
                };
            }
            try std.testing.expect(probes > 30);
            if (missing != 0) {
                std.debug.print("outline self-occlusion: viewport={d}, eye={d}, lost {d}/{d} visible-edge pixels\n", .{ side, eye, missing, probes });
                return error.OutlineSelfOcclusion;
            }
            if (missing_coplanar != 0) {
                std.debug.print("outline coplanar occlusion: viewport={d}, eye={d}, lost {d} face-edge pixels\n", .{ side, eye, missing_coplanar });
                return error.OutlineCoplanarOcclusion;
            }
        }
    }
}

fn isBright(pixel: [4]u8, occupied_overlay: bool) bool {
    return if (occupied_overlay) pixel[0] >= 160 else pixel[1] == 255;
}

fn checkPartialOcclusion(pixels: []const [4]u8, target_only: []const [4]u8, block_from_clip: zmath.Mat, side: u32, occupied_overlay: bool) !void {
    var front_face_probes: usize = 0;
    var covered_stroke: usize = 0;
    var visible_stroke: usize = 0;
    var leaked: usize = 0;
    const size: f32 = @floatFromInt(side);
    for (pixels, target_only, 0..) |pixel, target_pixel, index| {
        if (isBright(pixel, occupied_overlay)) visible_stroke += 1;
        const x: f32 = @floatFromInt(index % side);
        const y: f32 = @floatFromInt(index / side);
        const xy = zmath.Vec{ 2 * (x + 0.5) / size - 1, 1 - 2 * (y + 0.5) / size, 0, 1 };
        const near_h = utils.matApply(block_from_clip, xy);
        const far_h = utils.matApply(block_from_clip, .{ xy[0], xy[1], 1, 1 });
        const origin = near_h / @as(zmath.Vec, @splat(near_h[3]));
        const direction = far_h / @as(zmath.Vec, @splat(far_h[3])) - origin;
        const t = (-1 - origin[1]) / direction[1];
        const front = origin + direction * @as(zmath.Vec, @splat(t));
        // Exclude rasterization boundaries: these samples lie strictly inside
        // the foreground voxel's nearer y=-1 face, not its coplanar side face.
        if (t < 0 or t > 1 or front[0] <= 0.001 or front[0] >= 0.999 or front[2] <= 0.001 or front[2] >= 0.999) continue;
        front_face_probes += 1;
        if (isBright(target_pixel, occupied_overlay)) covered_stroke += 1;
        if (isBright(pixel, occupied_overlay)) leaked += 1;
    }
    try std.testing.expect(front_face_probes > 30);
    try std.testing.expect(covered_stroke > 20);
    try std.testing.expect(visible_stroke > 20);
    if (leaked != 0) {
        std.debug.print("outline grazing occlusion: viewport={d}, leaked {d} pixels over the foreground face\n", .{ side, leaked });
        return error.OutlineForegroundLeak;
    }
}
