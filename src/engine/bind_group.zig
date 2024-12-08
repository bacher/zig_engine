const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("types.zig").TextureDescriptor;

pub const BindGroupDefinition = struct {
    gctx: *zgpu.GraphicsContext,
    bind_group_layout: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) BindGroupDefinition {
        const bind_group_layout = gctx.createBindGroupLayout(&.{
            // Transform matrix
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .uniform,
                true,
                0,
            ),
            // Texture
            zgpu.textureEntry(
                1,
                .{ .fragment = true },
                .float,
                .tvdim_2d,
                false, // TODO: What does `multisampled` mean?
            ),
            // Sampler
            zgpu.samplerEntry(
                2,
                .{ .fragment = true },
                .filtering, // TODO: What's the difference between .filtering and .non_filtering
            ),
        });

        return .{
            .gctx = gctx,
            .bind_group_layout = bind_group_layout,
        };
    }

    pub fn deinit(bind_group_def: BindGroupDefinition) void {
        bind_group_def.gctx.releaseResource(bind_group_def.bind_group_layout);
    }

    pub fn createBindGroup(
        bind_group_def: BindGroupDefinition,
        sampler: zgpu.SamplerHandle,
        color_texture: TextureDescriptor,
    ) !BindGroupDescriptor {
        const gctx = bind_group_def.gctx;

        const bind_group_handle = gctx.createBindGroup(bind_group_def.bind_group_layout, &.{
            .{
                .binding = 0,
                .buffer_handle = gctx.uniforms.buffer,
                .offset = 0,
                .size = @sizeOf(zmath.Mat),
            },
            .{
                .binding = 1,
                .texture_view_handle = color_texture.view_handle,
            },
            .{
                .binding = 2,
                .sampler_handle = sampler,
            },
        });

        const bind_group = gctx.lookupResource(bind_group_handle) orelse return error.BindGroupNotAvailable;

        return .{
            .bind_group_handle = bind_group_handle,
            .bind_group = bind_group,
        };
    }
};

pub const BindGroupDescriptor = struct {
    bind_group_handle: zgpu.BindGroupHandle,
    bind_group: wgpu.BindGroup,

    pub fn deinit(bind_group_descriptor: BindGroupDescriptor, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_descriptor.bind_group_handle);
    }
};
