const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const ViewInstance = struct {
    view: wgpu.TextureView,
    view_handle: zgpu.TextureViewHandle,
};

pub const ShadowMapTexture = struct {
    gctx: *zgpu.GraphicsContext,
    texture: zgpu.TextureHandle,
    array_view: ViewInstance,
    layers_views: [3]ViewInstance,

    pub fn init(gctx: *zgpu.GraphicsContext, options: struct { layers_count: u8 = 1 }) !ShadowMapTexture {
        const texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true, .texture_binding = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = 1024,
                .height = 1024,
                .depth_or_array_layers = options.layers_count,
            },
            .format = .r32_float,
            // .format = .depth32_float,
            // or .depth32_float can be used?
            .mip_level_count = 1,
            .sample_count = 1,
        });

        const array_view_handle = gctx.createTextureView(texture, .{});
        const array_view = gctx.lookupResource(array_view_handle) orelse return error.TextureIsNoAvailable;

        var layers_views: [3]ViewInstance = undefined;

        for (&layers_views, 0..) |*layer_view, i| {
            const layer_view_handle = gctx.createTextureView(texture, .{
                .base_array_layer = @intCast(i),
                .array_layer_count = 1,
            });

            const view = gctx.lookupResource(layer_view_handle) orelse return error.TextureIsNoAvailable;

            layer_view.* = .{
                .view = view,
                .view_handle = layer_view_handle,
            };
        }

        return .{
            .gctx = gctx,
            .texture = texture,
            .array_view = .{
                .view = array_view,
                .view_handle = array_view_handle,
            },
            .layers_views = layers_views,
        };
    }

    pub fn deinit(shadow_map_texture: ShadowMapTexture) void {
        shadow_map_texture.gctx.releaseResource(shadow_map_texture.array_view.view_handle);
        for (shadow_map_texture.layers_views) |layer_view| {
            shadow_map_texture.gctx.releaseResource(layer_view.view_handle);
        }
        shadow_map_texture.gctx.destroyResource(shadow_map_texture.texture);
    }
};
