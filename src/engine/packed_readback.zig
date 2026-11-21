//! Production packed pipelines: opaque coverage, real holes, interior straps,
//! scene occlusion, directional shadow sampling/casting and global batch churn.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const cargo = @import("packed_renderer.zig");
const callbacks = @import("world_coordinate_readback.zig");
const Layouts = @import("bind_group_layouts.zig").BindGroupLayouts;
const WorldLayout = @import("world_layout.zig").WorldLayout;
const side = 128;
const pixels = side * side;
const bytes = pixels * 4;
const background = [4]u8{ 32, 64, 96, 255 };
const Case = enum { cube_front, cube_top, cube_hidden, cube_shadowed, cube_seam, packaging_front, packaging_inside, packaging_top, pallet_top, road_top, cargo_pallet_top, marker, stopped_marker, cube_oblique, road_oblique, cargo_pallet_oblique, marker_oblique, stopped_oblique, mixed_batch, shadow_pallet, shadow_front, shadow_inside, shadow_top };
const cases = std.enums.values(Case);

pub fn check(device: wgpu.Device, mapping: *callbacks.MapResponse) !void {
    const allocator = std.testing.allocator;
    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = device;
    gctx.queue = device.getQueue();
    defer gctx.queue.release();
    const pools = .{ "buffer_pool", "bind_group_pool", "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" };
    inline for (pools) |name| @field(gctx, name) = .{ .pool = try @TypeOf(@field(gctx, name).pool).initCapacity(allocator, 32) };
    defer inline for (pools) |name| @field(gctx, name).pool.deinit();
    try checkOwned(&gctx, mapping, false);
    if (std.c.getenv("PACKED_RENDER_REAL_ATLAS") != null) try checkOwned(&gctx, mapping, true);
    inline for (pools) |name| try std.testing.expectEqual(@as(usize, 0), @field(gctx, name).pool.liveHandleCount());
}

fn checkOwned(gctx: *zgpu.GraphicsContext, mapping: *callbacks.MapResponse, real_atlas: bool) !void {
    const allocator = std.testing.allocator;
    const device = gctx.device;
    var layouts: Layouts = undefined;
    layouts.scene = .init(gctx);
    defer layouts.scene.deinit(gctx);
    layouts.regular = .init(gctx, .tvdim_2d);
    defer layouts.regular.deinit(gctx);
    layouts.shadow_map = .init(gctx);
    defer layouts.shadow_map.deinit(gctx);
    const world = try WorldLayout.init(.{ .size_in_chunks = .{ 131072, 2, 2 } });
    var renderer = try cargo.Renderer.init(allocator, gctx, &world, &layouts);
    defer renderer.deinit(gctx);
    if (!real_atlas) {
        try checkDenseChanges(&renderer, gctx);
        try measureUpdates(&renderer, gctx);
        try std.testing.checkAllAllocationFailures(allocator, checkAllocationFailures, .{ gctx, &world, &layouts });
    }

    const clip_buffer = buffer(device, 64, .{ .uniform = true, .copy_dst = true });
    defer clip_buffer.release();
    const view_buffer = buffer(device, 64, .{ .uniform = true, .copy_dst = true });
    defer view_buffer.release();
    const origin_buffer = buffer(device, 16, .{ .uniform = true, .copy_dst = true });
    defer origin_buffer.release();
    const settings_buffer = buffer(device, 16, .{ .uniform = true, .copy_dst = true });
    defer settings_buffer.release();
    const dummy_instances = buffer(device, 80, .{ .storage = true });
    defer dummy_instances.release();
    const origin = [4]i32{ world.size_in_chunks[0] - 1, 1, 1, 0 };
    gctx.queue.writeBuffer(origin_buffer, 0, [4]i32, &.{origin});
    gctx.queue.writeBuffer(view_buffer, 0, zmath.Mat, &.{zmath.identity()});
    const scene_entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .buffer = clip_buffer, .size = 64 },
        .{ .binding = 1, .buffer = view_buffer, .size = 64 },
        .{ .binding = 2, .buffer = dummy_instances, .size = 80 },
        .{ .binding = 3, .buffer = settings_buffer, .size = 4 },
        .{ .binding = 4, .buffer = clip_buffer, .size = 64 },
        .{ .binding = 5, .buffer = origin_buffer, .size = 12 },
    };
    const scene_binding = device.createBindGroup(.{ .layout = gctx.lookupResource(layouts.scene.bind_group_layout_handle).?, .entries = &scene_entries, .entry_count = scene_entries.len });
    defer scene_binding.release();
    const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
    const atlas_extent = if (real_atlas) wgpu.Extent3D{ .width = 1024, .height = 1024, .depth_or_array_layers = 1 } else extent;
    const atlas = device.createTexture(.{ .size = atlas_extent, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer atlas.release();
    const atlas_view = atlas.createView(.{});
    defer atlas_view.release();
    const sampler = device.createSampler(.{});
    defer sampler.release();
    var atlas_pixels: [pixels][4]u8 = @splat(.{ 40, 120, 210, 255 });
    for (0..side) |y| for (24..31) |x| {
        atlas_pixels[y * side + x] = .{ 180, 100, 40, 255 };
    };
    if (real_atlas) {
        const zstbi = @import("zstbi");
        zstbi.init(std.testing.io, allocator);
        defer zstbi.deinit();
        var image = try @import("gltf_loader").StbiWrapper.loadTextureData(allocator, "content/minecraft.png", .{});
        defer image.deinit();
        try std.testing.expectEqual(@as(u32, 1024), image.width);
        try std.testing.expectEqual(@as(u32, 1024), image.height);
        gctx.queue.writeTexture(.{ .texture = atlas }, .{ .bytes_per_row = 1024 * 4, .rows_per_image = 1024 }, atlas_extent, u8, image.data);
    } else gctx.queue.writeTexture(.{ .texture = atlas }, .{ .bytes_per_row = side * 4, .rows_per_image = side }, extent, [4]u8, &atlas_pixels);
    const atlas_entries = [_]wgpu.BindGroupEntry{ .{ .binding = 0, .texture_view = atlas_view, .size = 0 }, .{ .binding = 1, .sampler = sampler, .size = 0 } };
    const atlas_binding = device.createBindGroup(.{ .layout = gctx.lookupResource(layouts.regular.bind_group_layout_handle).?, .entries = &atlas_entries, .entry_count = atlas_entries.len });
    defer atlas_binding.release();
    const light_buffer = buffer(device, 192, .{ .uniform = true, .copy_dst = true });
    defer light_buffer.release();
    var light_matrix = zmath.identity();
    light_matrix[0][0] = 0;
    light_matrix[1][1] = 0;
    light_matrix[2][2] = 0;
    light_matrix[3][2] = 0.5;
    gctx.queue.writeBuffer(light_buffer, 0, zmath.Mat, &.{ light_matrix, light_matrix, light_matrix });
    const light_extent = wgpu.Extent3D{ .width = 1, .height = 1, .depth_or_array_layers = 3 };
    const light_texture = device.createTexture(.{ .size = light_extent, .format = .r32_float, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer light_texture.release();
    const light_view = light_texture.createView(.{ .dimension = .tvdim_2d_array, .array_layer_count = 3 });
    defer light_view.release();
    const light_entries = [_]wgpu.BindGroupEntry{ .{ .binding = 0, .buffer = light_buffer, .size = 192 }, .{ .binding = 1, .texture_view = light_view, .size = 0 }, .{ .binding = 2, .sampler = sampler, .size = 0 } };
    const light_binding = device.createBindGroup(.{ .layout = gctx.lookupResource(layouts.shadow_map.bind_group_layout_handle).?, .entries = &light_entries, .entry_count = light_entries.len });
    defer light_binding.release();

    const color = device.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer color.release();
    const color_view = color.createView(.{});
    defer color_view.release();
    const normal = device.createTexture(.{ .size = extent, .format = .rgb10_a2_unorm, .usage = .{ .render_attachment = true } });
    defer normal.release();
    const normal_view = normal.createView(.{});
    defer normal_view.release();
    const depth = device.createTexture(.{ .size = extent, .format = .depth32_float, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer depth.release();
    const depth_view = depth.createView(.{});
    defer depth_view.release();
    const shadow_color = device.createTexture(.{ .size = extent, .format = .r32_float, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer shadow_color.release();
    const shadow_view = shadow_color.createView(.{});
    defer shadow_view.release();
    const mapped = buffer(device, bytes * 2 * cases.len, .{ .copy_dst = true, .map_read = true });
    defer mapped.release();
    var faces: [6]cargo.Face = undefined;
    for (&faces, 0..) |*face, direction| face.* = .{ .local = .{ 0, 0, 0 }, .material = 2, .direction = @intCast(direction) };
    const item = cargo.Instance{ .local = .{ 0, 0, 0 }, .material = 14 };
    const pallet_item = cargo.Instance{ .local = .{ 0, 0, 0 }, .material = 23 };
    for (cases, 0..) |case, index| {
        const top = switch (case) {
            .cube_top, .packaging_top, .pallet_top, .road_top, .cargo_pallet_top, .marker, .stopped_marker, .shadow_pallet, .shadow_top => true,
            else => false,
        };
        const inside = case == .packaging_inside or case == .shadow_inside;
        const shadow = case == .shadow_pallet or case == .shadow_front or case == .shadow_inside or case == .shadow_top;
        const oblique = case == .cube_oblique or case == .road_oblique or case == .cargo_pallet_oblique or case == .marker_oblique or case == .stopped_oblique;
        var matrix: zmath.Mat = @splat(@splat(0));
        matrix[0][0] = 1.6;
        matrix[3] = .{ -0.8, -0.8, 0.25, 1 };
        if (top) {
            matrix[1][1] = 1.6;
            matrix[2][2] = -0.5;
            matrix[3][2] = 0.8;
        } else {
            matrix[2][1] = 1.6;
            matrix[1][2] = if (inside) 0.8 else 0.5;
            if (inside) matrix[3][2] = -0.4;
        }
        if (oblique) {
            matrix[0] = .{ 1.1, 0.25, 0.15, 0 };
            matrix[1] = .{ -0.6, 0.35, 0.25, 0 };
            matrix[2] = .{ 0, 1.0, -0.25, 0 };
            matrix[3] = .{ -0.25, -0.8, 0.5, 1 };
        }
        var source_chunk = @Vector(3, i32){ origin[0], origin[1], origin[2] };
        var camera_chunk = origin;
        if (case == .cube_seam) {
            if (comptime WorldLayout.wrap_x) source_chunk[0] = 0 else camera_chunk[0] -= 1;
            matrix[3][0] -= 32 * 1.6;
        }
        const warehouse_case = case == .mixed_batch or case == .shadow_top;
        if (warehouse_case) {
            camera_chunk[0] = 0;
            source_chunk[0] = 0;
            renderer.clear(gctx);
        }
        if (case == .mixed_batch) matrix[0][0] = 0.8;
        gctx.queue.writeBuffer(origin_buffer, 0, [4]i32, &.{camera_chunk});
        gctx.queue.writeBuffer(clip_buffer, 0, zmath.Mat, &.{matrix});
        const light_depth: f32 = if (case == .cube_shadowed) 0 else 1;
        gctx.queue.writeTexture(.{ .texture = light_texture }, .{ .bytes_per_row = 4, .rows_per_image = 1 }, light_extent, f32, &.{ light_depth, light_depth, light_depth });
        var source = cargo.Source{ .chunk = source_chunk, .revision = index + 1 };
        switch (case) {
            .cube_front, .cube_top, .cube_hidden, .cube_shadowed, .cube_oblique, .cube_seam => source.faces = &faces,
            .packaging_front, .packaging_inside, .packaging_top, .shadow_front, .shadow_inside, .shadow_top => source.packaging = &.{item},
            .pallet_top, .shadow_pallet => source.pallets = &.{pallet_item},
            .road_top => source.models = &.{item},
            .cargo_pallet_top => source.models = &.{pallet_item},
            .road_oblique => {
                source.models = &.{item};
                source.packaging = &.{item};
            },
            .cargo_pallet_oblique => {
                source.models = &.{pallet_item};
                source.packaging = &.{pallet_item};
            },
            .marker_oblique, .stopped_oblique => {
                source.pallets = &.{pallet_item};
                source.markers = &.{.{ .local = .{ 0, 0, 0 }, .material = 2, .disabled = @intFromBool(case == .stopped_oblique) }};
            },
            .mixed_batch => {
                source.models = &.{item};
                source.packaging = &.{item};
            },
            .marker, .stopped_marker => {
                source.pallets = &.{pallet_item};
                source.markers = &.{.{ .local = .{ 0, 0, 0 }, .material = 2, .disabled = @intFromBool(case == .stopped_marker) }};
            },
        }
        renderer.removeSource(gctx, 2);
        renderer.removeSource(gctx, 5);
        renderer.removeSource(gctx, 6);
        if (case == .mixed_batch) try renderer.upsertSource(gctx, 2, .{ .chunk = source.chunk, .revision = index + 1, .models = &.{.{ .local = .{ 1, 0, 0 }, .material = 23 }}, .packaging = &.{.{ .local = .{ 1, 0, 0 }, .material = 23 }} });
        var boxes: [2]cargo.Group = undefined;
        const warehouse_packaging = [_]cargo.Instance{ item, .{ .local = .{ 3, 4, 5 }, .material = 14 }, .{ .local = .{ 25, 25, 25 }, .material = 14 } };
        if (warehouse_case) {
            var previous = source.chunk;
            previous[0] = if (WorldLayout.wrap_x) world.size_in_chunks[0] - 1 else -1;
            const body = cargo.Box{ .chunk = previous, .local = .{ 31, 0, 0 }, .extent = .{ 5, 5, 6 } };
            // A second chunk piece of the same warehouse, outside the viewport.
            try renderer.upsertSource(gctx, 5, .{ .chunk = previous, .revision = 1, .packaging = &.{.{ .local = .{ 31, 4, 5 }, .material = 14 }}, .groups = &.{.{ .box = body, .counts = .{ 0, 0, 1, 0, 0 } }} });
            // This warehouse shares the visible chunk and sits between the
            // visible pieces in the GPU buffer, but its entire box is outside.
            try renderer.upsertSource(gctx, 6, .{
                .chunk = source.chunk,
                .revision = 1,
                .packaging = &.{.{ .local = .{ 10, 10, 10 }, .material = 14 }},
                .groups = &.{.{ .box = .{ .chunk = source.chunk, .local = .{ 10, 10, 10 }, .extent = .{ 5, 5, 6 } }, .counts = .{ 0, 0, 1, 0, 0 } }},
            });
            source.packaging = &warehouse_packaging;
            boxes = .{
                .{ .box = body, .counts = .{ 0, @intCast(source.models.len), 2, 0, 0 } },
                .{ .box = .{ .chunk = source.chunk, .local = .{ 25, 25, 25 }, .extent = .{ 1, 1, 6 } }, .counts = .{ 0, 0, 1, 0, 0 } },
            };
            source.groups = &boxes;
        }
        try renderer.upsertSource(gctx, 1, source);
        renderer.upload(gctx);
        const encoder = device.createCommandEncoder(null);
        defer encoder.release();
        const color_attachments = [_]wgpu.RenderPassColorAttachment{
            .{ .view = if (shadow) shadow_view else color_view, .load_op = .clear, .store_op = .store, .clear_value = if (shadow) .{ .r = 1, .g = 1, .b = 1, .a = 1 } else .{ .r = 32.0 / 255.0, .g = 64.0 / 255.0, .b = 96.0 / 255.0, .a = 1 } },
            .{ .view = normal_view, .load_op = .clear, .store_op = .store },
        };
        const pass = encoder.beginRenderPass(.{ .color_attachments = &color_attachments, .color_attachment_count = if (shadow) 1 else 2, .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = if (case == .cube_hidden) 0.1 else 1 } });
        defer pass.release();
        pass.setBindGroup(0, scene_binding, &.{ 0, 0, 0, 0, 0 });
        pass.setBindGroup(1, atlas_binding, &.{});
        // Match Engine.draw: shadow passes receive scene + atlas only. Binding
        // the sampled shadow map while writing it would create a feedback hazard.
        if (!shadow) pass.setBindGroup(2, light_binding, &.{0});
        const before = renderer.stats();
        const View = @import("chunk_visibility.zig").View;
        const view = View.init(&world, .{ camera_chunk[0], camera_chunk[1], camera_chunk[2] }, matrix);
        if (warehouse_case) {
            var empty = view;
            empty.origin[2] += 200;
            renderer.draw(gctx, pass, shadow, &empty);
            try std.testing.expectEqual(before.vertex_invocations, renderer.stats().vertex_invocations);
        }
        renderer.draw(gctx, pass, shadow, &view);
        if (warehouse_case) {
            const after = renderer.stats();
            try std.testing.expectEqual(before.source_upload_bytes, after.source_upload_bytes);
            try std.testing.expectEqual(if (shadow) @as(u64, 2) else 3, after.draw_calls + after.shadow_draw_calls - before.draw_calls - before.shadow_draw_calls);
            // Both cross-chunk pieces survive. The invisible warehouses in the
            // middle and at the end contribute no vertices in either pass.
            const expected: u64 = if (shadow) 3 * cargo.packaging_vertex_count else 2 * cargo.model_vertex_count + 4 * cargo.packaging_vertex_count;
            try std.testing.expectEqual(expected, after.vertex_invocations - before.vertex_invocations);
        }
        pass.end();
        encoder.copyTextureToBuffer(.{ .texture = if (shadow) shadow_color else color }, .{ .buffer = mapped, .layout = .{ .offset = index * bytes * 2, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
        encoder.copyTextureToBuffer(.{ .texture = depth, .aspect = .depth_only }, .{ .buffer = mapped, .layout = .{ .offset = index * bytes * 2 + bytes, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
        const commands = encoder.finish(null);
        defer commands.release();
        gctx.queue.submit(&.{commands});
    }
    mapping.* = .{};
    mapped.mapAsync(.{ .read = true }, 0, bytes * 2 * cases.len, callbacks.MapResponse.callback, mapping);
    defer mapped.unmap();
    try callbacks.waitForCallback(device, &mapping.done);
    try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
    const results = mapped.getConstMappedRange(u8, 0, bytes * 2 * cases.len) orelse return error.NoMappedGpuResults;
    if (!real_atlas) try inspect(results);
    if (std.c.getenv("PACKED_RENDER_ARTIFACT_DIR")) |path| try writeArtifacts(std.mem.span(path), results, real_atlas);
    const stats = renderer.stats();
    std.debug.print("Packed GPU cases={d}, draws={d}+{d}shadow, uploads={d}B/{d}calls, moved={d}, GPUcapacity={d}B, CPUcapacity~{d}B\n", .{ cases.len, stats.draw_calls, stats.shadow_draw_calls, stats.source_upload_bytes, stats.source_upload_calls, stats.moved_records, stats.gpu_capacity_bytes, stats.cpu_capacity_bytes });
}

fn writeArtifacts(directory: []const u8, data: []const u8, real_atlas: bool) !void {
    const allocator = std.testing.allocator;
    for (cases) |case| {
        if (@intFromEnum(case) >= @intFromEnum(Case.shadow_pallet)) continue;
        const image = try allocator.alloc(u8, 15 + pixels * 3);
        defer allocator.free(image);
        @memcpy(image[0..15], "P6\n128 128\n255\n");
        const input = data[@as(usize, @intFromEnum(case)) * bytes * 2 ..][0..bytes];
        for (0..pixels) |index| @memcpy(image[15 + index * 3 ..][0..3], input[index * 4 ..][0..3]);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}{s}.ppm", .{ directory, @tagName(case), if (WorldLayout.wrap_x) "wrapped" else "finite", if (real_atlas) "-content" else "" });
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = image });
    }
}

fn checkAllocationFailures(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, world: *const WorldLayout, layouts: *const Layouts) !void {
    var renderer = try cargo.Renderer.init(allocator, gctx, world, layouts);
    defer renderer.deinit(gctx);
    try renderer.upsertSource(gctx, 1, .{ .chunk = .{ 0, 0, 0 }, .revision = 1, .faces = &.{.{ .local = .{ 0, 0, 0 }, .material = 2, .direction = 5 }} });
    renderer.upload(gctx);
    var faces: [32]cargo.Face = undefined;
    for (&faces, 0..) |*face, index| face.* = .{ .local = .{ @intCast(index), 0, 0 }, .material = 10, .direction = 5 };
    const old_buffer = renderer.faces.buffer;
    renderer.upsertSource(gctx, 1, .{ .chunk = .{ 0, 0, 0 }, .revision = 2, .faces = &faces, .models = &.{.{ .local = .{ 0, 0, 0 }, .material = 14 }} }) catch |err| {
        try std.testing.expectEqual(@as(u64, 1), renderer.sources.get(1).?.revision);
        try std.testing.expectEqual(@as(usize, 1), renderer.faces.entries.items.len);
        try std.testing.expectEqual(@as(u32, 2), renderer.faces.entries.items[0].material);
        // A later category can fail after an earlier buffer has grown. Its
        // replacement binding must remain valid and reupload the old records.
        renderer.upload(gctx);
        try std.testing.expect(gctx.isResourceValid(renderer.binding));
        try std.testing.expect(gctx.isResourceValid(renderer.faces.buffer));
        if (renderer.faces.buffer.id != old_buffer.id) try std.testing.expect(!renderer.faces.replaced);
        return err;
    };
    renderer.upload(gctx);
    try std.testing.expectEqual(@as(u64, 2), renderer.sources.get(1).?.revision);
    try std.testing.expectEqual(@as(usize, 32), renderer.faces.entries.items.len);
}

fn buffer(device: wgpu.Device, size: u64, usage: wgpu.BufferUsage) wgpu.Buffer {
    return device.createBuffer(.{ .size = size, .usage = usage });
}
fn pixel(x: f32, y: f32) usize {
    const px: usize = @intFromFloat((0.1 + 0.8 * x) * side);
    const py: usize = @intFromFloat((0.9 - 0.8 * y) * side);
    return py * side + px;
}
fn colorAt(data: []const u8, case: Case, x: f32, y: f32) [4]u8 {
    return data[@as(usize, @intFromEnum(case)) * bytes * 2 + pixel(x, y) * 4 ..][0..4].*;
}
fn floatAt(data: []const u8, case: Case, x: f32, y: f32, depth: bool) f32 {
    return @bitCast(data[@as(usize, @intFromEnum(case)) * bytes * 2 + (if (depth) @as(usize, bytes) else 0) + pixel(x, y) * 4 ..][0..4].*);
}
fn inspect(data: []const u8) !void {
    const resource = colorAt(data, .cube_front, 0.25, 0.7);
    try std.testing.expectEqual(resource, colorAt(data, .cube_seam, 0.25, 0.7));
    try std.testing.expectEqual(floatAt(data, .cube_front, 0.25, 0.7, true), floatAt(data, .cube_seam, 0.25, 0.7, true));
    try std.testing.expect(resource[2] > resource[1] and resource[1] > resource[0]);
    const wood = colorAt(data, .cube_front, 0.25, 0.17);
    try std.testing.expect(wood[0] > wood[1] and wood[1] > wood[2]);
    const strap = colorAt(data, .cube_front, 0.5, 0.7);
    try std.testing.expect(strap[0] < 50 and strap[2] < 60);
    try std.testing.expect(floatAt(data, .cube_front, 0.25, 0.7, true) < 1);
    try std.testing.expectEqual(background, colorAt(data, .cube_hidden, 0.25, 0.7));
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), floatAt(data, .cube_hidden, 0.25, 0.7, true), 1e-5);
    const shaded = colorAt(data, .cube_shadowed, 0.25, 0.7);
    for (0..3) |axis| try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(resource[axis])) / 2, @as(f32, @floatFromInt(shaded[axis])), 1);
    for ([_]Case{ .packaging_front, .packaging_inside }) |case| {
        try std.testing.expectEqual(background, colorAt(data, case, 0.25, 0.7));
        try std.testing.expectEqual(@as(f32, 1), floatAt(data, case, 0.25, 0.7, true));
        try std.testing.expect(floatAt(data, case, 0.5, 0.7, true) < 1);
        try std.testing.expectEqual(strap, colorAt(data, case, 0.5, 0.7));
    }
    try std.testing.expectEqual(background, colorAt(data, .packaging_top, 0.3, 0.185));
    try std.testing.expect(floatAt(data, .packaging_top, 0.5, 0.8, true) < 1);
    try std.testing.expectEqual(background, colorAt(data, .pallet_top, 0.3, 0.185));
    try std.testing.expect(floatAt(data, .pallet_top, 0.3, 0.08, true) < 1);
    try std.testing.expect(floatAt(data, .road_top, 0.3, 0.3, true) < 0.5);
    try std.testing.expect(floatAt(data, .cargo_pallet_top, 0.3, 0.12, true) < 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8 - 0.59 * 0.5), floatAt(data, .cargo_pallet_top, 0.3, 0.12, true), 1e-5);
    // Centered90% cargo pallet is floating at its original model's scaled z.
    try std.testing.expectEqual(background, colorAt(data, .cargo_pallet_top, 0.025, 0.08));
    const icon = colorAt(data, .marker, 0.5, 0.5);
    const stopped = colorAt(data, .stopped_marker, 0.5, 0.5);
    try std.testing.expect(icon[2] > icon[0]);
    try std.testing.expect(stopped[0] > 180 and stopped[1] < 30);
    const stopped_background = colorAt(data, .stopped_marker, 0.38, 0.45);
    try std.testing.expect(stopped_background[0] > stopped_background[2]);
    try std.testing.expect(floatAt(data, .mixed_batch, 0.15, 0.5, true) < 1);
    try std.testing.expect(floatAt(data, .mixed_batch, 0.65, 0.56, true) < 1);
    for ([_]Case{ .shadow_front, .shadow_inside }) |case| {
        try std.testing.expectEqual(@as(f32, 1), floatAt(data, case, 0.25, 0.7, false));
        try std.testing.expect(floatAt(data, case, 0.5, 0.7, false) < 1);
        try std.testing.expectEqual(floatAt(data, case, 0.5, 0.7, true), floatAt(data, case, 0.5, 0.7, false));
    }
    try std.testing.expectEqual(@as(f32, 1), floatAt(data, .shadow_top, 0.3, 0.185, false));
    try std.testing.expect(floatAt(data, .shadow_top, 0.5, 0.8, false) < 1);
    try std.testing.expectEqual(@as(f32, 1), floatAt(data, .shadow_pallet, 0.3, 0.185, false));
    try std.testing.expect(floatAt(data, .shadow_pallet, 0.3, 0.08, false) < 1);
    try std.testing.expectEqual(floatAt(data, .shadow_pallet, 0.3, 0.08, true), floatAt(data, .shadow_pallet, 0.3, 0.08, false));
}

fn measureUpdates(renderer: *cargo.Renderer, gctx: *zgpu.GraphicsContext) !void {
    const source_count = 128;
    const per_source = 256;
    var items: [per_source]cargo.Instance = undefined;
    for (&items, 0..) |*item, i| item.* = .{ .local = .{ @intCast(i % 16), @intCast(i / 16), 0 }, .material = if (i % 2 == 0) 14 else 23 };
    const started = std.Io.Clock.awake.now(std.testing.io);
    for (0..source_count) |id| try renderer.upsertSource(gctx, id + 1, .{ .chunk = .{ @intCast(id), 1, 1 }, .revision = 1, .models = &items, .packaging = &items });
    renderer.upload(gctx);
    const initialized_ns = started.durationTo(std.Io.Clock.awake.now(std.testing.io)).nanoseconds;
    const before = renderer.stats();
    const update_started = std.Io.Clock.awake.now(std.testing.io);
    try renderer.upsertSource(gctx, 1, .{ .chunk = .{ 0, 1, 1 }, .revision = 2, .models = items[0..255], .packaging = items[0..255] });
    renderer.upload(gctx);
    const update_ns = update_started.durationTo(std.Io.Clock.awake.now(std.testing.io)).nanoseconds;
    const after = renderer.stats();
    const model_count = source_count * per_source;
    // Localized replacement never uploads unchanged source geometry wholesale.
    try std.testing.expect(after.source_upload_bytes - before.source_upload_bytes < model_count * @sizeOf(cargo.GPU_Instance));
    std.debug.print("Packed batch {d}sources/{d}irregular: initCPU+queue={d}us, replace256->255CPU+queue={d}us/{d}B/{d}calls, GPU={d}B CPU~{d}B, VS/pass={d} (adaptive template overhead={d})\n", .{
        source_count,                                           model_count,              @divTrunc(initialized_ns, 1000), @divTrunc(update_ns, 1000),                                              after.source_upload_bytes - before.source_upload_bytes,
        after.source_upload_calls - before.source_upload_calls, after.gpu_capacity_bytes, after.cpu_capacity_bytes,        model_count * (cargo.model_vertex_count + cargo.packaging_vertex_count), (model_count / 2) * (cargo.model_vertex_count - 198),
    });
    renderer.clear(gctx);
}

fn checkDenseChanges(renderer: *cargo.Renderer, gctx: *zgpu.GraphicsContext) !void {
    // Alternating materials force one shared mixed-model batch over many sources.
    for (0..24) |id| {
        try renderer.upsertSource(gctx, id + 10, .{ .chunk = .{ @intCast(id), 0, 0 }, .revision = 1, .models = &.{.{ .local = .{ 0, 0, 0 }, .material = if (id % 2 == 0) 14 else 23 }}, .packaging = &.{.{ .local = .{ 0, 0, 0 }, .material = 14 }} });
    }
    renderer.upload(gctx);
    const before = renderer.stats();
    // Same revision performs zero work. Removal/resize move unrelated records;
    // their reverse references must survive further updates and slot reuse.
    try renderer.upsertSource(gctx, 10, .{ .chunk = .{ 0, 0, 0 }, .revision = 1 });
    try std.testing.expectEqual(before.source_builds, renderer.stats().source_builds);
    for (0..12) |id| renderer.removeSource(gctx, 10 + id * 2);
    for (0..12) |id| try renderer.upsertSource(gctx, 11 + id * 2, .{ .chunk = .{ @intCast(id), 1, 0 }, .revision = 2, .models = &.{ .{ .local = .{ 0, 0, 0 }, .material = 14 }, .{ .local = .{ 1, 0, 0 }, .material = 23 } } });
    for (renderer.models.refs.items, 0..) |ref, index| {
        const owner = renderer.sources.get(ref.id).?;
        try std.testing.expectEqual(index, owner.indices[1][ref.position]);
        try std.testing.expectEqual(owner.slot, renderer.models.entries.items[index].owner);
    }
    renderer.upload(gctx);
    try std.testing.expectEqual(@as(usize, 24), renderer.models.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), renderer.packaging.entries.items.len);
    renderer.clear(gctx);
    try std.testing.expectEqual(@as(usize, 0), renderer.sourceCount());

    // Move the last instance of a three-item source into slot 0. Slot 1
    // belongs to a different warehouse and must stay out of both cached runs.
    const items = [_]cargo.Instance{.{ .local = .{ 0, 0, 0 }, .material = 14 }} ** 3;
    for (0..3) |id| try renderer.upsertSource(gctx, id, .{ .chunk = .{ @intCast(id), 0, 0 }, .revision = 1, .models = if (id == 2) &items else items[0..1] });
    renderer.removeSource(gctx, 0);
    renderer.upload(gctx);
    const runs = renderer.sources.get(2).?.groups[0].runs[1];
    try std.testing.expectEqual(2, runs.len);
    var submitted: u32 = 0;
    for (runs) |r| {
        for (renderer.models.refs.items[r.first..r.end]) |ref| try std.testing.expectEqual(2, ref.id);
        submitted += r.end - r.first;
    }
    try std.testing.expectEqual(3, submitted);
    renderer.clear(gctx);
}
