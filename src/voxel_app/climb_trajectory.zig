//! Collision-checked climb planning and elapsed-time trajectory evaluation.
//! Player input, gravity, and climb cancellation are owned by PlayerController.
const std = @import("std");
const collision = @import("terrain_collision.zig");
const Position = collision.Position;
const ground_probe = collision.ground_probe;

pub const duration_seconds: f64 = 0.25;
pub const landing_distance: f64 = 0.1;
pub const face_margin: f64 = 0.001;
const max_climb_rise: f64 = 1;
const max_airborne_climb_rise: f64 = 0.5;
const airborne_climb_speed_fraction: f64 = 0.9;

pub const StartState = struct {
    position: Position,
    grounded: bool,
    last_grounded_z: f64,
};

pub const Trajectory = struct {
    start: Position,
    approach_delta: Position,
    landing: Position,
    planned_velocity: Position,
    rise_duration: f64,
    duration: f64,
    elapsed: f64 = 0,

    pub fn positionAt(self: Trajectory, elapsed: f64) Position {
        const progress = std.math.clamp(elapsed / self.rise_duration, 0, 1);
        const eased = progress * progress * (3 - 2 * progress);
        var position = self.start + self.approach_delta * @as(Position, @splat(progress));
        // Once the rise finishes before the contact face, walk the short level
        // exit at the planned speed until the body reaches supporting terrain.
        position += self.planned_velocity * @as(Position, @splat(@max(0, elapsed - self.rise_duration)));
        position[2] = self.start[2] + (self.landing[2] - self.start[2]) * eased;
        return position;
    }
};
pub const Plan = struct { delay: f64, climb: Trajectory };

/// Check upward clearance, the straight horizontal approach, and landing support.
pub fn findLanding(query: *collision.Query, start: Position, horizontal_delta: Position, rise: f64) ?Position {
    std.debug.assert(horizontal_delta[2] == 0);
    const up = query.moveAxis(start, 2, rise);
    if (up.collided) return null;
    // Use the same box/path intersection as the preview. Sweeping the full X leg
    // before Y also visits terrain outside a diagonal approach.
    if (query.horizontalContactTime(up.position, horizontal_delta, 1) != null) return null;
    const down = query.moveAxis(up.position + horizontal_delta, 2, -(rise + ground_probe));
    if (!down.collided) return null;
    return down.position;
}

pub fn plan(query: *collision.Query, state: StartState, velocity: Position, step: f64) ?Plan {
    const start = state.position;
    // Airborne catches have shorter reach. Keep the standing-height cap too,
    // so jumping cannot turn a two-block column into a reachable ledge.
    const reach = if (state.grounded) max_climb_rise else max_airborne_climb_rise;
    const rise = @min(reach, state.last_grounded_z + max_climb_rise - start[2]);
    if (rise <= collision.epsilon) return null;
    const speed = @sqrt(@reduce(.Add, velocity * velocity));
    if (speed < 0.1) return null;
    const direction = velocity / @as(Position, @splat(speed));
    // Look one substep beyond the usual preview to locate an entry during this
    // substep. The tiny extension includes a face exactly on the preview edge.
    const contact_time = query.horizontalContactTime(start, velocity, duration_seconds + step + 2 * collision.epsilon / speed) orelse return null;
    var delay = @max(0, contact_time - duration_seconds);
    if (delay * speed <= collision.epsilon) delay = 0;
    const climb_start = start + velocity * @as(Position, @splat(delay));
    const distance = speed * (contact_time - delay);
    const approach_delta = direction * @as(Position, @splat(@max(0, distance - face_margin)));
    const landing_delta = direction * @as(Position, @splat(distance + landing_distance));
    const landing = findLanding(query, climb_start, landing_delta, rise) orelse return null;
    if (landing[2] <= climb_start[2] + collision.epsilon) return null;
    const actual_rise = landing[2] - climb_start[2];
    // A full-height approach needs footing just before the face. Without this
    // check, the grounded preview could lift the body across a hole to a raised
    // far edge before airborne reach limits ever had a chance to apply.
    if (actual_rise > max_airborne_climb_rise and
        !query.moveAxis(climb_start + approach_delta, 2, -ground_probe).collided) return null;
    // A tiny lip catch must not stretch a few centimetres of walking over the
    // full step duration. Aim for 90% of walking speed, while limiting vertical
    // speed to that of a full-height ascent when already close to the face.
    const rise_duration = if (state.grounded) duration_seconds else @min(duration_seconds, @max(
        duration_seconds * actual_rise / max_climb_rise,
        @max(0, distance - face_margin) / (speed * airborne_climb_speed_fraction),
    ));
    return .{
        .delay = delay,
        .climb = .{
            .start = climb_start,
            .approach_delta = approach_delta,
            .landing = landing,
            .planned_velocity = velocity,
            .rise_duration = rise_duration,
            .duration = rise_duration + (landing_distance + @min(distance, face_margin)) / speed,
        },
    };
}
