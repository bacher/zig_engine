---
service: zig_engine
created: 2026-10-17
status: draft
---

# Budget world residency and prioritize player access under memory pressure

## Intent
Keep the game responsive by limiting memory growth before allocation failure or sustained
paging occurs. Prioritize chunks needed by players, throttle simulation-driven residency
earlier, and explain degraded operation to players. Plan this as the next feature after the
first version of [world persistence](world-persistence.md); no implementation is authorized
during the current planning discussion.

## Context
World chunks are loaded for player proximity and simulation operations, including their
terrain-validation dependencies. The current application is single-player; the planning
target is up to 16 players, potentially in disjoint regions. Generated and persisted chunks
both consume resources and must pass the same admission policy.

A radius of 2 chunks on each axis gives a 5x5x5 region: 125 chunks per player and 2,000 for
16 disjoint regions. Their 32-KiB block arrays alone occupy 62.5 MiB. Radius 3 gives 7x7x7,
343 per player, 5,488 total, and 171.5 MiB of raw blocks. These are examples, not total-memory
guarantees: metadata, dependency halos, service/client copies, COW versions, caches, meshes,
GPU resources, and queued/in-flight work add costs. Shared regions should deduplicate data.

Persistence permits eviction only after the exact current version is in the installed base
and ownership/gameplay pins clear. Equality of monotonic live and installed-base persistent
revisions establishes reloadability; eviction does not inspect WAL segments or require extra
dirty/pending-WAL checks. Loaded timer-bearing chunks remain pinned initially.
Admission control must prevent indefinite growth when these chunks cannot be evicted.
The temporary demo simulation does not define the future scheduler or deferred-event policy.

## Requirements
- R1: Establish a conservative application memory ceiling using effective physical memory,
  applicable process/container limits where discoverable, and an optional configured cap.
  Leave explicit headroom for the OS, other applications, and untracked overhead. Do not
  equate installed RAM or currently free RAM with memory safely available to the game.
- R2: Observe platform memory-pressure and available-memory signals where supported, plus
  application capacity/usage counters. Reduce new admissions before sustained paging or
  allocation failure; do not wait for swap activity as the only trigger. Define a conservative
  fallback on platforms without useful pressure signals. No promise of preventing all OS
  swapping: other processes and OS policy remain outside application control.
- R3: Maintain distinct player and simulation admission budgets within one shared ceiling.
  Protect capacity for player proximity and required gameplay dependencies; throttle
  simulation loads first. Player priority does not authorize exceeding the global ceiling.
  Support a future target of 16 separated players on machines meeting a measured memory
  requirement; the estimate above does not guarantee that every machine can support it.
- R4: Attribute each load/pin to its player or simulation reason. Deduplicate shared chunks,
  charge physical storage once, and promote effective priority when a player needs a chunk
  also requested by simulation. Removing one reason must not invalidate remaining users.
  Reserve capacity fairly across future players rather than allowing one to consume all
  protected capacity. Exact shares, borrowing, radii, and scheduling policies remain open.
- R5: Reserve estimated bytes and in-flight capacity before generation/read/decode begins.
  Reconcile estimates with validated actual sizes and obtain additional capacity before
  exceeding a reservation. Bound load counts, resident capacity, staging buffers, and request
  queues. Include operation dependencies, transient overlap, and metadata growth; chunk count
  alone is insufficient. Propagate priority to required dependencies.
- R6: At pressure thresholds, pause/defer lower-priority simulation admissions and work first,
  release unused capacity, and evict eligible chunks. Permit earlier saving/compaction to
  make dirty chunks evictable, using bounded working memory. Never discard unsaved versions,
  break ownership pins, or silently abandon pending timers to meet a target.
- R7: If a required player chunk cannot be admitted, notify the player and prevent movement
  into the unavailable region. Missing terrain must not act as empty air or allow falling
  through the world. Enforce the gate at gameplay/collision boundaries, not only through
  visuals. Spawn/teleport requires a safe loaded destination or remains pending/fails safely.
- R8: If simulation cannot obtain required chunks/resources, postpone or cancel the operation
  before partial effects are published. Preserve authoritative ordering and exactly-once
  effects for retries; cancellation must produce an explicit outcome rather than silently
  losing accepted work. Bound deferred work and provide backpressure to producers. Build on
  persistence's local failure contract: retain resource-blocked work/timers without consuming
  them, retry on resource-release signals with a backoff fallback, and avoid per-tick retry loops.
- R9: Show a stable, actionable status when simulation is throttled or player loading is
  blocked by memory pressure. Distinguish memory admission from disk/corruption failures.
  Coalesce notifications and clear/update status after recovery without per-chunk spam.
- R10: Use separate throttle/resume thresholds and recovery delays to avoid oscillation.
  Resume queued work gradually and fairly when headroom returns, without a burst of loads
  immediately recreating pressure. Never change semantic world contents merely to reduce RAM.
- R11: Account for application memory beyond block arrays: metadata/pool capacity, derived
  caches, client replicas, snapshots, persistence catalogs/buffers, meshes, assets, and GPU
  staging/resources as appropriate. Track usage and reservations without double-counting
  shared allocations or unified-memory residency. Include process-level telemetry to expose
  memory outside tracked allocators; CPU and GPU limits may need separate constraints.
- R12: Keep bounded working capacity available for completion/cleanup and persistence progress.
  Stopping admissions must not also prevent releasing resources or processing the completion
  messages needed to recover. If pinned state exceeds a reduced target, stop new growth and
  report degradation; do not attempt unsafe eviction or claim immediate compliance.

## Clarifications
- Q1: Which requests have priority?
  A1: CONFIRMED by the user: player-proximity loads have higher priority and a different
  budget from simulation loads. Simulation may be postponed/throttled sooner with notification.
- Q2: What if a player's required chunk cannot load within budget?
  A2: CONFIRMED by the user: notify the player and prevent entry into unloaded chunk boundaries.
  Simulation operations unable to load dependencies are cancelled/postponed with visible status.
- Q3: When is this implemented?
  A3: CONFIRMED by the user: after initial persistence, as a separate important follow-up.
  Persistence implements local accounting/limits and failure propagation as its foundation;
  this iteration does not include the whole-system controller, priority scheduler, movement
  gating, or simulation-throttling UI.
- Q4: Which numerical limits apply?
  A4: UNRESOLVED: RAM fraction/headroom, configured ceiling, minimum supported machine,
  player/simulation shares, maximum radius, in-flight limits, and pressure hysteresis.
  Propose a conservative RAM-derived startup ceiling capped by configuration/effective
  limits, with runtime pressure reducing admissions. Choose values using representative
  workloads and platform measurements rather than the block-array estimate alone.
- Q5: What happens to simulation time while work is postponed?
  A5: PARTIALLY CONFIRMED: resource-blocked operations remain unapplied and pending in bounded
  state, with producer backpressure and resource-triggered/backoff retries. Timers are consumed
  only on success. Persistence v1 also fixes each terrain-timer pass's tick/eligible-chunk list
  and preserves the existing finite overdue soil-transition chain using current terrain
  (world-persistence.md R47). Newly loaded chunks wait for a later normal pass. Fairness,
  explicit cancellation semantics beyond resource deferral, and generalized overdue-event/
  bounded catch-up versus paused-simulation policies remain unresolved.
  Coordinate with the future scheduled-event
  design; do not accidentally turn resumed work into an unlimited catch-up burst. Existing
  persistence timer residency and offline-time decisions remain unchanged until reviewed.
- Q6: May simulation borrow unused player-reserved capacity?
  A6: UNRESOLVED. Borrowing is safe only if the policy can reclaim the capacity in time;
  dirty/timer-pinned simulation chunks may be non-evictable. Define guarantees before allowing
  borrowing, and define the response when the active player target cannot fit the ceiling.
- Q7: What local allocation-failure behavior is settled during persistence planning?
  A7: CONFIRMED by the user: player edits receive at most one automatic retry after a useful
  snapshot handoff, then explicit rejection and optimistic reconciliation; rejected edits
  are not silently replayed. Simulation work is deferred as described in Q5. Distinguish
  budget exhaustion, allocator failure, and invalid requests. Reserve completion/status
  resources before accepting work. See world-persistence.md R38-R40; player chunk-load
  movement gating is a separate follow-up behavior, not implied by edit rejection alone.

## Acceptance Criteria
- AC1: GIVEN supported memory limits and configuration WHEN initializing budgets THEN the
  effective ceiling leaves defined headroom and never exceeds applicable caps. Unsupported
  pressure APIs select the documented fallback rather than disabling limits.
- AC2: GIVEN pressure or a nearly exhausted budget WHEN player and simulation loads compete
  THEN simulation is throttled first and protected player capacity remains available, while
  all admissions respect the shared ceiling and in-flight reservations.
- AC3: GIVEN overlapping player/simulation requests WHEN reasons change THEN shared chunk
  storage is charged once and effective priority/pins reflect all remaining reasons.
- AC4: GIVEN a player load refused for memory WHEN movement/spawn/teleport reaches unavailable
  terrain THEN entry is prevented safely and a memory-related loading status is visible.
- AC5: GIVEN a simulation operation lacking required chunk capacity WHEN admission fails THEN
  no partial effects are published, the operation is deferred or explicitly cancelled,
  queues remain bounded, and players receive coalesced throttling status.
- AC6: GIVEN capacity returns after pressure WHEN resuming work THEN hysteresis and paced
  scheduling prevent rapid throttle/resume oscillation and an unbounded catch-up burst.
- AC7: GIVEN dirty, timer-pinned, snapshot-owned, or in-flight chunks WHEN the target shrinks
  THEN no correctness pin or durable-state requirement is violated and growth is restricted
  while safe reclamation/persistence progress remains possible.
- AC8: GIVEN disjoint regions for 16 modeled players WHEN exercising the agreed supported
  radius and memory envelope THEN player access meets its measured residency/latency target;
  undersized configurations degrade explicitly rather than overrunning memory unchecked.
- AC9: GIVEN pool slack, COW duplication, meshes, and queued reads WHEN measuring pressure
  THEN accounting includes their reserved/backing capacity without double-counting shared
  storage and exposes untracked process memory separately.

## Constraints
The OS can reclaim/page application memory; budgets reduce risk rather than guarantee zero
swap. Free-memory sampling is advisory and racy, not a reservation from the OS. Avoid locking
large world allocations into physical memory as the default solution. Preserve persistence
atomicity, base-only reloads, and the initial timer-pin policy. Budget restrictions must not
silently alter terrain, lose edits, or turn missing data into generated/empty substitutes.

## Out of Scope
Implementation during current planning; the complete feature in persistence v1; multiplayer
networking; a new simulation/scheduled-event system; unconditional support for 16 players on
every machine; guaranteeing no OS paging; replacing world data with lossy representations.

## Plan
Provisional follow-up design; exact policies and limits remain open.

### Approach
1. Measure representative process/CPU/GPU usage, including 16 disjoint player regions,
   simulation bursts, heavy metadata, COW, slow storage, and pinned chunks.
2. Introduce platform memory observations and a configurable conservative budget controller.
3. Add reason-aware chunk admission, byte reservations, player protection, and bounded queues.
4. Integrate safe residency reclamation and persistence feedback; retain working headroom.
5. Add player movement/load gating, simulation deferral, and coalesced status reporting.
6. Validate pressure/recovery behavior and choose defaults from measured requirements.

### Persistence v1 Boundary
Persistence first supplies bounded COW/metadata/encoding storage, capacity counters,
structured allocation/cancellation failures, safe ownership release, persistence status,
and pressure-triggered early checkpoint/compaction. It also implements the local mutation
failure contract: bounded player-edit retry/rejection with optimistic reconciliation and
concise status, bounded simulation deferral/backpressure, pending-timer preservation, and
completion/status capacity reserved before accepting work. Global scheduling and richer
throttling UI remain here. Keep those limits configurable and
their interfaces usable by a later controller. This is not yet a process-wide RAM ceiling
or an assurance that resident world data cannot cause pressure. The follow-up feature adds
system-derived limits and prevents producers from admitting more work than can be supported.
Preserve persistence's asynchronous operation stages and resolved-command checkpoint/save
barriers (world-persistence.md R41-R43): deferred or I/O-waiting work is not completed merely
because it left a queue. Budget scheduling must not bypass those ordering contracts.
Persistence's confirmed parameter-tuning plan (world-persistence.md R66/Q40) selects local
pool/queue defaults and latency thresholds from measurements. Reuse its capacity counters,
workloads, and fault-injection tests here; its experimental memory values are not global
RAM ceilings or preallocation requirements. System-derived budgets and admission priorities
remain the responsibility of this follow-up.

### Affected Components
- `src/voxel_app/world_data_service.zig`: reason-aware admission, reservations, dependencies,
  residency/eviction, and structured failures.
- Player control/streaming: proximity demand, movement gating, and safe destinations.
- Future simulation scheduler: deferral, cancellation, fairness, and producer backpressure.
- Persistence coordinator/pools: accounting, pressure requests, and reclaimable-version feedback.
- Engine allocators/rendering: asset, mesh, GPU/staging accounting and bounded work queues.
- Platform/UI integration: memory-pressure observations and degradation status.

### Risks
Fixed chunk-count limits understate dynamic costs. Player requests may depend on more chunks
than their visible region. Dirty/timer-pinned chunks may prevent reclamation indefinitely;
admission must react before reaching that condition. Low memory can coincide with slow
storage, so compaction alone cannot guarantee rapid recovery. Lowering a target cannot
instantly reclaim existing allocations. Incorrect cache-absence handling can break collision.

## Tasks
Provisional work after initial persistence; these do not authorize implementation now.

- [ ] T1: Resolve limits, player guarantees, borrowing, pressure thresholds, and simulation timing.
- [ ] T2: Implement platform observations, accounting, and the budget controller.
- [ ] T3: Integrate prioritized admission/reservations, bounded queues, and safe reclamation.
- [ ] T4: Implement safe player gating, simulation deferral, and status reporting.
- [ ] T-val: Exercise acceptance criteria with simulated pressure and representative load tests;
  document supported memory envelopes and platform limitations.
