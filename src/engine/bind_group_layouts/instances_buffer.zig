const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;
const SkeletalAnimation = @import("../skeletal_animation.zig");

// TODO: Move struct fields definitions to top level?

pub const InstancesBufferBindGroupLayout = struct {
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
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_layout: InstancesBufferBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: InstancesBufferBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        instances_buffer: zgpu.BufferHandle,
        size: usize,
    ) BindGroup {
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

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
