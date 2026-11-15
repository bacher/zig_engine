//! Complete scalar warehouse publications. Terrain discovery carries identity and
//! geometry only; stock is carried exclusively by independent object snapshots.
const state = @import("warehouse_state.zig");
pub const Identity = @import("construction_state.zig").Identity;
pub const Reference = @import("warehouse_claims.zig").Reference;
pub const Snapshot = struct {
    identity: Identity,
    record: state.Record,
    subscription_id: u64,
    /// This endpoint's contiguous evaluated command prefix at publication.
    /// Predictions above it may still be overlaid; earlier ones are included.
    resolved_sequence: u64 = 0,
    player_inventory: ?struct { player_id: u64, material: ?@import("block_rules.zig").BlockType } = null,
};
pub const Update = union(enum) {
    snapshot: Snapshot,
    retired: struct { identity: Identity, subscription_id: u64 },
    unavailable: struct { identity: Identity, subscription_id: u64 },
};
