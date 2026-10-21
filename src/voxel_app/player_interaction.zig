//! One carried block and one timed/authoritative transfer at a time.
const std = @import("std");
const world = @import("world.zig");
const OperationResult = @import("world_data_service.zig").OperationResult;
const BlockType = @import("engine").voxel_chunk.BlockType;

pub const extraction_seconds: f64 = 3;
pub const placement_seconds: f64 = 1;
pub const Source = enum { key, mouse };

pub const Interaction = struct {
    inventory: ?BlockType = null,
    holding: ?Hold = null,
    pending: ?struct { request_id: ?u64 = null, resolved: bool = false } = null,
    requested: ?Source = null,
    key_down: bool = false,
    mouse_down: bool = false,

    pub const Hold = struct {
        source: Source,
        operation: world.BlockOperation,
        material: BlockType,
        elapsed: f64 = 0,

        pub fn duration(self: Hold) f64 {
            return if (self.operation.action == .remove) extraction_seconds else placement_seconds;
        }
    };

    pub fn press(self: *Interaction, source: Source) void {
        const was_down = self.key_down or self.mouse_down;
        switch (source) {
            .key => self.key_down = true,
            .mouse => self.mouse_down = true,
        }
        // Both controls must be released before a fresh action can start. A press
        // while waiting for authority is consumed, never queued for later.
        if (!was_down and self.pending == null and self.holding == null) self.requested = source;
    }

    pub fn release(self: *Interaction, source: Source) void {
        switch (source) {
            .key => self.key_down = false,
            .mouse => self.mouse_down = false,
        }
        if (self.requested == source) self.requested = null;
        if (self.holding) |hold| if (hold.source == source) {
            self.holding = null;
        };
    }

    /// Finish a local attempt. Only a successful terrain edit predicts a transfer.
    pub fn completePrediction(self: *Interaction, result: world.EditResult) void {
        std.debug.assert(self.pending == null);
        const hold = self.holding.?;
        self.holding = null;
        if (result.status != .success) return;
        self.inventory = if (hold.operation.action == .remove) result.mined_type.? else null;
        self.pending = .{};
    }

    /// Admission failures leave the prediction intact; call only after admission.
    pub fn markSubmitted(self: *Interaction, request_id: u64) void {
        const pending = &self.pending.?;
        std.debug.assert(pending.request_id == null and !pending.resolved);
        pending.request_id = request_id;
    }

    /// Returns whether this result belongs to the current transfer. Terrain may
    /// still need a later rebase if rolling back a rejected edit ran out of memory.
    pub fn acknowledge(self: *Interaction, player_id: u64, result: OperationResult) bool {
        const pending = if (self.pending) |*pending| pending else return false;
        if (pending.request_id != result.request_id) return false;
        if (result.player_inventory) |inventory| if (inventory.player_id == player_id) {
            self.inventory = inventory.material;
        };
        pending.resolved = true;
        return true;
    }

    /// Release the action gate only after both authority and terrain have settled.
    pub fn finishReconciliation(self: *Interaction, operations: []const world.PendingOperation) void {
        const pending = self.pending orelse return;
        if (!pending.resolved) return;
        for (operations) |operation| {
            if (operation.request_id == pending.request_id) return;
        }
        self.pending = null;
    }

    pub fn cancelHold(self: *Interaction) void {
        self.holding = null;
        self.requested = null;
    }

    pub fn loseFocus(self: *Interaction) void {
        self.cancelHold();
        self.key_down = false;
        self.mouse_down = false;
    }
};

test "release cancels even between frames and switching controls cannot extend a hold" {
    var interaction: Interaction = .{};
    interaction.press(.key);
    try std.testing.expectEqual(Source.key, interaction.requested.?);
    interaction.holding = .{ .source = .key, .operation = .{ .block = .{ 0, 0, 0 }, .action = .remove }, .material = .stone, .elapsed = 2.9 };
    interaction.requested = null;
    interaction.press(.mouse);
    interaction.release(.key);
    try std.testing.expectEqual(null, interaction.holding);
    interaction.press(.key);
    try std.testing.expectEqual(null, interaction.requested);
    interaction.release(.key);
    interaction.release(.mouse);
    interaction.press(.mouse);
    try std.testing.expectEqual(Source.mouse, interaction.requested.?);
}

test "presses during acknowledgement wait are consumed and focus loss preserves pending inventory" {
    var interaction: Interaction = .{ .inventory = .dirt, .pending = .{} };
    interaction.press(.key);
    try std.testing.expectEqual(null, interaction.requested);
    interaction.pending = null;
    interaction.press(.key);
    try std.testing.expectEqual(null, interaction.requested);
    interaction.release(.key);
    interaction.press(.key);
    try std.testing.expect(interaction.requested != null);
    interaction.pending = .{};
    interaction.loseFocus();
    try std.testing.expectEqual(null, interaction.requested);
    try std.testing.expect(interaction.pending != null);
    try std.testing.expectEqual(BlockType.dirt, interaction.inventory.?);
}

test "completing a local attempt predicts inventory only when the terrain edit succeeds" {
    for ([_]bool{ false, true }) |placing| {
        for ([_]world.OperationStatus{ .success, .constraint_violation }) |status| {
            const before: ?BlockType = if (placing) .sand else null;
            var interaction: Interaction = .{
                .inventory = before,
                .key_down = true,
                .holding = .{
                    .source = .key,
                    .operation = .{ .block = .{ 1, 2, 3 }, .action = if (placing) .{ .put = .sand } else .remove },
                    .material = if (placing) .none else .stone,
                },
            };
            interaction.completePrediction(.{ .status = status, .mined_type = if (status == .success and !placing) .crushed_stone else null });
            try std.testing.expectEqual(null, interaction.holding);
            try std.testing.expectEqual(status == .success, interaction.pending != null);
            const predicted: ?BlockType = if (placing) null else .crushed_stone;
            try std.testing.expectEqual(if (status == .success) predicted else before, interaction.inventory);
            // Completion must not turn a continued hold into another action.
            interaction.press(.key);
            try std.testing.expectEqual(null, interaction.requested);
        }
    }
}

test "prediction survives admission retries and unrelated acknowledgements" {
    var interaction: Interaction = .{
        .holding = .{ .source = .key, .operation = .{ .block = .{ 1, 2, 3 }, .action = .remove }, .material = .stone },
    };
    interaction.completePrediction(.{ .status = .success, .mined_type = .crushed_stone });
    for (0..3) |attempt| {
        // Failed admission assigns no ID and leaves the prediction waiting.
        if (attempt == 2) interaction.markSubmitted(7);
        interaction.release(.key);
        interaction.press(.key);
        interaction.finishReconciliation(&.{});
        try std.testing.expectEqual(null, interaction.requested);
        try std.testing.expectEqual(if (attempt == 2) @as(?u64, 7) else null, interaction.pending.?.request_id);
        try std.testing.expect(!interaction.acknowledge(1, .{
            .request_id = if (attempt == 2) 8 else 7,
            .status = .success,
            .player_inventory = .{ .player_id = 1, .material = null },
        }));
        try std.testing.expectEqual(BlockType.crushed_stone, interaction.inventory.?);
        try std.testing.expect(!interaction.pending.?.resolved);
    }
}

test "accepted and rejected transfers wait for terrain reconciliation and a fresh press" {
    for ([_]bool{ false, true }) |placing| {
        for ([_]bool{ false, true }) |accepted| {
            const before: ?BlockType = if (placing) .sand else null;
            const operation: world.BlockOperation = .{ .block = .{ 1, 2, 3 }, .action = if (placing) .{ .put = .sand } else .remove };
            var interaction: Interaction = .{
                .inventory = before,
                .holding = .{ .source = .key, .operation = operation, .material = if (placing) .none else .stone },
            };
            interaction.completePrediction(.{ .status = .success, .mined_type = if (placing) null else .crushed_stone });
            const authoritative = if (accepted) interaction.inventory else before;
            interaction.markSubmitted(7);
            try std.testing.expect(interaction.acknowledge(1, .{
                .request_id = 7,
                .status = if (accepted) .success else .constraint_violation,
                .player_inventory = .{ .player_id = 1, .material = authoritative },
            }));
            try std.testing.expectEqual(authoritative, interaction.inventory);
            const operations = [_]world.PendingOperation{.{ .operation = operation, .request_id = 7 }};
            interaction.finishReconciliation(&operations);
            try std.testing.expect(interaction.pending.?.resolved);
            interaction.press(.mouse);
            try std.testing.expectEqual(null, interaction.requested);
            // Once the terrain record retires, unrelated edits cannot hold this gate.
            const unrelated = [_]world.PendingOperation{.{ .operation = operation, .request_id = 8 }};
            interaction.finishReconciliation(&unrelated);
            try std.testing.expectEqual(null, interaction.pending);
            interaction.press(.mouse);
            try std.testing.expectEqual(null, interaction.requested);
            interaction.release(.mouse);
            interaction.press(.mouse);
            try std.testing.expectEqual(Source.mouse, interaction.requested.?);
        }
    }
}

test "acknowledgements without this player's inventory preserve the predicted slot" {
    for ([_]bool{ false, true }) |has_other_inventory| {
        var interaction: Interaction = .{ .inventory = .sand, .pending = .{} };
        interaction.markSubmitted(7);
        var result: OperationResult = .{ .request_id = 7, .status = .success };
        if (has_other_inventory) result.player_inventory = .{ .player_id = 2, .material = .snow };
        try std.testing.expect(interaction.acknowledge(1, result));
        try std.testing.expectEqual(BlockType.sand, interaction.inventory.?);
        interaction.finishReconciliation(&.{});
        try std.testing.expectEqual(null, interaction.pending);
        try std.testing.expect(!interaction.acknowledge(1, result));
    }
}
