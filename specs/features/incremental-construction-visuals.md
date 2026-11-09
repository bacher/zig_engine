---
service: zig_engine
created: 2026-11-08
status: in-progress
---

# Cache and budget construction visuals

## Intent

Combine repeated construction changes into a limited amount of client presentation work
per frame. Cache miniature geometry by chunk so camera movement does not reconstruct or
upload every pending target, while terrain and miniatures continue to show coherent results.

## Context

The client immediately reconciles authoritative block snapshots, local edits, inventory,
and blueprint progress. Previously, a frame rebuilt every dirty terrain chunk and traversed
visible pending targets to generate camera-relative miniature instances again. Full-size
application previews already cache immutable source geometry under
[blueprint R55](blueprints.md#requirements).

[Design principles](../../DESIGN_PRINCIPLES.md) prioritize throughput, permit stale visual
observations, require coherent outcomes, and bound work and retained memory. This feature
changes presentation scheduling and caching without changing simulation execution or saves.

## Requirements

- R1: Keep physics, collision, inventory/resource accounting, target identity, construction
  progress, and command reconciliation current through their existing paths. Only visual
  geometry may wait for the presentation queue.
- R2: Publish each chunk's terrain mesh and pending-target miniature geometry from the same
  client view. A completed target must not disappear as a miniature before the matching real
  geometry appears, nor remain as a miniature after its matching real geometry appears.
  Different chunks may temporarily display different ages.
- R3: Mark affected loaded chunks at existing edit, snapshot, road-change, and blueprint
  application/fulfillment/reconciliation paths. Preserve boundary-dependent terrain
  invalidation. Do not discover changes through a per-frame world, site, target, or revision
  scan. Observe only effective committed blueprint publications/fulfillments after fallible
  preflight; no-op replays must not notify visual work.
- R4: Keep one pending FIFO item per loaded chunk with expected O(1) marking, lookup,
  cancellation, and removal. Remove canceled items immediately. Queue occupancy is bounded
  by the admitted loaded-chunk set; retained allocation follows peak simultaneous occupancy,
  rather than the number of chunks visited while traveling.
- R5: **Adopted default:** allow work after two client update frames from its first dirty
  mark. Repeated marks for the same subscription retain its age and FIFO position, combining
  changes across frames without postponing continuously changing chunks indefinitely. A
  new subscription starts a fresh lifetime and rejoins the tail.
- R6: **Adopted default:** rebuild at most four whole chunks per frame and stop starting
  further chunks after two milliseconds of elapsed preparation time. Check time between whole
  chunk preparations, allowing one whole chunk to exceed the soft limit. The policy is
  configurable and promises neither a hard frame-time bound nor a maximum visual delay.
  Logical reconciliation and terrain uploads have their own costs outside this budget.
- R7: Store miniature source geometry in compact, camera-independent 16-byte
  `MiniatureCell` records, cached in GPU buffers per nonempty chunk. Camera movement and
  wrapped coordinate changes update transforms without reconstructing or uploading those
  source cells. Preserve quarter-size geometry, materials, texture orientation, depth, and
  world/chunk coordinate behavior. Use explicit dirty invalidation: unchanged frames and
  neighbor-only terrain changes reuse the source, while an accepted byte-identical block
  snapshot may conservatively trigger another chunk source upload.
- R8: Preserve the existing 1,100,000-cell logical source limit and combined visible-instance
  limit. Retain at most 4,096 nonempty/staged miniature chunks and 4,096 preparations.
  Reserve logical capacity conservatively across pending replacements so discarding a
  preparation can retain the old display. Displayed plus staged cell sources must not
  exceed twice the cell capacity: 2,200,000 records, or 35,200,000 source bytes, excluding
  transforms, bindings, container capacity, other renderer buffers, and driver overhead.
- R9: Prepare miniature resources without altering displayed geometry. Commit the prepared
  miniature revision only after its matching terrain upload succeeds, with no draw between
  the two publications. Commit must not allocate. Discarding a preparation or using a stale
  handle after unload must not publish or release a newer chunk lifetime.
- R10: Queue terrain replacements without removing the displayed chunk first. Preflight
  allocation for the complete upload batch; on capacity wait retain the previous terrain
  and miniature pair. Coalesce repeated terrain uploads by chunk, including empty
  replacements that remove its old geometry only when accepted.
- R11: Cancel pending work and retire matching cached/staged representations on unload or
  client teardown. Representation handoffs invalidate stale queued/prepared ownership while
  preserving the coherent displayed pair until its replacement is accepted. Validate the
  queued subscription against the current chunk lifetime before preparing or publishing
  work. Late old responses and prepared handles must not restore an evicted representation.
- R12: Keep selection diagnostics, continuous twelve-rail frames, the selected capture-only
  occluded pass, and immutable application-preview caching under their existing policies.
  These small dynamic elements do not require scanning miniature cells or rebuilding their
  cached sources.
- R13: If preparation or upload cannot fit its budgets, keep the previous coherent display
  and preserve/retry the outstanding latest-state obligation. A failed preparation must
  yield to other eligible queued work. Continue preparing new eligible dirty chunks within
  the normal frame budget while earlier uploads wait for capacity, allowing queued shrinking
  replacements to join the batch and release capacity. Retain unchanged staged work and
  cancel only a superseded chunk's preparation. Staging may accumulate across frames, bounded
  by loaded chunks and R8's renderer limits. Visual
  convergence requires capacity to become available; sustained overload must remain visible
  through the existing render-limit/capacity feedback.
- R14: Expose queue and renderer counters for marks, coalescing, pending peaks, completed
  work, head inspections, source builds/uploads/releases, displayed/staged occupancy, and
  transform/draw work. Report deterministic scheduling counts separately from GPU correctness
  and full-game performance measurements.

## Clarifications

- Q1: Does delayed rendering delay construction or resource consumption?
  A1: No. Authoritative state and existing immediate client reconciliation retain their
  current semantics. Only their displayed terrain/miniature pair can lag.
- Q2: Is two milliseconds a hard frame limit or a visual freshness guarantee?
  A2: No. Preparation is indivisible per chunk, one chunk can exceed it, uploads have their
  own cost, and a sustained backlog can increase visual delay. The two-frame minimum age
  deliberately trades some freshness for coalescing.
- Q3: Are nearby chunks prioritized?
  A3: The first implementation uses FIFO for predictable progress and low overhead.
  Distance sorting, priority queues, and per-frame queue scans are deferred until measured
  need justifies them. Newly dirtied or repeatedly changed chunks cannot displace older
  eligible work.
- Q4: Is a single coherent visual revision required across the entire world?
  A4: No. Coherence applies to the terrain/miniature pair in each published chunk. Neighbor
  mesh invalidations retain their existing eventual update behavior.
- Q5: Is the visual queue durable?
  A5: No. It is rebuilt from current streamed client state. Saved construction, material,
  and unfinished simulation work retain their existing persistence protocol.
- Q6: Are unchanged source cells compared or fingerprinted after every invalidation?
  A6: No. This iteration uses explicit dirty hooks. A conservative invalidation may repack
  and upload the same cells; the guarantee is no source work on unchanged/camera frames or
  neighbor-only terrain invalidations, without probabilistic source-equality checks.

## Acceptance Criteria

- AC1: GIVEN repeated changes to one loaded subscription across several frames WHEN its
  minimum age is reached THEN a single queued item rebuilds the current view without its
  first-dirty age or FIFO position being reset by those changes.
- AC2: GIVEN busy and quiet loaded chunks with newer invalidations continuing WHEN budgeted
  client frames process eligible work THEN older queue items make progress in FIFO order
  and rebuilt hot chunks rejoin the tail after a later change.
- AC3: GIVEN more pending chunks than the frame budget WHEN preparation runs THEN at most
  four chunk builds start, time is checked between builds, and one whole build can exceed
  the two-millisecond soft limit without exposing half a chunk's visual revision.
- AC4: GIVEN chunk unload, cancellation, subscription replacement, or a representation
  handoff WHEN old work is encountered or a stale prepared handle is committed THEN it
  cannot republish the old lifetime, canceled entries occupy no live queue slots, and
  reload starts fresh work.
- AC5: GIVEN no dirty invalidations WHEN client frames and the camera advance THEN there is no
  target/revision/dirty-population scan, no miniature source rebuild/upload, and cached
  visible geometry follows the camera through transform updates.
- AC6: GIVEN a fulfilled target whose previous miniature is displayed WHEN terrain upload
  is delayed and later succeeds THEN the previous terrain/miniature pair remains intact
  during the wait and both matching new representations become visible together.
- AC7: GIVEN several terrain replacements for one chunk, including an empty replacement,
  WHEN uploads coalesce or cannot fit THEN only the newest pending source is owned and the
  displayed geometry remains unchanged until a complete batch fits.
- AC8: GIVEN dense cached sources and staged replacements WHEN prepare, discard, commit,
  unload, or teardown runs THEN the logical/chunk limits and physical two-capacity bound
  hold, discarded work preserves the old display, and all retired resources are released.
- AC9: GIVEN identical dynamic and cached miniature scenes WHEN production renderer color
  and depth are compared across wrapping modes, seams, antipodes, and signed camera limits
  THEN materials, quarter-size positioning, textures, and depth agree, and diagnostics,
  application previews, and selected capture rails retain their behavior.
- AC10: GIVEN local edits and later accepted/rejected authoritative replies, blueprint
  publications/fills, and mesh/block handoffs WHEN client reconciliation completes THEN
  immediate logical state is correct and only affected chunks acquire eventual coherent
  visual replacements; no-op blueprint replays do not notify visual work.
- AC11: GIVEN allocation failure or miniature/terrain capacity pressure WHEN preparation
  cannot complete THEN the previous coherent display remains usable, outstanding latest
  work remains retryable, and failed preparation yields to other eligible chunks; a prepared
  terrain batch retains the capacity-wait behavior in AC6/AC7 while further eligible dirty
  chunks receive budgeted turns and shrinking replacements can join that batch.
- AC12: GIVEN 8,192 invalidations over four edit frames touching 128 or 343 chunks WHEN the
  deterministic queue fixture drains and then processes 1,024 idle frames THEN no frame
  exceeds four builds, pending occupancy never exceeds the chunk population, coalescing
  avoids repeated per-frame rebuilds, idle head inspections remain zero, and results are
  labeled as queue counts rather than full-game throughput.

## Constraints

Preserve current blueprint validation, five-neighbor fulfillment work, immediate resource
accounting, physics, prediction/replay ordering, save formats, and scene coordinate policy.
Use the client thread and existing renderer/upload ownership; add no worker, global
scheduler, copied world snapshot, or global revision polling. CPU queue memory is
proportional to peak loaded dirty chunks. Miniature source limits do not account for all
GPU memory, and queue counts do not establish end-to-end frame time.

## Out of Scope

NPC/economy scheduling, authoritative batching/protocol changes, new persistence formats,
per-cell terrain patching, exposed-face miniature culling, world-wide visual transactions,
hard visual-latency guarantees, distance-priority scheduling, and renderer-wide memory
budget redesign.

## Plan

### Approach

Replace the dirty hash set's unconditional end-of-frame drain with a coalesced FIFO and
deterministic frame-budget helper. Queue entries hold chunk and subscription identity,
rather than historical cell payloads; preparation reads the latest reconciled client view.
Use local mutation/reconciliation hooks to mark affected chunks.

Pack pending targets into per-chunk miniature source buffers. Stage the matching miniature
replacement before queueing terrain geometry. Keep displayed sources until the complete
terrain batch can upload, then commit the matching prepared miniature handles before the
next draw. Continue normal budgeted preparation under upload pressure, staging one latest
replacement per loaded chunk so shrinking replacements can join the held batch. Retain
unchanged preparations and cancel only superseded chunk work; use FIFO without pressure
priority or a dirty-population scan. Release/cancel owned work through the chunk lifecycle.

### Affected Components

- `src/voxel_app/chunk_visual_queue.zig` — coalescing, FIFO, age, count/time budget, counters.
- `src/voxel_app/chunk_visual_queue_benchmark.zig` — reproducible queue-work scenarios.
- `src/voxel_app/main.zig` — local dirty hooks, reconciliation, lifecycle, coherent publication.
- `src/voxel_app/world.zig` — synchronous notifications of effective committed blueprint
  changes, preserving the existing unobserved service path and package preflight.
- `src/engine/blueprint_renderer.zig` and `shaders/blueprint.wgsl` — cached miniature cells,
  transforms, reservations, preparation/commit/discard, and resource lifetime.
- `src/engine/voxel/voxel_grid.zig` — retained display and coalesced upload replacements.
- `src/engine/blueprint_readback.zig` — production renderer color/depth verification.
- `build.zig` and `docs/blueprints-validation.md` — targeted checks and measured evidence.

### Data Model Changes

Volatile client queue entries and prepared visual ownership only. GPU miniature source
records contain three local coordinates and one material as four `u32` values. Saved world,
blueprint definitions, progress, and resource records do not change.

### API Changes

Add `Queue.mark/remove/take`, `FrameBudget`, and queue statistics. Add renderer
`prepareMiniatureChunk/commitMiniatureChunk/discardMiniatureChunk` and lifecycle/statistics
methods. `VoxelGrid.replaceChunk` owns the newest pending replacement while retaining its
displayed resident until upload preflight succeeds.
`World.applyBlueprintChangesObserved` reports effective changes in commit order through
borrowed synchronous callbacks; `applyBlueprintChanges` retains its unobserved interface.

### Risks

Whole-chunk preparation and GPU upload can still be expensive; the CPU budget is soft.
Sustained changes can outpace processing, increasing visual delay until capacity recovers.
Per-chunk caching adds draw/resource overhead for spatially spread miniatures. Missed dirty
or lifetime hooks could leave stale geometry, so integration coverage must exercise local
prediction, authoritative replacement, cleanup, and representation handoffs explicitly.

### Measured tradeoffs

The [2026-11-09 component measurements](../../docs/validation/construction-visuals.md)
separate cached miniature rendering from CPU preparation scheduling. They support the
cache's reduction in repeated packing/uploads and the count budget's reduction in busy
rebuild work. The two-frame minimum age adds latency with almost no further work saving
in those traces. Neither harness measures the full client lifecycle or demonstrates a
performance benefit from persistent paired publication; R2 and R9–R13 impose that visual
coherence policy independently. Defaults remain unchanged pending the design discussion.

## Tasks

### Phase 1 — Queue and cache

- [x] T1: Implement coalesced FIFO admission, first-dirty age, cancellation, frame budget,
  counters, and allocation/fairness/lifetime tests (AC1–AC4).
- [x] T2: Implement compact per-chunk miniature sources and bounded prepare/commit/discard
  ownership with production renderer/readback checks (AC5, AC8, AC9).
- [x] T3: Coalesce terrain replacements and preserve the displayed resident during upload
  capacity waits, including empty replacements (AC6, AC7).

### Phase 2 — Client integration

- [x] T4: Connect dirty hooks to local and authoritative changes, blueprint reconciliation,
  boundary/road changes, and streaming handoffs without global revision scans (AC4, AC10).
- [x] T5: Apply the frame budget, prepare matching terrain/miniature views, and commit their
  representations together after accepted uploads; cover retry and lifecycle paths
  (AC3, AC6, AC11).

### Validation

- [x] T6: Add and run deterministic 128/343-chunk queue fixtures with 8,192 marks, bounded
  builds, bounded pending occupancy, and 1,024 idle frames (AC12).
- [x] T-val: Run acceptance criteria verification, focused GPU/application integration
  checks, appropriate aggregate builds/tests, and record results and measurement limits.
