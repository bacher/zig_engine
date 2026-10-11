//! Shared structural checks for client previews and authoritative edits.
const std = @import("std");
const engine = @import("engine");
pub const BlockType = engine.voxel_chunk.BlockType;
pub const Cell = @Vector(3, i64);
pub const Limits = struct {
    pub const wood_height: u32 = 12;
    pub const mineral_height: u32 = 20;
    pub const crushed_column: u32 = 6;
    pub const plank_span: u32 = 2;
    pub const reinforced_span: u32 = 4;
    pub const support_radius: u32 = 28;
    pub const maximum_span: u32 = @max(plank_span, reinforced_span);
};
const horizontal_search_radius = Limits.maximum_span + 1;
const horizontal_search_width = 2 * horizontal_search_radius + 1;
const horizontal_search_capacity = horizontal_search_width * horizontal_search_width;
pub const Reason = enum {
    material_not_placeable,
    missing_data,
    earth_footprint,
    earth_requires_stable_platform,
    incompatible_support,
    missing_foundation,
    horizontal_span,
    wood_height,
    mineral_height,
    crushed_column,
    would_remove_support,
    would_invalidate_structure,
    support_search_limit,
};

/// Target-relative coordinates remain continuous across the wrapped x seam.
pub fn displacement(layout: *const engine.WorldLayout, cell: Cell, center: Cell) Cell {
    var delta = cell - center;
    if (comptime engine.WorldLayout.wrap_x) {
        const width: i64 = layout.size_in_blocks[0];
        delta[0] = @mod(delta[0] + @divExact(width, 2), width) - @divExact(width, 2);
    }
    return delta;
}

pub fn distance(layout: *const engine.WorldLayout, cell: Cell, center: Cell) u64 {
    return @reduce(.Max, @abs(displacement(layout, cell, center)));
}

/// Value-owned diagnostics survive asynchronous replies. Coordinates are storage-space
/// cells (including missing cells at world edges), ready for a future 3D overlay.
pub const Failure = struct {
    reason: Reason,
    cause: ?Reason = null,
    subject: Cell,
    actual: u32 = 0,
    limit: u32 = 0,
    involved: [32]Cell = @splat(@splat(0)),
    involved_count: u6 = 0,
    truncated: bool = false,

    fn add(self: *Failure, cell: Cell) void {
        for (self.involved[0..self.involved_count]) |previous| {
            if (@reduce(.And, previous == cell)) return;
        }
        if (self.involved_count == self.involved.len) {
            self.truncated = true;
            return;
        }
        self.involved[self.involved_count] = cell;
        self.involved_count += 1;
    }
};

pub const Reader = struct {
    layout: *const engine.WorldLayout,
    context: *anyopaque,
    block_at: *const fn (*anyopaque, [3]u32) ?BlockType,

    pub fn normalize(self: Reader, cell: Cell) ?Cell {
        var result = cell;
        if (comptime engine.WorldLayout.wrap_x) result[0] = @mod(result[0], self.layout.size_in_blocks[0]);
        inline for (0..3) |axis| {
            if (result[axis] < 0 or result[axis] >= self.layout.size_in_blocks[axis]) return null;
        }
        return result;
    }

    pub fn get(self: Reader, cell: Cell) ?BlockType {
        const normalized = self.normalize(cell) orelse return .none;
        return self.block_at(self.context, .{ @intCast(normalized[0]), @intCast(normalized[1]), @intCast(normalized[2]) });
    }
};

const State = struct { wood: u32 = 0, mineral: u32 = 0 };
const Evaluation = union(enum) { supported: State, rejected: Failure };
/// Every consulted cell, including absent neighbors and diagonal/platform probes,
/// participates in reuse eligibility. Coordinates are relative to one cache center.
const ReadBounds = struct {
    low: Cell,
    high: Cell,

    fn include(self: *ReadBounds, cell: Cell) void {
        self.low = @min(self.low, cell);
        self.high = @max(self.high, cell);
    }

    fn fits(self: ReadBounds, layout: *const engine.WorldLayout, center: Cell) bool {
        const radius: i64 = Limits.support_radius;
        inline for (1..3) |axis| {
            if (self.low[axis] < center[axis] - radius or self.high[axis] > center[axis] + radius) return false;
        }
        if (self.low[0] >= center[0] - radius and self.high[0] <= center[0] + radius) return true;
        if (comptime engine.WorldLayout.wrap_x) {
            const width: i64 = layout.size_in_blocks[0];
            // Require the whole interval to fit one periodic window. Checking just
            // the wrapped endpoints could miss excluded cells between them.
            for ([_]i64{ center[0] - width, center[0] + width }) |wrapped| {
                if (self.low[0] >= wrapped - radius and self.high[0] <= wrapped + radius) return true;
            }
        }
        return false;
    }
};

const Evidence = struct {
    bounds: ReadBounds,
    /// A clipped or missing-data search can find support without finding its lowest
    /// height. Such results are reusable only in their original root window.
    complete: bool = true,

    fn merge(self: *Evidence, other: Evidence) void {
        self.bounds.include(other.bounds.low);
        self.bounds.include(other.bounds.high);
        self.complete = self.complete and other.complete;
    }
};

const CacheEntry = struct { evaluation: Evaluation, evidence: Evidence, scope: u64 };
const Cache = std.AutoHashMapUnmanaged(Cell, CacheEntry);
const ReadError = error{ MissingData, SupportWindowExceeded };

fn rememberError(previous: *?ReadError, next: ReadError) void {
    if (previous.* == null or next == error.SupportWindowExceeded) previous.* = next;
}

pub const Validator = struct {
    allocator: std.mem.Allocator,
    reader: Reader,
    /// Hypothetical edited contents; validation never mutates the world.
    edit: ?struct { cell: Cell, material: BlockType } = null,
    cache: Cache = .empty,
    depth: u16 = 0,
    /// Recursive support searches never recenter on intermediate blocks.
    root: ?Cell = null,
    outside: ?struct { cell: Cell, center: Cell } = null,
    /// All cache state belongs to this hypothetical edit, never to world metadata.
    cache_center: ?Cell = null,
    scope: u64 = 0,
    evidence: ?Evidence = null,

    pub fn deinit(self: *Validator) void {
        self.cache.deinit(self.allocator);
    }

    fn bound(self: *Validator, cell: Cell, center: Cell) ReadError!void {
        if (distance(self.reader.layout, cell, center) > Limits.support_radius) {
            if (self.outside == null) self.outside = .{ .cell = cell, .center = center };
            return error.SupportWindowExceeded;
        }
    }

    fn get(self: *Validator, cell: Cell) ReadError!BlockType {
        if (self.evidence) |*evidence| evidence.bounds.include(displacement(self.reader.layout, cell, self.cache_center.?));
        if (self.edit) |edit| self.bound(cell, edit.cell) catch |err| {
            self.markIncomplete();
            return err;
        };
        if (self.root) |root| self.bound(cell, root) catch |err| {
            self.markIncomplete();
            return err;
        };
        const normalized = self.reader.normalize(cell) orelse return .none;
        if (self.edit) |edit| {
            if (@reduce(.And, normalized == edit.cell)) return edit.material;
        }
        return self.reader.get(normalized) orelse {
            self.markIncomplete();
            return error.MissingData;
        };
    }

    fn markIncomplete(self: *Validator) void {
        if (self.evidence) |*evidence| evidence.complete = false;
    }

    fn mergeEvidence(self: *Validator, evidence: Evidence) void {
        if (self.evidence) |*current| current.merge(evidence);
    }

    fn beginCheck(self: *Validator, cell: Cell) void {
        if (self.root) |root| if (@reduce(.And, root == cell)) return;
        self.root = cell;
        if (self.cache_center == null) self.cache_center = if (self.edit) |edit| edit.cell else cell;
        self.scope += 1;
        self.outside = null;
    }

    fn readFailure(self: *Validator, err: ReadError, cell: Cell) Evaluation {
        if (err == error.MissingData) return failure(.missing_data, cell, 0, 0);
        var result = failure(.support_search_limit, cell, Limits.support_radius + 1, Limits.support_radius);
        if (self.outside) |outside| {
            result.rejected.actual = @intCast(distance(self.reader.layout, outside.cell, outside.center));
            result.rejected.add(outside.cell);
        }
        return result;
    }

    fn failure(reason: Reason, cell: Cell, actual: u32, limit: u32) Evaluation {
        var result: Failure = .{ .reason = reason, .subject = cell, .actual = actual, .limit = limit };
        result.add(cell);
        return .{ .rejected = result };
    }

    /// The cube occupies z-1 through z-3, centered directly beneath this cell.
    pub fn stablePlatform(self: *Validator, cell: Cell) ReadError!bool {
        var unresolved: ?ReadError = null;
        var incomplete = false;
        for (1..4) |depth| {
            for (0..3) |y| {
                for (0..3) |x| {
                    const block = self.get(cell + Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -@as(i64, @intCast(depth)) }) catch |err| {
                        rememberError(&unresolved, err);
                        continue;
                    };
                    incomplete = incomplete or !block.isStablePlatformMaterial();
                }
            }
        }
        if (incomplete) return false;
        if (unresolved) |err| return err;
        return true;
    }

    fn platformFailure(self: *Validator, reason: Reason, cell: Cell) Evaluation {
        var result: Failure = .{ .reason = reason, .subject = cell, .limit = 27 };
        for (1..4) |depth| {
            for (0..3) |y| {
                for (0..3) |x| {
                    const position = cell + Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -@as(i64, @intCast(depth)) };
                    const block = self.get(position) catch {
                        result.add(position);
                        continue;
                    };
                    if (block.isStablePlatformMaterial()) result.actual += 1 else result.add(position);
                }
            }
        }
        return .{ .rejected = result };
    }

    fn footprint(self: *Validator, cell: Cell) ReadError!Evaluation {
        var result: Failure = .{ .reason = .earth_footprint, .subject = cell, .limit = 9 };
        for (0..3) |y| {
            for (0..3) |x| {
                const below = cell + Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -1 };
                if ((try self.get(below)).isStructural()) result.actual += 1 else result.add(below);
            }
        }
        if (result.actual != 9) return .{ .rejected = result };
        return .{ .supported = .{} };
    }

    fn height(cell: Cell, material: BlockType, base: State) Evaluation {
        const state: State = if (material.isWood()) .{ .wood = base.wood + 1 } else .{ .mineral = base.mineral + 1 };
        if (state.wood > Limits.wood_height) return failure(.wood_height, cell, state.wood, Limits.wood_height);
        if (state.mineral > Limits.mineral_height) return failure(.mineral_height, cell, state.mineral, Limits.mineral_height);
        return .{ .supported = state };
    }

    /// Vertical support always decreases z; horizontal searches use only these direct
    /// sources, so same-level loops cannot create their own support.
    fn direct(self: *Validator, cell: Cell, material: BlockType) ReadError!Evaluation {
        const below_cell = cell - Cell{ 0, 0, 1 };
        const below = try self.get(below_cell);
        if (below == .none) return failure(.missing_foundation, cell, 0, 1);
        // These foundations already give the minimum height without inspecting an unused cube.
        if (below == .stone or (material.isWood() and below.isMineralConstruction()))
            return height(cell, material, .{});
        var unresolved: ?ReadError = null;
        const platform = below.isStablePlatformMaterial() and (self.stablePlatform(cell) catch |err| blk: {
            rememberError(&unresolved, err);
            break :blk false;
        });
        if (platform) return height(cell, material, .{});
        const vertical_result = self.vertical(cell, material, below) catch |err| {
            rememberError(&unresolved, err);
            return unresolved.?;
        };
        if (vertical_result == .supported) return vertical_result;
        if (unresolved) |err| return err;
        return vertical_result;
    }

    fn vertical(self: *Validator, cell: Cell, material: BlockType, below: BlockType) ReadError!Evaluation {
        const below_cell = cell - Cell{ 0, 0, 1 };
        if (below.isEarth()) return self.platformFailure(.earth_requires_stable_platform, cell);
        if (material.isWood()) {
            if (!below.isStructural()) return failure(.incompatible_support, below_cell, 0, 0);
            if (!below.isWood()) return height(cell, material, .{});
        } else if (material == .crushed_stone) {
            if (below == .stone) return height(cell, material, .{});
            if (below != .crushed_stone) return failure(.incompatible_support, below_cell, 0, 0);
        } else {
            if (below == .stone) return height(cell, material, .{});
            if (!below.isReinforced()) return self.platformFailure(.missing_foundation, cell);
        }
        return switch (try self.evaluate(below_cell, below)) {
            .supported => |base| height(cell, material, base),
            .rejected => |reason| .{ .rejected = reason },
        };
    }

    fn sameHorizontalFamily(material: BlockType, neighbor: BlockType) bool {
        return if (material == .planks) neighbor == .planks else neighbor.isReinforced();
    }

    fn horizontal(self: *Validator, cell: Cell, material: BlockType, limit: u32) ReadError!Evaluation {
        const Node = struct { cell: Cell, distance: u32 };
        // Search one extra shell to report an exceeded span, rather than a generic failure.
        std.debug.assert(limit <= Limits.maximum_span);
        var nodes: [horizontal_search_capacity]Node = undefined;
        nodes[0] = .{ .cell = cell, .distance = 0 };
        var count: usize = 1;
        var cursor: usize = 0;
        var best: ?State = null;
        var rejected = failure(.horizontal_span, cell, limit + 1, limit);
        var unresolved: ?ReadError = null;
        while (cursor < count) : (cursor += 1) {
            const node = nodes[cursor];
            const source = self.direct(node.cell, material) catch |err| blk: {
                rememberError(&unresolved, err);
                break :blk self.readFailure(err, node.cell);
            };
            switch (source) {
                .supported => |state| {
                    if (node.distance <= limit) {
                        if (best == null or state.wood + state.mineral < best.?.wood + best.?.mineral) best = state;
                    } else rejected.rejected.add(node.cell);
                },
                .rejected => |reason| {
                    if (reason.reason == .wood_height or reason.reason == .mineral_height) rejected = source;
                    if (reason.reason == .missing_data) rememberError(&unresolved, error.MissingData);
                    if (reason.reason == .support_search_limit) rememberError(&unresolved, error.SupportWindowExceeded);
                },
            }
            if (node.distance >= limit + 1) continue;
            for (0..3) |y| {
                for (0..3) |x| {
                    const dx = @as(i64, @intCast(x)) - 1;
                    const dy = @as(i64, @intCast(y)) - 1;
                    if (dx == 0 and dy == 0) continue;
                    const next = self.reader.normalize(node.cell + Cell{ dx, dy, 0 }) orelse continue;
                    const neighbor = self.get(next) catch |err| {
                        rememberError(&unresolved, err);
                        continue;
                    };
                    if (!sameHorizontalFamily(material, neighbor)) continue;
                    if (dx != 0 and dy != 0) {
                        // Both intermediate cells must fill the corner: corner-only chains
                        // do not transmit support even though diagonals cost one step.
                        const a = self.get(node.cell + Cell{ dx, 0, 0 }) catch |err| {
                            rememberError(&unresolved, err);
                            continue;
                        };
                        const b = self.get(node.cell + Cell{ 0, dy, 0 }) catch |err| {
                            rememberError(&unresolved, err);
                            continue;
                        };
                        if (!sameHorizontalFamily(material, a) or !sameHorizontalFamily(material, b)) continue;
                    }
                    var visited = false;
                    for (nodes[0..count]) |previous| visited = visited or @reduce(.And, previous.cell == next);
                    if (visited) continue;
                    std.debug.assert(count < nodes.len);
                    nodes[count] = .{ .cell = next, .distance = node.distance + 1 };
                    count += 1;
                }
            }
        }
        if (best) |state| return .{ .supported = state };
        if (unresolved) |err| return err;
        return rejected;
    }

    fn crushedBridgeSide(self: *Validator, side: Cell) ReadError!Evaluation {
        const neighbor = try self.get(side);
        if (neighbor != .stone and neighbor != .crushed_stone)
            return failure(.missing_foundation, side, 0, 1);
        // Another unsupported bridge cannot extend the one-cell exception.
        if (neighbor == .crushed_stone) return self.direct(side, neighbor);
        if (!(try self.get(side - Cell{ 0, 0, 1 })).isStablePlatformMaterial())
            return failure(.missing_foundation, side, 0, 1);
        return .{ .supported = .{} };
    }

    fn crushedBridge(self: *Validator, cell: Cell) ReadError!Evaluation {
        var pending: ?ReadError = null;
        for ([_]Cell{ .{ 1, 0, 0 }, .{ 0, 1, 0 } }) |direction| {
            var states: [2]State = undefined;
            var valid = true;
            var unresolved: ?ReadError = null;
            for ([_]Cell{ cell - direction, cell + direction }, 0..) |side, i| {
                const state = self.crushedBridgeSide(side) catch |err| {
                    rememberError(&unresolved, err);
                    continue;
                };
                switch (state) {
                    .supported => |value| states[i] = value,
                    .rejected => |reason| {
                        if (reason.reason == .missing_data) {
                            rememberError(&unresolved, error.MissingData);
                        } else if (reason.reason == .support_search_limit) {
                            rememberError(&unresolved, error.SupportWindowExceeded);
                        } else {
                            valid = false;
                            break;
                        }
                    },
                }
            }
            if (!valid) continue;
            if (unresolved) |err| {
                rememberError(&pending, err);
                continue;
            }
            return .{ .supported = .{ .mineral = @max(1, @min(states[0].mineral, states[1].mineral)) } };
        }
        if (pending) |err| return err;
        var result = failure(.missing_foundation, cell, 0, 2);
        for ([_]Cell{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 } }) |direction| {
            result.rejected.add(cell + direction);
            result.rejected.add(cell + direction - Cell{ 0, 0, 1 });
        }
        return result;
    }

    fn evaluate(self: *Validator, cell: Cell, material: BlockType) ReadError!Evaluation {
        if (self.cache.get(cell)) |cached| {
            const reusable = cached.scope == self.scope or
                (cached.evaluation == .supported and cached.evidence.complete and
                    cached.evidence.bounds.fits(self.reader.layout, displacement(self.reader.layout, self.root.?, self.cache_center.?)));
            if (reusable) {
                self.mergeEvidence(cached.evidence);
                return cached.evaluation;
            }
        }
        if (self.depth >= 256) {
            self.markIncomplete();
            return failure(.missing_foundation, cell, 0, 1);
        }
        const outer_evidence = self.evidence;
        const relative = displacement(self.reader.layout, cell, self.cache_center.?);
        self.evidence = .{ .bounds = .{ .low = relative, .high = relative } };
        self.depth += 1;
        defer {
            const evidence = self.evidence.?;
            self.evidence = outer_evidence;
            self.mergeEvidence(evidence);
            self.depth -= 1;
        }
        const result = try self.evaluateUncached(cell, material);
        self.cache.put(self.allocator, cell, .{ .evaluation = result, .evidence = self.evidence.?, .scope = self.scope }) catch @panic("OOM");
        return result;
    }

    fn evaluateUncached(self: *Validator, cell: Cell, material: BlockType) ReadError!Evaluation {
        if (material.isEarth()) return self.footprint(cell);
        if (!material.isWood() and !material.isMineralConstruction()) return .{ .supported = .{} };
        if (material == .crushed_stone) {
            var run: u32 = 0;
            var below = cell;
            var unresolved: ?ReadError = null;
            while (try self.get(below) == .crushed_stone) : (below[2] -= 1) {
                run += 1;
                if (run > Limits.crushed_column) {
                    if (unresolved) |err| return err;
                    return failure(.crushed_column, cell, run, Limits.crushed_column);
                }
                const platform = self.stablePlatform(below) catch |err| blk: {
                    rememberError(&unresolved, err);
                    break :blk false;
                };
                if (platform) break;
            }
        }
        const below = try self.get(cell - Cell{ 0, 0, 1 });
        const direct_result = self.direct(cell, material) catch |err| self.readFailure(err, cell);
        // An incompatible occupied block cannot be treated as air to bypass the hierarchy.
        if (below != .none) {
            if (direct_result == .rejected) {
                const compatible = if (material.isWood()) below.isStructural() and !below.isEarth() else if (material == .crushed_stone) below == .crushed_stone or below == .stone else below.isReinforced() or below == .stone;
                if (!compatible) return direct_result;
                const reason = direct_result.rejected.reason;
                if (reason != .wood_height and reason != .mineral_height and reason != .missing_data and reason != .support_search_limit)
                    return direct_result;
            }
        }
        // Height one is already minimal. Otherwise compare all legal routes before caching.
        if (direct_result == .supported and direct_result.supported.wood + direct_result.supported.mineral == 1)
            return direct_result;
        if (material == .planks) return self.horizontal(cell, material, Limits.plank_span);
        if (material.isReinforced()) return self.horizontal(cell, material, Limits.reinforced_span);
        if (material == .crushed_stone and below == .none) return self.crushedBridge(cell);
        return direct_result;
    }

    pub fn checkExisting(self: *Validator, cell: Cell) ?Failure {
        self.beginCheck(cell);
        const material = self.get(cell) catch |err| return self.readFailure(err, cell).rejected;
        if (material == .none) return null;
        const result = self.evaluate(cell, material) catch |err| return self.readFailure(err, cell).rejected;
        return switch (result) {
            .supported => null,
            .rejected => |reason| if (self.outside != null and (reason.reason == .wood_height or reason.reason == .mineral_height or reason.reason == .horizontal_span or reason.reason == .missing_foundation))
                self.readFailure(error.SupportWindowExceeded, cell).rejected
            else
                reason,
        };
    }

    pub fn checkPlacement(self: *Validator, cell: Cell, material: BlockType) ?Failure {
        if (!material.isPlaceable()) return failure(.material_not_placeable, cell, 0, 0).rejected;
        return self.checkExisting(cell);
    }

    /// A conservative downward support envelope, computed without a dependency index.
    /// Each lower level can add a horizontal search shell and an off-center platform cell.
    /// Soil reads only its immediate footprint. Wrapped x distances must follow the seam.
    fn mayDependOnEdit(self: *Validator, cell: Cell) ReadError!bool {
        const edit = self.edit orelse return true;
        if (distance(self.reader.layout, cell, edit.cell) > Limits.support_radius) return false;
        const depth = cell[2] - edit.cell[2];
        if (depth < 0) return false;
        self.beginCheck(cell);
        const material = try self.get(cell);
        const radius: u64 = if (material.isEarth()) blk: {
            if (depth != 1) return false;
            break :blk 1;
        } else if (material.isWood() or material.isMineralConstruction())
            @intCast((depth + 1) * (horizontal_search_radius + 1))
        else
            return false;
        const delta = displacement(self.reader.layout, cell, edit.cell);
        return @abs(delta[0]) <= radius and @abs(delta[1]) <= radius;
    }

    /// Revalidate potentially affected constructions; unrelated missing support data
    /// must not veto an edit. Generated cells are not subjected to construction rules.
    pub fn checkDependents(self: *Validator, cells: []const Cell, removal: bool) ?Failure {
        for (cells) |cell| {
            if (self.edit) |edit| if (@reduce(.And, edit.cell == cell)) continue;
            if (!(self.mayDependOnEdit(cell) catch |err| return self.readFailure(err, cell).rejected)) continue;
            if (self.checkExisting(cell)) |reason| {
                var result = reason;
                result.cause = reason.reason;
                result.reason = if (reason.reason == .missing_data) .missing_data else if (removal) .would_remove_support else .would_invalidate_structure;
                if (self.edit) |edit| result.add(edit.cell);
                return result;
            }
        }
        return null;
    }
};

const Fixture = struct {
    layout: engine.WorldLayout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 8 } }) catch unreachable,
    blocks: std.AutoHashMapUnmanaged(Cell, BlockType) = .empty,
    constructed: std.ArrayList(Cell) = .empty,
    missing: ?Cell = null,
    read_center: ?Cell = null,
    outside_reads: usize = 0,
    read_calls: usize = 0,
    maximum_read_distance: u64 = 0,

    fn deinit(self: *Fixture) void {
        self.blocks.deinit(std.testing.allocator);
        self.constructed.deinit(std.testing.allocator);
    }

    fn read(context: *anyopaque, block: [3]u32) ?BlockType {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.read_calls += 1;
        const cell: Cell = .{ block[0], block[1], block[2] };
        if (self.read_center) |center| {
            const reach = distance(&self.layout, cell, center);
            self.maximum_read_distance = @max(self.maximum_read_distance, reach);
            if (reach > Limits.support_radius) {
                self.outside_reads += 1;
                return null;
            }
        }
        if (self.missing) |missing| if (@reduce(.And, cell == missing)) return null;
        return self.blocks.get(cell) orelse if (cell[2] < 4) BlockType.stone else BlockType.none;
    }

    fn check(self: *Fixture, cell: Cell, material: BlockType) ?Failure {
        const reader: Reader = .{ .layout = &self.layout, .context = self, .block_at = read };
        const normalized = reader.normalize(cell) orelse return Validator.failure(.missing_foundation, cell, 0, 1).rejected;
        if (self.read_center != null) self.read_center = normalized;
        var validator: Validator = .{
            .allocator = std.testing.allocator,
            .reader = reader,
            .edit = .{ .cell = normalized, .material = material },
        };
        defer validator.deinit();
        if (material != .none) if (validator.checkPlacement(normalized, material)) |reason| return reason;
        return validator.checkDependents(self.constructed.items, material == .none);
    }

    fn put(self: *Fixture, cell: Cell, material: BlockType) !void {
        if (self.check(cell, material)) |reason| {
            std.debug.print("unexpected {s} at {any}, {d}/{d}\n", .{ @tagName(reason.reason), cell, reason.actual, reason.limit });
            return error.TestUnexpectedResult;
        }
        try self.blocks.put(std.testing.allocator, cell, material);
        try self.constructed.append(std.testing.allocator, cell);
    }

    fn raw(self: *Fixture, cell: Cell, material: BlockType) !void {
        const reader: Reader = .{ .layout = &self.layout, .context = self, .block_at = read };
        try self.blocks.put(std.testing.allocator, reader.normalize(cell) orelse return error.TestUnexpectedResult, material);
    }

    fn staircase(self: *Fixture, origin: Cell, direction: Cell, reach: u32, foundation: BlockType) !Cell {
        for (1..4) |depth| {
            for (0..3) |y| {
                for (0..3) |x| try self.raw(origin + Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -@as(i64, @intCast(depth)) }, foundation);
            }
        }
        try self.raw(origin, .rebar);
        var progress: u32 = 0;
        var level: i64 = 0;
        while (progress < reach) {
            const length = @min(Limits.reinforced_span, reach - progress);
            level += 1;
            const start = origin + direction * @as(Cell, @splat(progress)) + Cell{ 0, 0, level };
            for (0..length + 1) |offset| try self.raw(start + direction * @as(Cell, @splat(@intCast(offset))), .rebar);
            progress += length;
        }
        const reader: Reader = .{ .layout = &self.layout, .context = self, .block_at = read };
        const target = reader.normalize(origin + direction * @as(Cell, @splat(reach)) + Cell{ 0, 0, level }).?;
        try self.raw(target, .none);
        return target;
    }
};

test "loose earth needs nine cells; unknown dependencies and world seams are distinct from air" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.put(.{ 0, 10, 4 }, .dirt);
    const seam_removal = fixture.check(.{ fixture.layout.size_in_blocks[0] - 1, 10, 3 }, .none).?;
    try std.testing.expectEqual(Reason.would_remove_support, seam_removal.reason);
    try std.testing.expectEqual(Reason.earth_footprint, seam_removal.cause.?);
    try std.testing.expectEqual(Reason.earth_footprint, fixture.check(.{ 20, 0, 4 }, .dirt).?.reason);
    fixture.missing = .{ 20, 20, 3 };
    try std.testing.expectEqual(Reason.missing_data, fixture.check(.{ 20, 20, 4 }, .dirt).?.reason);
    fixture.missing = null;
    try fixture.raw(.{ 20, 20, 3 }, .none);
    const failure_result = fixture.check(.{ 20, 20, 4 }, .dirt).?;
    try std.testing.expectEqual(8, failure_result.actual);
    try std.testing.expectEqual(9, failure_result.limit);
    try std.testing.expectEqual(1, failure_result.involved_count);
}

test "soil supports other materials only through the centered three-layer platform" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.put(.{ 10, 10, 4 }, .dirt);
    try std.testing.expectEqual(Reason.earth_requires_stable_platform, fixture.check(.{ 10, 10, 5 }, .planks).?.reason);
    // A pyramid supplies a 3x3x3 soil cube beneath its central top cell.
    for (0..3) |layer| {
        const radius: i64 = 3 - @as(i64, @intCast(layer));
        var y: i64 = -radius;
        while (y <= radius) : (y += 1) {
            var x: i64 = -radius;
            while (x <= radius) : (x += 1) {
                const cell = Cell{ 30 + x, 30 + y, 4 + @as(i64, @intCast(layer)) };
                try fixture.put(cell, .dirt);
            }
        }
    }
    try fixture.put(.{ 30, 30, 7 }, .reinforced_concrete);
    try std.testing.expect(fixture.check(.{ 33, 30, 7 }, .tree_trunk) != null);
}

test "wood and reinforced spans count diagonal steps only through filled corners" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.put(.{ 10, 10, 4 }, .tree_trunk);
    try fixture.put(.{ 10, 10, 5 }, .planks);
    try std.testing.expect(fixture.check(.{ 11, 11, 5 }, .planks) != null);
    try fixture.put(.{ 11, 10, 5 }, .planks);
    // One intermediate face permits a two-step path, but not a one-step diagonal.
    try std.testing.expect(fixture.check(.{ 11, 11, 5 }, .planks) == null);
    try fixture.put(.{ 11, 11, 5 }, .planks);
    try std.testing.expect(fixture.check(.{ 12, 11, 5 }, .planks) != null);
    try fixture.put(.{ 12, 10, 5 }, .planks);
    try fixture.put(.{ 12, 11, 5 }, .planks);
    try fixture.put(.{ 10, 11, 5 }, .planks);
    const wood_span = fixture.check(.{ 13, 10, 5 }, .planks).?;
    try std.testing.expectEqual(Reason.horizontal_span, wood_span.reason);
    try std.testing.expectEqual(3, wood_span.actual);
    try std.testing.expectEqual(2, wood_span.limit);
    try fixture.put(.{ 30, 30, 4 }, .rebar);
    for (0..5) |offset| try fixture.put(.{ 30 + @as(i64, @intCast(offset)), 30, 5 }, if (offset % 2 == 0) .rebar else .reinforced_concrete);
    const concrete_span = fixture.check(.{ 35, 30, 5 }, .rebar).?;
    try std.testing.expectEqual(Reason.horizontal_span, concrete_span.reason);
    try std.testing.expectEqual(4, concrete_span.limit);
}

test "wood inherits height across a cantilever and gets a fresh group above stone" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    for (4..16) |z| try fixture.put(.{ 10, 10, @intCast(z) }, .planks);
    try fixture.put(.{ 11, 10, 15 }, .planks);
    const reason = fixture.check(.{ 11, 10, 16 }, .tree_trunk).?;
    try std.testing.expectEqual(Reason.wood_height, reason.reason);
    try std.testing.expectEqual(13, reason.actual);
    for (4..10) |z| try fixture.put(.{ 30, 30, @intCast(z) }, .crushed_stone);
    for (10..22) |z| try fixture.put(.{ 30, 30, @intCast(z) }, .tree_trunk);
    try std.testing.expectEqual(Reason.wood_height, fixture.check(.{ 30, 30, 22 }, .tree_trunk).?.reason);
}

test "mineral materials share twenty levels and crushed stone has a separate six-cell run" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    for (4..24) |z| try fixture.put(.{ 10, 10, @intCast(z) }, if (z % 2 == 0) .rebar else .reinforced_concrete);
    const reason = fixture.check(.{ 10, 10, 24 }, .rebar).?;
    try std.testing.expectEqual(Reason.mineral_height, reason.reason);
    try std.testing.expectEqual(21, reason.actual);
    for (4..10) |z| try fixture.put(.{ 30, 30, @intCast(z) }, .crushed_stone);
    try std.testing.expectEqual(Reason.crushed_column, fixture.check(.{ 30, 30, 10 }, .crushed_stone).?.reason);
    try std.testing.expectEqual(Reason.incompatible_support, fixture.check(.{ 10, 10, 24 }, .crushed_stone).?.reason);
}

test "a stable platform also restarts the crushed-stone run counter" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    for (4..7) |z| {
        for (29..32) |y| {
            for (29..32) |x| try fixture.raw(.{ @intCast(x), @intCast(y), @intCast(z) }, .crushed_stone);
        }
    }
    for (7..13) |z| try fixture.put(.{ 30, 30, @intCast(z) }, .crushed_stone);
    try std.testing.expectEqual(Reason.crushed_column, fixture.check(.{ 30, 30, 13 }, .crushed_stone).?.reason);
}

test "a platform resets height and removing its off-center cell can invalidate the tower" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    for (4..24) |z| try fixture.put(.{ 30, 30, @intCast(z) }, .rebar);
    try std.testing.expect(fixture.check(.{ 30, 30, 24 }, .rebar) != null);
    for (21..24) |z| {
        // Fill face neighbors before corners, preserving a legal construction order.
        for (0..2) |phase| {
            for (29..32) |y| {
                for (29..32) |x| {
                    if (x == 30 and y == 30) continue;
                    const diagonal = x != 30 and y != 30;
                    if (diagonal != (phase == 1)) continue;
                    try fixture.put(.{ @intCast(x), @intCast(y), @intCast(z) }, .reinforced_concrete);
                }
            }
        }
    }
    try fixture.put(.{ 30, 30, 24 }, .rebar);
    const reason = fixture.check(.{ 29, 29, 21 }, .none).?;
    try std.testing.expectEqual(Reason.would_remove_support, reason.reason);
    try std.testing.expectEqual(Reason.mineral_height, reason.cause);
}

test "filled wooden and reinforced platforms reach square corners at their respective limits" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    for ([_]struct { center: i64, radius: i64, material: BlockType }{
        .{ .center = 10, .radius = 2, .material = .planks },
        .{ .center = 30, .radius = 4, .material = .rebar },
    }) |platform| {
        try fixture.put(.{ platform.center, platform.center, 4 }, platform.material);
        var y: i64 = -platform.radius;
        while (y <= platform.radius) : (y += 1) {
            var x: i64 = -platform.radius;
            while (x <= platform.radius) : (x += 1)
                try fixture.raw(.{ platform.center + x, platform.center + y, 5 }, platform.material);
        }
        y = -platform.radius;
        while (y <= platform.radius) : (y += 1) {
            var x: i64 = -platform.radius;
            while (x <= platform.radius) : (x += 1)
                try std.testing.expect(fixture.check(.{ platform.center + x, platform.center + y, 5 }, platform.material) == null);
        }
        try std.testing.expect(fixture.check(.{ platform.center + platform.radius + 1, platform.center, 5 }, platform.material) != null);
    }
}

test "crushed stone bridges one cell between opposed vertically supported stone sides" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.put(.{ 9, 10, 4 }, .crushed_stone);
    try fixture.put(.{ 9, 10, 5 }, .crushed_stone);
    try fixture.put(.{ 11, 10, 4 }, .crushed_stone);
    try fixture.put(.{ 11, 10, 5 }, .crushed_stone);
    try fixture.put(.{ 10, 10, 5 }, .crushed_stone);
    const reason = fixture.check(.{ 9, 10, 4 }, .none).?;
    try std.testing.expectEqual(Reason.would_remove_support, reason.reason);
    try fixture.raw(.{ 11, 10, 4 }, .none);
    try std.testing.expect(fixture.check(.{ 10, 10, 6 }, .crushed_stone) != null);
    try std.testing.expectEqual(Reason.material_not_placeable, fixture.check(.{ 20, 20, 4 }, .stone).?.reason);
}

test "planks and reinforced blocks inherit the lowest height across vertical and horizontal routes" {
    for ([_]struct { material: BlockType, above: BlockType, height: u32 }{
        .{ .material = .planks, .above = .tree_trunk, .height = Limits.wood_height },
        .{ .material = .reinforced_concrete, .above = .rebar, .height = Limits.mineral_height },
    }) |construction| {
        var fixture: Fixture = .{};
        defer fixture.deinit();
        const top: i64 = 3 + construction.height;
        for (4..@as(usize, @intCast(top + 1))) |z| try fixture.put(.{ 10, 10, @intCast(z) }, construction.material);
        try std.testing.expect(fixture.check(.{ 10, 10, top + 1 }, construction.above) != null);
        // The existing top cell can inherit height one from this nearby natural ledge.
        try fixture.raw(.{ 11, 10, top - 1 }, .stone);
        try fixture.put(.{ 11, 10, top }, construction.material);
        try fixture.put(.{ 10, 10, top + 1 }, construction.above);
        const removed = fixture.check(.{ 11, 10, top - 1 }, .none).?;
        try std.testing.expectEqual(Reason.would_remove_support, removed.reason);
        try std.testing.expectEqual(if (construction.material.isWood()) Reason.wood_height else Reason.mineral_height, removed.cause.?);
        // Even a shorter horizontal route cannot legalize incompatible occupied support.
        try fixture.raw(.{ 10, 10, top - 1 }, .sand);
        const incompatible = fixture.check(.{ 10, 10, top }, construction.material).?;
        try std.testing.expectEqual(if (construction.material.isWood()) Reason.incompatible_support else Reason.missing_foundation, incompatible.reason);
    }
}

test "a known bridge orientation remains valid despite missing alternative neighbors" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    for ([_]i64{ 9, 11 }) |y| {
        try fixture.put(.{ 10, y, 4 }, .crushed_stone);
        try fixture.put(.{ 10, y, 5 }, .crushed_stone);
    }
    try std.testing.expect(fixture.check(.{ 10, 10, 5 }, .crushed_stone) == null);
    fixture.missing = .{ 9, 10, 5 };
    try std.testing.expect(fixture.check(.{ 10, 10, 5 }, .crushed_stone) == null);
    // An unavailable x side cannot matter when its opposite side is known to be air.
    try fixture.raw(.{ 10, 11, 5 }, .none);
    try std.testing.expectEqual(Reason.missing_foundation, fixture.check(.{ 10, 10, 5 }, .crushed_stone).?.reason);
    // Now the missing x side could complete a valid pair, so its data is required.
    try fixture.raw(.{ 11, 10, 4 }, .crushed_stone);
    try fixture.raw(.{ 11, 10, 5 }, .crushed_stone);
    try std.testing.expectEqual(Reason.missing_data, fixture.check(.{ 10, 10, 5 }, .crushed_stone).?.reason);
}

test "dependent filtering follows supports through successive offset floors" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    try fixture.put(.{ 10, 10, 4 }, .planks);
    for (1..4) |level| {
        const origin: Cell = .{ 10 + 2 * @as(i64, @intCast(level - 1)), 10, 4 + @as(i64, @intCast(level)) };
        for (0..3) |offset| try fixture.put(origin + Cell{ @intCast(offset), 0, 0 }, .planks);
    }
    // Isolate the highest construction: its foundation is six cells away horizontally.
    fixture.constructed.clearRetainingCapacity();
    try fixture.constructed.append(std.testing.allocator, .{ 16, 10, 7 });
    try std.testing.expectEqual(Reason.would_remove_support, fixture.check(.{ 10, 10, 3 }, .none).?.reason);
}

test "the inclusive read window bounds every axis before querying blocks, including the wrapped seam" {
    var fixture: Fixture = .{ .layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }) catch unreachable, .read_center = .{ 0, 128, 128 } };
    defer fixture.deinit();
    const center = fixture.read_center.?;
    var validator: Validator = .{
        .allocator = std.testing.allocator,
        .reader = .{ .layout = &fixture.layout, .context = &fixture, .block_at = Fixture.read },
        .edit = .{ .cell = center, .material = .rebar },
    };
    defer validator.deinit();
    inline for (0..3) |axis| {
        for ([_]i64{ -1, 1 }) |sign| {
            var cell = center;
            cell[axis] += sign * Limits.support_radius;
            try std.testing.expectEqual(BlockType.none, try validator.get(cell));
            cell[axis] += sign;
            try std.testing.expectError(error.SupportWindowExceeded, validator.get(cell));
        }
    }
    const diagnostic = validator.readFailure(error.SupportWindowExceeded, center).rejected;
    try std.testing.expectEqual(Reason.support_search_limit, diagnostic.reason);
    try std.testing.expectEqual(29, diagnostic.actual);
    try std.testing.expectEqual(28, diagnostic.limit);
    try std.testing.expectEqual(0, fixture.outside_reads);
    try std.testing.expectEqual(28, fixture.maximum_read_distance);
}

test "stacked overhangs keep one 28-cell window under translations, directions, and wrapping" {
    for ([_]Cell{ .{ 80, 80, 64 }, .{ 95, 95, 95 }, .{ 252, 128, 95 } }) |origin| {
        for ([_]Cell{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 } }) |direction| {
            for ([_]u32{ 28, 29 }) |reach| {
                var fixture: Fixture = .{ .layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }) catch unreachable, .read_center = origin };
                defer fixture.deinit();
                const target = try fixture.staircase(origin, direction, reach, .stone);
                const result = fixture.check(target, .rebar);
                if (reach == 28) {
                    try std.testing.expect(result == null);
                } else {
                    try std.testing.expectEqual(Reason.support_search_limit, result.?.reason);
                    try std.testing.expectEqual(28, result.?.limit);
                }
                try std.testing.expectEqual(0, fixture.outside_reads);
                try std.testing.expect(fixture.maximum_read_distance <= 28);
            }
        }
    }
}

test "a stable platform must fit wholly inside the window and a known closer route still suffices" {
    for ([_]u32{ 27, 28 }) |reach| {
        var fixture: Fixture = .{ .layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }) catch unreachable, .read_center = .{ 96, 96, 64 } };
        defer fixture.deinit();
        const target = try fixture.staircase(.{ 96, 96, 64 }, .{ 1, 0, 0 }, reach, .packed_dirt);
        const result = fixture.check(target, .rebar);
        if (reach == 27) {
            try std.testing.expect(result == null);
        } else {
            try std.testing.expectEqual(Reason.support_search_limit, result.?.reason);
            // A valid nearby side foundation makes the unresolved remote route unnecessary.
            try fixture.raw(target + Cell{ 0, 1, -1 }, .stone);
            try fixture.raw(target + Cell{ 0, 1, 0 }, .reinforced_concrete);
            try std.testing.expect(fixture.check(target, .rebar) == null);
        }
        try std.testing.expectEqual(0, fixture.outside_reads);
    }
}

test "removal conservatively rejects a dependent whose remaining foundation is outside the edit window" {
    const origin: Cell = .{ 80, 80, 64 };
    var fixture: Fixture = .{ .layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }) catch unreachable, .read_center = origin };
    defer fixture.deinit();
    const end = try fixture.staircase(origin, .{ 1, 0, 0 }, 28, .stone);
    try fixture.raw(end, .rebar);
    // This taller fallback column keeps the offset floors legal after removing the
    // original foundation, but cannot support the last two levels of the tower.
    try fixture.raw(.{ 81, 80, 52 }, .stone);
    for (53..65) |z| try fixture.raw(.{ 81, 80, @intCast(z) }, .rebar);
    try fixture.raw(end + Cell{ 0, 0, 1 }, .rebar);
    const top = end + Cell{ 0, 0, 2 };
    try fixture.raw(top, .rebar);
    // The tower has another legal, low foundation within its own window, but this
    // route is beyond x=108, the removal's inclusive boundary.
    for (1..5) |offset| try fixture.raw(end + Cell{ @intCast(offset), 0, 0 }, .rebar);
    try fixture.raw(end + Cell{ 4, 0, -1 }, .stone);
    var validator: Validator = .{
        .allocator = std.testing.allocator,
        .reader = .{ .layout = &fixture.layout, .context = &fixture, .block_at = Fixture.read },
        .edit = .{ .cell = origin, .material = .none },
    };
    defer validator.deinit();
    // All constructions remain valid when checked using their own windows.
    fixture.read_center = null;
    var iterator = fixture.blocks.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .rebar) continue;
        try fixture.constructed.append(std.testing.allocator, entry.key_ptr.*);
        var independent: Validator = .{ .allocator = std.testing.allocator, .reader = validator.reader, .edit = validator.edit };
        defer independent.deinit();
        independent.edit = null;
        try std.testing.expect(independent.checkExisting(entry.key_ptr.*) == null);
    }
    // The near floors can still prove their height from the fallback column.
    fixture.read_center = origin;
    fixture.maximum_read_distance = 0;
    try std.testing.expect(validator.checkExisting(end) == null);
    const failure_result = validator.checkDependents(&.{top}, true).?;
    try std.testing.expectEqual(Reason.would_remove_support, failure_result.reason);
    try std.testing.expectEqual(Reason.support_search_limit, failure_result.cause.?);
    const all_dependents = fixture.check(origin, .none).?;
    try std.testing.expectEqual(Reason.would_remove_support, all_dependents.reason);
    try std.testing.expectEqual(Reason.support_search_limit, all_dependents.cause.?);
    try std.testing.expectEqual(0, fixture.outside_reads);
    try std.testing.expect(fixture.maximum_read_distance <= 28);
}

test "dependent windows intersect the edit window and never reuse another root's cached support" {
    const origin: Cell = .{ 80, 80, 64 };
    const edit: Cell = .{ 94, 80, 67 };
    var fixture: Fixture = .{ .layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }) catch unreachable, .read_center = edit };
    defer fixture.deinit();
    const near = try fixture.staircase(origin, .{ 1, 0, 0 }, 28, .stone);
    try fixture.raw(near, .rebar);
    const far = near + Cell{ 1, 0, 0 };
    try fixture.raw(far, .rebar);
    var validator: Validator = .{
        .allocator = std.testing.allocator,
        .reader = .{ .layout = &fixture.layout, .context = &fixture, .block_at = Fixture.read },
        .edit = .{ .cell = edit, .material = .none },
    };
    defer validator.deinit();
    try std.testing.expect(validator.checkExisting(near) == null);
    try std.testing.expectEqual(Reason.support_search_limit, validator.checkExisting(far).?.reason);
    try std.testing.expect(validator.checkExisting(near) == null);
    for ([_][2]Cell{ .{ near, far }, .{ far, near } }) |order| {
        const failure_result = validator.checkDependents(&order, true).?;
        try std.testing.expectEqual(Reason.support_search_limit, failure_result.cause.?);
        try std.testing.expectEqualDeep(far, failure_result.subject);
    }
    // The foundation is within the edit window, but outside the far block's own window.
    try std.testing.expectEqual(0, fixture.outside_reads);
    try std.testing.expect(fixture.maximum_read_distance <= 28);
}

test "a short crushed column on known natural stone needs no unresolved platform corners" {
    const edit: Cell = .{ 80, 80, 64 };
    const dependent: Cell = .{ 108, 80, 80 };
    var fixture: Fixture = .{ .layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }) catch unreachable, .read_center = edit };
    defer fixture.deinit();
    // The apparent platform crosses the edit's boundary, but direct natural-stone
    // support and the one-cell crushed run are both completely known inside it.
    for (1..4) |depth| {
        for (0..3) |y| {
            for (0..3) |x| try fixture.raw(dependent + Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -@as(i64, @intCast(depth)) }, .stone);
        }
    }
    try fixture.raw(dependent, .crushed_stone);
    try fixture.constructed.append(std.testing.allocator, dependent);
    try std.testing.expect(fixture.check(edit, .none) == null);
    try std.testing.expectEqual(0, fixture.outside_reads);
    try std.testing.expect(fixture.maximum_read_distance <= 28);
}

test "nested unknown foundations retain their diagnostic while a known horizontal route can still succeed" {
    var fixture: Fixture = .{};
    defer fixture.deinit();
    for (4..7) |z| try fixture.raw(.{ 10, 10, @intCast(z) }, .tree_trunk);
    try fixture.raw(.{ 10, 10, 7 }, .planks);
    try fixture.raw(.{ 11, 10, 7 }, .planks);
    fixture.missing = .{ 10, 10, 4 };
    try std.testing.expectEqual(Reason.missing_data, fixture.check(.{ 12, 10, 7 }, .planks).?.reason);
    try fixture.raw(.{ 12, 11, 6 }, .stone);
    try fixture.raw(.{ 12, 11, 7 }, .planks);
    try std.testing.expect(fixture.check(.{ 12, 10, 7 }, .planks) == null);
}

test "an adjacent edit reuses overlapping searches in a 200-block plank building" {
    // The second position crosses chunk boundaries and puts the edit on the x seam.
    for ([_]Cell{ .{ 20, 20, 4 }, .{ 59, 27, 4 } }) |origin| {
        const target = origin + Cell{ 5, 2, 0 };
        var fixture: Fixture = .{ .read_center = target };
        defer fixture.deinit();
        for (0..8) |z| {
            for (0..5) |y| {
                for (0..5) |x| {
                    const cell = origin + Cell{ @intCast(x), @intCast(y), @intCast(z) };
                    try fixture.raw(cell, .planks);
                    try fixture.constructed.append(std.testing.allocator, cell);
                }
            }
        }
        try std.testing.expect(fixture.check(target, .planks) == null);
        // Count work instead of asserting a machine-dependent elapsed time. The version
        // rebuilding each dependent's graph takes 2,840,990 reads at the first position.
        if (fixture.read_calls > 200_000) std.debug.print("placement validation used {d} reader calls\n", .{fixture.read_calls});
        try std.testing.expect(fixture.read_calls <= 200_000);
        try std.testing.expectEqual(0, fixture.outside_reads);
    }
}

test "a clipped successful search is recomputed when another root admits a lower foundation" {
    const origin: Cell = .{ 108, 80, 64 };
    const edit: Cell = .{ 94, 80, 67 };
    var fixture: Fixture = .{ .layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 8, 8, 8 } }) catch unreachable, .read_center = edit };
    defer fixture.deinit();
    const first = try fixture.staircase(origin, .{ -1, 0, 0 }, 28, .stone);
    try fixture.raw(first, .rebar);
    try fixture.raw(.{ 108, 80, 52 }, .stone);
    for (53..65) |z| try fixture.raw(.{ 108, 80, @intCast(z) }, .rebar);
    // The first root's window ends at x=108. It can use the tall column, but
    // cannot see the lower foundation and platform corners at x=109.
    try fixture.raw(.{ 109, 80, 64 }, .rebar);
    const second = first + Cell{ 1, 0, 2 };
    try fixture.raw(second - Cell{ 0, 0, 1 }, .rebar);
    try fixture.raw(second, .rebar);
    var validator: Validator = .{
        .allocator = std.testing.allocator,
        .reader = .{ .layout = &fixture.layout, .context = &fixture, .block_at = Fixture.read },
        .edit = .{ .cell = edit, .material = .none },
    };
    defer validator.deinit();
    try std.testing.expect(validator.checkExisting(first) == null);
    try std.testing.expectEqual(19, validator.cache.get(first).?.evaluation.supported.mineral);
    try std.testing.expect(!validator.cache.get(first).?.evidence.complete);
    // Reusing the higher, incomplete result would reject this tower at height 21.
    // The shifted root admits the complete platform and proves height 10 instead.
    try std.testing.expect(validator.checkExisting(second) == null);
    try std.testing.expectEqual(10, validator.cache.get(second).?.evaluation.supported.mineral);
    try std.testing.expectEqual(0, fixture.outside_reads);
}

test "cached read bounds fit whole periodic intervals rather than just their wrapped endpoints" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    const crossing: ReadBounds = .{ .low = .{ -28, 0, 0 }, .high = .{ 0, 0, 0 } };
    // Both endpoints fit, but an intermediate read at x=-4 is 32 cells away.
    try std.testing.expect(distance(&layout, crossing.low, .{ 28, 0, 0 }) <= 28);
    try std.testing.expect(distance(&layout, crossing.high, .{ 28, 0, 0 }) <= 28);
    try std.testing.expect(!crossing.fits(&layout, .{ 28, 0, 0 }));
    const left: ReadBounds = .{ .low = .{ -31, -1, -1 }, .high = .{ -29, 1, 1 } };
    const right: ReadBounds = .{ .low = .{ 29, -1, -1 }, .high = .{ 31, 1, 1 } };
    try std.testing.expect(left.fits(&layout, .{ 28, 0, 0 }));
    try std.testing.expect(right.fits(&layout, .{ -28, 0, 0 }));
    try std.testing.expect(!left.fits(&layout, .{ 28, 30, 0 }));
    try std.testing.expect(!right.fits(&layout, .{ -28, 0, 30 }));
}
