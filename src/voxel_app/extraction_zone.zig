//! Canonical inclusive selection geometry and extraction filters shared by preview and authority.
const std = @import("std");
const engine = @import("engine");
const capture = @import("blueprint_capture.zig");
const chunk_size = engine.chunk_utils.CHUNK_SIZE;

pub const Cell = [3]u32;
pub const Budgets = capture.Budgets;
pub const BoundsError = error{ InvalidBounds, CellBudget, ChunkBudget, Overflow };

pub const Filter = packed struct(u8) {
    soil: bool = true,
    sand: bool = true,
    stone: bool = true,
    metal_ore: bool = true,
    limestone: bool = true,
    coal: bool = true,
    clay: bool = true,
    reserved: u1 = 0,

    pub fn any(self: Filter) bool {
        return self.soil or self.sand or self.stone or self.metal_ore or self.limestone or self.coal or self.clay;
    }

    pub fn valid(self: Filter) bool {
        return self.reserved == 0 and self.any();
    }

    pub fn matches(self: Filter, material: engine.voxel_chunk.BlockType) bool {
        return switch (material) {
            .dirt, .grass => self.soil,
            .sand => self.sand,
            .stone => self.stone,
            .metal_ore => self.metal_ore,
            .limestone => self.limestone,
            .coal => self.coal,
            .clay => self.clay,
            else => false,
        };
    }
};

pub const Bounds = struct {
    /// X starts in canonical storage coordinates and advances through the seam.
    /// Each size counts both selected endpoints. Y and Z are finite.
    min: Cell,
    size: Cell,

    pub fn fromFootprint(world_size: Cell, anchor: Cell, endpoint_x: i64, endpoint_y: i64, depth: u32) error{ InvalidBounds, AmbiguousX }!Bounds {
        if (world_size[0] < 2 or depth == 0 or endpoint_y < 0 or endpoint_y >= world_size[1]) return error.InvalidBounds;
        for (anchor, world_size) |coordinate, limit| if (coordinate >= limit) return error.InvalidBounds;

        const width: i64 = world_size[0];
        const wrapped = @mod(@mod(endpoint_x, width) - @as(i64, anchor[0]), width);
        if (wrapped * 2 == width) return error.AmbiguousX;
        const dx = if (wrapped * 2 > width) wrapped - width else wrapped;
        const y: u32 = @intCast(endpoint_y);
        const layers = @min(depth, anchor[2] + 1);
        return .{
            .min = .{ @intCast(@mod(@as(i64, anchor[0]) + @min(0, dx), width)), @min(anchor[1], y), anchor[2] + 1 - layers },
            .size = .{ @intCast(@abs(dx) + 1), @max(anchor[1], y) - @min(anchor[1], y) + 1, layers },
        };
    }

    pub fn volume(self: Bounds) error{Overflow}!usize {
        return std.math.mul(usize, try std.math.mul(usize, self.size[0], self.size[1]), self.size[2]);
    }

    pub fn validate(self: Bounds, world_size: Cell, budgets: Budgets) BoundsError!void {
        for (world_size, self.min, self.size) |limit, start, length| {
            if (limit == 0 or limit % chunk_size != 0 or start >= limit or length == 0) return error.InvalidBounds;
        }
        if (self.size[0] > world_size[0] / 2 or self.size[1] > world_size[1] - self.min[1] or self.size[2] > world_size[2] - self.min[2]) return error.InvalidBounds;
        if (try self.volume() > budgets.max_cells) return error.CellBudget;
        const counts = self.chunks(world_size).counts;
        const chunk_count = try std.math.mul(usize, try std.math.mul(usize, counts[0], counts[1]), counts[2]);
        if (chunk_count > budgets.max_source_chunks) return error.ChunkBudget;
    }

    pub fn contains(self: Bounds, world_width: u32, cell: Cell) bool {
        return cell[0] < world_width and self.containsX(world_width, cell[0]) and
            cell[1] >= self.min[1] and cell[1] - self.min[1] < self.size[1] and
            cell[2] >= self.min[2] and cell[2] - self.min[2] < self.size[2];
    }

    fn containsX(self: Bounds, world_width: u32, x: u32) bool {
        return @mod(@as(i64, x) - self.min[0], world_width) < self.size[0];
    }

    /// Both boxes use normalized X and positive extents on every axis.
    pub fn intersects(self: Bounds, world_width: u32, other: Bounds) bool {
        for (1..3) |axis| {
            if (@as(u64, self.min[axis]) + self.size[axis] <= other.min[axis] or
                @as(u64, other.min[axis]) + other.size[axis] <= self.min[axis]) return false;
        }
        return self.containsX(world_width, other.min[0]) or other.containsX(world_width, self.min[0]);
    }

    pub fn chunks(self: Bounds, world_size: Cell) ChunkIterator {
        var start: Cell = undefined;
        var counts: Cell = undefined;
        for (self.min, self.size, 0..) |minimum, length, axis| {
            start[axis] = minimum / chunk_size;
            const last: u64 = @as(u64, minimum) + length - 1;
            counts[axis] = @intCast(last / chunk_size - start[axis] + 1);
        }
        const period = world_size[0] / chunk_size;
        counts[0] = @min(counts[0], period);
        return .{ .start = start, .counts = counts, .x_period = period };
    }

    pub fn cells(self: Bounds, world_width: u32) CellIterator {
        return .{ .bounds = self, .world_width = world_width };
    }
};

pub const CellIterator = struct {
    bounds: Bounds,
    world_width: u32,
    offset: Cell = .{ 0, 0, 0 },

    pub fn next(self: *CellIterator) ?Cell {
        if (self.offset[2] == self.bounds.size[2]) return null;
        const minimum = self.bounds.min;
        const cell: Cell = .{
            @intCast((@as(u64, minimum[0]) + self.offset[0]) % self.world_width),
            minimum[1] + self.offset[1],
            minimum[2] + self.offset[2],
        };
        self.offset[0] += 1;
        if (self.offset[0] == self.bounds.size[0]) {
            self.offset[0] = 0;
            self.offset[1] += 1;
            if (self.offset[1] == self.bounds.size[1]) {
                self.offset[1] = 0;
                self.offset[2] += 1;
            }
        }
        return cell;
    }
};

pub const ChunkIterator = struct {
    start: Cell,
    counts: Cell,
    x_period: u32,
    offset: Cell = .{ 0, 0, 0 },

    pub fn next(self: *ChunkIterator) ?Cell {
        if (self.offset[2] == self.counts[2]) return null;
        const coords: Cell = .{
            (self.start[0] + self.offset[0]) % self.x_period,
            self.start[1] + self.offset[1],
            self.start[2] + self.offset[2],
        };
        self.offset[0] += 1;
        if (self.offset[0] == self.counts[0]) {
            self.offset[0] = 0;
            self.offset[1] += 1;
            if (self.offset[1] == self.counts[1]) {
                self.offset[1] = 0;
                self.offset[2] += 1;
            }
        }
        return coords;
    }
};

test "extraction bounds use the same two seam columns for selection and claims" {
    const size: Cell = .{ 128, 128, 128 };
    const bounds = try Bounds.fromFootprint(size, .{ 127, 4, 8 }, 0, 3, 40);
    try std.testing.expectEqualDeep(Bounds{ .min = .{ 127, 3, 0 }, .size = .{ 2, 2, 9 } }, bounds);
    try std.testing.expectEqualDeep(bounds, try Bounds.fromFootprint(size, .{ 0, 3, 8 }, 127, 4, 40));
    try std.testing.expect(bounds.contains(128, .{ 127, 3, 0 }));
    try std.testing.expect(bounds.contains(128, .{ 0, 4, 8 }));
    try std.testing.expect(!bounds.intersects(128, .{ .min = .{ 1, 3, 0 }, .size = .{ 1, 2, 9 } }));
    try std.testing.expect(bounds.intersects(128, .{ .min = .{ 0, 3, 0 }, .size = .{ 1, 2, 9 } }));
    try std.testing.expectError(error.AmbiguousX, Bounds.fromFootprint(size, .{ 127, 4, 8 }, 63, 3, 1));
}

test "extraction budgets use inclusive volume and distinct aligned chunks independently" {
    const size: Cell = .{ 128, 128, 128 };
    const bounds: Bounds = .{ .min = .{ 127, 31, 31 }, .size = .{ 2, 2, 2 } };
    try bounds.validate(size, .{ .max_cells = 8, .max_source_chunks = 8 });
    try std.testing.expectError(error.CellBudget, bounds.validate(size, .{ .max_cells = 7, .max_source_chunks = 8 }));
    try std.testing.expectError(error.ChunkBudget, bounds.validate(size, .{ .max_cells = 8, .max_source_chunks = 7 }));
    var chunks = bounds.chunks(size);
    for (0..8) |i| {
        try std.testing.expectEqual(Cell{ if (i % 2 == 0) 3 else 0, @intCast(i / 2 % 2), @intCast(i / 4) }, chunks.next().?);
    }
    try std.testing.expectEqual(null, chunks.next());
    const huge: Bounds = .{ .min = .{ 0, 0, 0 }, .size = .{ 1 << 30, 1 << 30, 1 << 30 } };
    try std.testing.expectError(error.Overflow, huge.validate(.{ 1 << 31, 1 << 30, 1 << 30 }, .{}));
}
