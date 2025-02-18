const std = @import("std");
const math = std.math;
const zmath = @import("zmath");

const debug = @import("debug.zig");

pub const Camera = struct {
    screen_width: u32,
    screen_height: u32,

    position: [3]f32,

    world_to_camera: zmath.Mat,
    camera_to_normalized_view: zmath.Mat,
    normalized_view_to_view: zmath.Mat,
    view_to_clip: zmath.Mat,

    // derived
    camera_to_view: zmath.Mat,
    world_to_clip: zmath.Mat,

    pub fn init(screen_width: u32, screen_height: u32) Camera {
        const position: [3]f32 = .{ 0, 0, 0 };

        const world_to_camera = zmath.translation(0, 0, 0);

        // NOTE: this matrix is effectively the same as:
        // const camera_to_normalized_view = zmath.rotationX(-0.5 * math.pi);
        const camera_to_normalized_view = zmath.lookAtRh(
            zmath.Vec{ 0, 0, 0, 1 },
            zmath.Vec{ 0, 1, 0, 1 },
            zmath.Vec{ 0, 0, 1, 0 },
        );

        const view_to_clip = createProjectionMatrix(screen_width, screen_height);

        var camera = Camera{
            .screen_width = screen_width,
            .screen_height = screen_height,

            .position = position,

            .world_to_camera = world_to_camera,
            .camera_to_normalized_view = camera_to_normalized_view,
            .normalized_view_to_view = zmath.identity(),
            .view_to_clip = view_to_clip,

            // derived:
            .camera_to_view = camera_to_normalized_view,
            .world_to_clip = zmath.identity(),
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
    }

    pub fn updateTargetScreenSize(camera: *Camera, screen_width: u32, screen_height: u32) void {
        if (camera.screen_width == screen_width and camera.screen_height == screen_height) {
            return;
        }

        camera.screen_width = screen_width;
        camera.screen_height = screen_height;
        camera.view_to_clip = createProjectionMatrix(screen_width, screen_height);
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

    fn createProjectionMatrix(screen_width: u32, screen_height: u32) zmath.Mat {
        return zmath.perspectiveFovRh(
            0.25 * math.pi,
            @as(f32, @floatFromInt(screen_width)) / @as(f32, @floatFromInt(screen_height)),
            0.01,
            200.0,
        );
    }
};
