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
pub const message_capacity = 512;
pub const player_overlap_message = "The block overlaps the player's body.";

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

    pub fn errorMessage(self: Preview, buffer: *[message_capacity]u8) ?[]const u8 {
        if (self.overlaps_player) return player_overlap_message;
        return errorMessageForResult(self.result, buffer);
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
        .material_not_placeable => "This material cannot be placed.",
        .missing_data => "Support cannot be checked: required world cells have not loaded.",
        .earth_footprint => "Soil requires a filled 3x3 support layer below it.",
        .earth_requires_stable_platform => "Building on soil requires a filled 3x3x3 platform below the block.",
        .incompatible_support => "The material below cannot support this block.",
        .missing_foundation => "A suitable foundation is missing.",
        .horizontal_span => "Horizontal distance from a supported block exceeds the limit.",
        .wood_height => "Wood height above its foundation exceeds the limit.",
        .mineral_height => "Mineral construction height above its foundation exceeds the limit.",
        .crushed_column => "Too many consecutive crushed-stone blocks.",
        .would_remove_support => "Removal would leave an existing construction unsupported.",
        .would_invalidate_structure => "Placement would make an existing construction invalid.",
        .support_search_limit => "Support cannot be proved within the allowed search radius.",
    };
}

pub fn errorMessageForResult(result: world.EditResult, buffer: *[message_capacity]u8) ?[]const u8 {
    if (result.status == .success) return null;
    if (result.failure) |failure| {
        var writer = std.Io.Writer.fixed(buffer);
        writer.writeAll(description(failure.reason)) catch unreachable;
        if (failure.cause) |cause| writer.print("\nCause: {s}", .{description(cause)}) catch unreachable;
        if (failure.limit != 0) writer.print("\nActual: {d}; required/limit: {d}.", .{ failure.actual, failure.limit }) catch unreachable;
        if (failure.truncated) writer.print("\nShowing the first {d} problem cells.", .{failure.involved_count}) catch unreachable;
        return writer.buffered();
    }
    return switch (result.status) {
        .success => unreachable,
        .already_exists => "This cell is already occupied.",
        .already_removed => "This block has already been removed.",
        .missing_data => "Required world cells have not loaded.",
        .constraint_violation => "The block edit violates construction constraints.",
    };
}

test "error text preserves dependent causes, limits and truncated hints for every reason" {
    var buffer: [message_capacity]u8 = undefined;
    for (std.enums.values(rules.Reason)) |reason| {
        for (std.enums.values(rules.Reason)) |cause| {
            const message = errorMessageForResult(.{ .status = .constraint_violation, .failure = .{
                .reason = reason,
                .cause = cause,
                .subject = .{ 0, 0, 0 },
                .actual = std.math.maxInt(u32),
                .limit = std.math.maxInt(u32),
                .truncated = true,
                .involved_count = 32,
            } }, &buffer).?;
            try std.testing.expect(std.mem.startsWith(u8, message, description(reason)));
            try std.testing.expect(std.mem.indexOf(u8, message, description(cause)) != null);
            try std.testing.expect(std.mem.indexOf(u8, message, "Actual: 4294967295; required/limit: 4294967295.") != null);
            try std.testing.expect(std.mem.endsWith(u8, message, "Showing the first 32 problem cells."));
        }
    }
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
