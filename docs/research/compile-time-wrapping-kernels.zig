// Assembly probe for the actual engine coordinate implementation.
// See ../world-configuration.md for commands and observed code generation.
// Exported entry points keep world dimensions and input coordinates runtime.
const WorldLayout = @import("world_layout").WorldLayout;

export fn delta_x(layout: *const WorldLayout, a: i32, b: i32) i64 {
    return layout.getChunkDelta(.{ a, 0, 0 }, .{ b, 0, 0 })[0];
}

export fn chunk_x(layout: *const WorldLayout, x: f64) i32 {
    return layout.getChunkCoords(.{ x, 0, 0 })[0];
}

export fn normalize_x(layout: *const WorldLayout, x: i32) i32 {
    const coords = layout.normalizeChunkCoords(.{ x, 0, 0 }) orelse return -1;
    return coords[0];
}
