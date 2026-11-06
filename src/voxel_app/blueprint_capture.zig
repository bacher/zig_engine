//! Client-only capture geometry, detached validation, and draft ownership.
//! Source residency and the single predicted-world copy belong to the main thread.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const BlockType = engine.voxel_chunk.BlockType;
pub const Position = engine.world_math.Position;
pub const Cell = @Vector(3, i64);
pub const max_cells: usize = 1_048_576;
pub const max_source_chunks: usize = 256;
pub const max_name_bytes = 400;
pub const Budgets = struct { max_cells: usize = max_cells_default, max_source_chunks: usize = 256 };
const max_cells_default = max_cells;
pub const range_squared: f64 = 900;
const parallel_epsilon: f64 = 1e-9;

pub const Box = struct {
    min: Cell,
    max: Cell,
    pub fn size(self: Box) [3]u32 {
        return .{ @intCast(self.max[0] - self.min[0] + 1), @intCast(self.max[1] - self.min[1] + 1), @intCast(self.max[2] - self.min[2] + 1) };
    }
    pub fn volume(self: Box) !usize {
        const dimensions = self.size();
        return try std.math.mul(usize, try std.math.mul(usize, dimensions[0], dimensions[1]), dimensions[2]);
    }
};
pub const Stage = enum { anchor, xy, height, loading, validating, invalid, ready, naming };
pub const PlacementTarget = struct { cell: [3]u32, hit: Position };
pub const TargetError = enum { no_target, no_placement_target, invalid_ray, out_of_range, out_of_bounds, ambiguous_x, size_limit, resource_limit };
pub fn targetMessage(reason: TargetError) []const u8 {
    return switch (reason) {
        .no_target => "Aim at a placement cell to choose the first corner.",
        .no_placement_target => "Aim at a solid block face to set XY while at the anchor height.",
        .invalid_ray => "Aim forward across the selection plane.",
        .out_of_range => "Selection point must be within 30 metres of your feet.",
        .out_of_bounds => "Selection point is outside the world.",
        .ambiguous_x => "The selection cannot span exactly half the world.",
        .size_limit => "Blueprint horizontal size exceeds this world's limit.",
        .resource_limit => "Blueprint selection exceeds the capture resource budget.",
    };
}

pub fn horizontalLimit(layout: *const engine.WorldLayout) u32 {
    return @min(layout.size_in_blocks[0] / 2 - 1, layout.size_in_blocks[1]);
}

pub const Selection = struct {
    generation: u64 = 1,
    budgets: Budgets = .{},
    stage: Stage = .anchor,
    anchor: ?Cell = null,
    bounds: ?Box = null,
    target_valid: bool = false,
    target_error: ?TargetError = .no_target,
    /// Exact accepted XY reference in the anchor's chosen periodic frame.
    plane_point: ?Position = null,
    plane_normal: Position = .{ 0, 1, 0 },
    current_hit: ?Position = null,
    current_yaw_heading: Position = .{ 0, 1, 0 },

    pub fn reset(self: *Selection) void {
        const next = self.generation +% 1;
        self.* = .{ .generation = next, .budgets = self.budgets };
    }
    pub fn setAnchor(self: *Selection, layout: *const engine.WorldLayout, cell: [3]u32, camera: Position) void {
        var lifted: Cell = .{ cell[0], cell[1], cell[2] };
        const origin: Position = @as(Position, @floatFromInt(layout.origin_chunk)) * @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
        const width: f64 = @floatFromInt(layout.size_in_blocks[0]);
        const camera_x = camera[0] + origin[0];
        lifted[0] += @as(i64, @intFromFloat(@round((camera_x - @as(f64, @floatFromInt(lifted[0]))) / width))) * @as(i64, layout.size_in_blocks[0]);
        self.anchor = lifted;
        self.bounds = .{ .min = lifted, .max = lifted };
        self.stage = .xy;
        self.target_valid = false;
        self.target_error = .invalid_ray;
    }
    pub fn usesPlacementTarget(self: *const Selection, layout: *const engine.WorldLayout, camera_world: Position) bool {
        if (self.stage != .xy) return false;
        const anchor = self.anchor orelse return false;
        const camera_z = camera_world[2] + @as(f64, @floatFromInt(layout.origin_chunk[2])) * engine.chunk_utils.CHUNK_SIZE;
        const anchor_z: f64 = @floatFromInt(anchor[2]);
        return camera_z >= anchor_z and camera_z < anchor_z + 1;
    }
    fn invalidateTarget(self: *Selection) void {
        self.target_valid = false;
        self.current_hit = null;
        self.target_error = .invalid_ray;
    }
    /// The target contact is an unwrapped world-coordinate point on the camera ray.
    /// Its raw distance determines reach, while only the placement cell's XY is selected.
    pub fn updatePlacementTarget(self: *Selection, layout: *const engine.WorldLayout, feet_world: Position, camera_world: Position, yaw_heading: Position, target: ?PlacementTarget) void {
        if (self.stage != .xy) return;
        self.invalidateTarget();
        _ = self.anchor orelse return;
        const placement = target orelse {
            self.target_error = .no_placement_target;
            return;
        };
        const origin: Position = @as(Position, @floatFromInt(layout.origin_chunk)) * @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
        const camera = camera_world + origin;
        inline for (0..3) |axis| if (!std.math.isFinite(camera[axis])) return;
        if (@abs(camera[0]) >= @as(f64, @floatFromInt(std.math.maxInt(i64) / 2))) return;
        if (placement.cell[1] >= layout.size_in_blocks[1] or placement.cell[2] >= layout.size_in_blocks[2]) {
            self.target_error = .out_of_bounds;
            return;
        }
        var cell: Cell = .{ placement.cell[0], placement.cell[1], placement.cell[2] };
        const width: f64 = @floatFromInt(layout.size_in_blocks[0]);
        cell[0] += @as(i64, @intFromFloat(@round((camera[0] - @as(f64, @floatFromInt(cell[0]))) / width))) * @as(i64, layout.size_in_blocks[0]);
        self.acceptHit(layout, feet_world + origin, placement.hit + origin, yaw_heading, cell);
    }
    /// Inputs are world coordinates. Range is measured on the raw hit before wrapping.
    pub fn updateRay(self: *Selection, layout: *const engine.WorldLayout, feet_world: Position, camera_world: Position, direction: Position, yaw_heading: Position) void {
        if (self.stage != .xy and self.stage != .height) return;
        self.invalidateTarget();
        const anchor = self.anchor orelse return;
        const origin: Position = @as(Position, @floatFromInt(layout.origin_chunk)) * @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
        const camera = camera_world + origin;
        const feet = feet_world + origin;
        inline for (0..3) |axis| if (!std.math.isFinite(camera[axis]) or !std.math.isFinite(feet[axis]) or !std.math.isFinite(direction[axis])) return;
        const length = @sqrt(@reduce(.Add, direction * direction));
        if (!std.math.isFinite(length) or length <= parallel_epsilon) return;
        const ray = direction / @as(Position, @splat(length));
        var normal: Position = .{ 0, 0, 1 };
        var point: Position = .{ 0, 0, @as(f64, @floatFromInt(anchor[2])) + 0.5 };
        if (self.stage == .height) {
            normal = self.plane_normal;
            point = self.plane_point.?;
            // Move only the plane's periodic image, never the confirmed logical bounds.
            const width: f64 = @floatFromInt(layout.size_in_blocks[0]);
            point[0] += @round((camera[0] - point[0]) / width) * width;
        }
        const denominator = @reduce(.Add, normal * ray);
        if (@abs(denominator) <= parallel_epsilon) return;
        const t = @reduce(.Add, normal * (point - camera)) / denominator;
        if (!std.math.isFinite(t) or t < 0) return;
        self.acceptHit(layout, feet, camera + ray * @as(Position, @splat(t)), yaw_heading, null);
    }
    fn acceptHit(self: *Selection, layout: *const engine.WorldLayout, feet: Position, hit: Position, yaw_heading: Position, placement_cell: ?Cell) void {
        const anchor = self.anchor.?;
        inline for (0..3) |axis| if (!std.math.isFinite(feet[axis]) or !std.math.isFinite(hit[axis])) return;
        const delta = hit - feet;
        const squared = @reduce(.Add, delta * delta);
        if (!std.math.isFinite(squared)) return;
        if (squared > range_squared) {
            self.target_error = .out_of_range;
            return;
        }
        if (hit[1] < 0 or hit[1] >= @as(f64, @floatFromInt(layout.size_in_blocks[1])) or
            hit[2] < 0 or hit[2] >= @as(f64, @floatFromInt(layout.size_in_blocks[2])) or
            @abs(hit[0]) >= @as(f64, @floatFromInt(std.math.maxInt(i64) / 2)))
        {
            self.target_error = .out_of_bounds;
            return;
        }
        var endpoint = anchor;
        var accepted_hit = hit;
        if (self.stage == .xy) {
            const raw_x: i64 = if (placement_cell) |cell| cell[0] else @intFromFloat(@floor(hit[0]));
            const width: i64 = layout.size_in_blocks[0];
            const wrapped = @mod(raw_x - anchor[0], width);
            if (wrapped == @divExact(width, 2)) {
                self.target_error = .ambiguous_x;
                return;
            }
            const dx = if (wrapped > @divExact(width, 2)) wrapped - width else wrapped;
            endpoint[0] = anchor[0] + dx;
            endpoint[1] = if (placement_cell) |cell| cell[1] else @intFromFloat(@floor(hit[1]));
            accepted_hit[0] += @as(f64, @floatFromInt(endpoint[0] - raw_x));
            // Preserve the exact horizontal plane Z.
            if (placement_cell == null) accepted_hit[2] = @as(f64, @floatFromInt(anchor[2])) + 0.5;
        } else {
            endpoint[2] = @intFromFloat(@floor(hit[2]));
        }
        var proposed = if (self.stage == .height) self.bounds.? else Box{ .min = @min(anchor, endpoint), .max = @max(anchor, endpoint) };
        if (self.stage == .height) {
            proposed.min[2] = @min(anchor[2], endpoint[2]);
            proposed.max[2] = @max(anchor[2], endpoint[2]);
        }
        const dimensions = proposed.size();
        const limit = horizontalLimit(layout);
        if (dimensions[0] > limit or dimensions[1] > limit) {
            self.target_error = .size_limit;
            return;
        }
        if ((proposed.volume() catch self.budgets.max_cells + 1) > self.budgets.max_cells) {
            self.target_error = .resource_limit;
            return;
        }
        if (self.stage == .xy) {
            const horizontal_length = @sqrt(yaw_heading[0] * yaw_heading[0] + yaw_heading[1] * yaw_heading[1]);
            if (!std.math.isFinite(horizontal_length) or horizontal_length <= parallel_epsilon) return;
            self.current_yaw_heading = .{ yaw_heading[0] / horizontal_length, yaw_heading[1] / horizontal_length, 0 };
        }
        self.bounds = proposed;
        self.current_hit = accepted_hit;
        self.target_valid = true;
        self.target_error = null;
    }
    /// Update the current ray or placement target immediately before confirming.
    pub fn confirmExtent(self: *Selection) bool {
        if (!self.target_valid) return false;
        switch (self.stage) {
            .xy => {
                self.plane_point = self.current_hit.?;
                self.plane_normal = self.current_yaw_heading;
                self.stage = .height;
            },
            .height => self.stage = .loading,
            else => return false,
        }
        return true;
    }
};

pub const NameError = @import("blueprint_name.zig").NameError;
pub const checkedName = @import("blueprint_name.zig").checkedName;

/// One reusable thread, one queued/running input, one result. Cancellation is cooperative.
/// A cancelled job continues to own its detached buffer until the worker releases it.
pub const Helper = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    job: ?Job = null,
    running: bool = false,
    result: ?Result = null,
    pub const Job = struct { generation: u64, size: [3]u32, cells: []BlockType, horizontal_limit: u32, max_cells: usize = max_cells_default };
    pub const Result = struct {
        generation: u64,
        output: ?blueprint.CompileResult = null,
        failed: bool = false,
        pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
            if (self.output) |*output| switch (output.*) {
                .valid => |*valid| valid.deinit(allocator),
                .invalid => {},
                .cancelled => {},
            };
            self.* = undefined;
        }
    };
    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*Helper {
        const self = try allocator.create(Helper);
        self.* = .{ .allocator = allocator, .io = io };
        errdefer allocator.destroy(self);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Helper) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.cancel.store(true, .release);
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        if (self.job) |job| self.allocator.free(job.cells);
        if (self.result) |*result| result.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    /// Ownership transfers only on success. Busy jobs must be polled/cancelled first.
    pub fn submit(self: *Helper, job: Job) error{Busy}!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running or self.job != null or self.result != null) return error.Busy;
        self.cancel.store(false, .release);
        self.job = job;
        self.condition.signal(self.io);
    }
    pub fn isIdle(self: *Helper) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.running and self.job == null and self.result == null;
    }
    pub fn cancelJob(self: *Helper) void {
        self.cancel.store(true, .release);
    }
    pub fn takeResult(self: *Helper) ?Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.result;
        self.result = null;
        return result;
    }
    fn run(self: *Helper) void {
        self.mutex.lockUncancelable(self.io);
        while (true) {
            while (self.job == null and !self.stopping) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) break;
            const job = self.job.?;
            self.job = null;
            self.running = true;
            self.mutex.unlock(self.io);
            var result: Result = .{ .generation = job.generation };
            result.output = blueprint.compile(self.allocator, .{ .size = job.size, .cells = job.cells }, .{ .horizontal_limit = job.horizontal_limit, .max_cells = job.max_cells, .cancel = &self.cancel }) catch blk: {
                result.failed = true;
                break :blk null;
            };
            self.allocator.free(job.cells);
            self.mutex.lockUncancelable(self.io);
            self.running = false;
            self.result = result;
        }
        self.mutex.unlock(self.io);
    }
};

test "names trim Unicode whitespace and count scalars rather than UTF8 bytes" {
    try std.testing.expectEqualStrings("é山", try checkedName(" \xc2\xa0é山\xe3\x80\x80"));
    try std.testing.expectError(error.EmptyName, checkedName(" \xe3\x80\x80"));
    try std.testing.expectError(error.InvalidNameCharacter, checkedName("a\nb"));
    try std.testing.expectError(error.InvalidNameCharacter, checkedName("\nname\n"));
    var name: [202]u8 = undefined;
    for (0..101) |i| @memcpy(name[2 * i ..][0..2], "é");
    try std.testing.expectEqual(@as(usize, 200), (try checkedName(name[0..200])).len);
    try std.testing.expectError(error.NameTooLong, checkedName(&name));
}

fn worldPosition(layout: *const engine.WorldLayout, storage: Position) Position {
    return storage - @as(Position, @floatFromInt(layout.origin_chunk)) * @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
}
fn aim(selection: *Selection, layout: *const engine.WorldLayout, feet: Position, camera: Position, hit: Position, heading: Position) void {
    selection.updateRay(layout, worldPosition(layout, feet), worldPosition(layout, camera), hit - camera, heading);
}

test "three clicks preserve exact fractional XY hit and yaw height plane" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var selection: Selection = .{};
    selection.setAnchor(&layout, .{ 100, 100, 100 }, worldPosition(&layout, .{ 103.2, 103.2, 108 }));
    const camera: Position = .{ 103.2, 103.2, 108 };
    const feet = camera - Position{ 0, 0, 1.6 };
    const point: Position = .{ 105.8, 104.2, 100.5 };
    aim(&selection, &layout, feet, camera, point, .{ 0, 1, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual([3]u32{ 6, 5, 1 }, selection.bounds.?.size());
    try std.testing.expect(selection.confirmExtent());
    try std.testing.expectApproxEqAbs(point[0], selection.plane_point.?[0], 1e-12);
    try std.testing.expectApproxEqAbs(point[1], selection.plane_point.?[1], 1e-12);
    // An unchanged nondegenerate ray must intersect the new plane at the same P.
    aim(&selection, &layout, feet, camera, point, .{ 1, 0, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(@as(u32, 1), selection.bounds.?.size()[2]);
    try std.testing.expectEqual(Position{ 0, 1, 0 }, selection.plane_normal);
    aim(&selection, &layout, .{ 105.8, 99.2, 101.6 }, .{ 105.8, 99.2, 103.2 }, .{ 105.8, 104.2, 96.8 }, .{ 1, 0, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual([3]u32{ 6, 5, 5 }, selection.bounds.?.size());
    const valid = selection.bounds.?;
    selection.updateRay(&layout, worldPosition(&layout, feet), worldPosition(&layout, camera), .{ 1, 0, 0 }, .{ 0, 1, 0 });
    try std.testing.expect(!selection.target_valid);
    try std.testing.expect(!selection.confirmExtent());
    try std.testing.expectEqualDeep(valid, selection.bounds.?);
}

test "XY placement fallback uses precisely the anchor camera-height slab" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var selection: Selection = .{};
    const camera: Position = .{ 103.2, 103.2, 100.25 };
    selection.setAnchor(&layout, .{ 100, 100, 100 }, worldPosition(&layout, camera));
    for ([_]struct { z: f64, enabled: bool }{
        .{ .z = 99.999999, .enabled = false },
        .{ .z = 100, .enabled = true },
        .{ .z = 100.5, .enabled = true },
        .{ .z = 100.999999, .enabled = true },
        .{ .z = 101, .enabled = false },
    }) |case| {
        try std.testing.expectEqual(case.enabled, selection.usesPlacementTarget(&layout, worldPosition(&layout, .{ camera[0], camera[1], case.z })));
    }
    try std.testing.expect(!selection.usesPlacementTarget(&layout, .{ 0, 0, std.math.nan(f64) }));
    selection.stage = .height;
    try std.testing.expect(!selection.usesPlacementTarget(&layout, worldPosition(&layout, camera)));
}

test "placement XY uses the adjacent cube and height immediately follows absolute contact Z" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var selection: Selection = .{};
    const camera: Position = .{ 103.2, 103.2, 100.25 };
    const feet = camera - Position{ 0, 0, 1.6 };
    const contact: Position = .{ 106, 104.2, 105.8 };
    selection.setAnchor(&layout, .{ 100, 100, 100 }, worldPosition(&layout, camera));
    selection.updatePlacementTarget(&layout, worldPosition(&layout, feet), worldPosition(&layout, camera), .{ 0, 2, 0 }, .{
        .cell = .{ 105, 104, 105 },
        .hit = worldPosition(&layout, contact),
    });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(Cell{ 105, 104, 100 }, selection.bounds.?.max);
    try std.testing.expectEqual([3]u32{ 6, 5, 1 }, selection.bounds.?.size());
    try std.testing.expectEqual(contact, selection.current_hit.?);
    try std.testing.expect(selection.confirmExtent());
    try std.testing.expectEqual(contact, selection.plane_point.?);
    try std.testing.expectEqual(Position{ 0, 1, 0 }, selection.plane_normal);
    aim(&selection, &layout, feet, camera, contact, .{ 1, 0, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual([3]u32{ 6, 5, 6 }, selection.bounds.?.size());
    aim(&selection, &layout, feet, camera, contact + Position{ 0, 0, 2.25 }, .{ 1, 0, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(@as(i64, 108), selection.bounds.?.max[2]);
    aim(&selection, &layout, feet, camera, contact - Position{ 0, 0, 2.2 }, .{ 1, 0, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(@as(i64, 103), selection.bounds.?.max[2]);
    aim(&selection, &layout, feet, camera, .{ contact[0], contact[1], 98.8 }, .{ 1, 0, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(@as(i64, 98), selection.bounds.?.min[2]);
    try std.testing.expectEqual(Position{ 0, 1, 0 }, selection.plane_normal);
}

test "invalid placement targets preserve the last bounds and raw reach precedes wrapping" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var selection: Selection = .{};
    const camera: Position = .{ 100.25, 100.25, 100.5 };
    const feet: Position = .{ 100.25, 100.25, 98.9 };
    const heading: Position = .{ 0, 1, 0 };
    selection.setAnchor(&layout, .{ 100, 100, 100 }, worldPosition(&layout, camera));
    const good: PlacementTarget = .{ .cell = .{ 103, 104, 109 }, .hit = worldPosition(&layout, .{ 104, 104.75, 109.2 }) };
    selection.updatePlacementTarget(&layout, worldPosition(&layout, feet), worldPosition(&layout, camera), heading, good);
    try std.testing.expect(selection.target_valid);
    const accepted = selection.bounds.?;
    selection.updatePlacementTarget(&layout, worldPosition(&layout, feet), worldPosition(&layout, camera), heading, null);
    try std.testing.expectEqual(TargetError.no_placement_target, selection.target_error.?);
    try std.testing.expect(!selection.confirmExtent());
    try std.testing.expectEqualDeep(accepted, selection.bounds.?);
    for ([_]struct { target: PlacementTarget, expected: TargetError }{
        .{ .target = .{ .cell = .{ 100, 100, 100 }, .hit = worldPosition(&layout, .{ 356.25, 100.25, 100.5 }) }, .expected = .out_of_range },
        .{ .target = .{ .cell = .{ 103, 256, 109 }, .hit = good.hit }, .expected = .out_of_bounds },
        .{ .target = .{ .cell = .{ 103, 104, 256 }, .hit = good.hit }, .expected = .out_of_bounds },
        .{ .target = .{ .cell = good.cell, .hit = .{ std.math.nan(f64), 0, 0 } }, .expected = .invalid_ray },
    }) |case| {
        selection.updatePlacementTarget(&layout, worldPosition(&layout, feet), worldPosition(&layout, camera), heading, case.target);
        try std.testing.expect(!selection.target_valid);
        try std.testing.expectEqual(case.expected, selection.target_error.?);
        try std.testing.expectEqualDeep(accepted, selection.bounds.?);
    }
    // Reach is inclusive on the raw contact, independent of selected cell Z.
    const contact: Position = .{ 100.25, 100.25, 100.5 };
    selection.updatePlacementTarget(&layout, worldPosition(&layout, contact - Position{ 0, 30, 0 }), worldPosition(&layout, camera), heading, .{ .cell = .{ 100, 100, 230 }, .hit = worldPosition(&layout, contact) });
    try std.testing.expect(selection.target_valid);
    const single = selection.bounds.?;
    selection.updatePlacementTarget(&layout, worldPosition(&layout, contact - Position{ 0, 30.000001, 0 }), worldPosition(&layout, camera), heading, .{ .cell = .{ 100, 100, 230 }, .hit = worldPosition(&layout, contact) });
    try std.testing.expectEqual(TargetError.out_of_range, selection.target_error.?);
    try std.testing.expectEqualDeep(single, selection.bounds.?);
    selection.updatePlacementTarget(&layout, worldPosition(&layout, .{ 100, 0, 100 }), worldPosition(&layout, .{ 100, 0, 100.5 }), heading, .{ .cell = .{ 100, 0, 100 }, .hit = worldPosition(&layout, .{ 100, -1, 100 }) });
    try std.testing.expectEqual(TargetError.out_of_bounds, selection.target_error.?);
    try std.testing.expectEqualDeep(single, selection.bounds.?);
    selection.updatePlacementTarget(&layout, worldPosition(&layout, .{ 227, 100, 100 }), worldPosition(&layout, .{ 227, 100, 100.5 }), heading, .{ .cell = .{ 227, 100, 100 }, .hit = worldPosition(&layout, .{ 227, 100, 100.5 }) });
    try std.testing.expectEqual(TargetError.size_limit, selection.target_error.?);
    try std.testing.expectEqualDeep(single, selection.bounds.?);
    selection.updatePlacementTarget(&layout, worldPosition(&layout, .{ 228, 100, 100 }), worldPosition(&layout, .{ 228, 100, 100.5 }), heading, .{ .cell = .{ 228, 100, 100 }, .hit = worldPosition(&layout, .{ 228, 100, 100.5 }) });
    try std.testing.expectEqual(TargetError.ambiguous_x, selection.target_error.?);
    try std.testing.expectEqualDeep(single, selection.bounds.?);
    selection.budgets.max_cells = 1;
    selection.updatePlacementTarget(&layout, worldPosition(&layout, feet), worldPosition(&layout, camera), heading, good);
    try std.testing.expectEqual(TargetError.resource_limit, selection.target_error.?);
    try std.testing.expectEqualDeep(single, selection.bounds.?);
}

test "placement contact and absolute height preserve the chosen frame across the X seam" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var selection: Selection = .{};
    selection.setAnchor(&layout, .{ 254, 100, 100 }, worldPosition(&layout, .{ 254.25, 100.25, 100.25 }));
    const camera: Position = .{ 2.25, 100.25, 100.25 };
    const feet = camera - Position{ 0, 0, 1.6 };
    const contact: Position = .{ 1, 102.75, 106.25 };
    selection.updatePlacementTarget(&layout, worldPosition(&layout, feet), worldPosition(&layout, camera), .{ -1, 0, 0 }, .{ .cell = .{ 1, 102, 106 }, .hit = worldPosition(&layout, contact) });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(Cell{ 257, 102, 100 }, selection.bounds.?.max);
    try std.testing.expectEqual(Position{ 257, 102.75, 106.25 }, selection.current_hit.?);
    try std.testing.expect(selection.confirmExtent());
    const plane = selection.plane_point.?;
    aim(&selection, &layout, feet, camera, contact, .{ 0, 1, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual([3]u32{ 4, 3, 7 }, selection.bounds.?.size());
    aim(&selection, &layout, feet + Position{ 256, 0, 0 }, camera + Position{ 256, 0, 0 }, contact + Position{ 256, 0, 3.2 }, .{ 0, 1, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual([3]u32{ 4, 3, 10 }, selection.bounds.?.size());
    try std.testing.expectEqual(plane, selection.plane_point.?);
    try std.testing.expectEqual(@as(i64, 257), selection.bounds.?.max[0]);
}

test "absolute height accepts in-bounds hits near either world boundary and validates raw reach" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    for ([_]struct { anchor_z: u32, contact_z: f64, change: f64 }{
        .{ .anchor_z = 0, .contact_z = 10.25, .change = -1 },
        .{ .anchor_z = 255, .contact_z = 250.25, .change = 1 },
    }) |case| {
        var selection: Selection = .{};
        const camera: Position = .{ 100.25, 100.25, @as(f64, @floatFromInt(case.anchor_z)) + 0.25 };
        const contact: Position = .{ 104.75, 104.25, case.contact_z };
        selection.setAnchor(&layout, .{ 100, 100, case.anchor_z }, worldPosition(&layout, camera));
        selection.updatePlacementTarget(&layout, worldPosition(&layout, camera), worldPosition(&layout, camera), .{ 0, 1, 0 }, .{ .cell = .{ 104, 103, @intFromFloat(case.contact_z) }, .hit = worldPosition(&layout, contact) });
        try std.testing.expect(selection.target_valid);
        try std.testing.expect(selection.confirmExtent());
        const accepted = selection.bounds.?;
        aim(&selection, &layout, camera, camera, contact + Position{ 0, 0, case.change }, .{ 0, 1, 0 });
        try std.testing.expect(selection.target_valid);
        const endpoint: i64 = @intFromFloat(@floor(case.contact_z + case.change));
        try std.testing.expectEqual(@min(@as(i64, case.anchor_z), endpoint), selection.bounds.?.min[2]);
        try std.testing.expectEqual(@max(@as(i64, case.anchor_z), endpoint), selection.bounds.?.max[2]);
        try std.testing.expectEqual(accepted.min[0], selection.bounds.?.min[0]);
        try std.testing.expectEqual(accepted.max[1], selection.bounds.?.max[1]);
    }
    var selection: Selection = .{};
    const camera: Position = .{ 100, 100, 100.25 };
    const contact: Position = .{ 100, 110, 120 };
    selection.setAnchor(&layout, .{ 100, 100, 100 }, worldPosition(&layout, camera));
    selection.updatePlacementTarget(&layout, worldPosition(&layout, camera), worldPosition(&layout, camera), .{ 0, 1, 0 }, .{ .cell = .{ 100, 109, 119 }, .hit = worldPosition(&layout, contact) });
    try std.testing.expect(selection.confirmExtent());
    const accepted = selection.bounds.?;
    // The actual plane contact remains subject to the thirty-metre range.
    aim(&selection, &layout, camera, camera, contact + Position{ 0, 0, 15 }, .{ 0, 1, 0 });
    try std.testing.expectEqual(TargetError.out_of_range, selection.target_error.?);
    try std.testing.expectEqualDeep(accepted, selection.bounds.?);
}

test "absolute height rejects plane intersections beyond world Z without applying an offset" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    for ([_]struct { anchor_z: u32, contact_z: f64, raw_z: f64 }{
        .{ .anchor_z = 240, .contact_z = 254, .raw_z = 256 },
        .{ .anchor_z = 15, .contact_z = 1, .raw_z = -1 },
    }) |case| {
        var selection: Selection = .{};
        const camera: Position = .{ 100.25, 100.25, @as(f64, @floatFromInt(case.anchor_z)) + 0.25 };
        const feet = camera - Position{ 0, 0, 1.6 };
        const contact: Position = .{ 100.25, 110, case.contact_z };
        selection.setAnchor(&layout, .{ 100, 100, case.anchor_z }, worldPosition(&layout, camera));
        selection.updatePlacementTarget(&layout, worldPosition(&layout, feet), worldPosition(&layout, camera), .{ 0, 1, 0 }, .{
            .cell = .{ 100, 109, @intFromFloat(case.contact_z) },
            .hit = worldPosition(&layout, contact),
        });
        try std.testing.expect(selection.confirmExtent());
        const accepted = selection.bounds.?;
        aim(&selection, &layout, feet, camera, .{ contact[0], contact[1], case.raw_z }, .{ 0, 1, 0 });
        try std.testing.expectEqual(TargetError.out_of_bounds, selection.target_error.?);
        try std.testing.expectEqualDeep(accepted, selection.bounds.?);
        try std.testing.expect(!selection.confirmExtent());
    }
}

test "range is inclusive from feet and raw far intersections cannot wrap near" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var selection: Selection = .{};
    selection.setAnchor(&layout, .{ 100, 100, 100 }, worldPosition(&layout, .{ 100.25, 100.75, 102.5 }));
    aim(&selection, &layout, .{ 100.25, 70.75, 100.5 }, .{ 100.25, 100.75, 102.5 }, .{ 100.25, 100.75, 100.5 }, .{ 0, 1, 0 });
    try std.testing.expect(selection.target_valid);
    const valid = selection.bounds.?;
    aim(&selection, &layout, .{ 100.25, 70.749, 100.5 }, .{ 100.25, 100.75, 102.5 }, .{ 100.25, 100.75, 100.5 }, .{ 0, 1, 0 });
    try std.testing.expectEqual(TargetError.out_of_range, selection.target_error.?);
    try std.testing.expectEqualDeep(valid, selection.bounds.?);
    aim(&selection, &layout, .{ 100.25, 100.75, 101 }, .{ 100.25, 100.75, 102.5 }, .{ 356.25, 100.75, 100.5 }, .{ 0, 1, 0 });
    try std.testing.expectEqual(TargetError.out_of_range, selection.target_error.?);
    // Walking to the endpoint allows a box longer than the targeting range.
    aim(&selection, &layout, .{ 149.25, 100.75, 101 }, .{ 149.25, 100.75, 102.5 }, .{ 150.25, 100.75, 100.5 }, .{ 0, 1, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(@as(u32, 51), selection.bounds.?.size()[0]);
}

test "short wrapped interval rejects half-period tie and cap without changing bounds" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    var selection: Selection = .{};
    selection.setAnchor(&layout, .{ 254, 100, 100 }, worldPosition(&layout, .{ 254.25, 100.75, 102.5 }));
    aim(&selection, &layout, .{ 258.25, 99.75, 101 }, .{ 258.25, 99.75, 102.5 }, .{ 258.25, 100.75, 100.5 }, .{ 0, 1, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(@as(i64, 258), selection.bounds.?.max[0]);
    try std.testing.expectEqual(@as(u32, 5), selection.bounds.?.size()[0]);
    try std.testing.expect(selection.confirmExtent());
    const plane_point = selection.plane_point.?;
    aim(&selection, &layout, .{ 2.25, 99.75, 101 }, .{ 2.25, 99.75, 102.5 }, .{ 2.25, 100.75, 100.5 }, .{ 1, 0, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(@as(u32, 1), selection.bounds.?.size()[2]);
    try std.testing.expectEqual(plane_point, selection.plane_point.?);
    selection.reset();
    selection.setAnchor(&layout, .{ 10, 100, 100 }, worldPosition(&layout, .{ 10, 100, 102 }));
    aim(&selection, &layout, .{ 136.25, 100, 101 }, .{ 136.25, 100, 102 }, .{ 136.25, 100, 100.5 }, .{ 0, 1, 0 });
    try std.testing.expect(selection.target_valid);
    try std.testing.expectEqual(horizontalLimit(&layout), selection.bounds.?.size()[0]);
    const accepted = selection.bounds.?;
    aim(&selection, &layout, .{ 137.25, 100, 101 }, .{ 137.25, 100, 102 }, .{ 137.25, 100, 100.5 }, .{ 0, 1, 0 });
    try std.testing.expectEqual(TargetError.size_limit, selection.target_error.?);
    aim(&selection, &layout, .{ 138.25, 100, 101 }, .{ 138.25, 100, 102 }, .{ 138.25, 100, 100.5 }, .{ 0, 1, 0 });
    try std.testing.expectEqual(TargetError.ambiguous_x, selection.target_error.?);
    try std.testing.expectEqualDeep(accepted, selection.bounds.?);
}

test "reset immediately invalidates generations and queued helper ownership is bounded" {
    var selection: Selection = .{};
    const original = selection.generation;
    selection.stage = .validating;
    selection.reset();
    try std.testing.expect(selection.generation != original);
    try std.testing.expectEqual(Stage.anchor, selection.stage);
    const allocator = std.testing.allocator;
    const helper = try Helper.create(allocator, std.testing.io);
    defer helper.destroy();
    const cells = try allocator.dupe(BlockType, &.{.dirt});
    try helper.submit(.{ .generation = original, .size = .{ 1, 1, 1 }, .cells = cells, .horizontal_limit = 31 });
    const rejected = try allocator.dupe(BlockType, &.{.dirt});
    defer allocator.free(rejected);
    try std.testing.expectError(error.Busy, helper.submit(.{ .generation = selection.generation, .size = .{ 1, 1, 1 }, .cells = rejected, .horizontal_limit = 31 }));
    helper.cancelJob();
    var result: ?Helper.Result = null;
    while (result == null) {
        result = helper.takeResult();
        if (result == null) std.Thread.yield() catch {};
    }
    defer result.?.deinit(allocator);
    try std.testing.expectEqual(original, result.?.generation);
    try std.testing.expect(helper.isIdle());
}
