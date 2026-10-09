//! Local player movement runs on the application thread using the latest cached terrain.
//! One world unit is one metre. No world-worker tick or service reply gates input.
const std = @import("std");
const engine = @import("engine");
const zmath = @import("zmath");
const World = @import("world.zig").World;
const collision = @import("terrain_collision.zig");
const Position = collision.Position;
const Cell = collision.Cell;

pub const gravity: f64 = 10;
pub const walk_speed: f64 = 5;
pub const jump_speed: f64 = 5;
pub const climb_hold_seconds: f64 = 0.25;
pub const climb_duration_seconds: f64 = 0.36;
pub const climb_lookahead_metres: f64 = 0.5;
const climb_landing_metres: f64 = 0.5;
pub const recovery_radius: i64 = 8;
const history_seconds: f64 = 5;
const max_step_seconds: f64 = 1.0 / 120.0;
const ground_probe: f64 = 0.00001;

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
    const Climb = struct {
        start: Position,
        target: Position,
        elapsed: f64 = 0,
        delayed_forward: bool = false,
        contact_distance: f64,

        fn positionAt(self: Climb, elapsed: f64) Position {
            const t = std.math.clamp(elapsed / climb_duration_seconds, 0, 1);
            const distance = @sqrt((self.target[0] - self.start[0]) * (self.target[0] - self.start[0]) +
                (self.target[1] - self.start[1]) * (self.target[1] - self.start[1]));
            // Two tangent-matched horizontal phases slow near the face and
            // accelerate out. The narrow foot clears before crossing the edge.
            const approach = self.contact_distance - 0.05;
            const horizontal = if (self.delayed_forward)
                smoothstep((t - 0.75) / 0.25)
            else if (t < 0.6)
                hermite(t / 0.6, 0, approach, walk_speed * climb_duration_seconds * 0.6, 0.6 * climb_duration_seconds * 0.6) / distance
            else
                hermite((t - 0.6) / 0.4, approach, distance, 0.6 * climb_duration_seconds * 0.4, walk_speed * climb_duration_seconds * 0.4) / distance;
            return self.start + (self.target - self.start) * Position{
                horizontal, horizontal, smoothstep(t / 0.75),
            };
        }
    };

    allocator: std.mem.Allocator,
    /// Feet, independent of the camera and its eye offset. Uses engine f64 coordinates.
    position: Position,
    body: collision.Body = .{},
    vertical_velocity: f64 = 0,
    grounded: bool = false,
    yaw: f32 = 0,
    pitch: f32 = 0,
    space_held_seconds: f64 = 0,
    auto_climb: bool = false,
    climb: ?Climb = null,
    climb_route_changed: bool = false,
    history: std.ArrayList(HistoryEntry) = .empty,
    next_recovery_attempt: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, position: Position) PlayerController {
        return .{ .allocator = allocator, .position = position };
    }

    pub fn deinit(self: *PlayerController) void {
        self.history.deinit(self.allocator);
    }

    pub fn resetJumpInput(self: *PlayerController) void {
        self.space_held_seconds = 0;
        self.auto_climb = false;
        self.climb = null;
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
        self.climb_route_changed = true;
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
        if (input.jump_pressed or !input.jump_down) self.space_held_seconds = 0;
        self.auto_climb = input.jump_down and self.space_held_seconds >= climb_hold_seconds;
        self.grounded = query.moveAxis(self.position, 2, -ground_probe).collided;
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
            const step = @min(remaining, max_step_seconds);
            if (input.jump_down) self.space_held_seconds += step;
            self.auto_climb = input.jump_down and self.space_held_seconds >= climb_hold_seconds;
            const dx = velocity[0] * step;
            const dy = velocity[1] * step;
            if (self.climb == null and self.auto_climb and self.grounded) {
                self.climb = self.planClimb(&query, velocity);
            }
            const climbing = self.climb != null and self.advanceClimb(&query, step);
            if (!climbing) {
                const mx = query.moveAxis(self.position, 0, dx);
                const my = query.moveAxis(mx.position, 1, dy);
                self.position = my.position;
                const supported = self.vertical_velocity <= 0 and query.moveAxis(self.position, 2, -ground_probe).collided;
                const dz = if (supported) 0 else self.vertical_velocity * step - 0.5 * gravity * step * step;
                if (supported) self.vertical_velocity = 0 else self.vertical_velocity -= gravity * step;
                const mz = query.moveAxis(self.position, 2, dz);
                self.position = mz.position;
                self.grounded = supported or (mz.collided and dz < 0);
                if (mz.collided or self.grounded) self.vertical_velocity = 0;
            }
            try self.recordPosition(now - remaining + step);
            remaining -= step;
        }
        // Also record valid initial positions and zero-duration frames.
        try self.recordPosition(now);
        self.expireHistory(now);
        result.missing_chunk = query.missing_chunk;
        return result;
    }

    fn findClimbLanding(query: *collision.Query, start: Position, dx: f64, dy: f64, rise: f64) ?Position {
        // Sweep up, across, then down. Both body clearance and an actual landing are
        // required; this cannot climb a two-block wall or pass through a low ceiling.
        const up = query.moveAxis(start, 2, rise);
        if (up.collided) return null;
        const across_x = query.moveAxis(up.position, 0, dx);
        const across_y = query.moveAxis(across_x.position, 1, dy);
        if (across_x.collided or across_y.collided) return null;
        const down = query.moveAxis(across_y.position, 2, -(rise + ground_probe));
        if (!down.collided or down.position[2] <= start[2] + collision.epsilon) return null;
        return down.position;
    }

    fn smoothstep(value: f64) f64 {
        const t = std.math.clamp(value, 0, 1);
        return t * t * (3 - 2 * t);
    }

    fn hermite(t: f64, first: f64, last: f64, first_tangent: f64, last_tangent: f64) f64 {
        const t2 = t * t;
        const t3 = t2 * t;
        return (2 * t3 - 3 * t2 + 1) * first + (t3 - 2 * t2 + t) * first_tangent +
            (-2 * t3 + 3 * t2) * last + (t3 - t2) * last_tangent;
    }

    fn moveTo(query: *collision.Query, start: Position, target: Position) collision.Move {
        const up = query.moveAxis(start, 2, target[2] - start[2]);
        const x = query.moveAxis(up.position, 0, target[0] - start[0]);
        const y = query.moveAxis(x.position, 1, target[1] - start[1]);
        return .{ .position = y.position, .collided = up.collided or x.collided or y.collided };
    }

    fn planClimb(self: *PlayerController, query: *collision.Query, velocity: Position) ?Climb {
        const speed = @sqrt(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
        if (speed <= collision.epsilon) return null;
        const direction = velocity / @as(Position, @splat(speed));
        const lookahead = direction * @as(Position, @splat(climb_lookahead_metres));
        const x = query.moveAxis(self.position, 0, lookahead[0]);
        const y = query.moveAxis(x.position, 1, lookahead[1]);
        if (!x.collided and !y.collided) return null;
        const contact_distance = @reduce(.Add, (y.position - self.position) * direction);
        const across = direction * @as(Position, @splat(contact_distance + climb_landing_metres));
        const target = findClimbLanding(query, self.position, across[0], across[1], 1) orelse return null;
        var climb = Climb{ .start = self.position, .target = target, .contact_distance = contact_distance };
        climb.delayed_forward = contact_distance < 0.45;
        if (!pathClear(query, climb, 0)) {
            // Enabling auto-climb while already touching a wall has no runway.
            // Preserve one-block climbing with a conservative late forward phase.
            climb.delayed_forward = true;
            if (!pathClear(query, climb, 0)) return null;
        }
        self.climb_route_changed = false;
        return climb;
    }

    fn pathClear(query: *collision.Query, climb: Climb, elapsed: f64) bool {
        var position = climb.positionAt(elapsed);
        for (1..33) |index| {
            const time = elapsed + (climb_duration_seconds - elapsed) * @as(f64, @floatFromInt(index)) / 32;
            const move = moveTo(query, position, climb.positionAt(time));
            if (move.collided) return false;
            position = move.position;
        }
        const down = query.moveAxis(climb.target, 2, -ground_probe);
        return down.collided and query.overlap(climb.target, true) == .clear;
    }

    fn advanceClimb(self: *PlayerController, query: *collision.Query, step: f64) bool {
        var climb = self.climb.?;
        // A committed climb finishes even after releasing Space/movement. Check
        // the remaining route and landing so terrain edits still abort safely.
        const landing_valid = query.overlap(climb.target, true) == .clear and
            query.moveAxis(climb.target, 2, -ground_probe).collided;
        if (!landing_valid or (self.climb_route_changed and !pathClear(query, climb, climb.elapsed))) {
            self.climb = null;
            return false;
        }
        self.climb_route_changed = false;
        climb.elapsed = @min(climb.elapsed + step, climb_duration_seconds);
        const move = moveTo(query, self.position, climb.positionAt(climb.elapsed));
        self.position = move.position;
        self.vertical_velocity = 0;
        self.grounded = climb.elapsed >= climb_duration_seconds;
        self.climb = if (move.collided or self.grounded) null else climb;
        return !move.collided;
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

const Fixture = struct {
    world: World,

    fn init() !Fixture {
        const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
        var world = try World.init(std.testing.allocator, &layout);
        errdefer world.deinit();
        for (0..4) |z| for (0..4) |y| for (0..4) |x| {
            try world.insertChunk(.{ @intCast(x), @intCast(y), @intCast(z) }, @import("world.zig").WorldChunk.initEmpty());
        };
        return .{ .world = world };
    }

    fn deinit(self: *Fixture) void {
        self.world.deinit();
    }

    fn set(self: *Fixture, cell: Cell, block: engine.voxel_chunk.BlockType) void {
        const origin: Cell = @as(Cell, self.world.layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
        var stored = cell + origin;
        stored[0] = @mod(stored[0], self.world.layout.size_in_blocks[0]);
        self.world.setBlock(@as(@Vector(3, u32), @intCast(stored)), block);
    }

    fn fill(self: *Fixture, first: Cell, last: Cell, block: engine.voxel_chunk.BlockType) void {
        var z = first[2];
        while (z <= last[2]) : (z += 1) {
            var y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) self.set(.{ x, y, z }, block);
            }
        }
    }

    fn floor(self: *Fixture) void {
        self.fill(.{ -16, -16, -1 }, .{ 16, 16, -1 }, .stone);
    }
};

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

test "narrow-foot climbing starts early, moves forward and up, and never overlaps its collider" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 1.21, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    var camera = std.meta.Child(@TypeOf(@as(engine.Scene, undefined).camera)).init(fixture.world.layout, 1);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    var previous = player.position;
    var envelope_grazed = false;
    for (0..44) |index| {
        const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 1.0 / 120.0, @as(f64, @floatFromInt(index + 1)) / 120.0);
        try std.testing.expect(!result.recovered);
        try std.testing.expect(player.position[0] > previous[0]);
        try std.testing.expect(player.position[2] >= previous[2]);
        try std.testing.expect(player.position[2] - previous[2] < 0.05);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
        if (player.position[0] > 1.7 and player.position[2] < 1 - collision.epsilon) {
            envelope_grazed = true;
            const block = [3]u32{ 66, 64, 64 };
            try std.testing.expect(!collision.overlapsBlock(player.body, player.position, fixture.world.layout, block));
        }
        player.applyCamera(&camera);
        try std.testing.expectApproxEqAbs(player.position[2] + player.body.eye_height, camera.position[2], 0.000001);
        if (index == 0) {
            try std.testing.expect(player.position[0] < 1.7);
            try std.testing.expect(player.position[2] > 0);
            try std.testing.expect(!player.climb.?.delayed_forward);
        }
        previous = player.position;
    }
    try std.testing.expect(envelope_grazed);
    try std.testing.expect(player.position[0] > 2);
    try std.testing.expect(player.grounded);
    try std.testing.expect(player.climb == null);
    try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
}

test "committed narrow-foot climb follows wall time across frame rates and long frames" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 1, 0 }, .stone);
    var reference: Position = undefined;
    for ([_]f64{ 30, 60, 120, 144, 240, 1000, 1 }) |fps| {
        var player = PlayerController.init(std.testing.allocator, .{ 1.21, 0.5, 0 });
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        var now: f64 = 0;
        while (now < 0.18) {
            const dt = @min(1 / fps, 0.18 - now);
            now += dt;
            _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, dt, now);
        }
        if (fps == 30) reference = player.position;
        inline for (0..3) |axis| try std.testing.expectApproxEqAbs(reference[axis], player.position[axis], 0.000001);
        try std.testing.expect(player.position[0] > 1.6 and player.position[2] > 0.7);
        _ = try player.update(&fixture.world, .{}, 0.18, 0.36);
        try std.testing.expectApproxEqAbs(@as(f64, 2.2), player.position[0], 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
        try std.testing.expect(player.grounded);
    }
}

test "releasing Space or movement and reversing direction finishes the committed climb" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.set(.{ 2, 0, 0 }, .stone);
    for ([_]Input{
        .{ .right = 1 },
        .{ .jump_down = true },
        .{},
        .{ .right = -1, .jump_down = true },
    }) |input| {
        var player = PlayerController.init(std.testing.allocator, .{ 1.21, 0.5, 0 });
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.08, 0.08);
        const before = player.position;
        const result = try player.update(&fixture.world, input, 0.02, 0.1);
        try std.testing.expect(!result.recovered);
        try std.testing.expect(player.climb != null);
        try std.testing.expect(player.position[0] > before[0] and player.position[2] > before[2]);
        _ = try player.update(&fixture.world, input, 0.26, 0.36);
        try std.testing.expect(player.climb == null);
        try std.testing.expect(player.grounded);
        try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 2.2), player.position[0], 0.000001);
    }
}

test "terrain removal, new overhead terrain and missing chunks cancel a committed route safely" {
    for (0..3) |variant| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        fixture.floor();
        fixture.set(.{ 2, 0, 0 }, .stone);
        var player = PlayerController.init(std.testing.allocator, .{ 1.21, 0.5, 0 });
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.04, 0.04);
        const height = player.position[2];
        try std.testing.expect(height > 0 and height < 0.2);
        if (variant == 0) {
            fixture.fill(.{ 1, 0, 2 }, .{ 2, 0, 2 }, .stone);
        } else if (variant == 1) {
            fixture.set(.{ 2, 0, 0 }, .none);
        } else {
            // The landing uses the same chunk, so disappearance freezes the body
            // before a stale trajectory can enter unknown space.
            fixture.world.removeChunk(fixture.world.layout.getChunkCoords(player.position));
        }
        player.terrainChanged();
        const result = try player.update(&fixture.world, .{}, 0.01, 0.05);
        try std.testing.expect(!result.recovered);
        try std.testing.expect(player.climb == null);
        if (variant == 2) {
            try std.testing.expect(result.missing_chunk != null);
            try std.testing.expectEqual(height, player.position[2]);
        } else {
            try std.testing.expect(player.position[2] < height);
            var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
            try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
        }
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

test "two-box body distinguishes lower envelope grazing from actual collision in every query" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 2, 0, 0 }, .stone);
    const body: collision.Body = .{};
    const feet: Position = .{ 1.8, 0.5, 0.8 };
    var query: collision.Query = .{ .world = &fixture.world, .body = body };
    try std.testing.expect(body.bounds(feet).max[0] > 2);
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(feet, false));
    const block = [3]u32{ 66, 64, 64 };
    try std.testing.expect(!collision.overlapsBlock(body, feet, fixture.world.layout, block));
    const sideways = query.moveAxis(feet, 0, 0.1);
    try std.testing.expect(sideways.collided);
    try std.testing.expectApproxEqAbs(@as(f64, 1.85), sideways.position[0], 0.000001);
    try std.testing.expect(collision.overlapsBlock(body, .{ 1.9, 0.5, 0.8 }, fixture.world.layout, block));
    const down = query.moveAxis(feet, 2, -0.5);
    try std.testing.expect(down.collided);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), down.position[2], 0.000001);
    fixture.set(.{ 1, 0, 3 }, .stone);
    const up = query.moveAxis(feet, 2, 1);
    try std.testing.expect(up.collided);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), up.position[2], 0.000001);
}

test "narrow feet remain supported on seams and ledges without changing standing height" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, -1 }, .stone);
    fixture.set(.{ 1, 0, -1 }, .stone);
    for ([_]f64{ 0, 0.5, 1, 1.5, 2.1 }) |x| {
        var player = PlayerController.init(std.testing.allocator, .{ x, 0.5, 0 });
        defer player.deinit();
        _ = try player.update(&fixture.world, .{}, 0.1, 0.1);
        try std.testing.expect(player.grounded);
        try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
    }
}

test "narrow-foot climb handles opposite and diagonal approaches and periodic seams" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 4, 4, 0 }, .stone);
    for ([_]Position{ .{ 1.21, 0.5, 0 }, .{ 5.79, 0.5, 0 }, .{ 1.21, 1.21, 0 } }, [_]Input{ .{ .right = 1, .jump_down = true }, .{ .right = -1, .jump_down = true }, .{ .right = 1, .forward = 1, .jump_down = true } }) |start, input| {
        var player = PlayerController.init(std.testing.allocator, start);
        defer player.deinit();
        player.space_held_seconds = climb_hold_seconds;
        _ = try player.update(&fixture.world, input, 0.6, 0.6);
        try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
        var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
    }
    fixture.fill(.{ 60, -1, -1 }, .{ 66, 1, -1 }, .stone);
    fixture.fill(.{ 64, -1, 0 }, .{ 66, 1, 0 }, .stone);
    const width: f64 = @floatFromInt(fixture.world.layout.size_in_blocks[0]);
    var player = PlayerController.init(std.testing.allocator, .{ 63.21 + 3 * width, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.36, 0.36);
    try std.testing.expectApproxEqAbs(@as(f64, 64.2 + 3 * width), player.position[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1), player.position[2], 0.000001);
}

test "narrow-foot controller climbs consecutive one-block stairs without recovering" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.fill(.{ 2, -1, 0 }, .{ 6, 1, 0 }, .stone);
    fixture.fill(.{ 3, -1, 1 }, .{ 6, 1, 1 }, .stone);
    fixture.fill(.{ 4, -1, 2 }, .{ 6, 1, 2 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 1.21, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    for (0..144) |index| {
        const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 1.0 / 120.0, @as(f64, @floatFromInt(index + 1)) / 120.0);
        try std.testing.expect(!result.recovered and !result.recovery_failed);
        try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
    }
    try std.testing.expect(player.position[0] > 4);
    try std.testing.expectApproxEqAbs(@as(f64, 3), player.position[2], 0.000001);
    try std.testing.expect(player.grounded);
}

test "a focus-reset climb can rest on its side shoulder and walk away safely" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.set(.{ 2, 0, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 1.21, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.25, 0.25);
    try std.testing.expect(player.position[0] > 1.7 and player.position[2] < 1);
    player.resetJumpInput();
    const stopped = try player.update(&fixture.world, .{}, 0.3, 0.55);
    try std.testing.expect(!stopped.recovered and !stopped.recovery_failed);
    try std.testing.expect(player.grounded);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), player.position[2], 0.000001);
    const away = try player.update(&fixture.world, .{ .right = -1 }, 0.6, 1.15);
    try std.testing.expect(!away.recovered and !away.recovery_failed);
    try std.testing.expect(player.position[0] < 1.7);
    try std.testing.expect(player.grounded);
    try std.testing.expectApproxEqAbs(@as(f64, 0), player.position[2], 0.000001);
}

test "terrain embedding during narrow-foot climbing recovers and clears the route" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.set(.{ 2, 0, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 1.21, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.1, 0.1);
    fixture.set(.{ 1, 0, 1 }, .stone);
    player.terrainChanged();
    const recovered = try player.update(&fixture.world, .{}, 0, 0.1);
    try std.testing.expect(recovered.recovered);
    try std.testing.expect(player.climb == null);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
}

test "loss of a future landing chunk cancels without entering unknown space" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fill(.{ 30, -1, -1 }, .{ 34, 1, -1 }, .stone);
    fixture.set(.{ 32, 0, 0 }, .stone);
    var player = PlayerController.init(std.testing.allocator, .{ 31.21, 0.5, 0 });
    defer player.deinit();
    player.space_held_seconds = climb_hold_seconds;
    _ = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.04, 0.04);
    try std.testing.expect(player.climb != null);
    const landing_chunk = fixture.world.layout.getChunkCoords(.{ 32.5, 0.5, 0 });
    fixture.world.removeChunk(landing_chunk);
    player.terrainChanged();
    const result = try player.update(&fixture.world, .{ .right = 1, .jump_down = true }, 0.2, 0.24);
    try std.testing.expect(!result.recovered and !result.recovery_failed);
    try std.testing.expectEqualDeep(landing_chunk, result.missing_chunk.?);
    try std.testing.expect(player.climb == null);
    try std.testing.expect(player.position[0] <= 31.7 + collision.epsilon);
    var query: collision.Query = .{ .world = &fixture.world, .body = player.body };
    try std.testing.expectEqual(collision.Overlap.clear, query.overlap(player.position, false));
}
