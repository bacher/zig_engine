const std = @import("std");
const math = std.math;

const gltf_loader = @import("gltf_loader");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const types = @import("../types.zig");
const load_buffer = @import("../load_buffer.zig");
const load_texture = @import("../load_texture.zig");
const GeometryData = @import("../shape_generation/geometry_data.zig").GeometryData;

pub const CubeWireframeDescriptor = struct {
    position: types.BufferDescriptor,
    geometry_bounds: types.GeometryBounds,

    pub fn init(
        gctx: *zgpu.GraphicsContext,
    ) !@This() {
        const positions = [_][3]f32{
            // top
            .{ -1.0, -1.0, 1.0 },
            .{ -1.0, 1.0, 1.0 },
            .{ -1.0, 1.0, 1.0 },
            .{ 1.0, 1.0, 1.0 },
            .{ 1.0, 1.0, 1.0 },
            .{ 1.0, -1.0, 1.0 },
            .{ 1.0, -1.0, 1.0 },
            .{ -1.0, -1.0, 1.0 },
            // between
            .{ -1.0, -1.0, 1.0 },
            .{ -1.0, -1.0, -1.0 },
            .{ -1.0, 1.0, 1.0 },
            .{ -1.0, 1.0, -1.0 },
            .{ 1.0, 1.0, 1.0 },
            .{ 1.0, 1.0, -1.0 },
            .{ 1.0, -1.0, 1.0 },
            .{ 1.0, -1.0, -1.0 },
            // bottom
            .{ -1.0, -1.0, -1.0 },
            .{ -1.0, 1.0, -1.0 },
            .{ -1.0, 1.0, -1.0 },
            .{ 1.0, 1.0, -1.0 },
            .{ 1.0, 1.0, -1.0 },
            .{ 1.0, -1.0, -1.0 },
            .{ 1.0, -1.0, -1.0 },
            .{ -1.0, -1.0, -1.0 },
        };

        const buffer = std.mem.asBytes(&positions);

        std.debug.print("positions len: {}\n", .{positions.len});
        std.debug.print("buffer len: {}\n", .{buffer.len});
        std.debug.print("buffer len 2: {}\n", .{@sizeOf([3]f32) * positions.len});

        const vertex_data = gltf_loader.ModelBuffer{
            .type = .float,
            .component_number = 3,
            .elements_count = @intCast(positions.len),
            .byte_length = @intCast(@sizeOf([3]f32) * positions.len),
            .buffer = buffer,
        };

        const positions_buffer_info = try load_buffer.loadBufferIntoGpu(
            gctx,
            .vertex,
            vertex_data,
        );

        const geometry_bounds: types.GeometryBounds = .{
            .min = .{ -1.0, -1.0, -1.0 },
            .max = .{ 1.0, 1.0, 1.0 },
            .radius = math.sqrt(3.0),
        };

        return .{
            .position = positions_buffer_info,
            .geometry_bounds = geometry_bounds,
        };
    }

    pub fn deinit(model_description: @This()) void {
        _ = model_description;
        // model_description.model.deinit();
    }
};
