//! Two camera-space arms drawn in the depth-free held-item overlay pass.
const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");
const utils = @import("utils.zig");
const Pose = @import("held_item_pose.zig").Pose;
const Offset = @import("held_item_motion.zig").Offset;
const Pipeline = @import("pipeline.zig").Pipeline;
const BindGroup = @import("bind_group.zig").BindGroup;
const RegularBindGroupLayout = @import("bind_group_layouts/regular.zig").RegularBindGroupLayout;
const TextureDescriptor = @import("types.zig").TextureDescriptor;

pub const shader = @embedFile("shaders/voxel/block_geometry.wgsl") ++ @embedFile("shaders/empty_hands.wgsl");
pub const dimensions: [3]f32 = .{ 0.22, 0.22, 0.66 };
const poses: [2]Pose = .{
    .{ .screen_position = .{ -0.52, -1.20 }, .distance = 1.5, .rotation_degrees = .{ -35, -12, -12 }, .scale = 1, .pivot = .{ 0.11, 0.11, 0.33 } },
    .{ .screen_position = .{ 0.52, -1.20 }, .distance = 1.5, .rotation_degrees = .{ -35, 12, 12 }, .scale = 1, .pivot = .{ 0.11, 0.11, 0.33 } },
};

/// Field order matches EmptyHands in shaders/empty_hands.wgsl.
pub const GPU_Uniform = extern struct {
    clip_from_hand: [2]zmath.Mat,
    view_from_hand: [2]zmath.Mat,

    pub fn init(projection: zmath.Mat, motion: Offset) GPU_Uniform {
        var result: GPU_Uniform = undefined;
        for (poses, 0..) |pose, hand| {
            const view = utils.matMul(pose.withMotion(motion).viewFromItem(projection), zmath.scaling(dimensions[0], dimensions[1], dimensions[2]));
            result.view_from_hand[hand] = view;
            result.clip_from_hand[hand] = utils.matMul(projection, view);
        }
        return result;
    }
};

comptime {
    std.debug.assert(@sizeOf(GPU_Uniform) == 256);
    std.debug.assert(@offsetOf(GPU_Uniform, "clip_from_hand") == 0);
    std.debug.assert(@offsetOf(GPU_Uniform, "view_from_hand") == 128);
}

/// Owns rendering resources; borrows the skin texture and sampler until deinit.
pub const Renderer = struct {
    layout: zgpu.BindGroupLayoutHandle,
    buffer: zgpu.BufferHandle,
    binding: BindGroup,
    skin_binding: BindGroup,
    pipeline: Pipeline,

    pub fn init(gctx: *zgpu.GraphicsContext, texture_layout: RegularBindGroupLayout, skin: TextureDescriptor, sampler: zgpu.SamplerHandle, format: wgpu.TextureFormat) Renderer {
        const layout = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, false, @sizeOf(GPU_Uniform)),
        });
        const buffer = gctx.createBuffer(.{
            .label = "empty hands pose",
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = @sizeOf(GPU_Uniform),
        });
        const binding = gctx.createBindGroup(layout, &.{
            .{ .binding = 0, .buffer_handle = buffer, .size = @sizeOf(GPU_Uniform) },
        });
        const pipeline_layout = gctx.createPipelineLayout(&.{ layout, texture_layout.bind_group_layout_handle });
        defer gctx.releaseResource(pipeline_layout);
        const module = zgpu.createWgslShaderModule(gctx.device, shader, "empty hands");
        defer module.release();
        const targets = [_]wgpu.ColorTargetState{.{ .format = format }};
        const pipeline = gctx.createRenderPipeline(pipeline_layout, .{
            .label = "empty hands",
            .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .back },
            .vertex = .{ .module = module, .entry_point = "vs" },
            .fragment = &.{ .module = module, .entry_point = "fs", .targets = &targets, .target_count = targets.len },
        });
        return .{
            .layout = layout,
            .buffer = buffer,
            .binding = .{ .bind_group_handle = binding, .wgpu_bind_group = gctx.lookupResource(binding).? },
            .skin_binding = texture_layout.createBindGroup(gctx, sampler, skin),
            .pipeline = Pipeline.init(gctx, pipeline),
        };
    }

    pub fn deinit(renderer: Renderer, gctx: *zgpu.GraphicsContext) void {
        renderer.pipeline.deinit(gctx);
        renderer.skin_binding.deinit(gctx);
        renderer.binding.deinit(gctx);
        gctx.releaseResource(renderer.buffer);
        gctx.releaseResource(renderer.layout);
    }

    pub fn draw(renderer: *const Renderer, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder, projection: zmath.Mat, motion: Offset) void {
        const uniform = GPU_Uniform.init(projection, motion);
        gctx.queue.writeBuffer(gctx.lookupResource(renderer.buffer).?, 0, GPU_Uniform, &.{uniform});
        pass.setPipeline(renderer.pipeline.pipeline_gpu);
        pass.setBindGroup(0, renderer.binding.wgpu_bind_group, null);
        pass.setBindGroup(1, renderer.skin_binding.wgpu_bind_group, null);
        pass.draw(36, 2, 0, 0);
    }
};

test "empty hands frame the lower view without covering the crosshair" {
    for ([_]f32{ 1, 4.0 / 3.0, 16.0 / 9.0, 21.0 / 9.0 }) |aspect| {
        const projection = zmath.perspectiveFovRh(std.math.pi / 4.0, aspect, 0.01, 200);
        const resting = GPU_Uniform.init(projection, .{});
        const offset: Offset = .{ .translation = .{ 0.02, 0.10, -0.01 }, .rotation_degrees = .{ 2, -3, 1 } };
        const moving = GPU_Uniform.init(projection, offset);
        for (0..2) |hand| {
            var visible: usize = 0;
            var clipped: usize = 0;
            for (0..8) |corner| {
                const point: zmath.Vec = .{ @floatFromInt(corner & 1), @floatFromInt((corner >> 1) & 1), @floatFromInt((corner >> 2) & 1), 1 };
                const screen = utils.resolvePosition(utils.matApply(resting.clip_from_hand[hand], point));
                try std.testing.expect(screen[0] > -1 and screen[0] < 1);
                try std.testing.expect(if (hand == 0) screen[0] < -0.1 else screen[0] > 0.1);
                try std.testing.expect(screen[1] < -0.3);
                try std.testing.expect(screen[2] > 0 and screen[2] < 1);
                if (screen[1] > -1) visible += 1 else clipped += 1;
                // Each arm consumes the same holder motion around its own grip.
                const rest_view = utils.matApply(resting.view_from_hand[hand], point);
                const pivot = utils.matApply(resting.view_from_hand[hand], .{ 0.5, 0.5, 0.5, 1 });
                const rotated = utils.matApply(offset.rotation(), rest_view - pivot);
                const actual = utils.matApply(moving.view_from_hand[hand], point);
                inline for (0..3) |axis| try std.testing.expectApproxEqAbs(pivot[axis] + rotated[axis] + offset.translation[axis], actual[axis], 0.00001);
            }
            try std.testing.expect(visible > 0 and clipped > 0);
        }
    }
}
