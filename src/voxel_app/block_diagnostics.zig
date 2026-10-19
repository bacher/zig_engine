//! Shared error text for block previews, local edits, and authoritative rejections.
const std = @import("std");
const rules = @import("block_rules.zig");
const world = @import("world.zig");

pub const message_capacity = 512;
pub const player_overlap_message = "The block overlaps the player's body.";

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
        .road_support => "Each road block requires solid support directly underneath.",
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
        .resource_exhausted => "The world cannot accept this edit yet. Try again shortly.",
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
