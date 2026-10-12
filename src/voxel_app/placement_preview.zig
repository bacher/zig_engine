//! Presentation of the shared, non-mutating placement validation result.
const std = @import("std");
const engine = @import("engine");
const rules = @import("block_rules.zig");
const world = @import("world.zig");
const outline = engine.block_outline;
const coordinates = @import("block_coordinates.zig");

pub const allowed_color: @Vector(4, f32) = .{ 0.1, 0.8, 1, 0.65 };
pub const rejected_color: @Vector(4, f32) = .{ 1, 0.15, 0.1, 0.7 };
pub const problem_color: @Vector(4, f32) = .{ 1, 0.65, 0.1, 0.65 };

pub const Preview = struct {
    block: [3]u32,
    material: rules.BlockType,
    result: world.EditResult,
    overlaps_player: bool = false,

    pub fn overlays(self: Preview, contents: *const world.World) outline.Overlays {
        var hints: outline.Overlays = .{};
        const candidate: rules.Cell = .{ self.block[0], self.block[1], self.block[2] };
        hints.add(.{ .cell = candidate, .color = if (self.overlaps_player or self.result.status != .success) rejected_color else allowed_color });
        if (!self.overlaps_player) if (self.result.failure) |failure| {
            addProblem(&hints, contents, failure.subject);
            for (failure.involved[0..failure.involved_count]) |cell| addProblem(&hints, contents, cell);
        };
        return hints;
    }

    pub fn print(self: Preview) void {
        std.debug.print("placement preview: {s} at {any}: ", .{ @tagName(self.material), self.block });
        if (self.overlaps_player) {
            std.debug.print("the block overlaps the player's body\n", .{});
        } else if (self.result.failure) |failure| {
            printFailure(failure);
        } else {
            std.debug.print("{s}\n", .{if (self.result.status == .success) "allowed" else @tagName(self.result.status)});
        }
    }
};

fn addProblem(hints: *outline.Overlays, contents: *const world.World, cell: rules.Cell) void {
    var normalized = cell;
    normalized[0] = @mod(normalized[0], contents.layout.size_in_blocks[0]);
    if (hints.contains(normalized)) return;
    const occupied = if (coordinates.fromStorage(contents.layout, normalized)) |block|
        contents.isBlockSolid(block) catch false
    else
        false;
    hints.add(.{ .cell = normalized, .color = problem_color, .occupied = occupied });
}

pub fn description(reason: rules.Reason) []const u8 {
    return switch (reason) {
        .material_not_placeable => "this material cannot be placed",
        .missing_data => "support cannot be checked: required world cells have not loaded",
        .earth_footprint => "soil requires a filled 3x3 support layer below it",
        .earth_requires_stable_platform => "building on soil requires a filled 3x3x3 platform below the block",
        .incompatible_support => "the material below cannot support this block",
        .missing_foundation => "a suitable foundation is missing",
        .horizontal_span => "horizontal distance from a supported block exceeds the limit",
        .wood_height => "wood height above its foundation exceeds the limit",
        .mineral_height => "mineral construction height above its foundation exceeds the limit",
        .crushed_column => "too many consecutive crushed-stone blocks",
        .would_remove_support => "removal would leave an existing construction unsupported",
        .would_invalidate_structure => "placement would make an existing construction invalid",
        .support_search_limit => "support cannot be proved within the allowed search radius",
    };
}

pub fn printFailure(failure: rules.Failure) void {
    std.debug.print("{s} ({s}) at {any}", .{ description(failure.reason), @tagName(failure.reason), failure.subject });
    if (failure.cause) |cause| std.debug.print("; cause: {s} ({s})", .{ description(cause), @tagName(cause) });
    if (failure.limit != 0) std.debug.print("; actual {d}, required/limit {d}", .{ failure.actual, failure.limit });
    if (failure.truncated) std.debug.print("; showing the first {d} problem cells", .{failure.involved_count});
    std.debug.print("\n", .{});
}

test "diagnostic overlays deduplicate wrapped cells and preserve missing cells outside finite bounds" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    var contents = try world.World.init(std.testing.allocator, &layout);
    defer contents.deinit();
    const failure: rules.Failure = .{
        .reason = .would_invalidate_structure,
        .cause = .earth_footprint,
        .subject = .{ 0, 1, 0 },
        .involved = blk: {
            var cells: [32]rules.Cell = @splat(@splat(0));
            cells[0] = .{ -1, 0, -1 };
            cells[1] = .{ 63, 0, -1 };
            cells[2] = .{ 0, 0, 0 };
            cells[3] = .{ 0, 1, 0 };
            break :blk cells;
        },
        .involved_count = 4,
    };
    const preview: Preview = .{ .block = .{ 0, 0, 0 }, .material = .dirt, .result = .{ .status = .constraint_violation, .failure = failure } };
    const hints = preview.overlays(&contents);
    try std.testing.expectEqual(3, hints.count);
    try std.testing.expectEqualDeep(rejected_color, hints.cells[0].color);
    try std.testing.expectEqualDeep(rules.Cell{ 0, 1, 0 }, hints.cells[1].cell);
    try std.testing.expectEqualDeep(rules.Cell{ 63, 0, -1 }, hints.cells[2].cell);
}

test "full truncated diagnostics fit alongside the ghost and affected construction" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    var contents = try world.World.init(std.testing.allocator, &layout);
    defer contents.deinit();
    var failure: rules.Failure = .{ .reason = .horizontal_span, .subject = .{ 0, 1, 2 }, .involved_count = 32, .truncated = true };
    for (&failure.involved, 0..) |*cell, i| cell.* = .{ @intCast(i), 0, 1 };
    const preview: Preview = .{ .block = .{ 0, 1, 1 }, .material = .planks, .result = .{ .status = .constraint_violation, .failure = failure } };
    try std.testing.expectEqual(34, preview.overlays(&contents).count);
}

test "only received occupied diagnostic cells request surface depth correction" {
    const layout = try engine.WorldLayout.init(.{ .size_in_chunks = .{ 2, 2, 2 } });
    var contents = try world.World.init(std.testing.allocator, &layout);
    defer contents.deinit();
    try contents.insertChunk(.{ 0, 0, 0 }, world.WorldChunk.initEmpty());
    try contents.insertChunk(.{ 1, 0, 0 }, world.WorldChunk.initEmpty());
    contents.setBlockUnchecked(.{ 1, 0, 0 }, .stone);
    contents.setBlockUnchecked(.{ 63, 0, 0 }, .stone);
    var failure: rules.Failure = .{ .reason = .missing_foundation, .subject = .{ 1, 0, 0 }, .involved_count = 5 };
    failure.involved[0] = .{ 2, 0, 0 }; // Received air.
    failure.involved[1] = .{ 0, 32, 0 }; // Unknown chunk.
    failure.involved[2] = .{ 0, -1, 0 }; // Finite y boundary.
    failure.involved[3] = .{ 0, 0, -1 }; // Finite z boundary.
    failure.involved[4] = .{ -1, 0, 0 }; // Wrapped occupied cell.
    const preview: Preview = .{ .block = .{ 0, 0, 0 }, .material = .dirt, .result = .{ .status = .constraint_violation, .failure = failure } };
    const hints = preview.overlays(&contents);
    try std.testing.expectEqual(7, hints.count);
    try std.testing.expect(!hints.cells[0].occupied); // The candidate remains a ghost.
    try std.testing.expect(hints.cells[1].occupied);
    for (hints.cells[2..6]) |hint| try std.testing.expect(!hint.occupied);
    try std.testing.expect(hints.cells[6].occupied);
}
