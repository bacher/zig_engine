//! Pure, detached blueprint compilation. No world state, source coordinates, or
//! historical gameplay rules are retained in a certified definition.
const std = @import("std");
const engine = @import("engine");
const rules = @import("block_rules.zig");
pub const BlockType = rules.BlockType;
pub const Size = [3]u32;
pub const LocalCell = [3]u32;
pub const default_max_cells: usize = 1_048_576;
pub const max_highlights = 128;

pub fn horizontalLimit(layout: *const engine.WorldLayout) u32 {
    return @min(layout.size_in_blocks[0] / 2 - 1, layout.size_in_blocks[1]);
}

pub const ShapeError = error{ InvalidDimensions, HorizontalLimit, CellBudget, InvalidContents, Empty, NotCompact, TargetCount };

pub fn checkedVolume(size: Size, horizontal_limit: u32, max_cells: usize) ShapeError!usize {
    if (size[0] == 0 or size[1] == 0 or size[2] == 0) return error.InvalidDimensions;
    if (size[0] > horizontal_limit or size[1] > horizontal_limit) return error.HorizontalLimit;
    var count: usize = 1;
    for (size) |extent| count = std.math.mul(usize, count, extent) catch return error.CellBudget;
    if (count > max_cells or count > std.math.maxInt(u32)) return error.CellBudget;
    return count;
}

pub fn logicalMaterial(material: BlockType) BlockType {
    return if (material.isEarth()) .dirt else material;
}

pub fn materialMatches(required: BlockType, actual: BlockType) bool {
    return required != .none and logicalMaterial(required) == logicalMaterial(actual);
}

pub fn eligibleHorizontalSupport(required: BlockType, neighbor: BlockType) bool {
    return neighbor != .none and (materialMatches(required, neighbor) or
        (required.isReinforced() and neighbor.isReinforced()) or
        (required == .crushed_stone and neighbor.isNaturalRock()));
}

/// This structural path performs one below read and at most four XY reads.
/// `physical` must expose actual terrain only; unknown data supplies no proof.
pub fn checkFulfillment(physical: rules.Reader, cell: rules.Cell, required: BlockType) bool {
    const below = physical.get(cell - rules.Cell{ 0, 0, 1 }) orelse return false;
    if (below != .none) return true;
    for (directions) |direction| {
        if (physical.get(cell + direction)) |neighbor| {
            if (eligibleHorizontalSupport(required, neighbor)) return true;
        }
    }
    return false;
}

const directions = [_]rules.Cell{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 } };

fn allowed(material: BlockType) bool {
    return switch (material) {
        .none, .dirt, .sand, .crushed_stone, .tree_trunk, .planks, .rebar, .reinforced_concrete, .country_road_solid => true,
        else => false,
    };
}

fn normalized(material: BlockType) BlockType {
    return if (material == .stone) .crushed_stone else logicalMaterial(material);
}

pub fn linearIndex(size: Size, cell: LocalCell) ?usize {
    for (cell, size) |coordinate, extent| if (coordinate >= extent) return null;
    return (@as(usize, cell[2]) * size[1] + cell[1]) * size[0] + cell[0];
}

pub fn cellAtIndex(size: Size, index: usize) LocalCell {
    const plane = @as(usize, size[0]) * size[1];
    return .{ @intCast(index % size[0]), @intCast((index % plane) / size[0]), @intCast(index / plane) };
}

/// Dense x-fastest array including internal empty cells. A definition owns its
/// allocation; clients share it by borrowing const slices or explicitly cloning.
pub const Definition = struct {
    size: Size,
    cells: []const BlockType,
    target_count: u32,

    pub fn deinit(self: *Definition, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn clone(self: Definition, allocator: std.mem.Allocator) !Definition {
        return .{ .size = self.size, .cells = try allocator.dupe(BlockType, self.cells), .target_count = self.target_count };
    }

    pub fn index(self: Definition, cell: LocalCell) ?usize {
        const result = linearIndex(self.size, cell) orelse return null;
        return if (result < self.cells.len) result else null;
    }

    pub fn blockAt(self: Definition, cell: LocalCell) ?BlockType {
        return self.cells[self.index(cell) orelse return null];
    }

    /// Serialization may restore certified contents, but malformed shape,
    /// unsupported types, incorrect counts, and noncompact arrays never publish.
    pub fn validateWellFormed(self: Definition, horizontal_limit: u32, max_cells: usize) ShapeError!void {
        const count = try checkedVolume(self.size, horizontal_limit, max_cells);
        if (count != self.cells.len) return error.InvalidContents;
        var occupied: u32 = 0;
        var low: LocalCell = self.size;
        var high: LocalCell = .{ 0, 0, 0 };
        for (self.cells, 0..) |material, i| {
            if (!allowed(material)) return error.InvalidContents;
            if (material == .none) continue;
            occupied += 1;
            const cell = cellAtIndex(self.size, i);
            inline for (0..3) |axis| {
                low[axis] = @min(low[axis], cell[axis]);
                high[axis] = @max(high[axis], cell[axis]);
            }
        }
        if (occupied == 0) return error.Empty;
        if (occupied != self.target_count) return error.TargetCount;
        inline for (0..3) |axis| if (low[axis] != 0 or high[axis] != self.size[axis] - 1) return error.NotCompact;
    }
};

pub fn rotatedSize(size: Size, turns: u2) Size {
    return if (turns & 1 == 0) size else .{ size[1], size[0], size[2] };
}

/// Clockwise viewed from +Z: (x,y,z) -> (y,width-1-x,z),
/// rebased to nonnegative offsets and repeated for each quarter turn.
pub fn rotatedCell(size: Size, cell: LocalCell, turns: u2) LocalCell {
    var result = cell;
    var current = size;
    for (0..turns) |_| {
        // Preserve scalar inputs before array assignment (result location
        // semantics can otherwise overwrite a component used by a later one).
        const x = result[0];
        const y = result[1];
        const width = current[0];
        const depth = current[1];
        result[0] = y;
        result[1] = width - 1 - x;
        current[0] = depth;
        current[1] = width;
    }
    return result;
}

pub const CertifiedDefinition = struct {
    definition: Definition,
    /// Compact coordinates + source_offset = original selected local coordinates.
    source_offset: LocalCell,
    substituted_count: u32 = 0,

    pub fn deinit(self: *CertifiedDefinition, allocator: std.mem.Allocator) void {
        self.definition.deinit(allocator);
        self.* = undefined;
    }
};

pub const Snapshot = struct { size: Size, cells: []const BlockType };
pub const Statistics = struct { rule_reads: usize = 0, validated_cells: usize = 0 };
pub const Options = struct {
    horizontal_limit: u32,
    max_cells: usize = default_max_cells,
    cancel: ?*const std.atomic.Value(bool) = null,
    cache_entries: usize = 8192,
    statistics: ?*Statistics = null,

    fn cancelled(self: Options) bool {
        return if (self.cancel) |token| token.load(.acquire) else false;
    }
};

pub const DiagnosticCode = enum { invalid_dimensions, horizontal_limit, budget_exceeded, invalid_contents, empty, structural, unassemblable };
pub const Diagnostics = struct {
    code: DiagnosticCode,
    failure: ?rules.Failure = null,
    actual: u32 = 0,
    limit: u32 = 0,
    highlights: [max_highlights]LocalCell = undefined,
    highlight_count: u16 = 0,
    truncated: bool = false,

    pub fn highlightedCells(self: *const Diagnostics) []const LocalCell {
        return self.highlights[0..self.highlight_count];
    }

    fn add(self: *Diagnostics, cell: LocalCell) void {
        for (self.highlightedCells()) |previous| if (std.mem.eql(u32, &previous, &cell)) return;
        if (self.highlight_count == max_highlights) {
            self.truncated = true;
            return;
        }
        self.highlights[self.highlight_count] = cell;
        self.highlight_count += 1;
    }
};

pub const CompileResult = union(enum) { valid: CertifiedDefinition, invalid: Diagnostics, cancelled: void };

fn shapeDiagnostic(err: ShapeError) Diagnostics {
    return .{ .code = switch (err) {
        error.InvalidDimensions => .invalid_dimensions,
        error.HorizontalLimit => .horizontal_limit,
        error.CellBudget => .budget_exceeded,
        error.Empty => .empty,
        else => .invalid_contents,
    } };
}

const padding: i64 = rules.Limits.support_radius + 4;
const Isolated = struct {
    size: Size,
    cells: []BlockType,
    layout: engine.WorldLayout,
    virtual_material: BlockType = .stone,
    statistics: ?*Statistics = null,

    fn init(size: Size, cells: []BlockType) Isolated {
        var layout = engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } }) catch unreachable;
        inline for (0..3) |axis| layout.size_in_blocks[axis] = size[axis] + @as(u32, 2 * padding);
        return .{ .size = size, .cells = cells, .layout = layout };
    }

    fn reader(self: *Isolated) rules.Reader {
        return .{ .layout = &self.layout, .periodic_x = false, .context = self, .block_at = read };
    }

    fn read(context: *anyopaque, block: [3]u32) ?BlockType {
        const self: *Isolated = @ptrCast(@alignCast(context));
        if (self.statistics) |statistics| statistics.rule_reads += 1;
        const local = rules.Cell{ block[0], block[1], block[2] } - @as(rules.Cell, @splat(padding));
        if (local[2] >= 0) {
            if (@reduce(.Or, local < @as(rules.Cell, @splat(0)))) return .none;
            const cell: LocalCell = .{ @intCast(local[0]), @intCast(local[1]), @intCast(local[2]) };
            return self.cells[linearIndex(self.size, cell) orelse return .none];
        }
        if (local[2] < -3) return .none;
        // The virtual foundation is precisely the 3x3 XY dilation of occupied
        // global-bottom cells, at z=-3..-1. No elevated island gets a root.
        for (0..3) |y| for (0..3) |x| {
            const root = local + rules.Cell{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, -local[2] };
            if (root[0] < 0 or root[1] < 0 or root[0] >= self.size[0] or root[1] >= self.size[1]) continue;
            if (self.cells[@as(usize, @intCast(root[1])) * self.size[0] + @as(usize, @intCast(root[0]))] != .none) return self.virtual_material;
        };
        return .none;
    }

    fn position(self: Isolated, index: usize) rules.Cell {
        const cell = cellAtIndex(self.size, index);
        return rules.Cell{ cell[0], cell[1], cell[2] } + @as(rules.Cell, @splat(padding));
    }

    fn indexOf(self: Isolated, point: rules.Cell) ?usize {
        const local = point - @as(rules.Cell, @splat(padding));
        if (@reduce(.Or, local < @as(rules.Cell, @splat(0)))) return null;
        return linearIndex(self.size, .{ @intCast(local[0]), @intCast(local[1]), @intCast(local[2]) });
    }
};

fn sourceCell(size: Size, index: usize, offset: LocalCell) LocalCell {
    const cell = cellAtIndex(size, index);
    return .{ cell[0] + offset[0], cell[1] + offset[1], cell[2] + offset[2] };
}

fn structuralDiagnostics(isolated: Isolated, failed_index: usize, failure: rules.Failure, offset: LocalCell, converted: std.DynamicBitSetUnmanaged) Diagnostics {
    var result: Diagnostics = .{ .code = .structural, .failure = failure, .actual = failure.actual, .limit = failure.limit };
    if (failure.reason == .mineral_height) {
        const top = cellAtIndex(isolated.size, failed_index);
        // Retain low substituted supports first, even if highlight capacity is
        // exhausted later by the upper failing cells or other involved probes.
        for (0..2) |pass| {
            for (0..top[2] + 1) |z| {
                const index = linearIndex(isolated.size, .{ top[0], top[1], @intCast(z) }).?;
                if (!isolated.cells[index].isReinforced()) continue;
                if (converted.isSet(index) != (pass == 0)) continue;
                result.add(sourceCell(isolated.size, index, offset));
            }
        }
    }
    result.add(sourceCell(isolated.size, failed_index, offset));
    for (failure.involved[0..failure.involved_count]) |cell| {
        if (isolated.indexOf(cell)) |index| if (isolated.cells[index] != .none) result.add(sourceCell(isolated.size, index, offset));
    }
    const translation = rules.Cell{ offset[0], offset[1], offset[2] } - @as(rules.Cell, @splat(padding));
    result.failure.?.subject += translation;
    for (result.failure.?.involved[0..result.failure.?.involved_count]) |*cell| cell.* += translation;
    return result;
}

fn validateAll(validator: *rules.Validator, isolated: Isolated, options: Options) error{ Cancelled, OutOfMemory }!?struct { index: usize, failure: rules.Failure } {
    for (isolated.cells, 0..) |material, index| {
        if (index & 255 == 0 and options.cancelled()) return error.Cancelled;
        if (material == .none) continue;
        const rejected = validator.checkExisting(isolated.position(index));
        if (options.statistics) |statistics| statistics.validated_cells += 1;
        if (options.cancelled()) return error.Cancelled;
        if (validator.allocation_failed) return error.OutOfMemory;
        if (rejected) |failure| return .{ .index = index, .failure = failure };
    }
    return null;
}

/// Caller retains `snapshot`; returned valid contents are an independent owned
/// allocation. All geometric limits are checked before reading or allocating it.
pub fn compile(allocator: std.mem.Allocator, snapshot: Snapshot, options: Options) !CompileResult {
    const volume = checkedVolume(snapshot.size, options.horizontal_limit, options.max_cells) catch |err| return .{ .invalid = shapeDiagnostic(err) };
    if (volume != snapshot.cells.len) return .{ .invalid = .{ .code = .invalid_contents } };
    if (options.cancelled()) return .cancelled;
    var low = snapshot.size;
    var high: LocalCell = .{ 0, 0, 0 };
    var target_count: u32 = 0;
    var original_reinforced = false;
    for (snapshot.cells, 0..) |material, i| {
        if (i & 1023 == 0 and options.cancelled()) return .cancelled;
        if (!allowed(normalized(material))) {
            var diagnostic: Diagnostics = .{ .code = .invalid_contents };
            diagnostic.add(cellAtIndex(snapshot.size, i));
            return .{ .invalid = diagnostic };
        }
        original_reinforced = original_reinforced or material.isReinforced();
        if (material == .none) continue;
        target_count += 1;
        const cell = cellAtIndex(snapshot.size, i);
        inline for (0..3) |axis| {
            low[axis] = @min(low[axis], cell[axis]);
            high[axis] = @max(high[axis], cell[axis]);
        }
    }
    if (target_count == 0) return .{ .invalid = .{ .code = .empty } };
    const size: Size = .{ high[0] - low[0] + 1, high[1] - low[1] + 1, high[2] - low[2] + 1 };
    const compact_volume = checkedVolume(size, options.horizontal_limit, options.max_cells) catch |err| return .{ .invalid = shapeDiagnostic(err) };
    const cells = try allocator.alloc(BlockType, compact_volume);
    var own_cells = true;
    defer if (own_cells) allocator.free(cells);
    for (cells, 0..) |*material, i| {
        if (i & 1023 == 0 and options.cancelled()) return .cancelled;
        const source = sourceCell(size, i, low);
        material.* = normalized(snapshot.cells[linearIndex(snapshot.size, source).?]);
    }
    var isolated = Isolated.init(size, cells);
    isolated.statistics = options.statistics;
    var validator: rules.Validator = .{ .allocator = allocator, .reader = isolated.reader(), .cache_limit = options.cache_entries, .cancel = options.cancel };
    defer validator.deinit();
    var converted = try std.DynamicBitSetUnmanaged.initEmpty(allocator, compact_volume);
    defer converted.deinit(allocator);
    var substituted: u32 = 0;
    var invalid = validateAll(&validator, isolated, options) catch |err| switch (err) {
        error.Cancelled => return .cancelled,
        else => return err,
    };
    const queue = try allocator.alloc(u32, target_count);
    defer allocator.free(queue);
    if (invalid != null and original_reinforced) {
        var count: usize = 0;
        // Highest original reinforced seeds first; each conversion appends the
        // immediate support and therefore records a single downward provenance.
        var i = cells.len;
        while (i > 0) {
            i -= 1;
            if (cells[i].isReinforced()) {
                queue[count] = @intCast(i);
                count += 1;
            }
        }
        var cursor: usize = 0;
        while (cursor < count) : (cursor += 1) {
            if (options.cancelled()) return .cancelled;
            const conflict = validator.reinforcedSupportConflict(isolated.position(queue[cursor]));
            if (validator.allocation_failed) return error.OutOfMemory;
            const support = conflict orelse continue;
            const index = isolated.indexOf(support) orelse continue;
            if (cells[index] != .crushed_stone) continue;
            cells[index] = .reinforced_concrete;
            converted.set(index);
            substituted += 1;
            validator.invalidate();
            std.debug.assert(count < queue.len);
            queue[count] = @intCast(index);
            count += 1;
        }
        validator.invalidate();
        invalid = validateAll(&validator, isolated, options) catch |err| switch (err) {
            error.Cancelled => return .cancelled,
            else => return err,
        };
    }
    if (invalid) |rejected| return .{ .invalid = structuralDiagnostics(isolated, rejected.index, rejected.failure, low, converted) };
    // Directed face-connected readiness; same-level cycles cannot root themselves.
    var reached = try std.DynamicBitSetUnmanaged.initEmpty(allocator, compact_volume);
    defer reached.deinit(allocator);
    var count: usize = 0;
    for (cells[0 .. @as(usize, size[0]) * size[1]], 0..) |material, index| {
        if (material != .none) {
            reached.set(index);
            queue[count] = @intCast(index);
            count += 1;
        }
    }
    var cursor: usize = 0;
    while (cursor < count) : (cursor += 1) {
        if (cursor & 255 == 0 and options.cancelled()) return .cancelled;
        const index = queue[cursor];
        const position = isolated.position(index);
        const neighbors = directions ++ [_]rules.Cell{.{ 0, 0, 1 }};
        for (neighbors, 0..) |direction, edge| {
            const next = isolated.indexOf(position + direction) orelse continue;
            if (cells[next] == .none or reached.isSet(next)) continue;
            if (edge < 4 and !eligibleHorizontalSupport(cells[next], cells[index])) continue;
            reached.set(next);
            queue[count] = @intCast(next);
            count += 1;
        }
    }
    if (count != target_count) {
        var diagnostic: Diagnostics = .{ .code = .unassemblable };
        for (cells, 0..) |material, i| if (material != .none and !reached.isSet(i)) diagnostic.add(sourceCell(size, i, low));
        return .{ .invalid = diagnostic };
    }
    own_cells = false;
    return .{ .valid = .{ .definition = .{ .size = size, .cells = cells, .target_count = target_count }, .source_offset = low, .substituted_count = substituted } };
}

fn compileTest(size: Size, cells: []const BlockType) !CompileResult {
    return compile(std.testing.allocator, .{ .size = size, .cells = cells }, .{ .horizontal_limit = 32767 });
}

test "compiler normalizes all source contents and compacts immutable x-fastest definitions" {
    var source = [_]BlockType{.none} ** 27;
    source[13] = .stone;
    var result = try compileTest(.{ 3, 3, 3 }, &source);
    try std.testing.expect(result == .valid);
    defer result.valid.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(Size{ 1, 1, 1 }, result.valid.definition.size);
    try std.testing.expectEqualDeep(LocalCell{ 1, 1, 1 }, result.valid.source_offset);
    try std.testing.expectEqual(BlockType.crushed_stone, result.valid.definition.cells[0]);
    source[13] = .none;
    try std.testing.expectEqual(BlockType.crushed_stone, result.valid.definition.cells[0]);
    try result.valid.definition.validateWellFormed(32767, default_max_cells);
    var copy = try result.valid.definition.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(BlockType, result.valid.definition.cells, copy.cells);
    for ([_]BlockType{ .dirt, .grass, .packed_dirt }) |earth| {
        var normalized_earth = try compileTest(.{ 1, 1, 1 }, &.{earth});
        defer normalized_earth.valid.deinit(std.testing.allocator);
        try std.testing.expectEqual(BlockType.dirt, normalized_earth.valid.definition.cells[0]);
    }
}

test "raw shape and unsupported contents reject before empty layers could rescue a selection" {
    const oversized = try compile(std.testing.allocator, .{ .size = .{ 32, 1, 1 }, .cells = &.{} }, .{ .horizontal_limit = 31 });
    try std.testing.expectEqual(DiagnosticCode.horizontal_limit, oversized.invalid.code);
    const budget = try compile(std.testing.allocator, .{ .size = .{ 100, 100, 32 }, .cells = &.{} }, .{ .horizontal_limit = 32767, .max_cells = 319999 });
    try std.testing.expectEqual(DiagnosticCode.budget_exceeded, budget.invalid.code);
    try std.testing.expectEqual(DiagnosticCode.empty, (try compileTest(.{ 1, 1, 1 }, &.{.none})).invalid.code);
    for ([_]BlockType{ .leaves, .metal_ore, .limestone, .coal, .clay, .deeprock, .water, .snow, .country_road_adaptive, .custom }) |material| {
        const result = try compileTest(.{ 1, 1, 1 }, &.{material});
        try std.testing.expectEqual(DiagnosticCode.invalid_contents, result.invalid.code);
        try std.testing.expectEqualDeep(LocalCell{ 0, 0, 0 }, result.invalid.highlights[0]);
    }
}

test "six stone cells pass and seven reject without introducing reinforced material" {
    var six = try compileTest(.{ 1, 1, 6 }, &([_]BlockType{.stone} ** 6));
    try std.testing.expect(six == .valid);
    defer six.valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), six.valid.substituted_count);
    const seven = try compileTest(.{ 1, 1, 7 }, &([_]BlockType{.stone} ** 7));
    try std.testing.expectEqual(rules.Reason.crushed_column, seven.invalid.failure.?.reason);
    try std.testing.expectEqual(@as(u32, 7), seven.invalid.actual);
    try std.testing.expectEqual(@as(u16, 7), seven.invalid.highlight_count);
}

test "reinforced conflict permits only its necessary downward concrete cascade" {
    var source = [_]BlockType{.stone} ** 8;
    source[7] = .rebar;
    var result = try compileTest(.{ 1, 1, 8 }, &source);
    try std.testing.expect(result == .valid);
    defer result.valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), result.valid.substituted_count);
    for (result.valid.definition.cells[0..7]) |material| try std.testing.expectEqual(BlockType.reinforced_concrete, material);
    try std.testing.expectEqual(BlockType.rebar, result.valid.definition.cells[7]);
    try std.testing.expectEqual(BlockType.stone, source[0]);
    var unrelated = [_]BlockType{.none} ** 21;
    for (0..7) |z| unrelated[z * 3] = .stone;
    unrelated[2] = .rebar;
    const rejected = try compileTest(.{ 3, 1, 7 }, &unrelated);
    try std.testing.expectEqual(rules.Reason.crushed_column, rejected.invalid.failure.?.reason);
}

test "valid platforms and independent lateral routes perform no concrete substitutions" {
    var source = [_]BlockType{.none} ** 8;
    source[0] = .crushed_stone;
    source[1] = .rebar;
    source[2] = .rebar;
    source[3] = .reinforced_concrete;
    // Two 2-cell columns: right reinforced column gives legal lateral support
    // above the left crushed cell without constructing a full platform.
    var lateral = try compileTest(.{ 2, 1, 2 }, source[0..4]);
    try std.testing.expect(lateral == .valid);
    defer lateral.valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), lateral.valid.substituted_count);
    try std.testing.expectEqual(BlockType.crushed_stone, lateral.valid.definition.cells[0]);
    var platform = [_]BlockType{.crushed_stone} ** 36;
    @memset(platform[27..], .none);
    platform[31] = .rebar;
    var supported = try compileTest(.{ 3, 3, 4 }, &platform);
    try std.testing.expect(supported == .valid);
    defer supported.valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), supported.valid.substituted_count);
}

test "conversion inherits mineral height 20 and prioritizes low supports at height 21" {
    var source = [_]BlockType{.stone} ** 21;
    source[19] = .rebar;
    var twenty = try compileTest(.{ 1, 1, 20 }, source[0..20]);
    try std.testing.expect(twenty == .valid);
    defer twenty.valid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 19), twenty.valid.substituted_count);
    source[19] = .stone;
    source[20] = .rebar;
    const twenty_one = try compileTest(.{ 1, 1, 21 }, &source);
    try std.testing.expect(twenty_one == .invalid);
    try std.testing.expectEqual(rules.Reason.mineral_height, twenty_one.invalid.failure.?.reason);
    try std.testing.expectEqual(@as(u32, 21), twenty_one.invalid.actual);
    try std.testing.expectEqual(@as(u32, 20), twenty_one.invalid.limit);
    try std.testing.expectEqualDeep(LocalCell{ 0, 0, 0 }, twenty_one.invalid.highlights[0]);
    try std.testing.expectEqualDeep(LocalCell{ 0, 0, 1 }, twenty_one.invalid.highlights[1]);
}

test "only the globally lowest occupied layer receives a virtual foundation" {
    const result = try compileTest(.{ 3, 1, 2 }, &.{ .tree_trunk, .none, .none, .none, .none, .tree_trunk });
    try std.testing.expect(result == .invalid);
    try std.testing.expectEqual(rules.Reason.missing_foundation, result.invalid.failure.?.reason);
    try std.testing.expectEqualDeep(LocalCell{ 2, 0, 1 }, result.invalid.highlights[0]);
}

test "quarter turns preserve dense target identity and well-formedness rejects malformed arrays" {
    const size: Size = .{ 2, 3, 1 };
    var cell: LocalCell = .{ 1, 2, 0 };
    var rotated = size;
    for (0..4) |_| {
        cell = rotatedCell(rotated, cell, 1);
        rotated = rotatedSize(rotated, 1);
    }
    try std.testing.expectEqualDeep(LocalCell{ 1, 2, 0 }, cell);
    try std.testing.expectEqualDeep(size, rotated);
    try std.testing.expectEqualDeep(LocalCell{ 2, 0, 0 }, rotatedCell(size, cell, 1));
    const wrong_count: Definition = .{ .size = .{ 1, 1, 1 }, .cells = &.{.dirt}, .target_count = 2 };
    try std.testing.expectError(error.TargetCount, wrong_count.validateWellFormed(31, 100));
    const outer_air: Definition = .{ .size = .{ 2, 1, 1 }, .cells = &.{ .dirt, .none }, .target_count = 1 };
    try std.testing.expectError(error.NotCompact, outer_air.validateWellFormed(31, 100));
    const unnormalized: Definition = .{ .size = .{ 1, 1, 1 }, .cells = &.{.stone}, .target_count = 1 };
    try std.testing.expectError(error.InvalidContents, unnormalized.validateWellFormed(31, 100));
}

test "fulfillment uses at most five physical reads and shared directed material rules" {
    const Physical = struct {
        reads: usize = 0,
        below: ?BlockType = .none,
        neighbors: [4]?BlockType = .{ .none, .none, .none, .none },

        fn read(context: *anyopaque, cell: [3]u32) ?BlockType {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.reads += 1;
            if (cell[2] == 9) return self.below;
            if (cell[0] == 11) return self.neighbors[0];
            if (cell[0] == 9) return self.neighbors[1];
            if (cell[1] == 11) return self.neighbors[2];
            return self.neighbors[3];
        }
    };
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    var physical: Physical = .{};
    const reader: rules.Reader = .{ .layout = &layout, .context = &physical, .block_at = Physical.read };
    try std.testing.expect(!checkFulfillment(reader, .{ 10, 10, 10 }, .planks));
    try std.testing.expectEqual(@as(usize, 5), physical.reads);
    physical.reads = 0;
    physical.below = .water;
    try std.testing.expect(checkFulfillment(reader, .{ 10, 10, 10 }, .planks));
    try std.testing.expectEqual(@as(usize, 1), physical.reads);
    physical.below = .none;
    for ([_]BlockType{ .stone, .metal_ore, .limestone, .coal, .deeprock }) |rock| {
        physical.reads = 0;
        physical.neighbors = .{ .none, .none, .none, rock };
        try std.testing.expect(checkFulfillment(reader, .{ 10, 10, 10 }, .crushed_stone));
        try std.testing.expectEqual(@as(usize, 5), physical.reads);
    }
    physical.neighbors = .{ .none, .none, .none, .rebar };
    try std.testing.expect(checkFulfillment(reader, .{ 10, 10, 10 }, .reinforced_concrete));
    try std.testing.expect(!checkFulfillment(reader, .{ 10, 10, 10 }, .crushed_stone));
    try std.testing.expect(materialMatches(.dirt, .grass));
    try std.testing.expect(!materialMatches(.rebar, .reinforced_concrete));
    physical.below = null;
    try std.testing.expect(!checkFulfillment(reader, .{ 10, 10, 10 }, .reinforced_concrete));
}

test "cancelled compilation releases allocations without publishing a candidate" {
    var token = std.atomic.Value(bool).init(true);
    const result = try compile(std.testing.allocator, .{ .size = .{ 1, 1, 1 }, .cells = &.{.rebar} }, .{ .horizontal_limit = 31, .cancel = &token });
    try std.testing.expect(result == .cancelled);
}

test "isolated virtual platforms agree across qualifying materials and never wrap geometry" {
    var cells = [_]BlockType{.rebar} ** 20;
    var isolated = Isolated.init(.{ 1, 1, 20 }, &cells);
    for ([_]BlockType{ .stone, .dirt, .packed_dirt, .grass, .clay, .crushed_stone, .reinforced_concrete }) |material| {
        isolated.virtual_material = material;
        var validator: rules.Validator = .{ .allocator = std.testing.allocator, .reader = isolated.reader() };
        defer validator.deinit();
        for (0..20) |i| try std.testing.expect(validator.checkExisting(isolated.position(i)) == null);
    }
    const reader = isolated.reader();
    try std.testing.expect(!reader.periodic_x);
    try std.testing.expectEqual(@as(u64, 100), reader.distance(.{ -50, 0, 0 }, .{ 50, 0, 0 }));
    try std.testing.expect(reader.normalize(.{ -1, 0, 0 }) == null);
}

fn allocationFailureFixture(allocator: std.mem.Allocator) !void {
    var source = [_]BlockType{.stone} ** 8;
    source[7] = .rebar;
    var result = try compile(allocator, .{ .size = .{ 1, 1, 8 }, .cells = &source }, .{ .horizontal_limit = 31 });
    if (result != .valid) return error.TestUnexpectedResult;
    defer result.valid.deinit(allocator);
}

test "every compiler allocation failure frees partial normalization cascade and queue state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureFixture, .{});
}

test "cancellation after helper allocations frees detached contents cache and cascade state" {
    const CancellingAllocator = struct {
        token: *std.atomic.Value(bool),
        trigger: usize,
        calls: usize = 0,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }

        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const result = std.testing.allocator.rawAlloc(len, alignment, ra) orelse return null;
            self.calls += 1;
            if (self.calls == self.trigger) self.token.store(true, .release);
            return result;
        }

        fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
            return std.testing.allocator.rawResize(memory, alignment, len, ra);
        }

        fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawRemap(memory, alignment, len, ra);
        }

        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ra);
        }
    };
    var source = [_]BlockType{.stone} ** 8;
    source[7] = .rebar;
    for (1..5) |trigger| {
        var token = std.atomic.Value(bool).init(false);
        var cancelling: CancellingAllocator = .{ .token = &token, .trigger = trigger };
        const result = try compile(cancelling.allocator(), .{ .size = .{ 1, 1, 8 }, .cells = &source }, .{ .horizontal_limit = 31, .cancel = &token });
        try std.testing.expect(result == .cancelled);
    }
}

test {
    _ = @import("blueprint_admission.zig");
    _ = @import("blueprint_road_updates.zig");
}
