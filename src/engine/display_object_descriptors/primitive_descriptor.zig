const std = @import("std");
const math = std.math;

const gltf_loader = @import("gltf_loader");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const types = @import("../types.zig");
const load_buffer = @import("../load_buffer.zig");
const load_texture = @import("../load_texture.zig");
const GeometryData = @import("../shape_generation/geometry_data.zig").GeometryData;

pub const PrimitiveDescriptor = struct {
    position: types.BufferDescriptor,
    geometry_bounds: types.GeometryBounds,

    pub fn init(
        gctx: *zgpu.GraphicsContext,
        positions: GeometryData,
    ) !PrimitiveDescriptor {
        const vertex_data = gltf_loader.ModelBuffer{
            .type = .float,
            .component_number = 3,
            .elements_count = @intCast(positions.data.len),
            .byte_length = @intCast(@sizeOf([3]f32) * positions.data.len),
            .buffer = positions.buffer,
        };

        const positions_buffer_info = try load_buffer.loadBufferIntoGpu(
            gctx,
            .vertex,
            vertex_data,
        );

        return PrimitiveDescriptor{
            .position = positions_buffer_info,
            .geometry_bounds = positions.bounding_box,
        };
    }

    pub fn deinit(model_description: PrimitiveDescriptor) void {
        _ = model_description;
        // model_description.model.deinit();
    }
};
