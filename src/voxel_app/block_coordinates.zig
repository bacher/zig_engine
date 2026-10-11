//! Cell conversion for the wrapped x axis and finite y/z storage bounds.
const engine = @import("engine");

pub const Cell = @Vector(3, i64);

/// Resolve a signed storage cell. Callers decide how to handle finite boundaries.
pub fn fromStorage(layout: *const engine.WorldLayout, cell: Cell) ?[3]u32 {
    if (cell[1] < 0 or cell[1] >= layout.size_in_blocks[1] or
        cell[2] < 0 or cell[2] >= layout.size_in_blocks[2]) return null;
    return .{ @intCast(@mod(cell[0], layout.size_in_blocks[0])), @intCast(cell[1]), @intCast(cell[2]) };
}

/// Translate a world cell by the layout origin before resolving storage bounds.
pub fn fromWorld(layout: *const engine.WorldLayout, cell: Cell) ?[3]u32 {
    const origin: Cell = @as(Cell, layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
    return fromStorage(layout, cell + origin);
}
