//! Value-only external warehouse intents and retained outcomes. Automatic work
//! calls simulation state directly and does not allocate a command per item.
const state = @import("warehouse_state.zig");
const rules = @import("block_rules.zig");
const identity = @import("construction_state.zig");
pub const Identity = identity.Identity;
pub const Actor = struct {
    /// Null denotes an observer stock edit; player transfers use the authoritative slot.
    player_id: ?u64 = null,
    viewpoint: [3]f64,
};
pub const Action = union(enum) {
    register: struct { aim_cell: [3]u32, material: rules.BlockType },
    transfer: struct { identity: Identity, aim_cell: [3]u32, material: rules.BlockType, direction: enum { put, take } },
    configure: struct { identity: Identity, active_columns: u8 },
    stop: Identity,
    enable: Identity,
    unregister: Identity,
    material: struct { identity: Identity, material: rules.BlockType },

    pub fn target(self: Action) ?Identity {
        return switch (self) {
            .register => null,
            .transfer => |v| v.identity,
            .configure => |v| v.identity,
            .material => |v| v.identity,
            .stop, .enable, .unregister => |v| v,
        };
    }
};
pub const Payload = struct { actor: Actor, action: Action };
pub const Rejection = enum {
    invalid_registration,
    invalid_material,
    wrong_material,
    empty,
    full,
    inventory_mismatch,
    out_of_reach,
    missing_data,
    invalid_base,
    invalid_support,
    obstructed,
    conflicting_claim,
    enabled,
    obligations,
    not_empty,
    invalid_capacity,
    busy,
    invalid_actor,
};
pub const Result = struct {
    request_id: u64,
    command: ?identity.CommandIdentity = null,
    /// Coherent stock/inventory cut, including this evaluated command. The
    /// acknowledgment/result remains owned until explicitly collected.
    resolved_sequence: u64 = 0,
    status: enum { success, rejected },
    rejection: ?Rejection = null,
    warehouse: ?state.Record = null,
    retired: ?Identity = null,
    player_inventory: ?struct { player_id: u64, material: ?rules.BlockType } = null,
};
