const std = @import("std");

const GeometryBounds = @import("../types.zig").GeometryBounds;

pub const GeometryData = struct {
    data: [][3]f32,
    buffer: []align(4) u8,
    bounding_box: GeometryBounds,

    pub fn deinit(data: *GeometryData, allocator: std.mem.Allocator) void {
        allocator.free(data.buffer);
        data.buffer = &.{};
        data.data = &.{};
    }
};
