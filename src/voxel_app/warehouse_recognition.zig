//! Bounded whole-component pallet recognition. Floor and clearance admission
//! remain separate composed-world checks performed at authoritative confirmation.
const std = @import("std");
const layout = @import("warehouse_layout.zig");
pub const Cell = layout.Cell;
pub const Error = error{ MissingData, NotPallet, NonRectangular, Oversized, OutOfBounds } || layout.Error;

pub const Reader = struct {
    context: *const anyopaque,
    /// null means unknown; it cannot prove the edge of a component.
    pallet: *const fn (*const anyopaque, Cell) ?bool,
};

pub fn recognize(world_size: Cell, clicked: Cell, reader: Reader) Error!layout.Geometry {
    if (world_size[0] < layout.chunk_size or clicked[0] >= world_size[0] or clicked[1] >= world_size[1] or clicked[2] >= world_size[2]) return error.OutOfBounds;
    if (!(reader.pallet(reader.context, clicked) orelse return error.MissingData)) return error.NotPallet;
    var members: [layout.max_columns]layout.Column = undefined;
    members[0] = .{ 0, 0 };
    var count: u8 = 1;
    var cursor: u8 = 0;
    var min: layout.Column = .{ 0, 0 };
    var max: layout.Column = .{ 0, 0 };
    const directions = [4]layout.Column{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    while (cursor < count) : (cursor += 1) {
        const current = members[cursor];
        for (directions) |direction| {
            const offset: layout.Column = .{ current[0] + direction[0], current[1] + direction[1] };
            var seen = false;
            for (members[0..count]) |member| if (std.meta.eql(member, offset)) {
                seen = true;
                break;
            };
            if (seen) continue;
            const y = @as(i64, clicked[1]) + offset[1];
            // The finite storage boundary contains no pallet. Full clearance is
            // checked separately and will reject a footprint against this edge.
            if (y < 0 or y >= world_size[1]) continue;
            const cell: Cell = .{ @intCast(@mod(@as(i64, clicked[0]) + offset[0], world_size[0])), @intCast(y), clicked[2] };
            if (!(reader.pallet(reader.context, cell) orelse return error.MissingData)) continue;
            min = .{ @min(min[0], offset[0]), @min(min[1], offset[1]) };
            max = .{ @max(max[0], offset[0]), @max(max[1], offset[1]) };
            if (max[0] - min[0] >= 5 or max[1] - min[1] >= 5 or count == layout.max_columns) return error.Oversized;
            members[count] = offset;
            count += 1;
        }
    }
    const width: u8 = @intCast(max[0] - min[0] + 1);
    const height: u8 = @intCast(max[1] - min[1] + 1);
    if (count != width * height) return error.NonRectangular;
    const minimum: Cell = .{ @intCast(@mod(@as(i64, clicked[0]) + min[0], world_size[0])), @intCast(@as(i64, clicked[1]) + min[1]), clicked[2] };
    return try layout.Geometry.fromMinimum(world_size, minimum, .{ width, height });
}

const Fixture = struct {
    cells: []const Cell,
    unknown: ?Cell = null,

    fn read(context: *const anyopaque, cell: Cell) ?bool {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (self.unknown) |unknown| if (std.meta.eql(cell, unknown)) return null;
        for (self.cells) |member| if (std.meta.eql(member, cell)) return true;
        return false;
    }

    fn reader(self: *const Fixture) Reader {
        return .{ .context = self, .pallet = read };
    }
};

test "warehouse recognizes whole wrapped rectangle independent of clicked member" {
    const size: Cell = .{ 128, 128, 128 };
    const fixture: Fixture = .{ .cells = &.{ .{ 127, 20, 12 }, .{ 0, 20, 12 }, .{ 1, 20, 12 }, .{ 127, 21, 12 }, .{ 0, 21, 12 }, .{ 1, 21, 12 } } };
    const expected = try layout.Geometry.fromMinimum(size, .{ 127, 20, 12 }, .{ 3, 2 });
    for (fixture.cells) |clicked| try std.testing.expectEqualDeep(expected, try recognize(size, clicked, fixture.reader()));
}

test "warehouse rejects holes oversized components and unknown boundaries" {
    const size: Cell = .{ 128, 128, 128 };
    const hole: Fixture = .{ .cells = &.{ .{ 10, 10, 10 }, .{ 11, 10, 10 }, .{ 10, 11, 10 } } };
    try std.testing.expectError(error.NonRectangular, recognize(size, hole.cells[0], hole.reader()));
    const oversized: Fixture = .{ .cells = &.{ .{ 10, 10, 10 }, .{ 11, 10, 10 }, .{ 12, 10, 10 }, .{ 13, 10, 10 }, .{ 14, 10, 10 }, .{ 15, 10, 10 } } };
    try std.testing.expectError(error.Oversized, recognize(size, oversized.cells[0], oversized.reader()));
    const unknown: Fixture = .{ .cells = &.{.{ 10, 10, 10 }}, .unknown = .{ 11, 10, 10 } };
    try std.testing.expectError(error.MissingData, recognize(size, unknown.cells[0], unknown.reader()));
    const diagonal: Fixture = .{ .cells = &.{ .{ 10, 10, 10 }, .{ 11, 11, 10 } } };
    try std.testing.expectEqual(@as(u8, 1), (try recognize(size, diagonal.cells[0], diagonal.reader())).bounds.count());
}
