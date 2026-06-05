const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;
const SkeletalAnimation = @import("../skeletal_animation.zig");

pub const JointsBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) JointsBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // joint matrix palette
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .uniform,
                false,
                @sizeOf(SkeletalAnimation.JointMatrixUniform),
            ),
        });

        return .{
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_layout: JointsBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: JointsBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        joint_matrix_buffer: zgpu.BufferHandle,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // joint matrix palette
                .{
                    .binding = 0,
                    .buffer_handle = joint_matrix_buffer,
                    .offset = 0,
                    .size = @sizeOf(SkeletalAnimation.JointMatrixUniform),
                },
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
