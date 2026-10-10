//! Climb planning, clearance, timing, and input regressions.
const std = @import("std");
const engine = @import("engine");
const collision = @import("terrain_collision.zig");
const Position = collision.Position;
const Fixture = @import("terrain_test_fixture.zig").Fixture;
const player_controller = @import("player_controller.zig");
const PlayerController = player_controller.PlayerController;
const Input = player_controller.Input;
const walk_speed = player_controller.walk_speed;
const climb_hold_seconds = player_controller.climb_hold_seconds;
const trajectory = @import("climb_trajectory.zig");
const climb_duration_seconds = trajectory.duration_seconds;
const climb_landing_distance = trajectory.landing_distance;
const climb_face_margin = trajectory.face_margin;

test "diagonal airborne catches ignore terrain outside the planned path" {
    for ([_]f64{ 1, -1 }) |sign| {
        for ([_]bool{ false, true }) |off_path_obstacle| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            fixture.fill(.{ -10, -10, -9 }, .{ 10, 10, -1 }, .stone);
            if (sign > 0) {
                fixture.fill(.{ 1, 1, -8 }, .{ 3, 2, -1 }, .none);
                if (off_path_obstacle) fixture.set(.{ 4, 1, 1 }, .stone);
            } else {
                fixture.fill(.{ -4, -3, -8 }, .{ -2, -2, -1 }, .none);
                if (off_path_obstacle) fixture.set(.{ -5, -2, 1 }, .stone);
            }
            for ([_]f64{ 30, 144, 1000 }) |fps| {
                var player = PlayerController.init(std.testing.allocator, .{ 0.5 * sign, 0.5 * sign, 0 });
                defer player.deinit();
                player.yaw = 0.5404195; // Roughly 31 degrees; D/A follows the diagonal.
                player.space_held_seconds = climb_hold_seconds;
                var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
                var now: f64 = 0;
                var caught_while_airborne = false;
                while (now < 1) {
                    const dt = @min(1 / fps, 1 - now);
                    now += dt;
                    const result = try player.update(&fixture.world, .{ .right = sign, .jump_down = true }, dt, now);
                    try std.testing.expect(!result.recovered);
                    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
                    caught_while_airborne = caught_while_airborne or (player.climb != null and !player.grounded);
                }
                try std.testing.expect(caught_while_airborne and player.grounded);
                try std.testing.expect(player.position[0] * sign > 4.2 and player.position[1] * sign > 2.8);
                try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
            }
        }
    }
}

test "diagonal landing clearance still rejects terrain on the planned path" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fill(.{ -4, -4, -9 }, .{ 10, 10, -1 }, .stone);
    fixture.fill(.{ 1, 1, -8 }, .{ 3, 2, -1 }, .none);
    var query: collision.Query = .{ .world = &fixture.world, .body = .{} };
    const start: Position = .{ 2.5, 1.7, -0.18 };
    const horizontal_delta: Position = .{ 1.286, 0.77, 0 };
    try std.testing.expect(trajectory.findLanding(&query, start, horizontal_delta, 0.5) != null);
    fixture.set(.{ 4, 2, 1 }, .stone);
    try std.testing.expect(trajectory.findLanding(&query, start, horizontal_delta, 0.5) == null);
}

test "jumping and holding Space catches a raised far lip without a second press" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.hole(4);
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    for ([_]f64{ 30, 144, 1000 }) |fps| {
        var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
        defer player.deinit();
        var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
        var now: f64 = 0;
        var climbed = false;
        while (now < 0.65) {
            const first_frame = now == 0;
            const dt = @min(1 / fps, 0.65 - now);
            now += dt;
            const result = try player.update(&fixture.world, .{
                .right = 1,
                .jump_down = true,
                .jump_pressed = first_frame,
            }, dt, now);
            try std.testing.expect(!result.recovered);
            try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
            climbed = climbed or player.climb != null;
        }
        try std.testing.expect(climbed and player.grounded and player.position[0] > 2);
        try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
    }
}

test "holding Space enables one-block climbing, release disables it, and tall walls remain solid" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 1.7, 0.5, 0 });
    defer player.deinit();
    _ = try player.update(&fixture.world, .{ .right = 1 }, 0.2, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 1.7), player.position[0], 0.000001);
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.7, 0.9);
    try std.testing.expect(player.auto_climb);
    try std.testing.expect(player.position[0] > 2);
    try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
    _ = try player.update(&fixture.world, .{}, 0.01, 0.91);
    try std.testing.expect(!player.auto_climb);
    fixture.fill(.{ 5, -1, 1 }, .{ 5, 1, 2 }, .stone);
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.4, 1.31);
    try std.testing.expect(player.position[0] <= 4.7 + collision.epsilon);
}

test "held Space catches the far lip of deep one-cell holes without ground support" {
    for ([_]i64{ 1, 2, 8 }) |depth| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.hole(depth);
        for ([_]f64{ 30, 144, 1000 }) |fps| {
            for ([_]f64{ 0, climb_hold_seconds }) |held_seconds| {
                var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
                defer player.deinit();
                player.space_held_seconds = held_seconds;
                var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
                var now: f64 = 0;
                var caught_while_airborne = false;
                while (now < 0.65) {
                    const dt = @min(1 / fps, 0.65 - now);
                    now += dt;
                    const previous_x = player.position[0];
                    const previous_z = player.position[2];
                    const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, dt, now);
                    try std.testing.expect(!result.recovered);
                    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
                    if (held_seconds == climb_hold_seconds) {
                        try std.testing.expect(player.position[0] - previous_x >= 0.85 * walk_speed * dt);
                    }
                    // A short catch may finish between rendered frames; lifting
                    // previously falling feet also demonstrates an airborne catch.
                    caught_while_airborne = caught_while_airborne or (player.climb != null and !player.grounded) or
                        (previous_z < 0 and player.position[2] > previous_z + collision.epsilon);
                }
                try std.testing.expect(caught_while_airborne);
                try std.testing.expect(player.position[0] > 2 and player.grounded);
                try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
            }
        }
        var walking = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
        defer walking.deinit();
        _ = try walking.update(&fixture.world, .{ .right = 1 }, 0.65, 0.65);
        try std.testing.expect(walking.position[2] < 0 and walking.climb == null);
    }
}

test "airborne climbing catches nearby tops but rejects tops more than half a metre above the feet" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.hole(4);
    for ([_]f64{ -0.25, -0.49, -0.51, -1.01 }) |height| {
        var player = PlayerController.init(std.testing.allocator, .{ 1.4, 0.5, height });
        defer player.deinit();
        player.vertical_velocity = -2;
        player.space_held_seconds = climb_hold_seconds;
        const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.001, 0.001);
        try std.testing.expect(!result.recovered);
        if (height > -0.5) {
            try std.testing.expect(player.climb != null and player.position[2] > height);
            _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.4, 0.401);
            try std.testing.expect(player.grounded and player.position[0] > 2);
            try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
        } else {
            try std.testing.expect(player.climb == null and player.position[2] < height);
        }
    }
}

test "an airborne Space press enables climbing immediately while a grounded press jumps" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.hole(4);
    var airborne = PlayerController.init(std.testing.allocator, .{ 1.4, 0.5, -0.25 });
    defer airborne.deinit();
    airborne.vertical_velocity = -2;
    _ = try airborne.update(&fixture.world, .{ .right = 1, .jump_down = true, .jump_pressed = true }, 0.001, 0.001);
    try std.testing.expect(airborne.auto_climb and airborne.climb != null);
    try std.testing.expect(airborne.position[2] > -0.25);
    _ = try airborne.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.005, 0.006);
    try std.testing.expect(airborne.auto_climb and airborne.climb != null);
    const height = airborne.position[2];
    _ = try airborne.update(&fixture.world, .{ .right = 1 }, 0.001, 0.007);
    try std.testing.expect(!airborne.auto_climb and airborne.climb == null);
    try std.testing.expect(airborne.vertical_velocity < 0 and airborne.position[2] < height);
    _ = try airborne.update(&fixture.world, .{ .right = 1, .jump_down = true, .jump_pressed = true }, 0.001, 0.008);
    try std.testing.expect(airborne.auto_climb and airborne.climb != null);

    var tapped = PlayerController.init(std.testing.allocator, .{ 1.4, 0.5, -0.25 });
    defer tapped.deinit();
    tapped.vertical_velocity = -2;
    // An airborne press/release within one frame does not latch climbing on.
    _ = try tapped.update(&fixture.world, .{ .right = 1, .jump_pressed = true }, 0.001, 0.001);
    try std.testing.expect(!tapped.auto_climb and tapped.climb == null);
    try std.testing.expect(tapped.position[2] < -0.25);

    var grounded = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer grounded.deinit();
    _ = try grounded.update(&fixture.world, .{ .right = 1, .jump_down = true, .jump_pressed = true }, 0.001, 0.001);
    try std.testing.expect(!grounded.auto_climb and grounded.climb == null);
    try std.testing.expect(grounded.vertical_velocity > 0 and grounded.position[2] > 0);
}

test "a raised far lip across a hole requires jumping before airborne climbing" {
    for ([_]i64{ 1, 4 }) |depth| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.hole(depth);
        fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
        for ([_]f64{ 30, 144, 1000 }) |fps| {
            var walking = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
            defer walking.deinit();
            walking.space_held_seconds = climb_hold_seconds;
            var query: collision.Query = .{ .world = &fixture.world, .body = walking.body };
            var now: f64 = 0;
            while (now < 0.65) {
                const dt = @min(1 / fps, 0.65 - now);
                now += dt;
                const result = try walking.update(&fixture.world, .{ .right = 1, .jump_down = true }, dt, now);
                try std.testing.expect(!result.recovered and walking.climb == null);
                try std.testing.expectEqual(collision.Overlap.clear, query.overlap(walking.position, false));
            }
            try std.testing.expect(walking.position[0] < 1.7 + collision.epsilon and walking.position[2] < 0);

            var jumping = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
            defer jumping.deinit();
            now = 0;
            var caught_while_airborne = false;
            // Press to jump, release, then press and hold again during flight.
            for ([_]f64{ 0.02, 0.05, 0.65 }, 0..) |checkpoint, phase| {
                var first_frame = true;
                while (now < checkpoint) {
                    const dt = @min(1 / fps, checkpoint - now);
                    now += dt;
                    const result = try jumping.update(&fixture.world, .{
                        .right = 1,
                        .jump_down = phase != 1,
                        .jump_pressed = first_frame and phase != 1,
                    }, dt, now);
                    first_frame = false;
                    try std.testing.expect(!result.recovered);
                    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(jumping.position, false));
                    if (phase == 2) try std.testing.expect(jumping.auto_climb);
                    if (jumping.climb != null and !jumping.grounded) {
                        caught_while_airborne = true;
                        try std.testing.expect(now < 0.05 + climb_hold_seconds);
                    }
                }
            }
            try std.testing.expect(caught_while_airborne and jumping.grounded and jumping.position[0] > 2);
            try std.testing.expectApproxEqAbs(@as(f64, 1), jumping.position[2], 0.000001);
        }
    }
}

test "held Space cannot turn a jump into a climb onto a two-block column" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 2, 1, 1 }, .stone);
    for ([_]f64{ 30, 144, 1000 }) |fps| {
        var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
        defer player.deinit();
        var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
        var now: f64 = 0;
        while (now < 1.6) {
            const jump_pressed = now == 0;
            const dt = @min(1 / fps, 1.6 - now);
            now += dt;
            const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true, .jump_pressed = jump_pressed }, dt, now);
            try std.testing.expect(!result.recovered);
            try std.testing.expect(player.climb == null);
            try std.testing.expect(player.position[2] <= 1.25 + collision.epsilon);
            try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
        }
        try std.testing.expect(player.position[0] <= 1.7 + collision.epsilon and player.grounded);
        try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
    }
}

test "anticipated climb moves forward and up before contact without overlapping any substep" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    var previous = player.position;
    var first_rise: f64 = 0;
    var middle_rise: f64 = 0;
    var last_rise: f64 = 0;
    for (0..48) |index| {
        const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 1.0 / 120.0, @as(f64, @floatFromInt(index + 1)) / 120);
        try std.testing.expect(!result.recovered);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
        // Preserve nearly ordinary walking speed throughout the approach and exit.
        try std.testing.expect(player.position[0] - previous[0] > 0.035);
        if (player.position[2] < 1 - collision.epsilon) try std.testing.expect(player.position[0] + player.body.half_width < 2);
        const rise = player.position[2] - previous[2];
        try std.testing.expect(rise < 0.055);
        if (index == 0) {
            first_rise = rise;
            try std.testing.expect(player.position[0] < 1.7);
            try std.testing.expect(player.position[2] > 0);
        }
        if (index == 14) middle_rise = rise;
        if (index == 29) last_rise = rise;
        previous = player.position;
    }
    try std.testing.expect(first_rise < middle_rise / 4 and last_rise < middle_rise / 4);
    try std.testing.expect(player.position[0] > 2);
    try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
    try std.testing.expect(player.grounded and player.climb == null);
}

test "anticipatory arc timing matches across short, long and fractional frames" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    var baseline = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer baseline.deinit();
    baseline.space_held_seconds = climb_hold_seconds;
    _ = try baseline.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.125, 0.125);
    const halfway = baseline.position;
    _ = try baseline.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.275, 0.4);
    for ([_]f64{ 30, 60, 120, 144, 240, 1000 }) |fps| {
        var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        var now: f64 = 0;
        for ([_]f64{ 0.125, 0.4 }) |checkpoint| {
            while (now < checkpoint) {
                const dt = @min(1 / fps, checkpoint - now);
                now += dt;
                _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, dt, now);
            }
            const expected = if (checkpoint == 0.125) halfway else baseline.position;
            try std.testing.expect(@reduce(.Max, @abs(player.position - expected)) < 0.000001);
        }
        try std.testing.expect(player.grounded and player.climb == null);
    }
}

fn expectClimbFramePartitions(fixture: *Fixture, start: Position, input: Input, held_seconds: f64, checkpoints: [4]f64) ![4]Position {
    var expected: [checkpoints.len]Position = undefined;
    var baseline = PlayerController.init(std.testing.allocator, start);
    defer baseline.deinit();
    baseline.space_held_seconds = held_seconds;
    var previous_time: f64 = 0;
    for (checkpoints, 0..) |checkpoint, index| {
        _ = try baseline.update(&fixture.world, input, checkpoint - previous_time, checkpoint);
        expected[index] = baseline.position;
        previous_time = checkpoint;
    }
    for ([_]f64{ 30, 60, 120, 144, 240, 1000, 0 }) |fps| {
        var player = PlayerController.init(std.testing.allocator, start);
        defer player.deinit();
        player.space_held_seconds = held_seconds;
        var now: f64 = 0;
        var frame: usize = 0;
        const irregular_frames = [_]f64{ 0.003, 0.017, 0.041, 0.00037 };
        var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
        for (checkpoints, expected) |checkpoint, position| {
            while (now < checkpoint) {
                const interval = if (fps == 0) irregular_frames[frame % irregular_frames.len] else 1 / fps;
                const dt = @min(interval, checkpoint - now);
                now += dt;
                frame += 1;
                const result = try player.update(&fixture.world, input, dt, now);
                try std.testing.expect(!result.recovered);
                try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
            }
            try std.testing.expect(@reduce(.Max, @abs(player.position - position)) < 0.000001);
        }
        try std.testing.expectEqual(baseline.grounded, player.grounded);
        try std.testing.expectEqual(baseline.climb == null, player.climb == null);
    }
    return expected;
}

test "climb preview entry matches across distant approaches and frame partitions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    const expected = try expectClimbFramePartitions(&fixture, .{ -0.5, 0.5, 0 }, .{ .right = 1, .jump_down = true }, climb_hold_seconds, .{ 0.19, 0.315, 0.46, 0.6 });
    // The face is 2.2m away; the 1.25m preview starts the arc at exactly 0.19s.
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), expected[1][2], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), expected[3][2], 0.000001);
}

test "diagonal corner preview entry matches frame partitions in both directions" {
    for ([_]f64{ 1, -1 }) |sign| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.floor();
        if (sign > 0) fixture.fill(.{ 2, 2, 0 }, .{ 8, 8, 0 }, .stone) else fixture.fill(.{ -9, -9, 0 }, .{ -3, -3, 0 }, .stone);
        const onset = 2.2 / 3.0 - climb_duration_seconds;
        const expected = try expectClimbFramePartitions(&fixture, .{ -0.5 * sign, -1.19 * sign, 0 }, .{ .right = 0.75 * sign, .forward = sign, .jump_down = true }, climb_hold_seconds, .{ onset, onset + 0.125, onset + 0.26, onset + 0.4 });
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), expected[1][2], 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1), expected[3][2], 0.000001);
    }
}

test "held Space activates climbing at the same instant across frame partitions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    for ([_]f64{ 0, 0.2 }) |held_seconds| {
        const onset = climb_hold_seconds - held_seconds;
        const expected = try expectClimbFramePartitions(&fixture, .{ 0.5, 0.5, 0 }, .{ .right = 1, .jump_down = true }, held_seconds, .{ onset, onset + 0.125, onset + 0.26, onset + 0.4 });
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), expected[1][2], 0.000001);
    }
}

test "consecutive climbs start at each exit across frame partitions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    for (2..10) |x| fixture.fill(.{ @intCast(x), -1, 0 }, .{ @intCast(x), 1, @intCast(x - 2) }, .stone);
    const exit_time = climb_duration_seconds + (climb_landing_distance + climb_face_margin) / walk_speed;
    const expected = try expectClimbFramePartitions(&fixture, .{ 0.5, 0.5, 0 }, .{ .right = 1, .jump_down = true }, climb_hold_seconds, .{ exit_time, 2 * exit_time, 3 * exit_time, 1.1 });
    for (0..3) |index| try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(index + 1)), expected[index][2], 0.000001);
}

test "horizontal contact preview uses the body corner and skips cubes off the path" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 2, 2, 0 }, .stone);
    var query: collision.Query = .{ .world = &fixture.world, .body = .{} };
    // Y reaches the face first, but the box only contacts the corner once X arrives.
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), query.horizontalContactTime(.{ 0.5, 0.5, 0 }, .{ 3, 4, 0 }, 1).?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2 / 3.0), query.horizontalContactTime(.{ 3.5, 3.5, 0 }, .{ -3, -4, 0 }, 1).?, 0.000001);
    // The swept bounding rectangle contains the block; the diagonal path misses it.
    try std.testing.expect(query.horizontalContactTime(.{ 0.5, -2.5, 0 }, .{ 3, 4, 0 }, 1.25) == null);
}

test "small mouse-look changes preserve the short climb path but sharp turns cancel it" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.08, 0.08);
    player.look(.{ -20, 0 }); // Roughly six degrees of view adjustment.
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.01, 0.09);
    try std.testing.expect(player.climb != null);
    const height = player.position[2];
    player.look(.{ -120, 0 });
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.01, 0.1);
    try std.testing.expect(player.climb == null);
    try std.testing.expect(player.position[2] < height);
}

test "diagonal anticipation and consecutive stair treads stay collision safe" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, 2, 0 }, .{ 8, 8, 0 }, .stone);
    var diagonal = PlayerController.init(std.testing.allocator, .{ 0.9, 0.9, 0 });
    defer diagonal.deinit();
    diagonal.space_held_seconds = climb_hold_seconds;
    var query: collision.Query = .{ .world = &fixture.world, .body = diagonal.body };
    for (0..72) |index| {
        const result = try diagonal.update(&fixture.world, .{ .forward = 1, .right = 1, .jump_down = true }, 1.0 / 120.0, @as(f64, @floatFromInt(index + 1)) / 120);
        try std.testing.expect(!result.recovered);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(diagonal.position, false));
        if (index == 0) try std.testing.expect(diagonal.position[2] > 0);
    }
    try std.testing.expect(diagonal.position[0] > 2 and diagonal.position[1] > 2);
    try std.testing.expectApproxEqAbs(@as(f64, 1), diagonal.position[2], 0.000001);
    fixture.fill(.{ 2, -1, 0 }, .{ 3, 1, 0 }, .stone);
    fixture.fill(.{ 4, -1, 0 }, .{ 5, 1, 1 }, .stone);
    fixture.fill(.{ 6, -1, 0 }, .{ 9, 1, 2 }, .stone);
    var stairs = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer stairs.deinit();
    stairs.space_held_seconds = climb_hold_seconds;
    for (0..192) |index| {
        const result = try stairs.update(&fixture.world, .{ .right = 1, .jump_down = true }, 1.0 / 120.0, @as(f64, @floatFromInt(index + 1)) / 120);
        try std.testing.expect(!result.recovered);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(stairs.position, false));
    }
    try std.testing.expect(stairs.position[0] > 6);
    try std.testing.expectApproxEqAbs(@as(f64, 3), stairs.position[2], 0.000001);
    try std.testing.expect(stairs.grounded);
}

test "missing step terrain cancels the preview arc and stays a solid barrier" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 30, -1, -1 }, .{ 36, 1, -1 }, .stone);
    fixture.fill(.{ 32, -1, 0 }, .{ 36, 1, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 30.5, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.04, 0.04);
    try std.testing.expect(player.climb != null);
    const height = player.position[2];
    const chunk = fixture.world.layout.getChunkCoords(.{ 32.5, 0.5, 0 });
    fixture.world.removeChunk(chunk);
    const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.01, 0.05);
    try std.testing.expect(!result.recovered);
    try std.testing.expectEqualDeep(chunk, result.missing_chunk.?);
    try std.testing.expect(player.climb == null and player.position[2] < height);
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.6, 0.65);
    try std.testing.expect(player.position[0] <= 31.7 + collision.epsilon);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
}

test "releasing Space or movement during the approach falls safely without becoming embedded" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    for ([_]Input{ .{ .right = 1 }, .{ .jump_down = true } }) |released| {
        var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.125, 0.125);
        const height = player.position[2];
        var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
        for (0..72) |index| {
            const result = try player.update(&fixture.world, released, 1.0 / 120.0, 0.125 + @as(f64, @floatFromInt(index + 1)) / 120);
            try std.testing.expect(!result.recovered);
            try std.testing.expect(player.climb == null);
            try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
            if (index == 0) try std.testing.expect(player.position[2] < height);
        }
        try std.testing.expect(player.grounded);
        try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
    }
}

test "anticipated climb crosses the periodic x seam using the nearest block image" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fill(.{ 62, -1, -1 }, .{ 68, 1, -1 }, .stone);
    fixture.fill(.{ 64, -1, 0 }, .{ 68, 1, 0 }, .stone);
    const width: f64 = @floatFromInt(fixture.world.layout.size_in_blocks[0]);
    var player = PlayerController.init(std.testing.allocator, .{ 62.5 + 3 * width, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    for (0..48) |index| {
        const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 1.0 / 120.0, @as(f64, @floatFromInt(index + 1)) / 120);
        try std.testing.expect(!result.recovered);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
        if (index == 0) try std.testing.expect(player.position[2] > 0);
    }
    try std.testing.expect(player.position[0] > 64 + 3 * width);
    try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
    try std.testing.expect(player.grounded);
}

test "auto-climbing raises the body and camera smoothly over multiple 120Hz frames" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 1.7, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    var camera = std.meta.Child(@TypeOf(@as(engine.Scene, undefined).camera)).init(fixture.world.layout, 1);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    var previous_height: f64 = 0;
    for (0..30) |index| {
        const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 1.0 / 120.0, @as(f64, @floatFromInt(index + 1)) / 120.0);
        try std.testing.expect(!result.recovered);
        try std.testing.expect(player.position[2] > previous_height);
        // No frame may snap up more than seven centimetres at 120Hz.
        try std.testing.expect(player.position[2] - previous_height < 0.07);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
        player.applyCamera(&camera);
        try std.testing.expectApproxEqAbs(player.position[2] + player.body.eye_height, camera.position[2], 0.000001);
        if (index == 14) try std.testing.expectApproxEqAbs(@as(f64, 0.5), player.position[2], 0.000001);
        previous_height = player.position[2];
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.05, 0.3);
    try std.testing.expect(player.position[0] > 1.7);
    try std.testing.expect(player.grounded);
    try std.testing.expect(player.climb == null);
    try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
}

test "auto-climbing duration follows elapsed time across frame rates and long frames" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    for ([_]f64{ 30, 60, 120, 144, 240, 1000 }) |fps| {
        var player = PlayerController.init(std.testing.allocator, .{ 1.7, 0.5, 0 });
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        var now: f64 = 0;
        for ([_]f64{ 0.125, 0.4 }) |checkpoint| {
            while (now < checkpoint) {
                const dt = @min(1 / fps, checkpoint - now);
                now += dt;
                _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, dt, now);
            }
            const height: f64 = if (checkpoint == 0.125) 0.5 else 1;
            try std.testing.expectApproxEqAbs(height, player.position[2], 0.000001);
        }
        try std.testing.expect(player.grounded);
        try std.testing.expect(player.position[0] > 2);
    }
    var player = PlayerController.init(std.testing.allocator, .{ 1.7, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.125, 0.125);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), player.position[2], 0.000001);
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.275, 0.4);
    try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
    try std.testing.expect(player.grounded);
    try std.testing.expect(player.position[0] > 2);
}

test "releasing Space, stopping, or moving away cancels a climb and restores gravity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.set(.{ 2, 0, 0 }, .stone);
    for ([_]Input{
        .{ .right = 1 },
        .{ .jump_down = true },
        .{ .right = -1, .jump_down = true },
    }) |input| {
        var player = PlayerController.init(std.testing.allocator, .{ 1.7, 0.5, 0 });
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.08, 0.08);
        const height = player.position[2];
        try std.testing.expect(height > 0 and height < 1);
        const result = try player.update(&fixture.world, input, 0.01, 0.09);
        try std.testing.expect(!result.recovered);
        try std.testing.expect(player.climb == null);
        try std.testing.expect(player.position[2] < height);
        try std.testing.expect(player.vertical_velocity < 0);
        _ = try player.update(&fixture.world, input, 0.5, 0.59);
        try std.testing.expect(player.grounded);
        try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
    }
}

test "new overhead terrain or a removed landing cancels an ongoing climb safely" {
    for ([_]bool{ false, true }) |add_ceiling| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.floor();
        fixture.set(.{ 2, 0, 0 }, .stone);
        var player = PlayerController.init(std.testing.allocator, .{ 1.7, 0.5, 0 });
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.04, 0.04);
        const height = player.position[2];
        try std.testing.expect(height > 0 and height < 0.2);
        if (add_ceiling) {
            fixture.fill(.{ 1, 0, 2 }, .{ 2, 0, 2 }, .stone);
        } else {
            fixture.set(.{ 2, 0, 0 }, .none);
        }
        player.terrainChanged();
        const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.01, 0.05);
        try std.testing.expect(!result.recovered);
        try std.testing.expect(player.climb == null);
        try std.testing.expect(player.position[2] < height);
        var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
        _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.5, 0.55);
        try std.testing.expect(player.grounded);
        try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
    }
}

test "auto-climbing respects overhead clearance" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.set(.{ 2, 0, 0 }, .stone);
    fixture.fill(.{ 1, 0, 2 }, .{ 2, 0, 2 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 1.7, 0.5, 0 });
    defer player.deinit();
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.4, 0.4);
    try std.testing.expectApproxEqAbs(@as(f64, 1.7), player.position[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
}
