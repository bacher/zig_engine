//! Camera-space block drawn in the application's depth-tested 3D overlay pass.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const utils = @import("utils.zig");
const BlockType = @import("voxel/voxel_chunk.zig").BlockType;
const Pipeline = @import("pipeline.zig").Pipeline;
const BindGroup = @import("bind_group.zig").BindGroup;

pub const shader = @embedFile("shaders/voxel/block_geometry.wgsl") ++ @embedFile("shaders/voxel/adaptive_geometry.wgsl") ++ @embedFile("shaders/held_block.wgsl");

pub fn vertexCount(block: BlockType) u32 {
    return if (block == .country_road_adaptive or block == .custom) @import("voxel/custom_block.zig").adaptive_vertex_count else 36;
}

pub const Pose = @import("held_item_pose.zig").Pose;

/// Field order matches shaders/held_block.wgsl.
pub const GPU_Uniform = extern struct {
    clip_from_block: zmath.Mat,
    view_from_block: zmath.Mat,
    material: [4]u32,

    pub fn init(projection: zmath.Mat, block: BlockType, pose: Pose) GPU_Uniform {
        const view = pose.viewFromItem(projection);
        return .{
            .clip_from_block = utils.matMul(projection, view),
            .view_from_block = view,
            .material = .{ @intFromEnum(block), 0, 0, 0 },
        };
    }
};

comptime {
    // Match HeldBlock in shaders/held_block.wgsl during ordinary application builds.
    std.debug.assert(@sizeOf(GPU_Uniform) == 144);
    std.debug.assert(@offsetOf(GPU_Uniform, "clip_from_block") == 0);
    std.debug.assert(@offsetOf(GPU_Uniform, "view_from_block") == 64);
    std.debug.assert(@offsetOf(GPU_Uniform, "material") == 128);
}

/// Owns preview GPU resources; borrows the engine's atlas layout and bind group.
pub const Renderer = struct {
    layout: zgpu.BindGroupLayoutHandle,
    buffer: zgpu.BufferHandle,
    binding: BindGroup,
    pipeline: Pipeline,

    pub fn init(gctx: *zgpu.GraphicsContext, atlas_layout: zgpu.BindGroupLayoutHandle, format: wgpu.TextureFormat) Renderer {
        const layout = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, false, @sizeOf(GPU_Uniform)),
        });
        const buffer = gctx.createBuffer(.{
            .label = "held block pose",
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = @sizeOf(GPU_Uniform),
        });
        const binding = gctx.createBindGroup(layout, &.{
            .{ .binding = 0, .buffer_handle = buffer, .size = @sizeOf(GPU_Uniform) },
        });
        const pipeline_layout = gctx.createPipelineLayout(&.{ layout, atlas_layout });
        defer gctx.releaseResource(pipeline_layout);
        const module = zgpu.createWgslShaderModule(gctx.device, shader, "held block");
        defer module.release();
        const targets = [_]wgpu.ColorTargetState{.{ .format = format }};
        const pipeline = gctx.createRenderPipeline(pipeline_layout, .{
            .label = "held block",
            .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .back },
            .depth_stencil = &.{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less },
            .vertex = .{ .module = module, .entry_point = "vs" },
            .fragment = &.{ .module = module, .entry_point = "fs", .targets = &targets, .target_count = targets.len },
        });
        return .{
            .layout = layout,
            .buffer = buffer,
            .binding = .{ .bind_group_handle = binding, .wgpu_bind_group = gctx.lookupResource(binding).? },
            .pipeline = Pipeline.init(gctx, pipeline),
        };
    }

    pub fn deinit(renderer: Renderer, gctx: *zgpu.GraphicsContext) void {
        renderer.pipeline.deinit(gctx);
        renderer.binding.deinit(gctx);
        gctx.releaseResource(renderer.buffer);
        gctx.releaseResource(renderer.layout);
    }

    pub fn draw(renderer: *const Renderer, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder, atlas: wgpu.BindGroup, projection: zmath.Mat, block: BlockType, pose: Pose) void {
        const uniform = GPU_Uniform.init(projection, block, pose);
        gctx.queue.writeBuffer(gctx.lookupResource(renderer.buffer).?, 0, GPU_Uniform, &.{uniform});
        pass.setPipeline(renderer.pipeline.pipeline_gpu);
        pass.setBindGroup(0, renderer.binding.wgpu_bind_group, null);
        pass.setBindGroup(1, atlas, null);
        pass.draw(vertexCount(block), 1, 0, 0);
    }
};

test "held block pose is centred below the crosshair and clipped by the bottom edge" {
    const pose: Pose = .{};
    for ([_]f32{ 1, 4.0 / 3.0, 16.0 / 9.0, 21.0 / 9.0 }) |aspect| {
        const projection = zmath.perspectiveFovRh(std.math.pi / 4.0, aspect, 0.01, 200);
        const uniform = GPU_Uniform.init(projection, .tree_trunk, pose);
        const centre = utils.resolvePosition(utils.matApply(uniform.clip_from_block, .{ 0.5, 0.5, 0.5, 1 }));
        try std.testing.expectApproxEqAbs(pose.screen_position[0], centre[0], 0.00001);
        try std.testing.expectApproxEqAbs(pose.screen_position[1], centre[1], 0.00001);
        // The block's upright edges should lean only by the requested roll.
        const up = utils.matApply(uniform.view_from_block, .{ 0, 0, 1, 0 });
        try std.testing.expectApproxEqAbs(-pose.rotation_degrees[2] * std.math.pi / 180.0, std.math.atan2(up[0], up[1]), 0.00001);
        var visible_corners: usize = 0;
        var clipped_corners: usize = 0;
        for (0..8) |corner| {
            const position = utils.resolvePosition(utils.matApply(uniform.clip_from_block, .{
                @floatFromInt(corner & 1),
                @floatFromInt((corner >> 1) & 1),
                @floatFromInt((corner >> 2) & 1),
                1,
            }));
            try std.testing.expect(position[0] > -1 and position[0] < 1);
            try std.testing.expect(position[1] < 0);
            if (position[1] > -1) visible_corners += 1 else clipped_corners += 1;
            try std.testing.expect(position[2] > 0 and position[2] < 1);
        }
        try std.testing.expect(visible_corners > 0 and clipped_corners > 0);
    }
}
