const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const DepthTexture = struct {
    gctx: *zgpu.GraphicsContext,
    texture: zgpu.TextureHandle,
    view_handle: zgpu.TextureViewHandle,
    view: wgpu.TextureView,

    pub fn init(gctx: *zgpu.GraphicsContext) !DepthTexture {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = gctx.swapchain_descriptor.width,
                .height = gctx.swapchain_descriptor.height,
                .depth_or_array_layers = 1,
            },
            .format = .depth32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });

        const view_handle = gctx.createTextureView(texture, .{});
        const view = gctx.lookupResource(view_handle) orelse return error.TextureIsNoAvailable;

        return .{
            .gctx = gctx,
            .texture = texture,
            .view_handle = view_handle,
            .view = view,
        };
    }

    pub fn deinit(depth_texture: DepthTexture) void {
        depth_texture.gctx.releaseResource(depth_texture.view_handle);
        depth_texture.gctx.destroyResource(depth_texture.texture);
    }
};
