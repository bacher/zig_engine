//! Warehouse Q5 column order and Q2 count-only cargo layout. No item positions
//! are authoritative: every occupied cell is a prefix of this shared sequence.
const std = @import("std");

pub const Cell = [3]u32;
pub const Offset = [3]i8;
pub const Column = [2]i8;
pub const max_columns = 25;
pub const levels = 6;
pub const max_stock = max_columns * levels;
pub const chunk_size = 32;
pub const Error = error{ InvalidBounds, OutOfBounds, InvalidActiveCount, InvalidSlot };

pub const Bounds = struct {
    xmin: i8,
    xmax: i8,
    ymin: i8,
    ymax: i8,

    pub fn validate(self: Bounds) Error!void {
        const w = @as(i16, self.xmax) - self.xmin + 1;
        const h = @as(i16, self.ymax) - self.ymin + 1;
        if (w < 1 or w > 5 or h < 1 or h > 5) return error.InvalidBounds;
        // The fixed registration origin is a member of this first-version base.
        if (self.xmin > 0 or self.xmax < 0 or self.ymin > 0 or self.ymax < 0) return error.InvalidBounds;
    }

    pub fn width(self: Bounds) u8 {
        return @intCast(@as(i16, self.xmax) - self.xmin + 1);
    }

    pub fn height(self: Bounds) u8 {
        return @intCast(@as(i16, self.ymax) - self.ymin + 1);
    }

    pub fn count(self: Bounds) u8 {
        return self.width() * self.height();
    }

    pub fn contains(self: Bounds, column: Column) bool {
        return column[0] >= self.xmin and column[0] <= self.xmax and
            column[1] >= self.ymin and column[1] <= self.ymax;
    }

    pub fn depth(self: Bounds, column: Column) i8 {
        return @min(column[0] - self.xmin, self.xmax - column[0], column[1] - self.ymin, self.ymax - column[1]);
    }

    pub fn isCorner(self: Bounds, column: Column) bool {
        return (column[0] == self.xmin or column[0] == self.xmax) and
            (column[1] == self.ymin or column[1] == self.ymax);
    }
};

pub const Geometry = struct {
    origin: Cell,
    bounds: Bounds,

    /// The minimum is locally unwrapped through width/height; X may cross the seam.
    pub fn fromMinimum(world_size: Cell, minimum: Cell, size: [2]u8) Error!Geometry {
        if (size[0] == 0 or size[0] > 5 or size[1] == 0 or size[1] > 5 or
            world_size[0] < chunk_size or minimum[0] >= world_size[0] or
            minimum[1] >= world_size[1] or minimum[2] >= world_size[2]) return error.InvalidBounds;
        const dx: i8 = @intCast((size[0] - 1) / 2);
        const dy: i8 = @intCast((size[1] - 1) / 2);
        return .{
            .origin = .{ @intCast((@as(u64, minimum[0]) + @as(u8, @intCast(dx))) % world_size[0]), minimum[1] + @as(u8, @intCast(dy)), minimum[2] },
            .bounds = .{ .xmin = -dx, .xmax = @as(i8, @intCast(size[0] - 1)) - dx, .ymin = -dy, .ymax = @as(i8, @intCast(size[1] - 1)) - dy },
        };
    }

    /// Validate the full six-level envelope, plus a real support cell below.
    pub fn validate(self: Geometry, world_size: Cell) Error!void {
        try self.bounds.validate();
        // In-place expansion is deferred. Every first-version registration uses
        // the lower-coordinate central member as its fixed layout origin.
        if (self.bounds.xmin != -@as(i8, @intCast((self.bounds.width() - 1) / 2)) or
            self.bounds.ymin != -@as(i8, @intCast((self.bounds.height() - 1) / 2))) return error.InvalidBounds;
        if (world_size[0] < chunk_size or self.origin[0] >= world_size[0] or self.origin[1] >= world_size[1] or self.origin[2] >= world_size[2]) return error.OutOfBounds;
        if (self.worldCell(world_size, .{ self.bounds.xmin - 1, self.bounds.ymin - 1, -1 }) == null or
            self.worldCell(world_size, .{ self.bounds.xmax + 1, self.bounds.ymax + 1, levels - 1 }) == null) return error.OutOfBounds;
    }

    pub fn worldCell(self: Geometry, world_size: Cell, offset: Offset) ?Cell {
        if (world_size[0] == 0) return null;
        const y = @as(i64, self.origin[1]) + offset[1];
        const z = @as(i64, self.origin[2]) + offset[2];
        if (y < 0 or y >= world_size[1] or z < 0 or z >= world_size[2]) return null;
        return .{ @intCast(@mod(@as(i64, self.origin[0]) + offset[0], world_size[0])), @intCast(y), @intCast(z) };
    }

    /// A small local offset, or null when the cell is nowhere near this owner.
    pub fn relativeCell(self: Geometry, world_width: u32, cell: Cell) ?Offset {
        if (world_width < chunk_size) return null;
        var dx = @mod(@as(i64, cell[0]) - self.origin[0], world_width);
        if (dx > world_width / 2) dx -= world_width;
        const dy = @as(i64, cell[1]) - self.origin[1];
        const dz = @as(i64, cell[2]) - self.origin[2];
        if (dx < -127 or dx > 127 or dy < -127 or dy > 127 or dz < -127 or dz > 127) return null;
        return .{ @intCast(dx), @intCast(dy), @intCast(dz) };
    }

    pub fn containsBody(self: Geometry, offset: Offset) bool {
        return offset[2] >= 0 and offset[2] < levels and self.bounds.contains(.{ offset[0], offset[1] });
    }

    pub fn containsMember(self: Geometry, offset: Offset) bool {
        return offset[2] == 0 and self.bounds.contains(.{ offset[0], offset[1] });
    }

    pub fn containsEnvelope(self: Geometry, offset: Offset) bool {
        return offset[2] >= 0 and offset[2] < levels and
            offset[0] >= self.bounds.xmin - 1 and offset[0] <= self.bounds.xmax + 1 and
            offset[1] >= self.bounds.ymin - 1 and offset[1] <= self.bounds.ymax + 1;
    }

    /// Stable base-level side candidates. Traversability is a routing concern.
    pub fn courierCandidates(self: Geometry) Candidates {
        var result: Candidates = .{};
        var x = self.bounds.xmin;
        while (x <= self.bounds.xmax) : (x += 1) {
            result.append(.{ x, self.bounds.ymin - 1, 0 });
            result.append(.{ x, self.bounds.ymax + 1, 0 });
        }
        var y = self.bounds.ymin;
        while (y <= self.bounds.ymax) : (y += 1) {
            result.append(.{ self.bounds.xmin - 1, y, 0 });
            result.append(.{ self.bounds.xmax + 1, y, 0 });
        }
        return result;
    }
};

pub const Candidates = struct {
    cells: [20]Offset = undefined,
    count: u8 = 0,

    fn append(self: *Candidates, cell: Offset) void {
        self.cells[self.count] = cell;
        self.count += 1;
    }
};

/// Pinned arithmetic, independent of procedural world generation.
pub fn originHash(origin: Cell) u64 {
    const key: u64 = origin[0] % chunk_size + chunk_size * (origin[1] % chunk_size) + chunk_size * chunk_size * (origin[2] % chunk_size);
    var value = key +% 0x9e3779b97f4a7c15;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return value ^ (value >> 31);
}

const reference = [25]Column{
    .{ 0, 0 },  .{ 1, 0 },   .{ 0, 1 },   .{ 1, 1 },   .{ -1, 0 },
    .{ -1, 1 }, .{ 0, -1 },  .{ -1, -1 }, .{ 1, -1 },  .{ 2, 0 },
    .{ 2, -1 }, .{ 2, 1 },   .{ 0, 2 },   .{ -1, 2 },  .{ 1, 2 },
    .{ -2, 0 }, .{ -2, -1 }, .{ -2, 1 },  .{ 0, -2 },  .{ -1, -2 },
    .{ 1, -2 }, .{ 2, -2 },  .{ -2, 2 },  .{ -2, -2 }, .{ 2, 2 },
};

pub const Layout = struct {
    columns: [max_columns]Column = undefined,
    count: u8,

    pub fn init(geometry: Geometry) Layout {
        return withSelector(geometry.bounds, @truncate(originHash(geometry.origin)));
    }

    /// Explicit selectors are useful for exhaustive agreement tests, not state.
    pub fn withSelector(bounds: Bounds, selector: u4) Layout {
        std.debug.assert(bounds.width() <= 5 and bounds.height() <= 5);
        const cx = bounds.xmin + @as(i8, @intCast((bounds.width() - 1) / 2)) + @as(i8, if (bounds.width() % 2 == 0) @intCast((selector >> 2) & 1) else 0);
        const cy = bounds.ymin + @as(i8, @intCast((bounds.height() - 1) / 2)) + @as(i8, if (bounds.height() % 2 == 0) @intCast((selector >> 3) & 1) else 0);
        var filtered: [max_columns]Column = undefined;
        var count: u8 = 0;
        for (reference) |offset| {
            const rotated: Column = switch (selector & 3) {
                0 => .{ -offset[1], offset[0] },
                1 => offset,
                2 => .{ offset[1], -offset[0] },
                3 => .{ -offset[0], -offset[1] },
                else => unreachable,
            };
            const column: Column = .{ cx + rotated[0], cy + rotated[1] };
            if (!bounds.contains(column)) continue;
            filtered[count] = column;
            count += 1;
        }
        std.debug.assert(count == bounds.count());
        var result: Layout = .{ .count = count };
        result.columns[0] = .{ cx, cy };
        var next: u8 = 1;
        // Stable depth grouping, followed by actual-corner deferral.
        var depth: i8 = 2;
        while (depth >= 0) : (depth -= 1) {
            for (filtered[1..count]) |column| {
                if (bounds.depth(column) != depth or bounds.isCorner(column)) continue;
                result.columns[next] = column;
                next += 1;
            }
        }
        for (filtered[1..count]) |column| {
            if (!bounds.isCorner(column)) continue;
            result.columns[next] = column;
            next += 1;
        }
        std.debug.assert(next == count);
        return result;
    }

    pub fn slotAt(self: Layout, active: u8, index: u16) ?Offset {
        if (active > self.count or index >= @as(u16, self.count) * levels) return null;
        const active_slots = @as(u16, active) * levels;
        const first: u8 = if (index < active_slots) 0 else active;
        const count = if (index < active_slots) active else self.count - active;
        const local = if (index < active_slots) index else index - active_slots;
        const four_levels = @as(u16, count) * 4;
        const rank: u8 = @intCast(if (local < four_levels) local / 4 else (local - four_levels) % count);
        const z: i8 = @intCast(if (local < four_levels) local % 4 else 4 + (local - four_levels) / count);
        const column = self.columns[first + rank];
        return .{ column[0], column[1], z };
    }

    pub fn columnRank(self: Layout, column: Column) ?u8 {
        for (self.columns[0..self.count], 0..) |candidate, rank| {
            if (std.meta.eql(candidate, column)) return @intCast(rank);
        }
        return null;
    }

    pub fn slotIndex(self: Layout, active: u8, cell: Offset) ?u16 {
        if (active > self.count or cell[2] < 0 or cell[2] >= levels) return null;
        const rank = self.columnRank(.{ cell[0], cell[1] }) orelse return null;
        const first: u8 = if (rank < active) 0 else active;
        const count = if (rank < active) active else self.count - active;
        const local_rank: u16 = rank - first;
        const local = if (cell[2] < 4) local_rank * 4 + @as(u16, @intCast(cell[2])) else @as(u16, count) * @as(u16, @intCast(cell[2])) + local_rank;
        return @as(u16, first) * levels + local;
    }

    pub fn occupied(self: Layout, stock: u16, active: u8, cell: Offset) bool {
        return (self.slotIndex(active, cell) orelse return false) < stock;
    }

    pub fn columnHeight(self: Layout, stock: u16, active: u8, rank: u8) u8 {
        if (rank >= self.count or active > self.count) return 0;
        var height: u8 = 0;
        while (height < levels) : (height += 1) {
            const column = self.columns[rank];
            if (!self.occupied(stock, active, .{ column[0], column[1], @intCast(height) })) break;
        }
        return height;
    }
};

test "warehouse pinned hash fixtures and chunk-local repetition" {
    try std.testing.expectEqual(@as(u64, 0xe220a8397b1dcdaf), originHash(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0x910a2dec89025cc1), originHash(.{ 1, 0, 0 }));
    try std.testing.expectEqual(@as(u64, 0xb73ab1ecf2c9d038), originHash(.{ 31, 31, 31 }));
    try std.testing.expectEqual(originHash(.{ 31, 7, 3 }), originHash(.{ 127, 71, 35 }));
}

test "warehouse every footprint and selector has unique inner-first late-corner columns" {
    for (1..6) |width| for (1..6) |height| for (0..16) |selector| {
        const bounds: Bounds = .{ .xmin = 0, .xmax = @intCast(width - 1), .ymin = 0, .ymax = @intCast(height - 1) };
        const order = Layout.withSelector(bounds, @intCast(selector));
        try std.testing.expectEqual(width * height, order.count);
        var seen: [5][5]bool = @splat(@splat(false));
        var previous_depth: i8 = 3;
        var corners = false;
        for (order.columns[0..order.count], 0..) |column, rank| {
            const x: usize = @intCast(column[0]);
            const y: usize = @intCast(column[1]);
            try std.testing.expect(!seen[y][x]);
            seen[y][x] = true;
            const depth = bounds.depth(column);
            try std.testing.expect(depth <= previous_depth);
            previous_depth = depth;
            if (rank == 0) continue;
            if (bounds.isCorner(column)) corners = true else try std.testing.expect(!corners);
        }
        if (width == 4 and height == 4) for (order.columns[0..4]) |column| {
            try std.testing.expect(column[0] >= 1 and column[0] <= 2 and column[1] >= 1 and column[1] <= 2);
        };
        for (0..order.count + 1) |active| {
            var occupied: [5][5][levels]bool = @splat(@splat(@splat(false)));
            for (0..@as(usize, order.count) * levels) |index| {
                const slot = order.slotAt(@intCast(active), @intCast(index)).?;
                try std.testing.expectEqual(@as(u16, @intCast(index)), order.slotIndex(@intCast(active), slot).?);
                const x: usize = @intCast(slot[0]);
                const y: usize = @intCast(slot[1]);
                const z: usize = @intCast(slot[2]);
                try std.testing.expect(!occupied[y][x][z]);
                if (z > 0) try std.testing.expect(occupied[y][x][z - 1]);
                occupied[y][x][z] = true;
                const rank = order.columnRank(.{ slot[0], slot[1] }).?;
                try std.testing.expectEqual(index >= active * levels, rank >= active);
            }
        }
    };
}

test "warehouse east-facing 5x5 order is the reference" {
    const order = Layout.withSelector(.{ .xmin = -2, .xmax = 2, .ymin = -2, .ymax = 2 }, 1);
    try std.testing.expectEqualDeep(reference, order.columns);
}

test "warehouse reduced active packing follows the N9 example" {
    const order = Layout.withSelector(.{ .xmin = -1, .xmax = 1, .ymin = -1, .ymax = 1 }, 1);
    for (0..9) |rank| try std.testing.expectEqual(@as(u8, if (rank < 4) 5 else 0), order.columnHeight(20, 4, @intCast(rank)));
    for (0..9) |rank| try std.testing.expectEqual(@as(u8, if (rank < 4) 6 else if (rank == 4) 4 else 0), order.columnHeight(28, 4, @intCast(rank)));
}

test "warehouse seam geometry and base-level courier halo" {
    const size: Cell = .{ 128, 128, 128 };
    const geometry = try Geometry.fromMinimum(size, .{ 127, 20, 31 }, .{ 4, 3 });
    try geometry.validate(size);
    try std.testing.expectEqualDeep(@as(Cell, .{ 0, 21, 31 }), geometry.origin);
    try std.testing.expectEqualDeep(@as(Offset, .{ -1, -1, 0 }), geometry.relativeCell(size[0], .{ 127, 20, 31 }).?);
    try std.testing.expectEqualDeep(@as(Cell, .{ 127, 20, 31 }), geometry.worldCell(size, .{ -1, -1, 0 }).?);
    const candidates = geometry.courierCandidates();
    try std.testing.expectEqual(@as(u8, 14), candidates.count);
    for (candidates.cells[0..candidates.count]) |offset| {
        try std.testing.expect(geometry.containsEnvelope(offset));
        try std.testing.expect(!geometry.containsBody(offset));
        try std.testing.expectEqual(@as(i8, 0), offset[2]);
        try std.testing.expect(!((offset[0] < geometry.bounds.xmin or offset[0] > geometry.bounds.xmax) and (offset[1] < geometry.bounds.ymin or offset[1] > geometry.bounds.ymax)));
    }
}
