//! Coordinate conversion shared by terrain readers; callers choose edge behavior.
const engine = @import("engine");
pub const Cell = @Vector(3, i64);

pub fn origin(layout: *const engine.WorldLayout) Cell {
    return @as(Cell, layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
}

/// Normalize a storage-space cell, wrapping x and rejecting finite y/z edges.
pub fn normalize(layout: *const engine.WorldLayout, cell: Cell) ?[3]u32 {
    var stored = cell;
    stored[0] = @mod(stored[0], layout.size_in_blocks[0]);
    if (stored[1] < 0 or stored[1] >= layout.size_in_blocks[1] or
        stored[2] < 0 or stored[2] >= layout.size_in_blocks[2]) return null;
    return @as(@Vector(3, u32), @intCast(stored));
}

pub fn fromWorldCell(layout: *const engine.WorldLayout, cell: Cell) ?[3]u32 {
    return normalize(layout, cell + origin(layout));
}
