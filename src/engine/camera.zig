const std = @import("std");
const math = std.math;
const zmath = @import("zmath");
const debug = @import("debug");

const BoundBox = @import("./bound_box.zig").BoundBox;
const FrustumPoints = @import("./frustum.zig").FrustumPoints;

pub const Camera = struct {
    aspect_ratio: f32,

    position: [3]f32,

    camera_from_world: zmath.Mat,
    normalized_view_from_camera: zmath.Mat,
    view_from_normalized_view: zmath.Mat,
    clip_from_view: zmath.Mat,
    view_from_clip: zmath.Mat,

    // derived
    view_from_camera: zmath.Mat,
    clip_from_world: zmath.Mat,
    view_from_world: zmath.Mat,
    world_from_clip: zmath.Mat,

    pub fn init(aspect_ratio: f32) Camera {
        const position: [3]f32 = .{ 0, 0, 0 };

        const camera_from_world = zmath.translation(0, 0, 0);

        // NOTE: this matrix is effectively the same as:
        // const normalized_view_from_camera = zmath.rotationX(-0.5 * math.pi);
        const normalized_view_from_camera = zmath.lookAtRh(
            zmath.Vec{ 0, 0, 0, 1 },
            zmath.Vec{ 0, 1, 0, 1 },
            zmath.Vec{ 0, 0, 1, 0 },
        );

        const clip_from_view = createProjectionMatrix(aspect_ratio);

        var camera = Camera{
            .aspect_ratio = aspect_ratio,

            .position = position,

            .camera_from_world = camera_from_world,
            .normalized_view_from_camera = normalized_view_from_camera,
            .view_from_normalized_view = zmath.identity(),
            .clip_from_view = clip_from_view,
            .view_from_clip = zmath.inverse(clip_from_view),

            // derived:
            .view_from_camera = undefined,
            .clip_from_world = undefined,
            .view_from_world = undefined,
            .world_from_clip = undefined,
        };

        camera.updateDerivedMatrices();

        return camera;
    }

    pub fn deinit(_: *Camera) void {}

    fn updateDerivedMatrices(camera: *Camera) void {
        camera.view_from_camera = zmath.mul(
            camera.normalized_view_from_camera,
            camera.view_from_normalized_view,
        );

        camera.view_from_world = zmath.mul(
            camera.camera_from_world,
            camera.view_from_camera,
        );

        camera.clip_from_world = zmath.mul(
            camera.view_from_world,
            camera.clip_from_view,
        );

        camera.world_from_clip = zmath.inverse(camera.clip_from_world);
    }

    pub fn updateTargetScreenSize(camera: *Camera, aspect_ratio: f32) void {
        if (camera.aspect_ratio == aspect_ratio) {
            return;
        }

        camera.aspect_ratio = aspect_ratio;
        camera.clip_from_view = createProjectionMatrix(aspect_ratio);
        camera.view_from_clip = zmath.inverse(camera.clip_from_view);
        camera.updateDerivedMatrices();
    }

    pub fn updatePosition(camera: *Camera, position: [3]f32) void {
        camera.position = position;
        // debug.printVec3Labeled("camera position", position);

        // NOTE: inverting position because moving of camera is effectively moving
        //       of the world in oposite direction.
        camera.camera_from_world = zmath.translation(
            -position[0],
            -position[1],
            -position[2],
        );
        camera.updateDerivedMatrices();
    }

    pub fn updateView(camera: *Camera, view_mat: zmath.Mat) void {
        camera.view_from_normalized_view = view_mat;
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

    pub fn getFrustumPoints(camera: *const Camera, options: struct { depth: f32 = 1.0 }) FrustumPoints {
        return FrustumPoints.initFromMatrix(
            camera.world_from_clip,
            zmath.Vec{
                camera.position[0],
                camera.position[1],
                camera.position[2],
                1,
            },
            options.depth,
        );
    }

    pub fn getCameraViewBoundBox(camera: *const Camera) BoundBox(f32) {
        const frustum_points = camera.getFrustumPoints(.{});
        return frustum_points.getBoundingBox();
    }
};
