---
service: zig_engine
created: 2026-11-12
updated: 2026-11-14
status: approved
---

# Move active construction targets into simulation state

## Intent

Make simulation the authoritative owner of active construction target cells, including their
physical contents, progress, and saved state. Clients compose an almost static terrain layer
with immutable blueprint definitions and compact construction progress. Completed constructions
materialize into world-data chunks in bounded background work.

The ownership, publication, and lifecycle contracts below are approved for implementation.
This is a documentation change: runtime implementation and performance measurements remain
pending. Exact wire encoding, scheduling budgets, and GPU representation are engineering
choices to validate against these contracts.

## Context

The direction originated in the [warehouse discussion](warehouses.md#q19--construction-storage-ownership-and-handback).
Construction is expected to dominate world modifications in the automated economy. Optimize
that frequent simulation path, while retaining world-data ownership of player inventory.

Current [blueprints](blueprints.md) require all nonempty target cells to be physically empty
at application, prohibit extraction throughout an active box, and allow compatible real
content and ordinary placements in blueprint-empty cavities. Boxes cannot overlap, but
multiple sites can occupy the same chunk and use each other's fulfilled targets as support.
Fulfillment checks at most five physical neighbors and needs no final structural scan.

Today `world_data_service.zig` writes completed blocks into terrain. The runtime's pending-target
index drops entries on fulfillment, and the last fill releases the site and its restrictions.
Persistence likewise retires the instance on its last fulfillment. These lifetimes must change:
filled targets need discovery until handback, and a fully filled site remains active while
materializing. This spec explicitly supersedes blueprint R32's immediate release and the soil
compaction/active-target aging rules. Q6 retains grass covering at admission and moves grass
initialization for built soil to world-data after completion. Other blueprint contracts remain
in force except the soil equivalence explicitly described there.

[PR #64](https://github.com/bacher/zig_engine/pull/64) made fulfillment's direct cell mutation
target-local. Current application still clears grass/cancels surface timers below targets;
manual compaction, compaction timers, and grass growth remain implemented. Q6 removes the
loose/compacted soil distinction and compaction mechanics, while retaining grass as surface
cover under world-data ownership. These are planned changes, not effects already implemented
by PR #64.

The [shared save baseline](warehouses.md#q18--atomic-transfers-and-coherent-durable-capture)
captures world, player, and simulation state coherently without a disk sync per item.
[Design principles](../../DESIGN_PRINCIPLES.md) prioritize automatic throughput and simulation
precedence. The [submission benchmark](../../docs/validation/world-command-batches.md) measures
enqueue cost only; it cannot establish the benefit of this ownership change.

## Requirements

- R1: Transfer actual storage, mutation, and persistence responsibility for nonempty blueprint
  target cells to simulation for their owned lifetime. Cavities and external foundations
  remain world-data-owned. This responsibility is independent of executor/thread assignment.
- R2: Preserve empty-target admission, box exclusion, cavity compatibility, and whole-active-box
  extraction restrictions. Storage scope and gameplay restrictions have different extents.
  R15 explicitly extends active-site restrictions through materialization.
- R3: Give every target one current authority, identified by world/session, construction
  lifetime, and definition-cell identity. Terrain placeholders, cached snapshots, discovery
  records, and prepared materialization copies are not independent writable physical state.
- R4: Admit site state and discovery coherently after fallible preparation and validation.
  Initially all targets represent known physical air. Prepare the Q6 grass clearing and growth
  cancellation below miniatures as part of the same admission. Rejection leaves no partial
  ownership, soil/timer, or resource effects; publication cannot expose a partial footprint.
- R5: Apply fulfillment, its resource outcome, and progress coherently in simulation.
  Repeated processing has one effect. A failed/deferred operation preserves the appropriate
  task/resource state; installing an already-paid result cannot charge the source again.
- R6: Compose physical reads: an unfulfilled target is air; a fulfilled target is its immutable
  definition material with ordinary collision/support semantics. The separate completed logical
  view substitutes planned targets for blueprint validation. These blocks are not packed goods.
- R7: Use composed views for collision, targeting, structural checks, blueprint capture,
  warehouse admission, routing, and rendering. Missing required state is unknown, never assumed
  air. Preserve the five-neighbor structural fulfillment bound and cross-site support, without
  a service message per neighbor or a final structural scan.
- R8: Discover relevant sites through chunk-level references and immutable definition/transform
  data, with no global site scan per cell query. Support multiple sites per chunk, wrapped X,
  rotated instances, and blueprint-empty cavities. Derived lookup caches may accelerate this.
- R9: Keep base terrain air at simulation-owned targets; do not write ownership-marker blocks
  or a canonical per-cell ownership mask at admission. Membership derives from the definition
  and transform, persists through fulfillment, and remains distinct from progress and current
  storage owner. Raw base air never authorizes an ordinary edit to an owned target.
- R10: Route edits to the current owner and preserve simulation precedence. Player fulfillment
  crosses the world-data-owned inventory boundary and has one coherent resource outcome.
  Ordinary edits retain existing guards, including support from other sites and active boxes.
- R11: Publish construction changes independently of base terrain payloads. A fill must not
  require rewriting static terrain cells or sending a full static chunk payload solely to
  convey that fill. Client geometry may be recomposed under R26.
  Coalesce progress and derived updates; still invalidate affected effective occupancy,
  occlusion, collision, and boundary geometry through their proper paths.
- R12: Capture definitions, construction progress/lifecycle, ownership transfers, resources/tasks,
  grass timers/initialization obligations, and terrain at one coherent boundary in the shared
  save system. Restore sources/discovery before dependent reads. No independent owner saves or
  per-target disk synchronization are required; recent unsaved progress may be lost coherently.
- R13: Materialize only targets and required constructed provenance into the current destination
  chunk. Preserve other sites and intervening edits to cavities or unrelated cells; never
  replace a current chunk with a whole-chunk snapshot taken at admission.
- R14: Transfer ownership coherently per construction and target-bearing chunk after fallible
  preparation. Before acceptance simulation owns that portion; afterward world-data owns it.
  Matching cell data and transfer metadata become visible together. Retry has one effect.
  Bound preparation, transient memory, and queued materialization work.
- R15: Use `building → materializing → complete`. The last fill detects remaining=0 in O(1)
  and starts materialization; it does not remove the frame or active-site restrictions.
  Release those only after all target-bearing chunks transfer. Do not add priority handback
  or a queue of blocked player edits. Completion requires no client acknowledgment.
- R16: Keep authoritative source lifetime independent of client residency and NPC presentation.
  Retire it only after handoff, safe readers/capture, and publication obligations permit.
  Identity/revision checks reject stale replies and prevent revival of retired lifetimes.
- R17: Remove the loose/compacted soil distinction and manual/timed compaction, but retain
  grass surface cover under world-data ownership. Soil targets use bare soil in the immutable
  definition and remain bare without growth timers throughout building and materializing,
  including portions already transferred. Definition plus progress still describes all
  simulation-owned target materials; no per-target grass state is needed there.
- R18: Measure end-to-end fulfillment, ordinary/target reads, active-site memory, publication,
  saves/recovery, and completion bursts. Include sparse/dense footprints, cold/empty chunks,
  multiple instances of one definition, cross-site support, and mixed player/simulation work.
  Compare Q2 alternatives without inferring throughput from enqueue timing alone.
- R19: Give immutable blueprint contents a stable `BlueprintId` scoped to the world. Cache a
  full definition once and reuse it across instances. Instance identity, origin, rotation,
  lifecycle, and progress are separate; a changed definition receives a different identity.
- R20: Discover sites in chunk metadata and subscribe by construction identity. On initial
  subscription or resynchronization send the instance descriptor and full progress snapshot;
  fetch its definition if absent. Cover visible sites and sites needed for local gameplay,
  including collision/support, even when their models are not drawn.
- R21: Send batched progress deltas with a defined base/result revision and lifetime/session
  identity. Changed indices or bitmap sections are both allowed. Detect gaps, ignore duplicates
  and stale lifetimes, and resynchronize from a snapshot. Do not require a whole-site bitmap
  or a separate message per fulfilled block.
- R22: Keep construction membership, current storage ownership per target chunk, and terrain
  snapshot versions distinguishable. Chunk metadata/snapshots must identify a coherent
  composition state, including during partial materialization and discovery retirement.
- R23: Distinguish terrain-data readiness from render readiness. For a portion still selected
  for display, retain its dynamic presentation until matching static geometry is installed
  and ready to draw; receiving a snapshot or queuing a mesh build/upload is insufficient.
  Activate the replacement and remove the old presentation in the same displayed frame,
  without a hole or duplicate. Collision/interaction may adopt newer coherent authoritative
  data independently of GPU readiness. Completion notices and stale data/jobs cannot erase
  the retained display, reopen a site, or overwrite a newer post-completion edit.
- R24: Build target groups by chunk and schedule materialization over those groups, without
  repeatedly scanning the full definition or transferring every chunk in a sparse box.
  About 5–10 seconds is an acceptable normal-load completion delay, not a forced wait or
  hard deadline. Backpressure/retry cannot discard targets or release restrictions early.
  Blocked portions must yield so other ready portions/sites receive fair service. Retain a
  bounded retry/wake path; finite admitted work must finish once dependencies and processing
  capacity remain available. Later arrivals cannot indefinitely displace ready admitted work.
- R25: Preserve constructed-cell enumeration and affected-construction validation across both
  owners. Changing a low-level block getter alone is insufficient if a caller enumerates
  only terrain metadata. Preserve bounded/coalesced road follow-up obligations and their
  ownership/derived-state consistency without synchronous road rebuilds on each fill.
- R26: Decouple GPU layout from authority and network encoding. Clients may combine static
  and dynamic geometry or use separate passes; both must render one effective world,
  including miniature removal, full blocks, boundaries, and partial materialization.

- R27: At admission clear grass and cancel pending grass growth on world-data soil immediately
  below occupied blueprint targets under Q6. Pending targets count as cover for grass, while
  empty definition cells and frames do not. Scheduling and expiry use composed occupancy and
  target membership, including chunk boundaries; unknown required data defers the decision.
- R28: After the whole site completes, world-data initializes ordinary growth for eligible
  exposed soil targets. Use the existing grass delay from site completion, without counting
  building time. Prepare candidates during bounded materialization; retain coherent pending
  work until initialized. Retry/restart cannot lose, duplicate, or reset deadlines, and delayed
  initialization must respect subsequent ordinary edits and their cell/timer lifetimes.
- R29: Grass is surface cover, not a change in structural capability. Use one soil support
  baseline for bare and grassy soil: current packed-soil behavior,
  including its own footprint/platform requirements. Remove loose-soil exclusions consistently
  from ordinary rules, blueprint normalization/certification, and the five-neighbor predicate;
  preserve that predicate's bound and resource identity across cover changes.

## Clarifications

### Q1 — Selected scope and authority

**CONFIRMED 2026-11-13.** Actual simulation ownership covers only nonempty blueprint cells.
Application validates them as physically empty; no existing blocks are copied into the site.
Terrain stays air underneath simulation-owned targets. Empty blueprint cells retain their
ordinary world-data contents and permitted placement behavior. The whole active box continues
to prohibit extraction, including during materialization.

This is an ownership and publication change, not a requirement for another server thread.
Start with separate state domains on the existing service executor, following
[warehouse Q22](warehouses.md#q22--initial-execution-of-simulation-owned-warehouses).
Read/mutation turns must not interleave halfway through an accepted transition. Published
snapshots are immutable and held through their use; capture and asynchronous preparation hold
sources or validate their versions before acceptance. A later parallel executor must preserve
these guarantees, but is not a prerequisite.

### Q2 — Ownership and execution alternatives

**RECORDED 2026-11-12; selected baseline refined 2026-11-13.** Retain alternatives for comparison.

| Alternative | Canonical target state | Routine fulfillment | Main tradeoff / status |
| --- | --- | --- | --- |
| Target-only simulation ownership | Simulation, then world-data at materialization | Resources and target/progress update within simulation | Selected; requires composed reads and bounded lifecycle transfer |
| Whole-box simulation ownership | Simulation owns terrain/metadata throughout the box | Region-local work plus boundary coordination | Includes unrelated contents, cavities, and potentially warehouse pallets; not selected |
| Target-defined actions with batched technical access | World-data retains terrain; simulation retains tasks/resources | Access all data needed for a batch and commit each result coherently | One terrain store; access and source lifetimes need coordination; retained alternative |
| Queued world-data operations | World-data retains terrain; simulation retains tasks/resources | Submit bounded batches and coordinate resource/task outcomes | Existing transport baseline; batching alone does not settle cross-owner outcomes |

The third alternative preserves the proposal: **site targets define permitted construction
actions, while technical access covers the data required for a batch of work**. That may
include neighbors, shared metadata, progress, and publication bookkeeping. It does not transfer
storage/persistence ownership or require an all-or-nothing gameplay transaction for the batch.

Best-effort resource accounting is a separate axis under
[warehouse Q20](warehouses.md#q20--measured-exceptions-to-resource-accounting).
No loss/duplication exception is selected.

### Q3 — Static target membership in chunk data

**CONFIRMED 2026-11-13: chunk references plus definitions; no in-cell markers.** The earlier
proposal to write a special ownership block into every target is superseded. Admission already
requires air, and the immutable definition/transform already describes the target set.
Avoid a second canonical per-cell membership representation and an admission write over all
target terrain cells.

For a query, find candidate sites in the chunk, transform the world coordinate into definition
space, and test whether that cell is nonempty. A bounding box match alone does not establish
ownership: its cavities remain terrain. Resolve wrapping/rotation with existing blueprint
coordinate rules. Chunks without sites take the ordinary terrain path. A chunk can reference
several sites; discovery must not assume one owner for the chunk.

Chunk references discover active restrictions and required construction data, including in
box-only chunks. Target groups identify the subset with simulation-owned cells. Fulfillment
may remove a miniature from pending traversal, but cannot erase ownership discovery. During
materialization, a per-(construction, target chunk) transfer record selects the current physical
owner while active-box membership persists until the whole site completes.

Earlier candidates were an in-cell tag, a separate 4 KiB membership bitset per 32³ chunk, and a
sparse target directory. They are not required storage formats. A derived bitset or sparse
lookup cache remains an optimization to measure; it must be rebuildable from site data and
cannot become another progress authority. A cell tag would also force some empty chunks to
allocate their otherwise omitted 32 KiB block array and change material-only consumers.

Persist or coherently rebuild chunk discovery from the saved active-site index without a
whole-world scan. Discovery and instance publication must describe one admitted state.
Unresolved required definitions/instances make affected reads unknown; raw air cannot grant
placement permission or imply safe collision traversal.

### Q4 — Safe composed reads and publication

**CONFIRMED 2026-11-13: static terrain plus construction subscriptions.**

| Source | Contents | Update pattern |
| --- | --- | --- |
| World-data | Ordinary terrain, constructed metadata, construction discovery and transfer state | Ordinary edits, admission/discovery changes, materialization |
| Immutable blueprint | Dimensions and nonempty target materials with stable cell identities | Fetch/cache once per definition; reuse for every instance |
| Simulation construction | Identity/transform, progress bits, lifecycle, revision, untransferred portions | Initial snapshot, batched progress/lifecycle updates, resync |

A client loads the full definition and an instance snapshot when a relevant site is discovered.
Several instances reuse the same definition. Bit 0 means a pending miniature/physical air;
bit 1 means a full block of the defined material. Empty definition cells do not participate.
The wire format may index definition cells or a canonical ordered target list, provided the
mapping is stable and shared by snapshots/deltas. Definition/material data cannot be inferred
from a bitmap alone.

Initial/resync snapshots carry all progress. Routine updates carry changed indices or bitmap
sections, batched by publication interval/budget. A dense 100×100×32 definition would require
320,000 bits, or 40,000 bytes, for a full bitmap; sending it per fill would defeat the intended
saving. These are payload arithmetic, not bandwidth measurements. Choose sparse/dense delta
encoding from measured workloads rather than fixing the encoding here.

Progress is monotone 0→1 while building, but OR-ing bits alone is not a protocol: receivers must
check world/session, construction lifetime, and base/result revisions. Apply a compatible
snapshot plus subsequent deltas; reject old/duplicate updates, detect gaps, and request current
state rather than guessing. Admission, completion, subscription removal, and materialization
are separately versioned lifecycle changes. A lost or reordered reply cannot resurrect a site.

Collision/interaction needs may retain a subscription outside the visible set. A mesh-only
terrain subscriber also needs construction discovery and snapshots. If required data is
missing, defer dependent actions and use existing missing-world collision behavior rather
than walking through assumed air. Server support, routing, and validation likewise compose
both domains through local reads/held snapshots, not a round trip per cell. Enumerators of
constructed blocks must include site-owned filled targets.

Base/dynamic hidden-face decisions and chunk boundaries must converge with the effective
physical view. Derived geometry work may be coalesced; a fill must not cause a full static
chunk payload solely to update the site. Separate rendering passes and combined GPU buffers
are both allowed. This specification does not mandate a particular renderer or unmeasured
latency target.

### Q5 — Completion and handback

**CONFIRMED 2026-11-13: keep restrictions until materialization finishes.** This deliberately
replaces immediate completion in blueprint R32. It avoids priority materialization on player
edits and a separate edit-wait/replay queue.

| Phase | Physical source | Frame and active-site restrictions |
| --- | --- | --- |
| `building` | Simulation for all targets; pending targets are physical air | Present |
| `materializing` | Simulation for untransferred target chunks; world-data for accepted portions | Present across the entire site |
| `complete` | World-data for all targets | Released; ordinary rules apply |

The last fill changes phase in O(1), with no final structural scan. Schedule bounded background
work over precomputed target-bearing chunk groups. A small site may finish immediately; a
normal-load delay around 5–10 seconds is acceptable, and the frame makes the retained site
state visible. This is not a guaranteed deadline under overload and does not introduce a
mandatory delay. Failed work retries while the source and restrictions remain intact.

A portion waiting for chunk data, a source hold, or retryable resource failure yields its
scheduling turn instead of repeatedly blocking the queue head. Other ready portions, including
those of other sites, continue receiving fair service. Keep blocked work discoverable through
a bounded retry/wake mechanism so it resumes after recovery; new arrivals cannot starve ready
admitted work. Finite admitted materialization completes once dependencies and processing
capacity remain available. This refines the existing [fairness principles](../../docs/simulation-notes.md#bounded-work-and-fairness)
without prescribing a queue layout, equal CPU shares, a hard deadline, or priority handback.

For each portion, prepare a target-only patch and required provenance, validate destination
versions/holds, then accept it into the current chunk together with its ownership-transfer
record. Other sites and cavity edits survive. Each accepted portion has one physical owner;
the site record may retain immutable progress/definition data for readers without authorizing
a second writer. Previously transferred chunks are not written again on retry.

Materialization does not freeze all cavity edits: existing permitted placements remain
permitted and go through completed-world checks. Target changes/extraction stay rejected under
active-site rules even in portions already owned by world-data. An attempted edit does not
accelerate the transfer or enter a future replay queue. After every portion is accepted, release
the frame/restrictions and retire discovery/source records subject to safe lifetimes.

Clients reconcile matching terrain data and composition state per chunk, then switch visual
presentation only when the corresponding static geometry is installed and ready for display.
If a transfer notice arrives first, retain the dynamic portion while awaiting terrain data.
If static data arrives first, use its composition metadata to prepare the replacement, but do
not hide the dynamic portion merely because a mesh build/upload has been queued. Delayed or
retryably failed geometry preparation/upload retains the previous presentation for portions
still selected for display, while collision/interaction can adopt newer coherent data without
waiting for the GPU.

At successful visual handoff, activate static geometry and hide the replaced dynamic portion
in the same displayed frame. Check chunk/subscription incarnation and composition/geometry
revisions before activation; superseded jobs cannot install an obsolete replacement. This
contract applies to combined buffers as well as separate passes. Normal visibility eviction
still applies and does not pin off-screen sites indefinitely. Other visible portions remain
dynamic until their own replacement is ready. A global completion notice alone cannot retire
their presentation. Clients need not load every chunk of a large site to make progress.

Server completion never waits for clients. A client may retain its cached definition/final
snapshot longer than the server retains the site. World-data must retain Q6's completion time
and pending grass-initialization work before the corresponding site data is retired. An old
chunk reference to a retired instance must trigger current chunk/object resynchronization;
it is not a new empty site. Older static
snapshots or delayed construction deltas cannot override post-completion ordinary edits.

Common capture records each partial transfer coherently: either the site owns a portion or
the current chunk does. Reopening resumes remaining materialization without rebuilding,
charging, or installing completed portions twice. Keep source holds for readers/capture;
remaining=0 alone is never permission to drop saved instance state. No per-chunk fsync is needed.
Applied-site cancellation/refunds remain a separate feature.

### Q6 — Soil and compact physical state

**REFINED 2026-11-13: grass remains; compaction does not.** This replaces the earlier proposal
to remove all soil transformations. Grass is surface cover on a single soil material; there
is no loose/compacted gameplay state, manual compaction action, or compaction timer. Blueprint
capture normalizes grassy soil to bare soil. Material enum/cover encoding is an implementation
choice; grass is not a separate construction resource or simulation-owned target override.

At application, world-data prepares grass removal and cancellation of pending growth directly
below every occupied blueprint target, including elevated targets over cavity contents.
Empty definition cells and the surrounding frame do not clear or suppress grass. A miniature
counts as cover until its real block replaces it. This retains the current coverage footprint
under blueprint R58, not a whole-box surface clearing pass. Admit these effects, site discovery,
and initial state atomically after all allocation/dependency checks, including neighboring
chunks. Grass clearing changes cover only, never structural support or the underlying resource.

Soil inside the blueprint stays bare throughout `building` and `materializing`. Do not schedule
or execute its grass timers while simulation owns it, or after a portion transfers while the
site is still active. Ordinary placement over a built target cannot trigger a write back into
simulation for grass: there is no grass/timer there to clear. Fulfillment remains target-local
and does not repeat admission's covering work or add per-fill soil coordination.

World-data retains grass scheduling for ordinary terrain. Coverage and exposure use the
composed physical view plus pending-target membership: base terrain air under a simulation-owned
block is not proof of exposure. An actual or pending block directly above prevents growth;
an empty definition cell or frame does not. Unknown dependencies defer work, not imply air.
This also applies to terrain soil placed in permitted cavities after admission. No whole-site
scan is needed when a grass timer runs.

During per-chunk materialization prepare soil surface candidates and world-data-owned pending
initialization work. After **all** portions transfer and the site becomes complete, initialize
growth for exposed bare-soil targets as for an ordinary newly placed soil block in this new
model. The deadline is completion time plus the existing grass delay (currently 30 minutes of
game time), never the target's earlier fulfillment time. There is no intervening compaction
stage. Covered internal soil receives no growth timer; later ordinary exposure starts the
ordinary delay. Existing top-surface rules apply, without adding sunlight/sky checks.

Preparation and activation may run in bounded batches. Keep the completion timestamp and any
unfinished initialization obligation in the shared capture until the resulting timer/no-op
outcome is accepted. Reopening resumes it without resetting elapsed time, duplicate timers,
or a full-world scan. Revalidate current cell identity, cover, and newer edit/timer state:
late initialization must not recreate soil, attach an old deadline to a replacement block,
or overwrite a newer ordinary exposure deadline. Save the resolved effect and obligation
retirement coherently. This follows the lifecycle principles of
[persisted unfinished work](deferred-world-work.md); it does not require the existing road key
format or a generic job queue. No timer starts in an early transferred portion while another
portion of the site is still materializing, even if a stall exceeds the growth delay.

Implementation must update [current soil rules](../../docs/block-placement.md#simulation-time-and-transformations)
and their tests explicitly, with the appropriate ruleset/save gates. Reuse the admission
preparation and world-data grass scheduler, removing their dependence on compaction. Keep the
single soil material's resource identity and structural behavior independent of grass cover.

**Confirmed soil support:** use current packed-soil support capabilities
for both bare and grassy soil, retaining soil's own footprint/platform requirements. Clearing
grass must not weaken an existing foundation; growing grass must not strengthen it. Remove the
old loose-soil support exclusion from ordinary rules and the cheap fulfillment predicate, and
normalize captured grassy soil to the same bare structural material. Recheck certification and
cross-site support tests under the new ruleset; the five-neighbor bound stays unchanged.
The author confirmed this support baseline and retained the all-miniature coverage footprint:
application requires empty target cells, not an empty whole box, so existing soil in cavities
can also lie immediately below elevated targets.
Road shapes remain derived geometry under their existing bounded follow-up contract.

### Q7 — Evidence for the final implementation

**ENGINEERING CHECKPOINT.** Choose representative site counts, footprint densities, read/write
ratios, observer counts, and budgets before the prototype measurements. The architectural
contract is selected; numeric tuning is not evidence of a measured speedup.

Compare completed work and end-to-end latency, CPU, allocations, retained bytes, encoded bytes,
publication/geometry work, save pauses, and materialization backlog. Include mostly ordinary
terrain reads, multiple sites per chunk, sparse boxes, large definitions shared by many sites,
client subscription churn, completion/grass-initialization bursts, and cold/empty chunks. Exercise capture/restart
and publication reordering at every lifecycle boundary. Record limits and uncertainty alongside
Q2 alternatives; revisit the design if composed reads or retained state erase the intended gain.

## Acceptance Criteria

These criteria specify future implementation behavior; they do not claim runtime verification
in this documentation change. Existing IDs are retained, with superseded marker/completion/soil
criteria updated to match Q3/Q5/Q6.

- AC1: GIVEN an admissible blueprint WHEN applied THEN only nonempty targets become
  simulation-owned physical air and cavity/foundation contents stay world-data-owned.
- AC2: GIVEN failed/conflicting admission WHEN rejected THEN no partial site/discovery or
  resource effects become authoritative and no target terrain cells are replaced with markers.
- AC3: GIVEN an accepted automatic fulfillment WHEN applied or retried THEN contents, progress,
  and resource outcome agree and the block is neither built nor charged twice.
- AC4: GIVEN pending and fulfilled targets WHEN read physically THEN they resolve to air and
  the definition material respectively, while planned logical reads retain blueprint semantics.
- AC5: GIVEN a filled target supporting another site WHEN that site validates a fill THEN it
  can use that support before handback with at most five physical neighbor checks.
- AC6: GIVEN discovery but missing required definition/instance state WHEN an affected query
  runs THEN it reports unknown rather than treating base air as free space.
- AC7: GIVEN multiple sites in a chunk WHEN resolving targets THEN each maps to its own
  lifetime/index and no blueprint-empty cavity is acquired by simulation.
- AC8: GIVEN a pending target WHEN fulfilled THEN membership persists until handback while its
  miniature disappears and physical/progress state changes.
- AC9: GIVEN a newly admitted site WHEN raw terrain storage is inspected THEN its owned targets
  remain air with no ownership-marker cells or canonical per-cell ownership mask written.
- AC10: GIVEN an empty base chunk with owned targets WHEN compacted/unloaded THEN site discovery
  survives or is rebuilt coherently and required state is available before dependent use.
- AC11: GIVEN player fulfillment WHEN accepted THEN carried inventory and the simulation-owned
  result have one coherent resource outcome across retry and recovery.
- AC12: GIVEN cavity edits and another site sharing a chunk WHEN a target portion materializes
  THEN only its targets/required metadata change and other contents survive.
- AC13: GIVEN preparation failure before transfer acceptance WHEN work resumes THEN simulation
  still owns the portion and retry does not expose a duplicate destination result.
- AC14: GIVEN partial materialization racing capture/interrupted persistence WHEN reopened
  THEN terrain, site, resources, discovery, and transfer state agree at one saved boundary.
- AC15: GIVEN an old snapshot/reply after handoff WHEN delivered THEN it cannot restore retired
  ownership, overwrite current cells, or address a reused lifetime.
- AC16: GIVEN the last target is accepted WHEN remaining reaches zero THEN the site becomes
  materializing in O(1), retains its frame/restrictions, and adds no final structural scan.
- AC17: GIVEN large/many simultaneous completions WHEN materialization runs THEN preparation,
  source/destination memory, and work per scheduling turn obey measured configured bounds.
- AC18: GIVEN an unobserved site WHEN saved/reopened THEN its contents, progress, phase,
  ownership, and tasks survive independently of client terrain residency.
- AC19: GIVEN changing progress WHEN published THEN effective occupancy and dependent views
  update without per-fill terrain membership writes or full static chunk payloads solely for the fill.
- AC20: GIVEN soil targets in a building or materializing site WHEN filled, covered, or time
  advances THEN they remain bare with no grass timers, no compaction action/event occurs, and
  simulation-owned contents remain reconstructible from the definition and progress alone.
- AC21: GIVEN an implementation candidate WHEN performance is compared THEN evidence covers
  ordinary/target reads, fulfillment, memory, publication, saves, and completion bursts.
- AC22: GIVEN several instances of one blueprint WHEN a client subscribes THEN it can reuse one
  immutable definition while maintaining separate transforms, lifetimes, and progress.
- AC23: GIVEN a new/reconnected subscriber WHEN snapshot plus updates are applied THEN it
  reconstructs current targets from the definition and a compatible progress revision.
- AC24: GIVEN a batched delta WHEN duplicated, reordered, or delivered with a gap THEN duplicate
  effects are ignored, incompatible updates do not apply, and gaps trigger resynchronization.
- AC25: GIVEN many fills in a large site WHEN a publication batch is produced THEN routine
  updates need neither a whole-site bitmap per fill nor a message per block.
- AC26: GIVEN rotated/seam-crossing sites and cavities WHEN ownership is queried THEN definition
  mapping is correct without scanning every world site or writing target markers.
- AC27: GIVEN an owned target whose base terrain is air WHEN ordinary placement is attempted
  THEN it is rejected or routed to valid blueprint fulfillment under existing action rules.
- AC28: GIVEN some portions materialized WHEN an allowed cavity placement or target extraction
  is attempted THEN cavity placement retains normal validation and target extraction remains
  rejected, without priority transfer or deferred edit replay.
- AC29: GIVEN all target portions transferred WHEN server completion commits THEN the frame
  and site restrictions release without awaiting any client acknowledgment.
- AC30: GIVEN materialization exceeds the normal-load delay or encounters failure WHEN work is
  delayed THEN source/restrictions persist and no timeout discards contents or completes early.
- AC31: GIVEN a transfer/completion notice before its terrain snapshot WHEN a client composes
  the world THEN it retains the visible dynamic portion until matching static geometry is
  installed and ready for display, not merely until its data arrives.
- AC32: GIVEN the matching static snapshot before a separate lifecycle notification WHEN applied
  THEN composition metadata permits data reconciliation, while visual replacement waits for
  render readiness and switches in one displayed frame without holes or duplicate rendering.
- AC33: GIVEN a client observing only some site chunks WHEN they materialize THEN it can switch
  those portions without loading or acknowledging the rest of the construction.
- AC34: GIVEN a stale chunk reference after server retirement WHEN the client requests the site
  THEN it resynchronizes current chunk/object state rather than treating the reference as empty.
- AC35: GIVEN an ordinary post-completion edit WHEN older terrain or construction data arrives
  THEN the newer authoritative version remains effective and the old block is not resurrected.
- AC36: GIVEN partial transfers saved before restart WHEN materialization resumes THEN only
  remaining portions install and already transferred blocks/resources are not applied again.
- AC37: GIVEN a sparse blueprint spanning box-only chunks WHEN scheduled for materialization
  THEN work visits target-bearing groups without rescanning its entire definition per chunk.
- AC38: GIVEN a terrain edit affecting a simulation-owned constructed neighbor WHEN dependencies
  are enumerated/validated THEN that neighbor participates despite absence from terrain metadata.
- AC39: GIVEN required collision/support state outside the visible set WHEN a client needs it
  THEN it retains/loads the relevant construction state or uses missing-data behavior, never air.
- AC40: GIVEN a mesh-only terrain subscription WHEN a site changes or transfers THEN discovery
  and construction updates still provide the effective world independent of GPU pass choice.
- AC41: GIVEN a fill affecting road geometry WHEN accepted THEN its bounded deferred follow-up
  remains coherent with current owners and captures without a synchronous per-fill road rebuild.
- AC42: GIVEN a reader/capture holding old source data WHEN a portion transfers THEN the held
  data remains valid until released and does not authorize writes through the old owner.

- AC43: GIVEN grass or a pending growth timer directly below an occupied blueprint target,
  including elevated targets and chunk/seam boundaries WHEN application commits THEN grass
  is cleared and growth canceled coherently with the site; empty definition cells are unchanged.
- AC44: GIVEN admission preparation failure or stale dependencies WHEN application is rejected
  THEN neither grass/timers nor construction discovery/progress change partially.
- AC45: GIVEN world-data soil with a pending or simulation-owned filled target directly above
  WHEN ordinary exposure scheduling or a grass deadline runs THEN the composed cover suppresses
  growth; unavailable required state defers rather than treating base air as exposure.
- AC46: GIVEN soil in an early transferred portion WHEN another portion remains materializing
  beyond the grass delay THEN no site soil has begun a growth timer or grown grass.
- AC47: GIVEN completed materialization with exposed and internally covered soil targets WHEN
  world-data initializes growth THEN only eligible exposed targets receive a deadline at site
  completion plus the ordinary grass delay, with no compaction stage or credit for build time.
- AC48: GIVEN pending grass initialization or scheduled growth WHEN saved, reopened, or retried
  THEN the deadline and outstanding work survive coherently without duplicate effects or resets.
- AC49: GIVEN soil removed/replaced or covered/exposed by ordinary edits after completion WHEN
  delayed initialization is processed THEN it respects the current cell lifetime and newer
  timer state without resurrecting soil or overwriting a newer exposure deadline.
- AC50: GIVEN ordinary newly placed bare soil outside active target ownership WHEN exposed
  THEN world-data schedules grass directly under the same delay/rules, without compaction.
- AC51: GIVEN bare and grassy versions of the unified soil WHEN checking support, construction
  certification, collision, or mining THEN cover does not change those outcomes; both use the
  selected soil baseline, and clearing grass at admission cannot weaken a foundation.
- AC52: GIVEN materializing sites A and B with A's destination held/unavailable and B ready
  WHEN the scheduler runs THEN A yields, B completes without waiting for A, and A resumes and
  completes after its dependencies and processing capacity remain available; later arrivals
  cannot indefinitely starve either site's ready work.
- AC53: GIVEN matching terrain data/composition metadata but a delayed or retryably failed
  mesh build/upload for a visible portion WHEN client frames advance THEN dynamic presentation
  remains while collision/interaction can use the newer coherent data; on successful current
  geometry installation it switches without a hole or duplicate, and superseded jobs cannot
  activate stale geometry.

## Constraints

- Keep one authoritative cell/resource state and shared coherent capture. Safe lifetimes and
  simulation precedence remain required; no accounting exception is implied by batching.
- Preserve wrapped X, finite Y/Z, world resource budgets, bounded structural validation, and
  existing blueprint gameplay except Q5's delayed release and Q6's soil simplification.
- Separate raw storage, resolved physical material, completed logical material, and geometry.
  Raw base-air shortcuts cannot answer effective occupancy inside a simulation-owned footprint.
- Budget definitions, site snapshots, lookup caches, delta histories, and transfer queues.
  Backpressure/resync must not silently drop accepted progress or make simulation observation-dependent.
- Existing saves may be rejected under the development compatibility policy. Use explicit
  format/ruleset gates for the new ownership/soil model; do not reinterpret old saves silently.

## Out of Scope

- Runtime implementation, benchmarks, deployment, or save-format changes in this documentation PR.
- NPC scheduler/task/cargo decomposition, new cancellation/refund UI, or whole-box ownership.
- A separate simulation thread, parallel region executor, universal transaction framework,
  independent owner saves, or an adopted best-effort resource-loss exception.
- Reintroducing compaction, grass growth in active targets, or unrelated material/support redesign.
- Mandatory GPU passes/buffer layout, exact delta serialization, numeric scheduling budgets,
  or a guaranteed completion deadline under arbitrary load.
- Priority materialization and player edit waiting/replay queues.

## Plan

### Approach

Implement one complete path on the existing service executor with separate ownership domains,
immutable published snapshots, and coherent capture. Begin with definition/instance identity,
chunk discovery, and composed readers; then move fulfillment/progress out of terrain. Introduce
construction subscriptions before removing the old terrain-based client update path. Complete
per-chunk materialization and recovery before enabling the new path for persistent worlds.

Apply Q6 explicitly with a ruleset/save gate and update affected soil tests/docs. Preserve
admission's one-time grass clearing, suppress active-target growth, and integrate bounded
world-data grass initialization with completion/capture. Keep blueprint logical validation,
resource checks, and bounded road obligations. Compare Q2 alternatives and Q7 workloads before expanding concurrency or adding discovery caches.

### Affected Components

- `src/voxel_app/blueprint_runtime.zig`: persistent site phases, progress, full-lifetime discovery,
  target groups, and retirement instead of dropping the instance on its last fill.
- `src/voxel_app/world_data_service.zig`, `world.zig`, `world_chunk_data.zig`: composed physical
  and logical reads, mutation routing, constructed enumeration, admission and materialization.
- `src/voxel_app/chunk_metadata.zig`, `persistence/blueprints.zig`, and capture modules: chunk
  references/transfer state, constructed provenance, partial handoff capture/recovery.
- Block/soil rules and timers: remove the compaction distinction/actions; retain grass clearing
  and ordinary growth in world-data, with composed cover and post-completion initialization.
- Client protocol/cache, collision/targeting, voxel/blueprint rendering: definition cache,
  construction subscriptions, revision reconciliation, prediction, and per-portion switch.
- Road derived-state processing: route through composed data, preserve bounded obligations
  and capture consistency across the ownership transition.

### Data Model Changes

| Record | Required meaning; concrete layout remains an implementation choice |
| --- | --- |
| Blueprint definition | World-scoped immutable ID, dimensions, material cells, stable target-index mapping |
| Construction instance | Lifetime ID, definition reference, origin/rotation, progress bits, remaining count, phase, revision |
| Target chunk group | Target indices for this instance/chunk; current owner/accepted-transfer state |
| Chunk discovery | Relevant active site references and coherent composition version, including box restrictions |
| Published snapshot/delta | World/session and lifetime identity, descriptor/progress/phase, compatible revisions |
| Materialization result | Target-only patch plus provenance, destination version, transfer state and grass-initialization obligation |
| Grass initialization | World-data-owned surface candidates, site completion time and outstanding work; eventual ordinary cell timers |

Do not keep a second mutable voxel array for site contents. Pending and fulfilled materials
derive from one definition/progress authority. The remaining counter, discovery, grouping,
and optional caches must agree with or be reconstructible from canonical state. Reference
lifetimes must retain definitions through materialization and safe publication/capture.

### API Changes

Distinguish raw terrain reads from composed physical and completed logical reads. Add coherent
admission, local simulation fulfillment, target-chunk materialization, and owner-aware mutation
routing. Publish definitions and versioned construction snapshots/deltas separately from static
terrain payloads, with resync and retirement semantics. Preserve the future network boundary;
clients cannot depend on shared in-process synchronization.

### Risks

Per-read composition and retained source state may offset cheaper writes. Large shared
definitions, subscription churn, partial handoffs, and completion bursts may dominate memory or
publication work. Missing enumeration paths can bypass structural validation even when direct
reads are correct. Out-of-order terrain/lifecycle updates can expose gaps or resurrect retired
state. Measure and fault-test these before claiming a performance improvement.

## Tasks

### Design and validation planning

- [x] T1: Record target-only ownership and the four storage/execution alternatives.
- [x] T2: Select chunk discovery without markers and the static/dynamic publication contract;
  record reader lifetimes and revision/resync requirements in Q1/Q3/Q4.
- [x] T3: Select bounded per-chunk materialization with retained restrictions and Q6's soil
  model: grass stays world-data-owned, active targets stay bare, compaction is removed.
- [ ] T4: Define Q7 workload sizes, counters, memory accounting, numeric budgets, and fault cases.

### Implementation sequence

- [ ] T5: Add simulation-owned records, target groups, full-lifetime discovery, and coherent admission.
- [ ] T6: Add composed reads/enumeration and route fulfillment/resources to the correct owners.
- [ ] T7: Add materialization phases, per-chunk acceptance, fair scheduling with blocked-work
  yielding/recovery, common capture, and safe retirement.
- [ ] T8: Integrate prediction, collision, rendering, and per-portion client handoff; separate
  data readiness from successful geometry installation and retain display through upload retries.
- [ ] T9: Apply Q6: remove compaction, retain atomic admission grass clearing, suppress active
  target growth, and add bounded post-completion world-data timer initialization/recovery;
  unify bare/grassy soil support in ordinary rules, certification, and cheap fulfillment;
  update format gates, tests, and documentation.
- [ ] T10: Add immutable definition caching, initial snapshots, batched deltas, subscriptions, and resync.
- [ ] T11: Audit ordinary/dependent validation, road obligations, mesh boundaries, and raw-air shortcuts.

### Validation

- [ ] T-val: Verify AC1–AC53, relevant blueprint/persistence regressions, allocation/fault/reordering
  cases, blocked-site fairness/recovery, delayed/failed geometry installation, restart during
  partial materialization, and end-to-end performance under Q7; record
  measured results, selected budgets, and remaining limitations.
