---
service: zig_engine
created: 2026-10-15
status: in-progress
---

# Persist consistent world snapshots without copy-on-write

## Intent

Save a recoverable world while normal player interaction and rendering remain responsive.
If saving falls behind, permit an exceptional, visible pause of world-changing actions to
prioritize save completion; rendering, camera, UI, and service completions remain responsive.
Capture a consistent boundary without persistence copy-on-write (COW): pause simulation
while source chunks are being captured, and defer conflicting player mutations until their
captured versions are safe to release. Append changed chunk images to a snapshot journal
and periodically compact committed journal segments into a base save.
This revision supersedes the conflicting COW decisions in
[PR #28](https://github.com/bacher/zig_engine/pull/28). Implementation is authorized as of
2026-10-19, on a branch based on PR #29. Whole-system RAM budgeting follows persistence v1 in
[Resource budgeting](resource-budgeting.md).

## Context

The world-data service has one worker ordering commands from multiple clients. A command
can modify several chunks through road formation/reversion, neighbor revelation, or soil
transformations. Due transformations run after a request batch. Modified chunks remain in
`WorkerState.modified_chunks` across subscription eviction; untouched chunks are generated
on demand. There is no disk persistence or disk-backed authoritative chunk lookup today.

Chunk blocks are byte values in `[z][y][x]` order, with x contiguous. Persistent metadata
includes construction markers, scheduled transformation kinds/deadlines, and custom road
ownership/orientation. Chunk flags include a historical revealed/unreachable property.
Boundary masks, meshes, subscription tokens, and optimistic client edits are derived or
transient. World ticks are u64 at 60 ticks/second; per-chunk revisions currently use u32.
Several edits can occur during one tick. Player state currently belongs to the main thread;
the demonstration simulation also has private execution state.

The intended late-game workload is approximately 99.9% simulation-initiated chunk updates,
when players mostly guide automation. Earlier play includes substantial manual building;
manual actions are difficult to scale, not forbidden. As described in
[Game vision](../../docs/game-vision.md), this is a planning assumption, not a measured ratio,
a hard limit, or permission to omit manual-building and worst-case workloads. Couriers can
span chunks; workers consume inputs at benches; builders follow blueprints. These systems are not implemented and remain outside persistence v1.
Simulation runs in the world-service process. In this discussion, block timers are distinct
from the broader simulation: they are local scheduled block transitions, while simulation
covers more involved work that may span chunks. Existing capture gates for block timers
remain explicit in R68/R78; the terminology does not itself change scheduling policy.
Player interactions must also work over a network; the current in-process endpoint is not a
wire-level retry/deduplication protocol.

The initial measurement target is approximately 10,000 simultaneously active chunks and
2,000-4,000 distinct changed chunks per 60-second save interval on a 16 GB machine, with
smaller worlds supported on 8 GB machines. These are workload/hardware targets, not hard
chunk limits or measured memory guarantees. Active materialized blocks alone occupy
312.5 MiB; 2,000-4,000 raw block payloads occupy 62.5-125 MiB before metadata/framing.
Metadata, meshes, replicas, retained dirty chunks, and work buffers add to those figures.
Missed saves can accumulate more dirty chunks than one normal interval or the active set.
Removing COW bounds neither this retained world state nor total process memory. With base-only
reloads, the exact current revision must reach the installed base before it can be evicted;
a WAL commit alone is insufficient. Retaining 100 additional distinct materialized chunks
per second for ten minutes without reclamation adds 60,000 * 32 KiB = about 1.83 GiB in block
arrays alone. This is an illustration of net retention, not a measured update rate or a cost
per repeated edit to the same chunk. Metadata, client copies, and other pins add further cost.

Decision status as of 2026-10-19:

- CONFIRMED by the user: distant chunks must not use persistence COW; start v1 with no
  persistence COW anywhere and pause all simulation, including near-player simulation,
  during capture. Keep player edits pending with optimistic visuals, prioritize their
  chunks, and normally use a bounded wait followed by safe capture cancellation when needed.
- CONFIRMED by the user: eventually prioritize completing an overdue save. Allow an
  exceptional visible pause of world-changing actions, including player edits, while
  rendering, camera, and UI remain responsive. Normal wait limits must not cause an endless
  cancellation loop. This explicitly qualifies the normal no-noticeable-freeze target;
  thresholds and the concrete escalation mechanism remain measurement/design choices.
- CONFIRMED by the user: use one coordinator watchdog for capture-related deadlines and
  overdue-save escalation. Preserve original player-wait timestamps across retries and
  capture epochs; retry waiting admissions on meaningful source-release progress (R75).
- CONFIRMED by the user: keep capture-pending primarily internal in v1. Brief waits need
  no new client notification; retain the optimistic operation until its terminal response.
  Coalesce status for longer delays while preserving required visible saving/failure status,
  stable identities, ordering, bounded outstanding work, and pending/rejected distinctions.
- CONFIRMED by the user: normal gameplay deadlines do not automatically cancel the final
  shutdown save. Keep memory limits and responsive completion handling; retain the existing
  wait/cancel-exit/quit choices. Cancel exit restores gameplay capture policy through safe
  ownership handoff, including overdue-save priority when still applicable.
- CONFIRMED by the user: catch up postponed simulation against current world conditions,
  preserving elapsed logical time and preventing duplicate effects. Exact historical
  replay of skipped ticks is not required. Economic event ordering across deferred work
  is explicitly deferred to the future simulation spec.
- CONFIRMED by the user: retain the current `WorldChunk` ownership and field arrangement
  initially. Persistent/derived/runtime categories remain logical serialization contracts;
  capture uses a restricted snapshot view, not a separately owned persistent object. Defer
  physical regrouping and version ownership until a demonstrated need justifies them.
- CONFIRMED by the user: defer custom block/metadata pools to a potential improvement.
  Start with existing allocators behind capacity accounting and reservations; preserve
  fallible preparation, empty arrays, and stable borrowed buffers. Pool geometry, including
  the earlier 64-byte minimum class, is no longer a v1 requirement or tuning default.
- CONFIRMED by the user: evaluate larger output capacity within the same bounded streaming
  pipeline before considering a separate whole-capture buffering mode. Encode and write
  concurrently; a capture that fits available capacity can release its sources even during
  a write stall. Larger caps are experiments, not shipping defaults or upfront allocations.
- CONFIRMED by the user: pending timers alone need not retain a chunk when every timer is
  explicitly lazy. Eviction still requires the exact current version in the installed base
  and clearance of other pins. Both existing block timer kinds, dirt compaction and grass
  growth, are confirmed lazy. R77 supersedes the blanket timer pin. CONFIRMED: ordinary
  loading restores/registers block timers; catch-up runs in the next eligible block-timer
  pass under R47/R78. Outdated terrain may be exposed and edited before that pass; edits
  maintain eligibility atomically, including across chunk boundaries, and timer execution
  revalidates current state. This supersedes catch-up-before-exposure without changing the
  binary format or promising execution in the next frame.
- RETAINED: unaffected PR #28 decisions, including the durable format, recovery, compaction,
  base-only reloads, mutation atomicity, offline-time policy, and local budget controls.
- DERIVED correctness requirements: one capture boundary, synchronized source release,
  complete mutation write-set admission, bounded pending work, and separation of pending
  admission from terminal rejection and durability.
- IMPLEMENTATION CHOICES: concrete capture state/queue APIs and scheduling data structures
  remain engineering decisions within the agreed contracts. R66/R76 require measurement
  and baseline evaluation; numerical defaults and optimization choices follow that evidence.
  These do not block finalizing the design and do not establish measured responsiveness.
  Direct simulation-thread mutation leases and the future NPC catch-up/state model remain
  deferred. The user subsequently authorized implementation on top of PR #29.

## Requirements

These requirements are normative. The referenced [format contract](../formats/world-persistence-v1.md)
provides their exact binary definitions. Clarifications record decision rationale and status;
acceptance criteria verify the requirements; the plan describes implementation sequencing and
mechanisms without overriding those contracts.

- R1: Capture a boundary between complete authoritative transactions, including every
  affected chunk and completed timer operations at the capture boundary. Preserve pending
  timers and their original deadlines, including overdue timers awaiting a later pass or
  deferred for dependencies/resources. A saved world tick does not imply that every timer
  due before it has executed. No snapshot may contain half a road formation, timer transition,
  or cross-chunk edit. Timer-pass eligibility follows R47.
  Unloaded chunks retain their saved timer state without being activated for a snapshot.
- R2: Keep player input, rendering, and service completion handling responsive during
  capture, encoding, disk writes, and compaction. Pause simulation under R68; player mutations
  may wait asynchronously under R38. Snapshot capture may perform bounded bookkeeping on the
  authoritative worker; no disk I/O, compression, or whole-world block copy may run there.
  Measure capture bookkeeping, interaction latency, and visible near-player simulation pauses
  before claiming the no-noticeable-freeze requirement is met. The initial global pause is
  a design to evaluate, not evidence that arbitrarily long pauses are invisible. R73 permits
  an exceptional visible pause of world-changing actions when saving falls behind; rendering,
  camera, UI, and completion handling remain responsive in that mode.
- R3: Save only persistent differences from generated terrain. Persist world identity,
  dimensions/topology, chunk size, generator identity/version/seed/settings, world tick,
  and a monotonic u64 snapshot sequence independent of world tick.
- R4: Persist complete changed chunk images, including gameplay metadata and historical
  flags. A changed chunk that becomes empty remains an explicit empty override; absence
  means fallback to the persisted generated baseline, not empty air.
- R5: Capture a fixed set of chunk identities and persistent revisions at one authoritative
  boundary, together with eligible global/player state. Freeze the captured blocks, metadata,
  and persistent flags as one unit until their complete old state has been encoded into
  independently owned output or safely released after cancellation. Do not clone that unit
  on mutation in v1. Every persistent mutation must pass the service's admission gate for
  its complete write set. Defer a conflicting operation without partial effects; permit
  mutation once all required captured sources are released. Enumeration/freezing and mutation
  admission share the service's ordering authority. A later read of a mutated chunk cannot
  substitute for its missing boundary version. The common mutation/source-release gate is
  a logical lifetime contract, not a requirement to regroup fields into a physical owner;
  build the restricted snapshot view under R33 at this same boundary.
- R6: Attempt autosaves every 60 seconds and base compaction every 600 seconds using
  monotonic real elapsed time while the world is open, including pause. Memory pressure
  may request an earlier checkpoint and compaction to make more chunks evictable. Allow
  at most one in-flight snapshot/WAL writer and one compactor; coalesce redundant triggers.
  V1 provides autosave and save-on-exit; manual-save UI is deferred. The 60-second cadence
  is an attempt schedule, not a maximum loss-window guarantee: only successful durable
  snapshots establish saved progress, and slow/failed saves can extend the unsaved interval.
  Escalate under R73 rather than indefinitely sacrificing save completion to cancellation.
- R7: Commit an entire snapshot as one validated journal transaction. Include the sequence,
  world tick, persistent world/player records, record count/extent, and integrity evidence.
  A save succeeds only after the transaction and its commit footer have been synchronized
  to storage using the supported platform durability primitives.
- R8: Dirty state is acknowledged only for successfully persisted versions. Changes made
  after capture remain dirty even when an older version finishes saving. Failed saves
  retain unsaved state, release snapshot ownership safely, and report failure. Track
  WAL durability separately from base installation: WAL acknowledgment alone does not
  make a modified chunk evictable.
- R9: Rotate the active journal at a committed boundary before compaction. The writer may
  append to a new durably established segment while the compactor reads immutable older
  segments and the base file. Identify segments and their sequence lineage explicitly.
- R10: Stream compaction into a temporary base in the same directory. Validate/sync the
  completed file and verify source integrity under R45 before publication. Atomically install
  it and sync directory metadata where required before
  deleting incorporated segments. A crash at any publication/cleanup step must retain a
  recoverable committed state. Compaction must never erase newer segments.
- R11: Recover the latest contiguous valid committed snapshot from the base plus associated
  segments, including two or more sequential segments and duplicate already-compacted
  records. Ignore an incomplete final append under R55's recovery classification. Never replay
  later snapshots across a missing or corrupt committed dependency; report corruption rather
  than silently skipping. An older valid prefix is not automatic authorization to roll back.
- R12: On startup, validate and apply leftover committed journals to the base before entering
  the world. Recovery progress may delay world loading. Startup through a runtime journal
  overlay is out of scope. During gameplay, reload evicted chunks directly from the current
  installed base or regenerate untouched terrain; do not replay or consult the WAL for
  gameplay chunk reads. Modified versions not yet incorporated into the base stay resident.
- R13: Base saves carry magic, version, u64 declared total size, bounded section lengths,
  chunk index entries containing u32 chunk IDs and u64 file offsets, player records, and
  chunk records. Encode integers little-endian with explicit field widths; never serialize
  native Zig struct layout. Reject unsupported versions, invalid bounds, and size mismatch.
- R14: Validate checksums as well as sizes. Journal recovery uses framed records and commit
  integrity instead of a mutable whole-file size. Base and journal files have no 4-GiB
  format limit. Use u64 file positions, aggregate byte lengths, and aggregate record counts
  throughout encoding, recovery, indexing, and compaction. Use checked arithmetic and
  checked conversions to platform I/O/allocation types; preserve durable data on failure.
- R15: Initially support exactly two block encodings: standard `(u8 block_type, u8 count)`
  RLE and raw one-byte blocks, both in x-fast `[z][y][x]` order. Counts are literal 1-255;
  split longer runs and reject zero counts. Use standard when its payload is at most 32,768
  bytes (including ties), otherwise raw with exactly 32,768 bytes. Keep explicit payload
  lengths, no terminator, and the standard-mode trailing-air omission rule: initialize the
  unrepresented suffix as air so every decoded chunk contains exactly 32,768 cells. Raw
  never omits cells. No dedicated uniform/palette codec or maintained material histogram
  is required initially; palette/statistics, nibble counts, and general-purpose streaming
  compression are deferred improvements.
- R16: Reserve block byte 255 for custom cells. Store one custom record in x-fast block
  order per custom cell, with stable type identifiers and enough road state to restore
  existing ownership. Store constructed markers and transformation queues in separate
  versioned metadata sections; custom-cell records alone are insufficient. Apply R51's
  per-section uniqueness, correspondence, and size limits.
- R17: Persist an array of players with Steam-compatible u64 IDs, f64 world positions,
  view orientation, and an explicitly framed inventory extension. Inventory schema 1
  persists the one carried material atomically with accepted terrain transfers; supported
  legacy schema 0 loads an empty slot. Multiplayer gameplay remains future work.
  Restore position/view, reset motion safely, and
  validate/resolve the restored player's collision against authoritative loaded terrain.
- R18: Resume from the saved world tick without adding offline elapsed time. Timer deadlines
  retain their saved relationship to world time. Autosave interval is separate from this
  simulation time policy.
- R19: Initial implementation must use compactor background worker QoS/priority where
  available, bounded buffers, incremental I/O, and cancellation/yield points. Adaptive
  throttling and contention feedback are follow-up improvements unless measurements show
  the basic controls are insufficient. Priority cannot guarantee absence of contention.
- R20: Use bounded reusable live-chunk/metadata storage and independently owned capture-output
  buffers; v1 has no persistence COW reserve. Account for the capture manifest, source pins,
  output capacity, and pending work. Normally cancel safely on excessive capture wait; R73
  overrides automatic wait-time cancellation when saving is overdue. A full output queue
  uses bounded backpressure; genuine inability to obtain required working capacity still
  fails safely, preserves dirty state, and reports the cause in either mode. A cancellation
  request alone does not grant mutable ownership. Accepted cancellation prevents new snapshot
  reads, allows an active read to reach a safe bounded stop, and releases source ownership
  through a synchronized handoff before affected mutations retry. Do not wait for unrelated
  disk I/O or WAL repair to release sources. Apply R30 if committing has started; select
  configurable limits through R66. No unbounded queue of snapshots, encoded records, deferred
  mutations, or abandoned compaction generations is allowed.
- R21: On clean shutdown, stop producers, drain accepted changes, commit a final snapshot,
  and finish compaction through that snapshot before reporting normal completion. A
  successful shutdown leaves a current base and no required WAL. Retain recoverable files
  on any failure. If the final snapshot is durable but compaction fails, allow exit with
  the failure reported and WALs retained for next-start recovery. If the final snapshot
  itself is not durable, offer retry, cancel exit, or explicitly quit with unsaved changes.
  Draining includes admitted operations waiting for dependency I/O and their ordered player
  checkpoints; an empty inbound queue alone does not establish completion.
- R22: Chain checksums at committed-snapshot granularity. Each checksum covers the previous
  committed checksum and sequence, current transaction identity/framing, and exact payload
  bytes. Include world/segment identity in the protected data. The base stores its last
  incorporated logical snapshot sequence/hash, independently of its physical file checksum.
  Continue this chain across rotation and compaction. Recompute and verify every transaction
  during recovery; stored predecessor digests alone do not verify predecessor payloads.
- R23: After a failed append/synchronization or an accepted cancellation that may have left
  WAL bytes, truncate the existing active segment to the writer's last successfully
  synchronized boundary and synchronize that repair before another transaction or rotation.
  A complete footer with failed synchronization still requires repair. If truncation or
  repair synchronization fails, retain dirty state, report failure, and suspend new appends
  and rotation until repair succeeds; gameplay continues. Do not bypass repair by creating
  a replacement segment. Successful saves require no repair or extra WAL scan.
- R24: Evict a modified chunk only when its exact current persistent content version is
  present in the durably installed, readable base: compare the live persistent revision
  with the installed-base catalog revision for that chunk. Also respect gameplay, reader,
  simulation, in-flight operation/load, and snapshot pins. Do not scan or inspect active/
  sealed WAL segments or require separate dirty/pending-WAL checks for eviction eligibility.
  Monotonic persistent revisions under R48 make the equality test sufficient for reloadability;
  WAL durability alone does not permit eviction. Missing base entries do not qualify modified chunks.
- R25: The persistence coordinator reports WAL commits and completed base installations to
  the service as distinct ordered messages. A base-install message identifies its generation,
  incorporated snapshot sequence/hash, and an immutable readable file/index view containing
  per-chunk content versions. The service decides eviction against current versions; an
  acknowledgment for an older version never makes a newer version evictable.
- R26: Bind chunk loads to an immutable base-generation file handle and its matching index.
  Retain old generation handles while reads still use them. Never combine an old index
  offset with the newly replaced file path. Reject stale load completions that would
  overwrite a newer live version or superseded residency request. Represent nonresident
  data distinctly from an explicitly empty chunk and from absent generated overrides.
- R27: Acquire a nonblocking OS-backed exclusive lock on a stable lock file in the canonical
  world directory before reading/recovering or modifying world persistence. Hold it through
  all workers' finalization and shutdown. Reject a second owner in the same or another
  process with a clear world-in-use error. Keep the lock file in place across sessions;
  lock ownership, not file existence or a PID check, is authoritative. The OS releases
  ownership after process exit/crash. Do not lock only the replaceable base file.
- R28: Eviction must preserve timer scheduling and construction/road validation. Load all
  required persisted dependencies before validating or committing an edit; absence from
  the resident map is not proof of absent construction/road metadata. Pending lazy timers
  do not themselves pin a chunk; R77 defines eligibility and non-lazy timer retention.
  Do not discover/preload all timer-bearing chunks when opening a saved world. Restore their
  original timer records when ordinary streaming or gameplay dependency reads load them,
  then use due-event processing with R47's fixed pass boundary. Persistence scanning, recovery,
  and compaction alone do not activate timers or create live resident chunks. Broader scheduled-
  event semantics and independent deadline scheduling with advance loading are follow-up work.
- R29: Release each frozen source as soon as its complete captured state has an independently
  owned encoded representation, before unrelated disk waits. A writer must never retain an
  alias to mutable chunk storage. Once all source holds are released, resume simulation even
  if WAL writing, synchronization, or compaction is still running. Source release is neither
  a durability acknowledgment nor permission for base-backed eviction. Reuse buffers only
  after their consumers release them.
- R30: Accept snapshot cancellation only before commit-footer writing begins. Serialize
  this decision with the writer's transition into committing. Once footer writing begins,
  resolve the commit attempt before reporting its outcome: acknowledge successful
  synchronization even if cancellation was requested, or report failure and require R23
  repair. A failed synchronization does not prove absence of a recoverable transaction;
  startup may recover a complete valid final transaction that was never acknowledged.
- R31: Make each authoritative multi-chunk mutation atomic under capture conflict and allocation
  failure. Secure admission for the complete write set and all mutation resources before
  modifying authoritative state, using private staging where advance reservation is
  impractical. Include metadata, timers, flags, revisions, derived caches, dirty tracking,
  and notifications. No partial result may become observable. Defer/retry or explicitly
  reject under R38/R39; retry only after safe source release and revalidation, preserving
  required authoritative order and preventing duplicate effects. A cross-chunk operation
  cannot publish one side while waiting for another. Snapshots see only complete operations.
- R32: Optimize the common case of absent dynamic metadata. Roads, timers, and construction
  markers initially use separate budgeted backing allocations from existing allocators,
  owned through the existing inline `WorldChunk.metadata` descriptors. Empty arrays require no backing
  allocation; copy live entries rather than unused capacity when a genuine copy is needed.
  Do not separately allocate the descriptors or move them into a new persistent owner.
  A contiguous metadata payload remains a deferred optimization.
- R33: Retain the current `WorldChunk` ownership and field arrangement initially; define
  persistent, derived, and runtime fields logically rather than requiring a physical split.
  Construct a restricted snapshot view at the authoritative capture boundary: copy chunk ID,
  persistent revision, capture epoch, and historical flags by value; borrow const block and
  metadata buffers with their pointer/length descriptors copied into the view. Preserve an
  explicit allocation-free empty-block representation. Keep every borrowed allocation stable,
  immutable, and alive until synchronized source release. The encoder must not read live
  `WorldChunk` headers, packed flags, array descriptors, derived caches, or runtime fields.
  Do not introduce a separate persistent owner, extra owner indirection, general reference
  counting, or a whole-`WorldChunk` header copy solely for capture. Required revision and
  bookkeeping changes elsewhere in this spec still apply. Mutations keep live caches and
  persistent contents consistent at operation boundaries; failure leaves both unchanged.
  Derived-only changes remain outside the persistent mutation gate and dirty tracking,
  preserving historical flag bits. Inline grouping for readability is optional; independently
  owned persistent versions and physical regrouping are deferred until justified.
- R34: Use existing allocators for materialized `WorldChunkData` buffers and separate
  metadata arrays, with configurable capacity accounting and reservations. Defer custom
  pools with fixed slots or page-based size classes until measured costs justify them.
  Keep the existing `WorldChunk` ownership and stable borrowed allocations under R33;
  unrelated allocations and growth must not relocate a captured buffer. Charge allocated
  capacity rather than used length, including spare array capacity, known bookkeeping,
  snapshot views/manifests, and simultaneous old/new storage during growth or copies.
  Track reservations, live storage, capture pins, and encoded output without counting the
  same allocation twice. Account for known allocator overhead where available; identify
  unmeasured overhead/fragmentation separately, leave conservative headroom, and use process
  telemetry rather than claiming these counters bound physical/process memory. Reservations
  enforce local admission limits but do not guarantee that the underlying allocation succeeds.
- R35: Make metadata copying, growth, and mutation preparation fallible and reservable.
  Replace panic-on-OOM paths involved in these operations with propagated allocation errors
  and cleanup of partially acquired resources. Include all required metadata capacity in
  operation preparation under R31. Derive semantic entry/payload limits from supported
  gameplay and actual structures, independently of allocation policy; enforce them
  consistently when mutating and loading. Entry-count limits are defined in R51; serialized
  byte limits are defined in R54; select allocation budgets through R66.
- R36: Persistence v1 provides configurable local capacity limits/counters, structured
  resource-failure/status reporting, safe capture cancellation, the capture-related
  simulation gate, and early checkpoint/compaction requests. These interfaces remain usable
  by a later global controller. They do not establish a process-wide RAM ceiling or guarantee
  no swapping. System-derived budgets, general prioritized admissions, movement gating,
  and richer simulation-throttling UI remain the resource-budgeting follow-up. The minimal
  capture pause/player-encoding priority belongs in persistence v1.
- R37: Preserve regular gameplay performance while providing R31 atomicity. Mutate admitted,
  exclusively owned chunks in place once preparation secures all required resources. Reuse
  still-valid validation/dependency discovery results and reusable scratch storage for compact
  operation descriptions. Do not introduce unconditional whole-chunk staging copies or a
  second full validation traversal solely for failure handling. Use private staging only
  where needed; no general rollback framework is required. Measure mutation-gate and
  preparation overhead separately from waiting, encoding, and existing client-copy costs.
- R38: Treat a player mutation blocked only by capture as nonterminal pending work, retaining
  its request identity, required order, and optimistic client effect. Prioritize capture of
  its frozen write dependencies and retry admission after meaningful source-release progress.
  Use a configurable elapsed wait limit, not a fixed number of timer-based retries; do not
  reset it on notifications, newly discovered dependencies, or a change of capture epoch. If the
  limit expires in normal mode, request safe capture cancellation, process its ownership
  handoff, then revalidate and prepare the operation; never replay already-applied effects.
  In R73 save-priority mode, retain the request with visible status and bounded backpressure
  instead of automatically cancelling solely for this elapsed limit. Pure capture
  contention must not become a terminal resource rejection merely because a retry timer fires.
  Genuine preparation allocation failure retains the previous policy: at most one automatic
  retry after a useful ownership handoff, then explicit `resource_exhausted`; reject directly
  if release cannot help. Terminal rejection removes/reconciles the optimistic effect and
  reports failure; never silently replay it later. A timeout or lost reply does not prove
  rejection. Keep pending/completion capacity bounded and distinguish admission refusal from
  an admitted operation's eventual outcome. Respect R30.
- R39: Simulation work blocked by capture or resources remains unapplied and bounded. Pause
  dispatch under R68, retain compact pending progress or an existing timer/event record, and
  apply producer backpressure instead of queuing one operation per skipped tick. Resume on
  a meaningful source/resource-release signal with bounded backoff as a fallback, not every
  tick. Revalidate against current conditions and consume timers/inputs only with successful
  operation completion. Catch-up follows R69; completion signals remain serviceable while
  dispatch is paused. Expose the blocked reason without implementing the future NPC scheduler
  or full global throttling UI in this iteration.
- R40: Distinguish configured-budget exhaustion from allocator failure in diagnostics; both
  use safe resource-failure paths. Semantic limit violations are invalid requests/data and
  are not retried as memory pressure. Secure bounded completion/status capacity before
  accepting work so failure reporting does not depend on a new allocation after exhaustion.
  Continue work that can complete safely within available capacity. These guarantees do not
  constitute recovery from arbitrary process-wide OOM.
- R41: Track admitted operations explicitly through waiting-for-dependencies, waiting-for-capture/
  resources, ready, and validate/prepare/commit stages to terminal applied/rejected outcomes.
  Dequeuing or starting I/O is not completion. Load and pin required dependencies before
  mutation; validate current authoritative state when ready. Newly discovered dependencies
  return the whole operation to waiting without partial publication. Preserve required
  command order despite out-of-order completions, while servicing I/O and source-release
  messages. Do not block the authoritative worker waiting for an event it must itself handle.
  Capture/resource deferral remains nonterminal under R38/R39.
- R42: Player checkpoint records identify the preceding player-command sequence they depend
  on, scoped to the originating client/session. A checkpoint becomes eligible only once
  every preceding required command has a terminal applied/rejected outcome. Track a resolved
  prefix, not merely the greatest completed sequence. Snapshot capture uses eligible player
  records and completed authoritative operations; it must not advance a save barrier past
  unresolved required commands or serialize optimistic pending terrain as authoritative state.
- R43: Final shutdown drains all admitted operations, including dependency waits, and makes
  the final ordered player records eligible before final snapshot capture. Keep dependency
  loading and completion processing alive during draining. If draining cannot resolve, report
  failure rather than claiming normal final-save completion or silently dropping work.
  Pending scheduled events remain governed by their saved-state policy; draining does not
  mean executing all future or resource-deferred timers before exit.
- R44: Create a new world's durable snapshot-zero base before establishing its first WAL or
  acknowledging any journal snapshot. Include world identity, generator identity/version/
  seed/settings, layout, initial logical tick/global/player state, initial persistent chunk
  overrides if any, snapshot sequence 0, and a defined initial checksum-chain anchor. Validate
  and synchronize the base, install it without overwriting an existing world, and synchronize
  required directory metadata before durably establishing the first segment with that anchor.
  Explicit new-world creation is distinct from opening an existing world with a missing or
  invalid base; the latter must fail visibly and preserve evidence, not regenerate a world.
- R45: Verify compaction inputs against their existing integrity evidence before publishing
  output: the base's physical checksum and protected bounds/identity, and the committed WAL
  transaction checksums/lineage through the target snapshot. A newly calculated output
  checksum does not validate source contents. Verification must cover the actual source
  bytes used to construct output, not rely solely on a successful earlier read/startup check.
  On source validation failure, report corruption, do not install the candidate or advance
  base-backed eviction status, and retain the installed base and required WALs. Apply this
  to both background and startup-recovery compaction; encoded-record copying remains allowed.
- R46: Include an independent checksum in each persisted chunk record, covering its identity,
  persistent content version, framing/codec, persistent flags, encoded blocks, and metadata.
  Use a 32-byte BLAKE3-256 footer in the initial format, identical in base and WAL records.
  Hash the chunk-format domain tag, world identity, and all record bytes before the footer;
  include the footer in total record size but exclude it from its own checksum input.
  Verify indexed chunk reads before publishing decoded contents to the world, including
  identity agreement with the requested chunk and expected version where known. Validate
  lengths/bounds before allocating or interpreting payloads; a checksum does not replace
  structural validation. Keep compatible records relocatable across base/WAL files without
  binding their checksum to physical offsets or segment/snapshot identity. Retain whole-base
  checksums and WAL transaction-chain verification as separate integrity requirements.
- R47: At the start of each normal resident block-timer pass, capture logical tick T and a
  fixed list of resident chunks with timers due at or before T. Process each selected chunk
  once with R78's local transition logic, revalidating current state/incarnation after waits.
  Keep T fixed throughout the pass; do not consume cancelled/replaced events from stale
  observations. Chunks loaded after selection do not expand that list or launch recursive
  passes; they become eligible for a later pass under R78. Preserve finite dirt-to-packed-
  dirt-to-grass catch-up: follow-up deadlines derive from the original deadline and
  may execute in the same pass if due by T and locally eligible. Work due after T waits for
  a later pass even if time advances. Resource/capture deferral publishes no partial operation
  and preserves pending state under R31/R39. No pass is added solely to drain all timers
  before saving; broader simulation scheduling remains deferred.
- R48: Persistent per-chunk revisions advance monotonically for every published persistent
  mutation, including metadata-only and historical-flag changes. Never wrap, reset on reload,
  or reuse an older revision when contents revert to earlier values. Preserve the revision
  in chunk records and installed-base catalogs; derive eviction equality from those identities,
  not mesh/client revisions. Check eligibility and release residency under the service's
  authority so a concurrent mutation or pin acquisition cannot invalidate the decision.
- R49: Use explicitly assigned material enum values and numeric u8 codec IDs, with
  air 0 and custom cells 255. Preserve their meanings across compatible versions; declaration
  reordering must not renumber stored values. Each file header records its save-format version.
  The engine defines its current write version and minimum readable version; reject versions
  outside that supported range before payload interpretation. Adding a material advances the
  write version while retaining the minimum if older saves remain readable. Incompatible
  interpretation changes advance the write version and raise the minimum as needed unless
  explicit compatible legacy decoding is retained. All accepted encodings use one current
  gameplay logic; legacy byte decoding does not select old rules. A sufficiently incompatible
  gameplay change advances the write version and raises the minimum to exclude old worlds,
  even if record layouts stay unchanged. This gates terrain, blueprint libraries, and active
  unfinished instances together, without historical gameplay implementations or per-blueprint
  migration. Older engines reject newer-version files.
- R50: Initially omit material-enum membership validation during loading, including per-cell
  and per-run membership checks. After supported-version, checksum, and structural validation,
  interpret the complete decoded block buffer directly as `[32][32][32]BlockType`, retaining
  the exhaustive `enum(u8)`. Require correct byte layout, alignment, buffer size/lifetime,
  and x-fast order; codec IDs and custom metadata types still receive their schema checks.
  This deliberately trusts compatible writers to emit valid enum values. A checksum proves
  byte integrity, not enum membership: a writer/versioning bug or invalid values with matching
  checksums can still cause undefined behavior. Integrated membership checks and a
  non-exhaustive enum are deferred improvements, not initial requirements.
- R51: Allow at most one construction marker and one pending transformation per cell,
  independently: a cell may have both. Each section has at most 32,768 entries; reject
  duplicate cell indices within a section and indices outside 0-32,767. Timer uniqueness is
  per cell, not per (cell, transformation kind). Custom metadata must contain exactly one
  record per custom cell in x-fast block order, with no missing/extra records and at most
  32,768 records. Derive section and combined metadata byte limits from finalized serialized
  record sizes, framing, and allowed counts/type payload limits using checked arithmetic.
  Apply these semantic rules during mutation and loading independently of allocation policy.
- R52: Use explicitly sized little-endian integer fields throughout base/WAL framing and
  metadata records. Metadata sections carry a stable type identifier, schema version,
  required/optional declaration, and explicit payload byte length. Reject unknown required
  sections, unsupported required section versions, and unknown custom-block types. Skip an
  unknown section/version only when the format explicitly declares it optional and safe
  to ignore. Validate its bounds and enclosing checksum even when skipping. File-version
  acceptance under R49 still applies; extension rules never authorize silent reinterpretation
  of existing bytes or bypass rejection of unsupported file versions.
- R53: Use the confirmed chunk-record, metadata-section, codec-ID, and checksum-domain
  layouts in the [format contract](../formats/world-persistence-v1.md) without native padding. Block codecs are u8 numbers: raw 0, standard RLE 1;
  reject reserved/unknown values 2-255 at per-record dispatch. Persist chunk revisions as
  u64 and historical `is_unreachable` as persistent flag bit 0. Initial metadata sections
  use schema version 1, required flag bit 0, and tags 1 custom blocks, 2 construction
  markers, 3 pending transformations. Emit nonempty sections once in ascending tag order;
  absence means an empty collection, subject to custom-cell correspondence requirements.
- R54: Use the schema-1 [metadata layouts and byte limits](../formats/world-persistence-v1.md#metadata-semantics-and-size-bounds): 2-byte construction
  markers, 11-byte pending transformations, and 2-byte unformed or 23-byte formed adaptive
  road records. Section payload maxima are respectively 65,536, 360,448, and 753,664 bytes.
  Including three 9-byte section headers, the initial combined metadata bound is 1,179,675
  bytes. These are conservative serialized limits, not allocation sizes or expected usage.
  Empty metadata occupies zero payload bytes. Derive version-specific bounds again when
  supported custom types or schemas change; validate framing/counts before allocation.
- R55: Distinguish an incomplete final WAL append from committed corruption or missing
  committed dependencies. Routine recovery may discard a clearly incomplete append after
  the last validated commit when no retained successor depends on it. Complete framed
  transactions with invalid checksums/identity/lineage, invalid required base contents, and
  missing committed dependencies require a fatal recovery error in v1: preserve original
  files, print a clear error identifying the save path and reason to stderr, and exit the
  game with a nonzero status. Do not load an older snapshot, enter gameplay, or run normal
  final-save/compaction cleanup on this path. Do not truncate, overwrite, or retire evidence
  to install an older valid prefix. Ambiguous damage follows the same fatal path; do not
  classify every validation failure at EOF as an incomplete append. Interactive recovery
  and restoration from a user-selected older snapshot are deferred.
- R56: Include a bounded reference-model test harness in persistence v1. Interleave edits,
  snapshot capture, cancellation, commits, WAL rotation, compaction, eviction/reload, and
  crashes using deterministic seeded sequences over a small world. Exercise production
  persistence logic against fault-injected storage that distinguishes written from durable
  state. Under the supported crash model, recovered state must equal a complete valid
  snapshot on the acknowledged history, never precede the last acknowledged snapshot, and
  may include a valid final commit whose acknowledgment was lost. Report reproducible seeds
  and operation/fault sequences. Deliberate committed-corruption cases verify R55 instead
  of assuming the crash-durability guarantee still holds.
- R57: Use the confirmed [binary container layouts](../formats/world-persistence-v1.md#binary-container-layouts), starting at save-format version 1:
  120-byte base and WAL segment headers, an 84-byte transaction header, and a 56-byte commit
  footer. Base index and chunk records are sorted by chunk ID, players by player ID, with
  unique identities and exact count/extent agreement. WAL transactions contain complete
  global/player state and unique changed-chunk records; their total length is in the footer
  so encoding streams without WAL backpatching. Follow record framing, never magic scanning.
- R58: Persist the immutable world descriptor's layout, topology, generator identity/version,
  seed, explicit settings, and tick rate. Do not substitute current generator defaults.
  Serialize global state and player records using the [format layouts](../formats/world-persistence-v1.md#global-and-player-records), with IEEE-754
  little-endian floats, f64 player feet positions, f32 yaw/pitch, and an initially empty
  framed inventory. Retain all historical players; the future concurrent-player limit is
  not a lifetime record-count limit. Session command watermarks govern capture eligibility
  but are not serialized as persistent session counters.
- R59: Use BLAKE3-256 for chunk, WAL-header, transaction, initial-anchor, and base checksums
  with the exact [domain-separated coverage](../formats/world-persistence-v1.md#snapshot-integrity). Validate the immutable segment header even
  when it contains no transactions. Bind each transaction to the complete validated segment
  header and its preceding committed snapshot. Preserve the incorporated logical digest
  during compaction while recomputing the finalized base's physical checksum. Derive snapshot
  zero from the canonical initial logical contents without offsets or self-referential fields.
- R60: Provide one responsive shutdown dialog with phases "Finishing pending actions...",
  "Saving...", and "Finalizing save...". Draining keeps loaders/completion handling alive;
  terminal rejected actions do not block it, and pending saved timers need not execute.
  For a transient failed dependency read, allow one automatic retry after a provisional
  one-second delay. Retry only the failed preparation/I/O step, never an applied or terminal
  rejected action. Keep existing allocation-failure policies unchanged. Persistent failure
  exposes Retry, Cancel exit, and Quit without saving, with a short explanation.
- R61: After a provisional five seconds without meaningful shutdown progress, show a delayed
  status with Keep waiting, Cancel exit, and Quit without saving. The threshold only changes
  the UI: it does not cancel work or establish failure. Do not launch a duplicate retry
  while the original request is still running. Retry becomes available only for a failed
  step after its outstanding work is resolved. Keep waits and retries off the UI thread.
- R62: Cancel exit resumes gameplay while preserving completed effects and outstanding work;
  it does not roll back actions or replay terminal requests. Restore gameplay capture policy
  through safe ownership handoff, retaining request wait timestamps and unsaved age; R73
  save priority still applies when warranted. Respect R30 for any commit already in progress.
  Explicit Quit without saving accepts loss since the last durable
  snapshot, retains base/WAL files, and must not wait indefinitely on a stalled worker.
  If safe worker shutdown cannot finish, process exit uses the supported crash-recovery
  contract without destructive cleanup or claiming final-save success. A durable final WAL
  followed by failed compaction instead exits with the failure reported and WAL retained;
  do not label that case as unsaved final state.
- R63: The v1 durability guarantee targets local APFS storage on macOS, with base, WALs,
  temporary files, and the stable lock in one world directory on the same filesystem.
  Acknowledged snapshots survive process termination, OS crashes, and power loss when the
  filesystem/device honor synchronization and atomic-replacement semantics. Network storage,
  actively cloud-synchronized save directories, external modification, arbitrary durable-data
  corruption, and hardware that ignores flushes are outside this guarantee. Linux/Windows
  durability backends require separate implementation and validation; the binary format is
  platform-independent.
- R64: Use a narrow macOS storage adapter for durable file synchronization with F_FULLFSYNC,
  directory fsync followed by a full device flush on the same filesystem, same-directory
  atomic replacement, no-replace initial installation, and nonblocking exclusive flock.
  Flush application buffers before file synchronization. Publish WAL acknowledgments only
  after durable synchronization; publish BaseInstalled and retire required journals only
  after replacement-directory durability is confirmed. Synchronize creation, truncation,
  and retirement boundaries as specified below. Unsupported/failed primitives must report
  errors, never silently downgrade durability. Ordinary fsync alone is insufficient for
  the agreed macOS power-loss guarantee.
- R65: The reference-model storage fake must model file contents and directory entries
  separately, including partial writes, unsynchronized survival/loss, atomic old/new base
  replacement before directory durability, uncertain effects after failed synchronization,
  reappearing unsynchronized deletions, and lock release after process exit. Use the same
  barrier order as the production adapter. Real-filesystem tests cover replacement, open
  readers, cross-process locking, and error propagation; process-kill tests alone do not
  establish power-loss durability.
- R66: Choose and record v1 tuning defaults through the measurement plan below. Keep memory
  budgets bounded, configurable, and lazily allocated; account for backing capacity, source
  pins, encoded output, and transient copies. Bound pending work by both item count and bytes,
  coalesce save triggers, and reserve completion capacity. Use R34 capacity/overhead accounting
  with existing allocators; custom pool geometry is deferred. Test capture-working budgets of
  16/32/64 MiB, then output-capacity caps of 64/128/256 MiB with an explicitly sufficient total
  working budget. Vary streaming buffers of 64/256/1,024 KiB separately. These are experimental
  inputs, not defaults or preallocations. Include queued and writer-owned output, encoding
  scratch, and large-record staging in accounting; reserve manifest/completion capacity too.
  Keep one concurrent encode/write pipeline with existing bounded overflow/backpressure
  behavior; fitting a complete capture must not require a second buffering mode.
  Compare gameplay/stress workloads with saving inactive, including tail latency, simulation
  pause/debt, player confirmation delay, gate overhead, memory occupancy, and cancellation
  handoff. Select normal capture/player-wait limits and the R73 escalation threshold from
  baseline/frame-budget and save-progress evidence; include R74 workloads. Use
  tiny configured budgets and injected failures rather than exhausting physical RAM.

- R67: Document the expected simulation-heavy workload (approximately 99.9% of chunk updates)
  and player role described in Context. Keep producer identity distinct from spatial priority;
  a simulation update does not become a player command merely because it runs near a player.
  No distant chunk uses persistence COW. The initial implementation uses no persistence COW
  for any chunk; future selective COW requires a separately reviewed policy.
- R68: Pause all simulation dispatch, including near-player simulation and current terrain
  transformations, for the capture-source lifetime. Finish already executing authoritative
  operations before establishing the boundary; do not stop a mutation halfway through.
  Keep world logical time, rendering, player input, and completion handling running under
  their normal pause rules. Resume once all capture sources are released, whether capture
  completed or was cancelled; do not wait for WAL durability or compaction. Normally bound
  the pause with configurable cancellation and measured handoff latency. R73 permits a
  longer visible capture pause for overdue saving, without adding a durability wait to
  source ownership. Other independent memory-pressure gates can still prevent resumption.
- R69: Preserve deferred logical-time progress and catch up against current conditions when
  simulation resumes. Do not equate saved world tick with completed simulation progress or
  silently discard skipped time. Pace catch-up and bound its retained representation;
  do not run an unlimited burst or allocate a record for every skipped tick. R47's fixed
  resident block-timer pass also handles R78 catch-up after loading, using finite local
  transition logic and preserving original deadlines.
  General NPC progress/debt representation, conservation rules, cross-chunk scheduling,
  and economic event ordering belong to the future simulation design. Persist the state
  that design requires when it is introduced.
  This does not add offline elapsed time or serialize the demo worker's private phase.
- R70: Keep mutation and capture correctness under world-service authority. A writable flag
  or global capture notification is advisory to producers, not permission to mutate. The
  actual admission/commit must recheck the capture generation and complete write set.
  Same-process simulation may avoid network serialization, but direct mutation from a
  separate thread requires explicit exclusive ownership, dependency protection, and ordered
  publication. V1 retains the single authoritative mutation worker; such leases are deferred.
- R71: Define pending, applied, terminal rejected, and not-admitted outcomes independently of
  transport. Use stable session/request identities and resolved command prefixes; nonterminal
  notifications cannot retire optimistic edits or make player checkpoints eligible. Keep
  capture-pending primarily internal in v1: brief waits need no new notification, and the
  client retains its outstanding optimistic operation until the terminal response. Coalesce
  nonterminal status for longer delays instead of notifying on every wait or retry; retain
  required visible saving/failure status. Status is advisory and never required for admission
  progress or correctness. Future wire retransmission must deduplicate the same logical
  request and distinguish unknown outcome from rejection, with bounded state and explicit
  session expiry/resynchronization.
  Persistence v1 does not implement networking or promise retry deduplication across process
  restarts without a future persisted operation ledger.
- R72: Preserve one boundary even with progressive release or prioritized encoding. After a
  source is released, newer mutations remain dirty for a later snapshot; this attempt must
  never recapture their newer contents. On abort, merge the captured candidates back into
  pending dirty tracking by current identity without erasing intervening mutations. Service
  completions carry sufficient generation/revision identity to ignore stale releases.

- R73: Eventually prioritize completing an overdue save instead of repeatedly cancelling
  it for normal player/capture wait limits. Use a configurable elapsed unsaved-age threshold
  while dirty work exists; starting/retrying/encoding a save or releasing sources does not
  count as durable success or reset that age. Permit an exceptional visible pause of
  world-changing actions, including player edits, while keeping rendering, camera, UI,
  read dispatch, and completion processing responsive. Enter between complete operations; preserve
  admitted request identities, ordering, and bounded pending/prediction capacity. Do not
  block commands required to establish the selected save boundary behind the new gate.
  Continue streaming within the same budgets and retain player-source priority. Clear the
  capture-related mutation pause on safe source release; track save priority separately
  until durable success. Actual allocation/I/O/repair failure still follows safe failure
  paths; an indefinitely stalled device cannot be promised eventual completion. Preserve
  explicit shutdown choices and R30 cancellation safety. Final shutdown saving is likewise
  exempt from automatic cancellation solely for normal gameplay wait limits.
- R74: Evaluate approximately 10,000 simultaneously active chunks and 2,000-4,000 distinct
  changed chunks per 60-second interval on a 16 GB machine, plus smaller worlds on 8 GB
  machines. Select/report the smaller workload through measurement; these targets neither
  reserve all machine RAM nor cap legitimate metadata or accumulated dirty state. Exercise
  both normal and overdue saving, maximum-record cases, and accumulation beyond one interval.
  Record total memory and base/timer retention alongside capture-output costs.

- R75: Use one logical coordinator watchdog for normal whole-capture/player-wait deadlines
  and R73 overdue-save escalation, driven by monotonic real elapsed time independently of
  simulation ticks. Check the earliest applicable deadline under the current mode; preserve
  each request's original wait timestamp across retries, notifications, newly discovered
  dependencies, and capture epochs. Retry admission on meaningful source-release progress,
  without separate timer-based retry loops per request or chunk. Deadline handling must
  remain serviceable while simulation is paused or the writer is blocked on I/O; it requests
  cancellation through R30's safe handoff and never assumes a deadline releases ownership.
  Exclude deadlines already acted upon or overridden by save priority or final-shutdown
  policy from wakeup selection until they become actionable again, avoiding busy loops.
  No dedicated watchdog thread or general simulation timer framework is required; numeric
  limits remain governed by R66.

- R76: Include bounded instrumentation and a repeatable evaluation harness in persistence v1,
  reusing production capture, writer, and recovery paths. Record the measurement plan's phase
  durations, output pressure, durable progress/freshness, gameplay delays, and memory separately,
  with capture identities and reproducible workload/storage settings. Exercise independent
  write and synchronization delays, full/oversized output, and repeated save/compaction cycles.
  Use deterministic tests for correctness and real elapsed-time runs for performance; a fake
  clock cannot establish latency on hardware. Choose v1 defaults from these results before
  treating the baseline as validated. Alternative capture policies and larger campaigns remain
  follow-ups; no production NPC implementation or unbounded event tracing is required.

- R77: Permit eviction of a chunk whose pending timers are all explicitly lazy when R24's
  installed-base revision and other pin conditions hold, even when a lazy deadline is overdue.
  Lazy means execution may be deferred while nonresident until an eligible block-timer pass
  after ordinary loading under R78, using original deadlines and current local conditions. It is
  a property of timer-kind semantics, not merely a distant deadline, player distance, or an
  empty subscription set. Both existing kinds, compact_dirt and grow_grass, are lazy. A
  recognized kind not explicitly classified lazy retains a timer residency pin while pending; unsupported serialized kinds remain load errors. V1 needs no
  global wakeup/loading scheduler or new serialized lazy flag. Remove resident due-index
  membership on eviction and restore it once on ordinary load. Revalidate timer incarnation
  and residency after waits; selected/executing timer operations retain scoped ownership pins
  until their operation safely completes or defers. A dormant lazy event alone holds no pin.
  Timer consumption, replacement, or cancellation advances persistent revision under R48,
  including metadata-only changes, before subsequent eviction can use base equality.

- R78: Ordinary loading restores saved block/timer state and registers pending timers once
  under R26's stale-load/publication rules. Chunk readiness does not wait for overdue timer
  catch-up. Run catch-up in the next eligible block-timer pass under R47; loads after pass
  selection wait for a later pass. Capture, backlog, or resource pressure may postpone work
  beyond the next frame. Use bounded, fair processing while chunks remain resident and
  execution is permitted; retain unprocessed due work without resetting its deadlines.
  Players, meshes/collision, and dependent commands may observe pre-catch-up terrain; edits
  admitted before timer execution take effect in authoritative order. Recheck current event
  identity/incarnation and expected material so stale timers cannot overwrite newer edits.
  Execute chunk-local transitions in stable (deadline, cell-index) order through the pass's
  fixed cutoff T, deriving follow-up deadlines from the original deadline. Timer execution
  must not read/load adjacent chunks or invoke general multi-chunk simulation/placement
  validation. All authoritative edits affecting eligibility must schedule, replace, or cancel
  affected timers atomically with their full write set, including exposure changes across
  boundaries; preserve current cover/uncover gameplay semantics. Audit all mutation paths
  before removing execution-time neighbor checks. No serialized eligibility flag is required.
  Timer operations follow R31's resource preparation and atomic publication, R68's capture
  gate, and R48's revision/dirty tracking, including metadata-only consumption. Registration
  alone does not consume a timer or dirty unchanged saved state. Persistence-only recovery,
  verification, and compaction reads do not register live timers or execute them. No extra
  timer pass is required for chunk readiness or a save boundary; add no offline elapsed time.

## Clarifications

- Q1: Persist generated or only changed chunks?
  A1: CONFIRMED by the user, with the single-current-logic compatibility policy: changed
  chunks; persist generator identity/version so supported saves reproduce untouched terrain.
  Reject incompatible old worlds instead of retaining historical generator implementations
  or requiring migration. Breaking changes advance the world-save write/minimum-readable
  versions under R49; unsupported generator descriptors are also rejected explicitly.
- Q2: Does simulation advance while closed?
  A2: CONFIRMED by the user: freeze offline world time.
- Q3: Restore exact player movement?
  A3: CONFIRMED by the user: restore position and view; reset motion safely.
- Q4: Which clock drives 60-second saves and 600-second compaction?
  A4: CONFIRMED by the user: monotonic real elapsed time while open, including pause,
  independent of logical ticks, with a final save on clean exit. The user also requires
  applying the WAL before normal exit. A busy writer coalesces autosave triggers.
- Q5: What are the autosave loss-window and manual-save UI policies?
  A5: CONFIRMED scope: use the agreed 60-second autosave schedule and save-on-exit; the user
  explicitly defers manual-save UI. The schedule does not guarantee at most 60 seconds of
  loss: changes since the last durable snapshot can be lost, ordinarily including the save
  interval plus encoding/write time, and longer during delays/failures. Report last-success
  status rather than claiming a fixed recovery window. R73 now prevents endless automatic
  cancellation at the expense of an exceptional visible saving pause. Final save/compaction
  and failure interactions follow Q15/Q38. No manual-save decision remains open for v1.
- Q6: What should happen to the demonstration simulation's private put/remove phase?
  A6: CONFIRMED by the user: exclude the temporary demonstration worker's private state.
  Its committed terrain changes remain world state. No actor continuation guarantee.
- Q7: What is the capture memory budget and exhaustion policy?
  A7: REVISED: no persistence COW reserve in v1. Source retention and independent encoded
  output have different lifetimes; cancellation can release capture holds without reclaiming
  live-world storage. R20/R29/R31/R38 govern capacity and handoff, R66 tuning, and R73 overdue
  saving. No promise of zero allocation or zero latency under arbitrary pressure.
- Q8: How are player state and world edits given a common ordering boundary?
  A8: CONFIRMED: ordered player checkpoints under R42 give player state and terrain one
  authority. Client optimism cannot establish that boundary; dequeuing an I/O-waiting command
  is not completion (R41/R43).
- Q9: What is the exact binary encoding contract?
  A9: CONFIRMED: the [format contract](../formats/world-persistence-v1.md) is the canonical
  reference for all agreed framing, codecs, payloads, IDs, magic values, and checksum coverage.
  R15/R49-R54/R57-R59 retain the corresponding requirements. Assigning explicit constants to
  existing material meanings under R49 is implementation work, not an open format decision.
- Q10: What happens after corruption, a missing journal, or repeated storage failures?
  A10: CONFIRMED v1 policy by the user: incomplete final WAL appends are routine recovery;
  committed corruption, missing committed dependencies, or ambiguous damage preserve the
  original files, print the save path and error to stderr, and exit the game with a nonzero
  status. No recovery selection UI or older-snapshot continuation in v1; those workflows
  and backup retention/export are follow-ups. Never silently create a replacement world.
  Ordinary write/compaction failures retain their existing retry/status contracts;
  shutdown-draining UI/retry behavior is confirmed in Q38.
- Q11: How are persisted nonresident chunks supplied to synchronous validation readers?
  A11: CONFIRMED: base-only indexed loading avoids runtime WAL replay. Exact installed-base
  revision equality plus ownership/gameplay pins establishes reloadability (R24-R26/R48).
  R41 stages dependency waits explicitly; loading/pin APIs remain implementation choices.
  Timer residency follows R77; startup still avoids eager activation (Q16).
- Q12: When should advanced persistence optimizations be implemented?
  A12: RETAINED: defer nibble counts, mutation overlays/replay-on-read, heuristic encoded
  caches, independent deadline scheduling, and adaptive contention feedback. Basic background
  priority, bounded streaming, and cancellation/yield points remain v1. Selective COW, eager
  encoding, and per-chunk simulation scheduling are later experiments using the same harness;
  see Alternatives and Potential Improvements.
- Q13: May memory pressure trigger saving and compaction before their normal intervals?
  A13: CONFIRMED by the user: permit an earlier checkpoint/compaction request under memory
  pressure and coalesce redundant triggers. With base-only reloads, recent modified chunks
  remain resident even after WAL commit; cache budgets remain soft while correctness pins
  prevent eviction.
- Q14: Can multiple game instances open the same save?
  A14: CONFIRMED by the user: prohibit multiple instances targeting the same save. Use a
  stable world-level OS lock, acquired before recovery and held until all I/O completes.
- Q15: What happens if final saving or compaction fails during exit?
  A15: CONFIRMED by the user: allow an explicitly reported exit with retained WALs when
  the final snapshot is durable but compaction fails. If the final snapshot itself is not
  durable, present retry/cancel-exit/quit-with-unsaved-changes choices. Do not report normal
  fully compacted completion for either failure case.
- Q16: Must world startup load all chunks with unfinished timers?
  A16: CONFIRMED by the user: no. Ordinary access activates saved timers; persistence-only
  reads do not. REVISED: R77 permits eviction with only lazy pending timers. A non-lazy
  pending kind retains residency once loaded until a future scheduler supports unloading it.
  This does not promise global activation of nonresident future simulation events.
- Q17: Must a committed snapshot fit a base smaller than 4 GiB?
  A17: CONFIRMED: remove the 4-GiB restriction rather than add a compacted-size preflight.
  R14 and the [large-file contract](../formats/world-persistence-v1.md#large-file-format-and-arithmetic)
  widen offsets and aggregate arithmetic while retaining u32 chunk IDs.
- Q18: Must every WAL transaction scan or repair the file, and when is cancellation too late?
  A18: CONFIRMED: repair uncertain appends from the remembered synchronized boundary,
  keeping scans and repair off the normal path (R23). Footer writing is the R30 commit point
  after which cancellation cannot be reported; a valid unacknowledged final transaction may
  still be recovered after a crash. The WAL Failure Repair section explains the sequence.
- Q19: How are capture failure policy and implementation choices separated?
  A19: REVISED: full-write-set admission replaces COW detachment; lightweight reservation
  and selective staging remain (R31/R37). R38 distinguishes capture contention from actual
  allocation failure. The capture plan and AC121 retain progress between captures; R66
  covers measured limits.
- Q20: Should all metadata arrays share one contiguous backing allocation?
  A20: RETAINED: separate nonempty arrays and allocation-free empty storage. REVISED/CONFIRMED:
  retain inline metadata descriptors and the existing block pointer (R32-R34). A combined
  persistent-owner/block allocation is unnecessary without COW; contiguous metadata remains
  an optional later optimization.
- Q21: Does capture require physically splitting the live `WorldChunk`?
  A21: REVISED/CONFIRMED: no physical split initially (R32/R33). Restricted views isolate
  encoder access without changing live ownership. Copying historical packed flags at the
  boundary also avoids races with derived-bit updates; see Persistent Contents and Live Chunk
  State. Inline grouping is optional; future version ownership requires separate justification.
- Q22: How should allocation, growth, and memory accounting work initially?
  A22: REVISED/CONFIRMED: existing allocators and budget accounting first (R34/R35).
  Custom pools and the former provisional 64-byte class are deferred until allocation cost
  or fragmentation is measured. Capacity accounting differs from process residency; semantic
  limits (R51/R54) and format compatibility do not depend on pool geometry.
- Q23: Does this iteration implement whole-system budgeting and priorities?
  A23: RETAINED: whole-system budgeting is the separate [follow-up](resource-budgeting.md).
  Persistence v1's capture gate and player-source priority are required to make no-COW
  capture usable; they do not choose a global residency or near-player scheduler (R36).
- Q24: How much normal-path work should allocation-failure safety introduce?
  A24: CONFIRMED: lightweight preparation and in-place mutation under R31/R37 avoid a general
  rollback framework. Existing validation work can often supply reservation information;
  exact mechanisms and overhead still need measurement. Configured budget exhaustion needs
  the same atomicity as physical allocation failure.
- Q25: What if memory is still unavailable after capture cancellation?
  A25: RETAINED: genuine allocation failure uses R38's one-useful-handoff retry allowance;
  ordinary capture contention is an elapsed wait, not a failed allocation. Cancelling capture
  is useful only when release can help. R39/R40 govern simulation deferral and failure status.
- Q26: How do asynchronous dependencies affect command/checkpoint/save ordering?
  A26: CONFIRMED: dependency loading is part of the command lifetime (R41-R43). Here an
  accepted terminal outcome means applied, not admitted to a queue. This distinction keeps
  checkpoints and shutdown from treating unresolved I/O as completed gameplay.
- Q27: What anchors journals before the first periodic compaction of a new world?
  A27: CONFIRMED by the user: install a small durable snapshot-zero base with world/generator/
  layout/initial state and its chain anchor, then establish the first WAL. No WAL snapshot
  may be acknowledged before that base is durable. Keep explicit creation separate from
  opening an existing world whose base is missing; never silently replace the missing base.
- Q28: Must compaction revalidate inputs, and should individual chunk records be checksummed?
  A28: CONFIRMED: source verification prevents compaction from making corrupted data look
  valid merely by checksumming its output (R45). Per-record checksums enable indexed reads
  without scanning the base; they supplement transaction completeness and ordering (R46).
  Exact bytes are in the [chunk layout](../formats/world-persistence-v1.md#chunk-record-layout).
- Q29: What timer eligibility and catch-up behavior belongs in persistence v1?
  A29: RETAINED: fixed resident-pass tick/list, original deadlines, finite soil-transition
  chains, no recursive draining before saving, and no offline elapsed-time catch-up.
  REVISED/CONFIRMED: ordinary loading restores/registers lazy block timers; R78 catches them
  up in the next eligible block-timer pass without delaying readiness. Execution uses local
  state with eligibility maintained by authoritative edits, including edits before catch-up.
  Block timers remain distinct from broader NPC simulation, whose scheduling is deferred.
- Q30: Must eviction inspect active/sealed WALs or maintain separate pending-WAL eligibility?
  A30: CONFIRMED by the user: no. Compare the current persistent chunk revision with its
  revision in the durably installed readable base, then check ownership/gameplay pins.
  Monotonic revisions cover every persistent mutation and survive eviction/reload; matching
  revisions establish reloadability without examining WAL membership or dirty flags.
  WAL-commit tracking remains necessary for saving, but is not part of the eviction predicate.
- Q31: Which block encodings should the first version implement?
  A31: CONFIRMED by the user: only standard byte material/count pairs, falling back to raw
  when the encoded block payload exceeds 32^3 bytes. No initial uniform/palette mode or
  per-chunk material statistics. Retain explicit lengths, runs split at 255, and the previously
  agreed trailing-air omission. Document palette encoding with optional maintained statistics
  and standard streaming compression available in the selected Zig toolchain as follow-ups.
- Q32: How do material enums and save-format compatibility evolve?
  A32: CONFIRMED by the user: explicit numeric enum assignments and separate current-write/
  minimum-readable versions. Adding a block type advances the write version but keeps older
  saves loadable when their meanings/layout remain supported; incompatible changes raise
  the minimum readable version. Avoid a separate per-block ID validation pass. Check both
  version bounds so an older engine cannot accept a file containing newer material IDs.
  CONFIRMED single-current-logic policy: all accepted encodings run the same current gameplay
  rules. A sufficiently incompatible gameplay change raises the write and minimum-readable
  versions to reject old worlds as a whole; retaining historical rules or migrating blueprint
  definitions/unfinished instances independently is not required.
  CONFIRMED by the user: initially reinterpret the decoded block buffer as the existing
  exhaustive enum array without material membership checks, trusting correct writers and
  careful format-version compatibility. The user accepts the undefined-behavior risk if
  those assumptions fail despite valid checksums. Defer integrated validation and a
  non-exhaustive enum as possible improvements; retain the enum-based runtime representation.
- Q33: What are the initial metadata entry and size limits?
  A33: CONFIRMED by the user: at most one construction marker and one pending transformation
  per cell, at most 32,768 entries per section, and rejection of duplicate/out-of-range cell
  indices. The limits are independent, so a cell may occur in both sections. Custom records
  correspond exactly to custom cells in block order. R54/Q36 now define the exact serialized
  layouts and byte limits; future schemas derive limits from records/counts, independently
  of allocation policy.
- Q34: What are the compatibility and extension rules for binary sections?
  A34: CONFIRMED: explicit versioned framing under R52 allows only declared safe optional
  extensions. A length does not make unknown gameplay data ignorable or bypass the overall
  file-version gate; see the [extension contract](../formats/world-persistence-v1.md#section-compatibility-and-extensions).
- Q35: Which concrete binary framing and IDs should the initial format use?
  A35: CONFIRMED: the [format contract](../formats/world-persistence-v1.md) records the R53
  chunk framing, codec IDs, metadata headers/tags, and checksum-domain bytes. Fixed framing
  permits bounded streaming and unambiguous validation without native struct layout.
- Q36: What are the concrete metadata payload layouts and resulting byte limits?
  A36: CONFIRMED: schema-1 [metadata layouts and bounds](../formats/world-persistence-v1.md#metadata-semantics-and-size-bounds)
  implement R54. Road ownership fields enable later edits; derived heights need no stored
  floats. Serialized maxima describe valid data, not worst-case preallocation.
- Q37: What are the base/WAL containers, world/player records, and full checksum coverage?
  A37: CONFIRMED: R57-R59 and the [format contract](../formats/world-persistence-v1.md)
  define containers, world/player records, and checksum coverage. Footer lengths permit WAL
  streaming without backpatching; logical snapshot digests survive physical compaction.
- Q38: What minimal UI and retry behavior should shutdown draining failures have?
  A38: CONFIRMED: one responsive shutdown dialog under R60-R62. Delay indicates uncertainty,
  not failure, so waiting work must not be duplicated. The Shutdown Status section retains
  the phase/choice table and provisional retry/status timings; Q49 records the later deadline
  exemption. Final-save versus compaction failure remains the distinction in Q15.
- Q39: What platform and filesystem durability assumptions apply to v1?
  A39: CONFIRMED by the user: local macOS/APFS with the storage primitives and ordering
  below, including F_FULLFSYNC for the device-cache barrier. Acknowledged state survives
  supported process/OS/power failures when the storage stack honors these operations.
  Keep all world artifacts on the same filesystem, exclude network/actively cloud-synced
  storage from the guarantee, and fail explicitly instead of falling back to weaker sync.
  Model these semantics in fault injection and verify native integration separately.
  Linux/Windows durability adapters are follow-ups without a binary-format redesign.
- Q40: How should the remaining implementation parameters be chosen?
  A40: CONFIRMED by the user: document the workload/measurement matrix now and select defaults
  during implementation. Use bounded internal configuration and small parameter sweeps, not
  new player-facing controls. Keep the agreed one-second transient-read retry and five-second
  delayed-status indication as provisional values; use resource notifications plus bounded
  backoff for simulation retries. Establish baseline/frame-budget evidence before choosing
  latency regression thresholds. Test pressure safely with configured limits/fault injection.
  Record selected values and evidence as routine engineering decisions; revisit with the user
  only if measurements reveal a meaningful gameplay tradeoff or require a design change.

- Q41: Which choices are newly agreed, and which remain proposals?
  A41: CONFIRMED starting policy and later approvals are collected in Context. Concrete
  state/queue APIs remain implementation choices. Baseline instrumentation and evaluation
  are required by R66/R76; numeric limits require measurement. Later optimized policies
  remain proposals. Q45 distinguishes design readiness from performance validation.
  Unaffected confirmed decisions remain in force.
- Q42: Does a global pause last through WAL synchronization or compaction?
  A42: DERIVED: source release, not WAL durability, ends the capture pause (R68). Slow
  storage can nevertheless extend capture by filling bounded output buffers. That coupling
  motivates normal cancellation and the explicit overdue-saving exception (R73).
- Q43: Must catch-up reconstruct every historical intermediate world?
  A43: CONFIRMED by the user: no; use current conditions while preserving logical-time
  progress and preventing duplicate effects. Future courier transfers must conserve goods
  atomically across their full affected state, workers cannot manufacture output for periods
  without eligible inputs, and builders must revalidate blueprints/resources. These are
  future simulation constraints, not an NPC implementation or a new save schema in this PR.
  CONFIRMED deferral: decide economic event ordering in the future simulation spec, including
  whether a delivery due before food expiry must be processed first after a capture pause.
  Current-conditions catch-up does not settle that ordering or guarantee unchanged economic
  outcomes across persistence delays. Local block timers follow the separate R47/R78 rules.
- Q44: Can simulation mutate service chunks directly from another thread?
  A44: The same-process clarification permits considering that optimization; it does not
  establish its synchronization design. R70 retains the existing service mutation worker
  in v1 and defers exclusive mutation leases. In-process intent/batch submission is compatible
  with that contract; the concrete API is an implementation choice.
  Any later lease must cover dependencies and authoritative publication, not only block bytes.
- Q45: What needs measurement before calling the implementation validated?
  A45: REQUIRED IMPLEMENTATION EVIDENCE under R66/R76: acceptable player confirmation
  latency and observable near-player simulation pause in normal mode; normal capture duration and overdue-save
  escalation threshold; cancellation/checkpoint backoff; catch-up service capacity; and
  buffer/queue sizes for the R74 target workloads. These are tuning and validation work,
  not unanswered v1 policy questions. The global-pause baseline must be tested
  against the normal no-noticeable-freeze requirement, with the explicit Q46 exceptional
  saving pause assessed separately. If normal operation fails, revisit per-chunk scheduling,
  near-player continuation, eager capture, or selective near-player COW rather than silently
  weakening that requirement. No finite-memory policy guarantees uninterrupted successful
  saves and edits under an indefinitely stalled disk or unbounded workload.

- Q46: May overdue saving visibly pause world-changing actions?
  A46: CONFIRMED on 2026-10-19: eventual save completion can justify an exceptional visible
  action pause. This qualifies the normal responsiveness target rather than asserting an
  invisible long wait. R73 defines escalation; thresholds and concrete mode/gate APIs remain
  measurement/design choices, and failed storage cannot be forced to succeed.
- Q47: What workload and machine sizes should the first usable version target?
  A47: CONFIRMED: R74 records the 10,000-active / 2,000-4,000-changed-chunk target on 16 GB
  and smaller worlds on 8 GB. Smaller-world size and defaults need measurement. Larger
  output-capacity experiments in the same pipeline are agreed under Q51; a separate
  whole-capture buffering mode and custom pools remain deferred.
- Q48: Does each capture or pending player request need its own timer/retry loop?
  A48: CONFIRMED: one coordinator watchdog under R75 avoids per-request timer/retry loops
  while preserving elapsed-wait fairness across epochs. Timer APIs and deadline data
  structures remain engineering choices, separate from simulation event scheduling.
- Q49: Do normal gameplay deadlines cancel the final shutdown save?
  A49: CONFIRMED: stopped producers remove the gameplay reason for short capture deadlines
  during final saving. R73 retains the shutdown exemption; R62/R75 govern safe restoration
  of gameplay policy when exit is cancelled, without resetting waits or overdue-save age.
- Q50: Must every capture wait produce a client-visible pending message?
  A50: CONFIRMED: client optimism can cover brief waits without a new pending message.
  R71 keeps pending primarily internal and coalesces longer-delay status while retaining
  required visible saving/failure status. Networking and reconnect machinery remain deferred.

- Q51: Should absorbing a whole capture require a separate buffering pipeline?
  A51: CONFIRMED by the user: first evaluate larger output capacity in the existing concurrent
  encode/write pipeline (R66). It can absorb a fitting capture without waiting for stalled
  writes, while larger captures use the same bounded streaming behavior. R73 remains the
  fallback for overdue saving. More capacity absorbs bursts; it cannot fix sustained storage
  overload or slow encoding. R76 makes the evidence needed to choose defaults part of v1.

- Q52: Which timers are lazy, and when does reload catch-up run?
  A52: CONFIRMED: compact_dirt and grow_grass are lazy. Ordinary loading restores/registers
  timers; catch-up runs in the next eligible block-timer pass under R47/R78. The user accepts
  outdated terrain being visible, even beyond a frame or two. This supersedes catch-up before
  exposure and removes a separate load-time execution stage. Edits may precede overdue timer
  execution and must atomically maintain eligibility; local event/material checks prevent
  stale effects. Identical state, cutoffs, and ordered edits are deterministic; changing the
  edit/timer order may change outcomes. Original deadlines and finite catch-up chains remain.
  Capture, backlog, and resource pressure may delay execution; fair bounded passes retain
  due work. Future economy events need their own scheduling contract and do not inherit
  these local block-timer semantics.

## Acceptance Criteria

- AC1: GIVEN an edit changes several chunks WHEN captured during repeated edits THEN each
  recovered snapshot contains the complete transaction or its complete predecessor.
- AC2: GIVEN due timer transitions and constructed/custom metadata WHEN saved and loaded
  THEN material, construction rules, road ownership, and deadlines match the captured state.
- AC3: GIVEN a frozen captured version WHEN a persistent mutation requests it THEN
  the mutation waits without partial effects until its complete source is safely released,
  the encoded record retains the boundary contents, and newer live contents remain dirty.
- AC4: GIVEN a chunk changes again after capture WHEN the older save succeeds THEN the newer
  version remains dirty and appears in a later successful snapshot.
- AC5: GIVEN a committed base/journal history WHEN a journal is truncated at any byte THEN
  recovery exposes only a complete validated snapshot and never a partial transaction.
- AC6: GIVEN journal rotation and compaction WHEN a crash is injected at each durability,
  rename, and cleanup boundary THEN all acknowledged snapshots remain recoverable.
- AC7: GIVEN several segments and a partially completed compaction WHEN loading THEN
  recovery handles segment order/lineage and already-incorporated records deterministically.
- AC8: GIVEN malformed sizes, offsets, checksums, versions, codec IDs, or metadata WHEN
  decoding THEN loading returns a descriptive error without overflow or out-of-bounds access.
- AC9: GIVEN arbitrary valid chunks WHEN encoded by every applicable mode and decoded THEN
  blocks and metadata round-trip exactly, including custom cells, empty chunks, runs over
  255 cells, and omitted trailing air in standard mode.
- AC10: GIVEN a saved changed chunk with no live subscription WHEN requested after loading
  THEN it loads from the recovered base before generator fallback; empty overrides stay
  empty. During that session, modified state newer than the base remains resident and no
  runtime chunk read requires WAL replay.
- AC11: GIVEN an incompatible older generator/world-save version WHEN reopening THEN loading
  explicitly rejects the unsupported save/descriptor before gameplay instead of selecting a
  historical generator or silently producing different terrain; supported descriptors retain
  their saved dimensions/settings and use the current implementation.
- AC12: GIVEN time spent with the game closed WHEN loading THEN world tick/deadlines do not
  advance, player position/view restore, and movement resumes from a safe reset state.
- AC13: GIVEN a slow writer/compactor, exhausted reserve, failed sync, or full disk WHEN
  gameplay and autosave triggers continue THEN queues remain bounded, errors remain visible,
  and no newer dirty state or previous durable state is discarded.
- AC14: GIVEN a large dirty set and sustained simulation load WHEN persistence runs THEN
  capture/interaction latency, simulation pauses, memory, and contention are measured against
  R66's selected thresholds, with no persistence COW copies. Encoding and I/O remain off
  the authoritative worker; a global pause is not considered validated solely because
  rendering remains responsive.
- AC15: GIVEN unchanged live state after a durable commit WHEN another checkpoint occurs
  THEN unchanged chunks are not rewritten, while world time/player records still commit.
- AC16: GIVEN successful final save and compaction WHEN normal shutdown completes THEN the
  next startup requires no WAL recovery and loads the final accepted world/player state.
- AC17: GIVEN a checksum chain WHEN a transaction payload, sequence, identity, or interior
  dependency changes THEN validation rejects that transaction and its dependent suffix.
- AC18: GIVEN a partially appended or cancelled transaction WHEN another save succeeds THEN
  recovery reaches the newer commit without crossing an invalid abandoned suffix.
- AC19: GIVEN base installation through a captured chunk version WHEN that chunk has a newer
  live persistent revision THEN the acknowledgment does not make it evictable, even if the
  newer revision is already WAL-durable; once its
  exact current version is installed and all pins clear, eviction and base reload round-trip.
- AC20: GIVEN a chunk load in flight WHEN compaction installs a new base or a live edit occurs
  THEN the load uses its matching generation/index and cannot overwrite newer live state.
- AC21: GIVEN an opened world WHEN another instance/session targets the same canonical world
  THEN it is rejected before recovery or persistence mutation; after owner exit/crash a new
  owner can acquire the lock without deleting a stale lock file.
- AC22: GIVEN persisted constructions/roads or timer metadata WHEN a chunk is loaded through
  normal world access THEN validation dependencies and road ownership are restored and its
  saved timers enter existing processing, without requiring global timer-chunk activation.
- AC23: GIVEN a chunk frozen for capture WHEN any player, simulation, timer, metadata,
  or historical-flag path requests mutation THEN it passes the same complete-write-set
  gate, cannot initiate persistence COW, and mutates in place only after safe release.
- AC24: GIVEN memory pressure before the next scheduled checkpoint/compaction WHEN an early
  request is triggered THEN persistence may run early while preserving the single-writer/
  single-compactor limits and coalescing duplicate requests.
- AC25: GIVEN a durable final snapshot WHEN shutdown compaction fails THEN exit remains
  available, the failure is reported, and retained base/WAL files recover that snapshot.
- AC26: GIVEN a final snapshot that could not be made durable WHEN exit is requested THEN
  the user can retry, cancel exit, or explicitly quit with unsaved changes.
- AC27: GIVEN a resident chunk whose pending timers are all explicitly lazy WHEN its exact
  current revision is in the installed base and other pins clear THEN it is eviction-eligible
  even with overdue deadlines, and removing residency removes its live due-index membership.
  WAL-only durability, a newer live revision, or a pending non-lazy timer still blocks eviction.
- AC28: GIVEN saved nonresident chunks with pending terrain transformations WHEN opening,
  recovering, or compacting a world THEN those persistence operations do not materialize
  live chunks or activate their timers solely because unfinished timers exist.
- AC29: GIVEN a saved lazy-timer chunk not loaded at startup WHEN ordinary streaming or
  gameplay dependency access later loads it THEN its original deadlines are restored and
  timers are registered once without catch-up delaying readiness. Due work becomes eligible
  under R47/R78. Repeated loads do not duplicate registration/effects; registration alone
  does not change persistent revision, and lazy events alone add no blanket residency pin.

- AC30: GIVEN base files, WAL segments, and transactions extending beyond 2^32 bytes WHEN
  written, validated, recovered, compacted, and read by index THEN sizes and offsets retain
  all bits and records on either side of that boundary are addressed correctly. Exercise
  boundary cases with sparse files or virtual I/O rather than multi-GiB buffer allocations.
- AC31: GIVEN a layout with 2^32 possible chunk IDs WHEN computing chunk counts and index
  extents THEN the count is 2^32 and a complete 12-byte-entry index occupies 12 * 2^32 bytes,
  without truncation or intermediate overflow. Arithmetic tests need not materialize it.
- AC32: GIVEN overflowing offset/length or count/stride combinations, out-of-file ranges,
  or values unrepresentable by a platform I/O/allocation API WHEN processed THEN return a
  descriptive error without wrapping, truncation, out-of-bounds access, or replacing the
  previous durable save. Include values near the u64 boundary and narrower API boundaries.
- AC33: GIVEN snapshot 10 synchronized and snapshot 11's complete footer written WHEN its
  synchronization fails and snapshot 12 is attempted THEN the writer truncates to 10 and
  synchronizes that repair before appending 12 linked to 10. No replacement segment or
  rotation may introduce a competing continuation, including after repeated repair failures.
- AC34: GIVEN a failed/cancelled append requiring repair WHEN truncation or its synchronization
  fails THEN gameplay continues, dirty state and the confirmed boundary remain retained,
  failure is visible, and no new append/rotation occurs until repair succeeds. Repair uses
  the remembered boundary without scanning the WAL; successful saves do no repair work.
- AC35: GIVEN cancellation racing with commit-footer writing WHEN the writer resolves the
  race THEN cancellation accepted before that phase prevents footer writing and requires
  repair for any partial tail; otherwise a successful sync is acknowledged, and a failed
  commit attempt enters repair-required state rather than being reported as cancelled.
- AC36: GIVEN a complete final transaction whose synchronization failed WHEN a crash occurs
  before, during, or after repair THEN recovery preserves acknowledged snapshots and may
  include that final transaction only if fully valid and contiguous. Once repair is durable
  the removed transaction cannot reappear; a later acknowledged retry has one valid lineage.
- AC37: GIVEN an encoder reading frozen A WHEN capture is cancelled THEN A remains
  immutable until the reader reaches a safe bounded stop and relinquishes ownership.
  Accepted cancellation prevents new reads; no buffer is mutated or recycled early.
- AC38: GIVEN an operation changes several chunks WHEN writable storage or metadata/publication
  allocation fails at any preparation step THEN no partial authoritative blocks, metadata,
  revisions, dirty state, or notifications are exposed. After handoff and revalidation, a
  retry applies the complete operation once, in order; snapshots see only complete states.
- AC39: GIVEN cancellation accepted before committing and stalled WAL I/O/repair WHEN the
  encoder has finished active reads and released its references THEN affected edits can
  resume once exclusive ownership and resources are available, without waiting for disk
  repair. The cancelled save retains dirty state and cannot publish a commit footer.
- AC40: GIVEN a snapshot entering the commit phase WHEN cancellation is requested for memory
  pressure THEN all chunk reads/references have already been released, the commit follows
  R30, and chunk ownership does not remain pinned until synchronization completes.
- AC41: GIVEN a chunk without dynamic metadata WHEN initialized or genuinely copied
  THEN its empty arrays allocate no backing storage. Adding entries to one array does not
  reserve worst-case capacity for the others; capture itself does not clone these arrays.
- AC42: GIVEN a captured snapshot view WHEN its sources are released and a mutation
  completes THEN the encoder/writer no longer uses borrowed buffers, its independent output
  retains the captured contents, and live caches match the new contents. Preparation failure
  leaves both unchanged; the view exposes no live header, derived cache, or runtime field.
- AC43: GIVEN an active snapshot view WHEN only derived/runtime state changes THEN
  persistent identity/dirtiness is unchanged and no persistent mutation gate is needed.
  Derived face-flag updates preserve the historical bit; the encoder uses its boundary-time
  copied historical value and never reads the live packed flags. Changing historical
  `is_unreachable` itself still follows the persistent mutation gate.
- AC44: GIVEN a persisted chunk WHEN loaded into gameplay THEN derived boundary masks, block
  count, and face flags are reconstructed from its contents, historical flags are restored,
  and client validation state is initialized by its runtime owner. Gameplay/client copies
  retain caches consistent with their own contents, including after optimistic edits.
- AC45: GIVEN existing metadata arrays and a budgeted allocator WHEN an unborrowed array
  needs growth THEN preparation reserves the simultaneous old/new capacities before copying,
  unrelated live allocations retain valid addresses, and failure preserves existing contents
  and valid ownership. An array borrowed by capture cannot be resized/freed until source release.
- AC46: GIVEN a semantically valid metadata request within R51/R54 limits WHEN available
  budget and the underlying allocator permit it THEN existing allocation mechanisms serve
  it without a new pool/class-size restriction. Budget exhaustion or allocation failure
  follows the resource-failure path; invalid entry/payload sizes fail semantic validation.
- AC47: GIVEN metadata copying or growth WHEN allocation failure is injected at each
  step THEN no OOM panic, leak, partial mutation, or capture corruption occurs. Accounting
  includes allocated capacity and transient growth allocations without double-counting pins.
- AC48: GIVEN an admitted edit with exclusive ownership and prepared capacity WHEN
  it completes THEN it mutates in place without an additional whole-chunk copy for capture
  or failure handling. Existing client-replica copies are measured separately.
- AC49: GIVEN completed validation/dependency discovery WHEN preparing and applying an edit
  against unchanged authoritative inputs THEN reuse its results without repeating the full
  discovery traversal. If deferral invalidates inputs, revalidate before applying rather
  than reusing a stale operation description.
- AC50: GIVEN simple edits, cross-chunk roads, and timer batches WHEN comparing the
  baseline with the new mutation path, saving inactive and active THEN report worker CPU,
  allocations, copied bytes, and tail edit latency, separating gate/preparation, pending
  wait, existing client copying, encoding, and cancellation costs.
- AC51: GIVEN a pending player edit whose genuine allocation failure survives one useful
  safe-handoff retry WHEN it is rejected THEN report `resource_exhausted`, preserve contents,
  and reconcile the optimistic effect without later automatic replay. Mere capture contention
  remains nonterminal and follows the elapsed-wait policy instead of this retry count.
- AC52: GIVEN capture/resource-blocked simulation or timer work WHEN time advances THEN
  effects remain unapplied, pending progress stays bounded, and timers/inputs are not consumed.
  After release, paced retries revalidate current conditions and apply effects at most once,
  preserving original deadlines and logical progress rather than dropping skipped time.
- AC53: GIVEN exhausted allocation capacity WHEN a request cannot proceed THEN its reserved
  completion/status path reports the failure without a new allocation. Diagnostics distinguish
  budget exhaustion, allocator failure, and non-retryable semantic-limit violations.
- AC54: GIVEN a resource-rejected player edit WHEN capacity later returns THEN the old edit is
  not silently replayed, while a newly submitted edit can succeed. Other operations that have
  sufficient prepared capacity may continue without requiring the game to exit.
- AC55: GIVEN an edit waiting for a persisted neighbor WHEN later I/O completions, commands,
  player checkpoints, or save requests arrive THEN the edit remains unresolved and required
  command order is preserved. Neither dequeue nor dependency-read completion alone permits
  a checkpoint/save barrier to treat the edit as applied.
- AC56: GIVEN an operation whose dependencies finish loading WHEN it becomes ready THEN it
  validates current authoritative contents and commits atomically or rejects explicitly.
  Newly discovered missing dependencies return it to waiting without effects; stale load
  completions cannot overwrite newer versions or validate against superseded contents.
- AC57: GIVEN a player checkpoint depending on command N WHEN all required commands through
  N are terminal THEN it becomes eligible, including when N is rejected. A completion beyond
  an unresolved gap cannot advance eligibility, and deferral/cancellation requests are not
  terminal outcomes by themselves. Command sequences from another session do not satisfy it.
- AC58: GIVEN an empty inbound queue but an admitted operation waiting for I/O WHEN shutdown
  drains THEN dependency/completion processing continues and final capture waits for required
  operations/player records to resolve. Failure cannot produce normal shutdown success;
  pending scheduled events remain saved according to their existing policy.
- AC59: GIVEN a new world WHEN its first WAL is established THEN a validated snapshot-zero
  base and required directory entries are already durable. The WAL identifies that world
  and sequence/hash anchor; failures during base installation cannot produce an acknowledged
  journal snapshot or a successful world-creation result.
- AC60: GIVEN crashes injected during snapshot-zero writing, synchronization, installation,
  and first-segment establishment WHEN reopening THEN either no valid world exists and
  opening reports incomplete creation, or the validated base permits safe initialization
  recovery. Temporary/truncated files are never promoted as a completed base without validation.
- AC61: GIVEN snapshot zero plus acknowledged WAL snapshots and no periodic compaction yet
  WHEN the process crashes and restarts THEN recovery reconstructs the last valid committed
  world from that base and journal chain, including the saved generator configuration.
- AC62: GIVEN an existing world's base is missing/invalid or persistence artifacts already
  occupy a creation destination WHEN opening/creating THEN report the error and preserve
  artifacts rather than regenerating a base, inventing an anchor, or overwriting the world.
- AC63: GIVEN corruption in a compaction input's base contents/index or committed WAL payload/
  framing WHEN background or recovery compaction runs THEN source validation rejects it even
  if the candidate output has a self-consistent new checksum. No candidate installation,
  base-install acknowledgment, or retirement of required journals occurs.
- AC64: GIVEN source files previously validated WHEN a read supplies changed/corrupt bytes
  during compaction THEN verification of the actual consumed bytes detects the mismatch and
  prevents publication. Include corruption in superseded records still covered by required
  whole-base/transaction integrity checks, not only records selected for the final index.
- AC65: GIVEN valid base/WAL inputs WHEN compaction copies compatible encoded records THEN
  source checksums and lineage are verified, records need not be decoded/re-encoded, and
  only the fully validated/synchronized candidate can be installed with its new checksum.
- AC66: GIVEN an indexed chunk whose record bytes have changed since startup validation WHEN
  it is loaded THEN the record checksum/structural/identity checks reject corruption before
  world publication, without scanning the whole base or substituting generated terrain.
- AC67: GIVEN a compatible valid chunk record WHEN moved from a WAL into a new base or to a
  different base offset THEN its record checksum remains valid without re-encoding, while
  container checksums and WAL lineage remain independently required.
- AC68: GIVEN a resident pass selecting A at tick T WHEN another ordinary load publishes B
  with overdue block timers THEN B is not added to A's fixed pass and no recursive pass is
  launched. B can be observed/edited before catch-up and becomes eligible for a later pass.
  Captures contain complete published operations and may retain overdue timers;
  persistence-only reads preserve saved timers without registering or executing them.

- AC69: GIVEN an eligible block-timer pass with an overdue dirt-compaction timer WHEN
  its grass-growth follow-up is also due by the fixed cutoff T and locally eligible THEN both
  transitions may complete using the original deadline relationship. A follow-up after T
  remains pending even if world time advances during processing or resource waits.
- AC70: GIVEN selected block-timer work delayed before execution WHEN its event is cancelled/
  replaced or authoritative state changes THEN local identity/material checks prevent stale
  effects without adjacent-chunk reads. Capture/resource failure preserves authoritative
  state without partial effects; deferred work follows R39. Eligibility-changing edits
  update affected timer state atomically under R78, including across chunk boundaries.
- AC71: GIVEN equal live/installed-base persistent revisions, a readable matching catalog,
  and no pins WHEN checking modified-chunk eviction THEN it is eligible without inspecting
  WAL segments or consulting separate dirty/pending-WAL flags. Redundant journal records or
  stale bookkeeping do not prevent the decision; missing/mismatched base revisions do.
- AC72: GIVEN a chunk whose installed-base revision is 12 WHEN persistent contents change
  to revision 13 and later return to their earlier values THEN the later revision advances
  again rather than reusing 12. Neither a stale base-install message nor WAL acknowledgment
  permits eviction until the current revision is installed and pins clear.
- AC73: GIVEN an evicted chunk WHEN reloaded and modified only in metadata or a historical
  flag THEN its stored persistent revision is restored and advanced without wrap/reuse.
  Snapshot/load/gameplay pins still block eviction despite matching installed-base revision,
  and eligibility checking cannot race with a mutation or newly acquired pin.
- AC74: GIVEN standard block payloads below, equal to, and above 32,768 bytes WHEN choosing
  the initial codec THEN select standard for the first two and raw for the third, with raw
  containing exactly 32,768 x-fast block bytes. Metadata/checksum bytes do not affect this
  payload comparison because their framing is common to both codecs.
- AC75: GIVEN standard runs exceeding 255, a trailing-air suffix, or an all-air chunk WHEN
  round-tripped THEN long runs split into nonzero byte counts and omitted suffixes decode
  as air; an empty standard payload decodes to 32,768 air cells. Reject odd RLE byte lengths,
  zero counts, decoded overflow, or any raw payload length other than 32,768.
- AC76: GIVEN an engine update that adds a material while preserving prior IDs/layout WHEN
  writing/loading THEN new saves carry the increased write version, older supported saves
  remain readable, and an older engine rejects the newer save at the header version gate.
- AC77: GIVEN an incompatible material/schema/gameplay change WHEN the write and minimum
  readable versions advance to exclude old worlds THEN older files are rejected without
  reinterpretation or historical-rule execution, even if the byte layout is unchanged;
  reordering enum declarations alone does not change explicitly assigned stored IDs.
- AC78: GIVEN a valid file emitted by a compatible writer WHEN decoding THEN no per-cell or
  per-run material-membership check is performed. After version, checksum, size/run, codec,
  and metadata validation, the owned decoded buffer is interpreted directly as the exhaustive
  enum array with correct layout, alignment, lifetime, and exactly 32,768 cells. This criterion
  does not promise safe rejection of invalid enum bytes carrying matching checksums.
- AC79: GIVEN an unsupported version, corrupt checksum, or invalid payload bounds WHEN loading
  THEN reject the record before interpreting its buffer as `BlockType` or publishing it to
  gameplay. Direct interpretation does not bypass existing integrity/structural checks.
- AC80: GIVEN construction/timer sections WHEN validating THEN accept up to 32,768 distinct
  valid cell indices in each independently, including a cell with both a marker and timer;
  reject excessive counts, duplicate indices within either section, and out-of-range indices.
  Two timer kinds for one cell still violate the one-pending-transformation rule.
- AC81: GIVEN custom cells in decoded block order WHEN validating metadata THEN require one
  schema-valid record for each such cell in that order and reject missing/extra records.
  A chunk without custom cells must not carry custom records, while 32,768 custom cells
  require exactly 32,768 records.
- AC82: GIVEN metadata counts/lengths near schema limits WHEN validating THEN derive byte
  bounds from serialized record sizes/type limits and framing with checked arithmetic, rejecting
  overflow or inconsistent lengths. Allocation strategy and budget do not change semantic
  validity; allocation proceeds only when budget and underlying memory are available.
- AC83: GIVEN known integer field values WHEN encoding/decoding base, WAL, and metadata
  fixtures THEN bytes match the specified little-endian widths independently of host byte
  order, alignment, or native struct padding.
- AC84: GIVEN an otherwise valid supported file with an unknown required metadata section,
  unsupported required section version, or unknown custom-block type WHEN loading THEN
  reject explicitly without treating the bytes as another schema or dropping required state.
- AC85: GIVEN a supported file with an unknown explicitly optional safe-to-ignore section
  WHEN loading THEN skip exactly its declared payload length and decode subsequent sections
  correctly. Invalid bounds/checksums still fail, and optionality does not permit opening
  an unsupported overall file version.
- AC86: GIVEN raw and standard RLE chunk fixtures WHEN encoded THEN codec IDs are respectively
  u8 0 and 1, the record follows the confirmed field order with 58 bytes of fixed overhead,
  and its length includes the 32-byte checksum. Unknown codecs fail at per-record dispatch.
- AC87: GIVEN empty and nonempty metadata collections WHEN serialized THEN empty sections
  are absent and nonempty sections appear once in ascending type order with the specified
  9-byte headers, schema version 1, and required bit. Reject duplicate/out-of-order sections
  and missing custom metadata for custom cells; section lengths exactly fill the enclosing
  metadata payload without a terminator or section count.
- AC88: GIVEN a chunk-record checksum fixture WHEN hashing THEN input is the exact chunk
  domain bytes including one trailing zero, the container's 16-byte world UUID, and every
  record byte before the footer. Changing identity, revision, flags, lengths, codec, blocks,
  or metadata invalidates the checksum; relocating the same record within the world does not.
- AC89: GIVEN construction and timer payloads WHEN decoded THEN entries occupy exactly 2
  and 11 bytes respectively, counts come from payload lengths, and nondivisible lengths or
  more than 32,768 entries fail before allocation. Existing index/uniqueness checks apply.
- AC90: GIVEN unformed and formed adaptive roads WHEN round-tripped THEN records occupy 2
  and 23 bytes respectively, preserving formation endpoint, direction, length, and section
  so heights and ownership can be restored. Reject unknown type/state/direction, truncated
  records, zero formed length, or section indices outside the formation.
- AC91: GIVEN schema-1 metadata WHEN checking serialized size bounds THEN section payload
  caps are 65,536 construction, 360,448 timer, and 753,664 custom bytes, with a combined
  cap of 1,179,675 including headers. Bounds do not replace semantic validation or require
  allocating maximum capacity; empty collections produce zero metadata payload bytes.
- AC92: GIVEN a validated base/commit chain followed by a clearly incomplete final append
  with no retained successor depending on it WHEN startup recovery runs THEN it can discard
  that suffix and recover the last valid commit without requiring a rollback decision.
- AC93: GIVEN a complete WAL transaction with a checksum mismatch, a missing committed
  dependency, or corrupt required base contents WHEN recovery finds an older valid candidate
  THEN it preserves original files, reports the save path and reason to stderr, and exits
  with nonzero status without loading the candidate or running final-save/compaction cleanup.
- AC94: GIVEN ambiguous final-record damage or a malformed interior transaction with later
  dependent commits WHEN recovery runs THEN it does not silently treat the error as an
  incomplete tail or skip across the damaged dependency; R55's fatal recovery path applies.
- AC95: GIVEN a bounded seeded sequence interleaving edits, capture, cancellation, commits,
  rotation, compaction, and eviction/reload WHEN a supported crash is injected and recovery
  completes THEN all persistent chunk, metadata, global, and player state matches one valid
  reference snapshot on the acknowledged history, never a mixture or a snapshot older than
  the last acknowledgment. A valid final commit with lost acknowledgment is permitted.
- AC96: GIVEN the same seed and recorded operation/fault choices WHEN a harness failure is
  replayed THEN its scheduling and storage outcomes are reproducible. Failures report the
  seed and sequence; the bounded v1 suite covers each modeled operation and critical commit,
  repair, rotation, and base-install boundary rather than relying on chance alone.
- AC97: GIVEN deliberately corrupted committed bytes or a missing committed dependency
  WHEN the harness runs recovery THEN it verifies R55's preservation, stderr, and fatal-exit
  behavior instead of treating fallback to an older snapshot as successful crash recovery.
- AC98: GIVEN initial-format base fixtures WHEN encoded/decoded THEN their 120-byte header,
  section order/lengths, sorted unique index/player/chunk identities, and trailing 32-byte
  checksum match the defined layout. Reject inconsistent counts, offsets, sizes, or extents.
- AC99: GIVEN a saved descriptor with explicit terrain parameters and optional base height
  WHEN reopened after runtime defaults change THEN generation uses the saved settings and
  supported generator version. Reject unsupported layout/topology/generator settings instead
  of substituting defaults; global state restores the saved tick without offline advancement.
- AC100: GIVEN player records including offline players WHEN a base or WAL snapshot is
  round-tripped THEN feet positions, view angles, and identities survive with the specified
  float widths, legacy 52-byte empty-inventory framing, and current 53-byte one-slot
  inventory framing. Reject nonfinite coordinates/angles;
  movement reset and collision validation still apply. Do not cap historical players at 16.
- AC101: GIVEN a WAL with streamed chunks of initially unknown encoded sizes WHEN writing
  and recovering THEN the header is 120 bytes, transaction header 84 bytes, and commit footer
  56 bytes. Total length includes the footer, counts consume exact records, repeated sequence
  agrees, and no WAL backpatch or payload-magic scanning is required. Duplicate chunk IDs fail.
- AC102: GIVEN fixtures for each checksum domain WHEN verified THEN coverage exactly matches
  the specified input bytes. WAL-header mutation is detected even in an empty segment;
  moving a transaction to a different segment invalidates its digest, while compatible
  chunk-record relocation within the world retains its record checksum.
- AC103: GIVEN snapshot zero and a later compacted snapshot WHEN calculating integrity data
  THEN the initial anchor hashes canonical logical contents without offsets/self-reference,
  and compaction retains the incorporated transaction digest while calculating the physical
  checksum from finalized base bytes, including the final header and index.
- AC104: GIVEN shutdown with admitted dependency-waiting operations WHEN draining runs THEN
  the dialog remains responsive, loaders/completions continue, and final capture waits for
  resolved operations/player checkpoints. Rejected actions resolve their dependencies and
  saved future/resource-deferred timers do not have to execute before exit.
- AC105: GIVEN a transient dependency-read failure during draining WHEN automatic retry
  runs THEN only the failed nonterminal step is retried once after the configured delay
  (initially one second). Further failure exposes user choices, without replaying applied
  or rejected actions or bypassing existing memory-failure limits.
- AC106: GIVEN shutdown with no meaningful progress for the configured delay (initially
  five seconds) WHEN the delayed dialog appears THEN Keep waiting leaves the original work
  active without a duplicate request. No action is abandoned and no retry starts solely
  because the threshold elapsed; an actual failure enables Retry.
- AC107: GIVEN a failed or delayed shutdown WHEN Cancel exit is selected THEN gameplay
  resumes with completed effects and outstanding operations preserved. Any active commit
  resolves under R30, and stale shutdown completions cannot subsequently terminate gameplay.
  Gameplay capture policy is restored through safe ownership handoff without resetting request
  wait timestamps or unsaved age; overdue-save priority still applies when warranted.
- AC108: GIVEN a stalled shutdown worker WHEN the player explicitly selects Quit without
  saving THEN exit does not wait indefinitely or destructively clean up persistence files.
  Restart follows the supported crash-recovery guarantees for previously durable snapshots.
  A final WAL already durable followed by compaction failure reports that failure and exits
  with the WAL retained, without an inaccurate unsaved-final-state warning.
- AC109: GIVEN an established durable WAL segment WHEN a transaction succeeds THEN all
  application buffers are flushed and F_FULLFSYNC succeeds before acknowledgment. A required
  synchronization failure cannot acknowledge success or silently fall back to ordinary fsync.
- AC110: GIVEN a compaction candidate WHEN installing it THEN candidate file durability
  precedes atomic replacement, directory fsync plus the same-filesystem full flush precedes
  BaseInstalled and journal retirement, and retirement-directory changes are synchronized.
  Failure to confirm replacement durability retains required WALs and blocks BaseInstalled.
- AC111: GIVEN new-world/WAL creation or failed-append repair WHEN claiming the relevant
  boundary durable THEN file data/length and required directory/parent entries are persisted
  using the specified barriers. Initial installation cannot overwrite an existing world;
  repair cannot permit another append before the truncated length is durably synchronized.
- AC112: GIVEN supported crash-model injections WHEN recovery runs THEN acknowledged state
  survives permitted old/new base outcomes, partial unsynchronized writes, uncertain failed
  flushes, and reappearing unretired WAL names. Durable-data corruption uses the separate
  R55 path rather than weakening the crash-model invariant.
- AC113: GIVEN the macOS/APFS adapter WHEN native integration tests run THEN concurrent
  processes cannot own the same world, process exit releases the lock, open old-generation
  readers survive atomic base replacement, and primitive failures reach persistence status.
  Passing process-kill tests alone is not reported as proof of power-loss durability.
- AC114: GIVEN the tuning workload matrix WHEN evaluating candidate settings THEN record a
  saving-inactive baseline and comparable saving/compaction runs, including frame/operation
  p95/p99 and observed maxima, capture/copy/encoding costs, memory/queue occupancy, and
  cancellation handoff. Record selected defaults and regression thresholds with their evidence.
- AC115: GIVEN existing allocators with budget accounting and bounded work queues WHEN
  exercising configured limits THEN allocated/spare capacity, transient copies, reservations,
  and retained queue bytes are tracked without double counting. Known allocator overhead and
  unmeasured overhead/fragmentation are distinguished from those counters and process telemetry.
  Triggers coalesce, completion resources remain available, and pressure follows the agreed
  failure paths. Budget sizes do not force preallocation or become semantic metadata limits.
- AC116: GIVEN allocation-failure and reserve-exhaustion scenarios WHEN verifying robustness
  THEN tiny configured budgets and injected failures exercise them reproducibly without
  deliberately exhausting physical RAM or forcing swap. Performance tuning must preserve
  atomicity, bounded work, safe ownership handoff, and responsive UI behavior.

- AC117: GIVEN a snapshot captured at T and chunk A encoded/released before B WHEN a player
  operation changes A and requests B THEN the complete operation waits until B is safe;
  the saved transaction contains both T versions and the later operation remains dirty.
- AC118: GIVEN an advisory writable observation WHEN capture begins before mutation admission
  THEN the actual service gate detects the new epoch and defers the whole operation.
  Newly discovered road/revelation/timer dependencies cannot bypass admission.
- AC119: GIVEN normal-mode capture, stalled disk I/O, and full output buffers WHEN the
  player-wait or capture limit expires before R73 escalation THEN accepted cancellation
  releases sources after bounded safe reader steps
  without waiting for disk repair, UI/service completions remain responsive, and the writer
  cannot append a commit footer for the cancelled attempt.
- AC120: GIVEN a released source, intervening mutations, and a delayed old completion WHEN
  capture fails or a newer attempt exists THEN dirty tracking retains the current revisions
  and the stale release cannot unlock a source belonging to the newer capture epoch.
- AC121: GIVEN capture completion or cancellation WHEN all source holds clear THEN all
  simulation classes may resume through paced dispatch even while WAL synchronization or
  repair continues; another save cannot immediately repause work before useful progress.
- AC122: GIVEN a capture-pending player command WHEN a brief wait sends no notification,
  a longer delay produces coalesced status, or delayed replies/modeled retransmissions occur
  THEN the logical request remains unique, its optimistic effect stays pending until a
  terminal result, and dependent checkpoints cannot pass the unresolved prefix. Status does
  not resolve or replay the command; waiting/prediction capacity stays bounded without
  per-retry notifications. Required exceptional-saving/failure status remains visible.
  Terminal resource rejection still removes the optimistic effect.
- AC123: GIVEN simulated capture delays and current-world changes WHEN catch-up resumes THEN
  retained logical progress is processed against current conditions without duplicate effects,
  a queue entry per skipped tick, or an unlimited burst. R47/R78 block-timer criteria apply;
  the future NPC scheduler is represented by test workloads, not implemented here.
- AC124: GIVEN raw/high-entropy blocks, metadata near supported limits, or many dirty chunks
  WHEN collecting a snapshot THEN bounded output/manifest capacity is respected, no 1-2 KiB
  average-size assumption becomes a correctness limit, and backpressure stays bounded.
  Normal cancellation and R73 continued streaming preserve authoritative atomicity; actual
  inability to reserve required working capacity reports failure without overrunning budgets.

- AC125: GIVEN a captured snapshot view WHEN the authoritative chunk map grows or relocates
  entries THEN encoding remains valid through pinned backing buffers and copied descriptors/
  scalars, without dereferencing a relocated `WorldChunk` header. Borrowed buffers cannot be
  freed, reused, resized, or mutated before synchronized source release.
- AC126: GIVEN materialized and all-air chunks WHEN capture constructs their views THEN only
  small scalars and buffer descriptors are copied; no full chunk header, derived caches,
  persistent-owner object, or all-air block allocation is created solely for capture.
  View/manifest capacity remains accounted for under the capture budget.

- AC127: GIVEN repeated normal capture cancellations and dirty work WHEN elapsed unsaved
  age reaches the configured threshold THEN save priority survives retries and normal wait
  deadlines no longer cancel the attempt. With finite progressing I/O, sufficient bounded
  workspace, and no injected failure, the fixed captured transaction becomes WAL-durable.
  Encoding/source-release notifications alone cannot reset age or report successful saving.
- AC128: GIVEN entry into save-priority mode WHEN player and simulation work compete THEN
  executing operations finish atomically, required pre-boundary commands remain serviceable,
  and deferred requests retain identity/order/optimistic state within bounded capacities.
  New work receives backpressure before admission; rendering/camera/UI remain responsive and
  show the exceptional pause. Source release clears this pause before WAL synchronization;
  escalation after all sources were released introduces no new mutation pause.
- AC129: GIVEN save-priority mode and stalled or failed storage WHEN progress stops THEN
  visible status and existing exit choices remain serviceable, no durability acknowledgment
  is invented, no unlimited queue grows, and actual failures retain safe handoff/repair rules.
  A failed working-capacity reservation cannot be fixed by bypassing its budget.
- AC130: GIVEN the R74 16 GB workload and measured smaller 8 GB workloads WHEN evaluating
  normal saves, accumulated dirty state, and metadata-heavy cases THEN record successful
  save age/rate, pause duration, confirmation delay, and total/capture/pinned memory separately;
  publish the measured supported envelope rather than inferring it from block bytes alone.
- AC131: GIVEN a final shutdown save with progressing I/O WHEN its duration exceeds normal
  gameplay capture/player-wait limits THEN it continues within the same budgets, with the
  existing responsive shutdown status and explicit choices; the elapsed limit alone does
  not create an endless cancel/retry loop or override a commit already in progress. The R75
  watchdog excludes these overridden deadlines from wakeup selection during final saving.

- AC132: GIVEN multiple capture-blocked requests with different original wait timestamps
  WHEN source releases, retries, new dependencies, capture epochs, and save-priority mode
  changes occur THEN one coordinator selects the earliest actionable deadline without
  resetting those timestamps, retries admission on meaningful source-release progress, and
  stays serviceable during paused simulation or blocked writer I/O. Already handled deadlines
  and normal limits overridden by save priority do not cause repeated wakeups/cancellations;
  any requested cancellation still respects R30 ownership and commit boundaries.

- AC133: GIVEN the same streaming pipeline with independently delayed writes and synchronization
  WHEN a capture fits the available output and working capacity THEN all sources can release
  before delayed writes complete, without an early durability acknowledgment. For an oversized
  capture, filling output retains the same boundary and bounded memory; normal cancellation
  or save-priority streaming follows R20/R73 without restarting solely to change buffering mode.
  After sources clear, a delayed final synchronization does not extend the capture pause.
- AC134: GIVEN replayable workloads and independently controlled write/synchronization delays
  WHEN running the R76 evaluation scenarios THEN reports contain the defined phase, pressure,
  freshness, gameplay, and memory metrics plus workload/configuration/seed provenance. Known
  injected stalls are attributed to the correct phases; fake-clock results are identified as
  correctness evidence, not hardware timings. Multi-cycle runs report trends and overload,
  including failed/cancelled attempts rather than only successful saves.

- AC135: GIVEN a timer pass or dependency wait racing with eviction/reload WHEN work resumes
  THEN scoped operation pins protect active readers/operations and stale residency or cancelled/
  replaced timer observations cannot execute. A recognized non-lazy kind in a mixed timer set
  prevents eviction; missing lazy classification is not permission to unload. After a lazy
  timer changes blocks or metadata, an older installed-base revision cannot permit eviction.

- AC136: GIVEN an ordinarily loaded loose-dirt chunk with overdue compaction and an eligible
  grass follow-up WHEN capture, backlog, or resource pressure postpones its timer work THEN
  the chunk may become ready and expose saved terrain with the original timers still pending.
  Once execution is permitted, fair bounded passes make progress while it remains resident.
  Without intervening edits, a pass cutoff T covering both deadlines produces grass; if only
  compaction is due by T, packed dirt retains the original future grass deadline. If an edit
  first cancels/replaces a timer or changes eligibility, stale work has no effect. Deferred
  work remains pending; no partial authoritative timer operation is published.

- AC137: GIVEN identical local block/timer state and cutoff T WHEN repeating catch-up or
  comparing one large step with incremental cutoffs through T without intervening edits
  THEN logical block/timer results agree and repeated catch-up at T has no additional effect.
  Replaying identical cutoffs and ordered edits also agrees; different edit/timer ordering
  need not produce equal outcomes. Publication revision counts may differ with grouping
  but remain monotonic. Cover/uncover
  edits across a chunk boundary maintain eligibility atomically; timer execution performs
  no neighboring reads/loads. Stale concurrent load results cannot overwrite newer state.

## Constraints

The v1 durability target is local APFS on macOS under R63-R65. Keep persistence algorithms
and format independent of the small platform storage adapter; do not advertise guarantees
for unvalidated filesystem/platform combinations.
Keep single-writer authority for world mutations. Chunk IDs depend on saved world layout.
Persist complete chunk images rather than cell deltas. Support one WAL writer and one
compactor, with concurrent operations on distinct active/sealed segments. Preserve prior
durable data on failures. Base format and custom/material IDs need explicit compatibility
contracts. Save-file offsets and aggregate sizes/counts use u64; practical file sizes remain
subject to platform/filesystem capacity. Actual autosave loss and latency depend on successful I/O.
Runtime chunk reads use the base, not journals; versions newer than the base are retained
in RAM. Cache budgets are soft while correctness pins prevent eviction. A stable world lock
is independent of the replaceable base and temporary/WAL files.
Timer-kind residency pins apply under R77 after ordinary loading; pending lazy timers alone
retain no residency. Opening a world does not eagerly load saved timer-bearing chunks or
activate a global scheduled-event system.

## Out of Scope

Manual-save UI is deferred; v1 uses autosave and save-on-exit.
Linux/Windows durability adapters and durability guarantees for network filesystems or
actively cloud-synchronized save directories are deferred.
Multiplayer networking; inventory beyond the player's single carried block;
offline simulation catch-up; nibble RLE; delta chunk journals; per-chunk
mutation overlays/replay-on-read; heuristic encoded caching; adaptive I/O throttling unless
profiling requires it; startup through a WAL overlay; serializing rendering caches or
optimistic client state; unversioned procedural regeneration; and saving the temporary
demonstration simulation's private state. Runtime loading of chunks from WAL records is
also out of scope under the confirmed eviction policy. Persistence COW, synchronous encoding
on the mutation worker, direct simulation-thread mutation leases, and an independent deadline
scheduler with advance loading are deferred alternatives. Custom block/metadata pools and
their page/size-class geometry are potential improvements outside persistence v1. Future NPC
scheduling, inventories, and persistent actor/progress schemas are not implemented here.
Global discovery/preloading of unfinished timers and a redesigned scheduled-event system
are also deferred. A replacement-segment fallback for failed WAL append/repair is out of scope.
Dedicated uniform/palette codecs, maintained material-count statistics, and general-purpose
streaming compression are deferred; initial block storage uses standard RLE or raw only.
A general live-state rollback framework is not part of the initial atomic-mutation design.
Interactive corruption recovery, selecting/restoring an older snapshot, and backup/export
management are deferred; v1 preserves files, reports fatal recovery errors to stderr, and exits.
Whole-system RAM/pressure control, player-versus-simulation admission budgets, player movement
gating on denied loads, and simulation-throttling UI are covered by the separate
[resource-budgeting follow-up](resource-budgeting.md), planned immediately after persistence v1.

## Plan

The no-COW/global-pause starting policy, current-conditions catch-up, scale targets, and
exceptional visible pause for overdue saving are confirmed.
Unchanged format/durability sections retain their prior confirmed status. The plan describes
how to implement and evaluate the agreed contracts; concrete interfaces, data structures,
and sequencing remain engineering choices. R66/R76 require baseline evaluation; later
optimization stages remain conditional proposals. Q45 lists the evidence needed to validate
the implementation. The user authorized this implementation after the design review.

### Approach

1. Initialize a new world's durable snapshot zero, or validate/recover an existing world.
   Keep creation and opening distinct; see New-World Initialization and Recovery Failure
   Classification.
2. Resolve the save barrier and eligible player checkpoints, then capture between complete
   authoritative operations under R1/R41-R43/R47. Pause simulation dispatch, freeze the dirty
   manifest, and copy small global/player state. The candidate bookkeeping is O(number of
   candidates) and needs measurement; the capture protocol is detailed below.
3. Encode the frozen sources into independent bounded output, prioritizing player dependencies,
   and stream one WAL transaction. Process source-release and durable acknowledgments as
   separate events. Use R75's watchdog with R73's normal/priority policy; the capture and WAL
   repair sections define cancellation and failure handling.
4. At a committed boundary, establish the next active segment and compact sealed inputs into
   a verified new base. Publish its immutable generation/index handle before reconciling
   base-backed revisions and eviction. Existing readers may finish through older handles;
   see Compaction Source Verification and Residency and Persistence Feedback.
5. On shutdown, stop producers, drain admitted operations and eligible player state, finish
   current persistence work, save, and compact. Shutdown Status defines responsive choices.
6. Coalesce periodic and pressure-triggered work under the same concurrency/capacity limits.
   Encoded records on disk already support reuse; any optional in-memory cache needs measured
   benefit and persistent-content identity including metadata, not age or mesh revision.

### Decision Impact Relative to PR #28

Stable requirement/criterion IDs are preserved; revised items replace their earlier COW
wording in place. New requirements start at R67 and new criteria at AC117.

| Existing decisions | Effect of the revised requirement |
| --- | --- |
| R2, R5, R20, R29, R31; Q7/Q12/Q19 | Replace mandatory COW with frozen-source admission, pending mutations, safe release, and capture limits. |
| R32-R35; Q20-Q22 | Keep logical field categories, empty metadata, budget accounting, and fallible preparation; retain the existing `WorldChunk` layout and restricted views. Defer custom pools; remove the mandatory physical split, combined owner/block slot, and version cloning. |
| R37-R43; Q24-Q26 | Keep in-place mutation, atomicity, resource failure, command prefixes and shutdown ordering; distinguish capture-pending work from terminal rejection. |
| R47/R78/R18; Q29/Q52 | Restore/register timers on load; catch up in the next eligible fixed resident pass, allowing edits first; retain local execution, edit-time eligibility maintenance, and no offline time. |
| R28/R77; Q16/Q52 | Replace blanket retention of loaded timer-bearing chunks with eligibility for all-lazy timer sets; keep exact-base and other pin requirements. |
| R36/R66; resource-budgeting R8/R11 and Q3/Q5/Q7 | Include minimal capture gating/priority now; account for source pins/output/debt and measure latency; keep global pressure control a follow-up. |
| R1/R3-R4/R7-R17/R21-R28/R30/R44-R46/R48-R65, except policy references clarified above | Retain snapshot atomicity, serialized layouts/codecs/checksums, WAL/base lineage, durability/recovery, eviction and shutdown contracts. |
| Future simulation-thread direct writes | Consider separately; not implied by same-process placement and not needed for persistence v1. |

### Alternatives, Costs, and Upgrade Boundaries

The selected first version is no COW, all-simulation capture pause, and asynchronous player
mutation deferral with priority encoding, normal safe cancellation, and R73 escalation for
overdue saving. The alternatives below remain
proposals; relative complexity is a design assessment, not measured CPU cost or an estimate
of implementation days. Every alternative still needs atomic mutations, dirty revisions,
source lifetime safety, bounded output, recovery, and failure reporting.

| Policy | Additional complexity | Advantages | Costs and correctness implications |
| --- | --- | --- | --- |
| Simulation submits; service returns deferred | Low to moderate above the common mutation gate | Producer need not predict capture; naturally covers discovered dependencies | Wasted computation; bounded retry state, revalidation and wakeup/backoff required; do not turn waits into failed gameplay actions. |
| Simulation checks per-chunk readiness before starting | Moderate | Avoids much wasted work; resumes independent chunks early | Check is advisory and races with capture; atomic write-set admission remains mandatory. Cross-chunk work and changing dependencies complicate scheduling. |
| Pause all simulation during capture | Lowest scheduler complexity; selected first | One dispatch gate; no simulation COW; easy controlled baseline | Unrelated and near-player simulation also pauses; slow capture creates visible pauses and catch-up debt. Normal capture deadlines, overdue-save escalation, and paced resume are required. |
| Pause distant simulation; continue near players | Moderate to high | Can preserve nearby activity | Need radius/priority policy, movement hysteresis, deduplicated player regions, and mixed near/far dependency handling. Near activity needs its own gate/eager/COW policy. |
| Terminally reject player edits and let clients retry | Small server mechanism, substantial end-to-end protocol work | No duplicated source; small server wait state | Extra round trips, optimistic rollback/flicker, reordered dependent edits, stale intent, duplicate effects on lost replies; fixed retry counts cannot survive arbitrary capture duration. Not selected. |
| Keep admitted player edits pending; prioritize background capture | Moderate; selected first | Preserves one request/prediction; no round trip retry loop or synchronous encoding on authority | Confirmation can lag; bounds, ordering, output backpressure and cancellation must be explicit. Does not prove delays invisible. |
| Encode a conflicting chunk synchronously before mutation | Moderate to high | Avoids retaining a raw clone; can release that source promptly when output fits | Moves variable CPU/metadata work onto mutation authority; raw fallback, multiple dependencies, ownership races and output reservations can exceed a latency budget. |
| Selective COW for eligible player/near-player work | High | Ordinary mutations can proceed while an old source is encoded; copying is usually predictable per byte | Adds deep-copy ownership, fallible multi-chunk detachment, transient budgets and concurrent reclamation; still needs a no-COW policy for distant sources and safe fallback on exhaustion. |

The three simulation options can share one correctness mechanism. Start with a global dispatch
gate; later add a per-chunk scheduling hint and a deferred result without changing the disk
format. A successful readiness observation is never an exclusive mutation right. Near-player
eligibility must consider an operation's entire write footprint, including revelation/road
side effects. A nearby courier or player edit cannot authorize COW of a distant dependency;
wait or capture that dependency, and publish the whole transaction together. Reads also need
validation if a future executor publishes concurrently.

COW costs on untouched chunks are not full-buffer copies. With one mutation authority, COW
can use an ownership/epoch check per touched chunk or prepared transaction, not per voxel read,
and need not perform atomic reference-count operations in every gameplay access. There may
still be an extra owner indirection/header, cache traffic, pin/release work, and mutation-path
branches. A no-COW frozen-source design also needs an admission check; removing all checks
would break capture isolation. Thus there is no defensible unmeasured percentage penalty for
having COW available. The strongest reason to defer it is the additional lifetime/failure
state space, especially when separate simulation threads can mutate directly.

A full COW implementation must audit every persistent write path, deep-copy nonempty metadata,
reserve all affected versions before publication, undo partial preparation on allocation
failure, keep caches/revisions coherent, and reclaim versions only after readers finish.
Cancellation races with encoding, commit and reclamation. No-COW still needs source handoff
and atomic preparation, but removes detach/publish-old-vs-new/reclaim-old-version transitions.
The current code already clones for validation, mutation results, and client subscriptions;
those costs must not be counted as new persistence COW overhead or assumed removed by this plan.

With one snapshot in flight, a captured chunk ordinarily detaches at most once before that
old source is released; repeated edits to its private live version do not each require a
snapshot copy. Peak extra memory follows distinct captured chunks modified while their old
sources remain retained, plus metadata/capacity overhead. As scale examples, 10,000 retained
32 KiB block copies are 312.5 MiB; 100,000 are about 3.05 GiB. These are arithmetic bounds for
those counts, not workload measurements. Encoding order and pin duration matter more than
raw edit count alone. A 99.9% simulation operation share is not a guarantee about the number
of player-touched chunks or their dependency footprint.

Eager encoding and copying both read the 32 KiB block array. A raw copy writes another 32 KiB
and still needs later encoding; eager encoding writes the encoded payload and avoids that
extra clone pass. But RLE performs run detection/branches, metadata serialization, and hashing;
optimized copying may be much faster on cache-resident input. RLE raw fallback can do an
attempted encoding scan followed by a raw copy. The hypothesized 1-2 KiB output is not measured
or guaranteed: blocks can use the full 32 KiB raw payload and allowed metadata can reach
1,179,675 bytes before common record overhead. Neither memory-bandwidth nor CPU bottlenecks
are established yet. A scalar codec microbenchmark alone would not settle frame-time impact.

### Simulation Pause and Catch-Up Semantics

The global world tick continues under the application's existing world-pause rules while
capture defers simulation execution. A saved tick describes time, not an assertion that every
actor/event has reached it. Existing terrain timers retain original deadlines, including
ones overdue at the capture boundary. Use R47's current-state evaluation and finite chain.
Stop new simulation dispatch, not completion processing or the world service itself.

For the future scheduler, preserve logical progress compactly, for example a last-completed
simulation time plus pending event state. This representation is a proposal for that feature,
not a new per-chunk field or NPC schema required in persistence v1. Bound dispatched work and
catch-up CPU per service slice; retain unprocessed debt rather than dropping it at the limit.
Do not record one queued operation per missed tick. In overload, bounded memory/CPU may mean
increasing lag: eventual catch-up requires sustained processing capacity above incoming work,
including the capacity lost during repeated capture pauses. Report lag and apply backpressure;
no scheduling rule can guarantee recovery under indefinitely insufficient capacity.

Current-conditions catch-up intentionally does not reproduce every historical intermediate
world. Courier pickup and delivery occur at different times: each transfer must atomically
conserve goods across its affected state, including carried cargo, and must not be applied
twice. Cargo and journey progress between transfers must be persistable when that feature
is introduced; the journey is not one long transaction. Worker output requires eligible inputs
and cannot blindly multiply a production rate by all skipped time if inputs only arrived later. A builder rechecks remaining blueprint
work/resources and records completed progress once. A resumed player edit or another actor may
have invalidated earlier plans; revalidation can change what work is still possible. Actor
identity, inventory, resource eligibility, cross-chunk transfers, and progress must eventually
be captured together with terrain to avoid loss/duplication after restart. Those schemas and
scheduler semantics belong to the future simulation feature; the current demo private phase
remains explicitly excluded. No elapsed time while the application is closed is added.

### Staged Evaluation Without Format Changes

With implementation authorized, stages 1-3 implement and evaluate the agreed
baseline. Stages 4-5 are conditional follow-up proposals, not requirements to add complexity:

1. Build/test the agreed codec, WAL/base formats, storage adapter, recovery, compaction,
   dirty identities, and reference-model harness using immutable test inputs. This establishes
   correctness infrastructure without selecting an optimized live capture policy.
2. Integrate the selected no-COW capture policy: one mutation authority, frozen manifest,
   global simulation dispatch pause, independent encoded output, pending player requests,
   priority encoding, normal bounded wait/cancellation, R73 save-priority escalation, and
   paced resume. Safe cancellation, bounded queues, and eventual-save policy are part of
   this first usable baseline, not postponed safety work. Exercise current
   soil timers plus synthetic couriers/workers/builders as stress workloads; do not implement
   the production NPC systems.
3. Measure against saving-inactive operation using the same input traces and fault schedules.
   Validate the normal no-noticeable-freeze requirement through frame/input time, player confirmation
   delay/corrections, and visible near-player simulation pause, not average encoding throughput.
   Separately exercise exceptional saving pauses and prove finite slow I/O can complete a
   save without deadline cancellation loops. Use R74 scale targets and smaller 8 GB cases.
   If the baseline meets targets, keep it. If it fails, report the specific limiting resource.
4. If unrelated simulation loses too much time, replace only global dispatch gating with
   per-chunk readiness scheduling plus the same authoritative admission check. If nearby
   activity requires special treatment, evaluate an explicit near-player policy including
   moving players and full cross-chunk dependency sets.
5. If player wait remains the bottleneck, compare bounded eager encoding and selective
   near-player COW on the same workloads. Add only the winning policy. Never introduce COW
   for distant chunks, and retain bounded failure paths. Combined policies are possible but
   are not necessary abstractions to implement before evidence exists.

Keep stable internal boundaries: begin a capture epoch with fixed identities/revisions;
obtain a read-only persistent source; produce independently owned encoded records; release
sources; report terminal command outcomes and durable acknowledgments separately. Do not bake
scheduler/COW/lock-state fields into chunk disk records or require generic reference-counted
objects in every reader. The existing explicit record format and whole-snapshot transaction
can remain unchanged across these policies. Logical field classification, restricted snapshot
views, stable revisions, atomic publication of complete write sets, and reference-model tests
are useful for every option.

Disk IDs, checksum domains, and durability semantics are the harder compatibility commitments;
this requirement change gives no reason to reopen them. A later NPC state schema is a real
format evolution and needs its own review. A different concurrency executor likewise needs
its own read/write ownership design; same-process execution alone is not a shortcut.

### New-World Initialization and Snapshot Zero

Expose separate create and open operations. Both acquire the stable world lock before
inspecting/modifying persistence. Creation requires a destination without existing world
persistence artifacts; the stable lock file itself is not evidence of a saved world. Do not
reuse a destination containing an old base, WALs, or incomplete creation files by silently
overwriting them. Existing-world opening never falls back to generating a new base from
defaults, remembered settings, or orphaned journal contents.

For explicit creation:

1. Construct the initial logical state and a new world identity. Record the generator's
   identity/version/seed/settings, saved layout, initial tick, global state, and valid initial
   player records (or an explicitly empty player array if no player has entered). Use an empty
   chunk index for an untouched generated world; include any actual initial persistent overrides.
   Do not materialize the generated world merely to create its base.
2. Assign snapshot sequence 0 and derive a domain-separated initial logical digest from the
   canonical initial persistent state, including world identity and generator/layout settings.
   Define the digest input without its own digest field or the physical file checksum to avoid
   circular hashing. Use the exact [snapshot-zero anchor encoding](../formats/world-persistence-v1.md#snapshot-integrity).
   Store this sequence/digest as the base's incorporated snapshot identity; maintain the base's
   independent physical checksum and declared-size validation as usual.
3. Write and validate a temporary base in the world directory, synchronize it, and atomically
   install it without replacing an existing world. Synchronize required directory metadata,
   including the new world directory's parent entry where required by platform durability.
   Only after these steps is snapshot zero a durable prerequisite for journal creation.
4. Establish/synchronize the first segment header and its directory entry, naming the same
   world and snapshot-zero predecessor. Report successful creation only after this setup.
   Subsequent WAL commits use the normal synchronization/acknowledgment protocol. Failure in
   initialization must not allow a writer to bypass the missing durable prerequisite.

A crash before installation may leave only incomplete creation artifacts; preserve/report
them and do not present that world as loadable. After a valid base is installed, a crash
before the first journal is established leaves snapshot zero recoverable. Under the lock,
startup can finish first-segment establishment using the validated base anchor; partial
initial journal bytes cannot be mistaken for a committed transaction. Once WAL snapshots
exist, normal chain validation and mandatory recovery compaction apply. A missing/invalid
base alongside WALs is a recovery error, not permission to recreate snapshot zero. Initialization
failures may leave a recoverable base even when creation was not reported successful.

### Asynchronous Operations and Checkpoint Eligibility

Implement R41-R43 with an explicit operation lifetime:

```text
Waiting for dependencies / capture / resources
             -> Ready -> Validate / prepare / commit -> Applied or rejected
                  ^                |
                  +-- revalidate after additional dependencies or waits
```

Load dependencies outside the mutation path and pin them while needed. Returning to ready
reuses valid preparation but does not permit overtaking required command order. Apply R26's
generation checks and R31's atomicity at publication; service completions remain runnable.

Track command sequences within each client/session, separately from snapshot sequences,
world ticks, and chunk revisions. Checkpoint messages carry a dependency watermark; retain
bounded checkpoint state until the whole required prefix resolves. A highest-completed ID
with a gap is not a resolved prefix. The latest eligible checkpoint supplies captured player
state; the pending/terminal outcome contract is R71.

Retain an ordered save request's required boundary across dependency waits. An explicitly
requested snapshot of an earlier completed prefix can use only player records eligible for
that prefix and cannot claim unresolved commands are included.

Draining counts queued, waiting, ready, and executing operations. A persisted future timer
need not execute to finish shutdown, but an admitted command cannot be discarded as a timer
unless its state is actually represented by that persistence policy. R60-R62 own shutdown
failure handling.

### Shutdown Status, Retry, and Exit Choices

Use one simple dialog with phase text: "Finishing pending actions...", "Saving...", then
"Finalizing save...". No percentage or estimated completion time is required. Stop new
gameplay/simulation producers while shutting down, but keep the UI, dependency loaders,
completion handling, and necessary persistence workers responsive. A terminal rejection
counts as a resolved command; future and resource-deferred timers saved in metadata do not
need to run merely to finish shutdown. Normal gameplay capture/player-wait deadlines do
not automatically cancel the final save; use the explicit choices below and retain the same
working-memory limits, failure handling, and safe ownership rules.

If a dependency read actually fails with a transient error, retry that nonterminal I/O/
preparation step once after a provisional one-second delay. Do not retry corruption or
invalid-data failures as transient errors. A retry is not a replay of an already applied
action or a new attempt at a terminal rejected edit. Existing resource backoff and the
one-useful-handoff player memory-failure policy still apply; shutdown adds no extra memory
retry allowance. Repeated failure leaves the operation unresolved and exposes these choices:

| Choice | Behavior |
| --- | --- |
| Retry | Retry the failed step after outstanding work from that attempt has finished; retain ordering and revalidation, then continue shutdown. Final-write retries still require R23 repair where applicable. |
| Cancel exit | Return to gameplay, preserving completed actions and outstanding work. Cancel the exit intent, not the effects of admitted commands. |
| Quit without saving | Explicitly accept possible loss since the last durable snapshot and exit with base/WAL files retained. |

After a provisional five seconds without meaningful progress, show "Still waiting for
pending actions..." during draining, or equivalent phase-specific delayed status during
saving/finalization. Offer Keep waiting, Cancel exit, and Quit without saving. Keep waiting
continues observing the same work. An elapsed delay does not prove an I/O failure or permit
starting another request. Enable Retry only once a step has failed and its previous attempt
is no longer active. Progress means completed work or advancement of the phase, not repeated
polling or retry notifications. Neither time threshold automatically cancels or drops work.

Cancel exit resumes producers through the coordinator without resetting operation identities
or duplicating effects. Invalidate the old exit intent so delayed final-save/compaction
completions cannot unexpectedly close the resumed game. Respect the existing ownership
handoff and commit-cancellation boundaries: a commit already begun must still resolve, and
successful durability acknowledgments remain valid after exit is cancelled. Restore gameplay
capture policy through that safe handoff, retaining original request wait timestamps and
unsaved age. Removing the shutdown exemption does not disable R73 overdue-save priority.
Normal gameplay deadlines become actionable again only where the restored policy permits;
their expiry never authorizes premature source reuse or cancellation of an active commit.

Explicit Quit without saving must not block indefinitely joining a stalled disk worker.
Finish safe shutdown where possible; if workers cannot finish, terminate with the same
persistence guarantees as supported process interruption. Do not truncate/delete files or
recycle worker-owned memory concurrently as a cleanup shortcut. This path requires the
player's explicit choice, never a timeout, and must not report a successful final save.

If the final snapshot is already WAL-durable but compaction fails, report the compaction
failure and exit with the WAL retained for ordinary next-start recovery. The final state is
saved, so do not display the unsaved-state warning for this case. Fatal startup recovery
failures remain R55's stderr/nonzero-exit path and do not enter this shutdown dialog.

### Lazy Timer Pass Boundary

Block timers execute only in fixed resident passes (R47/R78). Ordinary loading restores
saved block/timer state and registers timers once under the existing stale-load/publication
rules; it does not run timers or wait for catch-up before reporting readiness. R77 removes
evicted lazy chunks from the live due index; normal access registers them again.
Persistence-only reads leave saved state unchanged without live timer registration.
No global deadline-loading scheduler is introduced.

Each pass fixes logical cutoff T and its eligible resident-chunk list at pass start. Later
loads become eligible for a later pass, without expanding the selected list or launching a
recursive pass. Use stable (deadline, cell-index) order and original follow-up deadlines.
Bound work and schedule fairly while residency and execution permissions hold; preserve
unprocessed due work across deferrals. The next eligible pass is not a next-frame promise.
The existing two-stage soil chain is finite; future recurring timers need their own bounded
catch-up contract.

For example, a loaded loose-dirt block may be visible before compaction due at 100 and grass
due at 200 execute. With no intervening edit, a pass at cutoff 250 produces grass; a pass at
150 produces packed dirt and retains the deadline of 200. An edit can precede either pass
and change the applicable result. Current event identity/material checks prevent stale
work from overwriting that edit. With identical state, cutoffs, and ordered edits, execution
is deterministic. Without intervening edits, evaluation at T is idempotent and incremental
cutoffs through T produce the same logical contents as one large catch-up.

Current code checks the block above during timer execution. Replace that dependency only
after auditing eligibility maintenance in every authoritative mutation path: covering soil
cancels its timer and applies the existing covered-soil rule; uncovering schedules the
appropriate transition. Cross-boundary effects remain part of the edit's atomic write set.
Timer execution needs only local event/material checks and local follow-up scheduling.
It must not recursively load a neighbor or invoke broader simulation validation.

Timer execution defers while capture holds sources; existing executing operations finish
before capture. Loading follows normal publication rules without a timer catch-up gate.
Timer mutation/consumption dirties the published revision; registration alone leaves saved
contents and revision unchanged. An older base cannot permit eviction after timer mutations.
Neither loading nor capture adds offline wall time or resets deadlines. No extra pass is
required to eliminate overdue state before saving or before exposing a loaded chunk.

### Recovery Failure Classification

Validate framing, bounds, checksums, and predecessor links before deciding that recovery can
publish a base. A partial final transaction header, payload, or footer at physical EOF can
be an incomplete append when it follows a fully validated prefix and no retained successor
requires that transaction. Such a suffix is excluded from normal recovery output. A complete
framed transaction whose checksum fails is not an incomplete append merely because it is
last in the file. Interior damage, a dependent later segment, corrupt required base data,
or a missing committed predecessor prevents routine fallback to the earlier prefix.

If the evidence cannot distinguish an incomplete append from other damage, preserve it and
report the uncertainty. Framing cannot prove whether arbitrary external truncation removed
a formerly durable commit; do not promise recovery of bytes no longer present. This policy
handles observable damage conservatively without treating every failed decode as a crash tail.

For committed corruption, missing committed dependencies, or ambiguous damage, v1 preserves
the original base and WAL files, prints a clear save-path/error message to stderr, and exits
with a nonzero status. Finding an older valid snapshot does not authorize loading it. Do not
enter gameplay, publish recovery output, or invoke normal final-save/compaction cleanup on
this fatal path. Interactive selection and evidence-preserving restoration are follow-ups;
they are not prerequisites for v1. This classification does not turn ordinary transient
write/compaction failures into fatal corruption errors; R21/R23 still govern those failures.

### Compaction Source Verification

Verify the installed source base's declared size, physical checksum, protected header/index,
and record bounds. Validate every committed transaction required from that base anchor
through the target snapshot, including identity/framing, predecessor links, and payload
digests. Superseded chunk versions still participate in their enclosing source checksum;
choosing only the latest records does not allow skipping required source integrity checks.
Already-incorporated redundant journals remain subject to the existing recovery/retirement
rules rather than becoming new dependencies of the installed base.

Keep validation streaming and bounded. It may run alongside copying to the temporary output;
the output remains unpublished until all input verification and output validation succeed.
Validate the same bytes used to construct the output. If the implementation uses multiple
passes, an earlier successful scan alone is insufficient evidence for a later reread: use
verified retained buffers or reverify the consumed stream against the source integrity
evidence. Immutable generation handles prevent path/index mismatches but do not establish
that bytes remain intact after a previous checksum check.

On mismatch, stop publication, expose the error, and retain the installed base and required
journals. Do not issue `BaseInstalled` or make newer versions evictable. A failed candidate
must not be treated as a repaired save merely because hashing its corrupt contents produces
a matching new checksum. Interactive salvage, older-snapshot restoration, and backup/export
management are deferred under Q10; fatal startup recovery follows R55.

Per-chunk record checksums are required. Ordinary indexed reads verify the selected record
without scanning the entire base, detecting corruption arising after startup validation.
Cover record identity/version and all persistent payload/framing fields, including metadata.
Verify chunk identity against the request and the expected content version where known;
a valid checksum alone does not prove that an index selected the right record. Do not bind
a reusable record digest to physical offsets or segment/snapshot identity. The base checksum
still protects the index mapping, and WAL commit digests still protect snapshot completeness
and sequence. Corrupt indexed reads fail visibly without falling back to generated terrain.

Chunk framing and checksum bytes are defined in the
[format contract](../formats/world-persistence-v1.md#chunk-record-layout).

### WAL Failure Repair and Cancellation

The writer tracks its last confirmed boundary as `(segment, end_offset, sequence, digest)`
and a phase: ready, appending, committing, or repair-required. Advance the boundary only
after transaction synchronization succeeds, before publishing its acknowledgment. Delayed
delivery of that acknowledgment must not cause a successfully synchronized transaction to
be rolled back. For a newly established empty segment, use the end of its durable header
and the predecessor snapshot identity as the initial boundary.

The normal path is append payload, enter committing, write footer, synchronize, advance
the boundary, and acknowledge. It performs no repair, extra synchronization, or WAL scan.
Before entering committing, the writer may accept cancellation; once it enters that phase,
cancellation is deferred until the commit attempt resolves. Success must be acknowledged;
failure retains dirty state and marks the segment repair-required. Cancellation and errors
before the footer also require repair whenever bytes may have been appended.

For repair, first finish/stop the failed attempt's I/O and discard its buffered pending
writes so no stale write can land after truncation. Truncate the same segment to the known
confirmed offset, synchronize the truncation, then restore the append cursor/buffer state
to that offset. Only after successful repair may a new transaction or rotation begin.
If either repair operation fails, remain repair-required and retry repair later; coalesce
save triggers, retain dirty state, and report the failure without blocking gameplay. An
existing compactor may finish work on previously sealed segments, but the unresolved active
segment cannot be sealed or supplied to compaction. Buffer release still follows R20/R29.

Repair uses the in-memory boundary, not a file scan. Reading a failed transaction back
cannot establish durability because the bytes may only be cached. After a process restart,
normal startup validation determines the recoverable prefix. A complete valid final
transaction may survive even though its synchronization reported failure or acknowledgment
was never delivered. Recovering it is allowed; a save failure means durability was not
confirmed, not that the changes are guaranteed absent. A crash during repair may leave
either the confirmed prefix or that valid continuation; no new continuation is written
until removal of the uncertain suffix has been synchronized.

### Capture Admission, Cancellation, and Mutation Atomicity

The initial policy uses one service-controlled capture epoch, not a persistent COW graph.
Illustrative per-source states are `frozen -> reading -> released`, with the captured revision
and epoch attached. These names are proposals, not fixed APIs. The frozen manifest is the
boundary snapshot; sources do not acquire their snapshot values when the encoder eventually
reaches them. All persistent fields use the same lifetime.

Before publishing an operation, discover its complete write set and required read dependencies,
secure capture admission and metadata/publication capacity, and validate current conditions.
If discovery expands the set, return to preparation without partial publication. A road edit,
revelation, timer update, or future courier transfer cannot mutate an admitted subset while
waiting on the rest. With the current single mutation worker, admission and commit can share
that authority; no blocking per-cell lock or atomic reference-count increment is required.
Read-only access to frozen data is permitted under existing ownership rules. A future parallel
executor must additionally protect/validate its read set through publication.

For example, snapshot T freezes dirty A and B. Encode A's T record, release A, then receive
an edit that changes both A and B. Wait for B's source release, revalidate, and publish the
whole edit. The snapshot contains old A and old B, while the new live versions remain dirty.
Taking B's snapshot only after that edit would mix states and violate R1. A chunk absent
from this attempt retains its earlier durable baseline in the snapshot; post-boundary edits
to it become candidates for the next attempt.

Encoding must produce independently owned bytes before authorizing mutation of the source.
Reserve output capacity before starting a read. A simple proposal is a small bounded queue
of complete encoded records and a separate writer, with budgeted per-record staging when a
record exceeds the normal streaming buffer. R54 permits a 1,212,501-byte record; a 64 KiB
stream buffer alone is not enough to hold every valid record. Reserve by validated sizes or
a safe bound, without preallocating worst-case space for every chunk. Alternative incremental
encoding is acceptable only if cancellation/release remains safe at bounded work points.
A failed allocation leaves the source immutable until normal release or cancellation.

A full output queue can stall further encoding. Prioritizing a player's sources cannot bypass
that limit by growing memory or aliasing live data. In normal mode, check player-wait and
whole-capture elapsed limits independently of writer progress and request safe cancellation
on expiry. Do not terminally reject an admitted edit solely for elapsed capture waiting.
The global limit covers pauses without player edits. R73 save priority overrides these
automatic cancellations when saving is overdue; it continues with bounded backpressure and
visible status. Specific limits/yield granularity are measured under R66.

Treat source ownership and WAL cleanup as separate conditions. Serialize cancellation acceptance
with new-read admission and entry into commit-footer writing. Once accepted, prevent new reads,
stop the active reader at a safe bounded point, and release unread/partly encoded sources.
The cancelled transaction can never publish a footer. Control/ownership cleanup must progress
without joining a disk-blocked writer; merely adding a cancellation request to that writer's
queue is insufficient. Discard incomplete encoded output safely, keeping any writer-owned
buffers alive until its I/O ends. Complete R23 repair before any new append/rotation.

The service processes release/completion messages instead of blocking on its own queue. Match
epoch and revision so an old completion cannot release a new capture's source. Revalidate the
pending operation after handoff. All source references are gone before footer writing begins;
a too-late cancellation therefore does not need to hold gameplay for synchronization.

Source release neither acknowledges durability nor makes a modified chunk evictable. If a
released source changes and the save later fails, keep its latest revision dirty and merge the
failed manifest's candidates back without overwriting newer identities. Do not rebuild this
attempt from later live versions: start a fresh capture only after the writer is ready.

Before another capture, let unblocked player work and a paced simulation slice progress.
Coalesce replacement attempts and back off actual failures. Expose cancellation counts and
last successful durable save time. R73 prevents normal responsiveness deadlines from
indefinitely defeating save progress; R6 still does not promise a fixed recovery window.

### Overdue Saving and Exceptional Pause

Implement R73 with normal and save-priority modes under the R75 watchdog. Track unsaved age
from the latest durable save, or the first subsequent dirty transition if the world was
clean in between. Numerical thresholds follow R66.

On escalation, keep a viable active capture. If cancellation was already accepted, finish
its handoff and required repair before a fresh attempt; a mode change cannot revive it.
Enter the mutation gate between complete operations, leaving commands needed for the chosen
save/checkpoint boundary runnable. If sources have already been released and only writing/
synchronization remains, do not introduce a new mutation pause. A suitable status is
"Saving: world changes temporarily paused"; coalesce it under R71.

A full output queue waits for writer progress in this mode. A failed reservation for minimum
record/manifest/completion workspace is still an actual resource failure. Streaming keeps
its existing budgets and whole-snapshot commit; escalation requires neither whole-capture
buffering nor independently committed subsets.

Keep save priority separate from source ownership: source release clears the capture gate,
while durable success clears overdue-save tracking. Independent pressure gates may still
apply. R23 owns storage repair; failed repair suspends appends rather than cycling captures.
The Shutdown Status section owns final-save and explicit exit choices.

### Player Pending State, Retries, and Resource Failure

R38-R40 define admission waits, genuine allocation failures, and bounded progress; R71
owns client outcome semantics. Prioritize the complete blocked write set, then revalidate
on meaningful source-release progress. Releasing a pin alone does not free live-world
storage, so a genuine allocation failure benefits from handoff only if memory is reclaimable.

The current client's acknowledgment path retires both successful and failed requests. V1
can therefore keep brief waits internal by withholding the terminal response. Any advisory
status uses a separate path that does not retire predictions or resolve checkpoint prefixes.
The future wire contract must distinguish:

| Outcome | Meaning for client and authority |
| --- | --- |
| Pending/admitted | The same request remains outstanding; keep prediction and checkpoint dependency. |
| Applied | Effects published once; this does not itself mean WAL-durable. |
| Terminal rejected | No effects from this operation; remove/reconcile prediction and resolve the prefix. |
| Not admitted/busy | Authority retained no executable request; explicit resubmission/status rules are needed. |
| Unknown after timeout/disconnect | Query or resend the same identity within a supported session; never assume failure or mint a new identity blindly. |

Readiness hints/wakeups are advisory; recheck admission and capture generation when acting.
Use R75's coordinator and bounded backoff for a lost signal, not a timer/retry loop per request.
A future deduplication cache cannot silently forget identities while their session may still
retransmit them; expiry needs explicit stale-session/resynchronization behavior. Wire encoding,
reconnect machinery, and persisted deduplication remain deferred.

Keep capture contention, configured-budget exhaustion, allocator failure, and invalid data
separate in diagnostics. Measure frame time, confirmation lag, and corrections separately:
optimistic visuals alone do not establish that a prolonged wait is invisible. Simulation
resume/catch-up follows R68/R69 and its dedicated plan section.

### Mutation Preparation and Normal-Path Performance

Keep failure safety lightweight on the common path. Once dependencies, writable ownership,
and all mutation/publication capacity are secured, mutate exclusive versions in place.
Retain useful validation results as compact descriptions of affected chunks and intended
changes, using reusable bounded scratch storage. This preparation does not require copying
every affected block array or adding mutation overlays to ordinary block reads. Reserve
metadata capacity before the first change; growth should not allocate/copy again during
application when the prepared capacity suffices.

Reuse still-valid discovery results rather than traversing dependencies a second time solely
for resource preparation. Revalidation is necessary after deferred work if its inputs changed.
For example, road formation already collects candidate runs and resolves ambiguity before
applying formations; extend that preparation where practical. Current individual runs are
limited to 12 cells, but that alone is not a bound on the entire operation's dependencies or
side effects. Prove any scratch/reservation bound from the complete operation. Use selective
private staging when dynamic effects cannot be prepared safely, with no general rollback
framework and no unconditional whole-chunk copies solely for OOM handling.

Measure a comparable pre-change baseline and the new path with saving inactive and active.
Cover simple edits with spare capacity, metadata growth, cross-chunk road effects, and timer
batches. Track worker CPU time, allocation counts, copied bytes, and typical/tail edit latency;
separate gate/preparation overhead from capture waiting, encoding, and cancellation costs.
Existing edit paths already perform validation and multiple clones; removing persistence COW
neither removes those copies nor proves a performance improvement. Measure rather than assume. Simple prepared edits are expected to need mostly ownership/capacity checks;
complex operations may incur meaningful preparation costs. No percentage or latency estimate
is an accepted guarantee until benchmarked. Investigate regressions before broadening staging.

### Persistent Contents and Live Chunk State

CONFIRMED revision: retain the current `WorldChunk` ownership and field arrangement for the
first version. The earlier physical split existed to isolate COW storage and is no longer
required. Preserve the logical categories below; optional inline substructs may improve
readability but must not introduce a new allocation/ownership layer solely for capture.

| Logical category | Existing contents | Snapshot access |
| --- | --- | --- |
| Persistent payload | Blocks and roads/timers/construction metadata | Const borrows of pinned backing buffers; copy buffer descriptors into the view. |
| Persistent identity/history | Chunk ID, persistent revision, historical `is_unreachable` | Copy small values into the view at the authoritative boundary. |
| Derived state | Boundary masks, solid-block count, face-solidness flags | Exclude from the view; reconstruct on load. |
| Runtime state | Client validation revision and other session bookkeeping | Exclude from persisted data; carry only capture epoch identity needed for safe release. |

The authoritative worker constructs a small restricted snapshot view at the same boundary
that freezes the candidate set. `ChunkSnapshotView` is an illustrative API name, not a fixed
layout. It contains the copied identity/history/epoch values and an explicit empty-block case
or a const block-buffer reference, plus const slices of live metadata entries. These slices
copy their pointer/length descriptors; they do not borrow the mutable `ArrayList` descriptors
inside `WorldChunk`. The view is not a by-value copy of the full `WorldChunk` header and does
not contain derived caches or unrestricted access to the live chunk.

Keep every borrowed buffer and any transitively referenced payload stable, immutable, and
alive until safe source release, under the service's capture pins and mutation gate. Freeing,
reusing, resizing, or replacing borrowed storage is prohibited during that interval. Capture
handles and release messages identify chunk/revision/epoch rather than retaining a raw pointer
to a hash-map entry. The map may relocate `WorldChunk` headers during unrelated insertion;
that must not invalidate captured backing-buffer references or copied scalar values. Snapshot
view/manifest storage itself must also stay valid until its consumer finishes. Const pointers
alone neither extend lifetimes nor prevent concurrent mutation.

Historical `is_unreachable` may remain packed with derived face flags in live `WorldChunk`.
Extract its value on the authoritative worker when constructing the view; the encoder never
reads that live packed storage. Different bits can share the same read/modify/write unit,
so treating them as logically separate does not by itself make concurrent access safe.
Derived flag updates remain service-owned and preserve the historical bit. A persistent flag
mutation still passes the same admission gate as block/metadata mutations; copying the scalar
into the view does not introduce an independent mutation policy for it.

After source release and successful preparation, mutate existing storage in place and update
live caches within the same authoritative operation. Failure leaves both unchanged. The
independent encoded record keeps the captured revision; loading rebuilds derived caches from
persistent data. Ordinary gameplay/client copies still require consistent owned contents and
caches and remain separate from persistence capture. R48's persistent revision requirements
still apply; retaining the field arrangement does not prohibit required identity/bookkeeping.

There is no new persistent-owner allocation, owner indirection, refcounted version, or combined
block/header slot solely for capture. Later COW can supply a restricted view of a retained old
version through this same encoder boundary if evidence justifies that change. Defer physical
regrouping and independently owned persistent versions until then; the disk format does not
depend on either choice.

### Parameter Tuning and Measurement Plan

Finalize implementation parameters using repeatable measurements during persistence v1.
Numerical defaults are engineering choices under this plan; no new player-facing tuning UI
is required. The architectural limits and failure semantics already apply before tuning.

| Parameter | Initial policy | Evidence for selecting defaults |
| --- | --- | --- |
| Capture working-memory budgets | Bounded, configurable, lazy allocation; count output/manifest capacity separately from live source pins | Peak occupancy, player wait, simulation lag, cancellation rate |
| Allocation accounting | Existing allocators; charge capacities/reservations and transient overlap, report known/unmeasured overhead separately | Allocation-size distribution, spare capacity, allocation frequency/latency, process memory; evidence for later pools |
| Pending work | Bound both request count and retained bytes; coalesce save triggers; reserve completion capacity | Queue occupancy, waiting time, retained memory, producer backpressure |
| Shutdown retry/status timing | Provisional one-second transient-read retry and five-second delayed-status indication under R60/R61 | Useful retry outcomes and clear/responsive feedback |
| Simulation resume/retry timing | Source/resource-release signals, paced dispatch, bounded backoff; no per-frame retry loop | Pause/debt duration, catch-up service capacity, redundant work |
| Player wait and whole-capture limits | Normal elapsed limits trigger safe cancellation; R73 overrides automatic timeout cancellation for overdue saving | Confirmation lag, normal/exceptional pause duration, safe handoff latency |
| Overdue-save escalation | Configurable elapsed unsaved age; attempts/source release do not reset it | Successful save age/rate, time in save-priority mode, action backpressure |
| Cancellation responsiveness | Check between bounded encoding steps; safe release without unrelated disk waits | Request-to-ownership-handoff latency, including metadata-heavy chunks |

Use R66's small working-budget sweeps, then compare 64/128/256 MiB output caps in the same
concurrent pipeline. Select/report a total working budget that covers each output cap plus
manifest, scratch, staging, and completion needs; a larger queue cannot bypass that budget.
Count output until its final consumer releases it, including buffers removed from the queue
but still owned by the writer. Pins retain live storage without creating another allocation.
Vary I/O buffer size separately from total retained output capacity. Allocate on demand;
these experiments do not set shipping defaults or a process-wide memory ceiling.

Use R74's 10,000 active chunks and 2,000/4,000 changed chunks per interval as target cases
on 16 GB hardware, plus measured smaller worlds on 8 GB hardware. Include accumulation
beyond one interval; active chunks do not bound dirty or timer-pinned residency. These
counts do not define allocation caps or guarantee that arbitrary metadata/meshes fit.

Use this workload matrix, comparing each workload with saving inactive and with periodic
saving/compaction active under otherwise comparable conditions:

| Workload | Main purpose |
| --- | --- |
| Normal movement and occasional edits | Typical frame time, streaming, and autosave interference |
| Rapid construction across several chunks | Admission/preparation overhead, full-dependency waiting, atomic mutation behavior |
| Sustained simulation over many distinct chunks (99.9% updates), plus a player burst | Dirty-set growth, global-pause cost, backlog, cancellation, and priority behavior |
| Raw/high-entropy blocks and maximum/heavy metadata | Output capacity, encode tail latency, spare allocation capacity, cancellation extremes |
| Slow/stalled writes, full output queue, and overlapping compaction | Backpressure, source release independent of disk, UI responsiveness, eventual repair |
| Moving/separated players and cross-chunk operations | Priority changes, no partial publication, dependency footprint; input for later proximity policy |
| Repeated capture cancellation and resume | Useful progress before refreezing; overdue-save escalation without resetting unsaved age |
| Save-priority mode with finite slow writes, stalled writes, and actual failures | Eventual success when I/O progresses and workspace suffices; responsive exceptional-pause status, bounded queues, and honest failure |
| Intentionally tiny budgets and injected allocation failures | Bounded failure paths, backpressure, and recovery without exhausting system RAM |
| Distinct-chunk churn beyond active regions, with delayed compaction | Retention until the exact current base revision is installed, net resident growth, and separation of world memory from capture-output capacity |
| All-lazy and mixed timer sets, repeated eviction/reload, deferred catch-up, and timer-pass/edit races | Reclamation and pins remain correct; record load readiness, overdue wait/pass work, fair progress after deferral, and renewed dirty retention after timer execution |

Use monotonic timestamps and bounded counters/histograms, correlated by capture identity.
Report p95/p99 and observed maxima as well as typical values; include cancelled/failed attempts.
The required measurements are:

| Measurement | Definition and decision it supports |
| --- | --- |
| Capture and encoding | Boundary bookkeeping, per-source hold duration, last-source-release time, encoder active CPU/wall time excluding queue waits, encoded bytes and record-size distribution; distinguishes encoding cost from blocked output. |
| Output and storage | Byte occupancy/high-water mark including writer-owned buffers, encoder time blocked by full output, bytes written, write duration/throughput, final flush/synchronization duration, and repair time; distinguishes temporary buffering pressure from sustained I/O limits. |
| Durable progress and freshness | Successful commit count/rate, time since last durable success, R73 unsaved age, capture-to-durable-ack delay, and current age of the latest acknowledged capture boundary. Preserve boundary timestamps across delayed acknowledgments; these are diagnostic clocks, not changes to R73 escalation. |
| Gameplay and catch-up | Frame/input and authoritative-operation latency, original-request-to-terminal delay, normal/exceptional simulation pause durations, exceptional-pause count/time fraction, deferred actions, catch-up debt and service CPU/capacity. |
| Memory and backlog | Allocated/reserved working capacity, queued/predicted work, live source pins, dirty chunk count/capacity, base/timer retention, process memory, allocation counts, and copied bytes by cause; shows growth beyond the output queue. Split retained residency by waiting-for-current-base, timer-policy, and transient ownership/operation reasons, with overlapping pins identified rather than double-counted. Record net growth and retention age. |
| Cancellation and retries | Attempt/cancellation counts, reasons, retry frequency, and request-to-safe-handoff latency; separates useful completion from repeated abandoned work. |

Boundary age uses real time of the captured boundary, not saved logical ticks or time of
acknowledgment. A recent durable acknowledgment can cover old state. If the world remains
clean, growing boundary age alone does not mean unsaved work; report dirty state alongside it.
Separate useful execution from queue waiting and capture gate/preparation from existing client
copies. Later COW/eager-encoding experiments reuse these measurements, including metadata and
multi-chunk dependencies; a hot memcpy-versus-RLE microbenchmark is insufficient. Retain
worker CPU measurements across stages; later COW evaluation separately reports detach/copy/
retention costs and saving-inactive overhead while the policy is enabled but unused.

Evaluate storage sensitivity through these explicit scenarios:

| Scenario | Controlled input | Evidence expected |
| --- | --- | --- |
| Brief write stall | Hold write completion for a finite interval with output sized below and above the captured payload/workspace needs | Queue pressure explains any extra source-hold time; a fitting capture releases sources during the stall. |
| Sustained slow writes | Rate-limit writes through several finite throughput levels, including below offered workload demand | Save priority permits fixed attempts to finish when I/O progresses; repeated cycles expose backlog/pause growth rather than claiming steady-state capacity. |
| Slow final synchronization | Allow writes, hold only the final durability completion | Sources and simulation release independently; durability remains pending and freshness lag is visible. |
| Oversized capture | Raw blocks, heavy/maximal metadata, and accumulated dirty chunks exceeding output capacity | The same pipeline backpressures within budget and follows normal/priority policy without a second mode or partial snapshot commit. |
| Repeated cycles | Sustained simulation plus player bursts, periodic saves, and compaction overlap | Successful-save rate, boundary freshness, memory/backlog, and catch-up trends show whether the system keeps up. |

Implement short deterministic cases using a controllable storage adapter and coordinator
clock, with separate gates for writes and synchronization and explicit release/failure points.
Reuse the reference-model oracle for recovered contents and ownership/atomicity checks. Keep
these cases in the regular test suite without long real sleeps. Include permanent stalls and
actual failures to verify responsive status and bounded failure behavior, not eventual success.

For performance, run production paths on real storage with optional off-thread latency/rate
injection and real elapsed time. Use identical workload traces/seeds across budget settings
and a saving-inactive baseline. Run enough save and compaction cycles to report trends; record
cycle counts and warm-up separately. Scaled-down fake-clock tests do not substitute for target
scale or preserve storage/workload ratios automatically. Report hardware, build, workload,
seed, configuration, duration, injected schedule, and results in a machine-readable artifact.
Native filesystem tests still establish the supported adapter behavior separately.

Instrumentation, short deterministic cases, and a reproducible benchmark runner belong to
T4/T9/T7 in v1. Target-scale evaluation selects initial defaults; it need not run on every CI
change. Larger soak campaigns and new capture policies are follow-ups using the same runner.
Increase output capacity only when queue waits dominate and memory headroom permits it;
encoding-dominated pauses need a different optimization. Sustained throughput/freshness or
compaction deficits require addressing the service rate or workload, not merely a larger queue.

Establish the current baseline and intended frame budget before setting numerical latency
regression thresholds; no hard cancellation/frame-time promise is assumed in advance.
Choose and record defaults, the evidence behind them, and repeatable regression checks.
Bounded memory/work, no partial mutation, safe ownership, and no UI blocking on disk I/O
are correctness requirements independent of performance thresholds. Tiny budgets and fault
injection must test pressure without deliberately exhausting physical RAM or inducing swap.
Parameter selection can proceed as routine implementation work; discuss measured gameplay
tradeoffs or required design changes with the user rather than silently weakening guarantees.

### Metadata Allocation Layout

Use the existing allocator interfaces for materialized `WorldChunkData` buffers and the
separate roads, timer, and construction arrays. Add capacity accounting and reservation
checks at their owning allocation/preparation paths; no custom block or metadata pool is
required in v1. Keep `WorldChunk.content` and inline `WorldChunk.metadata` descriptors in
their existing owner. Empty arrays and all-air block storage allocate nothing. Reuse useful
array/scratch capacity through existing mechanisms; do not introduce a new allocator cache
solely for persistence.

Keep borrowed buffers immutable, stable, and alive under R33 until safe source release.
Once writable, an array may grow by acquiring new storage, copying live entries, and
releasing its old allocation. Reserve the simultaneous old/new capacities first. Preparation
must obtain all required backing storage before authoritative publication under R31; a
budget reservation alone does not make a later allocator call infallible. Propagate errors,
clean up partial acquisitions, and retain valid original contents/caches on failure.

Charge allocated capacities, including unused array capacity and known bookkeeping, rather
than only live entry bytes. Include growth/client-copy overlap, chunk headers, snapshot
views/manifests, and independently owned encoded output in their appropriate budgets.
Convert reservations to allocated charges without counting both for the same storage;
source pins describe retained live allocations and are not another allocation charge.
Where allocator overhead or fragmentation cannot be measured exactly, identify it as
untracked/estimated overhead, leave conservative headroom, and expose process telemetry.
Capacity counters do not establish a process-wide physical-memory ceiling. Freeing an
allocation may release its logical charge without immediately reducing process residency.

Semantic entry/serialized byte limits remain R51/R54 and apply independently of allocation
strategy. Metadata may exceed the 32-KiB block payload. Allocate validated required capacity
within budget, not the maximum merely because the schema permits it. R38-R40/R73 retain
the existing resource-failure, safe cancellation, and overdue-save policies.

On the current aarch64 Zig 0.16 build, `Metadata` is 72 bytes aligned to 8: three 24-byte
array descriptors (pointer, length, capacity), with the timer queue wrapping one array.
It is already inline in `WorldChunk`, not separately heap-allocated. The full `WorldChunk`
header is currently 872 bytes, including 768 bytes of derived boundary masks. Retain this
field arrangement initially, apart from identity/bookkeeping required elsewhere. These are
baseline layout observations, not a serialized schema or a mandated size for future builds.
Capture copies only selected scalars and descriptors, not the whole header or its caches.

Materialized blocks retain the existing 32,768-byte `WorldChunkData` allocation. All-air
chunks retain their allocation-free block representation even when they have metadata.
No combined block/header allocation, persistent-owner object, or custom slot geometry is
required. Later pools can sit behind these allocation interfaces without changing the
snapshot view or save format; adopt them only on measured evidence.

### Memory Budgeting Integration Boundary

Persistence v1 owns the minimal capture-related simulation gate, player-pending contract,
priority encoding, R73 overdue-save escalation/status, and paced release/resume. The broader
controller builds on these hooks; the exceptional saving pause is part of persistence v1.
Initially implement configurable bounds and capacity/retention counters for persistence
allocations and working buffers, structured allocation failures, cancellation/status, and early
checkpoint/compaction triggers. Preserve bounded working capacity for completion/cleanup
and streaming persistence so exhaustion can be resolved without allocating another full
snapshot. Report pinned/non-evictable memory separately from safely reclaimable capacity.

The [resource-budgeting follow-up](resource-budgeting.md) selects system-aware ceilings and
adds player/simulation admission, byte reservations, backpressure, movement safety, and
degradation UI. Until then, retained dirty/timer-pinned world data and other subsystems can
still create process-level memory pressure. Early compaction may help but must not be treated
as a guaranteed or immediate remedy, especially when storage is slow or unavailable.

### Residency and Persistence Feedback

Track resident current content identity, latest WAL-durable identity, and installed-base
identity separately. Persistent identities cover blocks, metadata, and historical flags;
mesh/validation revisions do not substitute for these identities. Preserve identities in
chunk records so eviction/reload does not reset them. Advance a chunk's persistent revision
on every published persistent mutation, including a change that restores older content.
Revisions cannot wrap or be reused. WAL-durable identity supports save acknowledgment/dirty
tracking; it is not an additional eviction condition.

Illustrative internal messages are `WalCommitted(snapshot_sequence, captured_versions)` and
`BaseInstalled(base_generation, through_sequence, through_hash, readable_catalog)`.
The catalog supplies `(chunk_id, content_version, record_offset)` through an immutable
in-memory view; the on-disk chunk map is `(u32 chunk_id, u64 offset)`
with the content version stored in each record. No block payload is returned to the service
merely to acknowledge compaction. Publish this catalog only after durable installation.

For modified chunks, the eviction predicate is:

```text
installed base has a readable record for this chunk
AND live persistent revision == installed-base persistent revision
AND no ownership/gameplay/operation pins prevent eviction
```

Evaluate the predicate and remove residency under service authority, preserving the matching
base-generation/catalog lifetime for future reads. No active/sealed-WAL inspection or extra
dirty/pending-WAL predicate is required. Every newer published edit advances the live revision,
so it necessarily breaks equality until that revision is installed. An acknowledgment for
version 12 while live version 13 exists cannot permit eviction, even if 13 is WAL-durable.
Ignore stale base-install messages that would regress the service's installed catalog.
WAL records and dirty candidates still support persistence bookkeeping, but their physical
presence or stale entries do not independently determine eviction. Untouched generated chunks
continue to use generator fallback under their existing pin rules; absence from the base is
not proof that a modified chunk is safely regenerable.
Apply R77's timer-kind policy within the pin predicate: all-lazy pending events, including
overdue ones, do not add a residency pin; a pending non-lazy kind does. An active timer pass
or dependency operation still has scoped ownership. Restore original queues on ordinary
load and use R47 due-event handling. Preload persisted construction and road dependencies
before an edit rather than silently ignoring nonresident metadata. Persistence-only reads
for integrity checking/recovery/compaction do not register gameplay chunks or timers.

This relaxation helps only after the exact current revision is base-backed. A lazy timer
that fires or is cancelled makes its modified chunk ineligible until the new revision reaches
the installed base. Repeated edits can keep it ahead of compaction indefinitely; earlier
compaction is a pressure response, not an unconditional resident-memory bound. Measure base
retention separately from timer-policy and transient-operation pins under R76.

### Platform Durability Contract (v1)

Target local APFS on macOS. Keep the base, WALs, temporary files, and lock in the same
world directory on one filesystem. A successful snapshot acknowledgment means the snapshot
survives game termination, OS crash, or power loss under a storage stack that honors the
operations below. This assumes no arbitrary corruption of previously durable bytes, no
external save-file modification, and no device lying about flush completion. Network storage
and actively cloud-synchronized save directories are outside the guarantee. R55 still
governs detected corruption; this scope does not disable validation.

Use a narrow platform adapter with these operations:

| Purpose | macOS primitive/contract |
| --- | --- |
| Durable file contents and length | Flush application buffers, then `fcntl(fd, F_FULLFSYNC)` |
| Durable directory changes | `fsync(directory_fd)`, then `F_FULLFSYNC` through an open file descriptor on that same filesystem/device |
| Replace an existing base | Same-directory atomic `rename`/`renameat` |
| Install snapshot zero without overwriting | No-replace rename, such as `renameatx_np(..., RENAME_EXCL)` |
| Exclusive ownership | Nonblocking `flock(LOCK_EX \| LOCK_NB)` on the stable lock file |
| Repair a failed WAL append | Truncate the existing segment to its confirmed offset, then durably synchronize the file/length |

The checked Zig 0.16 threaded backend's file-sync path uses ordinary `fsync` on macOS;
it does not supply the stronger device-cache barrier required here. Keep `F_FULLFSYNC`
and directory synchronization explicit in the adapter, rather than assuming a portable
API name establishes the required guarantee. Apple documents that `F_FULLFSYNC` also
flushes data previously fsynced on the same device, enabling the directory-barrier ordering
above. Check all results. Unsupported/failed primitives report failure without a silent
weaker fallback, a durability acknowledgment, or premature input retirement.

For a normal transaction in an already durably established WAL segment:

```text
Finish transaction/footer and flush application buffers
-> F_FULLFSYNC(WAL)
-> advance the confirmed boundary and acknowledge
```

The segment header and directory entry must already be durable. Appends do not require a
new directory synchronization each time. A failed synchronization leaves durability uncertain
and follows R23's repair rule, even if a subsequent read finds all transaction bytes.

For base compaction:

```text
Finish and validate the temporary base; flush application buffers
-> F_FULLFSYNC(temporary base)
-> atomically rename over the installed base
-> fsync(world directory), then F_FULLFSYNC through the retained new-base file handle
-> publish BaseInstalled
-> remove incorporated WAL segments
-> fsync(world directory), then F_FULLFSYNC through the installed-base handle
```

Atomic replacement and durable replacement are distinct. If the replacement-directory
barrier fails, retain required WALs and withhold BaseInstalled; a visible new pathname does
not establish durable installation. Old-generation read handles remain valid independently
of the pathname. A retirement barrier failure can leave redundant journals after restart;
recovery must recognize already-incorporated segments without treating them as new history.

Initial base installation uses the same file-before-rename and directory-after-rename
barriers, with no-replace semantics. When creating the world directory, also fsync its
parent entry and complete the same-device full flush before claiming initialization durable.
For a new WAL, flush its complete header, fsync the file and containing directory, and then
perform F_FULLFSYNC on that file before admitting transactions that could be acknowledged.
Keep initial-world and rotation ordering consistent with the existing snapshot-zero protocol.
For repair, finish failed-attempt I/O before truncation, durably synchronize the new length,
and only then resume appends/rotation; no directory mutation is needed for an ordinary
in-place truncation.

The lock coordinates cooperating game instances, not arbitrary external programs. Acquire
it before recovery and hold it through final filesystem work. Never delete/recreate the
lock file during ordinary cleanup; release ownership only after all owning references are
closed or the process exits. Report a busy world rather than waiting indefinitely.

### Exclusive World Ownership

Use a stable sidecar such as `world.lock` in the canonical managed world directory. Acquire
the OS lock before recovery; keep the handle/ownership until all world workers and final
filesystem work finish. Base replacement must not change the lock identity. Normal cleanup
does not unlink/recreate the lock file. PID/details may improve the busy message but do not
establish ownership. Save-path aliases must resolve to the same managed lock; unsupported
hard-linked/ambiguous base aliases should be rejected rather than bypass ownership.

### Reference-Model Verification (v1)

Use a small reference world and an independent history of complete eligible snapshots as
the oracle. Compare persistent contents, revisions, metadata, global/player records, and
snapshot identity; sequence-number comparison alone cannot detect mixed or incorrect state.
Drive the production coordinator/codec/recovery paths through controllable operation and I/O
boundaries. The model must not duplicate the implementation's encoding or recovery algorithm.

Run short deterministic scenarios and bounded seeded sequences that interleave edits,
capture, cancellation/ownership release, commit/acknowledgment, rotation, compaction,
eviction/reload, and crash/restart. Include edits after capture and delayed acknowledgments.
Track the last acknowledged snapshot separately from written and synchronized transactions;
require recovery to follow the same history and preserve every acknowledged snapshot's
durability, while allowing a complete final transaction whose acknowledgment was lost.

The storage fake follows Platform Durability Contract (v1), tracking file contents and
directory entries separately. Application-buffer flush establishes no durability. Permit
partial writes and complete/partial/no survival of unsynchronized changes, while successful
durability barriers preserve their covered state. Before replacement-directory durability,
model either the old or new base under the supported atomic-replacement contract. Failed
synchronization can leave some or all changes persisted. Unsynchronized journal deletions
may reappear, and process exit releases locks. Model truncation and creation boundaries
with the same ordering as the adapter. Record fault/scheduling choices with the seed for
replay; arbitrary corruption of durable data is a separate suite asserting R55.
Use explicit cases for critical boundaries so the bounded run cannot randomly miss them.
This harness complements codec tests and real-filesystem/platform integration tests; it
does not establish that the fake exactly reproduces every filesystem's behavior.
Native tests cover replacement, open old-generation readers, cross-process locking, and
error propagation. Killing a subprocess verifies process-crash handling, not power-loss
durability by itself; report that distinction in validation results.

### Potential Improvements

- Custom block/metadata pools are explicitly deferred. Measure allocation frequency/latency,
  size distributions, unused capacity, fragmentation, and process residency first. If they
  justify it, compare fixed slots for block buffers and page-based size classes for metadata
  against the existing budgeted allocators. Choose geometry from those measurements; the
  former 64-byte minimum class is not a preset. Include page slack, rounding, bookkeeping,
  and oversized allocations in accounting, preserve fallible preparation and capture-buffer
  stability, and keep semantic limits independent of pool thresholds. The allocator interface
  permits this upgrade without a save-format or capture-contract change.
- Consider a separate whole-capture buffering mode only if R66/R76 measurements demonstrate
  an advantage over increasing capacity in the existing concurrent streaming pipeline.
  Ordinary raw blocks for 2,000-4,000 chunks use 62.5-125 MiB before metadata/framing; heavy
  metadata and accumulated dirty state can exceed that. A 1-2 KiB average is not a bound.
  Any later mode needs a reviewed bounded overflow path and the same consistent boundary;
  the capacity sweep and measurement infrastructure already belong to v1.
- Add a manual Save action using the same ordered snapshot and durability pipeline, with
  explicit completion/failure feedback. V1 uses autosave and save-on-exit only.
- Add and validate Linux/Windows durability adapters with platform-specific synchronization,
  atomic replacement, directory publication, and locking contracts. Reuse the binary format
  and coordinator, and extend the reference model/native tests to each supported contract.
- Add an evidence-preserving recovery workflow for explicitly selecting and restoring an
  older fully validated snapshot after committed corruption, with clear lost-progress
  reporting. Consider backup retention/export alongside it; v1 only reports to stderr and exits.
- Extend the v1 reference-model harness with long-running fuzz campaigns, automatic failing
  sequence minimization, and exhaustive exploration of bounded state spaces/interleavings.
  These are follow-ups; short reproducible model tests and explicit crash-boundary cases
  remain required for v1.
- Add material-enum validation integrated into required work: validate once per RLE run and
  combine raw-byte membership checks with decoding/derived-state reconstruction, avoiding
  a separate full-chunk traversal. Measure the added checks before adopting this alternative
  to the initial trusted-buffer interpretation; retain clear rejection of invalid materials.
- Consider a non-exhaustive `BlockType` enum so all byte values are representable without
  membership checks at loading. Define and audit unknown-value behavior in rendering,
  collision, placement, and other consumers, including material-index bounds. This alternative
  changes the runtime contract and is deferred; do not assume adding `_` alone is sufficient.
- Revisit palette encoding alongside optional per-chunk material-count statistics after
  measuring real terrain and edits. A 256-entry u16 histogram costs 512 bytes before overhead,
  not 4 KiB; each count fits because a chunk has 32,768 cells. Consider temporary histograms
  collected during encoding as well as maintained runtime statistics. Counts identify palette
  membership but do not predict run structure or encoded size. Measure copy/update costs,
  compression ratio, and CPU cost before adding a codec. Maintained statistics would be
  derived state, not mandatory persistent capture payload. Define palette ordering and handling
  of three-material chunks only if adopting that follow-up.
- Evaluate standard streaming compression algorithms available in the selected Zig toolchain
  or appropriate libraries. Benchmark size, encode/decode throughput, scratch memory, and
  latency against standard RLE/raw on representative blocks and metadata. Preserve independent
  indexed chunk access with separately framed streams and bounded decompression; avoid a
  whole-world stream requiring unrelated chunks to decode. Add explicit codec/version
  compatibility if adopted rather than silently changing the initial format.
- Measure hashing costs of the initial BLAKE3-256 chunk-checksum solution across indexed
  reads, saves, recovery, and compaction; distinguish hashing from encoding and I/O costs.
  Experiment with alternative checksum/hash algorithms, including CRC32C, using representative
  tiny uniform records, large block payloads, and metadata-heavy chunks. Compare CPU cost,
  record-size overhead, and integrity strength before changing the design. Any adopted change
  requires explicit format compatibility/versioning; do not silently change existing digests.
- Pack variable metadata into one contiguous allocation if profiling shows benefits over
  separate array allocations. A relocatable layout using relative offsets, correct alignment,
  and records without owning pointers could clone its payload with one bulk byte copy.
  Current array descriptors contain absolute pointers: copying their bytes alone aliases
  the old storage and is not a deep clone. Separate pointer-free array payloads can already
  be copied in bulk individually; packing mainly reduces allocations and copy operations.
  Compare that benefit against capacity partitioning and relocation on growth. This remains
  an in-memory optimization; disk encoding still uses the explicit versioned binary format,
  not native struct bytes or padding.
- Per-chunk mutation overlays can defer full block copies, but require merged reads,
  collision/meshing/validation support, bounded overlay depth, and eventual materialization.
  Document this option and defer implementation until measured mutation/capture costs justify it.
- Nibble-count RLE may improve short-run compression; benchmark against byte counts on real
  terrain and edits before adding a codec version.
- Bounded encoded caches remain profiling-driven options. Adaptive compaction throttling
  could adjust I/O batch size, bandwidth, or work duty cycle in response to measured
  gameplay latency and storage contention. Defer that feedback loop; use background
  priority, bounded buffers, incremental I/O, and cancellation/yield points initially.
- If later adopting selective COW, separate block/metadata ownership could avoid block copies
  for metadata-only edits. This is conditional on that future decision: v1 has no persistence
  COW and one capture unit. Measure avoided copies against added ownership complexity before
  splitting it; do not introduce this machinery preemptively.
- A future independent scheduler could retain deadlines separately and arrange loading before
  execution for non-lazy events. Define late-I/O and global activation semantics before using
  it to release their timer residency pins. R77 already permits all-lazy timer chunks to
  unload without such a scheduler; v1 still does not preload unfinished timers at startup.
  Future economy events need explicit semantics and must not inherit terrain laziness.

### Affected Components

- `src/voxel_app/world_data_service.zig`: snapshot barriers, frozen-source ownership and admission, dirty
  tracking, durable lookup, mutation gateways, and checkpoint completion.
- `src/voxel_app/world.zig`, `world_chunk_data.zig`, `chunk_metadata.zig`, `roads.zig`:
  capture gating of persistent fields and restricted snapshot views, preserving current
  `WorldChunk` ownership/layout and excluding transient/derived fields from serialization.
- New application persistence modules: binary codec, base index, journal framing/recovery,
  save coordinator, allocation ownership, filesystem publication, and compaction.
- `src/voxel_app/main.zig`, `player_controller.zig`, `simulation_worker.zig`: lifecycle,
  authoritative player checkpoint publication, restored state, scheduling, stopping existing
  producers for shutdown, and visible save status/errors. No demo-worker state serialization.
- `build.zig` and CPU tests: persistence tests and deterministic fault injection.
- `docs/voxel-world.md`, `docs/architecture.md`: ownership, save lifecycle, and compatibility.

### Data Model Changes

Introduce a world UUID, generator version, snapshot sequence, checkpoint world/player
records, frozen source handles with epoch/revision identity, persistence dirty sets/watermarks,
segment identities/lineage, installed-base generations/read handles, residency pins, world-lock
ownership, and a disk record index. Persistent chunk revisions are serialized as u64.
During implementation, choose whether their in-memory identities are separate u64 values
or replace/widen authoritative u32 chunk revisions. Either choice must prevent wrap,
reset on reload, or reuse of older identities, and must cover metadata-only changes. Eviction uses
live/installed-base revision equality plus pins, without separate per-WAL eligibility tracking.
Retain `WorldChunk`'s existing field arrangement, block-pointer representation, inline metadata
descriptors, and derived/runtime fields. Do not add an independently owned persistent object
or physically split packed flags solely for capture. Introduce restricted views with copied
persistent identity/history and descriptors borrowing pinned backing buffers under R33.
Required persistent revision and service-side capture bookkeeping remain in scope.

### API Changes

Required capabilities, with exact API signatures chosen during implementation: request/observe
checkpoint; publish ordered player checkpoint;
resolve persisted chunk; admit complete mutation write sets; report source release and
checkpoint completion; request compaction; and drain/final-save shutdown. Narrow codec/file APIs should support
in-memory buffers and fault-injected storage tests without graphics or a running UI.
Expose separate WAL-commit/base-install events and an exclusive world-open/close lifetime.
Distinguish restricted snapshot views from complete gameplay/client chunk copies. Encoder
interfaces accept only views with copied scalars/descriptors and const borrowed payloads;
they cannot access live chunk headers or caches. Mutation interfaces maintain contents and
live caches together without exposing intermediate states.
Carry client/session command sequences and checkpoint dependency watermarks in service
messages; expose operation stages/resolved-prefix progress for save barriers and shutdown.

### Risks

Initial block decoding deliberately trusts compatible writers and checksum-verified bytes
without validating exhaustive-enum membership. A violated writer/versioning assumption can
therefore cause runtime undefined behavior even when the file's checksums match.
Missing one direct metadata mutation defeats capture isolation. Capturing only a global time
variable does not freeze a consistent object graph. O(dirty) manifest capture can still stall
large worlds. Global simulation pauses can be visible; output backpressure couples source
hold times to disk throughput. Borrowing live headers/array descriptors can race with updates
or hash-map relocation; reading packed live flags can race even when only derived bits change.
Copy the selected scalars/descriptors at capture and pin their backing payloads under R33.
Allocation budgets do not eliminate encoding, client copying, or live-world growth.
Unmeasured allocator overhead/fragmentation needs headroom and process telemetry.
Player state needs explicit ordering/ownership. Pending optimism can hide short waits
but cannot guarantee invisible long delays. Cancellation needs a safe encoder handoff that
can progress independently of stalled I/O. R73 prevents deadline cancellation starvation
but allows a visible exceptional pause; actual storage failure can still prevent saving.
Active-chunk estimates do not bound metadata, accumulated dirty state, or timer retention.
Catching up requires spare processing capacity and current-state revalidation.
File length alone does not detect corruption. Rename without required file/directory
synchronization does not establish
the intended crash durability. Background priority cannot prevent all resource contention.
Eviction before exact-version base acknowledgment loses newer state. Old offsets paired
with a replaced file read incorrect records. Construction/road helpers and timers currently
assume retained chunks, so eviction requires dependency/residency integration. A lock on
the replaceable base alone does not provide continuous exclusive ownership.

## Tasks

Proposed implementation tasks under the confirmed starting policy; sequencing may be refined
during implementation planning. Implementation is now authorized; mark tasks complete only with
implementation and validation evidence. The [validation report](../../docs/persistence-validation.md)
and [criterion evidence map](../../docs/persistence-acceptance.md) distinguish verified behavior
from incomplete test/evaluation campaigns; unchecked evaluation tasks are not waived.

- [x] T1: Translate the agreed contracts into module boundaries, ownership/message APIs,
  operation-specific reservation paths, and storage/fault-injection interfaces. Specify the
  restricted snapshot view and existing block/all-air allocation lifetimes; assign explicit
  material constants under R49. Use R66 for measured parameters; preserve the agreed binary
  layouts and failure policies.
- [x] T2: Implement the agreed container, descriptor, chunk/global/player codecs, and
  checksum coverage with strict validation, byte-layout fixtures, and round-trip tests.
- [x] T3: Implement framed journal commits, indexes, storage synchronization, and recovery.
  Implement the macOS/APFS storage adapter and R63-R65 barrier order, with explicit failures
  for unsupported primitives and native filesystem tests alongside the fault-injected model.
  Establish snapshot zero and the first segment durably, with distinct create/open paths
  and crash tests covering initialization before the first periodic compaction.
- [x] T4: Integrate service snapshot boundaries, frozen-source admission, bounded capture output, dirty
  acknowledgments, generation-safe base loading, and base-backed eviction/dependency pins.
  Preserve the current `WorldChunk` layout and construct restricted views with copied
  identity/history/descriptors and pinned const block/metadata buffers. Exclude live headers,
  packed flags, and caches from encoder access; preserve cache consistency across edits,
  failed preparation, loading, and gameplay/client copies.
  Add budget accounting/reservations to existing block/metadata allocation paths and
  fallible metadata operations with partial-allocation cleanup; defer custom pools. Expose
  configurable local limits, capacity counters, and resource-failure/status hooks for later RAM budgeting.
  Add R76 phase timestamps and bounded pressure/freshness instrumentation at those boundaries.
  Reuse validation/discovery results and bounded operation scratch storage; preserve in-place
  mutation for exclusive prepared chunks and use private staging only where necessary.
  Track dependency-wait/ready/terminal stages and preserve command order across async loads.
  Define timer passes with a fixed tick/resident due-chunk list, preserve finite local
  catch-up, and save overdue/deferred timer state without recursive catch-up passes.
  Implement R77 timer-kind eviction eligibility, resident due-index removal/restoration,
  and scoped operation pins. Integrate R78 registration on load and catch-up in the next
  eligible block-timer pass; audit edit-time eligibility maintenance across every mutation path.
- [x] T5: Implement segment rotation and streaming background compaction with source checksum/
  lineage verification and safe publication; inject source corruption during consumed reads.
- [x] T6: Integrate load/save lifecycle, autosave/final-save, player restore, and save status.
  Integrate capture-pending player state, priority encoding, normal elapsed-wait cancellation,
  R73 overdue-save escalation and visible exceptional pause, the R75 coordinator watchdog,
  genuine resource retry/rejection and optimistic reconciliation; global simulation capture gating,
  paced resume, deferral/backpressure; and pre-reserved completion/status reporting.
  Gate player checkpoints/save barriers on resolved command prefixes and drain outstanding
  dependency I/O before final capture.
  Add the single shutdown phase/error dialog, bounded dependency-read retry, delayed-status
  choices, safe cancel-exit handling, and explicit unsaved-exit path under R60-R62.
- [x] T8: Add stable exclusive world ownership before recovery through final shutdown.
- [ ] T9: Implement the bounded v1 reference-model harness and deterministic fault-injected
  storage. Exercise production paths across edits, snapshot/ownership transitions, commits,
  rotation, compaction, eviction/reload, and crashes; compare recovery with the reference
  history and verify corruption handling separately. Include progressive release followed by
  cross-chunk edits, stale completion epochs, stalled output and cancellation, pending-player
  status/retransmission models, paused/resumed timer progress, and view safety during header
  relocation/derived-flag updates under AC117-AC126 and AC43. Add AC127-AC131 coverage for
  escalation, bounded backpressure, finite slow/stalled I/O, source release, and shutdown.
  Add AC132 coverage for deadline selection, retained wait timestamps, release-driven retries,
  and freedom from deadline busy loops across capture epochs and mode changes.
  Cover AC133/AC134 with independent write/synchronization gates, fitting and oversized captures,
  and deterministic metric-attribution checks. Keep replayable seeds/traces and explicit
  critical-boundary cases in the regular CPU test suite. Cover revised AC27/AC29 and AC135
  with all-lazy and mixed timer sets, repeated reloads, original overdue deadlines, stale
  due-index entries, and metadata-only revisions that break base equality. Model the non-lazy
  policy case in the harness without adding a new serialized gameplay kind solely for testing.
  Add AC136/AC137 coverage for readiness before catch-up, fair bounded pass progress, edits
  before timer execution, idempotence, incremental/large-step equivalence, cross-boundary
  edits, and no timer-time neighbor loads.
- [ ] T7: Measure snapshot/edit latency, memory use, and compaction interference; tune budgets.
  Compare worker CPU, allocations, copied bytes, and latency against baseline with saving
  inactive/active, separating gate/preparation, source waiting, existing client copies, encoding,
  and cancellation work. Measure player confirmation/correction and near-player simulation
  pauses, plus catch-up debt and overload behavior; validate the chosen baseline before
  proposing additional capture policies.
  Run the R66 workload matrix and candidate parameter sweeps at R74 target scales, including
  smaller 8 GB workloads, successful-save age/rate and exceptional pauses. Select and record
  default allocation budgets, queue limits, retry/backoff and escalation parameters, and
  cancellation/latency regression thresholds, including p95/p99/maxima and occupancy results.
  Provide the R76 repeatable benchmark runner and machine-readable reports, including larger
  output-capacity sweeps and multi-cycle save/compaction trends. Compare the same traces and
  report real-time versus deterministic evidence separately. Verify pressure behavior with
  tiny configured budgets/fault injection, not physical OOM.
- [ ] T-val: Run acceptance criteria verification, crash/failure injection, relevant CPU
  regression tests, and application builds; document durability/performance limits.
