const std = @import("std");
const math = std.math;
const zmath = @import("zmath");
const debug = @import("debug");

const utils = @import("./utils.zig");
const BoundBox = @import("./bound_box.zig").BoundBox;
const FrustumPoints = @import("./frustum.zig").FrustumPoints;

pub const CHUNK_SIZE = 32.0;
// TODO: dedupe
const WORLD_ORIGIN_CHUNK = [_]i32{ 256, 128, 4 };
const WORLD_SIZE = [_]u32{
    std.math.pow(u32, 2, 9), //   512 chunks ( 16384 blocks)
    std.math.pow(u32, 2, 8), //   256 chunks (  8192 blocks)
    std.math.pow(u32, 2, 3), //     8 chunks (   256 blocks)
};

fn getChunk(position: [3]f32) [3]i32 {
    // TODO: refactor to use integer and bitwise shift operations instead of float operations
    return .{
        @mod(@as(i32, @intFromFloat(@divFloor(position[0], CHUNK_SIZE))) + WORLD_ORIGIN_CHUNK[0], WORLD_SIZE[0]),
        @as(i32, @intFromFloat(@divFloor(position[1], CHUNK_SIZE))) + WORLD_ORIGIN_CHUNK[1],
        @as(i32, @intFromFloat(@divFloor(position[2], CHUNK_SIZE))) + WORLD_ORIGIN_CHUNK[2],
    };
}

pub const Camera = struct {
    aspect_ratio: f32,

    position: [3]f32,
    chunk: [3]i32,

    camera_from_world: zmath.Mat,
    camera_from_world_chunked: zmath.Mat,
    normalized_view_from_camera: zmath.Mat,
    view_from_normalized_view: zmath.Mat,
    clip_from_view: zmath.Mat,
    view_from_clip: zmath.Mat,

    // derived
    view_from_camera: zmath.Mat,
    clip_from_world: zmath.Mat,
    clip_from_world_chunked: zmath.Mat, // NEW
    view_from_world: zmath.Mat,
    world_from_clip: zmath.Mat,

    pub fn init(aspect_ratio: f32) Camera {
        const position: [3]f32 = .{ 0, 0, 0 };
        const chunk: [3]i32 = .{ 0, 0, 0 };

        const no_translation = zmath.translation(0, 0, 0);

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
            .chunk = chunk,

            .camera_from_world = no_translation,
            .camera_from_world_chunked = no_translation,
            .normalized_view_from_camera = normalized_view_from_camera,
            .view_from_normalized_view = zmath.identity(),
            .clip_from_view = clip_from_view,
            .view_from_clip = zmath.inverse(clip_from_view),

            // derived:
            .view_from_camera = undefined,
            .clip_from_world = undefined,
            .clip_from_world_chunked = undefined,
            .view_from_world = undefined,
            .world_from_clip = undefined,
        };

        camera.updateDerivedMatrices();

        return camera;
    }

    pub fn deinit(_: *Camera) void {}

    fn updateDerivedMatrices(camera: *Camera) void {
        camera.view_from_camera = utils.matMul(
            camera.view_from_normalized_view,
            camera.normalized_view_from_camera,
        );

        camera.view_from_world = utils.matMul(
            camera.view_from_camera,
            camera.camera_from_world,
        );

        const view_from_world_chunked = utils.matMul(
            camera.view_from_camera,
            camera.camera_from_world_chunked,
        );

        camera.clip_from_world = utils.matMul(
            camera.clip_from_view,
            camera.view_from_world,
        );

        camera.clip_from_world_chunked = utils.matMul(
            camera.clip_from_view,
            view_from_world_chunked,
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
        camera.chunk = getChunk(position);
        // debug.printVec3Labeled("camera position", position);

        // NOTE: inverting position because moving of camera is effectively moving
        //       of the world in oposite direction.
        camera.camera_from_world = zmath.translation(
            -position[0],
            -position[1],
            -position[2],
        );
        camera.camera_from_world_chunked = zmath.translation(
            -@mod(position[0], CHUNK_SIZE),
            -@mod(position[1], CHUNK_SIZE),
            -@mod(position[2], CHUNK_SIZE),
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
