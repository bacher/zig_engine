//! Incremental road formation. A completed run owns its cells until it is broken.
const std = @import("std");
const engine = @import("engine");
const world = @import("world.zig");
const rules = @import("block_rules.zig");
const data = @import("road_data.zig");
const custom = engine.voxel_chunk.custom_block;
const Cell = rules.Cell;
pub const minimum_length: u32 = 4;
pub const maximum_length: u32 = 12;
pub const Undo = struct { block: [3]u32, slope: ?data.Slope };

pub const Context = struct {
    allocator: std.mem.Allocator,
    reader: rules.Reader,
    chunks: *world.ChunksHashMap,
    changed: *std.ArrayList(u32),
    undo: ?*std.ArrayList(Undo) = null,

    fn normalize(self: Context, cell: Cell) ?Cell {
        return self.reader.normalize(cell);
    }

    fn record(self: Context, cell: Cell) ?data.Road {
        const normalized = self.normalize(cell) orelse return null;
        const coords, const local = world.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
        const chunk = self.chunks.get(self.reader.layout.encodeChunkCoords(coords)) orelse return null;
        return chunk.metadata.road(@import("block_transformations.zig").index(local));
    }

    fn unformed(self: Context, cell: Cell) bool {
        const road = self.record(cell) orelse return false;
        return road.slope == null and self.reader.get(cell) == .custom;
    }

    fn supported(self: Context, cell: Cell) bool {
        const below = cell - Cell{ 0, 0, 1 };
        const material = self.reader.get(below) orelse return false;
        if (material == .none) return false;
        if (material == .custom) return if (self.record(below)) |road| road.slope == null else false;
        return true;
    }

    fn mark(self: Context, id: u32) void {
        if (std.mem.indexOfScalar(u32, self.changed.items, id) == null)
            self.changed.append(self.allocator, id) catch @panic("OOM");
    }

    fn set(self: Context, cell: Cell, slope: ?data.Slope) void {
        const normalized = self.normalize(cell) orelse return;
        const coords, const local = world.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
        const id = self.reader.layout.encodeChunkCoords(coords);
        const chunk = self.chunks.getPtr(id) orelse return;
        const road = chunk.metadata.roadPtr(@import("block_transformations.zig").index(local)) orelse return;
        if (std.meta.eql(road.slope, slope)) return;
        if (self.undo) |entries| {
            const block: [3]u32 = .{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) };
            var seen = false;
            for (entries.items) |entry| if (std.meta.eql(entry.block, block)) {
                seen = true;
                break;
            };
            if (!seen) entries.append(self.allocator, .{ .block = block, .slope = road.slope }) catch @panic("OOM");
        }
        road.slope = slope;
        self.mark(id);
    }

    fn sectionCell(self: Context, slope: data.Slope, section: u32) Cell {
        const high: Cell = .{ slope.high_endpoint[0], slope.high_endpoint[1], slope.high_endpoint[2] };
        return self.normalize(high + slope.downhill.offset() * @as(Cell, @splat(section + 1))).?;
    }

    fn lowEndpoint(self: Context, slope: data.Slope) Cell {
        return self.sectionCell(slope, slope.length) - Cell{ 0, 0, 1 };
    }

    fn revert(self: Context, slope: data.Slope) void {
        for (0..slope.length) |i| {
            const member = self.sectionCell(slope, @intCast(i));
            const road = self.record(member) orelse continue;
            const existing = road.slope orelse continue;
            if (sameRun(existing, slope)) self.set(member, null);
        }
    }

    /// Find both ends of an unclaimed straight row, without choosing ambiguous axes.
    fn candidate(self: Context, seed: Cell, axis: usize) ?data.Slope {
        if (!self.unformed(seed)) return null;
        var ends: [2]struct { cell: Cell, high: bool, count: u32 } = undefined;
        for (0..2) |side| {
            const sign: i64 = if (side == 0) -1 else 1;
            const step: Cell = if (axis == 0) .{ sign, 0, 0 } else .{ 0, sign, 0 };
            var cursor = seed;
            var count: u32 = 0;
            while (count <= maximum_length) : (count += 1) {
                cursor = self.normalize(cursor + step) orelse return null;
                const material = self.reader.get(cursor) orelse return null;
                if (self.unformed(cursor)) continue;
                if (material == .country_road_solid) {
                    ends[side] = .{ .cell = cursor, .high = true, .count = count };
                } else if (material == .none and self.reader.get(cursor - Cell{ 0, 0, 1 }) == .country_road_solid) {
                    ends[side] = .{ .cell = cursor - Cell{ 0, 0, 1 }, .high = false, .count = count };
                } else return null;
                break;
            } else return null;
        }
        if (ends[0].high == ends[1].high) return null;
        const n = ends[0].count + ends[1].count + 1;
        if (n < minimum_length or n > maximum_length) return null;
        const high = ends[if (ends[0].high) @as(usize, 0) else 1].cell;
        const direction: custom.Direction = if (axis == 0)
            (if (ends[0].high) .positive_x else .negative_x)
        else
            (if (ends[0].high) .positive_y else .negative_y);
        const result: data.Slope = .{ .high_endpoint = .{ @intCast(high[0]), @intCast(high[1]), @intCast(high[2]) }, .downhill = direction, .length = n, .section = 0 };
        for (0..n) |i| {
            const member = self.sectionCell(result, @intCast(i));
            if (!self.supported(member)) return null;
            // A formed section no longer supplies a full top face for a stacked road.
            const above = self.reader.get(member + Cell{ 0, 0, 1 }) orelse return null;
            if (above.isRoad()) return null;
        }
        return result;
    }

    fn ambiguous(self: Context, slope: data.Slope) bool {
        const other_axis: usize = if (@intFromEnum(slope.downhill) < 2) 1 else 0;
        for (0..slope.length) |i| if (self.candidate(self.sectionCell(slope, @intCast(i)), other_axis) != null) return true;
        return false;
    }

    /// previous preserves a removed section's ownership after its cell becomes air.
    pub fn afterEdit(self: Context, operation: world.BlockOperation, previous: ?data.Road) void {
        const target: Cell = .{ operation.block[0], operation.block[1], operation.block[2] };
        if (operation.action == .remove) {
            if (previous) |road| if (road.slope) |slope| self.revert(slope);
            for (std.enums.values(custom.Direction)) |direction| {
                for (0..2) |level| {
                    const neighbor = target + direction.offset() + Cell{ 0, 0, @intCast(level) };
                    const road = self.record(neighbor) orelse continue;
                    const slope = road.slope orelse continue;
                    const high: Cell = .{ slope.high_endpoint[0], slope.high_endpoint[1], slope.high_endpoint[2] };
                    if (@reduce(.And, target == high) or @reduce(.And, target == self.lowEndpoint(slope))) self.revert(slope);
                }
            }
            return;
        }
        var candidates: std.ArrayList(data.Slope) = .empty;
        defer candidates.deinit(self.allocator);
        for (0..2) |level| {
            for (0..5) |neighbor| {
                const seed = target + Cell{ 0, 0, @intCast(level) } + (if (neighbor == 4) @as(Cell, @splat(0)) else @as(custom.Direction, @enumFromInt(neighbor)).offset());
                for (0..2) |axis| {
                    const slope = self.candidate(seed, axis) orelse continue;
                    var seen = false;
                    for (candidates.items) |existing| if (sameRun(existing, slope)) {
                        seen = true;
                        break;
                    };
                    if (!seen) candidates.append(self.allocator, slope) catch @panic("OOM");
                }
            }
        }
        // Resolve all ambiguity before mutating anything; loop order cannot select a winner.
        var allowed: std.ArrayList(data.Slope) = .empty;
        defer allowed.deinit(self.allocator);
        for (candidates.items) |slope| if (!self.ambiguous(slope)) allowed.append(self.allocator, slope) catch @panic("OOM");
        for (allowed.items) |slope| for (0..slope.length) |i| {
            var section = slope;
            section.section = @intCast(i);
            self.set(self.sectionCell(slope, @intCast(i)), section);
        };
    }
};

fn sameRun(a: data.Slope, b: data.Slope) bool {
    return std.meta.eql(a.high_endpoint, b.high_endpoint) and a.downhill == b.downhill and a.length == b.length;
}

test {
    _ = @import("road_tests.zig");
}
