const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zmath = @import("zmath");

const TextureDescriptor = @import("../types.zig").TextureDescriptor;
const BindGroupDescriptor = @import("../bind_group_descriptor.zig").BindGroupDescriptor;

pub const ShadowMapPassBindGroupDefinition = struct {
    gctx: *zgpu.GraphicsContext,
    bind_group_layout_handle: zgpu.BindGroupLayoutHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) ShadowMapPassBindGroupDefinition {
        const bind_group_layout_handle = gctx.createBindGroupLayout(&.{
            // transform matrix
            zgpu.bufferEntry(
                0,
                .{ .vertex = true },
                .uniform,
                true,
                0,
            ),
        });

        return .{
            .gctx = gctx,
            .bind_group_layout_handle = bind_group_layout_handle,
        };
    }

    pub fn deinit(bind_group_definition: ShadowMapPassBindGroupDefinition) void {
        bind_group_definition.gctx.releaseResource(bind_group_definition.bind_group_layout_handle);
    }

    pub fn createBindGroup(
        // FIX: fix typo => definition
        bind_group_defenition: ShadowMapPassBindGroupDefinition,
    ) !BindGroupDescriptor {
        const gctx = bind_group_defenition.gctx;

        const bind_group_handle = gctx.createBindGroup(
            bind_group_defenition.bind_group_layout_handle,
            &.{
                // transform matrix
                .{
                    .binding = 0,
                    .buffer_handle = gctx.uniforms.buffer,
                    .offset = 0,
                    .size = @sizeOf(zmath.Mat),
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
