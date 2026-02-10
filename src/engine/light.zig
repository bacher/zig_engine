const std = @import("std");
const zmath = @import("zmath");
const debug = @import("debug");

const BoundBox = @import("./bound_box.zig").BoundBox;
const Camera = @import("./camera.zig").Camera;
const FrustumPoints = @import("./frustum.zig").FrustumPoints;
const resolvePosition = @import("./utils.zig").resolvePosition;

pub const DirectionalLightParams = struct {
    direction: zmath.Vec,
    color: [4]f32,
    intensity: f32,
};

pub const DirectionalLight = struct {
    const LIGHT_HEIGHT = 300.0;

    params: DirectionalLightParams,
    world_to_clip: zmath.Mat = undefined,
    clip_to_world: zmath.Mat = undefined,
    bound_box: BoundBox(f32) = undefined,

    pub fn init(light: *DirectionalLight, params: DirectionalLightParams) void {
        light.params = params;
    }

    pub fn applyCameraFrustum(light: *DirectionalLight, camera: *const Camera) void {
        const frustum_points = camera.getFrustumPoints();

        debug.printVecAsVec3Labeled("camera view bound box min", frustum_points.getMin());
        debug.printVecAsVec3Labeled("camera view bound box max", frustum_points.getMax());

        const look_to = zmath.lookToRh(
            zmath.Vec{ 0, 0, 0, 1 },
            light.params.direction,
            zmath.Vec{ 0, 0, 1, 1 },
        );

        const projected_frustum_points = frustum_points.applyMatrix(look_to);

        const min = projected_frustum_points.getMin();
        const max = projected_frustum_points.getMax();

        debug.printVecAsVec3Labeled("projected camera view bound box min", min);
        debug.printVecAsVec3Labeled("projected camera view bound box max", max);

        const view_to_clip = zmath.orthographicRh(
            max[0] - min[0],
            max[1] - min[1],
            0.001,
            LIGHT_HEIGHT,
        );

        std.debug.print("orthographic width: {d}, height: {d}\n", .{
            max[0] - min[0],
            max[1] - min[1],
        });

        const move_mat = zmath.translation(
            -(max[0] + min[0]) / 2,
            -(max[1] + min[1]) / 2,
            -(min[2] + LIGHT_HEIGHT),
        );

        // --

        const mat = zmath.mul(look_to, move_mat);

        const projected_and_moved_frustum_points = frustum_points.applyMatrix(mat);

        debug.printVecAsVec3Labeled(
            "projected and moved camera view bound box min",
            projected_and_moved_frustum_points.getMin(),
        );
        debug.printVecAsVec3Labeled(
            "projected and moved camera view bound box max",
            projected_and_moved_frustum_points.getMax(),
        );

        // --

        light.world_to_clip = zmath.mul(
            look_to,
            zmath.mul(move_mat, view_to_clip),
        );

        // --

        const ort_frustum_points = frustum_points.applyMatrix(light.world_to_clip);

        debug.printVecAsVec3Labeled(
            "ort camera view bound box min",
            ort_frustum_points.getMin(),
        );
        debug.printVecAsVec3Labeled(
            "ort camera view bound box max",
            ort_frustum_points.getMax(),
        );

        // --

        light.clip_to_world = zmath.inverse(light.world_to_clip);
    }

    // TODO:
    // Current approach with single bounding box is not optimal, the light view
    // can be very toll, so a lot of unused space in bound box.
    pub fn getLightViewBoundBox(light: *const DirectionalLight) BoundBox(f32) {
        const cube_points = CubePoints.initFromMatrix(light.clip_to_world);
        return cube_points.getBoundingBox();
    }
};

const CubePoints = struct {
    left_bottom_far: zmath.Vec,
    left_top_far: zmath.Vec,
    right_bottom_far: zmath.Vec,
    right_top_far: zmath.Vec,
    left_bottom_near: zmath.Vec,
    left_top_near: zmath.Vec,
    right_bottom_near: zmath.Vec,
    right_top_near: zmath.Vec,

    pub fn initFromMatrix(matrix: zmath.Mat) CubePoints {
        return .{
            .left_bottom_far = resolvePosition(zmath.mul(zmath.Vec{ -1, -1, 1, 1 }, matrix)),
            .left_top_far = resolvePosition(zmath.mul(zmath.Vec{ -1, 1, 1, 1 }, matrix)),
            .right_bottom_far = resolvePosition(zmath.mul(zmath.Vec{ 1, -1, 1, 1 }, matrix)),
            .right_top_far = resolvePosition(zmath.mul(zmath.Vec{ 1, 1, 1, 1 }, matrix)),
            .left_bottom_near = resolvePosition(zmath.mul(zmath.Vec{ -1, -1, -1, 1 }, matrix)),
            .left_top_near = resolvePosition(zmath.mul(zmath.Vec{ -1, 1, -1, 1 }, matrix)),
            .right_bottom_near = resolvePosition(zmath.mul(zmath.Vec{ 1, -1, -1, 1 }, matrix)),
            .right_top_near = resolvePosition(zmath.mul(zmath.Vec{ 1, 1, -1, 1 }, matrix)),
        };
    }

    pub fn getMin(self: *const CubePoints) zmath.Vec {
        return @min(
            self.left_bottom_far,
            self.left_top_far,
            self.right_bottom_far,
            self.right_top_far,
            self.left_bottom_near,
            self.left_top_near,
            self.right_bottom_near,
            self.right_top_near,
        );
    }

    pub fn getMax(self: *const CubePoints) zmath.Vec {
        return @max(
            self.left_bottom_far,
            self.left_top_far,
            self.right_bottom_far,
            self.right_top_far,
            self.left_bottom_near,
            self.left_top_near,
            self.right_bottom_near,
            self.right_top_near,
        );
    }

    pub fn getBoundingBox(self: *const CubePoints) BoundBox(f32) {
        const min = self.getMin();
        const max = self.getMax();

        return .{
            .x = .{ .start = min[0], .end = max[0] },
            .y = .{ .start = min[1], .end = max[1] },
            .z = .{ .start = min[2], .end = max[2] },
        };
    }
};
