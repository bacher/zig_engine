const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zstbi = @import("zstbi");
const gltf_loader = @import("gltf_loader");

const types = @import("./types.zig");
const load_buffer = @import("./load_buffer.zig");
const load_texture = @import("./load_texture.zig");
const QuadData = @import("./shape_generation/quad.zig").QuadData;

pub const WindowBoxDescriptor = struct {
    position: types.BufferDescriptor,
    color_texture: types.TextureDescriptor,

    pub fn init(
        gctx: *zgpu.GraphicsContext,
        allocator: std.mem.Allocator,
        texture_filename: []const u8,
    ) !WindowBoxDescriptor {
        var color_texture_image = try loadTextureData(allocator, texture_filename);
        defer color_texture_image.deinit();

        var quad = try QuadData.initCenteredQuad(allocator);
        defer quad.deinit(allocator);

        // TODO: Can we omit this case?
        const vertex_data = gltf_loader.ModelBuffer([3]f32){
            .buffer = quad.buffer,
            .data = quad.data,
        };

        const positions_buffer_info = try load_buffer.loadBufferIntoGpu(
            [3]f32,
            gctx,
            .vertex,
            vertex_data,
        );

        const color_texture = try load_texture.loadTextureIntoGpu(
            gctx,
            allocator,
            color_texture_image,
            .{ .generate_mipmaps = true },
        );

        return .{
            .position = positions_buffer_info,
            .color_texture = color_texture,
        };
    }

    pub fn deinit(self: WindowBoxDescriptor) void {
        _ = self;
    }
};

fn loadTextureData(allocator: std.mem.Allocator, file_path: []const u8) !zstbi.Image {
    const buffer_file_path = try std.fmt.allocPrintZ(allocator, "{s}", .{file_path});
    defer allocator.free(buffer_file_path);

    return try zstbi.Image.loadFromFile(buffer_file_path, 4);
}
