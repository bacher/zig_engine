const std = @import("std");
const math = std.math;
const gltf_loader = @import("gltf_loader");

const GeometryData = @import("./geometry_data.zig").GeometryData;

const SQRT2_2 = std.math.sqrt(2) / 2;
const M = 0.1;

pub fn initUnitTube(allocator: std.mem.Allocator) !GeometryData {
    const buffer = try allocator.alignedAlloc(u8, @sizeOf(f32), @sizeOf(f32) * 3 * 18);

    const data = std.mem.bytesAsSlice([3]f32, buffer);

    // side:
    //          (0, 1)
    //        8  [x]  1
    //     [x]         [x] (sqrt(2)/2, sqrt(2)/2)
    //    7               2
    //   [x]    (0, 0)   [x] (1, 0)
    //    6               3
    //     [x]         [x]
    //  Z     5  [x]  4
    //  * Y

    // top:
    //
    // (-0.5, 0, 0) [x]----------------------[x] (0.5, 0, 0)
    //

    // 1
    data[0] = .{ -0.5, 0, M };
    data[1] = .{ -0.5, M * SQRT2_2, M * SQRT2_2 };
    data[2] = .{ 0.5, 0, M };
    // 1-2
    data[1] = .{ -0.5, M * SQRT2_2, M * SQRT2_2 };
    data[4] = .{ 0.5, M * SQRT2_2, M * SQRT2_2 };
    data[5] = .{ 0.5, 0, M };
    // 2
    data[6] = .{ -0.5, M * SQRT2_2, M * SQRT2_2 };
    data[7] = .{ -0.5, M, 0 };
    data[8] = .{ 0.5, M, 0 };
    // 2-2
    data[9] = .{ -0.5, M * SQRT2_2, M * SQRT2_2 };
    data[10] = .{ 0.5, M * SQRT2_2, M * SQRT2_2 };
    data[11] = .{ 0.5, 0, M };
    // 3
    data[12] = .{ -0.5, M, 0 };
    data[13] = .{ -0.5, M * SQRT2_2, -M * SQRT2_2 };
    data[14] = .{ 0.5, M, 0 };
    // 3-2
    data[15] = .{ -0.5, M * SQRT2_2, -M * SQRT2_2 };
    data[16] = .{ 0.5, M * SQRT2_2, -M * SQRT2_2 };
    data[17] = .{ 0.5, M, 0 };

    return .{
        .data = data,
        .buffer = buffer,
        .bounding_box = .{
            .min = .{ -0.5, -M, -M },
            .max = .{ 0.5, M, M },
            .radius = comptime math.sqrt(math.pow(f32, 0.5, 2) + math.pow(f32, M, 2)),
        },
    };
}
