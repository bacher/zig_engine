const zone = @import("extraction_zone.zig");
const CommandIdentity = @import("construction_state.zig").CommandIdentity;

pub const Registration = struct {
    bounds: zone.Bounds,
    filter: zone.Filter,
};

pub const Status = enum {
    success,
    invalid_bounds,
    empty_filter,
    cell_budget,
    chunk_budget,
    overlap,
    missing_data,
    resource_exhausted,
};

pub const Result = struct {
    request_id: u64,
    command: ?CommandIdentity = null,
    status: Status,
    zone_id: ?u64 = null,
};
