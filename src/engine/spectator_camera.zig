const std = @import("std");
const zmath = @import("zmath");

const Camera = @import("camera.zig").Camera;
const InputController = @import("input_controller.zig").InputController;

pub const SpectatorCamera = struct {
    camera: *Camera,
    input_controller: *const InputController,

    pub fn init(camera: *Camera, input_controller: *const InputController) SpectatorCamera {
        return .{
            .camera = camera,
            .input_controller = input_controller,
        };
    }

    pub fn update(spectator_camera: *SpectatorCamera, time_passed: f32) void {
        spectator_camera.handleMovement(time_passed);
    }

    pub fn deinit(_: *SpectatorCamera) void {}

    fn handleMovement(spectator_camera: *SpectatorCamera, time_passed: f32) void {
        const camera = spectator_camera.camera;
        const input_controller = spectator_camera.input_controller;

        var direction = zmath.Vec{ 0, 0, 0, 1 };
        const step = 1 * time_passed;

        if (input_controller.isKeyPressed(.w)) {
            direction[2] -= step;
        }
        if (input_controller.isKeyPressed(.s)) {
            direction[2] += step;
        }
        if (input_controller.isKeyPressed(.a)) {
            direction[0] += step;
        }
        if (input_controller.isKeyPressed(.d)) {
            direction[0] -= step;
        }

        if (direction[0] != 0 or direction[2] != 0) {
            if (direction[0] != 0 and direction[2] != 0) {
                direction[0] *= std.math.sqrt1_2;
                direction[2] *= std.math.sqrt1_2;
            }

            // This is correct version, but we can skip inversing by chaning
            // order of multiplying because in case of only rotation:
            // mat * vec == vec * inverse(mat)
            //
            // const aligned_direction = zmath.mul(
            //     direction,
            //     zmath.inverse(scene.camera.camera_to_view),
            // );

            const aligned_direction = zmath.mul(
                camera.camera_to_view,
                direction,
            );

            camera.updatePosition(zmath.Vec{
                camera.position[0] + aligned_direction[0],
                camera.position[1] + aligned_direction[1],
                camera.position[2] + aligned_direction[2],
                camera.position[3],
            });
        }
    }
};
