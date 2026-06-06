const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;

pub const RegularOldBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext, texture_view_dimension: wgpu.TextureViewDimension) RegularOldBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // model to clip matrix
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .uniform,
                true,
                0,
            ),
            // texture
            zgpu.textureEntry(
                1,
                .{ .fragment = true },
                .float,
                texture_view_dimension,
                false, // TODO: What does `multisampled` mean?
            ),
            // sampler
            zgpu.samplerEntry(
                2,
                .{ .fragment = true },
                .filtering, // TODO: What's the difference between .filtering and .non_filtering
            ),
            // camera position in model space
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

    pub fn deinit(bind_group_layout: RegularOldBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: RegularOldBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        sampler: zgpu.SamplerHandle,
        color_texture: TextureDescriptor,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // model to clip matrix
                .{
                    .binding = 0,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Mat),
                },

                // texture
                .{
                    .binding = 1,
                    .texture_view_handle = color_texture.view_handle,
                },

                // sampler
                .{
                    .binding = 2,
                    .sampler_handle = sampler,
                },

                // camera position in model space
                .{
                    .binding = 3,
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
