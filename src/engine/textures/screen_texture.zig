const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const ScreenTexture = struct {
    texture: zgpu.TextureHandle,
    view: wgpu.TextureView,
    view_handle: zgpu.TextureViewHandle,

    pub fn init(
        gctx: *zgpu.GraphicsContext,
        width: u32,
        height: u32,
        format: wgpu.TextureFormat,
    ) ScreenTexture {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = width,
                .height = height,
                .depth_or_array_layers = 1,
            },
            .format = format,
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

    pub fn deinit(screen_color_texture: ScreenTexture, gctx: *zgpu.GraphicsContext) void {
        gctx.releaseResource(screen_color_texture.view_handle);
        gctx.destroyResource(screen_color_texture.texture);
    }
};
