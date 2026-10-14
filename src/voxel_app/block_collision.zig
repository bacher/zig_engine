//! Shared block collision properties and box-to-cell geometry.
const engine = @import("engine");
pub const Position = engine.world_math.Position;
pub const Cell = @import("block_coordinates.zig").Cell;
pub const epsilon: f64 = 0.0000001;

pub const MovementCollision = enum { none, full_cube };

/// A type property shared by all instances. Occupancy/meshing rules stay separate.
pub fn movementCollision(block: engine.voxel_chunk.BlockType) MovementCollision {
    return switch (block) {
        .none => .none,
        // Water remains a solid cube until swimming/fluid movement is introduced.
        .stone,
        .dirt,
        .grass,
        .water,
        .sand,
        .snow,
        .packed_dirt,
        .crushed_stone,
        .tree_trunk,
        .planks,
        .rebar,
        .reinforced_concrete,
        .country_road_solid,
        .country_road_adaptive,
        .custom,
        => .full_cube,
    };
}

pub const Bounds = struct {
    min: Position,
    max: Position,

    /// Cells whose interiors overlap the box on x/y. Shared with spawn support.
    pub fn horizontalCells(self: Bounds) HorizontalCells {
        return .{
            .first = .{ firstOverlappingCell(self.min[0]), firstOverlappingCell(self.min[1]) },
            .last = .{ lastOverlappingCell(self.max[0]), lastOverlappingCell(self.max[1]) },
        };
    }

    pub fn firstCell(self: Bounds) Cell {
        const horizontal = self.horizontalCells();
        return .{ horizontal.first[0], horizontal.first[1], firstOverlappingCell(self.min[2]) };
    }

    pub fn lastCell(self: Bounds) Cell {
        const horizontal = self.horizontalCells();
        return .{ horizontal.last[0], horizontal.last[1], lastOverlappingCell(self.max[2]) };
    }
};

pub const HorizontalCells = struct { first: [2]i64, last: [2]i64 };

fn firstOverlappingCell(min: f64) i64 {
    return @intFromFloat(@floor(min + epsilon));
}

fn lastOverlappingCell(max: f64) i64 {
    return @intFromFloat(@ceil(max - epsilon) - 1);
}
