---
service: zig_engine
created: 2026-11-08
status: in-progress
---

# Cache and budget construction visuals

## Intent

Cache miniature geometry by chunk so camera movement does not reconstruct or upload
every pending target. Deliver immediate cache updates first, then add a small FIFO
preparation budget to combine repeated changes and limit work started in one frame.

## Context

The client immediately reconciles authoritative blocks, local edits, inventory and
blueprint progress. Main at `b223e01` drains every dirty terrain chunk and rebuilds
camera-relative miniature instances each frame. Full-size application previews already
cache immutable geometry under [blueprint R55](blueprints.md#requirements).

The approved split replaces the original strict terrain/miniature publication policy:
brief missing or overlapping visuals are acceptable while the two representations catch
up. Physics, target identity and resource accounting remain authoritative. The first PR
contains immediate miniature caching; the second adds FIFO, four chunks per update and a
two-millisecond soft preparation budget with no minimum age. Persistent paired staging
is removed from the design.

[Design principles](../../DESIGN_PRINCIPLES.md) favor low client presentation latency
while preserving shared-service throughput and coherent eventual outcomes. Component
measurements support caching and busy-work coalescing; they do not establish whole-game
frame smoothness.

## Requirements

- R1: Keep physics, collision, inventory/resource accounting, target identity, construction
  progress and command reconciliation current through their existing paths. Only visual
  geometry may lag.
- R2: Allow terrain and miniature geometry to update independently. A miniature may briefly
  disappear before its real terrain appears, or overlap older terrain. When changes stop
  and required data/resources become available, both must converge to the latest accepted
  client state; visual mismatch must not alter gameplay state.
- R3: Mark affected loaded chunks at existing edit, snapshot, road-change and blueprint
  application/fulfillment/reconciliation paths. Preserve boundary-dependent terrain
  invalidation. Do not discover changes through a per-frame world, site, target or revision
  scan. Observe only effective committed blueprint publications/fulfillments after fallible
  preflight; no-op replays must not notify visual work.
- R4: In the second PR, keep one pending FIFO item per loaded chunk with expected O(1)
  marking, lookup, cancellation and removal. Remove canceled items immediately. Queue
  storage follows peak simultaneous loaded dirty chunks, rather than travel history.
  The first PR retains immediate dirty-set draining.
- R5: In the second PR, impose no minimum dirty age: work may start in the update that
  marks it. Repeated marks retain a pending item's FIFO position; a new subscription starts
  a fresh lifetime and rejoins the tail. Rebuilding a hot chunk must not starve older work.
- R6: In the second PR, start at most four whole chunk preparations per update and stop
  starting further chunks after two milliseconds of elapsed preparation time. Check time
  between preparations; one chunk may exceed the soft limit. Logical reconciliation and
  terrain uploads remain outside this budget. Neither phase promises a hard frame-time
  bound or maximum visual delay.
- R7: Store miniature sources as compact, camera-independent 16-byte `MiniatureCell`
  records in per-chunk GPU buffers. Camera movement and wrapped coordinate changes update
  transforms without rebuilding/uploading sources. Preserve quarter-size geometry,
  materials, textures, depth and coordinate behavior. Use explicit dirty invalidation:
  unchanged frames and neighbor-only terrain changes reuse sources; accepted byte-identical
  block snapshots may conservatively rebuild their own miniature source.
- R8: Preserve the 1,100,000-cell resident source limit and combined visible-instance limit.
  Retain at most 4,096 nonempty miniature chunks. Replace one chunk synchronously, with at
  most one temporary 32,768-cell replacement: accounted resident plus replacement sources
  must not exceed 1,132,768 records, or 18,124,288 bytes. These bounds exclude transforms,
  bindings, container capacity, other renderer buffers and driver/in-flight overhead.
- R9: Validate source data and reserve fallible metadata before replacing a cached chunk.
  A failed replacement preserves the old source. Publish each miniature replacement inside
  the same client call, independently of terrain upload; expose no prepared handle or
  persistent staged generation. Release every retired owned buffer/binding exactly once
  through the graphics resource lifecycle.
- R10: Preserve the existing terrain extraction, service-mesh acceptance and upload paths
  in the cache PR. Miniature maintenance must run even when terrain uploads cannot fit.
  Do not add a terrain/miniature transaction, retained paired batch or additional streaming
  mesh owner merely to coordinate the two displays.
- R11: Remove dirty/queued miniature work and release cached sources on unload or teardown.
  Validate asynchronous responses against the active subscription; late old responses
  cannot restore evicted cache state. A reload builds from the current logical state.
  Representation handoffs may retain stale visuals temporarily but cannot retain stale
  ownership or prevent later convergence.
- R12: Preserve selection diagnostics, continuous twelve-rail frames, the selected
  capture-only occluded pass and immutable application-preview caching. Their dynamic
  rendering must not scan miniature cells or rebuild cached sources.
- R13: On source allocation/capacity failure, preserve the previous miniature source and
  retain a retryable dirty obligation while the chunk remains loaded. Failure must not
  block unrelated updates or require retaining a paired terrain revision. In the second
  PR, failed work yields to other eligible queued chunks. Convergence requires available
  capacity; sustained limits remain visible through existing render-limit feedback.
- R14: Expose component counters for source builds/uploads/releases, resident occupancy and
  transform/draw work; add queue marks, coalescing, pending peaks, completed work and head
  inspections in the second PR. Label historical scheduling counts, renderer correctness
  checks and component timings separately from full-client performance measurements.

## Clarifications

- Q1: Does delayed rendering delay construction or resource consumption?
  A1: No. Authoritative state and immediate client reconciliation keep their current
  semantics. Terrain and miniature presentation may lag independently.
- Q2: Is two milliseconds a hard frame limit or visual freshness guarantee?
  A2: No. It is a second-PR preparation budget checked between indivisible chunks. Other
  work has separate costs and backlog can increase delay. There is no minimum-age delay.
- Q3: Are nearby chunks prioritized?
  A3: The second PR uses FIFO. Distance sorting, priority queues and per-frame queue scans
  remain deferred until measurements justify them.
- Q4: Is a coherent terrain/miniature revision required per chunk or world-wide?
  A4: No. The approved policy permits brief disagreement in those visual representations.
  GPU resource lifetime, authoritative state and eventual convergence remain required.
- Q5: Is the visual queue durable?
  A5: No. It is rebuilt from streamed client state. Saved construction, materials and
  unfinished simulation work retain their existing persistence protocol.
- Q6: Are invalidated sources compared or fingerprinted?
  A6: No. Explicit dirty hooks may conservatively upload identical cells. Camera-only and
  neighbor-only terrain changes do no source work; no probabilistic equality check is used.

## Acceptance Criteria

- AC1: GIVEN repeated changes to a loaded subscription WHEN the second-PR queue processes
  it THEN one pending item reads the latest view, retains its FIFO position across marks
  and can run in the same update without an age gate.
- AC2: GIVEN busy and quiet loaded chunks with continuing invalidations WHEN budgeted
  updates process work THEN older items progress in FIFO order and a rebuilt hot chunk
  rejoins the tail after its next change.
- AC3: GIVEN more pending chunks than the second-PR frame budget WHEN preparation runs
  THEN at most four preparations start, time is checked between chunks and one complete
  preparation can exceed two milliseconds without exposing a partial miniature source.
- AC4: GIVEN unload, cancellation, subscription replacement or representation handoff
  WHEN stale work/responses arrive THEN they cannot restore an evicted lifetime, canceled
  queue entries occupy no live slots and reload builds current state.
- AC5: GIVEN no dirty invalidations WHEN updates and camera movement continue THEN no
  target/revision/dirty-population scan or miniature source rebuild/upload occurs, and
  visible cached geometry follows camera transforms.
- AC6: GIVEN fulfillment whose terrain upload is delayed WHEN miniature maintenance runs
  and matching terrain later arrives THEN the miniature may advance independently,
  logical state stays correct and both displays eventually represent the latest state.
- AC7: GIVEN repeated miniature changes including an empty result WHEN dirty sources are
  rebuilt THEN the cache uses the latest reconciled cells, empty chunks release their
  source and no obsolete replacement remains owned after the synchronous call.
- AC8: GIVEN dense sources and a replacement WHEN replacement, failure, unload or teardown
  runs THEN resident/chunk/transient bounds hold, failed replacement preserves the old
  source and all retired resources are released exactly once.
- AC9: GIVEN identical dynamic and cached miniature scenes WHEN production color/depth
  readbacks cover wrapping modes, seams, antipodes and signed camera limits THEN materials,
  quarter-size placement, textures and depth agree, and diagnostics/previews/rails retain
  their behavior.
- AC10: GIVEN local edits, accepted/rejected replies, blueprint publications/fulfillments
  and mesh/block handoffs WHEN reconciliation completes THEN logical state stays correct,
  affected miniature chunks become dirty and converge, neighbor-only terrain changes reuse
  sources and no-op blueprint replays emit no visual notification.
- AC11: GIVEN allocation failure or miniature capacity pressure WHEN source replacement
  fails THEN the old source stays valid, current work remains retryable, terrain handling
  continues independently and unrelated dirty chunks can progress.
- AC12: GIVEN 8,192 invalidations over four edit frames touching 128 or 343 chunks WHEN the
  second-PR queue fixture drains and then handles 1,024 idle frames THEN at most four builds
  start per frame, occupancy stays within the chunk population, repeated changes coalesce
  and idle head inspections stay zero; report these as queue counts, not game throughput.

## Constraints

Preserve blueprint validation, five-neighbor fulfillment, immediate resource accounting,
physics, prediction/replay order, save formats and scene coordinates. Use the client thread
and existing graphics ownership; add no worker, copied world snapshot or global revision
polling. Cache ownership and second-PR queue storage must remain bounded independently.
GPU resource retirement is mandatory even though visual pairing is relaxed.

## Out of Scope

Strict terrain/miniature pairing, persistent prepared GPU generations, upload-capacity
transactions, new service-mesh staging, mandatory dirty age, NPC/economy scheduling,
authoritative batching/protocol changes, persistence changes, per-cell terrain patching,
exposed-face miniature culling, world-wide visual transactions, hard visual-latency
guarantees, distance priorities and renderer-wide memory-budget redesign.

## Plan

### Approach

The first PR adds a separate miniature dirty set while retaining main's immediate terrain
drain and service-mesh path. Collect only affected chunks' latest targets/occupancy, replace
their cache synchronously and update transforms during drawing. Run cache maintenance
before terrain-capacity early returns. Observe effective blueprint commits and compare
pending-operation cell materials across reconciliation so prediction replay cannot leave
stale sources. Cancel dirty ownership and release sources on unload.

The second PR replaces immediate preparation draining with a small FIFO and count/time
budget. Entries contain chunk/subscription identity rather than historical payloads;
preparation reads current state. It adds no age gate or terrain/miniature publication
coordination. A failed item yields; unchanged frames do no queue population scan.

### Affected Components

- `src/engine/blueprint_renderer.zig` and `shaders/blueprint.wgsl` — miniature cache,
  synchronous replacement, transforms, limits and resource lifetime.
- `src/voxel_app/main.zig` — dirty hooks, immediate cache drain, reconciliation/lifecycle;
  FIFO budget integration in the second PR.
- `src/voxel_app/world.zig` — synchronous notifications of effective blueprint commits,
  preserving package preflight and the unobserved service path.
- `src/engine/blueprint_readback.zig` — renderer parity and resource/limit checks.
- `src/engine/blueprint_visual_benchmark.zig` — component cache measurements.
- `src/voxel_app/chunk_visual_queue.zig` and queue/CPU replay benchmarks — second PR only.
- `build.zig` and validation documentation — focused checks and scoped evidence.

### Data Model Changes

Volatile dirty/cache ownership, then volatile queue entries. Each miniature source record
contains three local coordinates and one material as four `u32` values. Saved world,
definitions, progress and resources do not change.

### API Changes

Provide synchronous miniature replacement, removal, clear, count and draw operations.
`World.applyBlueprintChangesObserved` borrows synchronous callbacks for effective changes
in commit order; `applyBlueprintChanges` retains its unobserved interface. The second PR
adds `Queue.mark/remove/take`, `FrameBudget` and queue counters. Terrain APIs stay unchanged.

### Risks

Whole-chunk extraction and upload may still be expensive. FIFO backlog increases visual
age, while separate terrain/miniature updates can show temporary gaps or overlaps. Missed
invalidation or lifetime hooks can cause permanent staleness and require integration
coverage. Per-chunk drawing adds submission overhead for spatially spread sources.

### Measured tradeoffs

The [2026-11-09 report](../../docs/validation/construction-visuals.md) separates historical
prepared-API timings from verification of the simplified synchronous cache. Historical
results motivate caching and count-budget coalescing, but not the discarded paired
publication machinery. Minimum age two saved almost no additional work in those traces;
the approved second PR uses age zero. No component result establishes full-game smoothness,
actual event-to-visible latency or simulation throughput.

## Tasks

### Phase 1 — Immediate cache PR

- [x] T2: Add compact per-chunk sources, synchronous bounded replacement and GPU lifetime
  handling; preserve renderer parity and camera-only reuse (AC5, AC7–AC9).
- [x] T3: Decouple miniature updates from terrain upload admission, retaining existing
  terrain/service ownership and allowing temporary mismatch (AC6, AC11).
- [x] T4: Connect effective blueprint changes, edits, snapshots, prediction reconciliation
  and unload/reload to cache invalidation without global scans (AC4, AC10).

### Phase 2 — FIFO preparation PR (pending)

- [ ] T1: Add deduplicated FIFO admission, identity/cancellation, zero age, count/time
  budgets and allocation/fairness tests (AC1–AC4).
- [ ] T5: Apply four-chunk/two-millisecond preparation scheduling without paired staging;
  retain retryable failures and independent terrain handling (AC3, AC6, AC11).
- [ ] T6: Run deterministic queue fixtures and CPU replay; report scheduling, CPU work and
  nominal publication ages with their exclusions (AC12).

### Validation

Phase 1 validation is complete: branch-specific Debug/ReleaseFast builds/tests, GPU
readbacks and fresh synchronous-API renderer measurements are recorded in the
[validation report](../../docs/validation/construction-visuals.md). Overall acceptance
verification remains open for the pending queue PR.

- [ ] T-val: Verify second-PR queue/budget criteria and record its branch-specific checks
  and measurements; preserve the completed cache coverage while integrating scheduling.
