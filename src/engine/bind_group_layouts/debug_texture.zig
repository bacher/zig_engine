const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;

pub const DebugTextureBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) DebugTextureBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // texture
            zgpu.textureEntry(
                0,
                .{ .fragment = true },
                .unfilterable_float,
                .tvdim_2d_array,
                false,
            ),
            // sampler
            zgpu.samplerEntry(
                1,
                .{ .fragment = true },
                .non_filtering,
            ),
            // screen aspect ratio
            zgpu.bufferEntry(
                2,
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

    pub fn deinit(bind_group_layout: DebugTextureBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: DebugTextureBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        sampler: zgpu.SamplerHandle,
        color_texture_view_handle: zgpu.TextureViewHandle,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // texture
                .{
                    .binding = 0,
                    .texture_view_handle = color_texture_view_handle,
                },

                // sampler
                .{
                    .binding = 1,
                    .sampler_handle = sampler,
                },

                // screen aspect ratio
                .{
                    .binding = 2,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(f32),
                },
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
