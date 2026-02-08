const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;

pub const RegularBindGroupDefinition = struct {
    gctx: *zgpu.GraphicsContext,
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext, texture_view_dimension: wgpu.TextureViewDimension) RegularBindGroupDefinition {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // transform matrix
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .uniform,
                true,
                0,
            ),
            // camera position vec4<f32>
            zgpu.bufferEntry(
                1,
                .{ .vertex = true, .fragment = true },
                .uniform,
                true,
                0,
            ),
            // texture
            zgpu.textureEntry(
                2,
                .{ .fragment = true },
                .float,
                texture_view_dimension,
                false, // TODO: What does `multisampled` mean?
            ),
            // sampler
            zgpu.samplerEntry(
                3,
                .{ .fragment = true },
                .filtering, // TODO: What's the difference between .filtering and .non_filtering
            ),
        });

        return .{
            .gctx = gctx,
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_definition: RegularBindGroupDefinition) void {
        bind_group_definition.gctx.releaseResource(bind_group_definition.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_definition: RegularBindGroupDefinition,
        sampler: zgpu.SamplerHandle,
        color_texture: TextureDescriptor,
    ) !BindGroup {
        const gctx = bind_group_definition.gctx;

        const bind_group_handle = gctx.createBindGroup(
            bind_group_definition.bind_group_layout_handle,
            &.{
                // transform matrix
                .{
                    .binding = 0,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Mat),
                },

                // camera position vec4<f32>
                .{
                    .binding = 1,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Vec),
                },

                // texture
                .{
                    .binding = 2,
                    .texture_view_handle = color_texture.view_handle,
                },

                // sampler
                .{
                    .binding = 3,
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
