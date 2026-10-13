const std = @import("std");
const zmath = @import("zmath");

const debug = @import("debug");

const utils = @import("./utils.zig");
const Camera = @import("./camera.zig").Camera;
const InputControllerGeneric = @import("./input_controller.zig").InputControllerGeneric;

const DEBUG = false;

const zero_vec = zmath.Vec{ 0, 0, 0, 0 };

pub const SpectatorCamera = struct {
    camera: *Camera,
    input_controller: *const InputControllerGeneric,
    pitch: f32 = 0,
    yaw: f32 = 0,

    pub fn init(camera: *Camera, input_controller: *const InputControllerGeneric) SpectatorCamera {
        return .{
            .camera = camera,
            .input_controller = input_controller,
        };
    }

    pub fn update(spectator_camera: *SpectatorCamera, time_passed: f32) void {
        spectator_camera.handleMovement(time_passed);
        spectator_camera.handleView(time_passed);
    }

    pub fn deinit(_: *SpectatorCamera) void {}

    fn handleMovement(spectator_camera: *SpectatorCamera, time_passed: f32) void {
        const camera = spectator_camera.camera;
        const input_controller = spectator_camera.input_controller;

        var direction = zmath.Vec{ 0, 0, 0, 0 };
        const step = 5 * time_passed;
        var vertical_shift: f32 = 0;

        if (input_controller.isKeyPressed(.w)) {
            direction[2] -= step;
        }
        if (input_controller.isKeyPressed(.s)) {
            direction[2] += step;
        }
        if (input_controller.isKeyPressed(.a)) {
            direction[0] -= step;
        }
        if (input_controller.isKeyPressed(.d)) {
            direction[0] += step;
        }
        if (input_controller.isKeyPressed(.space)) {
            vertical_shift += step;
        }
        if (input_controller.isKeyPressed(.c)) {
            vertical_shift -= step;
        }

        var aligned_direction: zmath.Vec = zero_vec;

        if (!zmath.all(direction == zero_vec, 3)) {
            if (direction[0] != 0 and direction[2] != 0) {
                direction[0] *= std.math.sqrt1_2;
                direction[2] *= std.math.sqrt1_2;
            }

            if (direction[0] != 0 or direction[2] != 0) {
                // we are using transpose instead of inverse here, because in case of
                // matrices containing only rotation information (ortonormal matrices),
                // tranpose operation gives us the same results as inverse, but
                // computationally is much easier.
                aligned_direction = utils.matApply(
                    zmath.transpose(camera.view_from_camera),
                    direction,
                );
            }
        }

        aligned_direction[2] += vertical_shift;

        if (!zmath.all(aligned_direction == zero_vec, 3)) {
            camera.translate(@floatCast(@shuffle(f32, aligned_direction, undefined, @Vector(3, i32){ 0, 1, 2 })));
        }
    }

    fn handleView(spectator_camera: *SpectatorCamera, _: f32) void {
        if (!spectator_camera.input_controller.cursor_left_button_pressed) {
            return;
        }

        const delta = spectator_camera.input_controller.cursor_position_delta;

        spectator_camera.yaw -= delta[0] * 0.005;
        spectator_camera.pitch -= delta[1] * 0.005;

        if (DEBUG) {
            std.debug.print("yaw: {d:2.2}, pitch: {d:2.2}\n", .{
                spectator_camera.yaw,
                spectator_camera.pitch,
            });
        }

        spectator_camera.updateCameraView();
    }

    pub fn updateCameraView(spectator_camera: *SpectatorCamera) void {
        const pitch_limit: f32 = std.math.pi / 2.0;
        spectator_camera.pitch = std.math.clamp(spectator_camera.pitch, -pitch_limit, pitch_limit);
        // NOTE: matFromRollPitchYaw can't be used because it applies pitch then yaw,
        //       but it should be yaw then pitch.
        // const view_mat = zmath.matFromRollPitchYaw(
        //     spectator_camera.pitch,
        //     spectator_camera.yaw,
        //     0,
        // );

        // NOTE: inverting position because moving of camera is effectively moving
        //       of the world in oposite direction.
        const view_mat = utils.matMul(
            zmath.rotationX(-spectator_camera.pitch),
            zmath.rotationY(-spectator_camera.yaw),
        );

        spectator_camera.camera.updateView(view_mat);
    }
};

test "spectator pitch stops at vertical and reverses without accumulated overshoot" {
    const WorldLayout = @import("world_layout.zig").WorldLayout;
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var camera = Camera.init(&layout, 1);
    var input: InputControllerGeneric = undefined;
    input.cursor_left_button_pressed = true;
    var spectator = SpectatorCamera.init(&camera, &input);
    const limit: f32 = std.math.pi / 2.0;
    for ([_]f32{ -1, 1 }) |direction| {
        input.cursor_position_delta = .{ 0, -direction * 2000 };
        for (0..3) |_| {
            spectator.handleView(0);
            try std.testing.expectEqual(direction * limit, spectator.pitch);
            try std.testing.expectApproxEqAbs(@as(f64, direction), camera.forwardDirection()[2], 0.000001);
        }
        input.cursor_position_delta = .{ 0, direction * 2 };
        spectator.handleView(0);
        try std.testing.expectApproxEqAbs(direction * (limit - 0.01), spectator.pitch, 0.000001);
    }
    // Programmatic changes use the same restriction as mouse input.
    spectator.pitch = 2 * std.math.pi;
    spectator.updateCameraView();
    try std.testing.expectEqual(limit, spectator.pitch);
}
