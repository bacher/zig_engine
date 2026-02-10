const zmath = @import("zmath");

const BoundBox = @import("./bound_box.zig").BoundBox;
const resolvePosition = @import("./utils.zig").resolvePosition;

pub const FrustumPoints = struct {
    left_bottom_far: zmath.Vec,
    left_top_far: zmath.Vec,
    right_bottom_far: zmath.Vec,
    right_top_far: zmath.Vec,
    point_of_view: zmath.Vec,

    pub fn initFromMatrix(matrix: zmath.Mat, point_of_view: zmath.Vec) FrustumPoints {
        return .{
            .left_bottom_far = resolvePosition(zmath.mul(zmath.Vec{ -1, -1, 1, 1 }, matrix)),
            .left_top_far = resolvePosition(zmath.mul(zmath.Vec{ -1, 1, 1, 1 }, matrix)),
            .right_bottom_far = resolvePosition(zmath.mul(zmath.Vec{ 1, -1, 1, 1 }, matrix)),
            .right_top_far = resolvePosition(zmath.mul(zmath.Vec{ 1, 1, 1, 1 }, matrix)),
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
            .left_bottom_far = resolvePosition(zmath.mul(self.left_bottom_far, matrix)),
            .left_top_far = resolvePosition(zmath.mul(self.left_top_far, matrix)),
            .right_bottom_far = resolvePosition(zmath.mul(self.right_bottom_far, matrix)),
            .right_top_far = resolvePosition(zmath.mul(self.right_top_far, matrix)),
            .point_of_view = resolvePosition(zmath.mul(self.point_of_view, matrix)),
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
};
