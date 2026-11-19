//! Warehouse dialog and input lifetimes. The modal never owns the world clock.
const std = @import("std");
const commands = @import("warehouse_commands.zig");
const layout = @import("warehouse_layout.zig");
const interaction = @import("player_interaction.zig");
const BlockType = @import("engine").voxel_chunk.BlockType;
pub const transfer_seconds: f64 = 0.1;
pub const materials = [_]BlockType{ .dirt, .sand, .snow, .crushed_stone, .tree_trunk, .planks, .rebar, .reinforced_concrete, .country_road_solid, .country_road_adaptive, .pallet };
pub const Tool = struct {
    pub const Dialog = union(enum) {
        creation: struct { aim_cell: layout.Cell, geometry: layout.Geometry, material: BlockType = .dirt },
        management: commands.Identity,
    };
    pub const Hold = struct {
        source: interaction.Source,
        identity: commands.Identity,
        aim_cell: layout.Cell,
        material: BlockType,
        putting: bool,
        elapsed: f64 = 0,
    };
    dialog: ?Dialog = null,
    hold: ?Hold = null,
    pending_dialog: ?u64 = null,
    pending_dialog_closed: bool = false,
    pending_player: ?u64 = null,
    pending_player_sequence: ?u64 = null,
    inventory_fence: u64 = 0,
    selected_material: BlockType = .dirt,
    active_columns: i32 = 0,
    error_message: ?[]const u8 = null,

    pub fn close(self: *Tool) void {
        self.dialog = null;
        self.hold = null;
        // Retain command ownership without letting its late result reopen this
        // modal or replace a different dialog opened afterward.
        if (self.pending_dialog != null) self.pending_dialog_closed = true;
        self.error_message = null;
    }

    pub fn release(self: *Tool, source: interaction.Source) void {
        if (self.hold) |hold| if (hold.source == source) {
            self.hold = null;
        };
    }

    /// Only a snapshot including the pending warehouse command can replace its
    /// carried prediction. Ordinary transfers keep their existing result path.
    pub fn rebaseInventory(self: *Tool, snapshot: @import("warehouse_stream.zig").Snapshot, player_id: u64, carried: *interaction.Interaction) void {
        const sequence = self.pending_player_sequence orelse return;
        if (self.pending_player == null or snapshot.resolved_sequence < sequence or snapshot.resolved_sequence < self.inventory_fence) return;
        if (snapshot.player_inventory) |inventory| if (inventory.player_id == player_id) {
            carried.inventory = inventory.material;
            self.inventory_fence = snapshot.resolved_sequence;
        };
    }

    /// Mode/focus changes never transfer result ownership to an observer edit.
    pub fn acknowledgePlayer(self: *Tool, result: commands.Result, player_id: u64, carried: *interaction.Interaction) bool {
        if (self.pending_player != result.request_id) return false;
        if (result.resolved_sequence >= self.inventory_fence) {
            if (result.player_inventory) |inventory| if (inventory.player_id == player_id) {
                carried.inventory = inventory.material;
            };
        }
        carried.pending = null;
        self.pending_player = null;
        self.pending_player_sequence = null;
        return true;
    }

    pub fn cancelHold(self: *Tool) void {
        self.hold = null;
    }
};

pub fn message(reason: commands.Rejection) []const u8 {
    return switch (reason) {
        .wrong_material, .inventory_mismatch => "The held material does not match this warehouse.",
        .empty => "This warehouse is empty.",
        .full => "No unreserved active capacity remains.",
        .out_of_reach => "Warehouse is out of reach.",
        .missing_data => "Waiting for warehouse or terrain data.",
        .invalid_registration => "This warehouse registration is no longer available.",
        .invalid_material => "This material cannot be stored in a warehouse.",
        .invalid_base => "Warehouses require a complete rectangular pallet base, up to 5 by 5.",
        .invalid_support => "Every pallet requires a supported solid floor.",
        .obstructed => "The warehouse needs a clear one-cell border and six cargo levels.",
        .conflicting_claim => "This area is reserved by another structure.",
        .enabled => "Stop automatic work first.",
        .obligations => "Wait for accepted work and deliveries to finish.",
        .not_empty => "Empty the warehouse first.",
        .invalid_capacity => "Choose a valid number of active columns.",
        .busy => "The world is busy. Try again shortly.",
        .invalid_actor => "The current viewpoint is unavailable.",
    };
}

test "warehouse release and modal close cancel holds without losing pending result ownership" {
    var tool: Tool = .{ .pending_player = 9, .pending_dialog = 10 };
    tool.hold = .{ .source = .key, .identity = .{ .kind = .warehouse, .world_session = 1, .id = 1, .lifetime = 1 }, .aim_cell = .{ 1, 1, 1 }, .material = .dirt, .putting = false };
    tool.release(.mouse);
    try std.testing.expect(tool.hold != null);
    tool.release(.key);
    try std.testing.expect(tool.hold == null);
    tool.close();
    try std.testing.expectEqual(@as(?u64, 9), tool.pending_player);
    try std.testing.expectEqual(@as(?u64, 10), tool.pending_dialog);
    try std.testing.expect(tool.pending_dialog_closed);
}

test "warehouse observer and duplicate results cannot replace another player transfer inventory" {
    var carried: interaction.Interaction = .{ .inventory = .sand, .pending = .{ .request_id = 3 } };
    var tool: Tool = .{ .pending_player = 3 };
    // Closing the modal or switching to observer retains the player result gate.
    tool.close();
    try std.testing.expect(!tool.acknowledgePlayer(.{ .request_id = 4, .status = .success, .player_inventory = .{ .player_id = 1, .material = .dirt } }, 1, &carried));
    try std.testing.expectEqual(BlockType.sand, carried.inventory.?);
    try std.testing.expect(carried.pending != null);
    const resolved: commands.Result = .{ .request_id = 3, .status = .success, .player_inventory = .{ .player_id = 1, .material = .planks } };
    try std.testing.expect(tool.acknowledgePlayer(resolved, 1, &carried));
    carried.inventory = .snow;
    try std.testing.expect(!tool.acknowledgePlayer(resolved, 1, &carried));
    try std.testing.expectEqual(BlockType.snow, carried.inventory.?);
}

test "warehouse inventory snapshot fence preserves coherent stock cut before a late result" {
    var carried: interaction.Interaction = .{ .inventory = null, .pending = .{ .request_id = 3 } };
    var tool: Tool = .{ .pending_player = 3, .pending_player_sequence = 3 };
    var snapshot: @import("warehouse_stream.zig").Snapshot = .{ .identity = undefined, .record = undefined, .subscription_id = 7, .resolved_sequence = 2, .player_inventory = .{ .player_id = 1, .material = .sand } };
    tool.rebaseInventory(snapshot, 1, &carried);
    try std.testing.expect(carried.inventory == null);
    snapshot.resolved_sequence = 4;
    snapshot.player_inventory.?.material = .planks;
    tool.rebaseInventory(snapshot, 1, &carried);
    try std.testing.expectEqual(BlockType.planks, carried.inventory.?);
    try std.testing.expect(tool.pending_player != null);
    try std.testing.expect(tool.acknowledgePlayer(.{ .request_id = 3, .status = .success, .resolved_sequence = 3, .player_inventory = .{ .player_id = 1, .material = null } }, 1, &carried));
    try std.testing.expectEqual(BlockType.planks, carried.inventory.?);
}
