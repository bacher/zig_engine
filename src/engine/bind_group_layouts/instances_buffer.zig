const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;
const SkeletalAnimation = @import("../skeletal_animation.zig");

// TODO: Move struct fields definitions to top level?

pub const InstancesBufferBindGroupLayout = struct {
    gctx: *zgpu.GraphicsContext,
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) InstancesBufferBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // Instances buffer
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .read_only_storage,
                false,
                0, // min_binding_size, is it okay to be zero for storage buffers?
            ),
        });

        return .{
            .gctx = gctx,
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_layout: InstancesBufferBindGroupLayout) void {
        bind_group_layout.gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: InstancesBufferBindGroupLayout,
        instances_buffer: zgpu.BufferHandle,
        size: usize,
    ) !BindGroup {
        const gctx = bind_group_layout.gctx;

        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // Instances buffer
                .{
                    .binding = 0,
                    .buffer_handle = instances_buffer,
                    .offset = 0,
                    .size = size,
                },
            },
        );

        const wgpu_bind_group = gctx.lookupResource(bind_group_handle) orelse return error.BindGroupNotAvailable;

        return .{
            .wgpu_bind_group = wgpu_bind_group,
            .bind_group_handle = bind_group_handle,
        };
    }
};
