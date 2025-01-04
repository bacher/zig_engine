const std = @import("std");
const math = std.math;
const zmath = @import("zmath");

pub const Camera = struct {
    screen_width: u32,
    screen_height: u32,
    world_to_view: zmath.Mat,
    view_to_clip: zmath.Mat,
    world_to_clip: zmath.Mat,

    pub fn init(screen_width: u32, screen_height: u32) Camera {
        const world_to_view = zmath.lookAtLh(
            zmath.f32x4(3.0, 3.0, -3.0, 1.0),
            zmath.f32x4(0.0, 0.0, 0.0, 1.0),
            zmath.f32x4(0.0, 1.0, 0.0, 0.0),
        );

        const view_to_clip = createProjectionMatrix(screen_width, screen_height);

        const world_to_clip = zmath.mul(world_to_view, view_to_clip);

        return .{
            .screen_width = screen_width,
            .screen_height = screen_height,
            .world_to_view = world_to_view,
            .view_to_clip = view_to_clip,
            .world_to_clip = world_to_clip,
        };
    }

    pub fn updateTargetScreenSize(camera: *Camera, screen_width: u32, screen_height: u32) void {
        if (camera.screen_width == screen_width and camera.screen_height == screen_height) {
            return;
        }

        const view_to_clip = createProjectionMatrix(screen_width, screen_height);
        const world_to_clip = zmath.mul(camera.world_to_view, view_to_clip);

        camera.screen_width = screen_width;
        camera.screen_height = screen_height;
        camera.view_to_clip = view_to_clip;
        camera.world_to_clip = world_to_clip;
    }

    pub fn deinit() void {}

    fn createProjectionMatrix(screen_width: u32, screen_height: u32) zmath.Mat {
        return zmath.perspectiveFovLh(
            0.25 * math.pi,
            @as(f32, @floatFromInt(screen_width)) / @as(f32, @floatFromInt(screen_height)),
            0.01,
            200.0,
        );
    }
};
