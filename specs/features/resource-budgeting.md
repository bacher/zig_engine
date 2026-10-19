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

The user targets approximately 10,000 active chunks and 2,000-4,000 distinct changed chunks
per 60-second save interval on a 16 GB machine, with smaller worlds on 8 GB machines. See
world-persistence.md R74 for the measurement contract. Raw active block storage is 312.5 MiB;
a normal interval's raw block payloads are 62.5-125 MiB. Neither estimate includes metadata,
rendering/client copies or inactive dirty chunks and timer/operation pins, nor establishes
a safe RAM cap.

A radius of 2 chunks on each axis gives a 5x5x5 region: 125 chunks per player and 2,000 for
16 disjoint regions. Their 32-KiB block arrays alone occupy 62.5 MiB. Radius 3 gives 7x7x7,
343 per player, 5,488 total, and 171.5 MiB of raw blocks. These are examples, not total-memory
guarantees: metadata, dependency halos, service/client copies, capture output, caches, meshes,
GPU resources, and queued/in-flight work add costs. Persistence v1 no longer uses COW;
source pins retain existing live storage rather than duplicating it. Shared regions should
deduplicate data.

Persistence permits eviction only after the exact current version is in the installed base
and ownership/gameplay pins clear. Equality of monotonic live and installed-base persistent
revisions establishes reloadability; eviction does not inspect WAL segments or require extra
dirty/pending-WAL checks. Under persistence R77, explicitly lazy pending timers alone do
not pin a chunk; pending non-lazy kinds and active operation/ownership pins still retain it.
Admission control must prevent indefinite growth when these chunks cannot be evicted.
For example, retaining 100 additional distinct materialized chunks per second for ten minutes
without reclamation adds about 1.83 GiB of block arrays alone; this counts net retained chunks,
not repeated edits to the same chunks. Metadata and other storage add to it. Measure retained
world capacity and age separately from capture-output memory before attributing growth to
allocator overhead. Early compaction can help, but installation of an older revision does
not make a newer live version evictable.
The temporary demo simulation does not define the future scheduler or actor-state schema.

The planned workload is approximately 99.9% simulation-initiated chunk updates: players guide
the simulation and cannot directly cause massive changes. Couriers span chunks, workers
consume inputs at benches, and builders follow blueprints; none are implemented here. Treat
this ratio as a planning assumption, not an admission or worst-case capacity guarantee.
Simulation runs in the service process; player interaction must also work over a wire.

CONFIRMED on 2026-10-19: persistence starts without COW, pauses all simulation during capture,
and keeps conflicting player edits pending while prioritizing their sources, with safe capture
cancellation after a bounded wait in normal mode. The user also confirms eventual priority
for save completion and an exceptional visible pause of world-changing actions, including
player edits, with responsive rendering/camera/UI. Persistence R73 owns this escalation;
normal timeout cancellations must not indefinitely starve saving. Resume on source release,
not disk durability, and catch up against current conditions while retaining logical progress. Exact historical
replay is not required. This supersedes the earlier COW baseline and the previously open
catch-up-versus-paused-progress policy. Concrete catch-up scheduling/actor state, numerical
limits, and later near-player continuation remain proposals or future design work. Unaffected
budget and persistence decisions remain in force.

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
  requirement; the estimates above do not guarantee that every machine can support it.
  Evaluate the persistence R74 workload on 16 GB and measured smaller worlds on 8 GB;
  support for 16 separated players still depends on the measured complete workload.
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
- R8: If simulation cannot obtain required chunks/resources or capture admission, postpone
  or explicitly cancel the operation before partial effects are published. Preserve required
  authoritative order and at-most-once effects for retries; explicit cancellation must not silently lose accepted
  work. Bound retained work and apply producer backpressure. Retain resource-blocked events
  without consuming them and use release notifications/backoff instead of per-tick retry loops.
  Preserve logical progress compactly and catch up against current conditions; do not allocate
  one queued job per skipped tick or silently drop debt to meet a queue limit. Processing
  capacity must exceed incoming work to guarantee eventual catch-up; report increasing lag
  under sustained overload. Future NPC state/scheduling remains separately designed.
- R9: Show a stable, actionable status when simulation is throttled or player loading is
  blocked by memory pressure. Distinguish memory admission from disk/corruption failures.
  Coalesce notifications and clear/update status after recovery without per-chunk spam.
- R10: Use separate throttle/resume thresholds and recovery delays to avoid oscillation.
  Resume queued work gradually and fairly when headroom returns, without a burst of loads
  immediately recreating pressure. Never change semantic world contents merely to reduce RAM.
- R11: Account for memory beyond block arrays: metadata backing capacity, derived caches,
  client replicas, capture manifests/output, persistence catalogs/buffers, meshes, assets,
  and GPU staging/resources as appropriate. Count a frozen source as existing live storage
  with a pin, not a second allocation; count independent encoded output and temporary growth
  separately. Track usage/reservations without double-counting shared or unified-memory
  residency. Account for known allocator overhead and distinguish unmeasured overhead/
  fragmentation from tracked capacities; leave headroom and expose process telemetry for
  untracked memory. Custom persistence pools are deferred. CPU/GPU limits may differ.
  If selective COW is later adopted, account for its actual duplicate storage explicitly.
- R12: Keep bounded working capacity available for completion/cleanup and persistence progress.
  Stopping admissions must not also prevent releasing resources or processing the completion
  messages needed to recover. If pinned state exceeds a reduced target, stop new growth and
  report degradation; do not attempt unsafe eviction or claim immediate compliance.

- R13: Keep producer identity distinct from spatial priority. A nearby simulation operation
  is still simulation; admission and reservations cover its full dependency/write footprint.
  A player-proximity priority boost does not authorize allocating outside budgets or adding
  COW for distant dependencies. Preserve whole-operation atomicity across near/far boundaries.
- R14: Reuse persistence's minimum capture gate, pending-player outcomes, source-release
  notifications, epoch/revision identities, capacity counters, and stress traces. This feature
  adds system-wide admission/pressure policy rather than redefining the capture boundary or
  holding simulation until WAL durability. Capture wait and memory-pressure wait remain
  distinct reasons; resumption clears only the reasons actually resolved. Reuse persistence
  R73's overdue-save priority and visible exceptional pause. Save priority does not raise
  memory limits or itself keep gameplay paused after source release; actual pressure can
  independently require admission backpressure.

## Clarifications

- Q1: Which requests have priority?
  A1: CONFIRMED by the user: player-proximity loads have higher priority and a different
  budget from simulation loads. Simulation may be postponed/throttled sooner with notification.
- Q2: What if a player's required chunk cannot load within budget?
  A2: CONFIRMED by the user: notify the player and prevent entry into unloaded chunk boundaries.
  Simulation operations unable to load dependencies are cancelled/postponed with visible status.
- Q3: When is this implemented?
  A3: RETAINED: whole-system budgeting follows initial persistence. Persistence supplies
  local limits/accounting, failure propagation, and the selected minimal capture pause/
  player-encoding priority. This follow-up adds the global controller, general residency
  priorities, movement gating, and richer simulation-throttling UI. It does not delay the
  capture-related pause/resume and player-pending contract needed for persistence correctness.
- Q4: Which numerical limits apply?
  A4: CONFIRMED targets: 16 GB for the persistence R74 workload and smaller worlds on 8 GB.
  UNRESOLVED: RAM fraction/headroom, configured ceiling, measured supported world sizes,
  player/simulation shares, maximum radius, in-flight limits, and pressure hysteresis.
  Propose a conservative RAM-derived startup ceiling capped by configuration/effective
  limits, with runtime pressure reducing admissions. Choose values using representative
  workloads and platform measurements rather than the block-array estimate alone.
- Q5: What happens to simulation time while work is postponed?
  A5: REVISED/CONFIRMED: preserve logical progress and catch up against current conditions,
  without exact historical replay. Retain bounded pending/event state with backpressure;
  consume timers/inputs only on successful application. Persistence v1 pauses all simulation
  for capture and preserves the fixed terrain-timer pass and finite overdue chain in
  world-persistence.md R47. Newly loaded chunks wait for a later normal pass. Pace resumed
  work and retain debt rather than creating an unlimited burst or silently discarding time.
  General NPC progress representation, conservation/eligibility rules, and fair scheduling
  remain future simulation work; persistence must cover that state when introduced. The user
  explicitly defers economic event ordering across postponed work to the simulation spec;
  current-conditions catch-up alone does not guarantee unchanged economic outcomes. Timer
  residency now follows persistence R77's all-lazy exception; no-offline-time policy remains.
- Q6: May simulation borrow unused player-reserved capacity?
  A6: UNRESOLVED. Borrowing is safe only if the policy can reclaim the capacity in time;
  dirty simulation chunks or non-lazy/active timer pins may prevent eviction. Define guarantees
  before allowing borrowing, and define the response when the active player target cannot
  fit the ceiling.
- Q7: What local failure and waiting behavior is settled during persistence planning?
  A7: RETAINED for actual allocation failure: at most one useful ownership-handoff retry
  for player edits, then explicit rejection and optimistic reconciliation; no silent replay.
  REVISED: ordinary capture contention is nonterminal pending work, with priority encoding
  and normally an elapsed limit followed by safe cancellation, not a terminal rejection
  per retry. CONFIRMED exception: persistence R73 may visibly pause world-changing actions
  and continue an overdue save past normal wait limits; memory bounds and UI responsiveness
  still apply, and failed storage is reported rather than treated as successful saving.
  Simulation dispatch pauses during capture, retains progress, and resumes with backpressure.
  Distinguish capture contention, budget exhaustion, allocator failure, and invalid requests.
  Reserve completion/status resources before admission. See world-persistence.md R38-R41
  and R67-R74. Player movement gating on failed loads remains a separate follow-up behavior.

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
- AC7: GIVEN dirty chunks or chunks held by non-lazy timers, snapshots, or active operations
  WHEN the target shrinks THEN no correctness pin or durable-state requirement is violated,
  and growth is restricted while safe reclamation/persistence progress remains possible. All-lazy timers
  alone do not block reclamation once exact-base equality and other pin conditions permit it.
- AC8: GIVEN disjoint regions for 16 modeled players WHEN exercising the agreed supported
  radius and memory envelope THEN player access meets its measured residency/latency target;
  undersized configurations degrade explicitly rather than overrunning memory unchecked.
- AC9: GIVEN spare allocation capacity, frozen sources, encoded output, meshes, and queued
  reads WHEN measuring pressure THEN backing/reserved capacity is accounted for without charging live
  source pins twice; actual COW duplicates are charged only if a later policy creates them.
  Known allocator overhead and unmeasured overhead/fragmentation are identified separately
  alongside process telemetry; tracked capacity is not presented as exact process residency.
- AC10: GIVEN capture and memory pressure both defer simulation WHEN capture sources clear
  THEN the capture/exceptional-saving-pause reason clears independently of WAL durability,
  even while save priority remains active. Remaining pressure gates still apply; resumption
  preserves logical progress and paced backpressure.
- AC11: GIVEN a multi-chunk operation crossing player-priority regions WHEN some dependencies
  lack admission THEN the whole operation remains unapplied, no distant COW is introduced,
  and source/priority hints cannot bypass final service-authorized admission.

## Constraints

The OS can reclaim/page application memory; budgets reduce risk rather than guarantee zero
swap. Free-memory sampling is advisory and racy, not a reservation from the OS. Avoid locking
large world allocations into physical memory as the default solution. Preserve persistence
atomicity, base-only reloads, and persistence R77's timer-kind eligibility. Budget restrictions must not
silently alter terrain, lose edits, or turn missing data into generated/empty substitutes.

## Out of Scope

Implementation during current planning; the complete feature in persistence v1; multiplayer
networking; a new simulation/scheduled-event system; unconditional support for 16 players on
every machine; guaranteeing no OS paging; replacing world data with lossy representations.

## Plan

Provisional follow-up design; exact policies and limits remain open.

### Approach

1. Measure representative process/CPU/GPU usage, including 16 disjoint player regions,
   simulation bursts, catch-up debt, heavy metadata, capture output, slow storage, and pinned
   chunks. Include COW only as a separately identified future policy experiment.
2. Introduce platform memory observations and a configurable conservative budget controller.
3. Add reason-aware chunk admission, byte reservations, player protection, and bounded queues.
4. Integrate safe residency reclamation and persistence feedback; retain working headroom.
5. Add player movement/load gating, simulation deferral, and coalesced status reporting.
6. Validate pressure/recovery behavior and choose defaults from measured requirements.

### Persistence v1 Boundary

Persistence first supplies bounded metadata/encoding storage, capture-output/manifest limits,
capacity counters, structured failures, safe source release, status, and early save/compaction.
It also supplies the minimal all-simulation capture gate, pending player requests, priority
encoding, normal elapsed-wait cancellation, overdue-save escalation with visible exceptional
pause, bounded queues, paced resume, and the existing genuine
allocation-failure retry/rejection policy. Existing allocators supply block/metadata storage
with capacity accounting; custom pools are deferred until measurements justify them. No
persistence COW is implemented in this baseline.

Whole-system pressure observation, protected player residency budgets, movement gating, and
richer throttling UI remain here. Local limits do not establish a process-wide RAM ceiling;
removing COW does not bound dirty world growth, non-lazy/active timer pins, client replicas,
or encoded output. All-lazy timers can unload only once their current version is base-backed
and other pins clear; their absence from the residency map does not consume their events.
Keep source pins, pending mutations, and independent output distinct in accounting. Preserve
working capacity for completion/cleanup even when ordinary admissions stop.

Preserve persistence's explicit operation stages and resolved-command checkpoint/save barriers
(world-persistence.md R41-R43/R71): a pending or I/O-waiting command is not complete merely
because it left a queue or received a status response. Gate simulation dispatch without
blocking completion processing. Readiness notifications are advisory; admission still checks
current ownership and the complete write set. A future in-process direct mutation API needs
an explicit exclusive ownership/publication contract and is not implied by shared memory.

Reuse persistence's R66 workload matrix, measured limits, reference-model harness, and traceable
stress scenarios. Include distinct-chunk simulation churn, stalled output, moving/disjoint
players, cross-chunk work, catch-up debt, repeated cancellation and save-priority completion
under finite slow I/O. Include the R74 16 GB target and measured smaller 8 GB worlds.
Experimental memory values are not global RAM ceilings or preallocation requirements. Numeric limits, fairness,
borrowing, proximity policy, and future actor-state design remain open as identified above.

### Affected Components

- `src/voxel_app/world_data_service.zig`: reason-aware admission, reservations, dependencies,
  residency/eviction, and structured failures.
- Player control/streaming: proximity demand, movement gating, and safe destinations.
- Future simulation scheduler: deferral, cancellation, fairness, and producer backpressure.
- Persistence coordinator/allocation paths: accounting, pressure requests, and reclaimable-version feedback.
- Engine allocators/rendering: asset, mesh, GPU/staging accounting and bounded work queues.
- Platform/UI integration: memory-pressure observations and degradation status.

### Risks

Fixed chunk-count limits understate dynamic costs. Player requests may depend on more chunks
than their visible region. Dirty chunks and non-lazy timer pins may prevent reclamation
indefinitely; admission must react before reaching that condition. Low memory can coincide with slow
storage, so compaction alone cannot guarantee rapid recovery. Lowering a target cannot
instantly reclaim existing allocations. Incorrect cache-absence handling can break collision.

## Tasks

Provisional work after initial persistence; these do not authorize implementation now.

- [ ] T1: Resolve limits, player guarantees, borrowing, pressure thresholds, and paced
  catch-up scheduling under the confirmed current-conditions policy.
- [ ] T2: Implement platform observations, accounting, and the budget controller.
- [ ] T3: Integrate prioritized admission/reservations, bounded queues, and safe reclamation.
- [ ] T4: Implement safe player gating, simulation deferral, and status reporting.
- [ ] T-val: Exercise acceptance criteria with simulated pressure and representative load tests;
  document supported memory envelopes and platform limitations.
