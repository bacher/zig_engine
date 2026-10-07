const layout = @import("test_world.zig").layout;
const std = @import("std");
const zmath = @import("zmath");
const chunks = @import("chunk_utils.zig");
const ChunkTransform = @import("chunk_transform.zig").ChunkTransform;
const Camera = @import("camera.zig").Camera;
const DirectionalLight = @import("light.zig").DirectionalLight;
const utils = @import("utils.zig");
const world_math = @import("world_math.zig");

test {
    _ = @import("naive_space_tree.zig");
}

fn expectVector(expected: zmath.Vec, actual: zmath.Vec, tolerance: f32) !void {
    inline for (0..4) |i| try std.testing.expectApproxEqAbs(expected[i], actual[i], tolerance);
}

test "f64 world translations are rebased before narrowing to the GPU matrix" {
    const object = ChunkTransform.init(&layout, world_math.translation(1e9 + 0.125, -1e9 - 0.25, 1e9 + 31.875));
    try expectVector(.{ 0.125, 31.75, 31.875, 1 }, object.chunk_from_model[3], 0.000001);
    try expectVector(.{ 0.125, -0.25, 31.875, 1 }, object.relativeTo(&layout, layout.getChunkCoords(.{ 1e9, -1e9, 1e9 }))[3], 0.000001);
    // The lost offset is observable if a caller narrows the absolute position first.
    const rounded_world: f32 = @floatCast(@as(f64, 1e9 + 0.125));
    try std.testing.expectEqual(@as(f32, 1e9), rounded_world);
}

test "small camera movements accumulate in f64 across distant chunk boundaries" {
    var camera = Camera.init(&layout, 1.5);
    camera.updatePosition(.{ 1e9 + 31.5, -1e9 + 31.5, 1e9 + 31.5 });
    const before_chunk = camera.chunk;
    for (0..1024) |_| camera.translate(.{ 1.0 / 1024.0, -2.0 / 1024.0, 3.0 / 1024.0 });
    try std.testing.expectEqual(world_math.Position{ 1e9 + 32.5, -1e9 + 29.5, 1e9 + 34.5 }, camera.position);
    try std.testing.expectEqual(@Vector(3, i64){ 1, 0, 1 }, layout.getChunkDelta(camera.chunk, before_chunk));
    try expectVector(.{ 0.5, 29.5, 2.5, 1 }, camera.getLocalPosition(), 0.000001);
    try expectVector(.{ -0.5, -29.5, -2.5, 1 }, camera.camera_from_world_chunked[3], 0.000001);
}

test "x wraps before conversion to the GPU integer chunk range" {
    const repeated_worlds: f64 = 16384.0 * 100000000.0;
    try std.testing.expectEqual(layout.getChunkCoords(.{ 0.125, 0, 0 }), layout.getChunkCoords(.{ repeated_worlds + 0.125, 0, 0 }));
    try std.testing.expectEqual(layout.getChunkCoords(.{ -0.125, 0, 0 }), layout.getChunkCoords(.{ -repeated_worlds - 0.125, 0, 0 }));
    const transform = ChunkTransform.init(&layout, world_math.translation(repeated_worlds + 0.125, 0, 0));
    try expectVector(.{ 0.125, 0, 0, 1 }, transform.chunk_from_model[3], 0.000001);
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
    const relative = object.relativeTo(&layout, .{ 300, 16777218, -16777220 });
    try expectVector(.{ 32.125, 32.25, 32.5, 1 }, relative[3], 0.00001);
    try expectVector(.{ 32.126, 32.252, 32.503, 1 }, utils.matApply(relative, .{ 0.001, 0.002, 0.003, 1 }), 0.00001);
}

test "signed chunk differences span the full i32 range and wrap repeated x worlds" {
    const low = std.math.minInt(i32);
    const high = std.math.maxInt(i32);
    const a: world_math.ChunkCoords = .{ low, high, low };
    const b: world_math.ChunkCoords = .{ high, low, high };
    const expected: @Vector(3, i64) = .{ 1, 4294967295, -4294967295 };
    try std.testing.expectEqual(expected, layout.getChunkDelta(a, b));
    try std.testing.expectEqual(-expected, layout.getChunkDelta(b, a));

    const object: ChunkTransform = .{
        .chunk = .{ -513, high, low, 0 },
        .chunk_from_model = zmath.translation(0.125, 0.25, 0.5),
    };
    try expectVector(.{ -31.875, 32.25, -31.5, 1 }, object.relativeTo(&layout, .{ 0, high - 1, low + 1 })[3], 0.00001);
}

test "camera supports the signed chunk limits after applying the world offset" {
    const low = std.math.minInt(i32);
    const high = std.math.maxInt(i32);
    var camera = Camera.init(&layout, 1);
    camera.updatePosition(.{
        0.125,
        (@as(f64, low) - layout.origin_chunk[1]) * chunks.CHUNK_SIZE + 0.25,
        (@as(f64, high) - layout.origin_chunk[2]) * chunks.CHUNK_SIZE + 0.5,
    });
    try std.testing.expectEqual(world_math.ChunkCoords{ layout.origin_chunk[0], low, high }, camera.chunk);
    try expectVector(.{ 0.125, 0.25, 0.5, 1 }, camera.getLocalPosition(), 0.00001);
    try expectVector(.{ -0.125, -0.25, -0.5, 1 }, camera.camera_from_world_chunked[3], 0.00001);
}

test "negative boundaries and the x seam use the same local frame" {
    const negative = ChunkTransform.init(&layout, world_math.translation(-0.25, -32.25, -64));
    try std.testing.expectEqual(@Vector(4, i32){ 255, 126, 2, 0 }, negative.chunk);
    try expectVector(.{ 31.75, 31.75, 0, 1 }, negative.chunk_from_model[3], 0.00001);
    const across_seam = ChunkTransform.init(&layout, world_math.translation(-8191.75, 0, 0));
    const camera_chunk = layout.getChunkCoords(.{ 8191.75, 0, 0 });
    try expectVector(.{ 32.25, 0, 0, 1 }, across_seam.relativeTo(&layout, camera_chunk)[3], 0.00001);
    const reverse = ChunkTransform.init(&layout, world_math.translation(8191.75, 0, 0));
    try expectVector(.{ -0.25, 0, 0, 1 }, reverse.relativeTo(&layout, across_seam.getChunkCoords())[3], 0.00001);
}

test "camera initialization agrees with updating its initial position" {
    var camera = Camera.init(&layout, 1.5);
    const initial_chunk = camera.chunk;
    const initial_clip = camera.clip_from_world_chunked;
    camera.updatePosition(.{ 0, 0, 0 });
    try std.testing.expectEqual(initial_chunk, camera.chunk);
    for (initial_clip, camera.clip_from_world_chunked) |expected, actual| try expectVector(expected, actual, 0.00001);
}

test "camera and all shadow cascades are invariant under a distant chunk translation" {
    var near = Camera.init(&layout, 1.5);
    near.updatePosition(.{ 3.25, -2.5, 6.125 });
    near.updateView(zmath.rotationZ(0.3));
    var far = Camera.init(&layout, 1.5);
    far.updatePosition(.{ 3.25 + 1e9, -2.5 + 1e9, 6.125 - 1e9 });
    far.updateView(zmath.rotationZ(0.3));

    const near_object = ChunkTransform.init(&layout, world_math.fromSRT(.{ 5.25, 40.5, 8.125 }, zmath.quatFromRollPitchYaw(0.4, 0, 0), 1));
    const far_object = ChunkTransform.init(&layout, world_math.fromSRT(.{ 5.25 + 1e9, 40.5 + 1e9, 8.125 - 1e9 }, zmath.quatFromRollPitchYaw(0.4, 0, 0), 1));
    const near_model = near_object.relativeTo(&layout, near.chunk);
    const far_model = far_object.relativeTo(&layout, far.chunk);
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
    var before = Camera.init(&layout, 1);
    before.updatePosition(.{ 31.875, 1000000000, 10 });
    var after = Camera.init(&layout, 1);
    after.updatePosition(.{ 32.125, 1000000000, 10 });
    const object = ChunkTransform.init(&layout, world_math.translation(33, 100010, 11));
    const before_position = utils.matApply(before.view_from_world_chunked, object.relativeTo(&layout, before.chunk)[3]);
    const after_position = utils.matApply(after.view_from_world_chunked, object.relativeTo(&layout, after.chunk)[3]);
    try expectVector(.{ -0.25, 0, 0, 0 }, after_position - before_position, 0.00001);
}

test "wrapped and unwrapped cameras and object projections coexist" {
    const WorldLayout = @import("world_layout.zig").WorldLayout;
    const wrapped = try WorldLayout.init(.{ .size_in_chunks = .{ 128, 64, 16 }, .wrap_x = true });
    const ordinary = try WorldLayout.init(.{ .size_in_chunks = .{ 128, 64, 16 }, .wrap_x = false });
    var wrapped_camera = Camera.init(&wrapped, 1);
    var ordinary_camera = Camera.init(&ordinary, 1);
    wrapped_camera.updatePosition(.{ 2047.75, 0, 0 });
    ordinary_camera.updatePosition(.{ 2047.75, 0, 0 });
    const matrix = world_math.translation(-2047.75, 0, 0);
    const wrapped_object = ChunkTransform.init(&wrapped, matrix);
    const ordinary_object = ChunkTransform.init(&ordinary, matrix);
    const wrapped_relative = wrapped_object.relativeTo(&wrapped, wrapped_camera.chunk);
    const ordinary_relative = ordinary_object.relativeTo(&ordinary, ordinary_camera.chunk);
    const wrapped_view = utils.matApply(wrapped_camera.view_from_world_chunked, wrapped_relative[3]);
    const ordinary_view = utils.matApply(ordinary_camera.view_from_world_chunked, ordinary_relative[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), wrapped_view[0], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, -4095.5), ordinary_view[0], 0.00001);
    wrapped_camera.translate(.{ 0.5, 0, 0 });
    ordinary_camera.translate(.{ 0.5, 0, 0 });
    try std.testing.expectEqual(@as(i32, 0), wrapped_camera.chunk[0]);
    try std.testing.expectEqual(@as(i32, 128), ordinary_camera.chunk[0]);

    const low = std.math.minInt(i32);
    const high = std.math.maxInt(i32);
    const delta = ordinary.getChunkDelta(.{ high, low, high }, .{ low, high, low });
    try std.testing.expectEqual(@Vector(3, i64){ 4294967295, -4294967295, 4294967295 }, delta);
    const adjacent = ChunkTransform{
        .chunk_from_model = zmath.translation(0.125, 0.25, 0.5),
        .chunk = .{ high, low, high, 0 },
    };
    try expectVector(.{ 32.125, -31.75, 32.5, 1 }, adjacent.relativeTo(&ordinary, .{ high - 1, low + 1, high - 1 })[3], 0.00001);
    ordinary_camera.updatePosition(.{ (@as(f64, low) - ordinary.origin_chunk[0]) * chunks.CHUNK_SIZE + 0.125, 0, 0 });
    try std.testing.expectEqual(@as(i32, low), ordinary_camera.chunk[0]);
    try expectVector(.{ 0.125, 0, 0, 1 }, ordinary_camera.getLocalPosition(), 0.00001);
}
