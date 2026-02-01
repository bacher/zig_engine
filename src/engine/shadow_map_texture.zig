const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const ShadowMapTexture = struct {
    gctx: *zgpu.GraphicsContext,
    texture: zgpu.TextureHandle,
    view_handle: zgpu.TextureViewHandle,
    view: wgpu.TextureView,

    pub fn init(gctx: *zgpu.GraphicsContext) !ShadowMapTexture {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = 1024,
                .height = 1024,
                .depth_or_array_layers = 1,
            },
            .format = .r32_float,
            // .format = .depth32_float,
            // or .depth32_float can be used?
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

    pub fn deinit(shadow_map_texture: ShadowMapTexture) void {
        shadow_map_texture.gctx.releaseResource(shadow_map_texture.view_handle);
        shadow_map_texture.gctx.destroyResource(shadow_map_texture.texture);
    }
};
