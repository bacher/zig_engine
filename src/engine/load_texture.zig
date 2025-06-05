const std = @import("std");

const zgpu = @import("zgpu");
const zstbi = @import("zstbi");

const TextureDescriptor = @import("./types.zig").TextureDescriptor;

pub const LoadTextureOptions = struct {
    generate_mipmaps: bool = false,
};

pub fn loadTextureIntoGpu(
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    image: zstbi.Image,
    options_maybe: ?LoadTextureOptions,
) !TextureDescriptor {
    const options: LoadTextureOptions = options_maybe orelse .{
        .generate_mipmaps = false,
    };

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
        .mip_level_count = if (options.generate_mipmaps)
            std.math.log2_int(u32, @max(image.width, image.height)) + 1
        else
            1,
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

    const texture_descriptor = TextureDescriptor{
        .texture_handle = texture_handle,
        .texture = texture,
        .view_handle = view_handle,
        .view = view,
    };

    if (options.generate_mipmaps) {
        try texture_descriptor.generateMipmaps(gctx, allocator);
    }

    return texture_descriptor;
}
