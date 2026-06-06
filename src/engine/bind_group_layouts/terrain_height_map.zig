const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;

// NOTE: Most of the code is duplicated from RegularBindGroupDefinition,
//       can it be refactored to remove duplication?
pub const TerrainHeightMapBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(
        gctx: *zgpu.GraphicsContext,
    ) TerrainHeightMapBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // transform matrix
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
                .tvdim_2d,
                false, // TODO: What does `multisampled` mean?
            ),
            // sampler
            zgpu.samplerEntry(
                2,
                .{ .fragment = true },
                .filtering, // TODO: What's the difference between .filtering and .non_filtering
            ),
            // height map texture
            zgpu.textureEntry(
                3,
                .{ .vertex = true },
                .uint,
                .tvdim_2d,
                false,
            ),
            // mixing texture
            zgpu.textureEntry(
                4,
                .{ .fragment = true },
                .float,
                .tvdim_2d,
                false,
            ),
            // texture 2
            zgpu.textureEntry(
                5,
                .{ .fragment = true },
                .float,
                .tvdim_2d,
                false,
            ),
            // time (ms)
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

    pub fn deinit(bind_group_layout: TerrainHeightMapBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: TerrainHeightMapBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        sampler: zgpu.SamplerHandle,
        color_texture: TextureDescriptor,
        depth_map_texture: TextureDescriptor,
        mixing_texture: TextureDescriptor,
        texture_2: TextureDescriptor,
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

                // height map texture
                .{
                    .binding = 3,
                    .texture_view_handle = depth_map_texture.view_handle,
                },

                // mixing texture
                .{
                    .binding = 4,
                    .texture_view_handle = mixing_texture.view_handle,
                },

                // texture 2
                .{
                    .binding = 5,
                    .texture_view_handle = texture_2.view_handle,
                },

                // time (ms)
                .{
                    .binding = 6,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(u32),
                },
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
