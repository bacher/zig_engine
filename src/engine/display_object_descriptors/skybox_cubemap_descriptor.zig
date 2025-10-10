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

pub const SkyBoxCubemapDescriptor = struct {
    position: types.BufferDescriptor,
    index: types.BufferDescriptor,
    color_texture: types.TextureDescriptor,
    geometry_bounds: types.GeometryBounds,

    pub fn init(
        gctx: *zgpu.GraphicsContext,
        allocator: std.mem.Allocator,
        texture_filenames: [6][]const u8,
    ) !SkyBoxCubemapDescriptor {
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

        var color_texture_images: [6]zstbi.Image = undefined;

        for (0..6) |i| {
            color_texture_images[i] = try texture_loader.loadTextureData(allocator, texture_filenames[i]);
            errdefer {
                // free all previously allocated texture images
                for (0..i - 1) |j| {
                    color_texture_images[j].deinit();
                }
            }
        }

        const color_texture = try load_texture.loadCubeTextureIntoGpu(
            gctx,
            allocator,
            color_texture_images,
            null,
            // TODO: Why enabling of mipmaps crushes the program?
            // .{ .generate_mipmaps = true },
        );

        defer {
            for (0..6) |i| {
                color_texture_images[i].deinit();
            }
        }

        return .{
            .position = positions_buffer_info,
            .index = index_buffer_info,
            .color_texture = color_texture,
            .geometry_bounds = sky_box_data.bounding_box,
        };
    }

    pub fn deinit(self: SkyBoxCubemapDescriptor) void {
        // noop for now
        _ = self;
    }
};
