const std = @import("std");
const math = std.math;
const zmath = @import("zmath");
const debug = @import("debug");

const BoundBox = @import("./bound_box.zig").BoundBox;
const FrustumPoints = @import("./frustum.zig").FrustumPoints;

pub const Camera = struct {
    aspect_ratio: f32,

    position: [3]f32,

    world_to_camera: zmath.Mat,
    camera_to_normalized_view: zmath.Mat,
    normalized_view_to_view: zmath.Mat,
    view_to_clip: zmath.Mat,

    // derived
    camera_to_view: zmath.Mat,
    world_to_clip: zmath.Mat,
    clip_to_world: zmath.Mat,

    pub fn init(aspect_ratio: f32) Camera {
        const position: [3]f32 = .{ 0, 0, 0 };

        const world_to_camera = zmath.translation(0, 0, 0);

        // NOTE: this matrix is effectively the same as:
        // const camera_to_normalized_view = zmath.rotationX(-0.5 * math.pi);
        const camera_to_normalized_view = zmath.lookAtRh(
            zmath.Vec{ 0, 0, 0, 1 },
            zmath.Vec{ 0, 1, 0, 1 },
            zmath.Vec{ 0, 0, 1, 0 },
        );

        const view_to_clip = createProjectionMatrix(aspect_ratio);

        var camera = Camera{
            .aspect_ratio = aspect_ratio,

            .position = position,

            .world_to_camera = world_to_camera,
            .camera_to_normalized_view = camera_to_normalized_view,
            .normalized_view_to_view = zmath.identity(),
            .view_to_clip = view_to_clip,

            // derived:
            .camera_to_view = undefined,
            .world_to_clip = undefined,
            .clip_to_world = undefined,
        };

        camera.updateDerivedMatrices();

        return camera;
    }

    pub fn deinit(_: *Camera) void {}

    fn updateDerivedMatrices(camera: *Camera) void {
        camera.camera_to_view = zmath.mul(
            camera.camera_to_normalized_view,
            camera.normalized_view_to_view,
        );

        camera.world_to_clip = zmath.mul(
            camera.world_to_camera,
            zmath.mul(
                camera.camera_to_view,
                camera.view_to_clip,
            ),
        );

        camera.clip_to_world = zmath.inverse(camera.world_to_clip);
    }

    pub fn updateTargetScreenSize(camera: *Camera, aspect_ratio: f32) void {
        if (camera.aspect_ratio == aspect_ratio) {
            return;
        }

        camera.aspect_ratio = aspect_ratio;
        camera.view_to_clip = createProjectionMatrix(aspect_ratio);
        camera.updateDerivedMatrices();
    }

    pub fn updatePosition(camera: *Camera, position: [3]f32) void {
        camera.position = position;
        // debug.printVec3Labeled("camera position", position);

        // NOTE: inverting position because moving of camera is effectively moving
        //       of the world in oposite direction.
        camera.world_to_camera = zmath.translation(
            -position[0],
            -position[1],
            -position[2],
        );
        camera.updateDerivedMatrices();
    }

    pub fn updateView(camera: *Camera, view_mat: zmath.Mat) void {
        camera.normalized_view_to_view = view_mat;
        camera.updateDerivedMatrices();
    }

    fn createProjectionMatrix(aspect_ratio: f32) zmath.Mat {
        return zmath.perspectiveFovRh(
            0.25 * math.pi,
            aspect_ratio,
            0.01,
            200.0,
        );
    }

    pub fn getFrustumPoints(camera: *const Camera) FrustumPoints {
        return FrustumPoints.initFromMatrix(camera.clip_to_world, zmath.Vec{
            camera.position[0],
            camera.position[1],
            camera.position[2],
            1,
        });
    }

    pub fn getCameraViewBoundBox(camera: *const Camera) BoundBox(f32) {
        const frustum_points = camera.getFrustumPoints();
        return frustum_points.getBoundingBox();
    }
};
