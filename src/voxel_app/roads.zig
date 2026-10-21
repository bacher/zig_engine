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
const Change = struct { cell: Cell, slope: ?data.Slope };
pub const Plan = struct {
    changes: []Change,
    chunk_ids: []u32,
    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.changes);
        allocator.free(self.chunk_ids);
        self.* = undefined;
    }
    pub fn reserveCommit(self: Plan, context: Context) !void {
        try context.changed.ensureUnusedCapacity(context.allocator, self.chunk_ids.len);
    }
    pub fn applyPrepared(self: Plan, context: Context) void {
        std.debug.assert(context.undo == null and context.formed == null);
        var commit = context;
        commit.prepared = true;
        commit.virtual_edit = null;
        for (self.changes) |change| commit.set(change.cell, change.slope);
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    reader: rules.Reader,
    chunks: *world.ChunksHashMap,
    changed: *std.ArrayList(u32),
    undo: ?*std.ArrayList(Undo) = null,
    formed: ?*std.ArrayList(data.Slope) = null,
    planned: ?*std.ArrayList(Change) = null,
    planning_failure: ?*?anyerror = null,
    prepared: bool = false,
    virtual_edit: ?world.BlockOperation = null,
    max_plan_changes: usize = std.math.maxInt(usize),

    /// Discover the complete section-change footprint before reserving and
    /// applying it. Authoritative callers do not request optimistic undo data.
    /// Includes members absent from the current resident map, so callers can
    /// load/gate a persisted formation before computing its exact mutation plan.
    pub fn appendRunChunkIds(self: Context, slope: data.Slope, ids: *std.ArrayList(u32)) !void {
        for (0..self.memberLimit(slope)) |section| {
            const cell = self.normalize(self.sectionCell(slope, @intCast(section))) orelse continue;
            const coords, _ = world.splitBlockCoords(.{ @intCast(cell[0]), @intCast(cell[1]), @intCast(cell[2]) });
            const id = self.reader.layout.encodeChunkCoords(coords);
            if (std.mem.indexOfScalar(u32, ids.items, id) == null) {
                if (ids.items.len >= self.max_plan_changes) return error.Capacity;
                try ids.append(self.allocator, id);
            }
        }
    }

    pub fn planAfterEdit(self: Context, operation: world.BlockOperation, previous: ?data.Road) !Plan {
        return self.planReplay(operation, previous, &.{});
    }

    pub fn planReplay(self: Context, operation: world.BlockOperation, previous: ?data.Road, formations: []const data.Slope) !Plan {
        std.debug.assert(self.undo == null and self.formed == null);
        var changes: std.ArrayList(Change) = .empty;
        errdefer changes.deinit(self.allocator);
        var failure: ?anyerror = null;
        var planner = self;
        planner.planned = &changes;
        planner.planning_failure = &failure;
        for (formations) |formation| planner.restoreFormation(formation);
        planner.afterEdit(operation, previous);
        if (failure) |err| return err;
        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(self.allocator);
        for (changes.items) |change| {
            const coords, _ = world.splitBlockCoords(.{ @intCast(change.cell[0]), @intCast(change.cell[1]), @intCast(change.cell[2]) });
            const id = self.reader.layout.encodeChunkCoords(coords);
            if (std.mem.indexOfScalar(u32, ids.items, id) == null) try ids.append(self.allocator, id);
        }
        const owned_changes = try changes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_changes);
        return .{ .changes = owned_changes, .chunk_ids = try ids.toOwnedSlice(self.allocator) };
    }

    pub fn tryAfterEdit(self: Context, operation: world.BlockOperation, previous: ?data.Road) !void {
        var plan = try self.planAfterEdit(operation, previous);
        defer plan.deinit(self.allocator);
        try plan.reserveCommit(self);
        plan.applyPrepared(self);
    }

    fn normalize(self: Context, cell: Cell) ?Cell {
        return self.reader.normalize(cell);
    }

    fn readMaterial(self: Context, cell: Cell) ?engine.voxel_chunk.BlockType {
        const normalized = self.normalize(cell) orelse return null;
        if (self.virtual_edit) |edit| {
            if (@reduce(.And, normalized == Cell{ edit.block[0], edit.block[1], edit.block[2] })) return switch (edit.action) {
                .remove => .none,
                .put => |value| if (value == .country_road_adaptive) .custom else value,
            };
        }
        return self.reader.get(normalized);
    }

    fn record(self: Context, cell: Cell) ?data.Road {
        const normalized = self.normalize(cell) orelse return null;
        if (self.planned) |changes| {
            for (changes.items) |change| if (@reduce(.And, change.cell == normalized)) {
                const coords, const local = world.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
                _ = coords;
                return .{ .index = @import("block_transformations.zig").index(local), .slope = change.slope };
            };
        }
        if (self.virtual_edit) |edit| {
            if (@reduce(.And, normalized == Cell{ edit.block[0], edit.block[1], edit.block[2] })) {
                return switch (edit.action) {
                    .remove => null,
                    .put => |value| if (value == .country_road_adaptive or value == .custom) .{ .index = @import("block_transformations.zig").index(world.splitBlockCoords(edit.block)[1]) } else null,
                };
            }
        }
        const coords, const local = world.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
        const chunk = self.chunks.get(self.reader.layout.encodeChunkCoords(coords)) orelse return null;
        return chunk.metadata.road(@import("block_transformations.zig").index(local));
    }

    fn unformed(self: Context, cell: Cell) bool {
        const road = self.record(cell) orelse return false;
        return road.slope == null and self.readMaterial(cell) == .custom;
    }

    fn supported(self: Context, cell: Cell) bool {
        const below = cell - Cell{ 0, 0, 1 };
        const material = self.readMaterial(below) orelse return false;
        if (material == .none) return false;
        if (material == .custom) return if (self.record(below)) |road| road.slope == null else false;
        return true;
    }

    fn mark(self: Context, id: u32) void {
        if (std.mem.indexOfScalar(u32, self.changed.items, id) == null)
            if (self.prepared) self.changed.appendAssumeCapacity(id) else self.changed.append(self.allocator, id) catch @panic("OOM");
    }

    fn set(self: Context, cell: Cell, slope: ?data.Slope) void {
        const normalized = self.normalize(cell) orelse return;
        const coords, const local = world.splitBlockCoords(.{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
        const id = self.reader.layout.encodeChunkCoords(coords);
        const observed = self.record(normalized) orelse return;
        if (std.meta.eql(observed.slope, slope)) return;
        if (self.planned) |changes| {
            if (self.planning_failure.?.* != null) return;
            for (changes.items) |*change| if (@reduce(.And, change.cell == normalized)) {
                change.slope = slope;
                return;
            };
            if (changes.items.len >= self.max_plan_changes) {
                self.planning_failure.?.* = error.Capacity;
                return;
            }
            changes.append(self.allocator, .{ .cell = normalized, .slope = slope }) catch |err| {
                self.planning_failure.?.* = err;
            };
            return;
        }
        const chunk = self.chunks.getPtr(id) orelse return;
        const road = chunk.metadata.roadPtr(@import("block_transformations.zig").index(local)) orelse return;
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
        const cell = high + slope.downhill.offset() * @as(Cell, @splat(@as(i64, section) + 1));
        return self.normalize(cell) orelse cell;
    }

    fn lowEndpoint(self: Context, slope: data.Slope) Cell {
        return self.sectionCell(slope, slope.length) - Cell{ 0, 0, 1 };
    }

    fn memberLimit(self: Context, slope: data.Slope) u64 {
        // X wraps, so later laps revisit the same cells. Y is finite, so
        // later out-of-bounds sections cannot affect stored road ownership.
        const available: u64 = switch (slope.downhill) {
            .positive_x, .negative_x => self.reader.layout.size_in_blocks[0],
            .positive_y => self.reader.layout.size_in_blocks[1] - slope.high_endpoint[1] - 1,
            .negative_y => slope.high_endpoint[1],
        };
        return @min(@as(u64, slope.length), available);
    }

    fn revert(self: Context, slope: data.Slope) void {
        for (0..self.memberLimit(slope)) |i| {
            if (self.planning_failure) |failure| if (failure.* != null) return;
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
                const material = self.readMaterial(cursor) orelse return null;
                if (self.unformed(cursor)) continue;
                if (material == .country_road_solid) {
                    ends[side] = .{ .cell = cursor, .high = true, .count = count };
                } else if (material == .none and self.readMaterial(cursor - Cell{ 0, 0, 1 }) == .country_road_solid) {
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
            const above = self.readMaterial(member + Cell{ 0, 0, 1 }) orelse return null;
            if (above.isRoad()) return null;
        }
        return result;
    }

    fn ambiguous(self: Context, slope: data.Slope) bool {
        const other_axis: usize = if (@intFromEnum(slope.downhill) < 2) 1 else 0;
        for (0..slope.length) |i| if (self.candidate(self.sectionCell(slope, @intCast(i)), other_axis) != null) return true;
        return false;
    }

    /// Replay a previously chosen orientation after rebasing. A later crossing
    /// must not make that choice ambiguous, but new authoritative ownership,
    /// missing members, unsupported cells, or changed endpoints take precedence.
    pub fn restoreFormation(self: Context, slope: data.Slope) void {
        const high: Cell = .{ slope.high_endpoint[0], slope.high_endpoint[1], slope.high_endpoint[2] };
        const low = self.lowEndpoint(slope);
        if (self.readMaterial(high) != .country_road_solid or self.readMaterial(low) != .country_road_solid or self.readMaterial(low + Cell{ 0, 0, 1 }) != .none) return;
        for (0..slope.length) |i| {
            const member = self.sectionCell(slope, @intCast(i));
            const road = self.record(member) orelse return;
            if (self.readMaterial(member) != .custom or !self.supported(member)) return;
            const above = self.readMaterial(member + Cell{ 0, 0, 1 }) orelse return;
            if (above.isRoad()) return;
            if (road.slope) |existing| if (!sameRun(existing, slope)) return;
        }
        for (0..slope.length) |i| {
            var section = slope;
            section.section = @intCast(i);
            self.set(self.sectionCell(slope, @intCast(i)), section);
        }
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
        var candidate_storage: [20]data.Slope = undefined;
        var candidate_count: usize = 0;
        for (0..2) |level| {
            for (0..5) |neighbor| {
                const seed = target + Cell{ 0, 0, @intCast(level) } + (if (neighbor == 4) @as(Cell, @splat(0)) else @as(custom.Direction, @enumFromInt(neighbor)).offset());
                for (0..2) |axis| {
                    const slope = self.candidate(seed, axis) orelse continue;
                    var seen = false;
                    for (candidate_storage[0..candidate_count]) |existing| if (sameRun(existing, slope)) {
                        seen = true;
                        break;
                    };
                    if (!seen) {
                        candidate_storage[candidate_count] = slope;
                        candidate_count += 1;
                    }
                }
            }
        }
        // Resolve all ambiguity before mutating anything; loop order cannot select a winner.
        var allowed_storage: [20]data.Slope = undefined;
        var allowed_count: usize = 0;
        for (candidate_storage[0..candidate_count]) |slope| if (!self.ambiguous(slope)) {
            allowed_storage[allowed_count] = slope;
            allowed_count += 1;
        };
        for (allowed_storage[0..allowed_count]) |slope| {
            for (0..slope.length) |i| {
                var section = slope;
                section.section = @intCast(i);
                self.set(self.sectionCell(slope, @intCast(i)), section);
            }
            if (self.formed) |entries| {
                var seen = false;
                for (entries.items) |existing| if (sameRun(existing, slope)) {
                    seen = true;
                    break;
                };
                if (!seen) entries.append(self.allocator, slope) catch @panic("OOM");
            }
        }
    }
};

fn sameRun(a: data.Slope, b: data.Slope) bool {
    return std.meta.eql(a.high_endpoint, b.high_endpoint) and a.downhill == b.downhill and a.length == b.length;
}

test {
    _ = @import("road_tests.zig");
}
