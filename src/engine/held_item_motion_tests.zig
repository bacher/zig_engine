const std = @import("std");
const zmath = @import("zmath");
const motion = @import("held_item_motion.zig");
const Pose = @import("held_item_pose.zig").Pose;
const utils = @import("utils.zig");
const Position = @import("world_math.zig").Position;

fn input(position: Position) motion.Input {
    return .{ .position = position, .view_from_world = zmath.rotationX(-std.math.pi / 2.0) };
}

fn advance(state: *motion.Motion, sample: motion.Input, frames: usize) void {
    for (0..frames) |_| state.update(sample, 1.0 / 60.0);
}

test "hybrid preserves the approved resting pose and settles after movement and look" {
    const rest: Pose = .{};
    const projection = zmath.perspectiveFovRh(std.math.pi / 4.0, 16.0 / 9.0, 0.01, 200);
    var state: motion.Motion = .{};
    var sample = input(.{ 0, 0, 0 });
    advance(&state, sample, 120);
    try std.testing.expectEqualDeep(motion.Offset{}, state.offset);
    try std.testing.expectEqualDeep(rest.viewFromItem(projection), rest.withMotion(state.offset).viewFromItem(projection));
    var peak_motion: f32 = 0;
    for (0..60) |_| {
        sample.position[0] += 5.0 / 60.0;
        state.update(sample, 1.0 / 60.0);
        peak_motion = @max(peak_motion, @abs(state.offset.translation[0]) + @abs(state.offset.translation[1]));
    }
    try std.testing.expect(peak_motion > 0.001);
    sample.look_angles = .{ 0.5, 0.2 };
    sample.view_from_world = utils.matMul(zmath.rotationX(-0.2), utils.matMul(zmath.rotationY(-0.5), zmath.rotationX(-std.math.pi / 2.0)));
    advance(&state, sample, 60);
    sample.look_angles[1] = 0;
    sample.view_from_world = utils.matMul(zmath.rotationY(-0.5), zmath.rotationX(-std.math.pi / 2.0));
    advance(&state, sample, 300);
    try std.testing.expectEqualDeep(motion.Offset{}, state.offset);
}

test "inertia opposes acceleration and reverses on braking even before velocity reaches zero" {
    var state: motion.Motion = .{ .tuning = .{ .bob_amplitude = 0, .direction_lag = 0 } };
    var sample = input(.{ 0, 0, 0 });
    state.update(sample, 1.0 / 60.0);
    for (0..6) |_| {
        sample.position[0] += 5.0 / 60.0;
        state.update(sample, 1.0 / 60.0);
    }
    try std.testing.expect(state.offset.translation[0] < -0.001);
    for (0..120) |_| {
        sample.position[0] += 5.0 / 60.0;
        state.update(sample, 1.0 / 60.0);
    }
    // Still moving right, but decelerating strongly: the item moves ahead of the grip.
    for (0..6) |frame| {
        const speed = 5 - @as(f64, @floatFromInt(frame + 1)) * 0.6;
        sample.position[0] += speed / 60.0;
        state.update(sample, 1.0 / 60.0);
    }
    try std.testing.expect(state.velocity_world[0] > 0);
    try std.testing.expect(state.offset.translation[0] > 0.001);
}

test "vertical takeoff and landing move the item while gait fades in flight" {
    var state: motion.Motion = .{};
    var sample = input(.{ 0, 0, 0 });
    state.update(sample, 1.0 / 60.0);
    sample.grounded = false;
    sample.gait_enabled = false;
    for (0..6) |_| {
        sample.position[2] += 4.0 / 60.0;
        state.update(sample, 1.0 / 60.0);
    }
    try std.testing.expect(state.offset.translation[1] < -0.001);
    for (0..30) |_| {
        sample.position[2] -= 3.0 / 60.0;
        state.update(sample, 1.0 / 60.0);
    }
    const before_landing = state.offset.translation[1];
    sample.grounded = true;
    sample.gait_enabled = true;
    advance(&state, sample, 6);
    try std.testing.expect(state.offset.translation[1] < before_landing - 0.001);
    advance(&state, sample, 300);
    try std.testing.expectEqualDeep(motion.Offset{}, state.offset);
}

fn profilePosition(time: f64) Position {
    const x = if (time < 0.2) 12.5 * time * time else if (time < 1.2) 0.5 + 5 * (time - 0.2) else if (time < 1.4) blk: {
        const t = time - 1.2;
        break :blk 5.5 + 5 * t - 12.5 * t * t;
    } else 6;
    return .{ x, 0, 0 };
}

fn runProfile(fps: f64, end: f64, origin: Position) motion.Offset {
    var state: motion.Motion = .{};
    state.update(input(origin), 1 / fps);
    const frames: usize = @intFromFloat(@round(end * fps));
    for (0..frames) |frame| state.update(input(origin + profilePosition(@as(f64, @floatFromInt(frame + 1)) / fps)), 1 / fps);
    return state.offset;
}

test "bob and spring response are consistent across frame rates and large world positions" {
    for ([_]f64{ 0.5, 1.3, 1.5 }) |time| {
        const reference = runProfile(240, time, @splat(0));
        for ([_]f64{ 30, 60, 120 }) |fps| {
            const actual = runProfile(fps, time, @splat(0));
            inline for (0..3) |axis| {
                try std.testing.expectApproxEqAbs(reference.translation[axis], actual.translation[axis], 0.008);
                try std.testing.expectApproxEqAbs(reference.rotation_degrees[axis], actual.rotation_degrees[axis], 0.3);
            }
        }
        const distant = runProfile(240, time, .{ 1000000000, -1000000000, 1000000000 });
        inline for (0..3) |axis| try std.testing.expectApproxEqAbs(reference.translation[axis], distant.translation[axis], 0.0001);
    }
}

test "camera turns do not invent acceleration and look angle wrapping stays smooth" {
    var state: motion.Motion = .{ .tuning = .{ .look_sway = 0, .bob_amplitude = 0, .direction_lag = 0 } };
    var sample = input(.{ 0, 0, 0 });
    state.update(sample, 1.0 / 60.0);
    for (0..240) |_| {
        sample.position[0] += 5.0 / 60.0;
        state.update(sample, 1.0 / 60.0);
    }
    sample.look_angles[0] = 1;
    sample.view_from_world = utils.matMul(zmath.rotationY(-1), zmath.rotationX(-std.math.pi / 2.0));
    for (0..20) |_| {
        sample.position[0] += 5.0 / 60.0;
        state.update(sample, 1.0 / 60.0);
        try std.testing.expect(@abs(state.offset.translation[0]) < 0.0001);
    }
    state.reset();
    sample.look_angles[0] = std.math.pi - 0.01;
    state.update(sample, 1.0 / 60.0);
    sample.look_angles[0] = -std.math.pi + 0.01;
    state.update(sample, 1.0 / 60.0);
    try std.testing.expect(@abs(state.look_velocity[0]) < 1);
}

test "focus loss, teleports and invalid frame durations reset motion without losing tuning" {
    const tuning: motion.Tuning = .{ .pitch_shift = 0.12, .pitch_follow_time = 0.25 };
    var state: motion.Motion = .{ .tuning = tuning };
    var sample = input(.{ 0, 0, 0 });
    for ([_]f64{ 0, -1, 1, std.math.nan(f64), 1e-40 }) |elapsed| {
        state.offset.translation = .{ 0.1, 0.1, 0.1 };
        state.update(sample, elapsed);
        try std.testing.expectEqualDeep(motion.Offset{}, state.offset);
        try std.testing.expectEqualDeep(tuning, state.tuning);
    }
    state.update(sample, 1.0 / 60.0);
    sample.position[0] = 100;
    state.update(sample, 1.0 / 60.0);
    try std.testing.expectEqualDeep(motion.Offset{}, state.offset);
    sample.active = false;
    state.update(sample, 1.0 / 60.0);
    try std.testing.expect(state.previous == null);
}

test "duration resets preserve held pitch and discard the movement baseline" {
    const tuning: motion.Tuning = .{ .strength = 0.5, .pitch_shift = 0.12 };
    for ([_]f32{ -std.math.pi / 4.0, std.math.pi / 4.0 }) |pitch| {
        for ([_]f64{ 0, -1, 0.3, std.math.nan(f64), 1e-40 }) |elapsed| {
            var state: motion.Motion = .{ .tuning = tuning };
            var sample = input(.{ 0, 0, 0 });
            sample.look_angles[1] = pitch;
            state.update(sample, 1.0 / 60.0);
            const resting = state.offset;
            for (0..6) |_| {
                sample.position[0] += 5.0 / 60.0;
                state.update(sample, 1.0 / 60.0);
            }
            try std.testing.expect(@abs(state.offset.translation[0]) > 0.001);
            state.update(sample, elapsed);
            try std.testing.expectEqualDeep(resting, state.offset);
            try std.testing.expectEqualDeep(tuning, state.tuning);
            try std.testing.expect(state.previous == null);
            // A resumed sample cannot differentiate movement during the pause.
            sample.position[0] += 1;
            state.update(sample, 1.0 / 60.0);
            try std.testing.expectEqualDeep(resting, state.offset);
        }
    }
}

test "inactive samples retain pitch height without carrying inertia into reactivation" {
    var state: motion.Motion = .{};
    var sample = input(.{ 0, 0, 0 });
    sample.look_angles[1] = -std.math.pi / 4.0;
    state.update(sample, 1.0 / 60.0);
    const resting = state.offset;
    for (0..6) |_| {
        sample.position[0] += 5.0 / 60.0;
        state.update(sample, 1.0 / 60.0);
    }
    sample.active = false;
    advance(&state, sample, 60);
    try std.testing.expectEqualDeep(resting, state.offset);
    try std.testing.expect(state.previous == null);
    sample.active = true;
    sample.position[0] += 1;
    state.update(sample, 1.0 / 60.0);
    try std.testing.expectEqualDeep(resting, state.offset);
}

test "invalid camera samples clear motion instead of retaining an invalid pitch" {
    inline for (0..5) |invalid| {
        var state: motion.Motion = .{};
        var sample = input(.{ 0, 0, 0 });
        sample.look_angles[1] = 0.6;
        state.update(sample, 1.0 / 60.0);
        if (invalid < 3) sample.position[invalid] = std.math.nan(f64) else sample.look_angles[invalid - 3] = std.math.nan(f32);
        state.update(sample, 1.0 / 60.0);
        try std.testing.expectEqualDeep(motion.Offset{}, state.offset);
        try std.testing.expect(state.previous == null);
    }
}

test "gait reference speed controls amplitude without changing distance-based cadence" {
    var normal: motion.Motion = .{ .tuning = .{ .acceleration_lag = 0, .direction_lag = 0 } };
    var slower_bob = normal;
    slower_bob.tuning.gait_reference_speed = 10;
    var sample = input(.{ 0, 0, 0 });
    normal.update(sample, 1.0 / 60.0);
    slower_bob.update(sample, 1.0 / 60.0);
    for (0..120) |_| {
        sample.position[0] += 5.0 / 60.0;
        normal.update(sample, 1.0 / 60.0);
        slower_bob.update(sample, 1.0 / 60.0);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1), normal.bob_weight, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), slower_bob.bob_weight, 0.000001);
    try std.testing.expectEqual(normal.phase, slower_bob.phase);
    inline for (0..3) |axis| try std.testing.expectApproxEqAbs(normal.offset.translation[axis] * 0.5, slower_bob.offset.translation[axis], 0.000001);
}

test "pitch shift eases toward held angles and persists after transient motion settles" {
    var state: motion.Motion = .{};
    var sample = input(.{ 0, 0, 0 });
    state.update(sample, 1.0 / 60.0);
    for ([_]f32{ -std.math.pi / 4.0, std.math.pi / 4.0 }) |pitch| {
        sample.look_angles[1] = pitch;
        const target = -@sin(pitch) * state.tuning.pitch_shift;
        state.update(sample, 1.0 / 60.0);
        try std.testing.expect(@abs(state.pitch_offset - target) > 0.01);
        advance(&state, sample, 300);
        try std.testing.expectApproxEqAbs(target, state.offset.translation[1], 0.000001);
        try std.testing.expectEqual(@as(f32, 0), state.offset.translation[0]);
        try std.testing.expectEqual(@as(f32, 0), state.offset.translation[2]);
        try std.testing.expectEqualDeep(@as(motion.Vec3, @splat(0)), state.offset.rotation_degrees);
        const held_offset = state.offset;
        advance(&state, sample, 120);
        try std.testing.expectEqualDeep(held_offset, state.offset);
        sample.look_angles[1] = 0;
        advance(&state, sample, 300);
        try std.testing.expectEqualDeep(motion.Offset{}, state.offset);
    }
}

fn runPitchRamp(fps: f64) !f32 {
    var state: motion.Motion = .{ .tuning = .{ .look_sway = 0 } };
    var sample = input(.{ 0, 0, 0 });
    state.update(sample, 1 / fps);
    const frames: usize = @intFromFloat(2 * fps);
    for (0..frames) |frame| {
        sample.look_angles[1] = @as(f32, @floatFromInt(frame + 1)) / @as(f32, @floatCast(fps)) * 0.4;
        const previous = state.pitch_offset;
        state.update(sample, 1 / fps);
        try std.testing.expect(state.pitch_offset < previous);
        try std.testing.expect(state.pitch_offset > -@sin(sample.look_angles[1]) * state.tuning.pitch_shift);
    }
    return state.offset.translation[1];
}

test "slow pitch changes follow gradually with consistent response across frame rates" {
    const reference = try runPitchRamp(240);
    try std.testing.expect(reference < -0.05);
    for ([_]f64{ 30, 60, 120 }) |fps| {
        try std.testing.expectApproxEqAbs(reference, try runPitchRamp(fps), 0.0005);
    }
}

test "pitch initializes at the held angle and remains bounded independently of rotation" {
    var state: motion.Motion = .{ .tuning = .{ .strength = 0.5 } };
    var sample = input(.{ 0, 0, 0 });
    sample.look_angles[1] = -std.math.pi;
    state.update(sample, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(state.tuning.pitch_shift * 0.5, state.offset.translation[1], 0.000001);
    advance(&state, sample, 300);
    try std.testing.expectEqualDeep(@as(motion.Vec3, @splat(0)), state.offset.rotation_degrees);
    // Teleports discard inertia while preserving the correct grip height.
    sample.position[0] = 100;
    state.update(sample, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(state.tuning.pitch_shift * 0.5, state.offset.translation[1], 0.000001);
    state.tuning.strength = 0;
    state.update(sample, 1.0 / 60.0);
    try std.testing.expectEqualDeep(motion.Offset{}, state.offset);
}

test "motion rotates around the item centre and translates in camera space" {
    const projection = zmath.perspectiveFovRh(std.math.pi / 4.0, 1, 0.01, 200);
    const rest: Pose = .{};
    const original = utils.matApply(rest.viewFromItem(projection), .{ 0.5, 0.5, 0.5, 1 });
    const animated = rest.withMotion(.{ .translation = .{ 0.03, 0.04, -0.02 }, .rotation_degrees = .{ 3, -2, 1 } });
    const centre = utils.matApply(animated.viewFromItem(projection), .{ 0.5, 0.5, 0.5, 1 });
    try std.testing.expectApproxEqAbs(original[0] + 0.03, centre[0], 0.00001);
    try std.testing.expectApproxEqAbs(original[1] + 0.04, centre[1], 0.00001);
    try std.testing.expectApproxEqAbs(original[2] - 0.02, centre[2], 0.00001);
}

test "arbitrary model grip remains anchored when scaling and animating a held item" {
    const projection = zmath.perspectiveFovRh(std.math.pi / 4.0, 1.5, 0.01, 200);
    const rest: Pose = .{ .pivot = .{ 2, -3, 0.25 }, .scale = 1.4, .screen_position = .{ 0.3, -0.8 } };
    const grip: zmath.Vec = .{ rest.pivot[0], rest.pivot[1], rest.pivot[2], 1 };
    const original = utils.matApply(rest.viewFromItem(projection), grip);
    const projected = utils.resolvePosition(utils.matApply(projection, original));
    try std.testing.expectApproxEqAbs(rest.screen_position[0], projected[0], 0.00001);
    try std.testing.expectApproxEqAbs(rest.screen_position[1], projected[1], 0.00001);
    const animated = rest.withMotion(.{ .translation = .{ 0.03, 0.04, -0.02 }, .rotation_degrees = .{ 3, -2, 1 } });
    const shifted = utils.matApply(animated.viewFromItem(projection), grip);
    try std.testing.expectApproxEqAbs(original[0] + 0.03, shifted[0], 0.00001);
    try std.testing.expectApproxEqAbs(original[1] + 0.04, shifted[1], 0.00001);
    try std.testing.expectApproxEqAbs(original[2] - 0.02, shifted[2], 0.00001);
}
