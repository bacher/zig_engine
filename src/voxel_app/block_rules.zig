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
};

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
const Cache = std.AutoHashMapUnmanaged(Cell, Evaluation);
const Missing = error{MissingData};

pub const Validator = struct {
    allocator: std.mem.Allocator,
    reader: Reader,
    /// Hypothetical edited contents; validation never mutates the world.
    edit: ?struct { cell: Cell, material: BlockType } = null,
    cache: Cache = .empty,
    depth: u16 = 0,

    pub fn deinit(self: *Validator) void {
        self.cache.deinit(self.allocator);
    }

    fn get(self: *Validator, cell: Cell) Missing!BlockType {
        const normalized = self.reader.normalize(cell) orelse return .none;
        if (self.edit) |edit| {
            if (@reduce(.And, normalized == edit.cell)) return edit.material;
        }
        return self.reader.get(normalized) orelse error.MissingData;
    }

    fn failure(reason: Reason, cell: Cell, actual: u32, limit: u32) Evaluation {
        var result: Failure = .{ .reason = reason, .subject = cell, .actual = actual, .limit = limit };
        result.add(cell);
        return .{ .rejected = result };
    }

    /// The cube occupies z-1 through z-3, centered directly beneath this cell.
    pub fn stablePlatform(self: *Validator, cell: Cell) Missing!bool {
        var unknown = false;
        var incomplete = false;
        for (1..4) |depth| {
            for (0..3) |y| {
                for (0..3) |x| {
                    const block = self.get(cell + Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -@as(i64, @intCast(depth)) }) catch {
                        unknown = true;
                        continue;
                    };
                    incomplete = incomplete or !block.isStablePlatformMaterial();
                }
            }
        }
        if (incomplete) return false;
        if (unknown) return error.MissingData;
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

    fn footprint(self: *Validator, cell: Cell) Missing!Evaluation {
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
    fn direct(self: *Validator, cell: Cell, material: BlockType) Missing!Evaluation {
        const below_cell = cell - Cell{ 0, 0, 1 };
        const below = try self.get(below_cell);
        if (below == .none) return failure(.missing_foundation, cell, 0, 1);
        if (try self.stablePlatform(cell)) return height(cell, material, .{});
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

    fn horizontal(self: *Validator, cell: Cell, material: BlockType, limit: u32) Missing!Evaluation {
        const Node = struct { cell: Cell, distance: u32 };
        // Search one extra shell to report an exceeded span, rather than a generic failure.
        std.debug.assert(limit <= Limits.maximum_span);
        var nodes: [horizontal_search_capacity]Node = undefined;
        nodes[0] = .{ .cell = cell, .distance = 0 };
        var count: usize = 1;
        var cursor: usize = 0;
        var best: ?State = null;
        var rejected = failure(.horizontal_span, cell, limit + 1, limit);
        var unknown = false;
        while (cursor < count) : (cursor += 1) {
            const node = nodes[cursor];
            const source = self.direct(node.cell, material) catch blk: {
                unknown = true;
                break :blk failure(.missing_data, node.cell, 0, 0);
            };
            switch (source) {
                .supported => |state| {
                    if (node.distance <= limit) {
                        if (best == null or state.wood + state.mineral < best.?.wood + best.?.mineral) best = state;
                    } else rejected.rejected.add(node.cell);
                },
                .rejected => |reason| {
                    if (reason.reason == .wood_height or reason.reason == .mineral_height) rejected = source;
                },
            }
            if (node.distance >= limit + 1) continue;
            for (0..3) |y| {
                for (0..3) |x| {
                    const dx = @as(i64, @intCast(x)) - 1;
                    const dy = @as(i64, @intCast(y)) - 1;
                    if (dx == 0 and dy == 0) continue;
                    const next = self.reader.normalize(node.cell + Cell{ dx, dy, 0 }) orelse continue;
                    const neighbor = self.get(next) catch {
                        unknown = true;
                        continue;
                    };
                    if (!sameHorizontalFamily(material, neighbor)) continue;
                    if (dx != 0 and dy != 0) {
                        // Both intermediate cells must fill the corner: corner-only chains
                        // do not transmit support even though diagonals cost one step.
                        const a = self.get(node.cell + Cell{ dx, 0, 0 }) catch {
                            unknown = true;
                            continue;
                        };
                        const b = self.get(node.cell + Cell{ 0, dy, 0 }) catch {
                            unknown = true;
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
        if (unknown) return error.MissingData;
        return rejected;
    }

    fn crushedBridgeSide(self: *Validator, side: Cell) Missing!Evaluation {
        const neighbor = try self.get(side);
        if (neighbor != .stone and neighbor != .crushed_stone)
            return failure(.missing_foundation, side, 0, 1);
        // Another unsupported bridge cannot extend the one-cell exception.
        if (neighbor == .crushed_stone) return self.direct(side, neighbor);
        if (!(try self.get(side - Cell{ 0, 0, 1 })).isStablePlatformMaterial())
            return failure(.missing_foundation, side, 0, 1);
        return .{ .supported = .{} };
    }

    fn crushedBridge(self: *Validator, cell: Cell) Missing!Evaluation {
        var unknown = false;
        for ([_]Cell{ .{ 1, 0, 0 }, .{ 0, 1, 0 } }) |direction| {
            var states: [2]State = undefined;
            var valid = true;
            var unresolved = false;
            for ([_]Cell{ cell - direction, cell + direction }, 0..) |side, i| {
                const state = self.crushedBridgeSide(side) catch {
                    unresolved = true;
                    continue;
                };
                switch (state) {
                    .supported => |value| states[i] = value,
                    .rejected => {
                        valid = false;
                        break;
                    },
                }
            }
            if (!valid) continue;
            if (unresolved) {
                unknown = true;
                continue;
            }
            return .{ .supported = .{ .mineral = @max(1, @min(states[0].mineral, states[1].mineral)) } };
        }
        if (unknown) return error.MissingData;
        var result = failure(.missing_foundation, cell, 0, 2);
        for ([_]Cell{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 } }) |direction| {
            result.rejected.add(cell + direction);
            result.rejected.add(cell + direction - Cell{ 0, 0, 1 });
        }
        return result;
    }

    fn evaluate(self: *Validator, cell: Cell, material: BlockType) Missing!Evaluation {
        if (self.cache.get(cell)) |cached| return cached;
        if (self.depth >= 256) return failure(.missing_foundation, cell, 0, 1);
        self.depth += 1;
        defer self.depth -= 1;
        const result = try self.evaluateUncached(cell, material);
        self.cache.put(self.allocator, cell, result) catch @panic("OOM");
        return result;
    }

    fn evaluateUncached(self: *Validator, cell: Cell, material: BlockType) Missing!Evaluation {
        if (material.isEarth()) return self.footprint(cell);
        if (!material.isWood() and !material.isMineralConstruction()) return .{ .supported = .{} };
        if (material == .crushed_stone) {
            var run: u32 = 0;
            var below = cell;
            while (try self.get(below) == .crushed_stone) : (below[2] -= 1) {
                run += 1;
                if (run > Limits.crushed_column) return failure(.crushed_column, cell, run, Limits.crushed_column);
                if (try self.stablePlatform(below)) break;
            }
        }
        const direct_result = try self.direct(cell, material);
        const below = try self.get(cell - Cell{ 0, 0, 1 });
        // An incompatible occupied block cannot be treated as air to bypass the hierarchy.
        if (below != .none) {
            if (direct_result == .rejected and direct_result.rejected.reason != .wood_height and direct_result.rejected.reason != .mineral_height)
                return direct_result;
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
        const material = self.get(cell) catch return failure(.missing_data, cell, 0, 0).rejected;
        if (material == .none) return null;
        const result = self.evaluate(cell, material) catch return failure(.missing_data, cell, 0, 0).rejected;
        return switch (result) {
            .supported => null,
            .rejected => |reason| reason,
        };
    }

    pub fn checkPlacement(self: *Validator, cell: Cell, material: BlockType) ?Failure {
        if (!material.isPlaceable()) return failure(.material_not_placeable, cell, 0, 0).rejected;
        return self.checkExisting(cell);
    }

    /// A conservative downward support envelope, computed without a dependency index.
    /// Each lower level can add a horizontal search shell and an off-center platform cell.
    /// Soil reads only its immediate footprint. Wrapped x distances must follow the seam.
    fn mayDependOnEdit(self: *Validator, cell: Cell) Missing!bool {
        const edit = self.edit orelse return true;
        const depth = cell[2] - edit.cell[2];
        if (depth < 0) return false;
        const material = try self.get(cell);
        const radius: u64 = if (material.isEarth()) blk: {
            if (depth != 1) return false;
            break :blk 1;
        } else if (material.isWood() or material.isMineralConstruction())
            @intCast((depth + 1) * (horizontal_search_radius + 1))
        else
            return false;
        var dx: u64 = @abs(cell[0] - edit.cell[0]);
        if (comptime engine.WorldLayout.wrap_x) dx = @min(dx, self.reader.layout.size_in_blocks[0] - dx);
        return dx <= radius and @abs(cell[1] - edit.cell[1]) <= radius;
    }

    /// Revalidate potentially affected constructions; unrelated missing support data
    /// must not veto an edit. Generated cells are not subjected to construction rules.
    pub fn checkDependents(self: *Validator, cells: []const Cell, removal: bool) ?Failure {
        for (cells) |cell| {
            if (self.edit) |edit| if (@reduce(.And, edit.cell == cell)) continue;
            if (!(self.mayDependOnEdit(cell) catch return failure(.missing_data, cell, 0, 0).rejected)) continue;
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

    fn deinit(self: *Fixture) void {
        self.blocks.deinit(std.testing.allocator);
        self.constructed.deinit(std.testing.allocator);
    }

    fn read(context: *anyopaque, block: [3]u32) ?BlockType {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const cell: Cell = .{ block[0], block[1], block[2] };
        if (self.missing) |missing| if (@reduce(.And, cell == missing)) return null;
        return self.blocks.get(cell) orelse if (cell[2] < 4) BlockType.stone else BlockType.none;
    }

    fn check(self: *Fixture, cell: Cell, material: BlockType) ?Failure {
        var validator: Validator = .{
            .allocator = std.testing.allocator,
            .reader = .{ .layout = &self.layout, .context = self, .block_at = read },
            .edit = .{ .cell = cell, .material = material },
        };
        defer validator.deinit();
        if (material != .none) if (validator.checkPlacement(cell, material)) |reason| return reason;
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
        try self.blocks.put(std.testing.allocator, cell, material);
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
