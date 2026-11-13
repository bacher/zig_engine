---
service: zig_engine
created: 2026-11-12
status: draft
---

# Move active construction targets into simulation state

## Intent

Make simulation the authoritative owner of active construction target cells, including their
physical contents, progress, and saved state. Integrate completed targets into world-data
chunks when returning ownership, so routine automatic fulfillment can update resources and
construction state within simulation.

Target-only ownership is the selected direction for further design. Marker encoding, safe
reads, handback scheduling, and soil transformations remain open. This specification records
alternatives and implementation checkpoints; it does not claim a runtime implementation or
measured performance improvement.

## Context

The author selected this direction on 2026-11-12 during the [warehouse discussion](warehouses.md#q19--construction-storage-ownership-and-handback)
and authorized related architecture/specification changes in the same documentation change.
Warehouse and simulation decisions in this change are dependencies for this design; it is
not necessary to wait for a separate warehouse merge before describing their consequences.

Current [blueprints](blueprints.md) require all nonempty target cells to be physically empty
at application, prohibit extraction throughout an active box, and allow compatible real
content and ordinary placements in blueprint-empty cavities. Boxes cannot overlap, but
different sites can occupy the same chunk and rely on each other's fulfilled targets.
Fulfillment checks at most five physical neighbors and needs no final structural scan.

Today `world_data_service.zig` writes each completed block into terrain and updates blueprint
progress. `blueprint_runtime.zig` already maintains chunk-local target lookups containing
instance identity, definition-cell index, and material; fulfillment removes the target entry.
This index describes pending miniatures, not the full lifetime of future simulation ownership.

Chunks contain 32³ byte-sized block cells. `BlockType.custom = 255` already represents custom
blocks; it is not a free ownership flag. Empty chunks can omit the 32 KiB dense cell array.
Existing raw occupancy shortcuts frequently treat non-air as occupied. A new redirect marker
would therefore require explicit decoding and an audit of these shortcuts.

The [shared save baseline](warehouses.md#q18--atomic-transfers-and-coherent-durable-capture)
captures world, player, and simulation state coherently without a disk sync per item.
Player inventory remains world-data-owned. [Design principles](../../DESIGN_PRINCIPLES.md)
prioritize frequent automatic work and simulation precedence. The current
[submission benchmark](../../docs/validation/world-command-batches.md) measures enqueue cost
only and cannot select this architecture.

## Requirements

- R1: Transfer actual storage, mutation, and persistence responsibility for nonempty
  blueprint target cells to simulation for their owned lifetime. This is ownership of the
  cells, not a temporary grant to mutate world-data-owned block arrays.
- R2: Keep blueprint-empty cells, external foundations, and other terrain in world-data.
  Preserve existing application validation, empty-target requirements, box exclusion,
  cavity compatibility, and whole-active-box extraction restrictions. Storage scope and
  gameplay restrictions have different extents.
- R3: Give every owned cell one current authority, identified by site/registration lifetime
  and target identity. Raw terrain bytes, discovery records, snapshots, and prepared merge
  copies must not become independent writable copies of its physical state.
- R4: Admit site state and its ownership discovery coherently after fallible preparation
  and validation. Initially all targets represent known physical air. A rejected application
  leaves no active ownership or resource effects; publish no partially admitted footprint.
- R5: Apply accepted fulfillment, its resource outcome, and progress coherently in simulation.
  Repeated processing has one effect. A failed or deferred operation preserves the appropriate
  resource/task state. Concrete construction task division and cargo representation remain
  separate design; installing an already-paid result must not charge the source again.
- R6: Resolve owned cells into a physical world view: pending targets are air, fulfilled
  targets are real blocks with ordinary collision, material, and support semantics. Preserve
  a separate completed logical view that also substitutes planned targets where blueprint
  validation requires it. Storage location does not make constructed blocks packed goods.
- R7: Use the appropriate composed view for collision, targeting, structural checks, blueprint
  capture, warehouse admission, routing, transformations, and rendering. Missing required
  owner state is unknown, never stale base terrain or assumed air. Keep the five-neighbor
  structural fulfillment bound and permitted cross-site support.
- R8: Resolve target ownership through bounded spatial discovery without scanning all sites
  for each cell or requiring a service message for each neighbor read. Chunk-local records
  may name multiple sites. Select snapshot/access lifetimes and consistency under Q4 before
  implementation; material reads do not authorize resource consumption.
- R9: Keep ownership membership distinct from fulfillment. Any chunk-local membership mark
  selected under Q3 remains present for pending and fulfilled targets until handback. It
  identifies redirection, not occupancy or progress. Its presence alone cannot supply
  collision, support, occlusion, a mineable item, or permission for ordinary placement.
- R10: Route edits to the current owner and preserve simulation precedence. Player fulfillment
  still crosses the world-data-owned inventory boundary and must retain a coherent outcome.
  Ordinary edits outside the target set retain their existing guards, including restrictions
  inside the active box and support from nearby sites.
- R11: Publish effective physical/progress changes independently of the static membership
  encoding. Reuse and coalesce derived data where possible, but update logical occupancy and
  dependent views through their proper paths. An unchanged ownership mark does not permit
  stale physical state or eliminate boundary/mesh invalidation.
- R12: Save site definitions/state, ownership discovery, resources/tasks, and terrain at a
  common coherent capture boundary in the existing coordinated save system. Restore ownership
  and required sources before dependent queries. No independently committed owner saves or
  per-item disk synchronization are required; recent unsaved progress can be lost coherently.
- R13: At handback, integrate only the owned cells and required metadata into current destination
  chunks. Preserve intervening changes to other cells; never overwrite a current chunk with
  a snapshot captured at site admission. Preserve constructed provenance and relevant remaining
  timers/downstream obligations under their selected policies.
- R14: Keep the simulation source authoritative until a prepared ownership handoff is accepted.
  Installation, discovery retirement, and recovery must identify one coherent owner/outcome;
  retry cannot duplicate blocks. Bound preparation and transient memory across large or
  simultaneous handbacks. Multi-chunk handoff granularity remains Q5.
- R15: Preserve blueprint R32's gameplay completion contract, including removal of site-specific
  restrictions, without a new final structural scan. Resolve how completion relates to delayed
  storage consolidation before implementation; do not silently extend restrictions while a
  merge waits or discard an authoritative source that still serves readers/edits.
- R16: Keep source lifetime independent of client terrain residency or NPC models. A site may
  span chunks and survive restart without observation. Any delayed physical/visual handoff
  must retain enough identity/version information to reject stale updates.
- R17: Treat retained material transformations and their side effects explicitly. Definition
  plus progress bits are sufficient only if no unrepresented physical material changes occur.
  Optional compaction is under Q6; removal of it or grass behavior is not selected here.
- R18: Compare the selected ownership direction and Q2 alternatives using end-to-end automatic
  construction, common non-target reads, target reads, contention, active-site memory, save/load,
  and completion bursts. Report cold/empty chunks and sparse/dense target footprints as well
  as mixed player/simulation work. Marker and batching microbenchmarks alone are insufficient.

## Clarifications

### Q1 — Selected scope and authority

**CONFIRMED 2026-11-12: target-only simulation ownership for further design.** Nonempty
blueprint cells are simulation-owned physical cells until handback. Cavities and foundations
remain world-data-owned. Registration establishes known empty targets; it does not copy
existing target blocks because current admission forbids them.

The author authorizes recording the broader architecture work alongside the warehouse spec.
This selection does not settle encodings, threads, safe-read protocol, cancellation, or final
merge scheduling. Existing runtime documentation remains descriptive of current code until
implementation; it links this spec as the intended change.

### Q2 — Ownership and execution alternatives

**RECORDED 2026-11-12.** Preserve these choices for prototype comparison and later review.

| Alternative | Canonical target state | Routine fulfillment | Main tradeoff / status |
| --- | --- | --- | --- |
| Target-only simulation ownership | Simulation, then world-data at handback | Resources and target/progress update within simulation | Selected for further design; composed reads and lifecycle handoff remain necessary |
| Whole-box simulation ownership | Simulation owns terrain and metadata throughout the box | Region-local work, plus boundary coordination | Broader transfer includes unrelated contents, cavities, and potentially warehouse pallets; not selected |
| Target-defined actions with batched technical access | World-data retains terrain; simulation retains tasks/resources | Acquire access to all data needed for a batch, including shared metadata/side effects, and commit each result coherently | Preserves one terrain store; access and record lifetimes need coordination; retained alternative |
| Queued world-data operations | World-data retains terrain; simulation retains tasks/resources | Submit bounded batches to the service and coordinate task/resource outcomes | Existing transport baseline; enqueue batching alone does not make cross-owner outcomes coherent |

The batched-access alternative preserves the earlier proposal: **site targets define the
permitted construction actions, while technical access covers the data required for a batch
of work**. The access set can include neighboring cells, shared metadata, progress records,
and publication bookkeeping. It is not limited to target coordinates. The grant does not
move terrain storage or save responsibility into simulation, and a batch need not be an
all-or-nothing gameplay transaction. Compare bounded/renewable grants and coarser region
access without prescribing a lock, thread topology, or permanent site-lifetime lock.

Best-effort resource accounting is a separate axis under
[warehouse Q20](warehouses.md#q20--measured-exceptions-to-resource-accounting), not an inherent
property of any ownership choice. No loss/duplication exception is selected.

### Q3 — Static target membership in chunk data

**UNRESOLVED — author proposal 2026-11-12.** At admission, write a persistent indication
that each target belongs to simulation. Leave it unchanged when the miniature is fulfilled;
read current occupancy/material from simulation. Clear or replace it only at accepted
handback. This avoids mirroring progress into canonical chunk cells on every placement.

The marker means **simulation-owned target**, including an already built block; it does not
mean **remaining miniature**. Owner lookup must resolve site lifetime and target index. A
single marker byte or membership bit cannot also encode an arbitrary site identity, and a
chunk may intersect several nonoverlapping sites. Do not assume one owner for the whole chunk.

| Encoding candidate | Ordinary-cell read | Storage / integration cost |
| --- | --- | --- |
| Dedicated tag in the cell byte | Load cell and branch; ordinary material needs no per-cell owner lookup | No extra cell bytes in an already dense chunk, but a previously empty chunk may need its full 32 KiB array; tag decode, save/wire gates, counts and material-only consumers need revision |
| Separate membership bitset in affected chunks | Chunk presence check and bit test, then resolve marked cells | 4,096 bytes for 32³ bits, excluding owner references/metadata; can preserve allocation-free base air; compare sparse footprints |
| Sparse chunk-local target directory | Skip chunks with no sites; lookup within affected chunks | Scales with targets but has lookup/entry overhead; reuse concepts from the existing index, with different retention rules |

These are raw payload calculations, not measured whole-process memory. A tag in the existing
byte format does not provide a free high bit: `custom = 255` already uses it, and all codecs
and raw material assumptions need review. The tag must be an internal storage reference,
never a selectable, mineable, colliding, supporting, or rendered material by itself. A decoded
physical read returns the owner's real material, air, or unknown.

The current pending-target index removes entries on fulfillment. Ownership lookup must retain
fulfilled entries until handback, while miniature traversal may still remove them. Decide
whether to split these indexes or derive one from another; do not keep two authoritative
progress counts. Persist/rebuild the chosen discovery representation coherently with site
identity. Loaded markers with unavailable owner state block dependent reads until resolved.

Static membership removes per-fill membership writes, not the need to publish changing site
state and invalidate effective occupancy/occlusion/collision or neighboring geometry. This
also matters for mesh-only subscriptions that never receive the raw block array. Encoding,
whether it is saved verbatim or rebuilt from canonical sites, and lookup layout remain open.
Prototype the in-cell tag and compare it with bitsets and sparse discovery before selection.

### Q4 — Safe composed reads and publication

**UNRESOLVED.** Select reader lifetimes, snapshot ownership, revisions, subscription behavior,
and update ordering without per-cell messaging. A reader must not combine an old ownership
generation with a new unrelated site or a released source. Current physical/progress semantics
must remain separate from allowed visual lag and individually approved stale condition checks.

Preserve bounded structural validation, cross-site support, and ordinary extraction guards.
Account for hidden faces between base terrain and site blocks, origin/chunk wrapping,
unknown sources, client prediction, and the switch from site drawing to terrain drawing.
Separate site geometry and merged chunk geometry are alternatives, not a selected renderer.

### Q5 — Completion and handback

**UNRESOLVED.** Decide whether transfer is prepared before accepting the last target, uses
a distinct storage-consolidation phase, or has another bounded schedule. Account for current
immediate gameplay completion, edits after completion, multiple destination chunks, retries,
memory pressure, and capture races. No proposal may lose the source or expose two owners.

Admission and handback are lifecycle transitions; common saves need not synchronize disk
after either individual event. Keep stale whole-chunk replacement out of every candidate.
Future cancellation must retain already built blocks under its separate gameplay design;
it is not implemented or selected by this spec.

### Q6 — Soil and compact physical state

**UNRESOLVED.** [Warehouse Q21](warehouses.md#q21--optional-soil-transformations) records
permission to simplify optional compaction. Placement no longer compacts loose soil, but covering packed soil can clear grass
and cancel its surface timer. Manual/timed compaction and grass growth can change
the target material itself.
Removing only a delayed compaction timer does not remove these interactions.

Resolve automatic compaction, grass coverage, and any remaining timer owner before relying
on definition plus fulfillment bits as the complete physical state. Existing generated packed
soil, earth support equivalence, mining yields, and blueprint normalization need not disappear.
No runtime rule is changed by this architecture choice.

### Q7 — Evidence for the final implementation

**UNRESOLVED.** Establish representative active-site counts and footprint densities, read/write
ratios, observation load, cross-site boundaries, and save/handback pressure. Measure completed
work and end-to-end latency alongside CPU, allocations, retained bytes, publication work,
and save pause/backpressure. Include mostly ordinary terrain reads to test the marker fast
path. Record uncertainty and compare equivalent gameplay outcomes. No speedup is assumed.

## Acceptance Criteria

These are contracts for future implementation of the selected direction, including conditional
marker contracts; their presence does not settle the open mechanisms or claim tests have run.

- AC1: GIVEN an admissible blueprint WHEN applied THEN only nonempty target cells become
  simulation-owned, initially as physical air, and existing cavity/foundation contents remain
  world-data-owned under their existing edit restrictions.
- AC2: GIVEN failed or conflicting admission WHEN rejected THEN no partial site ownership,
  target markers, or resource effects become authoritative.
- AC3: GIVEN an accepted automatic fulfillment WHEN applied THEN target contents, progress,
  and its resource outcome agree, and replay does not build or charge a second block.
- AC4: GIVEN a pending target and a fulfilled target WHEN queried physically THEN the first
  is air and the second has its actual block's collision/support; planned logical reads retain
  their separate blueprint semantics.
- AC5: GIVEN a fulfilled target supporting another site WHEN that site validates placement
  THEN it can use the real neighbor without waiting for handback and without exceeding the
  existing five-neighbor structural predicate.
- AC6: GIVEN unavailable required site state WHEN a marked cell is queried THEN its physical
  result is unknown, not a base-air fallback or an occupied marker material.
- AC7: GIVEN two sites sharing a chunk WHEN their targets are resolved THEN each resolves to
  the correct site lifetime and target; neither cavity cells nor the other site are acquired.
- AC8: GIVEN an encoding under Q3 WHEN one target is fulfilled THEN its ownership membership
  remains until handback while progress/physical views change and miniature traversal can retire it.
- AC9: GIVEN an in-cell marker candidate WHEN storage is decoded for occupancy, rendering,
  support, inventory, or targeting THEN the marker itself is never treated as a gameplay material.
- AC10: GIVEN an empty base chunk containing owned targets WHEN base storage is compacted or
  unloaded THEN ownership is retained/discoverable and required state is loaded before use.
- AC11: GIVEN a player fulfills a target WHEN accepted THEN the world-data-owned carried item
  and simulation-owned result have one coherent resource outcome, including retry and recovery.
- AC12: GIVEN ordinary edits to cavity cells during construction WHEN target handback occurs
  THEN those intervening edits survive and only owned cells/required metadata are integrated.
- AC13: GIVEN a prepared handback fails before acceptance WHEN work resumes THEN simulation
  remains the authoritative source and no duplicate destination result is exposed.
- AC14: GIVEN a handback racing save capture or interrupted persistence WHEN recovery succeeds
  THEN site, ownership discovery, terrain, and resources describe the same coherent boundary.
- AC15: GIVEN an old snapshot or reply after ownership changes WHEN it arrives THEN it cannot
  restore retired ownership, overwrite current cells, or address a reused site lifetime.
- AC16: GIVEN the last target is accepted WHEN gameplay completion occurs THEN the existing
  completion restrictions/frame behavior is preserved and no full structural scan is added;
  any remaining storage phase keeps valid readers and edit routing.
- AC17: GIVEN a large multi-chunk site or many simultaneous completions WHEN handback runs
  THEN preparation, retained source/destination memory, and scheduling obey the selected bounds.
- AC18: GIVEN an unobserved active site WHEN saved and reopened THEN its physical contents,
  progress, ownership, and tasks survive independently of client terrain residency.
- AC19: GIVEN static membership and changing progress WHEN updates are published THEN physical
  collision/support and required invalidation reflect accepted state without rewriting membership
  for each fill; visual lag does not change authoritative occupancy.
- AC20: GIVEN retained soil transformations WHEN they change a site-owned cell or an external
  neighbor THEN the selected owner/state protocol accounts for the change; definition/progress
  decoding cannot silently erase the resulting material or timer.
- AC21: GIVEN a proposed encoding or ownership implementation WHEN performance is compared
  THEN results include ordinary and target reads, full fulfillment, memory, saves, and completion
  bursts rather than extrapolating whole-world throughput from enqueue timing.

## Constraints

- Keep one authoritative cell/resource state. Preserve simulation precedence and the shared
  capture boundary; an ownership choice is not permission for unsafe concurrent access.
- Preserve wrapped X, finite Y/Z, current blueprint gameplay, bounded validation, and world
  resource budgets. Do not allocate whole-world marker arrays or scan all sites per query.
- Separate raw storage, physical material, completed logical material, and visual geometry.
  Existing `BlockType != none` shortcuts cannot decode a redirect marker correctly by themselves.
- Existing saves may be rejected under the development compatibility policy. Choose explicit
  format/version gates if storage changes; do not silently reinterpret old material bytes.

## Out of Scope

- Runtime implementation, benchmarking, deployment, or changes to the current save format in
  this documentation change.
- NPC scheduler/task decomposition, new cancellation UI/refunds, or permanent whole-box ownership.
- Selecting marker encoding, thread topology, renderer, or handback scheduling before review.
- Removing compaction, grass, or material types without the separate gameplay decision.
- Independent simulation save files, a universal transaction framework, or an adopted best-effort
  accounting exception.

## Plan

### Approach

Record the selected ownership contract and alternatives now. Resolve Q3–Q6, then prototype
the smallest complete admission/fulfillment/handback path with safe composed reads and saves.
Compare Q2 and Q3 candidates using Q7's workloads before choosing optimizations. The steps
below are provisional implementation planning, not an instruction to change runtime now.

### Affected Components

- `src/voxel_app/blueprint_runtime.zig`: site state, progress, ownership discovery and retirement.
- `src/voxel_app/world_data_service.zig`, `world.zig`, and `world_chunk_data.zig`: admission,
  composed physical reads, mutation routing, destination integration and chunk lifecycle.
- `src/voxel_app/chunk_metadata.zig` and persistence modules: target references, constructed
  provenance, retained transformations, coherent capture and restoration.
- Block rules/targeting, warehouse queries, client snapshots and voxel/blueprint rendering:
  resolved physical contents, missing-data behavior, prediction and boundary publication.

### Data Model Changes

Canonical site identity/lifetime, definition/transform, progress, and any required physical
overrides live in simulation. Spatial references or marks locate this owner and remain distinct
from progress. Site/material representation and record widths are open; a dense duplicate voxel
array is not required by the contract. Keep pending-miniature traversal and ownership retention
semantically separate even if an implementation shares storage.

### API Changes

Distinguish raw chunk storage reads from resolved physical and completed logical reads.
Define owner-aware edit routing, prepared admission/handback, and versioned publication.
Choose concrete synchronization and wire APIs after the unresolved questions; a local lookup
does not require a message round trip per cell.

### Risks

Per-read overhead may outweigh saved writes; tags may materialize sparse empty chunks;
ownership retention may enlarge indexes; stale snapshots may misroute cells; completion may
create merge/memory spikes. Current soil side effects and post-completion edits complicate
ownership boundaries. Measure and resolve these rather than assuming storage transfer is free.

## Tasks

### Design and validation planning

- [x] T1: Record target-only ownership, the four execution/storage alternatives, and static
  membership encoding candidates separately from selected contracts.
- [ ] T2: Resolve Q3/Q4 encoding, owner discovery, reader lifetimes, and publication semantics.
- [ ] T3: Resolve Q5/Q6 handback scheduling, completion/edit routing, and soil behavior.
- [ ] T4: Define Q7 workload sizes, counters, memory accounting, and fault scenarios.

### Provisional implementation sequence

- [ ] T5: Add simulation-owned site records and coherent admission/discovery.
- [ ] T6: Add resolved world reads and route fulfillment/resources to their owners.
- [ ] T7: Add coherent handback, capture/recovery, and bounded source retirement.
- [ ] T8: Integrate client prediction, physical occupancy, and rendering handoff.

### Validation

- [ ] T-val: Run acceptance criteria verification, fault/recovery cases, and representative
  end-to-end comparison; record measured results and remaining limitations.
