//! Tool-independent, camera-space held-item motion. One state follows the holder,
//! regardless of which item is visible. World samples remain f64 until differenced.
const std = @import("std");
const zmath = @import("zmath");
const utils = @import("utils.zig");
const Position = @import("world_math.zig").Position;
pub const Vec3 = @Vector(3, f32);
const zero: Vec3 = @splat(0);

/// Offsets from any item's resting pose, in view metres and camera-axis degrees.
pub const Offset = struct {
    translation: Vec3 = zero,
    rotation_degrees: Vec3 = zero,

    pub fn rotation(offset: Offset) zmath.Mat {
        const angles = offset.rotation_degrees * @as(Vec3, @splat(std.math.pi / 180.0));
        return utils.matMul(zmath.rotationZ(angles[2]), utils.matMul(zmath.rotationX(angles[0]), zmath.rotationY(angles[1])));
    }
};

/// Hybrid gait and inertia; defaults are deliberately subtle.
pub const Tuning = struct {
    strength: f32 = 1,
    bob_amplitude: f32 = 0.0154, // metres
    stride_length: f32 = 3.2, // metres per full left/right cycle
    acceleration_lag: f32 = 0.52, // inertial force multiplier
    direction_lag: f32 = 0.005, // metres per m/s
    spring_frequency: f32 = 3, // Hz
    damping_ratio: f32 = 0.7,
    look_sway: f32 = 0.014, // metres per rad/s
    pitch_shift: f32 = 0.10, // maximum vertical shift in metres at +/-90 degrees
    pitch_follow_time: f32 = 0.18, // seconds to follow 63% of a pitch shift
    landing_strength: f32 = 0.04, // spring velocity per m/s of impact
    rotation_strength: f32 = 1,
};

pub const Input = struct {
    position: Position,
    view_from_world: zmath.Mat,
    /// Yaw and pitch in radians; positive pitch looks up. Rate wrapping is handled here.
    look_angles: [2]f32 = .{ 0, 0 },
    grounded: bool = true,
    gait_enabled: bool = true,
    active: bool = true,
};

const Sample = struct { position: Position, look_angles: [2]f32, grounded: bool };
const Spring = struct {
    position: Vec3 = zero,
    velocity: Vec3 = zero,

    fn advance(self: *Spring, target: Vec3, force: Vec3, frequency: f32, damping: f32, elapsed: f32) void {
        const omega = 2 * std.math.pi * frequency;
        var remaining = elapsed;
        while (remaining > 0) {
            const dt = @min(remaining, 1.0 / 240.0);
            self.velocity += ((target - self.position) * @as(Vec3, @splat(omega * omega)) -
                self.velocity * @as(Vec3, @splat(2 * damping * omega)) + force) * @as(Vec3, @splat(dt));
            self.position += self.velocity * @as(Vec3, @splat(dt));
            inline for (0..3) |axis| {
                const limit: f32 = if (axis == 1) 0.14 else 0.12;
                if (@abs(self.position[axis]) > limit) {
                    self.position[axis] = std.math.clamp(self.position[axis], -limit, limit);
                    self.velocity[axis] = 0;
                }
            }
            remaining -= dt;
        }
    }
};

pub const Motion = struct {
    tuning: Tuning = .{},
    offset: Offset = .{},
    previous: ?Sample = null,
    velocity_world: Vec3 = zero,
    look_velocity: @Vector(2, f32) = @splat(0),
    spring: Spring = .{},
    phase: f32 = 0,
    bob_weight: f32 = 0,
    pitch_offset: f32 = 0,

    pub fn reset(self: *Motion) void {
        self.* = .{ .tuning = self.tuning };
    }

    fn synchronize(self: *Motion, sample: Sample, pitch_target: f32) void {
        self.previous = sample;
        self.pitch_offset = pitch_target;
        self.offset.translation[1] = pitch_target * std.math.clamp(self.tuning.strength, 0, 2);
    }

    pub fn update(self: *Motion, input: Input, elapsed: f64) void {
        if (!input.active or !std.math.isFinite(elapsed) or elapsed < 0.000001 or elapsed > 0.25 or
            !finitePosition(input.position) or !std.math.isFinite(input.look_angles[0]) or !std.math.isFinite(input.look_angles[1]))
        {
            self.reset();
            return;
        }
        const sample: Sample = .{ .position = input.position, .look_angles = input.look_angles, .grounded = input.grounded };
        // Absolute pitch changes the grip height even when the camera is stationary.
        const pitch_target = -@sin(std.math.clamp(input.look_angles[1], -std.math.pi / 2.0, std.math.pi / 2.0)) * self.tuning.pitch_shift;
        const previous = self.previous orelse {
            self.synchronize(sample, pitch_target);
            return;
        };
        self.previous = sample;
        const dt: f32 = @floatCast(elapsed);
        const measured: Vec3 = @floatCast((input.position - previous.position) / @as(Position, @splat(elapsed)));
        // Camera mode changes, recovery teleports, and long pauses should not kick the item.
        if (!finiteVector(measured) or length(measured) > 80) {
            self.reset();
            self.synchronize(sample, pitch_target);
            return;
        }
        self.pitch_offset += (pitch_target - self.pitch_offset) * (1 - @exp(-dt / @max(0.001, self.tuning.pitch_follow_time)));
        if (@abs(pitch_target - self.pitch_offset) < 0.000001) self.pitch_offset = pitch_target;
        const old_velocity = self.velocity_world;
        const smoothing = 1 - @exp(-dt / 0.06);
        self.velocity_world += (measured - self.velocity_world) * @as(Vec3, @splat(smoothing));
        const acceleration = (self.velocity_world - old_velocity) / @as(Vec3, @splat(dt));
        inline for (0..2) |axis| {
            const difference = input.look_angles[axis] - previous.look_angles[axis];
            const rate = std.math.atan2(@sin(difference), @cos(difference)) / dt;
            self.look_velocity[axis] += (std.math.clamp(rate, -8, 8) - self.look_velocity[axis]) * smoothing;
        }

        // Differentiate world velocity before transforming: looking around must not
        // invent a braking impulse from a mere change of camera basis.
        const velocity_view = inView(input.view_from_world, self.velocity_world);
        const acceleration_view = inView(input.view_from_world, acceleration);
        const speed = @sqrt(measured[0] * measured[0] + measured[1] * measured[1]);
        const gait = if (input.gait_enabled) std.math.clamp(speed / 5, 0, 1.5) else 0;
        self.bob_weight += (gait - self.bob_weight) * (1 - @exp(-dt / 0.12));
        if (input.gait_enabled and speed > 0.01) self.phase = @mod(self.phase + 2 * std.math.pi * speed * dt / @max(0.1, self.tuning.stride_length), 2 * std.math.pi);

        const look = Vec3{ self.look_velocity[0], -self.look_velocity[1], 0 } * @as(Vec3, @splat(self.tuning.look_sway));
        const target = look - velocity_view * @as(Vec3, @splat(self.tuning.direction_lag));
        const force = -acceleration_view * @as(Vec3, @splat(self.tuning.acceleration_lag));
        if (input.grounded and !previous.grounded) {
            self.spring.velocity[1] -= std.math.clamp(-old_velocity[2], 0, 10) * self.tuning.landing_strength;
        }
        const frequency = std.math.clamp(self.tuning.spring_frequency, 0.5, 12);
        const damping = std.math.clamp(self.tuning.damping_ratio, 0.2, 2);
        self.spring.advance(target, force, frequency, damping, dt);
        const amplitude = self.tuning.bob_amplitude * self.bob_weight;
        const bob = Vec3{ @sin(self.phase) * amplitude, @sin(2 * self.phase) * amplitude * 0.65, @cos(2 * self.phase) * amplitude * 0.2 };
        var translation = self.spring.position + bob;
        inline for (0..3) |axis| translation[axis] = std.math.clamp(translation[axis], -0.16, 0.16);
        var angles = Vec3{
            -translation[1] * 28 + translation[2] * 18 - self.look_velocity[1] * self.tuning.look_sway * 35,
            -translation[0] * 22 + self.look_velocity[0] * self.tuning.look_sway * 35,
            -translation[0] * 12 + @sin(self.phase) * self.bob_weight * 0.1925,
        };
        angles *= @as(Vec3, @splat(self.tuning.rotation_strength));
        inline for (0..3) |axis| angles[axis] = std.math.clamp(angles[axis], -5, 5);
        const strength = std.math.clamp(self.tuning.strength, 0, 2);
        self.offset = .{ .translation = translation * @as(Vec3, @splat(strength)), .rotation_degrees = angles * @as(Vec3, @splat(strength)) };
        // Settle transient motion exactly, while retaining the absolute pitch shift.
        if (length(measured) < 0.001 and length(self.velocity_world) < 0.001 and
            length(self.spring.position) < 0.00001 and length(self.spring.velocity) < 0.0001 and
            @abs(self.look_velocity[0]) + @abs(self.look_velocity[1]) < 0.001 and self.bob_weight < 0.0001)
        {
            self.spring = .{};
            self.offset = .{};
            self.bob_weight = 0;
        }
        // Keep this separate from motion-derived rotation: pitch changes grip height only.
        self.offset.translation[1] += self.pitch_offset * strength;
    }
};

fn inView(matrix: zmath.Mat, vector: Vec3) Vec3 {
    const transformed = utils.matApply(matrix, .{ vector[0], vector[1], vector[2], 0 });
    return .{ transformed[0], transformed[1], transformed[2] };
}

fn length(vector: Vec3) f32 {
    return @sqrt(@reduce(.Add, vector * vector));
}

fn finiteVector(vector: Vec3) bool {
    inline for (0..3) |axis| if (!std.math.isFinite(vector[axis])) return false;
    return true;
}

fn finitePosition(position: Position) bool {
    inline for (0..3) |axis| if (!std.math.isFinite(position[axis])) return false;
    return true;
}
