const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("types.zig").TextureDescriptor;
const BindGroupDescriptor = @import("./bind_group_descriptor.zig").BindGroupDescriptor;

pub const DebugTextureBindGroupDefinition = struct {
    gctx: *zgpu.GraphicsContext,
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) DebugTextureBindGroupDefinition {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // texture
            zgpu.textureEntry(
                0,
                .{ .fragment = true },
                .unfilterable_float,
                .tvdim_2d,
                false,
            ),
            // sampler
            zgpu.samplerEntry(
                1,
                .{ .fragment = true },
                .non_filtering,
            ),
        });

        return .{
            .gctx = gctx,
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_definition: DebugTextureBindGroupDefinition) void {
        bind_group_definition.gctx.releaseResource(bind_group_definition.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_definition: DebugTextureBindGroupDefinition,
        sampler: zgpu.SamplerHandle,
        color_texture_view_handle: zgpu.TextureViewHandle,
    ) !BindGroupDescriptor {
        const gctx = bind_group_definition.gctx;

        const bind_group_handle = gctx.createBindGroup(
            bind_group_definition.bind_group_layout_handle,
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

        const bind_group = gctx.lookupResource(bind_group_handle) orelse return error.BindGroupNotAvailable;

        return .{
            .bind_group_handle = bind_group_handle,
            .bind_group = bind_group,
        };
    }
};
