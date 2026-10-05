const std = @import("std");
const zmath = @import("zmath");
const chunks = @import("chunk_utils.zig");
const ChunkTransform = @import("chunk_transform.zig").ChunkTransform;
const Camera = @import("camera.zig").Camera;
const DirectionalLight = @import("light.zig").DirectionalLight;
const utils = @import("utils.zig");

test {
    _ = @import("naive_space_tree.zig");
}

fn expectVector(expected: zmath.Vec, actual: zmath.Vec, tolerance: f32) !void {
    inline for (0..4) |i| try std.testing.expectApproxEqAbs(expected[i], actual[i], tolerance);
}

test "chunk-local transforms preserve tiny vertices in far neighboring chunks" {
    // Adjacent integer chunks above f32's exact integer range must be subtracted
    // before conversion. This also checks the shared WGSL storage-buffer layout.
    try std.testing.expectEqual(80, @sizeOf(ChunkTransform));
    try std.testing.expectEqual(64, @offsetOf(ChunkTransform, "chunk"));
    const object: ChunkTransform = .{
        .chunk = .{ 301, 16777219, -16777219, 0 },
        .chunk_from_model = zmath.translation(0.125, 0.25, 0.5),
    };
    const relative = object.relativeTo(.{ 300, 16777218, -16777220, 0 });
    try expectVector(.{ 32.125, 32.25, 32.5, 1 }, relative[3], 0.00001);
    try expectVector(.{ 32.126, 32.252, 32.503, 1 }, utils.matApply(relative, .{ 0.001, 0.002, 0.003, 1 }), 0.00001);
}

test "negative boundaries and the x seam use the same local frame" {
    const negative = ChunkTransform.init(zmath.translation(-0.25, -32.25, -64));
    try std.testing.expectEqual(@Vector(4, i32){ 255, 126, 2, 0 }, negative.chunk);
    try expectVector(.{ 31.75, 31.75, 0, 1 }, negative.chunk_from_model[3], 0.00001);
    const across_seam = ChunkTransform.init(zmath.translation(-8191.75, 0, 0));
    const camera_chunk = chunks.getChunkCoords(.{ 8191.75, 0, 0 });
    try expectVector(.{ 32.25, 0, 0, 1 }, across_seam.relativeTo(camera_chunk)[3], 0.00001);
    const reverse = ChunkTransform.init(zmath.translation(8191.75, 0, 0));
    try expectVector(.{ -0.25, 0, 0, 1 }, reverse.relativeTo(across_seam.chunk)[3], 0.00001);
}

test "camera initialization agrees with updating its initial position" {
    var camera = Camera.init(1.5);
    const initial_chunk = camera.chunk;
    const initial_clip = camera.clip_from_world_chunked;
    camera.updatePosition(.{ 0, 0, 0 });
    try std.testing.expectEqual(initial_chunk, camera.chunk);
    for (initial_clip, camera.clip_from_world_chunked) |expected, actual| try expectVector(expected, actual, 0.00001);
}

test "camera and all shadow cascades are invariant under a distant chunk translation" {
    var near = Camera.init(1.5);
    near.updatePosition(.{ 3.25, -2.5, 6.125 });
    near.updateView(zmath.rotationZ(0.3));
    var far = Camera.init(1.5);
    far.updatePosition(.{ 3.25 + 32000, -2.5 + 320000, 6.125 - 32000 });
    far.updateView(zmath.rotationZ(0.3));

    const near_object = ChunkTransform.init(utils.matMul(zmath.translation(5.25, 40.5, 8.125), zmath.rotationX(0.4)));
    const far_object = ChunkTransform.init(utils.matMul(zmath.translation(32005.25, 320040.5, -31991.875), zmath.rotationX(0.4)));
    const near_model = near_object.relativeTo(near.chunk);
    const far_model = far_object.relativeTo(far.chunk);
    const vertex: zmath.Vec = .{ 0.001, 0.002, 0.003, 1 };
    try expectVector(
        utils.matApply(utils.matMul(near.clip_from_world_chunked, near_model), vertex),
        utils.matApply(utils.matMul(far.clip_from_world_chunked, far_model), vertex),
        0.00001,
    );

    var near_light = DirectionalLight.init(.{ .direction = .{ 0.5, 0.5, -1, 0 }, .color = .{ 1, 1, 1, 1 }, .intensity = 1 });
    var far_light = near_light;
    for (&near_light.cascades, &far_light.cascades) |*near_cascade, *far_cascade| {
        near_light.applyCameraFrustum(near_cascade, &near);
        far_light.applyCameraFrustum(far_cascade, &far);
        try std.testing.expectEqual(far.chunk, far_cascade.chunk);
        for (near_cascade.clip_from_chunk, far_cascade.clip_from_chunk) |expected, actual| try expectVector(expected, actual, 0.00001);
        const near_shadow = utils.matApply(utils.matMul(near_cascade.clip_from_chunk, near_model), vertex);
        const far_shadow = utils.matApply(utils.matMul(far_cascade.clip_from_chunk, far_model), vertex);
        try expectVector(near_shadow, far_shadow, 0.00001);
        // The CPU per-object path and GPU-style position-then-projection path agree.
        try expectVector(far_shadow, utils.matApply(far_cascade.clip_from_chunk, utils.matApply(far_model, vertex)), 0.00001);
    }
}

test "crossing a chunk boundary moves camera-space geometry continuously" {
    var before = Camera.init(1);
    before.updatePosition(.{ 31.875, 100000, 10 });
    var after = Camera.init(1);
    after.updatePosition(.{ 32.125, 100000, 10 });
    const object = ChunkTransform.init(zmath.translation(33, 100010, 11));
    const before_position = utils.matApply(before.view_from_world_chunked, object.relativeTo(before.chunk)[3]);
    const after_position = utils.matApply(after.view_from_world_chunked, object.relativeTo(after.chunk)[3]);
    try expectVector(.{ -0.25, 0, 0, 0 }, after_position - before_position, 0.00001);
}
