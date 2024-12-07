const std = @import("std");

const zgpu = @import("zgpu");
const zstbi = @import("zstbi");

const TextureDescriptor = @import("./types.zig").TextureDescriptor;

pub fn loadTextureIntoGpu(gctx: *zgpu.GraphicsContext, image: zstbi.Image) !TextureDescriptor {
    const texture_handle = gctx.createTexture(.{
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
            // .copy_src = true,
        },
        .size = .{
            .width = image.width,
            .height = image.height,
            .depth_or_array_layers = 1,
        },
        .format = zgpu.imageInfoToTextureFormat(
            image.num_components,
            image.bytes_per_component,
            image.is_hdr,
        ),
        .mip_level_count = std.math.log2_int(u32, @max(image.width, image.height)) + 1,
    });

    const view_handle = gctx.createTextureView(texture_handle, .{});

    const texture = gctx.lookupResource(texture_handle) orelse return error.TextureIsNoAvailable;
    const view = gctx.lookupResource(view_handle) orelse return error.ViewIsNoAvailable;

    gctx.queue.writeTexture(
        .{ .texture = texture },
        .{
            .bytes_per_row = image.bytes_per_row,
            .rows_per_image = image.height,
        },
        .{ .width = image.width, .height = image.height },
        u8,
        image.data,
    );

    return .{
        .texture_handle = texture_handle,
        .texture = texture,
        .view_handle = view_handle,
        .view = view,
    };
}
