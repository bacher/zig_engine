//! CPU collision queries against the application's optimistic block cache.
const engine = @import("engine");
const World = @import("world.zig").World;
pub const Position = engine.world_math.Position;
pub const Cell = @Vector(3, i64);
pub const epsilon: f64 = 0.0000001;
/// Experimental climb exemption is restricted to the last 12cm of the feet.
pub const max_climb_overlap: f64 = 0.12;

pub const ClimbOverlap = struct {
    top: f64,
    cells: [4]Cell = undefined,
    count: usize = 0,

    fn allows(self: ClimbOverlap, cell: Cell, feet: Position) bool {
        if (feet[2] < self.top - max_climb_overlap - epsilon) return false;
        for (self.cells[0..self.count]) |allowed| {
            if (@reduce(.And, cell == allowed)) return true;
        }
        return false;
    }
};

pub const MovementCollision = enum { none, full_cube };

/// A type property shared by all instances. Occupancy/meshing rules stay separate.
pub fn movementCollision(block: engine.voxel_chunk.BlockType) MovementCollision {
    return switch (block) {
        .none => .none,
        // Water remains a solid cube until swimming/fluid movement is introduced.
        .stone, .dirt, .grass, .water, .sand, .snow => .full_cube,
    };
}

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

pub const Bounds = struct {
    min: Position,
    max: Position,

    fn firstCell(self: Bounds) Cell {
        return @intFromFloat(@floor(self.min + @as(Position, @splat(epsilon))));
    }

    fn lastCell(self: Bounds) Cell {
        return @intFromFloat(@ceil(self.max - @as(Position, @splat(epsilon))) - @as(Position, @splat(1)));
    }
};

pub const Overlap = enum { clear, missing, solid };
pub const Move = struct { position: Position, collided: bool };

pub const Query = struct {
    world: *const World,
    body: Body,
    /// Only contact queries report missing data; recovery searches remain quiet.
    missing_chunk: ?engine.ChunkCoords = null,
    climb_overlap: ?ClimbOverlap = null,

    /// Capture only the known solid cells directly under the planned landing.
    /// Later edits to other cells and missing chunks never receive an exemption.
    pub fn landingOverlap(self: *Query, landing: Position) ?ClimbOverlap {
        const bounds = self.body.bounds(landing - Position{ 0, 0, max_climb_overlap });
        const first = bounds.firstCell();
        const last = bounds.lastCell();
        var overlap_cells: ClimbOverlap = .{ .top = landing[2] };
        var z = first[2];
        while (z <= last[2]) : (z += 1) {
            var y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) {
                    const cell = Cell{ x, y, z };
                    switch (self.cellState(cell, true)) {
                        .missing => return null,
                        .solid => {
                            if (@abs(@as(f64, @floatFromInt(z + 1)) - landing[2]) > epsilon or overlap_cells.count == overlap_cells.cells.len) return null;
                            overlap_cells.cells[overlap_cells.count] = cell;
                            overlap_cells.count += 1;
                        },
                        .clear => {},
                    }
                }
            }
        }
        return if (overlap_cells.count == 0) null else overlap_cells;
    }

    fn exempt(self: *const Query, cell: Cell, feet: Position) bool {
        return if (self.climb_overlap) |overlap_cells| overlap_cells.allows(cell, feet) else false;
    }

    fn cellState(self: *Query, cell: Cell, report_missing: bool) Overlap {
        const layout = self.world.layout;
        const origin: Cell = @as(Cell, layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
        var stored = cell + origin;
        stored[0] = @mod(stored[0], layout.size_in_blocks[0]);
        // The finite y/z edges are walls. X follows the voxel application's topology.
        if (stored[1] < 0 or stored[1] >= layout.size_in_blocks[1] or
            stored[2] < 0 or stored[2] >= layout.size_in_blocks[2]) return .solid;
        const block: [3]u32 = @as(@Vector(3, u32), @intCast(stored));
        const chunk_coords, const local = @import("world.zig").splitBlockCoords(block);
        const chunk = self.world.getChunk(chunk_coords) orelse {
            if (report_missing) self.missing_chunk = self.missing_chunk orelse chunk_coords;
            return .missing;
        };
        return if (movementCollision(chunk.content.getBlock(local)) == .full_cube) .solid else .clear;
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
                    switch (self.cellState(.{ x, y, z }, report_missing)) {
                        .solid => if (!self.exempt(.{ x, y, z }, feet)) {
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
                    const face: f64 = @floatFromInt(cell[axis]);
                    const gap = if (distance > 0) face - body_bounds.max[axis] else face + 1 - body_bounds.min[axis];
                    if (distance > 0 and (gap < -epsilon or gap > allowed)) continue;
                    if (distance < 0 and (gap > epsilon or gap < allowed)) continue;
                    const state = self.cellState(cell, true);
                    if (state == .clear or (state == .solid and self.exempt(cell, feet))) continue;
                    allowed = if (distance > 0) @max(0, gap) else @min(0, gap);
                }
            }
        }
        var position = feet;
        position[axis] += allowed;
        return .{ .position = position, .collided = @abs(allowed - distance) > epsilon };
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
