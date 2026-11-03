//! Noncolliding instanced blueprint blocks and twelve square-section hazard rails.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const Camera = @import("camera.zig").Camera;
const BlockType = @import("voxel/voxel_chunk.zig").BlockType;
const chunks = @import("chunk_utils.zig");
const shader = @embedFile("shaders/voxel/block_geometry.wgsl") ++ @embedFile("shaders/voxel/adaptive_geometry.wgsl") ++ @embedFile("shaders/voxel/material_color.wgsl") ++ @embedFile("shaders/blueprint.wgsl");
pub const capacity = 1_100_000;
pub const frame_instance_count: u32 = 12;
pub const Cell = @Vector(3, i64);
pub const Instance = extern struct {
    position: [4]f32,
    scale: [4]f32,
    material: [4]u32,
};
fn relativePosition(camera: *const Camera, cell: Cell) @Vector(3, f32) {
    var chunk: @Vector(3, i32) = undefined;
    var local: @Vector(3, f32) = undefined;
    inline for (0..3) |axis| {
        chunk[axis] = @intCast(@divFloor(cell[axis], chunks.CHUNK_SIZE));
        local[axis] = @floatFromInt(@mod(cell[axis], chunks.CHUNK_SIZE));
    }
    return @as(@Vector(3, f32), @floatFromInt(camera.layout.getChunkDelta(chunk, camera.chunk))) * @as(@Vector(3, f32), @splat(chunks.CHUNK_SIZE)) + local;
}
pub fn blockInstance(camera: *const Camera, cell: Cell, material: BlockType, miniature: bool, invalid: bool) Instance {
    const scale: f32 = if (miniature) 0.25 else 1;
    const position = relativePosition(camera, cell) + @as(@Vector(3, f32), @splat((1 - scale) / 2));
    return .{ .position = .{ position[0], position[1], position[2], 0 }, .scale = .{ scale, scale, scale, 0 }, .material = .{ @intFromEnum(material), if (invalid) 2 else 0, 0, 0 } };
}
pub fn appendFrame(list: *std.ArrayList(Instance), allocator: std.mem.Allocator, camera: *const Camera, minimum: Cell, size: [3]u32) !void {
    const base = relativePosition(camera, minimum);
    const thickness: f32 = 0.035;
    inline for (0..3) |axis| {
        const other_a = (axis + 1) % 3;
        const other_b = (axis + 2) % 3;
        for (0..4) |corner| {
            var position = base - @as(@Vector(3, f32), @splat(thickness / 2));
            position[other_a] += if ((corner & 1) != 0) @as(f32, @floatFromInt(size[other_a])) else 0;
            position[other_b] += if ((corner & 2) != 0) @as(f32, @floatFromInt(size[other_b])) else 0;
            var scale: [4]f32 = .{ thickness, thickness, thickness, 0 };
            scale[axis] = @as(f32, @floatFromInt(size[axis])) + thickness;
            try list.append(allocator, .{ .position = .{ position[0], position[1], position[2], 0 }, .scale = scale, .material = .{ 1, 1, 0, 0 } });
        }
    }
}
pub const Renderer = struct {
    layout: zgpu.BindGroupLayoutHandle,
    uniform: zgpu.BufferHandle,
    instances: zgpu.BufferHandle,
    binding: zgpu.BindGroupHandle,
    pipeline: zgpu.RenderPipelineHandle,
    occluded_pipeline: zgpu.RenderPipelineHandle,
    allocated_capacity: usize = 1024,
    pub fn init(gctx: *zgpu.GraphicsContext, atlas_layout: zgpu.BindGroupLayoutHandle, format: wgpu.TextureFormat) Renderer {
        const layout = gctx.createBindGroupLayout(&.{ zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, false, @sizeOf(zmath.Mat)), zgpu.bufferEntry(1, .{ .vertex = true }, .read_only_storage, false, @sizeOf(Instance)) });
        const uniform = gctx.createBuffer(.{ .label = "blueprint camera", .usage = .{ .uniform = true, .copy_dst = true }, .size = @sizeOf(zmath.Mat) });
        const instances = gctx.createBuffer(.{ .label = "visible blueprint instances", .usage = .{ .storage = true, .copy_dst = true }, .size = @sizeOf(Instance) * 1024 });
        const binding = gctx.createBindGroup(layout, &.{ .{ .binding = 0, .buffer_handle = uniform, .size = @sizeOf(zmath.Mat) }, .{ .binding = 1, .buffer_handle = instances, .size = @sizeOf(Instance) * 1024 } });
        const pipeline_layout = gctx.createPipelineLayout(&.{ layout, atlas_layout });
        defer gctx.releaseResource(pipeline_layout);
        const module = zgpu.createWgslShaderModule(gctx.device, shader, "blueprints");
        defer module.release();
        const targets = [_]wgpu.ColorTargetState{.{ .format = format }};
        const pipeline = gctx.createRenderPipeline(pipeline_layout, .{ .label = "blueprints", .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .back }, .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less_equal }, .vertex = .{ .module = module, .entry_point = "vs" }, .fragment = &.{ .module = module, .entry_point = "fs", .targets = &targets, .target_count = targets.len } });
        const occluded_targets = [_]wgpu.ColorTargetState{.{ .format = format, .blend = &.{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
            .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .operation = .add },
        } }};
        const occluded_pipeline = gctx.createRenderPipeline(pipeline_layout, .{
            .label = "occluded capture frame",
            .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .back },
            .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = false, .depth_compare = .greater },
            .vertex = .{ .module = module, .entry_point = "vs" },
            .fragment = &.{ .module = module, .entry_point = "fs_occluded", .targets = &occluded_targets, .target_count = occluded_targets.len },
        });
        return .{ .layout = layout, .uniform = uniform, .instances = instances, .binding = binding, .pipeline = pipeline, .occluded_pipeline = occluded_pipeline };
    }
    pub fn deinit(self: Renderer, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(self.occluded_pipeline);
        gctx.releaseResource(self.pipeline);
        gctx.releaseResource(self.binding);
        gctx.releaseResource(self.instances);
        gctx.releaseResource(self.uniform);
        gctx.releaseResource(self.layout);
    }
    /// The optional start selects exactly one complete frame in the shared instance buffer.
    /// Its faint occluded rails draw before the ordinary opaque batch, using the same upload.
    pub fn draw(self: *Renderer, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder, atlas: wgpu.BindGroup, camera: *const Camera, instances: []const Instance, selection_frame_start: ?u32) void {
        std.debug.assert(instances.len <= capacity);
        if (selection_frame_start) |start| {
            std.debug.assert(@as(usize, start) + frame_instance_count <= instances.len);
            for (instances[start..][0..frame_instance_count]) |rail| std.debug.assert(rail.material[1] == 1);
        }
        if (instances.len == 0) return;
        if (instances.len > self.allocated_capacity) {
            const next_capacity = @min(capacity, std.math.ceilPowerOfTwoAssert(usize, instances.len));
            gctx.releaseResource(self.binding);
            gctx.releaseResource(self.instances);
            self.instances = gctx.createBuffer(.{ .label = "visible blueprint instances", .usage = .{ .storage = true, .copy_dst = true }, .size = @sizeOf(Instance) * next_capacity });
            self.binding = gctx.createBindGroup(self.layout, &.{ .{ .binding = 0, .buffer_handle = self.uniform, .size = @sizeOf(zmath.Mat) }, .{ .binding = 1, .buffer_handle = self.instances, .size = @sizeOf(Instance) * next_capacity } });
            self.allocated_capacity = next_capacity;
        }
        gctx.queue.writeBuffer(gctx.lookupResource(self.uniform).?, 0, zmath.Mat, &.{camera.clip_from_world_chunked});
        gctx.queue.writeBuffer(gctx.lookupResource(self.instances).?, 0, Instance, instances);
        pass.setBindGroup(0, gctx.lookupResource(self.binding).?, null);
        pass.setBindGroup(1, atlas, null);
        if (selection_frame_start) |start| {
            pass.setPipeline(gctx.lookupResource(self.occluded_pipeline).?);
            pass.draw(36, frame_instance_count, 0, start);
        }
        pass.setPipeline(gctx.lookupResource(self.pipeline).?);
        pass.draw(36, @intCast(instances.len), 0, 0);
    }
};

test "frame consists of twelve square section rails" {
    const layout = try @import("world_layout.zig").WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    const camera = Camera.init(&layout, 1);
    var list: std.ArrayList(Instance) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendFrame(&list, std.testing.allocator, &camera, .{ 128, 128, 128 }, .{ 5, 6, 7 });
    try std.testing.expectEqual(12, list.items.len);
    const miniature = blockInstance(&camera, .{ 128, 128, 128 }, .planks, true, false);
    try std.testing.expectEqual(@as(f32, 0.25), miniature.scale[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.375), miniature.position[0], 0.00001);
}
