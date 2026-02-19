const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const BindGroup = @import("../bind_group.zig").BindGroup;
const TextureDescriptor = @import("../types.zig").TextureDescriptor;

pub const ShadowMapBindGroupDefinition = struct {
    gctx: *zgpu.GraphicsContext,
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) ShadowMapBindGroupDefinition {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // object to light clip transformation matrix
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
                .tvdim_2d,
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
            .gctx = gctx,
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_definition: ShadowMapBindGroupDefinition) void {
        bind_group_definition.gctx.releaseResource(bind_group_definition.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_definition: ShadowMapBindGroupDefinition,
        sampler: zgpu.SamplerHandle,
        shadow_map_texture_view_handle: zgpu.TextureViewHandle,
    ) !BindGroup {
        const gctx = bind_group_definition.gctx;

        const bind_group_handle = gctx.createBindGroup(
            bind_group_definition.bind_group_layout_handle,
            &.{
                // transformation matrix
                .{
                    .binding = 0,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Mat),
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

        const wgpu_bind_group = gctx.lookupResource(bind_group_handle) orelse return error.BindGroupNotAvailable;

        return .{
            .wgpu_bind_group = wgpu_bind_group,
            .bind_group_handle = bind_group_handle,
        };
    }
};
