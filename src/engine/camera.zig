const std = @import("std");
const math = std.math;
const zmath = @import("zmath");

const utils = @import("./utils.zig");
const FrustumPoints = @import("./frustum.zig").FrustumPoints;
const chunk_utils = @import("./chunk_utils.zig");
const WorldLayout = @import("world_layout.zig").WorldLayout;
const Position = @import("world_math.zig").Position;

pub const CHUNK_SIZE = chunk_utils.CHUNK_SIZE;

pub const Camera = struct {
    layout: *const WorldLayout,
    aspect_ratio: f32,

    position: Position,
    chunk: @import("world_math.zig").ChunkCoords,

    camera_from_world_chunked: zmath.Mat,
    normalized_view_from_camera: zmath.Mat,
    view_from_normalized_view: zmath.Mat,
    clip_from_view: zmath.Mat,
    view_from_clip: zmath.Mat,

    // derived
    view_from_camera: zmath.Mat,
    clip_from_world_chunked: zmath.Mat,
    view_from_world_chunked: zmath.Mat,
    world_from_clip_chunked: zmath.Mat,

    pub fn init(layout: *const WorldLayout, aspect_ratio: f32) Camera {
        const position: Position = @splat(0);

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
            .layout = layout,
            .aspect_ratio = aspect_ratio,

            .position = position,
            .chunk = layout.getChunkCoords(position),

            .camera_from_world_chunked = no_translation,
            .normalized_view_from_camera = normalized_view_from_camera,
            .view_from_normalized_view = zmath.identity(),
            .clip_from_view = clip_from_view,
            .view_from_clip = zmath.inverse(clip_from_view),

            // derived:
            .view_from_camera = undefined,
            .clip_from_world_chunked = undefined,
            .view_from_world_chunked = undefined,
            .world_from_clip_chunked = undefined,
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

        camera.view_from_world_chunked = utils.matMul(
            camera.view_from_camera,
            camera.camera_from_world_chunked,
        );

        camera.clip_from_world_chunked = utils.matMul(
            camera.clip_from_view,
            camera.view_from_world_chunked,
        );

        camera.world_from_clip_chunked = zmath.inverse(camera.clip_from_world_chunked);
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

    pub fn updatePosition(camera: *Camera, position: Position) void {
        camera.position = position;
        camera.chunk = camera.layout.getChunkCoords(position);
        // Narrow only after removing the chunk origin in f64.
        const local = -chunk_utils.getLocalPosition(position);
        camera.camera_from_world_chunked = zmath.translation(local[0], local[1], local[2]);
        camera.updateDerivedMatrices();
    }

    /// Movement deltas are local distances; accumulate them into the f64 position.
    pub fn translate(camera: *Camera, delta: Position) void {
        camera.updatePosition(camera.position + delta);
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

    pub fn getLocalPosition(camera: *const Camera) zmath.Vec {
        const local = chunk_utils.getLocalPosition(camera.position);
        return .{ local[0], local[1], local[2], 1 };
    }

    /// World-space direction through the centre of the camera view.
    pub fn forwardDirection(camera: *const Camera) Position {
        const forward = utils.matApply(zmath.transpose(camera.view_from_camera), zmath.Vec{ 0, 0, -1, 0 });
        return @floatCast(@shuffle(f32, forward, undefined, @Vector(3, i32){ 0, 1, 2 }));
    }

    /// Fit shadow cascades without ever reconstructing a world-space frustum.
    pub fn getChunkFrustumPoints(camera: *const Camera, options: struct { depth: f32 = 1.0 }) FrustumPoints {
        return FrustumPoints.initFromMatrix(camera.world_from_clip_chunked, camera.getLocalPosition(), options.depth);
    }
};

test "camera forward direction follows yaw and pitch independently of its position" {
    const layout = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    var camera = Camera.init(&layout, 1);
    const views = [_]zmath.Mat{
        zmath.identity(),
        zmath.rotationY(-math.pi / 2.0),
        zmath.rotationX(math.pi / 2.0),
        zmath.rotationX(-math.pi / 2.0),
    };
    const expected = [_]Position{ .{ 0, 1, 0 }, .{ -1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 1 } };
    for (views, expected) |view, direction| {
        camera.updateView(view);
        camera.updatePosition(.{ 1000000000.5, -0.5, 31.5 });
        const actual = camera.forwardDirection();
        inline for (0..3) |axis| try std.testing.expectApproxEqAbs(direction[axis], actual[axis], 0.000001);
    }
}
