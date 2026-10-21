//! One carried block and one timed/authoritative transfer at a time.
const std = @import("std");
const world = @import("world.zig");
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
