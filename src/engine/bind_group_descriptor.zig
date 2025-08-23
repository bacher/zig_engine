const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const BindGroupDescriptor = struct {
    bind_group_handle: zgpu.BindGroupHandle,
    bind_group: wgpu.BindGroup,

    pub fn deinit(bind_group_descriptor: BindGroupDescriptor, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group_descriptor.bind_group_handle);
    }
};
