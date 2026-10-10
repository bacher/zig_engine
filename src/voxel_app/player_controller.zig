//! Local player movement runs on the application thread using the latest cached terrain.
//! One world unit is one metre. No world-worker tick or service reply gates input.
const std = @import("std");
const engine = @import("engine");
const zmath = @import("zmath");
const World = @import("world.zig").World;
const collision = @import("terrain_collision.zig");
const climb_trajectory = @import("climb_trajectory.zig");
const Position = collision.Position;
const Cell = collision.Cell;

pub const gravity: f64 = 10;
pub const walk_speed: f64 = 5;
pub const jump_speed: f64 = 5;
pub const climb_hold_seconds: f64 = 0.25;
pub const climb_duration_seconds = climb_trajectory.duration_seconds;
pub const recovery_radius: i64 = 8;
const history_seconds: f64 = 5;
const max_step_seconds: f64 = 1.0 / 120.0;
const ground_probe = collision.ground_probe;

pub const Input = struct {
    forward: f64 = 0,
    right: f64 = 0,
    jump_pressed: bool = false,
    jump_down: bool = false,
};

pub const UpdateResult = struct {
    missing_chunk: ?engine.ChunkCoords = null,
    recovered: bool = false,
    recovery_failed: bool = false,
};

pub const PlayerController = struct {
    const HistoryEntry = struct { cell: Cell, time: f64 };
    const ClimbStepResult = enum { not_consumed, consumed };

    allocator: std.mem.Allocator,
    /// Feet, independent of the camera and its eye offset. Uses engine f64 coordinates.
    position: Position,
    body: collision.Body = .{},
    vertical_velocity: f64 = 0,
    grounded: bool = false,
    last_grounded_z: f64 = 0,
    climb_blocked: bool = false,
    yaw: f32 = 0,
    pitch: f32 = 0,
    space_held_seconds: f64 = 0,
    auto_climb: bool = false,
    climb: ?climb_trajectory.Trajectory = null,
    history: std.ArrayList(HistoryEntry) = .empty,
    next_recovery_attempt: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, position: Position) PlayerController {
        return .{ .allocator = allocator, .position = position, .last_grounded_z = position[2] };
    }

    pub fn deinit(self: *PlayerController) void {
        self.history.deinit(self.allocator);
    }

    pub fn resetJumpInput(self: *PlayerController) void {
        self.space_held_seconds = 0;
        self.auto_climb = false;
        self.cancelClimb();
    }

    fn cancelClimb(self: *PlayerController) void {
        // An input/terrain cancellation must resume gravity instead of immediately
        // acquiring the same or another ledge during the next airborne substep.
        // Ground contact or a fresh airborne Space press permits another attempt.
        if (self.climb != null) self.climb_blocked = true;
        self.climb = null;
    }

    fn rememberGroundContact(self: *PlayerController) void {
        if (self.climb == null and self.grounded and self.vertical_velocity <= 0) {
            self.last_grounded_z = self.position[2];
            self.climb_blocked = false;
        }
    }

    pub fn look(self: *PlayerController, delta: [2]f32) void {
        self.yaw = @mod(self.yaw - delta[0] * 0.005 + std.math.pi, 2 * std.math.pi) - std.math.pi;
        const limit: f32 = std.math.pi / 2.0 - 0.01;
        self.pitch = std.math.clamp(self.pitch - delta[1] * 0.005, -limit, limit);
    }

    pub fn applyCamera(self: *const PlayerController, camera: anytype) void {
        camera.updatePosition(self.position + Position{ 0, 0, self.body.eye_height });
        camera.updateView(engine.utils.matMul(zmath.rotationX(-self.pitch), zmath.rotationY(-self.yaw)));
    }

    pub fn terrainChanged(self: *PlayerController) void {
        self.next_recovery_attempt = 0;
    }

    /// Consume every frame immediately, including its final fractional substep. These
    /// subdivisions improve numerical stability; they impose no input/update rate cap.
    pub fn update(self: *PlayerController, world: *const World, input: Input, elapsed: f64, now: f64) !UpdateResult {
        var result: UpdateResult = .{};
        self.expireHistory(now);
        var query: collision.Query = .{ .world = world, .body = self.body };
        switch (query.overlap(self.position, true)) {
            .missing => {
                self.vertical_velocity = 0;
                self.grounded = false;
                self.resetJumpInput();
                result.missing_chunk = query.missing_chunk;
                return result;
            },
            .solid => {
                if (now < self.next_recovery_attempt) {
                    result.recovery_failed = true;
                    result.missing_chunk = query.missing_chunk;
                    return result;
                }
                if (!self.recover(&query, now)) {
                    self.next_recovery_attempt = now + 1;
                    self.vertical_velocity = 0;
                    self.grounded = false;
                    self.resetJumpInput();
                    result.recovery_failed = true;
                    result.missing_chunk = query.missing_chunk;
                    return result;
                }
                result.recovered = true;
            },
            .clear => {},
        }

        const dt = @max(0, elapsed);
        self.grounded = query.moveAxis(self.position, 2, -ground_probe).collided;
        if (!input.jump_down) {
            self.space_held_seconds = 0;
        } else if (input.jump_pressed) {
            // An airborne press grabs a nearby lip immediately; a grounded press
            // still jumps and uses the ordinary hold delay for automatic climbing.
            self.space_held_seconds = if (self.grounded) 0 else climb_hold_seconds;
            if (!self.grounded) self.climb_blocked = false;
        }
        self.auto_climb = input.jump_down and self.space_held_seconds >= climb_hold_seconds;
        if (!self.auto_climb) self.cancelClimb();
        self.rememberGroundContact();
        if (input.jump_pressed and self.grounded) {
            self.vertical_velocity = jump_speed;
            self.grounded = false;
        }

        var forward = input.forward;
        var right = input.right;
        const magnitude = @sqrt(forward * forward + right * right);
        if (magnitude > 1) {
            forward /= magnitude;
            right /= magnitude;
        }
        const yaw: f64 = self.yaw;
        const velocity = Position{
            walk_speed * (right * @cos(yaw) - forward * @sin(yaw)),
            walk_speed * (forward * @cos(yaw) + right * @sin(yaw)),
            0,
        };
        var remaining = dt;
        while (remaining > 0) {
            var step = @min(remaining, max_step_seconds);
            self.auto_climb = input.jump_down and self.space_held_seconds >= climb_hold_seconds;
            if (input.jump_down and !self.auto_climb) step = @min(step, climb_hold_seconds - self.space_held_seconds);
            if (self.climb == null and self.auto_climb and !self.climb_blocked) {
                if (climb_trajectory.plan(&query, .{
                    .position = self.position,
                    .grounded = self.grounded,
                    .last_grounded_z = self.last_grounded_z,
                }, velocity, step)) |plan| {
                    if (plan.delay == 0) self.climb = plan.climb else step = @min(step, plan.delay);
                }
            }
            // Split at trajectory completion too, so the next stair can start at
            // that instant rather than waiting for another frame/substep boundary.
            if (self.climb) |climb| step = @min(step, climb.duration - climb.elapsed);
            const step_consumed = self.climb != null and self.advanceClimb(&query, step, velocity) == .consumed;
            if (!step_consumed) {
                const mx = query.moveAxis(self.position, 0, velocity[0] * step);
                const my = query.moveAxis(mx.position, 1, velocity[1] * step);
                self.position = my.position;
                const supported = self.vertical_velocity <= 0 and query.moveAxis(self.position, 2, -ground_probe).collided;
                const dz = if (supported) 0 else self.vertical_velocity * step - 0.5 * gravity * step * step;
                if (supported) self.vertical_velocity = 0 else self.vertical_velocity -= gravity * step;
                const mz = query.moveAxis(self.position, 2, dz);
                self.position = mz.position;
                self.grounded = supported or (mz.collided and dz < 0);
                if (mz.collided or self.grounded) self.vertical_velocity = 0;
            }
            self.rememberGroundContact();
            if (input.jump_down) self.space_held_seconds += step;
            self.auto_climb = input.jump_down and self.space_held_seconds >= climb_hold_seconds;
            try self.recordPosition(now - remaining + step);
            remaining -= step;
        }
        // Also record valid initial positions and zero-duration frames.
        try self.recordPosition(now);
        self.expireHistory(now);
        result.missing_chunk = query.missing_chunk;
        return result;
    }

    /// A consumed step already applied movement, even if the climb ended or collided.
    fn advanceClimb(self: *PlayerController, query: *collision.Query, step: f64, velocity: Position) ClimbStepResult {
        var climb = self.climb.?;
        // Releasing movement or turning abandons the arc. Because the original box
        // remains clear at every point, normal gravity can safely take over anywhere.
        const speed_squared = @reduce(.Add, velocity * velocity);
        const planned_speed_squared = @reduce(.Add, climb.planned_velocity * climb.planned_velocity);
        const alignment = @reduce(.Add, velocity * climb.planned_velocity);
        if (speed_squared < 0.01 or alignment < @sqrt(speed_squared * planned_speed_squared) * 0.8660254037844386) {
            self.cancelClimb();
            return .not_consumed;
        }
        const remaining_rise = @max(0, climb.landing[2] - self.position[2]);
        const landing = climb_trajectory.findLanding(query, self.position, .{
            climb.landing[0] - self.position[0],
            climb.landing[1] - self.position[1],
            0,
        }, remaining_rise);
        if (landing == null or @abs(landing.?[2] - climb.landing[2]) > collision.epsilon) {
            self.cancelClimb();
            return .not_consumed;
        }
        climb.elapsed += step;
        const target = climb.positionAt(climb.elapsed);
        // Feet reach the top before the box crosses the face. A short level lead-out
        // bridges into support, avoiding a fall in the tiny clearance gap at the end.
        const up = query.moveAxis(self.position, 2, target[2] - self.position[2]);
        const mx = query.moveAxis(up.position, 0, target[0] - up.position[0]);
        const my = query.moveAxis(mx.position, 1, target[1] - mx.position[1]);
        self.position = my.position;
        self.vertical_velocity = 0;
        self.grounded = query.moveAxis(self.position, 2, -ground_probe).collided;
        if (up.collided or mx.collided or my.collided) {
            self.cancelClimb();
        } else {
            self.climb = if (climb.elapsed >= climb.duration) null else climb;
        }
        // Even when a newly inserted obstacle clips this substep, do not also apply
        // ordinary horizontal movement; gravity resumes on the following substep.
        return .consumed;
    }

    pub fn expireHistory(self: *PlayerController, now: f64) void {
        var expired: usize = 0;
        while (expired < self.history.items.len and self.history.items[expired].time < now - history_seconds) : (expired += 1) {}
        if (expired > 0) {
            const retained = self.history.items.len - expired;
            std.mem.copyForwards(HistoryEntry, self.history.items[0..retained], self.history.items[expired..]);
            self.history.items.len = retained;
        }
    }

    fn recordPosition(self: *PlayerController, now: f64) !void {
        const cell: Cell = @intFromFloat(@floor(self.position));
        if (self.history.items.len > 0) {
            const last = &self.history.items[self.history.items.len - 1];
            if (@reduce(.And, last.cell == cell)) {
                last.time = now;
                return;
            }
        }
        try self.history.append(self.allocator, .{ .cell = cell, .time = now });
    }

    /// Local neighbours, then newest still-clear history, then a bounded nearest search.
    pub fn recover(self: *PlayerController, query: *collision.Query, now: f64) bool {
        self.expireHistory(now);
        if (self.nearestClear(query, 1)) |position| return self.restore(position);
        var index = self.history.items.len;
        while (index > 0) {
            index -= 1;
            const position = collision.cellPosition(self.history.items[index].cell);
            if (query.overlap(position, false) == .clear) return self.restore(position);
        }
        if (self.nearestClear(query, recovery_radius)) |position| return self.restore(position);
        return false;
    }

    fn restore(self: *PlayerController, position: Position) bool {
        self.position = position;
        self.vertical_velocity = 0;
        self.grounded = false;
        self.resetJumpInput();
        self.last_grounded_z = position[2];
        self.climb_blocked = false;
        self.next_recovery_attempt = 0;
        return true;
    }

    fn nearestClear(self: *const PlayerController, query: *collision.Query, radius: i64) ?Position {
        const centre: Cell = @intFromFloat(@floor(self.position));
        var best: ?Position = null;
        var best_distance: f64 = std.math.inf(f64);
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            var dy = -radius;
            while (dy <= radius) : (dy += 1) {
                var dx = -radius;
                while (dx <= radius) : (dx += 1) {
                    const position = collision.cellPosition(centre + Cell{ dx, dy, dz });
                    const delta = position - self.position;
                    const distance = @reduce(.Add, delta * delta);
                    // Immediate neighbours include diagonals; the wider search is an 8m sphere.
                    if (radius > 1 and distance > @as(f64, @floatFromInt(radius * radius))) continue;
                    if (distance >= best_distance) continue;
                    if (query.overlap(position, false) != .clear) continue;
                    best = position;
                    best_distance = distance;
                }
            }
        }
        return best;
    }
};

const Fixture = @import("terrain_test_fixture.zig").Fixture;

test "gravity and walking consume wall time across frame rates, including short frames" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var slow = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 10 });
    defer slow.deinit();
    var fast = PlayerController.init(std.testing.allocator, slow.position);
    defer fast.deinit();
    _ = try slow.update(&fixture.world, .{ .forward = 1 }, 0.5, 0.5);
    for (0..1000) |index| {
        _ = try fast.update(&fixture.world, .{ .forward = 1 }, 0.0005, @as(f64, @floatFromInt(index + 1)) * 0.0005);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 3), fast.position[1], 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 8.75), fast.position[2], 0.0000001);
    inline for (0..3) |axis| try std.testing.expectApproxEqAbs(slow.position[axis], fast.position[axis], 0.0000001);
}

test "diagonal walking is normalized and looking vertically does not change walking" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer player.deinit();
    player.look(.{ 0, -10000 });
    try std.testing.expect(player.pitch < std.math.pi / 2.0);
    _ = try player.update(&fixture.world, .{ .forward = 1, .right = 1 }, 1, 1);
    const displacement = player.position - Position{ 0.5, 0.5, 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 5), @sqrt(@reduce(.Add, displacement * displacement)), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
}

test "very short grounded frames stay on the floor and walking off an edge starts falling" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, -1 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer player.deinit();
    for (0..2000) |index| {
        const result = try player.update(&fixture.world, .{}, 0.00001, @as(f64, @floatFromInt(index + 1)) * 0.00001);
        try std.testing.expect(!result.recovered);
        try std.testing.expectEqual(@as(f64, 0), player.position[2]);
        try std.testing.expect(player.grounded);
    }
    _ = try player.update(&fixture.world, .{ .right = 1 }, 0.5, 0.52);
    try std.testing.expect(player.position[2] < 0);
    try std.testing.expect(!player.grounded);
}

test "sweeps stop fast falls and long movements at floors and walls and allow sliding" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -16, 0 }, .{ 2, 16, 4 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 10 });
    defer player.deinit();
    player.vertical_velocity = -1000;
    _ = try player.update(&fixture.world, .{}, 0.1, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
    try std.testing.expect(player.grounded);
    _ = try player.update(&fixture.world, .{ .forward = 1, .right = 1 }, 1, 1.1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.7), player.position[0], 0.000001);
    try std.testing.expect(player.position[1] > 3);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    const long_move = query.moveAxis(.{ 0.5, 0.5, 0 }, 0, 20);
    try std.testing.expect(long_move.collided);
    try std.testing.expectApproxEqAbs(@as(f64, 1.7), long_move.position[0], 0.000001);
}

test "a fast Space tap jumps once, holding does not repeatedly jump, and ceilings stop ascent" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer player.deinit();
    _ = try player.update(&fixture.world, .{ .jump_pressed = true, .jump_down = false }, 0.5, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), player.position[2], 0.000001);
    _ = try player.update(&fixture.world, .{ .jump_down = true }, 0.6, 1.1);
    try std.testing.expect(player.grounded);
    try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
    _ = try player.update(&fixture.world, .{ .jump_down = true }, 0.3, 1.4);
    try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
    fixture.set(.{ 0, 0, 2 }, .stone);
    _ = try player.update(&fixture.world, .{ .jump_pressed = true }, 0.1, 1.5);
    try std.testing.expect(player.position[2] > 0 and player.position[2] <= 0.2 + collision.epsilon);
    try std.testing.expect(player.vertical_velocity <= 0);
}

test "missing terrain is solid, reports its chunk, and movement resumes after loading" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    const chunk = fixture.world.layout.getChunkCoords(.{ 32.5, 0.5, 0 });
    fixture.world.removeChunk(chunk);
    var player = PlayerController.init(std.testing.allocator, .{ 31.5, 0.5, 0 });
    defer player.deinit();
    const blocked = try player.update(&fixture.world, .{ .right = 1 }, 0.3, 0.3);
    try std.testing.expectEqualDeep(chunk, blocked.missing_chunk.?);
    try std.testing.expectApproxEqAbs(@as(f64, 31.7), player.position[0], 0.000001);
    try fixture.world.insertChunk(chunk, @import("world.zig").WorldChunk.initEmpty());
    _ = try player.update(&fixture.world, .{ .right = 1 }, 0.1, 0.4);
    try std.testing.expect(player.position[0] > 32);
}

test "initial missing body data freezes movement without teleporting and mouse look remains available" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const start = Position{ 0.5, 0.5, 0 };
    fixture.world.removeChunk(fixture.world.layout.getChunkCoords(start));
    var player = PlayerController.init(std.testing.allocator, start);
    defer player.deinit();
    const result = try player.update(&fixture.world, .{ .forward = 1 }, 1, 1);
    try std.testing.expect(result.missing_chunk != null);
    try std.testing.expectEqualDeep(start, player.position);
    player.look(.{ 20, 20 });
    try std.testing.expect(player.yaw != 0);
    try std.testing.expect(player.pitch != 0);
    try std.testing.expectEqual(@as(usize, 0), player.history.items.len);
}

test "optimistic terrain edits recover to a nearby clear full-body space" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer player.deinit();
    fixture.set(.{ 0, 0, 1 }, .stone);
    const result = try player.update(&fixture.world, .{}, 0, 0);
    try std.testing.expect(result.recovered);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
    try std.testing.expect(@reduce(.Max, @abs(player.position - Position{ 0.5, 0.5, 0 })) <= 1);
}

test "authoritative rollback of an optimistic opening triggers recovery from current block data" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, 0 }, .stone);
    fixture.world.pending_operations.clearRetainingCapacity();
    const coords = fixture.world.layout.getChunkCoords(.{ 0.5, 0.5, 0 });
    var authority = fixture.world.getChunk(coords).?.clone(std.testing.allocator);
    defer authority.content.deinit(std.testing.allocator);
    authority.chunk_revision = 1;
    fixture.set(.{ 0, 0, 0 }, .none);
    fixture.world.pending_operations.items[0].request_id = 1;
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer player.deinit();
    _ = try player.update(&fixture.world, .{}, 0, 0);
    // Unacknowledged removal is replayed over the snapshot and still permits movement.
    try fixture.world.insertChunk(coords, authority.clone(std.testing.allocator));
    const optimistic = try player.update(&fixture.world, .{}, 0, 0.1);
    try std.testing.expect(!optimistic.recovered);
    fixture.world.acknowledgeOperation(1);
    try fixture.world.insertChunk(coords, authority.clone(std.testing.allocator));
    const rolled_back = try player.update(&fixture.world, .{}, 0, 0.2);
    try std.testing.expect(rolled_back.recovered);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
}

test "recovery uses newest valid history before a closer distant opening and expires after five seconds" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var player = PlayerController.init(std.testing.allocator, .{ 10.2, 0.2, 0 });
    defer player.deinit();
    _ = try player.update(&fixture.world, .{}, 0, 0);
    player.position = .{ 12.2, 0.2, 0 };
    _ = try player.update(&fixture.world, .{}, 0, 1);
    player.position = .{ 0.5, 0.5, 0 };
    fixture.fill(.{ -1, -1, -1 }, .{ 1, 1, 3 }, .stone);
    fixture.fill(.{ 12, 0, 0 }, .{ 12, 0, 2 }, .stone);
    const result = try player.update(&fixture.world, .{}, 0, 2);
    try std.testing.expect(result.recovered);
    try std.testing.expectEqualDeep(Position{ 10.5, 0.5, 0 }, player.position);
    player.expireHistory(7.1);
    try std.testing.expectEqual(@as(usize, 0), player.history.items.len);
}

test "bounded fallback finds nearest clear space, rejects head obstructions, and fails safely when enclosed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var player = PlayerController.init(std.testing.allocator, .{ 0.5, 0.5, 0 });
    defer player.deinit();
    fixture.fill(.{ -1, -1, -1 }, .{ 1, 1, 3 }, .stone);
    const recovered = try player.update(&fixture.world, .{}, 0, 0);
    try std.testing.expect(recovered.recovered);
    const delta = player.position - Position{ 0.5, 0.5, 0 };
    try std.testing.expectApproxEqAbs(@as(f64, 2), @sqrt(@reduce(.Add, delta * delta)), 0.000001);
    player.position = .{ 0.5, 0.5, 0 };
    fixture.fill(.{ -9, -9, -9 }, .{ 9, 9, 10 }, .stone);
    const failed = try player.update(&fixture.world, .{ .right = 1 }, 0.1, 0.1);
    try std.testing.expect(failed.recovery_failed);
    try std.testing.expectEqualDeep(Position{ 0.5, 0.5, 0 }, player.position);
    fixture.fill(.{ 0, 1, 0 }, .{ 0, 1, 2 }, .none);
    player.terrainChanged();
    const retry = try player.update(&fixture.world, .{}, 0, 0.2);
    try std.testing.expect(retry.recovered);
}

test "collision and placement checks work across the periodic x seam and repeated trips" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fill(.{ -64, 0, 0 }, .{ -64, 0, 2 }, .grass);
    const width: f64 = @floatFromInt(fixture.world.layout.size_in_blocks[0]);
    var player = PlayerController.init(std.testing.allocator, .{ 63.5 + 3 * width, 0.5, 0 });
    defer player.deinit();
    _ = try player.update(&fixture.world, .{ .right = 1 }, 0.3, 0.3);
    try std.testing.expectApproxEqAbs(63.7 + 3 * width, player.position[0], 0.000001);
    try std.testing.expect(collision.overlapsBlock(player.body, .{ 64.1 + 3 * width, 0.5, 0 }, fixture.world.layout, .{ 0, 64, 64 }));
    try std.testing.expect(!collision.overlapsBlock(player.body, player.position, fixture.world.layout, .{ 0, 64, 64 }));
}

test {
    _ = @import("player_climb_tests.zig");
}
