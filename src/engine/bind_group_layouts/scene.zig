const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const BindGroup = @import("../bind_group.zig").BindGroup;

pub const SceneBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) SceneBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // world to clip matrix
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .uniform,
                true,
                0,
            ),
        });

        return .{
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_layout: SceneBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: SceneBindGroupLayout,
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
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
