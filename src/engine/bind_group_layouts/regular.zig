const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroup = @import("../bind_group.zig").BindGroup;
const SkeletalAnimation = @import("../skeletal_animation.zig");

pub const RegularBindGroupLayout = struct {
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext, texture_view_dimension: wgpu.TextureViewDimension) RegularBindGroupLayout {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // camera position vec4<f32>
            zgpu.bufferEntry(
                0,
                .{ .vertex = true, .fragment = true },
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
            // joint matrix palette
            zgpu.bufferEntry(
                3,
                .{ .vertex = true },
                .uniform,
                false,
                @sizeOf(SkeletalAnimation.JointMatrixUniform),
            ),
        });

        return .{
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_layout: RegularBindGroupLayout, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_layout.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        bind_group_layout: RegularBindGroupLayout,
        gctx: *zgpu.GraphicsContext,
        sampler: zgpu.SamplerHandle,
        color_texture: TextureDescriptor,
        joint_matrix_buffer: zgpu.BufferHandle,
    ) BindGroup {
        const bind_group_handle = gctx.createBindGroup(
            bind_group_layout.bind_group_layout_handle,
            &.{
                // camera position vec4<f32>
                .{
                    .binding = 0,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Vec),
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

                // joint matrix palette
                .{
                    .binding = 3,
                    .buffer_handle = joint_matrix_buffer,
                    .offset = 0,
                    .size = @sizeOf(SkeletalAnimation.JointMatrixUniform),
                },
            },
        );

        return .{
            .wgpu_bind_group = gctx.lookupResource(bind_group_handle).?,
            .bind_group_handle = bind_group_handle,
        };
    }
};
