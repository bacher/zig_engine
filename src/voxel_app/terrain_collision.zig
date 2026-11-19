//! CPU collision queries against the composed optimistic physical world.
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
        if (!coordinates.isPlayableY(self.world.layout, block[1], self.world.playable_y_inset)) return .{ .occupancy = .solid };
        const chunk_coords, _ = @import("world.zig").splitBlockCoords(block);
        switch (self.world.warehouseOccupancy(block)) {
            .cargo => return .{ .occupancy = .solid },
            .unknown => {
                if (report_missing) self.missing_chunk = self.missing_chunk orelse chunk_coords;
                return .{ .occupancy = .missing };
            },
            else => {},
        }
        const material = self.world.reader().get(.{ block[0], block[1], block[2] }) orelse {
            if (report_missing) self.missing_chunk = self.missing_chunk orelse chunk_coords;
            return .{ .occupancy = .missing };
        };
        // Missing construction definitions/progress use the same blocked-world
        // behavior as missing terrain. Packed cargo can extend movement queries
        // separately without becoming support/capturable material.
        return .{
            .occupancy = if (movementCollision(material) == .full_cube) .solid else .clear,
            .shape = if (material == .custom) self.world.customShape(block) else null,
        };
    }

    /// Search only halos of cargo actually intersecting this body. Candidate
    /// full-body sources are already inside the player's pinned 3x3x3 chunk
    /// neighborhood (a warehouse spans at most five cells plus its halo).
    pub fn warehouseHalo(self: *Query, feet: Position) ?Position {
        const bounds = self.body.bounds(feet);
        const first = bounds.firstCell();
        const last = bounds.lastCell();
        var best: ?Position = null;
        var best_distance = @import("std").math.inf(f64);
        var seen: [8]@import("construction_state.zig").Identity = undefined;
        var seen_count: usize = 0;
        var z = first[2];
        while (z <= last[2]) : (z += 1) {
            var y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) {
                    const block = coordinates.fromWorld(self.world.layout, .{ x, y, z }) orelse continue;
                    const owner = switch (self.world.warehouseOccupancy(block)) {
                        .cargo => |record| record,
                        else => continue,
                    };
                    var duplicate = false;
                    for (seen[0..seen_count]) |identity| if (@import("std").meta.eql(identity, owner.identity)) {
                        duplicate = true;
                        break;
                    };
                    if (duplicate) continue;
                    if (seen_count < seen.len) {
                        seen[seen_count] = owner.identity;
                        seen_count += 1;
                    }
                    var dy = owner.geometry.bounds.ymin - 1;
                    while (dy <= owner.geometry.bounds.ymax + 1) : (dy += 1) {
                        var dx = owner.geometry.bounds.xmin - 1;
                        while (dx <= owner.geometry.bounds.xmax + 1) : (dx += 1) {
                            if (owner.geometry.bounds.contains(.{ dx, dy })) continue;
                            const cell = owner.geometry.worldCell(self.world.layout.size_in_blocks, .{ dx, dy, 0 }) orelse continue;
                            var world_cell = @as(Cell, .{ cell[0], cell[1], cell[2] }) - @as(Cell, self.world.layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
                            // Use the nearest wrapped copy, including repeated trips.
                            if (comptime engine.WorldLayout.wrap_x) {
                                const width: i64 = self.world.layout.size_in_blocks[0];
                                const current_x: i64 = @intFromFloat(@floor(feet[0]));
                                world_cell[0] = current_x + @mod(world_cell[0] - current_x + @divTrunc(width, 2), width) - @divTrunc(width, 2);
                            }
                            const destination = cellPosition(world_cell);
                            const delta = destination - feet;
                            const distance = @reduce(.Add, delta * delta);
                            if (distance >= best_distance) continue;
                            switch (self.overlap(destination, true)) {
                                .clear => {
                                    best = destination;
                                    best_distance = distance;
                                },
                                else => {},
                            }
                        }
                    }
                }
            }
        }
        return best;
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

test "polar walls and finite floor do not depend on loaded terrain" {
    const std = @import("std");
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 4 } });
    var world = try World.init(std.testing.allocator, &layout);
    defer world.deinit();
    world.playable_y_inset = 64;
    try world.insertChunk(.{ 4, 2, 2 }, @import("world.zig").WorldChunk.initEmpty());
    var query: Query = .{ .world = &world, .body = .{} };
    const feet: Position = .{ 0.5, -63.5, 0 };
    try std.testing.expectEqual(Overlap.clear, query.overlap(feet, false));
    const stopped = query.moveAxis(feet, 1, -10);
    try std.testing.expect(stopped.collided);
    try std.testing.expectApproxEqAbs(@as(f64, -63.7), stopped.position[1], epsilon);
    try std.testing.expectEqual(Overlap.solid, query.overlap(.{ 0.5, -65, 0 }, false));
    try std.testing.expectEqual(Overlap.solid, query.overlap(.{ 0.5, 65, 0 }, false));
    try std.testing.expectEqual(Overlap.solid, query.overlap(.{ 0.5, 0.5, -64.1 }, false));
    // A flat profile reserves no polar rows, so an unloaded row is missing data.
    world.playable_y_inset = 0;
    try std.testing.expectEqual(Overlap.missing, query.overlap(.{ 0.5, -65, 0 }, false));
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

test "warehouse cargo collision and halo recovery use logical state before graphics" {
    const std = @import("std");
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, 0 }, .pallet);
    var query: Query = .{ .world = &fixture.world, .body = .{} };
    try std.testing.expectEqual(Overlap.clear, query.overlap(.{ 0.5, 0.5, 0 }, false));
    fixture.fill(.{ -1, -1, 0 }, .{ 1, 1, 1 }, .stone);
    fixture.fill(.{ -1, -1, 0 }, .{ -1, -1, 1 }, .none);
    const origin = coordinates.fromWorld(fixture.world.layout, .{ 0, 0, 0 }).?;
    const record: @import("warehouse_state.zig").Record = .{ .identity = .{ .kind = .warehouse, .world_session = 91, .id = 1, .lifetime = 1 }, .geometry = try @import("warehouse_layout.zig").Geometry.fromMinimum(fixture.world.layout.size_in_blocks, origin, .{ 1, 1 }), .material = .sand, .stock = 1, .active = 1, .revision = 1 };
    const cache = &fixture.world.warehouses;
    _ = cache.acceptSession(91);
    const source_chunks = try @import("warehouse_claims.zig").chunks(fixture.world.layout.size_in_blocks, record.geometry);
    for (source_chunks.coords[0..source_chunks.count]) |coords| {
        const id = fixture.world.layout.encodeChunkCoords(.{ @intCast(coords[0]), @intCast(coords[1]), @intCast(coords[2]) });
        _ = try cache.installChunk(std.testing.allocator, id, 1, 1, &.{.{ .identity = record.identity, .geometry = record.geometry }});
    }
    cache.subscribed(record.identity, 7);
    _ = cache.apply(.{ .snapshot = .{ .identity = record.identity, .record = record, .subscription_id = 7 } });
    try std.testing.expectEqual(Overlap.solid, query.overlap(.{ 0.5, 0.5, 0 }, false));
    // Contradictory occupied halo is excluded; the free corner is legal with no
    // support or path requirement. The result is a complete 1.8m body check.
    const destination = query.warehouseHalo(.{ 0.5, 0.5, 0 }).?;
    try std.testing.expectEqualDeep(Position{ -0.5, -0.5, 0 }, destination);
    try std.testing.expectEqual(Overlap.clear, query.overlap(destination, false));
    cache.invalidate(record.identity);
    try std.testing.expectEqual(Overlap.missing, query.overlap(.{ 0.5, 0.5, 0 }, false));
    try std.testing.expect(query.warehouseHalo(.{ 0.5, 0.5, 0 }) == null);
}
