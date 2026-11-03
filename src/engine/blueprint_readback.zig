//! Color/depth regression through the production blueprint renderer and shaders.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const blueprint = @import("blueprint_renderer.zig");
const Camera = @import("camera.zig").Camera;
const callbacks = @import("world_coordinate_readback.zig");

const side = 128;
const pixel_count = side * side;
const image_bytes = pixel_count * 4;
const background: [4]u8 = .{ 32, 64, 96, 255 };
const Case = enum { visible, visible_selected, hidden, hidden_selected, hidden_reference };
const cases = std.enums.values(Case);
const Image = struct { pixels: []const [4]u8, depths: []const f32 };

pub fn check(device: wgpu.Device, mapping: *callbacks.MapResponse) !void {
    const allocator = std.testing.allocator;
    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = device;
    gctx.queue = device.getQueue();
    defer gctx.queue.release();
    const pools = .{ "buffer_pool", "bind_group_pool", "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" };
    inline for (pools) |name| @field(gctx, name) = .{ .pool = try @TypeOf(@field(gctx, name).pool).initCapacity(allocator, 16) };
    defer inline for (pools) |name| @field(gctx, name).pool.deinit();
    try checkDraw(&gctx, mapping);
    // Renderer owns both pipelines and every transient binding/buffer it creates.
    inline for (pools) |name| try std.testing.expectEqual(@as(usize, 0), @field(gctx, name).pool.liveHandleCount());
}

fn checkDraw(gctx: *zgpu.GraphicsContext, mapping: *callbacks.MapResponse) !void {
    const allocator = std.testing.allocator;
    const device = gctx.device;
    var atlas_layout = @import("bind_group_layouts/regular.zig").RegularBindGroupLayout.init(gctx, .tvdim_2d);
    defer atlas_layout.deinit(gctx);
    var renderer = blueprint.Renderer.init(gctx, atlas_layout.bind_group_layout_handle, .rgba8_unorm);
    defer renderer.deinit(gctx);

    const texel_extent = wgpu.Extent3D{ .width = 1, .height = 1, .depth_or_array_layers = 1 };
    const atlas = device.createTexture(.{ .size = texel_extent, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer atlas.release();
    const atlas_view = atlas.createView(.{});
    defer atlas_view.release();
    const sampler = device.createSampler(.{});
    defer sampler.release();
    const atlas_entries = [_]wgpu.BindGroupEntry{ .{ .binding = 0, .texture_view = atlas_view, .size = 0 }, .{ .binding = 1, .sampler = sampler, .size = 0 } };
    const atlas_binding = device.createBindGroup(.{ .layout = gctx.lookupResource(atlas_layout.bind_group_layout_handle).?, .entries = &atlas_entries, .entry_count = atlas_entries.len });
    defer atlas_binding.release();
    gctx.queue.writeTexture(.{ .texture = atlas }, .{ .bytes_per_row = 4, .rows_per_image = 1 }, texel_extent, u8, &.{ 255, 255, 255, 255 });

    const layout = try @import("world_layout.zig").WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var camera = Camera.init(&layout, 1);
    // Oblique orthographic view separates front/back rails, with all geometry
    // behind the simulated foreground surface at depth 0.25 and in front of 1.
    camera.clip_from_world_chunked = zmath.identity();
    camera.clip_from_world_chunked[0][0] = 0.25;
    camera.clip_from_world_chunked[1][1] = 0.25;
    camera.clip_from_world_chunked[2] = .{ 0.06, 0.04, -0.05, 0 };
    camera.clip_from_world_chunked[3] = .{ -0.75, -0.75, 0.75, 1 };
    var instances: std.ArrayList(blueprint.Instance) = .empty;
    defer instances.deinit(allocator);
    // Miniature, full-size preview, and another instance's frame precede the
    // selected twelve rails, so a wrong first-instance/count leaks into readback.
    try instances.append(allocator, blueprint.blockInstance(&camera, .{ 128, 132, 128 }, .planks, true, false));
    try instances.append(allocator, blueprint.blockInstance(&camera, .{ 132, 132, 128 }, .dirt, false, false));
    try blueprint.appendFrame(&instances, allocator, &camera, .{ 132, 128, 128 }, .{ 2, 2, 1 });
    const selected_start: u32 = @intCast(instances.items.len);
    try blueprint.appendFrame(&instances, allocator, &camera, .{ 128, 128, 128 }, .{ 2, 2, 1 });
    try std.testing.expectEqual(@as(usize, blueprint.frame_instance_count), instances.items.len - selected_start);

    const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
    const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer color.release();
    const color_view = color.createView(.{});
    defer color_view.release();
    const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer depth.release();
    const depth_view = depth.createView(.{});
    defer depth_view.release();
    const readback = device.createBuffer(.{ .size = image_bytes * 2 * cases.len, .usage = .{ .copy_dst = true, .map_read = true } });
    defer readback.release();
    for (cases, 0..) |case, index| {
        const encoder = device.createCommandEncoder(null);
        defer encoder.release();
        const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = color_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 32.0 / 255.0, .g = 64.0 / 255.0, .b = 96.0 / 255.0, .a = 1 } }};
        const pass = encoder.beginRenderPass(.{
            .color_attachments = &attachments,
            .color_attachment_count = attachments.len,
            .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = switch (case) {
                .visible, .visible_selected => 1,
                else => 0.25,
            } },
        });
        defer pass.release();
        const reference = case == .hidden_reference;
        renderer.draw(gctx, pass, atlas_binding, &camera, if (reference) instances.items[selected_start..] else instances.items, switch (case) {
            .visible_selected, .hidden_selected => selected_start,
            .hidden_reference => 0,
            else => null,
        });
        pass.end();
        const offset = index * 2 * image_bytes;
        encoder.copyTextureToBuffer(.{ .texture = color }, .{ .buffer = readback, .layout = .{ .offset = offset, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
        encoder.copyTextureToBuffer(.{ .texture = depth, .aspect = .depth_only }, .{ .buffer = readback, .layout = .{ .offset = offset + image_bytes, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
        const command = encoder.finish(null);
        defer command.release();
        // Submit each upload/draw before Renderer.draw can overwrite its buffers.
        gctx.queue.submit(&.{command});
    }
    mapping.* = .{};
    readback.mapAsync(.{ .read = true }, 0, image_bytes * 2 * cases.len, callbacks.MapResponse.callback, mapping);
    defer readback.unmap();
    try callbacks.waitForCallback(device, &mapping.done);
    try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
    var images: [cases.len]Image = undefined;
    for (&images, 0..) |*image, index| {
        const offset = index * 2 * image_bytes;
        image.* = .{
            .pixels = readback.getConstMappedRange([4]u8, offset, pixel_count) orelse return error.NoMappedGpuResults,
            .depths = readback.getConstMappedRange(f32, offset + image_bytes, pixel_count) orelse return error.NoMappedGpuResults,
        };
    }
    const visible = images[@intFromEnum(Case.visible)];
    const visible_selected = images[@intFromEnum(Case.visible_selected)];
    const hidden = images[@intFromEnum(Case.hidden)];
    const selected = images[@intFromEnum(Case.hidden_selected)];
    const reference = images[@intFromEnum(Case.hidden_reference)];
    // Adding occluded-only rendering cannot change any visible surface or depth.
    try std.testing.expectEqualSlices([4]u8, visible.pixels, visible_selected.pixels);
    try std.testing.expectEqualSlices(f32, visible.depths, visible_selected.depths);
    // Shared storage offsets select precisely the same rails as a separate batch.
    try std.testing.expectEqualSlices([4]u8, reference.pixels, selected.pixels);
    var visible_count: usize = 0;
    var ghost_count: usize = 0;
    var quarter_blend_count: usize = 0;
    for (visible.pixels, visible.depths, hidden.pixels, hidden.depths, selected.pixels, selected.depths, reference.depths) |solid, visible_depth, absent, absent_depth, ghost, ghost_depth, reference_depth| {
        try std.testing.expectEqual(background, absent);
        try std.testing.expectEqual(@as(f32, 0.25), absent_depth);
        try std.testing.expectEqual(@as(f32, 0.25), ghost_depth);
        try std.testing.expectEqual(@as(f32, 0.25), reference_depth);
        if (visible_depth < 1) visible_count += 1;
        if (!std.meta.eql(ghost, background)) {
            ghost_count += 1;
            try std.testing.expectEqual(@as(u8, 255), ghost[3]);
            // Isolated yellow rail fragments blend at alpha .25. Some overlapping
            // rails legitimately accumulate more than one translucent fragment.
            if (solid[0] > background[0] and solid[1] > background[1]) {
                var quarter_blend = true;
                for (0..3) |channel| {
                    const expected = 0.25 * @as(f32, @floatFromInt(solid[channel])) + 0.75 * @as(f32, @floatFromInt(background[channel]));
                    if (@abs(@as(f32, @floatFromInt(ghost[channel])) - expected) > 2) quarter_blend = false;
                }
                if (quarter_blend) quarter_blend_count += 1;
            }
        }
    }
    try std.testing.expect(visible_count > 100);
    try std.testing.expect(ghost_count > 20 and ghost_count < pixel_count / 10);
    try std.testing.expect(quarter_blend_count > 5);
}
