//! CPU collision queries against the application's optimistic block cache.
const engine = @import("engine");
const World = @import("world.zig").World;
pub const Position = engine.world_math.Position;
pub const Cell = @Vector(3, i64);
pub const epsilon: f64 = 0.0000001;

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
    /// The lower 20cm is a narrower support, not an allowed terrain penetration.
    foot_height: f64 = 0.2,
    foot_half_width: f64 = 0.15,

    /// The camera/body envelope remains useful for describing the player's size.
    /// Every collision decision uses these two actual boxes instead of the envelope.
    pub fn colliderBounds(self: Body, feet: Position) [2]Bounds {
        return .{
            .{ .min = feet - Position{ self.foot_half_width, self.foot_half_width, 0 }, .max = feet + Position{ self.foot_half_width, self.foot_half_width, self.foot_height } },
            .{ .min = feet + Position{ -self.half_width, -self.half_width, self.foot_height }, .max = feet + Position{ self.half_width, self.half_width, self.height } },
        };
    }

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
        var result: Overlap = .clear;
        for (self.body.colliderBounds(feet)) |bounds| {
            const first = bounds.firstCell();
            const last = bounds.lastCell();
            var z = first[2];
            while (z <= last[2]) : (z += 1) {
                var y = first[1];
                while (y <= last[1]) : (y += 1) {
                    var x = first[0];
                    while (x <= last[0]) : (x += 1) {
                        switch (self.cellState(.{ x, y, z }, report_missing)) {
                            .solid => result = .solid,
                            .missing => if (result == .clear) {
                                result = .missing;
                            },
                            .clear => {},
                        }
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
        var allowed = distance;
        for (self.body.colliderBounds(feet)) |body_bounds| {
            var swept = body_bounds;
            if (distance > 0) swept.max[axis] += distance else swept.min[axis] += distance;
            const first = swept.firstCell();
            const last = swept.lastCell();
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
                        if (self.cellState(cell, true) == .clear) continue;
                        allowed = if (distance > 0) @max(0, gap) else @min(0, gap);
                    }
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
    for (body.colliderBounds(feet)) |bounds| {
        if (@reduce(.And, bounds.max > min + @as(Position, @splat(epsilon))) and
            @reduce(.And, bounds.min < min + @as(Position, @splat(1 - epsilon)))) return true;
    }
    return false;
}
