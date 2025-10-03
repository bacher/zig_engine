const std = @import("std");

const GeometryBounds = @import("../types.zig").GeometryBounds;

pub const SkyBoxVertexData = struct {
    vertex_count: u32,
    elements_count: u32,
    positions: []align(4) u8,
    uvs: []align(4) u8,
    indices: []align(4) u8,
    bounding_box: GeometryBounds,

    pub fn deinit(data: *SkyBoxVertexData, allocator: std.mem.Allocator) void {
        allocator.free(data.positions);
        allocator.free(data.uvs);
        allocator.free(data.indices);

        data.positions = &.{};
        data.uvs = &.{};
        data.indices = &.{};
    }
};

pub fn generateSkyBoxVertexData(allocator: std.mem.Allocator) !SkyBoxVertexData {
    const positions = try allocator.alignedAlloc(u8, @sizeOf(f32), @sizeOf(f32) * 3 * 14);
    const positions_slice = std.mem.bytesAsSlice([3]f32, positions);
    const uvs = try allocator.alignedAlloc(u8, @sizeOf(f32), @sizeOf(f32) * 2 * 14);
    const uvs_slice = std.mem.bytesAsSlice([2]f32, uvs);

    const indices = try allocator.alignedAlloc(u8, 4, @sizeOf(u16) * 3 * 12); // TODO:
    const indices_slice = std.mem.bytesAsSlice([3]u16, indices);

    positions_slice[0] = .{ -1, 1, 1 };
    positions_slice[1] = .{ 1, 1, 1 };
    positions_slice[2] = .{ 1, 1, -1 };
    positions_slice[3] = .{ -1, 1, -1 };
    positions_slice[4] = .{ -1, -1, -1 };
    positions_slice[5] = .{ -1, -1, 1 };
    positions_slice[6] = .{ -1, -1, 1 };
    positions_slice[7] = .{ 1, -1, 1 };
    positions_slice[8] = .{ 1, -1, 1 };
    positions_slice[9] = .{ -1, -1, 1 };
    positions_slice[10] = .{ -1, -1, -1 };
    positions_slice[11] = .{ 1, -1, -1 };
    positions_slice[12] = .{ 1, -1, -1 };
    positions_slice[13] = .{ -1, -1, -1 };

    // for (0..positions_slice.len) |i| {
    //     positions_slice[i] = .{
    //         1 * positions_slice[i][0],
    //         1 * positions_slice[i][1],
    //         1 * positions_slice[i][2],
    //     };
    // }

    uvs_slice[0] = .{ 0.25, 0.333333 };
    uvs_slice[1] = .{ 0.5, 0.333333 };
    uvs_slice[2] = .{ 0.5, 0.666667 };
    uvs_slice[3] = .{ 0.25, 0.666667 };
    uvs_slice[4] = .{ 0, 0.666667 };
    uvs_slice[5] = .{ 0, 0.333333 };
    uvs_slice[6] = .{ 0.25, 0 };
    uvs_slice[7] = .{ 0.5, 0 };
    uvs_slice[8] = .{ 0.75, 0.333333 };
    uvs_slice[9] = .{ 1, 0.333333 };
    uvs_slice[10] = .{ 1, 0.666667 };
    uvs_slice[11] = .{ 0.75, 0.666667 };
    uvs_slice[12] = .{ 0.5, 1 };
    uvs_slice[13] = .{ 0.25, 1 };

    indices_slice[0] = .{ 0, 2, 1 };
    indices_slice[1] = .{ 0, 3, 2 };
    indices_slice[2] = .{ 6, 1, 7 };
    indices_slice[3] = .{ 6, 0, 1 };
    indices_slice[4] = .{ 1, 11, 8 };
    indices_slice[5] = .{ 1, 2, 11 };
    indices_slice[6] = .{ 8, 10, 9 };
    indices_slice[7] = .{ 8, 11, 10 };
    indices_slice[8] = .{ 3, 12, 2 };
    indices_slice[9] = .{ 3, 13, 12 };
    indices_slice[10] = .{ 5, 3, 0 };
    indices_slice[11] = .{ 5, 4, 3 };

    return .{
        .vertex_count = @intCast(positions_slice.len),
        .elements_count = @intCast(indices_slice.len),
        .positions = positions,
        .uvs = uvs,
        .indices = indices,
        .bounding_box = .{
            .min = .{ -1, -1, -1 },
            .max = .{ 1, 1, 1 },
            .radius = std.math.sqrt(3),
        },
    };
}
