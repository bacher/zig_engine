//! Shared creation/management reach against current members and occupied cargo.
const std = @import("std");
const WorldLayout = @import("engine").WorldLayout;
const Position = @import("engine").world_math.Position;
const warehouse_layout = @import("warehouse_layout.zig");
const block_targeting = @import("block_targeting.zig");

/// The caller supplies a captured viewpoint and any cached cargo layout.
/// Geometry alone proves member reach; missing layout cannot prove cargo reach.
pub fn withinReach(world: *const WorldLayout, geometry: warehouse_layout.Geometry, order: ?*const warehouse_layout.Layout, stock: u16, active: u8, viewpoint: Position) bool {
    var y = geometry.bounds.ymin;
    while (y <= geometry.bounds.ymax) : (y += 1) {
        var x = geometry.bounds.xmin;
        while (x <= geometry.bounds.xmax) : (x += 1) {
            const cell = geometry.worldCell(world.size_in_blocks, .{ x, y, 0 }) orelse continue;
            if (block_targeting.withinReach(world, viewpoint, cell)) return true;
        }
    }
    const cargo = order orelse return false;
    for (0..stock) |index| {
        const slot = cargo.slotAt(active, @intCast(index)) orelse return false;
        const cell = geometry.worldCell(world.size_in_blocks, slot) orelse continue;
        if (block_targeting.withinReach(world, viewpoint, cell)) return true;
    }
    return false;
}

test "warehouse reach includes empty edge members and only current occupied upper cargo" {
    const world = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const geometry = try warehouse_layout.Geometry.fromMinimum(world.size_in_blocks, .{ 64, 64, 64 }, .{ 5, 5 });
    const order = warehouse_layout.Layout.init(geometry);
    const edge: Position = .{ 9, 2, 0 };
    try std.testing.expect(!block_targeting.withinReach(&world, edge, geometry.origin));
    try std.testing.expect(withinReach(&world, geometry, &order, 0, 0, edge));
    try std.testing.expect(withinReach(&world, geometry, null, 150, 25, edge));
    try std.testing.expect(!withinReach(&world, geometry, &order, 0, 0, .{ 9.000001, 2, 0 }));
    const above: Position = .{ 2, 2, 10 };
    try std.testing.expect(!withinReach(&world, geometry, &order, 0, 25, above));
    try std.testing.expect(withinReach(&world, geometry, &order, 150, 25, above));
    // Reducing active capacity does not remove cargo in inactive columns.
    try std.testing.expect(withinReach(&world, geometry, &order, 150, 0, above));
    try std.testing.expect(!withinReach(&world, geometry, null, 150, 25, above));
    try std.testing.expect(!withinReach(&world, geometry, &order, 150, 25, .{ 2, 2, 10.000001 }));
}

test "warehouse reach preserves inclusive four metre nearest vertices" {
    const world = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const geometry = try warehouse_layout.Geometry.fromMinimum(world.size_in_blocks, .{ 64, 64, 64 }, .{ 1, 1 });
    inline for (0..8) |vertex| {
        const corner: Position = .{ vertex & 1, (vertex >> 1) & 1, (vertex >> 2) & 1 };
        const outward = (corner * @as(Position, @splat(2)) - @as(Position, @splat(1))) / @as(Position, @splat(@sqrt(@as(f64, 3))));
        try std.testing.expect(withinReach(&world, geometry, null, 0, 0, corner + outward * @as(Position, @splat(4))));
        try std.testing.expect(!withinReach(&world, geometry, null, 0, 0, corner + outward * @as(Position, @splat(4.000001))));
    }
    // Being four metres from a face interior does not imply vertex reach.
    try std.testing.expect(!withinReach(&world, geometry, null, 0, 0, .{ 0.5, 0.5, 5 }));
}

test "warehouse reach crosses wrapped x footprints after repeated world trips" {
    const world = try WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const geometry = try warehouse_layout.Geometry.fromMinimum(world.size_in_blocks, .{ 126, 64, 64 }, .{ 5, 1 });
    const order = warehouse_layout.Layout.init(geometry);
    for ([_]f64{ 0, 128, -256, 128 * 10000000000.0 }) |trip| {
        const near: Position = .{ -57 + trip, 0, 0 };
        try std.testing.expect(!block_targeting.withinReach(&world, near, geometry.origin));
        try std.testing.expect(withinReach(&world, geometry, null, 0, 0, near));
        try std.testing.expect(!withinReach(&world, geometry, null, 0, 0, .{ -56.9 + trip, 0, 0 }));
        try std.testing.expect(withinReach(&world, geometry, &order, 30, 5, .{ -61 + trip, 0, 10 }));
        try std.testing.expect(!withinReach(&world, geometry, &order, 0, 5, .{ -61 + trip, 0, 10 }));
    }
}
