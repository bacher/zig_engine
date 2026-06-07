const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;

pub const FinalPassBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) FinalPassBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // texture
            zgpu.textureEntry(
                0,
                .{ .fragment = true },
                .float,
                .tvdim_2d,
                false,
            ),
            // sampler
            zgpu.samplerEntry(
                1,
                .{ .fragment = true },
                .filtering, // TODO: Maybe it's have non_filtering for texture -> texture transformations?
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
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
