const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;

pub const FinalPassBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) FinalPassBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // depth texture
            zgpu.textureEntry(
                0,
                .{ .fragment = true },
                .unfilterable_float, // or .depth
                .tvdim_2d,
                false,
            ),
            // color texture
            zgpu.textureEntry(
                1,
                .{ .fragment = true },
                .float,
                .tvdim_2d,
                false,
            ),
            // normal texture
            zgpu.textureEntry(
                2,
                .{ .fragment = true },
                .float,
                .tvdim_2d,
                false,
            ),
            // color sampler
            zgpu.samplerEntry(
                3,
                .{ .fragment = true },
                .filtering, // TODO: Maybe it's better to have non_filtering for texture -> texture transformations?
            ),
            // depth sampler (depth texture has UnfilterableFloat type)
            zgpu.samplerEntry(
                4,
                .{ .fragment = true },
                .non_filtering,
            ),
            // view to clip matrix
            zgpu.bufferEntry(
                5,
                .{ .fragment = true },
                .uniform,
                true,
                0,
            ),
            // clip to view matrix
            zgpu.bufferEntry(
                6,
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

    pub fn deinit(bind_group_layout: FinalPassBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: FinalPassBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        sampler: zgpu.SamplerHandle,
        depth_texture_view_handle: zgpu.TextureViewHandle,
        color_texture_view_handle: zgpu.TextureViewHandle,
        normal_texture_view_handle: zgpu.TextureViewHandle,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // depth texture
                .{
                    .binding = 0,
                    .texture_view_handle = depth_texture_view_handle,
                },

                // color texture
                .{
                    .binding = 1,
                    .texture_view_handle = color_texture_view_handle,
                },

                // normal texture
                .{
                    .binding = 2,
                    .texture_view_handle = normal_texture_view_handle,
                },

                // color sampler
                .{
                    .binding = 3,
                    .sampler_handle = sampler,
                },

                // depth sampler
                .{
                    .binding = 4,
                    .sampler_handle = sampler,
                },

                // view to clip matrix
                .{
                    .binding = 5,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Mat),
                },

                // clip to view matrix
                .{
                    .binding = 6,
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
