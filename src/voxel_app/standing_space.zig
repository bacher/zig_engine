//! A supported surface with clear space above it, read from current blocks.
const std = @import("std");
const engine = @import("engine");
const geometry = @import("block_collision.zig");
const coordinates = @import("block_coordinates.zig");
pub const Reader = @import("block_rules.zig").Reader;
pub const Position = geometry.Position;
const Cell = geometry.Cell;

pub const Error = error{ InvalidSearch, MissingData, NoSurface, NoSpace };

pub const Request = struct {
    preferred_xy: [2]f64,
    /// Metres/blocks, centred on the returned x/y, extending upward from its z.
    clearance_size: [3]f64,
    /// Actual contact footprint; extra clearance at the sides is never support.
    support_size: [2]f64,
    /// Search integer offsets from preferred_xy, up to fifteen blocks per axis.
    search_radius: u4 = 0,
};

fn bounds(xy: [2]f64, size: [3]f64, z: f64) geometry.Bounds {
    return .{
        .min = .{ xy[0] - size[0] / 2, xy[1] - size[1] / 2, z },
        .max = .{ xy[0] + size[0] / 2, xy[1] + size[1] / 2, z + size[2] },
    };
}

fn validate(reader: Reader, request: Request) Error!void {
    for (request.preferred_xy) |coordinate|
        if (!std.math.isFinite(coordinate) or @abs(coordinate) >= 0x1p62) return error.InvalidSearch;
    for (request.clearance_size, 0..) |size, axis|
        if (!std.math.isFinite(size) or size <= 2 * geometry.epsilon or size > @as(f64, @floatFromInt(reader.layout.size_in_blocks[axis]))) return error.InvalidSearch;
    for (request.support_size, 0..) |size, axis|
        if (!std.math.isFinite(size) or size <= 2 * geometry.epsilon or size > request.clearance_size[axis]) return error.InvalidSearch;
    const area = bounds(request.preferred_xy, .{ request.support_size[0], request.support_size[1], 1 }, 0).horizontalCells();
    if (area.first[0] > area.last[0] or area.first[1] > area.last[1]) return error.InvalidSearch;
}

fn solid(reader: Reader, cell: Cell) Error!bool {
    const block = coordinates.fromWorld(reader.layout, cell) orelse return error.NoSpace;
    if (!coordinates.isPlayableY(reader.layout, block[1], reader.playable_y_inset)) return error.NoSpace;
    const material = reader.block_at(reader.context, block) orelse return error.MissingData;
    return geometry.movementCollision(material) == .full_cube;
}

fn shapeAt(reader: Reader, cell: Cell) ?engine.voxel_chunk.custom_block.Shape {
    const read_shape = reader.custom_shape_at orelse return null;
    return read_shape(reader.context, coordinates.fromWorld(reader.layout, cell) orelse return null);
}

fn surface(reader: Reader, cell: Cell, footprint: geometry.Bounds) f64 {
    const origin: Position = @floatFromInt(cell);
    const shape = shapeAt(reader, cell) orelse return origin[2] + 1;
    return geometry.surfaceHeight(shape, cell, footprint);
}

/// Each x/y candidate uses its highest real support. We do not spawn in a cave
/// beneath a blocked surface or replace missing support with a world boundary.
fn at(reader: Reader, request: Request, xy: [2]f64) Error!Position {
    const area = bounds(xy, .{ request.support_size[0], request.support_size[1], 1 }, 0).horizontalCells();
    const origin: Cell = @as(Cell, reader.layout.origin_chunk) * @as(Cell, @splat(engine.chunk_utils.CHUNK_SIZE));
    if (area.first[1] < @as(i64, reader.playable_y_inset) - origin[1] or area.last[1] >= @as(i64, reader.layout.size_in_blocks[1]) - reader.playable_y_inset - origin[1]) return error.NoSpace;
    var z: i64 = @as(i64, reader.layout.size_in_blocks[2]) - origin[2];
    while (z > -origin[2]) {
        z -= 1;
        var supported = false;
        var highest: f64 = -std.math.inf(f64);
        const footprint = bounds(xy, .{ request.support_size[0], request.support_size[1], 1 }, 0);
        var y = area.first[1];
        while (y <= area.last[1]) : (y += 1) {
            var x = area.first[0];
            while (x <= area.last[0]) : (x += 1) {
                // Read every support cell even after finding one; unknown cells
                // could contain a higher obstruction and must not be skipped.
                const occupied = try solid(reader, .{ x, y, z });
                supported = supported or occupied;
                if (occupied) highest = @max(highest, surface(reader, .{ x, y, z }, footprint));
            }
        }
        if (!supported) continue;
        const feet: Position = .{ xy[0], xy[1], highest };
        const volume = bounds(xy, request.clearance_size, feet[2]);
        const first = volume.firstCell();
        const last = volume.lastCell();
        // Check continuous bounds too: the spare volume must fit beneath the ceiling.
        if (volume.max[2] > @as(f64, @floatFromInt(@as(i64, reader.layout.size_in_blocks[2]) - origin[2])) + geometry.epsilon) return error.NoSpace;
        var cz = first[2];
        while (cz <= last[2]) : (cz += 1) {
            y = first[1];
            while (y <= last[1]) : (y += 1) {
                var x = first[0];
                while (x <= last[0]) : (x += 1) {
                    const cell: Cell = .{ x, y, cz };
                    if (try solid(reader, cell)) {
                        if (shapeAt(reader, cell)) |shape| if (shape == .slope and volume.min[2] >= surface(reader, cell, volume) - geometry.epsilon) continue;
                        return error.NoSpace;
                    }
                }
            }
        }
        return feet;
    }
    return error.NoSurface;
}

/// Nearest fitting surface among integer x/y offsets. Ties keep a stable order.
/// Coordinates retain the caller's fractional part and unwrapped x image.
pub fn find(reader: Reader, request: Request) Error!Position {
    try validate(reader, request);
    var best: ?Position = null;
    var best_distance: i32 = std.math.maxInt(i32);
    var blocked = false;
    var radius: i32 = 0;
    while (radius <= request.search_radius and radius * radius <= best_distance) : (radius += 1) {
        var dy = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx = -radius;
            while (dx <= radius) : (dx += 1) {
                if (@max(@abs(dx), @abs(dy)) != radius) continue;
                const distance = dx * dx + dy * dy;
                if (distance >= best_distance) continue;
                const xy = [2]f64{ request.preferred_xy[0] + @as(f64, @floatFromInt(dx)), request.preferred_xy[1] + @as(f64, @floatFromInt(dy)) };
                const candidate = at(reader, request, xy) catch |err| switch (err) {
                    error.NoSurface => continue,
                    error.NoSpace => {
                        blocked = true;
                        continue;
                    },
                    else => return err,
                };
                best = candidate;
                best_distance = distance;
            }
        }
    }
    return best orelse if (blocked) error.NoSpace else error.NoSurface;
}

test "extra clearance cannot provide support outside the real contact footprint" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 1, 0, -1 }, .stone);
    const query: Request = .{ .preferred_xy = .{ 0.5, 0.5 }, .clearance_size = .{ 2, 2, 3 }, .support_size = .{ 0.6, 0.6 } };
    try std.testing.expectError(error.NoSurface, find(fixtureReader(&fixture.world), query));
    fixture.set(.{ 0, 0, -1 }, .stone);
    fixture.set(.{ 1, 0, 1 }, .stone);
    // Raising the feet onto the adjacent obstruction would leave them unsupported.
    try std.testing.expectError(error.NoSpace, find(fixtureReader(&fixture.world), query));
}

test "nearest surface search moves away from an obstruction in the spare volume" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    fixture.set(.{ 1, 0, 1 }, .stone);
    const query: Request = .{ .preferred_xy = .{ 0.5, 0.5 }, .clearance_size = .{ 2, 2, 3 }, .support_size = .{ 0.6, 0.6 }, .search_radius = 2 };
    const position = try find(fixtureReader(&fixture.world), query);
    try std.testing.expectEqual(Position{ -0.5, 0.5, 0 }, position);
    var contact: collision.Query = .{ .world = &fixture.world, .body = .{} };
    try std.testing.expectEqual(.clear, contact.overlap(position, true));
    try std.testing.expect(contact.moveAxis(position, 2, -collision.ground_probe).collided);
}

test "nearest means Euclidean distance rather than the first square search shell" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 3, 3, -1 }, .stone);
    fixture.set(.{ 4, 0, -1 }, .stone);
    try std.testing.expectEqual(Position{ 4.5, 0.5, 0 }, try find(fixtureReader(&fixture.world), .{
        .preferred_xy = .{ 0.5, 0.5 },
        .clearance_size = .{ 2, 2, 3 },
        .support_size = .{ 0.6, 0.6 },
        .search_radius = 4,
    }));
}

test "spare headroom and unknown clearance cells are checked beyond the actual body" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, 61 }, .stone);
    try std.testing.expectEqual(Position{ 0.5, 0.5, 62 }, try testFind(&fixture.world, .{}, .{ 0.5, 0.5 }));
    try std.testing.expectError(error.NoSpace, find(fixtureReader(&fixture.world), .{
        .preferred_xy = .{ 0.5, 0.5 },
        .clearance_size = .{ 2, 2, 3 },
        .support_size = .{ 0.6, 0.6 },
    }));
    fixture.set(.{ 31, 0, -1 }, .stone);
    fixture.world.removeChunk(.{ 3, 2, 2 });
    try std.testing.expectEqual(Position{ 31.5, 0.5, 0 }, try testFind(&fixture.world, .{}, .{ 31.5, 0.5 }));
    try std.testing.expectError(error.MissingData, find(fixtureReader(&fixture.world), .{
        .preferred_xy = .{ 31.5, 0.5 },
        .clearance_size = .{ 2, 2, 3 },
        .support_size = .{ 0.6, 0.6 },
    }));
}

const collision = @import("terrain_collision.zig");

fn fixtureRead(context: *anyopaque, block: [3]u32) ?engine.voxel_chunk.BlockType {
    const world: *const @import("world.zig").World = @ptrCast(@alignCast(context));
    const coords, const local = @import("world.zig").splitBlockCoords(block);
    const chunk = world.getChunk(coords) orelse return null;
    return chunk.content.getBlock(local);
}

fn fixtureReader(world: *const @import("world.zig").World) Reader {
    return .{ .layout = world.layout, .context = @constCast(world), .block_at = fixtureRead };
}

fn testFind(world: *const @import("world.zig").World, body: collision.Body, xy: [2]f64) Error!Position {
    return find(fixtureReader(world), .{
        .preferred_xy = xy,
        .clearance_size = .{ 2 * body.half_width, 2 * body.half_width, body.height },
        .support_size = .{ 2 * body.half_width, 2 * body.half_width },
    });
}

test "spawn follows added and removed blocks and starts standing without a fall" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.floor();
    const xy = [2]f64{ 0.5, 0.5 };
    try std.testing.expectEqual(Position{ 0.5, 0.5, 0 }, try testFind(&fixture.world, .{}, xy));
    fixture.set(.{ 0, 0, 12 }, .planks);
    const spawn = try testFind(&fixture.world, .{}, xy);
    try std.testing.expectEqual(Position{ 0.5, 0.5, 13 }, spawn);
    var player = @import("player_controller.zig").PlayerController.init(std.testing.allocator, spawn);
    defer player.deinit();
    _ = try player.update(&fixture.world, .{}, 1, 1);
    try std.testing.expectEqual(spawn, player.position);
    try std.testing.expect(player.grounded);
    try std.testing.expectEqual(@as(f64, 0), player.vertical_velocity);
    fixture.set(.{ 0, 0, 12 }, .none);
    fixture.set(.{ 0, 0, -1 }, .none);
    fixture.set(.{ 0, 0, -8 }, .stone);
    try std.testing.expectEqual(Position{ 0.5, 0.5, -7 }, try testFind(&fixture.world, .{}, xy));
}

test "spawn checks the whole footprint across horizontal and vertical chunk boundaries" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 31, 31, 3 }, .stone);
    // The centre cell is lower; the corner touched by the body is the support.
    fixture.set(.{ 32, 32, 31 }, .reinforced_concrete);
    const spawn = try testFind(&fixture.world, .{}, .{ 31.95, 31.95 });
    try std.testing.expectEqual(Position{ 31.95, 31.95, 32 }, spawn);
    var query: collision.Query = .{ .world = &fixture.world, .body = .{} };
    try std.testing.expectEqual(.clear, query.overlap(spawn, true));
    try std.testing.expect(query.moveAxis(spawn, 2, -collision.ground_probe).collided);
}

test "spawn and collision agree when the body only touches a taller neighboring block" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ 0, 0, 0 }, .stone);
    fixture.set(.{ 1, 0, 1 }, .stone);
    var query: collision.Query = .{ .world = &fixture.world, .body = .{} };
    for ([_]f64{ 0.7, 0.7 + collision.epsilon / 2 }) |x| {
        const spawn = try testFind(&fixture.world, .{}, .{ x, 0.5 });
        try std.testing.expectEqual(Position{ x, 0.5, 1 }, spawn);
        try std.testing.expectEqual(.clear, query.overlap(spawn, true));
        try std.testing.expect(query.moveAxis(spawn, 2, -collision.ground_probe).collided);
    }
    const x = 0.7 + 2 * collision.epsilon;
    try std.testing.expectEqual(.solid, query.overlap(.{ x, 0.5, 1 }, true));
    try std.testing.expectEqual(Position{ x, 0.5, 2 }, try testFind(&fixture.world, .{}, .{ x, 0.5 }));
}

test "spawn handles the wrapped x seam and preserves the requested world coordinates" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    fixture.set(.{ -65, 0, 8 }, .stone);
    fixture.set(.{ -64, 0, -1 }, .stone);
    try std.testing.expectEqual(Position{ -63.95, 0.5, 9 }, try testFind(&fixture.world, .{}, .{ -63.95, 0.5 }));
    try std.testing.expectEqual(Position{ 64.05, 0.5, 9 }, try testFind(&fixture.world, .{}, .{ 64.05, 0.5 }));
}

test "spawn requires known terrain, a real surface and room within the world" {
    var fixture = try @import("terrain_test_fixture.zig").Fixture.init();
    defer fixture.deinit();
    try std.testing.expectError(error.NoSurface, testFind(&fixture.world, .{}, .{ 0.5, 0.5 }));
    fixture.set(.{ 0, 0, 63 }, .stone);
    try std.testing.expectError(error.NoSpace, testFind(&fixture.world, .{}, .{ 0.5, 0.5 }));
    fixture.set(.{ 0, 0, 63 }, .none);
    fixture.set(.{ 0, 0, -1 }, .stone);
    fixture.world.removeChunk(.{ 2, 2, 3 });
    try std.testing.expectError(error.MissingData, testFind(&fixture.world, .{}, .{ 0.5, 0.5 }));
    try std.testing.expectError(error.NoSpace, testFind(&fixture.world, .{}, .{ 0.5, 63.95 }));
    try std.testing.expectError(error.InvalidSearch, testFind(&fixture.world, .{}, .{ std.math.nan(f64), 0.5 }));
}
