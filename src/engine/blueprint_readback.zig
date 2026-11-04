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
    try checkCachedPreview(&gctx, mapping);
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

const BlockType = @import("voxel/voxel_chunk.zig").BlockType;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const PreviewScene = struct {
    origin: [3]u32,
    camera_chunk: @Vector(3, i32),
    size_in_chunks: [3]u32 = .{ 8, 8, 8 },
    depth_axis: ?u2 = null,
};
const preview_scenes = [_]PreviewScene{
    .{ .origin = .{ 128, 128, 128 }, .camera_chunk = .{ 4, 4, 4 } },
    .{ .origin = .{ 128, 128, 128 }, .camera_chunk = .{ 4, 4, 4 } }, // Stable warm draw.
    .{ .origin = .{ 130, 129, 128 }, .camera_chunk = .{ 4, 4, 4 } },
    .{ .origin = .{ 159, 128, 128 }, .camera_chunk = .{ 5, 4, 4 } }, // Chunk transition.
    .{ .origin = .{ 255, 128, 128 }, .camera_chunk = .{ 7, 4, 4 } }, // World seam.
    .{ .origin = .{ 159, 128, 128 }, .camera_chunk = .{ 0, 4, 4 } }, // Positive half-period tie.
    .{ .origin = .{ 255, 128, 128 }, .camera_chunk = .{ 4, 4, 4 } }, // Negative half-period tie.
    .{ .origin = .{ (1 << 31) - 32, 128, 128 }, .camera_chunk = .{ (1 << 26) - 1, 4, 4 }, .size_in_chunks = .{ 1 << 26, 8, 8 } },
    .{ .origin = .{ (1 << 31) - 1, 128, 128 }, .camera_chunk = .{ (1 << 26) - 1, 4, 4 }, .size_in_chunks = .{ 1 << 26, 8, 8 } },
    .{ .origin = .{ 0, 128, 128 }, .camera_chunk = .{ std.math.minInt(i32), 4, 4 }, .depth_axis = if (WorldLayout.wrap_x) null else 0 },
    .{ .origin = .{ 255, 128, 128 }, .camera_chunk = .{ std.math.maxInt(i32), 4, 4 }, .depth_axis = if (WorldLayout.wrap_x) null else 0 },
    .{ .origin = .{ 128, 128, 128 }, .camera_chunk = .{ 4, std.math.minInt(i32), 4 }, .depth_axis = 1 },
    .{ .origin = .{ 128, 128, 128 }, .camera_chunk = .{ 4, std.math.maxInt(i32), 4 }, .depth_axis = 1 },
    .{ .origin = .{ 128, 128, 128 }, .camera_chunk = .{ 4, 4, std.math.minInt(i32) }, .depth_axis = 2 },
    .{ .origin = .{ 128, 128, 128 }, .camera_chunk = .{ 4, 4, std.math.maxInt(i32) }, .depth_axis = 2 },
};
const preview_pair_count = preview_scenes.len * 4 + 6;

/// Submit before the next draw can overwrite renderer uniforms or dynamic instances.
const PreviewTarget = struct {
    color: wgpu.Texture,
    color_view: wgpu.TextureView,
    depth: wgpu.Texture,
    depth_view: wgpu.TextureView,
    readback: wgpu.Buffer,

    fn init(device: wgpu.Device) PreviewTarget {
        const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
        const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
        const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true, .copy_src = true } });
        return .{
            .color = color,
            .color_view = color.createView(.{}),
            .depth = depth,
            .depth_view = depth.createView(.{}),
            .readback = device.createBuffer(.{ .size = image_bytes * 4 * preview_pair_count, .usage = .{ .copy_dst = true, .map_read = true } }),
        };
    }

    fn deinit(self: PreviewTarget) void {
        self.readback.release();
        self.depth_view.release();
        self.depth.release();
        self.color_view.release();
        self.color.release();
    }

    fn draw(self: PreviewTarget, gctx: *zgpu.GraphicsContext, renderer: *blueprint.Renderer, atlas: wgpu.BindGroup, camera: *const Camera, instances: []const blueprint.Instance, selected_start: ?u32, preview: ?blueprint.Preview, cached: bool, allocator: std.mem.Allocator, clear_depth: f32, capture_index: ?usize) !void {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();
        const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = self.color_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 32.0 / 255.0, .g = 64.0 / 255.0, .b = 96.0 / 255.0, .a = 1 } }};
        const pass = encoder.beginRenderPass(.{
            .color_attachments = &attachments,
            .color_attachment_count = attachments.len,
            .depth_stencil_attachment = &.{ .view = self.depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = clear_depth },
        });
        defer pass.release();
        var draw_error: ?anyerror = null;
        if (cached) {
            renderer.drawWithPreview(gctx, pass, atlas, camera, instances, selected_start, allocator, preview) catch |err| {
                draw_error = err;
            };
        } else {
            renderer.draw(gctx, pass, atlas, camera, instances, selected_start);
        }
        pass.end();
        if (capture_index) |index| {
            const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
            const offset = index * 2 * image_bytes;
            encoder.copyTextureToBuffer(.{ .texture = self.color }, .{ .buffer = self.readback, .layout = .{ .offset = offset, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
            encoder.copyTextureToBuffer(.{ .texture = self.depth, .aspect = .depth_only }, .{ .buffer = self.readback, .layout = .{ .offset = offset + image_bytes, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
        }
        const command = encoder.finish(null);
        defer command.release();
        gctx.queue.submit(&.{command});
        if (draw_error) |err| return err;
    }

    fn image(self: PreviewTarget, index: usize) !Image {
        const offset = index * 2 * image_bytes;
        return .{
            .pixels = self.readback.getConstMappedRange([4]u8, offset, pixel_count) orelse return error.NoMappedGpuResults,
            .depths = self.readback.getConstMappedRange(f32, offset + image_bytes, pixel_count) orelse return error.NoMappedGpuResults,
        };
    }
};

fn previewCamera(layout: *const WorldLayout, scene: PreviewScene) Camera {
    var camera = Camera.init(layout, 1);
    camera.chunk = scene.camera_chunk;
    const anchor = blueprint.blockInstance(&camera, previewOriginCell(scene.origin), .planks, false, false).position;
    if (scene.depth_axis) |depth_axis| {
        // At signed camera limits one block is smaller than the f32 spacing on
        // that axis. Project the other two axes onto the screen and retain the
        // distant axis in depth: an overflowing signed delta visibly changes
        // depth without relying on subpixel geometry or huge cancellation.
        const a = (@as(usize, depth_axis) + 1) % 3;
        const b = (@as(usize, depth_axis) + 2) % 3;
        camera.clip_from_world_chunked = .{ @splat(0), @splat(0), @splat(0), @splat(0) };
        camera.clip_from_world_chunked[a][0] = 0.24;
        camera.clip_from_world_chunked[b][0] = 0.06;
        camera.clip_from_world_chunked[b][1] = 0.28;
        camera.clip_from_world_chunked[depth_axis][2] = 0x1p-38;
        camera.clip_from_world_chunked[3] = .{ -0.7 - anchor[a] * 0.24 - anchor[b] * 0.06, -0.6 - anchor[b] * 0.28, 0.5, 1 };
        return camera;
    }
    camera.clip_from_world_chunked = zmath.identity();
    camera.clip_from_world_chunked[0] = .{ 0.24, 0, 0, 0 };
    camera.clip_from_world_chunked[1] = .{ 0, 0.28, 0, 0 };
    camera.clip_from_world_chunked[2] = .{ 0.06, 0.04, -0.05, 0 };
    camera.clip_from_world_chunked[3] = .{ -0.75 - anchor[0] * 0.24 - anchor[2] * 0.06, -0.65 - anchor[1] * 0.28 - anchor[2] * 0.04, 0.75 + anchor[2] * 0.05, 1 };
    return camera;
}

fn previewOriginCell(origin: [3]u32) blueprint.Cell {
    return .{ origin[0], origin[1], origin[2] };
}

/// Independent reference: rotate cell offsets, then let the existing full-cell
/// instance path perform CPU chunk-relative and wrapping calculations.
fn appendPreviewReference(list: *std.ArrayList(blueprint.Instance), allocator: std.mem.Allocator, camera: *const Camera, preview: blueprint.Preview) !void {
    const origin = preview.origin.?;
    for (preview.cells, 0..) |material, index| {
        if (material == .none) continue;
        const x: u32 = @intCast(index % preview.size[0]);
        const y: u32 = @intCast((index / preview.size[0]) % preview.size[1]);
        const z: u32 = @intCast(index / (@as(usize, preview.size[0]) * preview.size[1]));
        const rotated: [3]u32 = switch (preview.rotation) {
            0 => .{ x, y, z },
            1 => .{ y, preview.size[0] - 1 - x, z },
            2 => .{ preview.size[0] - 1 - x, preview.size[1] - 1 - y, z },
            3 => .{ preview.size[1] - 1 - y, x, z },
        };
        const cell: blueprint.Cell = .{
            @as(i64, origin[0]) + rotated[0],
            @as(i64, origin[1]) + rotated[1],
            @as(i64, origin[2]) + rotated[2],
        };
        try list.append(allocator, blueprint.blockInstance(camera, cell, material, false, false));
    }
}

fn checkLongFrameEnd(gctx: *zgpu.GraphicsContext, renderer: *blueprint.Renderer, atlas: wgpu.BindGroup, target: PreviewTarget, pair_index: *usize) !void {
    const allocator = std.testing.allocator;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var camera = Camera.init(&layout, 1);
    camera.chunk = .{ 5, 4, 4 }; // Storage X160: the box ends nearby at X158.
    camera.clip_from_world_chunked = zmath.identity();
    camera.clip_from_world_chunked[0][0] = 0.5;
    camera.clip_from_world_chunked[1][1] = 0.5;
    camera.clip_from_world_chunked[2] = .{ 0.12, 0.08, -0.08, 0 };
    camera.clip_from_world_chunked[3] = .{ 1.4, -0.5, 0.75, 1 };
    var actual: std.ArrayList(blueprint.Instance) = .empty;
    defer actual.deinit(allocator);
    var expected: std.ArrayList(blueprint.Instance) = .empty;
    defer expected.deinit(allocator);
    const miniature = blueprint.blockInstance(&camera, .{ 157, 128, 128 }, .planks, true, false);
    try std.testing.expectEqual(@as(f32, -3 + 0.375), miniature.position[0]);
    try std.testing.expectEqual(@as(f32, -2), blueprint.blockInstance(&camera, .{ 158, 128, 128 }, .planks, false, false).position[0]);
    try actual.append(allocator, miniature);
    try blueprint.appendFrame(&actual, allocator, &camera, .{ 159, 129, 128 }, .{ 1, 1, 1 });
    try expected.appendSlice(allocator, actual.items);
    const selected_start: u32 = @intCast(actual.items.len);
    const size: [3]u32 = .{ 127, 2, 1 };
    try blueprint.appendFrame(&actual, allocator, &camera, .{ 31, 128, 128 }, size);
    // Construct the same continuous box at zero, then explicitly translate its
    // minimum to 31 - 160 = -129. Only the supported nearby end is in view.
    var zero_camera = Camera.init(&layout, 1);
    zero_camera.chunk = @splat(0);
    try blueprint.appendFrame(&expected, allocator, &zero_camera, .{ 0, 0, 0 }, size);
    for (expected.items[selected_start..]) |*rail| rail.position[0] -= 129;
    try std.testing.expectEqual(@as(u32, 12), blueprint.frame_instance_count);
    try std.testing.expectEqual(@as(u32, 13), selected_start);
    try std.testing.expectEqual(@as(usize, 12), actual.items.len - selected_start);
    try std.testing.expectEqual(actual.items.len, expected.items.len);
    for ([_]f32{ 1, 0.25 }) |clear_depth| {
        try target.draw(gctx, renderer, atlas, &camera, expected.items, selected_start, null, false, allocator, clear_depth, pair_index.* * 2);
        try target.draw(gctx, renderer, atlas, &camera, actual.items, selected_start, null, false, allocator, clear_depth, pair_index.* * 2 + 1);
        pair_index.* += 1;
    }
}

fn checkCachedPreview(gctx: *zgpu.GraphicsContext, mapping: *callbacks.MapResponse) !void {
    const allocator = std.testing.allocator;
    const device = gctx.device;
    var atlas_layout = @import("bind_group_layouts/regular.zig").RegularBindGroupLayout.init(gctx, .tvdim_2d);
    defer atlas_layout.deinit(gctx);
    var reference = blueprint.Renderer.init(gctx, atlas_layout.bind_group_layout_handle, .rgba8_unorm);
    defer reference.deinit(gctx);
    var renderer = blueprint.Renderer.init(gctx, atlas_layout.bind_group_layout_handle, .rgba8_unorm);
    defer renderer.deinit(gctx);

    // Every atlas tile has an asymmetric pattern, so rotating block vertices/UVs
    // together with cell offsets cannot accidentally pass a white-atlas test.
    const atlas_side = 256;
    var texels: [atlas_side * atlas_side][4]u8 = undefined;
    for (&texels, 0..) |*texel, index| {
        const x = index % atlas_side;
        const y = index / atlas_side;
        texel.* = .{ @intCast(32 + (13 * x + 3 * y) % 192), @intCast(32 + (5 * x + 17 * y) % 192), @intCast(32 + (19 * x + 7 * y) % 192), 255 };
    }
    const atlas_extent = wgpu.Extent3D{ .width = atlas_side, .height = atlas_side, .depth_or_array_layers = 1 };
    const atlas = device.createTexture(.{ .size = atlas_extent, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer atlas.release();
    const atlas_view = atlas.createView(.{});
    defer atlas_view.release();
    const sampler = device.createSampler(.{});
    defer sampler.release();
    const entries = [_]wgpu.BindGroupEntry{ .{ .binding = 0, .texture_view = atlas_view, .size = 0 }, .{ .binding = 1, .sampler = sampler, .size = 0 } };
    const atlas_binding = device.createBindGroup(.{ .layout = gctx.lookupResource(atlas_layout.bind_group_layout_handle).?, .entries = &entries, .entry_count = entries.len });
    defer atlas_binding.release();
    gctx.queue.writeTexture(.{ .texture = atlas }, .{ .bytes_per_row = atlas_side * 4, .rows_per_image = atlas_side }, atlas_extent, [4]u8, &texels);
    const target = PreviewTarget.init(device);
    defer target.deinit();
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    const cells = [_]BlockType{ .planks, .none, .dirt, .tree_trunk, .rebar, .none, .none, .sand, .reinforced_concrete, .planks, .none, .packed_dirt };
    var preview = blueprint.Preview{ .definition_id = 10, .generation = 20, .size = .{ 3, 2, 2 }, .cells = &cells, .target_count = 8, .rotation = 0 };
    var dynamic: std.ArrayList(blueprint.Instance) = .empty;
    defer dynamic.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var pair_index: usize = 0;
    for (0..4) |rotation| {
        preview.rotation = @intCast(rotation);
        for (preview_scenes) |scene| {
            preview.origin = scene.origin;
            const scene_layout = try WorldLayout.init(.{ .size_in_chunks = scene.size_in_chunks });
            const camera = previewCamera(&scene_layout, scene);
            dynamic.clearRetainingCapacity();
            var miniature = blueprint.blockInstance(&camera, previewOriginCell(scene.origin), .planks, true, false);
            miniature.position[0] += 4;
            miniature.position[1] += 1;
            try dynamic.append(allocator, miniature);
            const frame_size: [3]u32 = if (rotation & 1 == 0) preview.size else .{ preview.size[1], preview.size[0], preview.size[2] };
            try blueprint.appendFrame(&dynamic, allocator, &camera, previewOriginCell(scene.origin), frame_size);
            const extras = dynamic.items.len;
            try appendPreviewReference(&dynamic, allocator, &camera, preview);
            try target.draw(gctx, &reference, atlas_binding, &camera, dynamic.items, 1, null, false, allocator, 1, pair_index * 2);
            try target.draw(gctx, &renderer, atlas_binding, &camera, dynamic.items[0..extras], 1, preview, true, if (pair_index == 0) allocator else failing.allocator(), 1, pair_index * 2 + 1);
            const stats = renderer.previewCacheStats();
            try std.testing.expectEqual(@as(u64, 1), stats.cache_builds);
            try std.testing.expectEqual(@as(u64, 8 * 16), stats.source_upload_bytes);
            try std.testing.expectEqual(@as(u64, 0), stats.cache_releases);
            try std.testing.expectEqual(@as(u32, 8), stats.cached_instances);
            pair_index += 1;
        }
    }

    try checkLongFrameEnd(gctx, &reference, atlas_binding, target, &pair_index);

    const camera = previewCamera(&layout, preview_scenes[0]);
    preview.origin = preview_scenes[0].origin;
    preview.rotation = 0;
    dynamic.clearRetainingCapacity();
    try appendPreviewReference(&dynamic, allocator, &camera, preview);
    // A cached preview also draws when there are no dynamic instances at all.
    try target.draw(gctx, &reference, atlas_binding, &camera, dynamic.items, null, null, false, allocator, 1, pair_index * 2);
    try target.draw(gctx, &renderer, atlas_binding, &camera, &.{}, null, preview, true, failing.allocator(), 1, pair_index * 2 + 1);
    pair_index += 1;
    dynamic.clearRetainingCapacity();
    try dynamic.append(allocator, blueprint.blockInstance(&camera, .{ 132, 132, 128 }, .planks, true, false));
    try blueprint.appendFrame(&dynamic, allocator, &camera, .{ 128, 128, 128 }, preview.size);
    // Cached preview must never enter the selected rails' faint occluded pass.
    try target.draw(gctx, &reference, atlas_binding, &camera, dynamic.items, 1, null, false, allocator, 0.25, pair_index * 2);
    try target.draw(gctx, &renderer, atlas_binding, &camera, dynamic.items, 1, preview, true, failing.allocator(), 0.25, pair_index * 2 + 1);
    pair_index += 1;
    // An unavailable origin hides geometry while retaining the cached source.
    preview.origin = null;
    try target.draw(gctx, &reference, atlas_binding, &camera, dynamic.items, 1, null, false, allocator, 1, pair_index * 2);
    try target.draw(gctx, &renderer, atlas_binding, &camera, dynamic.items, 1, preview, true, failing.allocator(), 1, pair_index * 2 + 1);
    pair_index += 1;
    try std.testing.expectEqual(@as(usize, preview_pair_count - 1), pair_index);
    try std.testing.expectEqual(@as(u64, 1), renderer.previewCacheStats().cache_builds);
    try std.testing.expectEqual(@as(u64, 8 * 16), renderer.previewCacheStats().source_upload_bytes);
    try std.testing.expectEqual(@as(u32, 8), renderer.previewCacheStats().cached_instances);
    try std.testing.expect(!failing.has_induced_failure);

    // Definition and scene-generation changes independently invalidate one cache.
    preview.origin = preview_scenes[0].origin;
    preview.definition_id += 1;
    try target.draw(gctx, &renderer, atlas_binding, &camera, &.{}, null, preview, true, allocator, 1, null);
    try std.testing.expectEqual(@as(u64, 2), renderer.previewCacheStats().cache_builds);
    try std.testing.expectEqual(@as(u64, 1), renderer.previewCacheStats().cache_releases);
    preview.generation += 1;
    try target.draw(gctx, &renderer, atlas_binding, &camera, &.{}, null, preview, true, allocator, 1, null);
    try std.testing.expectEqual(@as(u64, 3), renderer.previewCacheStats().cache_builds);
    try std.testing.expectEqual(@as(u64, 3 * 8 * 16), renderer.previewCacheStats().source_upload_bytes);
    try std.testing.expectEqual(@as(u64, 2), renderer.previewCacheStats().cache_releases);
    for (0..2) |_| try target.draw(gctx, &renderer, atlas_binding, &camera, &.{}, null, null, true, failing.allocator(), 1, null);
    try std.testing.expectEqual(@as(u32, 0), renderer.previewCacheStats().cached_instances);
    try std.testing.expectEqual(@as(u64, 3), renderer.previewCacheStats().cache_releases);
    try target.draw(gctx, &renderer, atlas_binding, &camera, &.{}, null, preview, true, allocator, 1, null);
    try std.testing.expectEqual(@as(u64, 4), renderer.previewCacheStats().cache_builds);
    try std.testing.expectEqual(@as(u64, 4 * 8 * 16), renderer.previewCacheStats().source_upload_bytes);
    try std.testing.expectEqual(@as(u32, 8), renderer.previewCacheStats().cached_instances);

    // Replacement allocation failure clears the previous definition before
    // rendering dynamic miniatures/rails; it cannot leave an old preview behind.
    preview.generation += 1;
    try target.draw(gctx, &reference, atlas_binding, &camera, dynamic.items, 1, null, false, allocator, 1, pair_index * 2);
    try std.testing.expectError(error.OutOfMemory, target.draw(gctx, &renderer, atlas_binding, &camera, dynamic.items, 1, preview, true, failing.allocator(), 1, pair_index * 2 + 1));
    pair_index += 1;
    try std.testing.expectEqual(@as(usize, preview_pair_count), pair_index);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 4), renderer.previewCacheStats().cache_builds);
    try std.testing.expectEqual(@as(u64, 4), renderer.previewCacheStats().cache_releases);
    try std.testing.expectEqual(@as(u32, 0), renderer.previewCacheStats().cached_instances);

    var budget_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var oversized = preview;
    oversized.target_count = blueprint.capacity + 1;
    try std.testing.expectError(error.PreviewCapacityExceeded, target.draw(gctx, &renderer, atlas_binding, &camera, dynamic.items, 1, oversized, true, budget_allocator.allocator(), 1, null));
    try std.testing.expect(!budget_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 4), renderer.previewCacheStats().cache_builds);
    try std.testing.expectEqual(@as(u64, 4), renderer.previewCacheStats().cache_releases);
    try std.testing.expectEqual(@as(u32, 0), renderer.previewCacheStats().cached_instances);
    // Recover after both errors and leave a live cache for the deinit leak check.
    try target.draw(gctx, &renderer, atlas_binding, &camera, &.{}, null, preview, true, allocator, 1, null);
    try std.testing.expectEqual(@as(u64, 5), renderer.previewCacheStats().cache_builds);
    try std.testing.expectEqual(@as(u64, 5 * 8 * 16), renderer.previewCacheStats().source_upload_bytes);
    try std.testing.expectEqual(@as(u32, 8), renderer.previewCacheStats().cached_instances);

    mapping.* = .{};
    target.readback.mapAsync(.{ .read = true }, 0, image_bytes * 4 * preview_pair_count, callbacks.MapResponse.callback, mapping);
    defer target.readback.unmap();
    try callbacks.waitForCallback(device, &mapping.done);
    try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
    for (0..preview_pair_count) |index| {
        errdefer std.debug.print("cached blueprint readback mismatch in pair {d} (rotation {d}, scene {d})\n", .{ index, index / preview_scenes.len, index % preview_scenes.len });
        const expected = try target.image(index * 2);
        const actual = try target.image(index * 2 + 1);
        try std.testing.expectEqualSlices([4]u8, expected.pixels, actual.pixels);
        try std.testing.expectEqualSlices(f32, expected.depths, actual.depths);
        var changed: usize = 0;
        for (expected.pixels) |pixel| if (!std.meta.eql(pixel, background)) {
            changed += 1;
        };
        try std.testing.expect(changed > 20);
        if (index == preview_scenes.len * 4 + 1 or index == preview_pair_count - 3) for (actual.depths) |depth| try std.testing.expectEqual(@as(f32, 0.25), depth);
    }
}
