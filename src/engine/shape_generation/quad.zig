const std = @import("std");
const gltf_loader = @import("gltf_loader");

const GeometryData = @import("./geometry_data.zig").GeometryData;

pub fn initUpRightQuad(allocator: std.mem.Allocator) !GeometryData {
    const buffer = try allocator.alignedAlloc(u8, @sizeOf(f32), @sizeOf(f32) * 18);

    const data = std.mem.bytesAsSlice([3]f32, buffer);

    //  (0,1)           (1,1)
    //     [x]---------[x]
    //      | (1)    *  |
    //      |     *     |
    //      |  *    (2) |
    //     [x]---------[x]
    //  (0,0)           (1,0)
    //
    // arrangement - couter clock wise

    // 1st triangle
    data[0] = .{ 0, 0, 0 };
    data[1] = .{ 1, 1, 0 };
    data[2] = .{ 0, 1, 0 };

    // 2nd triangle
    data[3] = .{ 0, 0, 0 };
    data[4] = .{ 1, 0, 0 };
    data[5] = .{ 1, 1, 0 };

    return .{
        .data = data,
        .buffer = buffer,
        .bounding_box = .{
            .min = .{ 0, 0, 0 },
            .max = .{ 1, 1, 0 },
            .radius = std.math.sqrt(2),
        },
    };
}

pub fn initCenteredQuad(allocator: std.mem.Allocator) !GeometryData {
    const buffer = try allocator.alignedAlloc(u8, .of(f32), @sizeOf(f32) * 18);

    const data = std.mem.bytesAsSlice([3]f32, buffer);

    // (-0.5,0.5)   (0.5,0.5)
    //     [x]---------[x]
    //      | (1)    *  |
    //      |     *     |
    //      |  *    (2) |
    //     [x]---------[x]
    // (-0.5,-0.5)   (0.5,-0.5)
    //
    // arrangement - couter clock wise

    // 1st triangle
    data[0] = .{ -0.5, -0.5, 0 };
    data[1] = .{ 0.5, 0.5, 0 };
    data[2] = .{ -0.5, 0.5, 0 };

    // 2nd triangle
    data[3] = .{ -0.5, -0.5, 0 };
    data[4] = .{ 0.5, -0.5, 0 };
    data[5] = .{ 0.5, 0.5, 0 };

    return .{
        .data = data,
        .buffer = buffer,
        .bounding_box = .{
            .min = .{ -0.5, -0.5, 0 },
            .max = .{ 0.5, 0.5, 0 },
            .radius = std.math.sqrt(0.5),
        },
    };
}
