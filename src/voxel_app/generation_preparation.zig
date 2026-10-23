pub const FailureCategory = enum { none, unsupported_generator, invalid_configuration, candidate_rejected, preparation_aborted, seed_rejected };
pub const FailureReason = enum { none, invalid_layout, invalid_climate_widths, invalid_coast_bounds, infeasible_capacity, topology_conflict, required_feature_placement, feature_index_capacity, deposit_validity, start_access_unavailable, allocation_failed, cancelled, work_budget_exceeded, memory_budget_exceeded, internal_invariant_failure };
pub const PreparationStage = enum { preflight, geography, deposits, first_start, vegetation, complete };
pub const RejectionDetail = struct { reason: FailureReason = .none, stage: PreparationStage = .preflight, observed: u64 = 0, limit: u64 = 0 };
pub const PreparationReport = struct {
    generator_id: u32 = 2,
    generator_version: u32 = 1,
    profile: enum { natural, flat, legacy_terrain } = .natural,
    seed: u64 = 0,
    category: FailureCategory = .none,
    reason: FailureReason = .none,
    stage: PreparationStage = .preflight,
    attempts_started: u8 = 0,
    candidates_rejected: u8 = 0,
    selected_attempt: ?u8 = null,
    rejections: [8]FailureReason = @splat(.none),
    rejection_details: [8]RejectionDetail = @splat(.{}),
    peak_owned_bytes: usize = 0,
    feature_references: usize = 0,
    max_bin_occupancy: usize = 0,
    observed: u64 = 0,
    limit: u64 = 0,
    work_units: u64 = 0,
};
pub const PrepareError = error{ InvalidLayout, InvalidClimateWidths, InvalidCoastBounds, InfeasibleCapacity, SeedRejected, OutOfMemory, Cancelled, WorkBudgetExceeded, MemoryBudgetExceeded, InternalInvariantFailure };

pub const PrepareOptions = struct {
    memory_budget: usize = 32 * 1024 * 1024,
    work_budget: u64 = 250_000_000,
    cancellation_context: ?*anyopaque = null,
    is_cancelled: ?*const fn (?*anyopaque) bool = null,
    /// Deterministic diagnostic injection exercises the real bounded retry path.
    reject_first_candidates: u8 = 0,
    injected_rejection: FailureReason = .topology_conflict,
    abort_at_attempt: ?u8 = null,
    injected_abort: FailureReason = .work_budget_exceeded,
};
