const std = @import("std");
const zmath = @import("zmath");
const debug = @import("debug");

const utils = @import("./utils.zig");
const BoundBox = @import("./bound_box.zig").BoundBox;
const Camera = @import("./camera.zig").Camera;
const FrustumPoints = @import("./frustum.zig").FrustumPoints;

const DEBUG_LIGHT = false;

pub const DirectionalLightParams = struct {
    direction: zmath.Vec,
    color: [4]f32,
    intensity: f32,
};

const DirectLightLayer = enum(u8) {
    layer_0 = 0,
    layer_1 = 1,
    layer_2 = 2,
};

pub const DirectionalLightCascade = struct {
    layer: DirectLightLayer,
    clip_from_world: zmath.Mat = undefined,
    view_from_world: zmath.Mat = undefined,
    world_from_clip: zmath.Mat = undefined,

    // TODO:
    // Current approach with single bounding box is not optimal, the light view
    // can be very toll, so a lot of unused space in bound box.
    pub fn getLightViewBoundBox(cascade: *const DirectionalLightCascade) BoundBox(f32) {
        const cube_points = CubePoints.initFromMatrix(cascade.world_from_clip);
        return cube_points.getBoundingBox();
    }
};

pub const DirectionalLight = struct {
    const LIGHT_HEIGHT = 300.0;

    params: DirectionalLightParams,
    cascades: [3]DirectionalLightCascade = .{
        .{ .layer = .layer_0 },
        .{ .layer = .layer_1 },
        .{ .layer = .layer_2 },
    },

    pub fn init(params: DirectionalLightParams) DirectionalLight {
        return .{
            .params = params,
        };
    }

    pub fn applyCameraFrustum(light: *DirectionalLight, cascade: *DirectionalLightCascade, camera: *const Camera) void {
        const frustum_points = camera.getFrustumPoints(.{
            .depth = switch (cascade.layer) {
                .layer_0 => 1.0,
                .layer_1 => 0.99985,
                .layer_2 => 0.9991,
            },
        });

        if (DEBUG_LIGHT) {
            debug.printVecAsVec3Labeled("camera view bound box min", frustum_points.getMin());
            debug.printVecAsVec3Labeled("camera view bound box max", frustum_points.getMax());
        }

        const look_to = zmath.lookToRh(
            zmath.Vec{ 0, 0, 0, 1 },
            light.params.direction,
            zmath.Vec{ 0, 0, 1, 1 },
        );

        const projected_frustum_points = frustum_points.applyMatrix(look_to);

        const min = projected_frustum_points.getMin();
        const max = projected_frustum_points.getMax();

        if (DEBUG_LIGHT) {
            debug.printVecAsVec3Labeled("projected camera view bound box min", min);
            debug.printVecAsVec3Labeled("projected camera view bound box max", max);
        }

        const clip_from_view = zmath.orthographicRh(
            max[0] - min[0],
            max[1] - min[1],
            0.001,
            LIGHT_HEIGHT,
        );

        if (DEBUG_LIGHT) {
            std.debug.print("orthographic width: {d}, height: {d}\n", .{
                max[0] - min[0],
                max[1] - min[1],
            });
        }

        const move_mat = zmath.translation(
            -(max[0] + min[0]) / 2,
            -(max[1] + min[1]) / 2,
            -(min[2] + LIGHT_HEIGHT),
        );

        // --
        if (DEBUG_LIGHT) {
            const mat = utils.matMul(move_mat, look_to);

            const projected_and_moved_frustum_points = frustum_points.applyMatrix(mat);

            debug.printVecAsVec3Labeled(
                "projected and moved camera view bound box min",
                projected_and_moved_frustum_points.getMin(),
            );
            debug.printVecAsVec3Labeled(
                "projected and moved camera view bound box max",
                projected_and_moved_frustum_points.getMax(),
            );
        }
        // --

        cascade.clip_from_world = utils.matMul(
            utils.matMul(clip_from_view, move_mat),
            look_to,
        );

        // --
        if (DEBUG_LIGHT) {
            const ort_frustum_points = frustum_points.applyMatrix(cascade.clip_from_world);

            debug.printVecAsVec3Labeled(
                "ort camera view bound box min",
                ort_frustum_points.getMin(),
            );
            debug.printVecAsVec3Labeled(
                "ort camera view bound box max",
                ort_frustum_points.getMax(),
            );
        }
        // --

        cascade.world_from_clip = zmath.inverse(cascade.clip_from_world);
    }
};

inline fn resolve(mat: zmath.Mat, vec: zmath.Vec) zmath.Vec {
    return utils.resolvePosition(utils.matApply(mat, vec));
}

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
            .left_bottom_far = resolve(matrix, zmath.Vec{ -1, -1, 1, 1 }),
            .left_top_far = resolve(matrix, zmath.Vec{ -1, 1, 1, 1 }),
            .right_bottom_far = resolve(matrix, zmath.Vec{ 1, -1, 1, 1 }),
            .right_top_far = resolve(matrix, zmath.Vec{ 1, 1, 1, 1 }),
            .left_bottom_near = resolve(matrix, zmath.Vec{ -1, -1, -1, 1 }),
            .left_top_near = resolve(matrix, zmath.Vec{ -1, 1, -1, 1 }),
            .right_bottom_near = resolve(matrix, zmath.Vec{ 1, -1, -1, 1 }),
            .right_top_near = resolve(matrix, zmath.Vec{ 1, 1, -1, 1 }),
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
