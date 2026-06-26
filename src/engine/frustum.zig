const std = @import("std");
const zmath = @import("zmath");

const BoundBox = @import("./bound_box.zig").BoundBox;
const utils = @import("./utils.zig");

inline fn resolve(mat: zmath.Mat, vec: zmath.Vec) zmath.Vec {
    return utils.resolvePosition(utils.matApply(mat, vec));
}

pub const FrustumPoints = struct {
    left_bottom_far: zmath.Vec,
    left_top_far: zmath.Vec,
    right_bottom_far: zmath.Vec,
    right_top_far: zmath.Vec,
    point_of_view: zmath.Vec,

    pub fn initFromMatrix(matrix: zmath.Mat, point_of_view: zmath.Vec, depth: f32) FrustumPoints {
        return .{
            .left_bottom_far = resolve(matrix, zmath.Vec{ -1, -1, depth, 1 }),
            .left_top_far = resolve(matrix, zmath.Vec{ -1, 1, depth, 1 }),
            .right_bottom_far = resolve(matrix, zmath.Vec{ 1, -1, depth, 1 }),
            .right_top_far = resolve(matrix, zmath.Vec{ 1, 1, depth, 1 }),
            .point_of_view = point_of_view,
        };
    }

    pub fn getMin(self: *const FrustumPoints) zmath.Vec {
        return @min(
            self.left_bottom_far,
            self.left_top_far,
            self.right_bottom_far,
            self.right_top_far,
            self.point_of_view,
        );
    }

    pub fn getMax(self: *const FrustumPoints) zmath.Vec {
        return @max(
            self.left_bottom_far,
            self.left_top_far,
            self.right_bottom_far,
            self.right_top_far,
            self.point_of_view,
        );
    }

    pub fn applyMatrix(self: *const FrustumPoints, matrix: zmath.Mat) FrustumPoints {
        return .{
            .left_bottom_far = resolve(matrix, self.left_bottom_far),
            .left_top_far = resolve(matrix, self.left_top_far),
            .right_bottom_far = resolve(matrix, self.right_bottom_far),
            .right_top_far = resolve(matrix, self.right_top_far),
            .point_of_view = resolve(matrix, self.point_of_view),
        };
    }

    pub fn getBoundingBox(self: *const FrustumPoints) BoundBox(f32) {
        const min = self.getMin();
        const max = self.getMax();

        return .{
            .x = .init(min[0], max[0]),
            .y = .init(min[1], max[1]),
            .z = .init(min[2], max[2]),
        };
    }

    pub fn debugPrint(self: *const FrustumPoints) void {
        std.debug.print("frustum points:\n  left bottom far:  {any}\n  left top far:     {any}\n  right bottom far: {any}\n  right top far:    {any}\n  point of view:    {any}\n", .{
            self.left_bottom_far,
            self.left_top_far,
            self.right_bottom_far,
            self.right_top_far,
            self.point_of_view,
        });
    }
};
