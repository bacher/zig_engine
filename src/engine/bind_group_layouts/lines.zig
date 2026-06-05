const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;

pub const LinesBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) LinesBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // transform matrix
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .uniform,
                true,
                0,
            ),
            // color
            zgpu.bufferEntry(
                1,
                .{ .fragment = true },
                .uniform,
                true,
                0,
            ),
        });

        return .{
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_layout: LinesBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: LinesBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // transform matrix
                .{
                    .binding = 0,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Mat),
                },

                // color
                .{
                    .binding = 1,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Vec),
                },
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
