const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const GPUBuffer = @import("../types.zig").GPUBuffer;
const BindGroup = @import("../bind_group.zig").BindGroup;

pub const VoxelBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) VoxelBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // block array buffer
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .read_only_storage,
                false,
                0, // min_binding_size, is it okay to be zero for storage buffers?
            ),
            // chunk side info array buffer
            zgpu.bufferEntry(
                1,
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

    pub fn deinit(bind_group_layout: VoxelBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: VoxelBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        block_array_buffer: GPUBuffer,
        chunk_side_info_array_buffer: GPUBuffer,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // block array buffer
                .{
                    .binding = 0,
                    .buffer_handle = block_array_buffer.handle,
                    .offset = 0,
                    .size = block_array_buffer.size,
                },
                // chunk side info array buffer
                .{
                    .binding = 1,
                    .buffer_handle = chunk_side_info_array_buffer.handle,
                    .offset = 0,
                    .size = chunk_side_info_array_buffer.size,
                },
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
