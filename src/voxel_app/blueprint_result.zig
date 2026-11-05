//! Value-owned blueprint request outcomes shared by authority and tools.
const rules = @import("block_rules.zig");
pub const RejectCode = enum { invalid_definition, bounds, overlap, occupied, immutable, missing_data, foundation, composition, budget_exceeded };
pub const Rejection = struct {
    code: RejectCode,
    cell: ?[3]u32 = null,
    failure: ?rules.Failure = null,
};
pub const Result = struct {
    request_id: u64,
    kind: enum { save, apply },
    status: enum { success, invalid, missing_data, resource_exhausted, stale },
    definition_id: ?u64 = null,
    instance_id: ?u64 = null,
    rejection: ?Rejection = null,
};
