//! CPU collision queries against the application's optimistic block cache.
const engine = @import("engine");
const World = @import("world.zig").World;
const coordinates = @import("block_coordinates.zig");
pub const Position = engine.world_math.Position;
pub const Cell = coordinates.Cell;
const geometry = @import("block_collision.zig");
const custom = engine.voxel_chunk.custom_block;
pub const epsilon = geometry.epsilon;
pub const MovementCollision = geometry.MovementCollision;
pub const movementCollision = geometry.movementCollision;
pub const Bounds = geometry.Bounds;
pub const HorizontalCells = geometry.HorizontalCells;
/// Small downward sweep used to recognize standing contact.
pub const ground_probe: f64 = 0.00001;

pub const Body = struct {
    half_width: f64 = 0.3,
    height: f64 = 1.8,
    eye_height: f64 = 1.6,

    pub fn bounds(self: Body, feet: Position) Bounds {
        return .{
            .min = feet - Position{ self.half_width, self.half_width, 0 },
            .max = feet + Position{ self.half_width, self.half_width, self.height },
        };
    }
};

pub const Overlap = enum { clear, missing, solid };
pub const Move = struct { position: Position, collided: bool };

pub const Query = struct {
    world: *const World,
    body: Body,
    /// Only contact queries report missing data; recovery searches remain quiet.
    missing_chunk: ?engine.ChunkCoords = null,

    fn shapeContact(self: *const Query, shape: custom.Shape, cell: Cell, feet: Position, delta: Position) ?f64 {
        return shape.sweep(feet - @as(Position, @floatFromInt(cell)), delta, .{ -self.body.half_width, -self.body.half_width, 0 }, .{ self.body.half_width, self.body.half_width, self.body.height });
    }

    const CellState = struct { occupancy: Overlap, shape: ?custom.Shape = null };

    fn cellState(self: *Query, cell: Cell, report_missing: bool) CellState {
        // The finite y/z edges are walls. X follows the voxel application's topology.
        const block = coordinates.fromWorld(self.world.layout, cell) orelse return .{ .occupancy = .solid };
        const chunk_coords, const local = @import("world.zig").splitBlockCoords(block);
        const chunk = self.world.getChunk(chunk_coords) orelse {
            if (report_missing) self.missing_chunk = self.missing_chunk orelse chunk_coords;
            return .{ .occupancy = .missing };
        };
        const material = chunk.content.getBlock(local);
        // One chunk/material lookup per cell; sparse road metadata is only read
        // for the custom sentinel, never for ordinary terrain or air.
        const road = if (material == .custom) chunk.metadata.road(@import("block_transformations.zig").index(local)) else null;
        return .{
            .occupancy = if (movementCollision(material) == .full_cube) .solid else .clear,
            .shape = if (road) |r| r.shape() else null,
        };
    }

    pub fn overlap(self: *Query, feet: Position, report_missing: bool) Overlap {
        const bounds = self.body.bounds(feet);
        const first = bounds.firstCell();
        const last = bounds.lastCell();
        var result: Overlap = .clear;
        var z = first[2];
        while (z <= last[2]) : (z += 1) {
            var y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) {
                    const state = self.cellState(.{ x, y, z }, report_missing);
                    switch (state.occupancy) {
                        .solid => {
                            if (state.shape) |shape| {
                                if (shape == .slope and bounds.min[2] >= geometry.surfaceHeight(shape, .{ x, y, z }, bounds) - epsilon) continue;
                            }
                            result = .solid;
                        },
                        .missing => if (result == .clear) {
                            result = .missing;
                        },
                        .clear => {},
                    }
                }
            }
        }
        return result;
    }

    /// Earliest contact along a straight horizontal path, in seconds. Intersect each
    /// cube's x/y time intervals so diagonal corners have the same contact time
    /// regardless of how the movement is divided into frames.
    pub fn horizontalContactTime(self: *Query, feet: Position, velocity: Position, duration: f64) ?f64 {
        const bounds = self.body.bounds(feet);
        const delta = velocity * @as(Position, @splat(duration));
        const swept: Bounds = .{
            .min = bounds.min + @min(delta, @as(Position, @splat(0))),
            .max = bounds.max + @max(delta, @as(Position, @splat(0))),
        };
        const first = swept.firstCell();
        const last = swept.lastCell();
        var contact: ?f64 = null;
        var z = first[2];
        while (z <= last[2]) : (z += 1) {
            var y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) {
                    const cell = Cell{ x, y, z };
                    const state = self.cellState(cell, false);
                    if (state.occupancy == .clear) continue;
                    if (state.shape) |shape| if (shape == .slope) {
                        if (self.shapeContact(shape, cell, feet, delta)) |fraction| {
                            const time = fraction * duration;
                            if (contact == null or time < contact.?) contact = time;
                        }
                        continue;
                    };
                    var enter: f64 = 0;
                    var leave = duration;
                    inline for (0..2) |axis| {
                        const face: f64 = @floatFromInt(cell[axis]);
                        if (velocity[axis] == 0) {
                            if (bounds.max[axis] <= face + epsilon or bounds.min[axis] >= face + 1 - epsilon) leave = 0;
                        } else {
                            const a = (face - bounds.max[axis]) / velocity[axis];
                            const b = (face + 1 - bounds.min[axis]) / velocity[axis];
                            enter = @max(enter, @min(a, b));
                            leave = @min(leave, @max(a, b));
                        }
                    }
                    if (enter >= leave or (contact != null and enter > contact.?)) continue;
                    if (state.occupancy == .missing) _ = self.cellState(cell, true);
                    contact = enter;
                }
            }
        }
        return contact;
    }

    /// Sweep along one axis, clipping at the first cube face. The whole path is tested,
    /// so long displacements cannot tunnel through a one-block wall or floor.
    pub fn moveAxis(self: *Query, feet: Position, comptime axis: usize, distance: f64) Move {
        if (distance == 0) return .{ .position = feet, .collided = false };
        const body_bounds = self.body.bounds(feet);
        var swept = body_bounds;
        if (distance > 0) swept.max[axis] += distance else swept.min[axis] += distance;
        const first = swept.firstCell();
        const last = swept.lastCell();
        var allowed = distance;
        var z = first[2];
        while (z <= last[2]) : (z += 1) {
            var y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) {
                    const cell = Cell{ x, y, z };
                    const state = self.cellState(cell, false);
                    if (state.occupancy == .clear) continue;
                    if (state.shape) |shape| if (shape == .slope) {
                        var delta: Position = @splat(0);
                        delta[axis] = distance;
                        if (self.shapeContact(shape, cell, feet, delta)) |fraction| {
                            const gap = distance * fraction;
                            allowed = if (distance > 0) @min(allowed, gap) else @max(allowed, gap);
                        }
                        continue;
                    };
                    const face: f64 = @floatFromInt(cell[axis]);
                    const gap = if (distance > 0) face - body_bounds.max[axis] else face + 1 - body_bounds.min[axis];
                    if (distance > 0 and (gap < -epsilon or gap > allowed)) continue;
                    if (distance < 0 and (gap > epsilon or gap < allowed)) continue;
                    if (state.occupancy == .missing) _ = self.cellState(cell, true);
                    allowed = if (distance > 0) @max(0, gap) else @min(0, gap);
                }
            }
        }
        var position = feet;
        position[axis] += allowed;
        return .{ .position = position, .collided = @abs(allowed - distance) > epsilon };
    }

    const Surface = struct { height: f64, slope: bool };

    fn groundSurface(self: *Query, feet: Position, lower: f64, upper: f64) ?Surface {
        const footprint = self.body.bounds(feet);
        const area = footprint.horizontalCells();
        var result: ?Surface = null;
        var z: i64 = @intFromFloat(@floor(lower - 1));
        const last_z: i64 = @intFromFloat(@floor(upper));
        while (z <= last_z) : (z += 1) {
            var y = area.first[1];
            while (y <= area.last[1]) : (y += 1) {
                var x = area.first[0];
                while (x <= area.last[0]) : (x += 1) {
                    const cell: Cell = .{ x, y, z };
                    if (coordinates.fromWorld(self.world.layout, cell) == null) continue;
                    const state = self.cellState(cell, true);
                    if (state.occupancy != .solid) continue;
                    const shape = state.shape;
                    const height = if (shape) |s| geometry.surfaceHeight(s, cell, footprint) else @as(f64, @floatFromInt(z + 1));
                    if (height < lower - epsilon or height > upper + epsilon) continue;
                    const is_slope = if (shape) |s| s == .slope else false;
                    if (result == null or height > result.?.height + epsilon) {
                        result = .{ .height = height, .slope = is_slope };
                    } else if (@abs(height - result.?.height) <= epsilon and is_slope) result.?.slope = true;
                }
            }
        }
        return result;
    }

    /// Follow a supported road surface in short controller substeps. Lift before an
    /// uphill horizontal sweep, then settle onto the actual surface after wall clipping.
    /// This never grants ordinary cubes step-up behavior, and ceilings clip the lift.
    pub fn moveGroundedAxis(self: *Query, feet: Position, comptime axis: usize, distance: f64) Move {
        if (distance == 0) return .{ .position = feet, .collided = false };
        const current = self.groundSurface(feet, feet[2] - ground_probe, feet[2] + ground_probe) orelse return self.moveAxis(feet, axis, distance);
        var destination = feet;
        destination[axis] += distance;
        const reach = @abs(distance) / 4 + ground_probe;
        const target = self.groundSurface(destination, feet[2] - reach, feet[2] + reach) orelse return self.moveAxis(feet, axis, distance);
        if (!current.slope and !target.slope) return self.moveAxis(feet, axis, distance);
        const raised = self.moveAxis(feet, 2, @max(0, target.height - feet[2]));
        // A ceiling may clip the lift just as the trailing edge leaves it. Keep
        // that valid partial rise; the horizontal sweep still clips against the
        // slope, and settling preserves both ceiling clearance and ground contact.
        const horizontal = self.moveAxis(raised.position, axis, distance);
        const actual = self.groundSurface(horizontal.position, feet[2] - reach, feet[2] + reach) orelse return horizontal;
        const settled = self.moveAxis(horizontal.position, 2, actual.height - horizontal.position[2]);
        return .{ .position = settled.position, .collided = horizontal.collided or settled.collided };
    }
};

/// Centred horizontally in the foot cell, with feet on its bottom face.
pub fn cellPosition(cell: Cell) Position {
    return @as(Position, @floatFromInt(cell)) + Position{ 0.5, 0.5, 0 };
}

/// Tests the nearest periodic image of a storage block against the body.
pub fn overlapsBlock(body: Body, feet: Position, layout: *const engine.WorldLayout, block: [3]u32) bool {
    var min: Position = @as(Position, @floatFromInt(@as(@Vector(3, u32), block))) -
        @as(Position, @floatFromInt(layout.origin_chunk)) * @as(Position, @splat(engine.chunk_utils.CHUNK_SIZE));
    const width: f64 = @floatFromInt(layout.size_in_blocks[0]);
    min[0] += @floor((feet[0] - min[0]) / width + 0.5) * width;
    const bounds = body.bounds(feet);
    return @reduce(.And, bounds.max > min + @as(Position, @splat(epsilon))) and
        @reduce(.And, bounds.min < min + @as(Position, @splat(1 - epsilon)));
}
