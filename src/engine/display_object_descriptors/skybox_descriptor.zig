const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zstbi = @import("zstbi");
const gltf_loader = @import("gltf_loader");

const types = @import("../types.zig");
const load_buffer = @import("../load_buffer.zig");
const load_texture = @import("../load_texture.zig");
const quad = @import("../shape_generation/quad.zig");
const generateSkyBoxVertexData = @import("../shape_generation/skybox.zig").generateSkyBoxVertexData;
const texture_loader = @import("../texture_loader.zig");

pub const SkyBoxDescriptor = struct {
    position: types.BufferDescriptor,
    uvs: types.BufferDescriptor,
    index: types.BufferDescriptor,
    color_texture: types.TextureDescriptor,
    geometry_bounds: types.GeometryBounds,

    pub fn init(
        gctx: *zgpu.GraphicsContext,
        allocator: std.mem.Allocator,
        texture_filename: []const u8,
    ) !SkyBoxDescriptor {
        var color_texture_image = try texture_loader.loadTextureData(allocator, texture_filename);
        defer color_texture_image.deinit();

        var sky_box_data = try generateSkyBoxVertexData(allocator);
        defer sky_box_data.deinit(allocator);

        // TODO: Can we omit using of gltf_loader.ModelBuffer?
        const vertex_data = gltf_loader.ModelBuffer{
            .type = .float,
            .component_number = 3,
            .elements_count = @intCast(sky_box_data.vertex_count),
            .byte_length = @intCast(sky_box_data.positions.len),
            .buffer = sky_box_data.positions,
        };

        // TODO:
        // Load the single buffer which includes positions, normals, uvs and index
        // buffers, and then use it by offsets.
        const positions_buffer_info = try load_buffer.loadBufferIntoGpu(
            gctx,
            .vertex,
            vertex_data,
        );

        // TODO: Can we omit using of gltf_loader.ModelBuffer?
        const uv_data = gltf_loader.ModelBuffer{
            .type = .float,
            .component_number = 2,
            .elements_count = sky_box_data.vertex_count,
            .byte_length = @intCast(sky_box_data.uvs.len),
            .buffer = sky_box_data.uvs,
        };

        // TODO:
        // Load the single buffer which includes positions, normals, uvs and index
        // buffers, and then use it by offsets.
        const uv_buffer_info = try load_buffer.loadBufferIntoGpu(
            gctx,
            .vertex,
            uv_data,
        );

        // TODO: Can we omit using of gltf_loader.ModelBuffer?
        const indices_data = gltf_loader.ModelBuffer{
            .type = .u16,
            .component_number = 3,
            .elements_count = sky_box_data.elements_count * 3,
            .byte_length = @intCast(sky_box_data.indices.len),
            .buffer = sky_box_data.indices,
        };
        const index_buffer_info = try load_buffer.loadBufferIntoGpu(
            gctx,
            .index,
            indices_data,
        );

        const color_texture = try load_texture.loadTextureIntoGpu(
            gctx,
            allocator,
            color_texture_image,
            .{ .generate_mipmaps = true },
        );

        return .{
            .position = positions_buffer_info,
            .uvs = uv_buffer_info,
            .index = index_buffer_info,
            .color_texture = color_texture,
            .geometry_bounds = sky_box_data.bounding_box,
        };
    }

    pub fn deinit(self: SkyBoxDescriptor) void {
        // noop for now
        _ = self;
    }
};
