//! The selection, resource checklist, and input edges of the extraction tool.
const std = @import("std");
const zone = @import("extraction_zone.zig");

pub const Draft = struct {
    pub const Stage = enum { inactive, anchor, footprint, depth, ready, resources };
    pub const Issue = enum {
        no_anchor,
        no_endpoint,
        ambiguous_x,
        invalid_bounds,
        cell_budget,
        chunk_budget,
        overflow,

        pub fn message(self: Issue) []const u8 {
            return switch (self) {
                .no_anchor => "Aim at a surface block to choose the first corner.",
                .no_endpoint => "Aim at the ground or across the selection plane.",
                .ambiguous_x => "The selection cannot span exactly half the world.",
                .invalid_bounds => "The extraction box extends outside the world.",
                .cell_budget => "The extraction box exceeds the cell limit.",
                .chunk_budget => "The extraction box exceeds the source chunk limit.",
                .overflow => "The extraction box dimensions are too large to count.",
            };
        }
    };

    pub const pixels_per_block = 12;
    stage: Stage = .inactive,
    generation: u64 = 0,
    budgets: zone.Budgets = .{},
    filter: zone.Filter = .{},
    issue: ?Issue = null,
    target: ?[3]u32 = null,
    anchor: ?[3]u32 = null,
    bounds: ?zone.Bounds = null,
    depth: f64 = 1,

    pub fn enter(self: *Draft) void {
        self.* = .{ .stage = .anchor, .generation = self.generation +% 1, .budgets = self.budgets, .issue = .no_anchor };
    }

    pub fn leave(self: *Draft) void {
        self.* = .{ .generation = self.generation, .budgets = self.budgets };
    }

    pub fn active(self: Draft) bool {
        return self.stage != .inactive;
    }

    pub fn aims(self: Draft) bool {
        return self.stage == .anchor or self.stage == .footprint;
    }

    pub fn updateAnchor(self: *Draft, target: ?[3]u32) void {
        self.target = target;
        self.issue = if (target == null) .no_anchor else null;
    }

    pub fn updateFootprint(self: *Draft, world_size: [3]u32, endpoint: ?[2]i64) void {
        const xy = endpoint orelse {
            self.issue = .no_endpoint;
            return;
        };
        const bounds = zone.Bounds.fromFootprint(world_size, self.anchor.?, xy[0], xy[1], 1) catch |err| {
            self.issue = if (err == error.AmbiguousX) .ambiguous_x else .invalid_bounds;
            return;
        };
        self.issue = budgetIssue(bounds, world_size, self.budgets);
        if (self.issue == null) self.bounds = bounds;
    }

    pub fn adjustDepth(self: *Draft, world_size: [3]u32, vertical_pixels: f64) void {
        const top = self.anchor.?[2];
        const max_depth: f64 = @floatFromInt(@as(u64, top) + 1);
        if (std.math.isFinite(vertical_pixels)) self.depth = std.math.clamp(self.depth + vertical_pixels / pixels_per_block, 1, max_depth);
        const depth: u32 = @intFromFloat(@round(self.depth));
        self.bounds.?.size[2] = depth;
        self.bounds.?.min[2] = top - (depth - 1);
        self.checkBudget(world_size);
    }

    pub fn confirmClick(self: *Draft, world_size: [3]u32) void {
        if (self.issue != null) return;
        switch (self.stage) {
            .anchor => {
                const anchor = self.target orelse return;
                self.anchor = anchor;
                self.stage = .footprint;
                self.updateFootprint(world_size, .{ anchor[0], anchor[1] });
            },
            .footprint => self.stage = .depth,
            .depth => self.stage = .ready,
            else => {},
        }
    }

    pub fn openResources(self: *Draft, world_size: [3]u32) bool {
        if (self.stage != .ready) return false;
        self.checkBudget(world_size);
        if (self.issue != null) return false;
        self.stage = .resources;
        self.filter = .{};
        return true;
    }

    pub fn checkBudget(self: *Draft, world_size: [3]u32) void {
        const bounds = self.bounds orelse return;
        self.issue = budgetIssue(bounds, world_size, self.budgets);
    }

    fn budgetIssue(bounds: zone.Bounds, world_size: [3]u32, budgets: zone.Budgets) ?Issue {
        bounds.validate(world_size, budgets) catch |err| {
            return switch (err) {
                error.InvalidBounds => .invalid_bounds,
                error.CellBudget => .cell_budget,
                error.ChunkBudget => .chunk_budget,
                error.Overflow => .overflow,
            };
        };
        return null;
    }

    pub fn canSubmit(self: Draft) bool {
        return self.stage == .resources and self.issue == null and self.filter.any();
    }
};

test "extraction draft selects both XY directions and adjusts buried depth without a target" {
    const world_size = [3]u32{ 128, 128, 96 };
    var draft: Draft = .{};
    draft.enter();
    draft.updateAnchor(.{ 15, 13, 18 });
    draft.confirmClick(world_size);
    draft.updateFootprint(world_size, .{ 11, 17 });
    draft.confirmClick(world_size);
    try std.testing.expectEqual(.depth, draft.stage);
    try std.testing.expectEqualDeep(zone.Bounds{ .min = .{ 11, 13, 18 }, .size = .{ 5, 5, 1 } }, draft.bounds.?);
    draft.adjustDepth(world_size, 7 * Draft.pixels_per_block);
    try std.testing.expectEqualDeep(zone.Bounds{ .min = .{ 11, 13, 11 }, .size = .{ 5, 5, 8 } }, draft.bounds.?);
    draft.adjustDepth(world_size, -7 * Draft.pixels_per_block);
    try std.testing.expectEqual(@as(u32, 1), draft.bounds.?.size[2]);
    draft.adjustDepth(world_size, 1000);
    try std.testing.expectEqualDeep(zone.Bounds{ .min = .{ 11, 13, 0 }, .size = .{ 5, 5, 19 } }, draft.bounds.?);
}

test "extraction draft retains its previous bounds on a half-period tie" {
    const world_size = [3]u32{ 128, 96, 96 };
    var draft: Draft = .{};
    draft.enter();
    draft.updateAnchor(.{ 127, 20, 30 });
    draft.confirmClick(world_size);
    draft.updateFootprint(world_size, .{ 0, 20 });
    const across_seam = zone.Bounds{ .min = .{ 127, 20, 30 }, .size = .{ 2, 1, 1 } };
    try std.testing.expectEqualDeep(across_seam, draft.bounds.?);
    draft.updateFootprint(world_size, .{ 63, 20 });
    try std.testing.expectEqual(.ambiguous_x, draft.issue.?);
    try std.testing.expectEqualDeep(across_seam, draft.bounds.?);
    draft.confirmClick(world_size);
    try std.testing.expectEqual(.footprint, draft.stage);
    draft.updateFootprint(world_size, .{ 0, 20 });
    draft.confirmClick(world_size);
    try std.testing.expectEqual(.depth, draft.stage);
}

test "extraction draft checks cell and aligned chunk budgets and starts with seven choices" {
    const world_size = [3]u32{ 128, 96, 96 };
    var draft: Draft = .{ .budgets = .{ .max_cells = 2, .max_source_chunks = 2 } };
    draft.enter();
    draft.updateAnchor(.{ 31, 20, 30 });
    draft.confirmClick(world_size);
    draft.budgets.max_source_chunks = 1;
    draft.updateFootprint(world_size, .{ 32, 20 });
    try std.testing.expectEqual(.chunk_budget, draft.issue.?);
    draft.budgets.max_source_chunks = 2;
    draft.updateFootprint(world_size, .{ 33, 20 });
    try std.testing.expectEqual(.cell_budget, draft.issue.?);
    draft.updateFootprint(world_size, .{ 32, 20 });
    try std.testing.expectEqual(null, draft.issue);
    draft.confirmClick(world_size);
    draft.confirmClick(world_size);
    try std.testing.expect(draft.openResources(world_size));
    try std.testing.expect(draft.filter.soil and draft.filter.sand and draft.filter.stone and draft.filter.metal_ore and draft.filter.limestone and draft.filter.coal and draft.filter.clay);
    draft.filter = .{ .soil = false, .sand = false, .stone = false, .metal_ore = false, .limestone = false, .coal = false, .clay = false };
    try std.testing.expect(!draft.canSubmit());
}
