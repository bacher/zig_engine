const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const DepthTexture = struct {
    texture: zgpu.TextureHandle,
    view_handle: zgpu.TextureViewHandle,
    view: wgpu.TextureView,

    pub fn init(gctx: *zgpu.GraphicsContext, width: u32, height: u32) DepthTexture {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = width,
                .height = height,
                .depth_or_array_layers = 1,
            },
            .format = .depth32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });

        const view_handle = gctx.createTextureView(texture, .{});
        const view = gctx.lookupResource(view_handle) orelse @panic("Can't create a texture");

        return .{
            .texture = texture,
            .view_handle = view_handle,
            .view = view,
        };
    }

    pub fn deinit(depth_texture: *const DepthTexture, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(depth_texture.view_handle);
        gctx.destroyResource(depth_texture.texture);
    }
};
