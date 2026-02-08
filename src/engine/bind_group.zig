const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const BindGroup = struct {
    wgpu_bind_group: wgpu.BindGroup,
    bind_group_handle: zgpu.BindGroupHandle,

    pub fn deinit(bind_group: BindGroup, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(bind_group.bind_group_handle);
    }
};
