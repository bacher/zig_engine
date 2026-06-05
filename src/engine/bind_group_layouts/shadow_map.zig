const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const BindGroup = @import("../bind_group.zig").BindGroup;
const TextureDescriptor = @import("../types.zig").TextureDescriptor;

pub const ShadowMapBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) ShadowMapBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // object to light clip transformation matrix array
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .uniform,
                true,
                0,
            ),
            // shadow map texture
            zgpu.textureEntry(
                1,
                .{ .fragment = true },
                .unfilterable_float,
                .tvdim_2d_array,
                false,
            ),
            // shadow map texture sampler
            zgpu.samplerEntry(
                2,
                .{ .fragment = true },
                .non_filtering,
            ),
        });

        return .{
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_layout: ShadowMapBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: ShadowMapBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        sampler: zgpu.SamplerHandle,
        shadow_map_texture_view_handle: zgpu.TextureViewHandle,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // transformation matrix
                .{
                    .binding = 0,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf([3]zmath.Mat),
                },

                // texture
                .{
                    .binding = 1,
                    .texture_view_handle = shadow_map_texture_view_handle,
                },

                // sampler
                .{
                    .binding = 2,
                    .sampler_handle = sampler,
                },
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
