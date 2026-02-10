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

pub fn printMatLabeled(label: []const u8, mat: zmath.Mat) void {
    std.debug.print("Mat \"{s}\":\n", .{label});
    printMat(mat);
}

pub fn printVec(vec: zmath.Vec) void {
    std.debug.print("  {d:10.3} {d:10.3} {d:10.3} {d:10.3}\n", .{
        vec[0],
        vec[1],
        vec[2],
        vec[3],
    });
}

pub fn printVec3(vec: [3]f32) void {
    std.debug.print("  {d:10.3} {d:10.3} {d:10.3}\n", .{
        vec[0],
        vec[1],
        vec[2],
    });
}

pub fn printVecLabeled(label: []const u8, vec: zmath.Vec) void {
    std.debug.print("Vec \"{s}\":\n", .{label});
    printVec(vec);
}

pub fn printVecAsVec3Labeled(label: []const u8, vec: zmath.Vec) void {
    std.debug.print("Vec \"{s}\":\n", .{label});
    printVec3(.{ vec[0], vec[1], vec[2] });
}

pub fn printVec3Labeled(label: []const u8, vec: [3]f32) void {
    std.debug.print("Vec \"{s}\":\n", .{label});
    printVec3(vec);
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

pub fn areVectorsEqual(vec1: zmath.Vec, vec2: zmath.Vec) bool {
    const eq = zmath.isNearEqual(vec1, vec2, zmath.splat(zmath.Vec, 0.001));
    return @reduce(.And, eq == zmath.boolx4(true, true, true, true));
}

pub fn areVectorsEqualInFirst(vec1: zmath.Vec, vec2: zmath.Vec, components: u8) bool {
    const eq = zmath.isNearEqual(vec1, vec2, zmath.splat(zmath.Vec, 0.001));
    for (0..components) |i| {
        if (eq[i] == false) {
            return false;
        }
    }
    return true;
}
