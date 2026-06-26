const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const BindGroup = @import("../bind_group.zig").BindGroup;

pub const SceneShaderRuntimeSettings = packed struct {
    ssao_enabled: bool,
    _padding: u31 = 0,
};

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
            // world to view matrix
            zgpu.bufferEntry(
                1,
                .{ .vertex = true },
                .uniform,
                true,
                0,
            ),
            // instances buffer
            zgpu.bufferEntry(
                2,
                .{ .vertex = true },
                .read_only_storage,
                false,
                0, // min_binding_size, is it okay to be zero for storage buffers?
            ),
            // settings
            zgpu.bufferEntry(
                3,
                .{ .vertex = true, .fragment = true },
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
        instances_buffer: zgpu.BufferHandle,
        size: usize,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // world to clip matrix
                .{
                    .binding = 0,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Mat),
                },
                // world to view matrix
                .{
                    .binding = 1,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Mat),
                },
                // instances buffer
                .{
                    .binding = 2,
                    .buffer_handle = instances_buffer,
                    .offset = 0,
                    .size = size,
                },
                // settings
                .{
                    .binding = 3,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(SceneShaderRuntimeSettings),
                },
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
