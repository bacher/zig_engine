const std = @import("std");
const math = std.math;
const gltf_loader = @import("gltf_loader");

const GeometryData = @import("./geometry_data.zig").GeometryData;

const R = 0.5;
const L = -R;
pub const M = 0.05;

pub fn initUnitTube(allocator: std.mem.Allocator) !GeometryData {
    const buffer = try allocator.alignedAlloc(u8, @sizeOf(f32), @sizeOf(f32) * 3 * 36);

    const data = std.mem.bytesAsSlice([3]f32, buffer);

    // side:
    //            [x]---[x] (M, M)
    //             |  o  |
    //   (-M, -M) [x]---[x]
    //  Z
    //  * Y

    // top:
    // (-0.5,  M, M) [x]----------------------[x] (0.5,  M, M)
    // (-0.5, -M, M) [x]----------------------[x] (0.5, -M, M)
    //

    const N = -M;

    // TOP-1
    data[0] = .{ L, M, M };
    data[1] = .{ L, N, M };
    data[2] = .{ R, M, M };
    // TOP-2
    data[3] = .{ R, M, M };
    data[4] = .{ L, N, M };
    data[5] = .{ R, N, M };
    // NEAR-SIDE-1
    data[6] = .{ L, N, M };
    data[7] = .{ L, N, N };
    data[8] = .{ R, N, M };
    // NEAR-SIDE-2
    data[9] = .{ R, N, M };
    data[10] = .{ L, N, N };
    data[11] = .{ R, N, N };
    // BOTTOM-1
    data[12] = .{ L, M, N };
    data[13] = .{ R, M, N };
    data[14] = .{ L, N, N };
    // BOTTOM-2
    data[15] = .{ R, M, N };
    data[16] = .{ R, N, N };
    data[17] = .{ L, N, N };
    // FAR-SIDE-1
    data[18] = .{ L, M, M };
    data[19] = .{ R, M, M };
    data[20] = .{ L, M, N };
    // FAR-SIDE-2
    data[21] = .{ R, M, M };
    data[22] = .{ R, M, N };
    data[23] = .{ L, M, N };
    // LEFT-1
    data[24] = .{ L, M, M };
    data[25] = .{ L, M, N };
    data[26] = .{ L, N, N };
    // LEFT-2
    data[27] = .{ L, N, M };
    data[28] = .{ L, M, M };
    data[29] = .{ L, N, N };
    // RIGHT-1
    data[30] = .{ R, M, M };
    data[31] = .{ R, N, N };
    data[32] = .{ R, M, N };
    // RIGHT-2
    data[33] = .{ R, N, M };
    data[34] = .{ R, N, N };
    data[35] = .{ R, M, M };

    return .{
        .data = data,
        .buffer = buffer,
        .bounding_box = .{
            .min = .{ L, -M, -M },
            .max = .{ R, M, M },
            .radius = comptime math.sqrt(math.pow(f32, R, 2) + math.pow(f32, M, 2)),
        },
    };
}
