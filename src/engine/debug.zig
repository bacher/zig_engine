const std = @import("std");
const zmath = @import("zmath");

pub fn printMat(mat: zmath.Mat) void {
    for (0..4) |i| {
        std.debug.print("  {d:10.3} {d:10.3} {d:10.3} {d:10.3}\n", .{
            mat[i][0],
            mat[i][1],
            mat[i][2],
            mat[i][3],
        });
    }
}

pub fn printMathLabeled(label: []const u8, mat: zmath.Mat) void {
    std.debug.print("Mat {s}\n", .{label});
    printMat(mat);
}

pub fn areMatricesEqual(mat1: zmath.Mat, mat2: zmath.Mat) bool {
    for (0..4) |i| {
        const eq = zmath.isNearEqual(mat1[i], mat2[i], zmath.splat(zmath.Vec, 0.001));

        if (!@reduce(.And, eq == zmath.boolx4(true, true, true, true))) {
            return false;
        }
    }
    return true;
}
