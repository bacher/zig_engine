//! Nonempty construction/terrain handoff through the production voxel pipeline.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const voxel = @import("voxel/voxel_chunk.zig");
const VoxelGrid = @import("voxel/voxel_grid.zig").VoxelGrid;
const layouts_module = @import("bind_group_layouts.zig");
const voxel_pipeline = @import("pipelines/voxel_pipeline.zig");
const callbacks = @import("world_coordinate_readback.zig");
const side = 128;
const pixel_count = side * side;
const image_bytes = pixel_count * 4;

pub fn check(device: wgpu.Device, mapping: *callbacks.MapResponse) !void {
    return checkSurface(device, mapping, false);
}

pub fn checkOversized(device: wgpu.Device, mapping: *callbacks.MapResponse) !void {
    return checkSurface(device, mapping, true);
}

fn checkSurface(device: wgpu.Device, mapping: *callbacks.MapResponse, oversized: bool) !void {
    const allocator = std.testing.allocator;
    var gctx: zgpu.GraphicsContext = undefined;
    gctx.device = device;
    gctx.queue = device.getQueue();
    defer gctx.queue.release();
    const pools = .{ "buffer_pool", "bind_group_pool", "bind_group_layout_pool", "pipeline_layout_pool", "render_pipeline_pool" };
    inline for (pools) |name| @field(gctx, name) = .{ .pool = try @TypeOf(@field(gctx, name).pool).initCapacity(allocator, 16) };
    defer inline for (pools) |name| @field(gctx, name).pool.deinit();
    try checkDraw(&gctx, mapping, oversized);
    inline for (pools) |name| try std.testing.expectEqual(@as(usize, 0), @field(gctx, name).pool.liveHandleCount());
}

fn surface(cells: []const [3]u8) !voxel.ChunkSurfaceData {
    var result: voxel.ChunkSurfaceData = .{};
    errdefer result.deinit(std.testing.allocator);
    for (&result.blocks_grouped_by_side) |*faces| for (cells) |cell| try faces.append(std.testing.allocator, .{ .coords = cell, .block_type = .planks });
    return result;
}

fn checkerboardSurface() !voxel.ChunkSurfaceData {
    var result: voxel.ChunkSurfaceData = .{};
    errdefer result.deinit(std.testing.allocator);
    for (0..32) |z| for (0..32) |y| for (0..32) |x| {
        if ((x + y + z) % 2 != 0) continue;
        for (&result.blocks_grouped_by_side) |*faces| try faces.append(std.testing.allocator, .{ .coords = .{ @intCast(x), @intCast(y), @intCast(z) }, .block_type = .planks });
    };
    return result;
}

fn checkDraw(gctx: *zgpu.GraphicsContext, mapping: *callbacks.MapResponse, oversized: bool) !void {
    const allocator = std.testing.allocator;
    const device = gctx.device;
    var layouts: layouts_module.BindGroupLayouts = undefined;
    layouts.scene = .init(gctx);
    defer layouts.scene.deinit(gctx);
    layouts.regular = .init(gctx, .tvdim_2d);
    defer layouts.regular.deinit(gctx);
    layouts.shadow_map = .init(gctx);
    defer layouts.shadow_map.deinit(gctx);
    layouts.voxel = .init(gctx);
    defer layouts.voxel.deinit(gctx);
    const layout = try @import("world_layout.zig").WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    const source = try layout.shaderSource(allocator, voxel_pipeline.shader_body);
    defer allocator.free(source);
    const pipeline = voxel_pipeline.createVoxelPipeline(gctx, &layouts, source);
    defer pipeline.deinit(gctx);
    const grid = try VoxelGrid.init(allocator, gctx);
    defer grid.deinit(gctx);
    const voxel_binding = layouts.voxel.createBindGroup(gctx, grid.gpu_chunk_info_buffer, grid.gpu_block_buffer, grid.gpu_custom_block_buffer);
    defer voxel_binding.deinit(gctx);

    const uniforms = device.createBuffer(.{ .size = 1024, .usage = .{ .uniform = true, .storage = true, .copy_dst = true } });
    defer uniforms.release();
    const identity = zmath.identity();
    var clip = identity;
    clip[0][0] = 0.5;
    clip[1][1] = 0.5;
    clip[2][2] = -0.1;
    clip[3] = .{ -4.75, -4.25, 1.3, 1 };
    gctx.queue.writeBuffer(uniforms, 0, zmath.Mat, &.{identity});
    gctx.queue.writeBuffer(uniforms, 256, zmath.Mat, &.{clip});
    gctx.queue.writeBuffer(uniforms, 512, [4]i32, &.{.{ 1, 1, 1, 0 }});
    gctx.queue.writeBuffer(uniforms, 768, zmath.Mat, &.{ identity, identity, identity });
    const scene_entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .buffer = uniforms, .offset = 0, .size = 64 },
        .{ .binding = 1, .buffer = uniforms, .offset = 0, .size = 64 },
        .{ .binding = 2, .buffer = uniforms, .offset = 0, .size = 80 },
        .{ .binding = 3, .buffer = uniforms, .offset = 0, .size = 4 },
        .{ .binding = 4, .buffer = uniforms, .offset = 256, .size = 64 },
        .{ .binding = 5, .buffer = uniforms, .offset = 512, .size = 16 },
    };
    const scene_binding = device.createBindGroup(.{ .layout = gctx.lookupResource(layouts.scene.bind_group_layout_handle).?, .entries = &scene_entries, .entry_count = scene_entries.len });
    defer scene_binding.release();
    const atlas = device.createTexture(.{ .size = .{ .width = 1, .height = 1 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer atlas.release();
    const atlas_view = atlas.createView(.{});
    defer atlas_view.release();
    const sampler = device.createSampler(.{});
    defer sampler.release();
    gctx.queue.writeTexture(.{ .texture = atlas }, .{ .bytes_per_row = 4, .rows_per_image = 1 }, .{ .width = 1, .height = 1 }, u8, &.{ 255, 255, 255, 255 });
    const atlas_entries = [_]wgpu.BindGroupEntry{ .{ .binding = 0, .texture_view = atlas_view, .size = 0 }, .{ .binding = 1, .sampler = sampler, .size = 0 } };
    const atlas_binding = device.createBindGroup(.{ .layout = gctx.lookupResource(layouts.regular.bind_group_layout_handle).?, .entries = &atlas_entries, .entry_count = atlas_entries.len });
    defer atlas_binding.release();
    const shadow = device.createTexture(.{ .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 3 }, .format = .r32_float, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer shadow.release();
    const shadow_view = shadow.createView(.{ .dimension = .tvdim_2d_array });
    defer shadow_view.release();
    gctx.queue.writeTexture(.{ .texture = shadow }, .{ .bytes_per_row = 4, .rows_per_image = 1 }, .{ .width = 1, .height = 1, .depth_or_array_layers = 3 }, f32, &.{ 1, 1, 1 });
    const shadow_entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .buffer = uniforms, .offset = 768, .size = 192 },
        .{ .binding = 1, .texture_view = shadow_view, .size = 0 },
        .{ .binding = 2, .sampler = sampler, .size = 0 },
    };
    const shadow_binding = device.createBindGroup(.{ .layout = gctx.lookupResource(layouts.shadow_map.bind_group_layout_handle).?, .entries = &shadow_entries, .entry_count = shadow_entries.len });
    defer shadow_binding.release();

    const extent = wgpu.Extent3D{ .width = side, .height = side, .depth_or_array_layers = 1 };
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
    const readback = device.createBuffer(.{ .size = image_bytes * 2 * 3, .usage = .{ .copy_dst = true, .map_read = true } });
    defer readback.release();
    const coords: @Vector(3, i32) = .{ 1, 1, 1 };
    try grid.tryAppendChunk(.{ .chunk_coords = coords, .chunk_surface_data = try surface(&.{.{ 10, 8, 8 }}), .geometry_stamp = .{ .surface_revision = 1 } });
    try grid.tryAppendChunk(.{ .chunk_coords = coords, .layer = .construction, .chunk_surface_data = if (oversized) try checkerboardSurface() else try surface(&.{.{ 8, 8, 8 }}), .geometry_stamp = .{ .surface_revision = 1 } });
    try std.testing.expect(grid.tryUploadToGPU(gctx));
    if (oversized) {
        const resident = grid.chunks.items[1].gpu_residence_info.?;
        try std.testing.expectEqual(@as(u8, 9), resident.data_slot_size_level);
        for (resident.faces_count_per_view) |count| try std.testing.expectEqual(@as(u16, 49_152), count);
    }
    for (0..3) |frame| {
        if (frame == 1) {
            try grid.tryAppendChunk(.{ .chunk_coords = coords, .chunk_surface_data = if (oversized) try checkerboardSurface() else try surface(&.{ .{ 8, 8, 8 }, .{ 10, 8, 8 } }), .geometry_stamp = .{ .surface_revision = 2 } });
            try grid.tryAppendChunk(.{ .chunk_coords = coords, .layer = .construction, .chunk_surface_data = .{}, .geometry_stamp = .{ .surface_revision = 2 } });
            try std.testing.expectEqual(@as(u64, 1), grid.installedGeometry(coords, .terrain).?.surface_revision);
            try std.testing.expectEqual(@as(u64, 1), grid.installedGeometry(coords, .construction).?.surface_revision);
        }
        if (frame == 2) {
            try std.testing.expect(grid.tryUploadToGPU(gctx));
            try std.testing.expectEqual(@as(u64, 2), grid.installedGeometry(coords, .terrain).?.surface_revision);
            try std.testing.expectEqual(@as(u64, 2), grid.installedGeometry(coords, .construction).?.surface_revision);
        }
        const encoder = device.createCommandEncoder(null);
        defer encoder.release();
        const attachments = [_]wgpu.RenderPassColorAttachment{
            .{ .view = color_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } },
            .{ .view = normal_view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        };
        const pass = encoder.beginRenderPass(.{ .color_attachments = &attachments, .color_attachment_count = attachments.len, .depth_stencil_attachment = &.{ .view = depth_view, .depth_load_op = .clear, .depth_store_op = .store, .depth_clear_value = 1 } });
        defer pass.release();
        pass.setPipeline(pipeline.pipeline_gpu);
        pass.setBindGroup(0, scene_binding, &.{ 0, 0, 0, 0, 0 });
        pass.setBindGroup(1, atlas_binding, &.{});
        pass.setBindGroup(2, shadow_binding, &.{0});
        pass.setBindGroup(3, voxel_binding.wgpu_bind_group, &.{});
        var resident_layers: usize = 0;
        const chunk_view = @import("chunk_visibility.zig").View.init(&layout, coords, clip);
        for (grid.visibleChunks(&chunk_view)) |hit| {
            const chunk = grid.chunks.items[hit.id];
            const info = chunk.gpu_residence_info orelse continue;
            resident_layers += 1;
            // Compare the combined draw with both constituent views, including
            // the checkerboard whose full face count exceeds 16 bits.
            if (frame == 1) {
                info.drawFaces(pass, 0);
                info.drawFaces(pass, 7);
            } else info.drawFaces(pass, null);
        }
        try std.testing.expectEqual(@as(usize, if (frame == 2) 1 else 2), resident_layers);
        pass.end();
        const offset = frame * image_bytes * 2;
        encoder.copyTextureToBuffer(.{ .texture = color }, .{ .buffer = readback, .layout = .{ .offset = offset, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
        encoder.copyTextureToBuffer(.{ .texture = depth, .aspect = .depth_only }, .{ .buffer = readback, .layout = .{ .offset = offset + image_bytes, .bytes_per_row = side * 4, .rows_per_image = side } }, extent);
        const command = encoder.finish(null);
        defer command.release();
        gctx.queue.submit(&.{command});
    }
    mapping.* = .{};
    readback.mapAsync(.{ .read = true }, 0, image_bytes * 2 * 3, callbacks.MapResponse.callback, mapping);
    defer readback.unmap();
    try callbacks.waitForCallback(device, &mapping.done);
    try std.testing.expectEqual(wgpu.BufferMapAsyncStatus.success, mapping.status);
    const before = readback.getConstMappedRange([4]u8, 0, pixel_count) orelse return error.NoMappedGpuResults;
    const before_depth = readback.getConstMappedRange(f32, image_bytes, pixel_count) orelse return error.NoMappedGpuResults;
    for (1..3) |frame| {
        const pixels = readback.getConstMappedRange([4]u8, frame * image_bytes * 2, pixel_count) orelse return error.NoMappedGpuResults;
        const depths = readback.getConstMappedRange(f32, frame * image_bytes * 2 + image_bytes, pixel_count) orelse return error.NoMappedGpuResults;
        try std.testing.expectEqualSlices([4]u8, before, pixels);
        try std.testing.expectEqualSlices(f32, before_depth, depths);
    }
    var counts: [2]usize = .{ 0, 0 };
    for (before, before_depth, 0..) |pixel, stored_depth, index| if (stored_depth < 1) {
        try std.testing.expect(pixel[0] > 0);
        counts[@intFromBool(index % side >= side / 2)] += 1;
    };
    try std.testing.expect(counts[0] > 100 and counts[1] > 100);
}
