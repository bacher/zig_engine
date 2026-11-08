//! Detached Apply reads for new targets and their physical platform. The whole
//! rotated box is included, so its publication index sources survive cavities.
const std = @import("std");
const engine = @import("engine");
const blueprint = @import("blueprint.zig");
const runtime = @import("blueprint_runtime.zig");
const rules = @import("block_rules.zig");
const consts = @import("consts.zig");
const ChunkId = consts.ChunkId;

/// Support reads stay within XY +/-28 and Z [-28, 0] of each new target.
/// This also contains the three-deep, one-cell-dilated bottom platform and every
/// whole-box publication source, including chunks with no new target cells.
pub fn chunks(allocator: std.mem.Allocator, layout: *const engine.WorldLayout, origin: runtime.Cell, definition_size: blueprint.Size, rotation: u2, max_chunks: usize) ![]ChunkId {
    if (!runtime.validFootprint(layout, origin, definition_size, rotation)) return error.InvalidFootprint;
    const size = blueprint.rotatedSize(definition_size, rotation);
    const radius = rules.Limits.support_radius;
    var result: std.ArrayList(ChunkId) = .empty;
    errdefer result.deinit(allocator);
    var unique: std.AutoHashMapUnmanaged(ChunkId, void) = .empty;
    defer unique.deinit(allocator);
    var z = @divFloor(@as(i64, origin[2]) - radius, consts.CHUNK_SIZE);
    while (z <= @divFloor(@as(i64, origin[2]) + size[2] - 1, consts.CHUNK_SIZE)) : (z += 1) {
        var y = @divFloor(@as(i64, origin[1]) - radius, consts.CHUNK_SIZE);
        while (y <= @divFloor(@as(i64, origin[1]) + size[1] - 1 + radius, consts.CHUNK_SIZE)) : (y += 1) {
            var x = @divFloor(@as(i64, origin[0]) - radius, consts.CHUNK_SIZE);
            while (x <= @divFloor(@as(i64, origin[0]) + size[0] - 1 + radius, consts.CHUNK_SIZE)) : (x += 1) {
                const coords = layout.normalizeChunkCoords(.{ @intCast(x), @intCast(y), @intCast(z) }) orelse continue;
                const id = layout.encodeChunkCoords(coords);
                if (unique.contains(id)) continue;
                if (result.items.len == max_chunks) return error.Capacity;
                try unique.put(allocator, id, {});
                try result.append(allocator, id);
            }
        }
    }
    return result.toOwnedSlice(allocator);
}

fn expectCoordinates(layout: *const engine.WorldLayout, actual: []const ChunkId, xs: []const i32, ys: []const i32, zs: []const i32) !void {
    try std.testing.expectEqual(xs.len * ys.len * zs.len, actual.len);
    var unique: std.AutoHashMapUnmanaged(ChunkId, void) = .empty;
    defer unique.deinit(std.testing.allocator);
    for (actual) |id| {
        try std.testing.expect(!unique.contains(id));
        try unique.put(std.testing.allocator, id, {});
        const coords = layout.decodeChunkId(id);
        try std.testing.expect(std.mem.indexOfScalar(i32, xs, coords[0]) != null);
        try std.testing.expect(std.mem.indexOfScalar(i32, ys, coords[1]) != null);
        try std.testing.expect(std.mem.indexOfScalar(i32, zs, coords[2]) != null);
    }
}

test "Apply dependencies use exact rotated whole-box support chunk coverage" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    for (0..4) |turn| {
        const ids = try chunks(std.testing.allocator, &layout, .{ 60, 95, 64 }, .{ 1, 34, 33 }, @intCast(turn), 1024);
        defer std.testing.allocator.free(ids);
        // Even turns: X[32,88], Y[67,156]. Odd turns: X[32,121], Y[67,123].
        // Both: Z[36,96], including the top cell's chunk without an upper halo.
        try expectCoordinates(&layout, ids, if (turn & 1 == 0) &.{ 1, 2 } else &.{ 1, 2, 3 }, if (turn & 1 == 0) &.{ 2, 3, 4 } else &.{ 2, 3 }, &.{ 1, 2, 3 });
    }
}

test "Apply dependencies include boundary cells and stop at the box top" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    const Case = struct { origin: runtime.Cell, size: blueprint.Size, xs: []const i32, ys: []const i32, zs: []const i32 };
    for ([_]Case{
        .{ .origin = .{ 60, 60, 60 }, .size = .{ 1, 1, 4 }, .xs = &.{ 1, 2 }, .ys = &.{ 1, 2 }, .zs = &.{1} }, // Low halo = 32; box top = 63.
        .{ .origin = .{ 59, 59, 59 }, .size = .{ 1, 1, 6 }, .xs = &.{ 0, 1, 2 }, .ys = &.{ 0, 1, 2 }, .zs = &.{ 0, 1, 2 } }, // Low halo = 31; box top = 64.
        .{ .origin = .{ 35, 35, 60 }, .size = .{ 1, 1, 1 }, .xs = &.{ 0, 1 }, .ys = &.{ 0, 1 }, .zs = &.{1} }, // High halo = 63.
        .{ .origin = .{ 36, 36, 60 }, .size = .{ 1, 1, 1 }, .xs = &.{ 0, 1, 2 }, .ys = &.{ 0, 1, 2 }, .zs = &.{1} }, // High halo = 64.
    }) |case| {
        const ids = try chunks(std.testing.allocator, &layout, case.origin, case.size, 0, 1024);
        defer std.testing.allocator.free(ids);
        try expectCoordinates(&layout, ids, case.xs, case.ys, case.zs);
    }
}

test "Apply dependencies clip finite Y and Z and normalize wrapped X seams" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 4, 4, 4 } });
    const low = try chunks(std.testing.allocator, &layout, .{ 0, 0, 0 }, .{ 1, 1, 1 }, 0, 1024);
    defer std.testing.allocator.free(low);
    try expectCoordinates(&layout, low, if (engine.WorldLayout.wrap_x) &.{ 3, 0 } else &.{0}, &.{0}, &.{0});
    const high = try chunks(std.testing.allocator, &layout, .{ 127, 127, 127 }, .{ 1, 1, 1 }, 0, 1024);
    defer std.testing.allocator.free(high);
    try expectCoordinates(&layout, high, if (engine.WorldLayout.wrap_x) &.{ 3, 0 } else &.{3}, &.{3}, &.{3});
    const seam = try chunks(std.testing.allocator, &layout, .{ 120, 60, 64 }, .{ 16, 1, 1 }, 0, 1024);
    defer std.testing.allocator.free(seam);
    try expectCoordinates(&layout, seam, if (engine.WorldLayout.wrap_x) &.{ 2, 3, 0, 1 } else &.{ 2, 3 }, &.{ 1, 2 }, &.{ 1, 2 });
}

test "Apply dependency cap counts canonical chunks after wrap deduplication" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    // X[-12,68] crosses both seams in the 64-cell world. Chunks -1 and 1
    // canonicalize to the same source; chunk 2 repeats chunk 0.
    const ids = try chunks(std.testing.allocator, &layout, .{ 16, 16, 32 }, .{ 25, 1, 1 }, 0, 8);
    defer std.testing.allocator.free(ids);
    try expectCoordinates(&layout, ids, &.{ 0, 1 }, &.{ 0, 1 }, &.{ 0, 1 });
    try std.testing.expectError(error.Capacity, chunks(std.testing.allocator, &layout, .{ 16, 16, 32 }, .{ 25, 1, 1 }, 0, 7));
    try std.testing.expectError(error.Capacity, chunks(std.testing.allocator, &layout, .{ 16, 16, 32 }, .{ 25, 1, 1 }, 0, 0));
}

test "Apply dependencies contain whole-box cavity sources and the full physical platform" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } });
    for (0..4) |turn| {
        const origin: runtime.Cell = .{ 252, 31, 64 };
        const size: blueprint.Size = .{ 5, 67, 34 };
        const rotation: u2 = @intCast(turn);
        const ids = try chunks(std.testing.allocator, &layout, origin, size, rotation, 1024);
        defer std.testing.allocator.free(ids);
        const sources = try runtime.boxChunks(std.testing.allocator, &layout, origin, size, rotation);
        defer std.testing.allocator.free(sources);
        // A compact definition may have targets only at opposite corners; all
        // interior cavity chunk indexes must still be available to publication.
        for (sources) |id| try std.testing.expect(std.mem.indexOfScalar(ChunkId, ids, id) != null);
        const rotated = blueprint.rotatedSize(size, rotation);
        for (0..rotated[1]) |y| for (0..rotated[0]) |x| {
            for (0..3) |dy| for (0..3) |dx| for (1..4) |depth| {
                const cell = rules.Cell{ @as(i64, origin[0]) + @as(i64, @intCast(x)) + @as(i64, @intCast(dx)) - 1, @as(i64, origin[1]) + @as(i64, @intCast(y)) + @as(i64, @intCast(dy)) - 1, @as(i64, origin[2]) - @as(i64, @intCast(depth)) };
                const coords = layout.normalizeChunkCoords(.{ @intCast(@divFloor(cell[0], consts.CHUNK_SIZE)), @intCast(@divFloor(cell[1], consts.CHUNK_SIZE)), @intCast(@divFloor(cell[2], consts.CHUNK_SIZE)) }) orelse continue;
                try std.testing.expect(std.mem.indexOfScalar(ChunkId, ids, layout.encodeChunkCoords(coords)) != null);
            };
        };
    }
}
