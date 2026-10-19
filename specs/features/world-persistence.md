---
service: zig_engine
created: 2026-10-15
status: draft
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
[PR #28](https://github.com/bacher/zig_engine/pull/28). Implementation remains
unauthorized. Whole-system RAM budgeting follows persistence v1 in
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

The intended future workload is approximately 99.9% simulation-initiated chunk updates.
Players guide the simulation and cannot directly perform massive world changes. This is a
planning assumption, not a measured ratio, a hard limit, or permission to omit worst-case
workloads. Couriers can span chunks; workers consume inputs at benches; builders follow
blueprints. These systems are not implemented and remain outside persistence v1.
Simulation runs in the world-service process. Player interactions must also work over a
network; the current in-process endpoint is not a wire-level retry/deduplication protocol.

The initial measurement target is approximately 10,000 simultaneously active chunks and
2,000-4,000 distinct changed chunks per 60-second save interval on a 16 GB machine, with
smaller worlds supported on 8 GB machines. These are workload/hardware targets, not hard
chunk limits or measured memory guarantees. Active materialized blocks alone occupy
312.5 MiB; 2,000-4,000 raw block payloads occupy 62.5-125 MiB before metadata/framing.
Metadata, meshes, replicas, retained dirty chunks, and work buffers add to those figures.
Missed saves can accumulate more dirty chunks than one normal interval or the active set.

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
- RETAINED: unaffected PR #28 decisions, including the durable format, recovery, compaction,
  base-only reloads, mutation atomicity, offline-time policy, and local budget controls.
- DERIVED correctness requirements: one capture boundary, synchronized source release,
  complete mutation write-set admission, bounded pending work, and separation of pending
  admission from terminal rejection and durability.
- PROPOSED implementation details: the capture states, scheduling/notification mechanisms,
  and staged evaluation plan below. Numerical latency/work limits remain measurement
  decisions under R66. Direct simulation-thread mutation leases and the future NPC
  catch-up/state model are not approved implementations. Draft status records those
  remaining details; it does not reopen unaffected confirmed decisions.

## Requirements

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
  view orientation, and an explicitly framed inventory extension. Inventory contents and
  multiplayer gameplay are future work. Restore position/view, reset motion safely, and
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
  the resident map is not proof of absent construction/road metadata. Once normally loaded,
  chunks with pending terrain transformations stay resident in the initial implementation.
  Do not discover/preload all timer-bearing chunks when opening a saved world. Restore their
  original timer records when ordinary streaming or gameplay dependency reads load them,
  then use due-event processing with R47's fixed pass boundary. Persistence scanning, recovery, and compaction
  alone do not activate timers or create live resident chunks. Broader scheduled-event
  semantics and independent deadline scheduling with advance loading are follow-up work.
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
- R47: At the start of each normal terrain-timer pass, capture logical tick T and a fixed
  list of currently resident chunks with timers due at or before T. Process each selected
  chunk once against current authoritative state, revalidating after asynchronous waits;
  cancelled/replaced timers must not execute from stale observations. Keep T fixed throughout
  the pass. Chunks loaded after the eligibility boundary, including dependency loads, wait
  for a later normal pass rather than expanding the current list or triggering recursive
  passes. Preserve existing finite dirt-to-packed-dirt-to-grass catch-up within a selected
  chunk: follow-up deadlines derive from the original deadline and may execute in the same
  pass if due by T and current conditions permit. Dependency/resource deferral publishes no
  partial operation and preserves pending timer state under R31/R39. This rule is in scope
  for persistence v1; broader scheduling remains deferred.
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
  explicit legacy decoding is retained. Older engines reject newer-version files.
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
  layouts below without native padding. Block codecs are u8 numbers: raw 0, standard RLE 1;
  reject reserved/unknown values 2-255 at per-record dispatch. Persist chunk revisions as
  u64 and historical `is_unreachable` as persistent flag bit 0. Initial metadata sections
  use schema version 1, required flag bit 0, and tags 1 custom blocks, 2 construction
  markers, 3 pending transformations. Emit nonempty sections once in ascending tag order;
  absence means an empty collection, subject to custom-cell correspondence requirements.
- R54: Use the schema-1 metadata payload layouts and byte limits below: 2-byte construction
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
- R57: Use the confirmed binary container layouts below, starting at save-format version 1:
  120-byte base and WAL segment headers, an 84-byte transaction header, and a 56-byte commit
  footer. Base index and chunk records are sorted by chunk ID, players by player ID, with
  unique identities and exact count/extent agreement. WAL transactions contain complete
  global/player state and unique changed-chunk records; their total length is in the footer
  so encoding streams without WAL backpatching. Follow record framing, never magic scanning.
- R58: Persist the immutable world descriptor's layout, topology, generator identity/version,
  seed, explicit settings, and tick rate. Do not substitute current generator defaults.
  Serialize global state and player records using the layouts below, with IEEE-754
  little-endian floats, f64 player feet positions, f32 yaw/pitch, and an initially empty
  framed inventory. Retain all historical players; the future concurrent-player limit is
  not a lifetime record-count limit. Session command watermarks govern capture eligibility
  but are not serialized as persistent session counters.
- R59: Use BLAKE3-256 for chunk, WAL-header, transaction, initial-anchor, and base checksums
  with the exact domain-separated coverage below. Validate the immutable segment header even
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
  16/32/64 MiB and streaming buffers of 64/256/1,024 KiB as experimental inputs, not defaults
  or preallocations; separately reserve bounded output for records larger than a stream buffer.
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
  terrain-timer pass and finite local transition chain remain intact, with original deadlines.
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

## Clarifications

- Q1: Persist generated or only changed chunks?
  A1: CONFIRMED by the user: changed chunks; preserve generator compatibility. Persist a
  generator version and retain its implementation or provide an explicit migration.
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
  A7: REVISED by the user on 2026-10-19: v1 uses no persistence COW reserve. Budget the
  manifest, encoding/output buffers, and waiting operations, while accounting for source
  retention. Keep the confirmed safe-cancellation and no-partial-publication guarantees.
  A request to cancel is not a source-release acknowledgment. Defer mutations until active
  readers relinquish ownership, independently of stalled WAL writes/repair. R38 distinguishes
  ordinary capture waits from genuine allocation failures. Numerical limits follow R66.
  R73 changes the automatic cancellation policy for overdue saves without weakening safe
  ownership handoff or capacity limits. No promise of zero allocation or zero latency under
  arbitrary pressure.
- Q8: How are player state and world edits given a common ordering boundary?
  A8: CONFIRMED by the user: publish small player checkpoint records to the authoritative
  service in order with player commands. Each record carries its preceding player-command
  dependency sequence and becomes eligible when the required prefix is applied or rejected.
  Capture the latest eligible record at the snapshot boundary, never the optimistic chunk
  cache. Dequeued operations waiting for I/O remain unresolved; see Q26.
- Q9: What is the exact binary encoding contract?
  A9: CONFIRMED by the user: runs split at 255, explicitly length-framed encoded sections,
  no nibble counts initially, and chained WAL checksums. Little-endian integers, explicit
  field widths, and metadata extension rules are confirmed in Q34. Stable material IDs follow
  R49; BLAKE3-256 is confirmed for all checksums, with snapshot hashes streamed over new bytes.
  CONFIRMED initial block codecs: standard byte-pair RLE and raw fallback under R15; palette
  order/three-material handling are deferred with palette encoding. Q35 confirms chunk-record
  framing, codec IDs, metadata headers/tags, and checksum-domain bytes. Q37 confirms full
  containers, world/player records, and checksum coverage. Q36 confirms initial metadata
  payload layouts and byte limits. Assigning explicit constants to the existing material
  meanings under R49 is implementation work, not an undecided format strategy.
  Metadata entry-count/uniqueness rules are confirmed in R51.
  Stable enum/version policy is confirmed in Q32.
  Confirmed eight-byte magic values are `ZGWORLD\0` and `ZGWAL\0\0\0`, with initial write/
  minimum-readable versions 1. Reject unsupported versions and required sections/custom types.
- Q10: What happens after corruption, a missing journal, or repeated storage failures?
  A10: CONFIRMED v1 policy by the user: incomplete final WAL appends are routine recovery;
  committed corruption, missing committed dependencies, or ambiguous damage preserve the
  original files, print the save path and error to stderr, and exit the game with a nonzero
  status. No recovery selection UI or older-snapshot continuation in v1; those workflows
  and backup retention/export are follow-ups. Never silently create a replacement world.
  Ordinary write/compaction failures retain their existing retry/status contracts;
  shutdown-draining UI/retry behavior is confirmed in Q38.
- Q11: How are persisted nonresident chunks supplied to synchronous validation readers?
  A11: CONFIRMED by the user: permit eviction only once the exact latest state is in the
  installed base, established by equality of monotonic live and installed-base revisions
  together with ownership/gameplay pin checks; no WAL inspection is needed. Propagate persistence status
  to the service. Runtime loads read indexed base records without replaying WALs. CONFIRMED:
  explicit dependency-wait/ready/validate-and-commit stages under R41; concrete loading/pin
  interfaces remain implementation design. CONFIRMED: keep chunks
  with pending terrain transformations resident once loaded, without preloading timer-bearing
  chunks at world startup. Treat unsaved and pending-snapshot versions as newer state too.
- Q12: When should advanced persistence optimizations be implemented?
  A12: RETAINED: defer nibble counts, mutation overlays/replay-on-read, heuristic encoded
  caches, and independent deadline scheduling. Implement basic background priority, bounded
  streaming, and cancellation/yield points initially; adaptive contention feedback remains
  a follow-up. REVISED: the initial design has no persistence COW. Keep blocks, metadata,
  and flags under one per-chunk capture/mutation gate and release sources promptly after encoding.
  Selective COW, synchronous encode-before-write, and per-chunk simulation scheduling are
  optional later policies evaluated with the same correctness/performance harness.
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
  A16: CONFIRMED by the user: no. Saved timer-bearing chunks load through ordinary world
  access. Loaded pending timers prevent eviction; unloaded saved timers do not cause
  eager loading or global timer activation. Preserve their saved records and use existing
  timer processing when loaded. Revisit this logic when more scheduled events are added.
- Q17: Must a committed snapshot fit a base smaller than 4 GiB?
  A17: CONFIRMED by the user: remove the 4-GiB restriction and use u64 chunk file offsets
  instead of adding a prospective compacted-size check. Widen related aggregate sizes and
  counts as described below; chunk IDs remain u32. Normal bounds and arithmetic validation
  still apply.
- Q18: Must every WAL transaction scan or repair the file, and when is cancellation too late?
  A18: CONFIRMED by the user: repair only after a failed/cancelled append that may have left
  bytes. Remember the last synchronized offset, sequence, and checksum in memory; truncate
  and synchronize the existing segment without a WAL scan. Suspend new appends/rotation
  until repair succeeds. Once commit-footer writing begins, finish resolving the commit
  attempt instead of reporting cancellation. Startup may recover an unacknowledged valid
  final transaction if a crash preceded durable repair.
- Q19: How are capture failure policy and implementation choices separated?
  A19: RETAINED: lightweight advance reservation with selective staging and the genuine
  allocation-failure policy in Q25. Include metadata/publication capacity. REVISED: replace
  COW preparation with full-write-set capture admission; there is no detachment path in v1.
  Let released player work and a paced simulation slice progress before a replacement
  capture can freeze their data again. Concrete queues, notifications, and cancellation
  limits below are implementation proposals to validate under R66.
- Q20: Should all metadata arrays share one contiguous backing allocation?
  A20: RETAINED: initially allocate each nonempty array separately and prioritize empty
  metadata; all-air chunks do not need a block buffer. REVISED/CONFIRMED by the user: retain
  the inline `WorldChunk.metadata` descriptors and existing block-pointer representation.
  Remove the requirement to colocate a new persistent owner/header with the block payload
  in one allocation. R34 now defers custom pools and uses existing allocators with budget
  accounting. A contiguous variable metadata payload remains a potential improvement.
- Q21: Does capture require physically splitting the live `WorldChunk`?
  A21: REVISED/CONFIRMED by the user: no. Retain its current ownership and field arrangement
  initially. Keep persistent/derived/runtime categories in the serialization contract and
  expose a restricted snapshot view under R33. At the boundary, copy small persistent values
  and buffer descriptors into the view; pin the borrowed backing allocations until release.
  Historical `is_unreachable` may stay in the existing packed flags: capture its value on
  the authoritative worker so the encoder never reads storage shared with mutable face flags.
  No separate persistent owner or header copy is needed. Inline field grouping is optional;
  future COW ownership can be introduced behind the capture interface if justified. Ordinary
  gameplay/client copies retain their own consistent contents and caches.
- Q22: How should allocation, growth, and memory accounting work initially?
  A22: REVISED/CONFIRMED by the user: defer custom pools to a potential improvement. Retain
  existing allocation mechanisms, separate nonempty metadata arrays, empty-array/all-air
  optimization, stable capture buffers, and fallible/reservable preparation. Count allocated
  capacities and temporary old/new overlap, views/manifests, and encoded output; pins do not
  duplicate live storage. Report known overhead and unmeasured allocator costs separately
  under R34, with headroom/process telemetry. The former two-pool policy and provisional
  64-byte minimum class are withdrawn. Semantic limits remain R51/R54; budgets are tuned
  under R66. No save format or `WorldChunk` ownership change is needed.
- Q23: Does this iteration implement whole-system budgeting and priorities?
  A23: RETAINED: global pressure controls, player-protected residency, movement gating, and
  richer throttling UI follow persistence as a separate feature. REVISED: persistence v1
  includes the minimal all-simulation capture gate and priority for encoder work needed to
  unblock pending player edits. Those are capture policies, not the full future residency
  scheduler or near-player simulation policy. See [Resource budgeting](resource-budgeting.md).
- Q24: How much normal-path work should allocation-failure safety introduce?
  A24: CONFIRMED by the user: preserve atomicity with lightweight resource preparation rather
  than a general rollback framework. Mutate exclusive chunks in place, reuse validation/
  discovery results, and keep compact operation descriptions in reusable scratch storage.
  Reserve capacity before mutation; use private staging only where dynamic effects require
  it. Do not add unconditional whole-chunk copies or duplicate full validation just for OOM
  handling. Concrete preparation mechanisms require code-level design and measurement;
  there is no measured percentage or latency guarantee yet. Configured budget exhaustion
  must also be handled safely even when physical RAM is not exhausted.
- Q25: What if memory is still unavailable after capture cancellation?
  A25: RETAINED for genuine allocation failures: one automatic player retry after a useful
  ownership handoff, then explicit rejection/reconciliation; skip ineffective cancellation.
  Simulation remains pending with bounded state, backpressure, and resource signals/backoff.
  Preserve timers and dirty state; distinguish budget, allocator, and semantic failures and
  reserve completion capacity. REVISED: ordinary capture contention is a nonterminal wait
  governed by elapsed time and safe release, not this one-retry failure allowance. Applied
  and terminal rejected commands are never silently replayed.
- Q26: How do asynchronous dependencies affect command/checkpoint/save ordering?
  A26: CONFIRMED by the user: load dependencies before mutation, then validate and commit
  atomically against current authoritative state, preserving required command order. Model
  dependency waits explicitly; dequeuing is not completion. Player records name a preceding
  command sequence and become eligible after those commands are applied or rejected. Here
  an accepted outcome means the operation was applied, not merely admitted to a queue.
  Final shutdown must drain I/O-waiting operations as well as queued/ready work.
- Q27: What anchors journals before the first periodic compaction of a new world?
  A27: CONFIRMED by the user: install a small durable snapshot-zero base with world/generator/
  layout/initial state and its chain anchor, then establish the first WAL. No WAL snapshot
  may be acknowledged before that base is durable. Keep explicit creation separate from
  opening an existing world whose base is missing; never silently replace the missing base.
- Q28: Must compaction revalidate inputs, and should individual chunk records be checksummed?
  A28: CONFIRMED by the user: verify base/WAL source integrity before publishing a newly
  checksummed output. Direct encoded copies remain valid only under that verification.
  CONFIRMED by the user: per-chunk record checksums for independent indexed-read verification,
  covering chunk identity/content version, framing/codec, persistent flags, encoded blocks,
  and metadata. CONFIRMED initial choice: BLAKE3-256 footer and coverage/layout described below.
  Chunk field widths and checksum-domain bytes are confirmed in Q35 and the layout tables below.
  These record checksums supplement the base physical checksum
  and WAL transaction chain; they cannot replace transaction-wide completeness/ordering checks.
- Q29: What timer eligibility and catch-up behavior belongs in persistence v1?
  A29: RETAINED: fixed pass tick and resident due-chunk list; newly loaded chunks wait for
  the next pass; preserve finite overdue soil-transition chains and original deadlines,
  evaluating current terrain. No recursive draining before saving. REVISED by the user:
  capture pauses all simulation, including these passes, and resumed work catches up
  against current conditions. Preserve elapsed logical progress and pace resumed work.
  General NPC scheduling/state representation and global timer discovery remain deferred;
  exact historical replay and offline elapsed-time catch-up are not required.
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
  A34: CONFIRMED by the user: little-endian integers, explicit field widths, and versioned,
  length-delimited metadata sections. Reject unknown required sections/custom types; skip
  unknown sections only when explicitly declared optional and safe to ignore. Never silently
  reinterpret existing bytes after a format change. Section-header widths/tags are confirmed
  in Q35; the current/minimum readable version policy still applies.
- Q35: Which concrete binary framing and IDs should the initial format use?
  A35: CONFIRMED by the user: numeric u8 block codecs (raw 0, standard RLE 1), the chunk
  record field order/widths below with 58 bytes of fixed overhead, and 9-byte metadata
  headers with tags 1-3, schema version 1, and a required flag. Empty collections omit
  their sections; nonempty sections appear once in ascending tag order. Use the specified
  zero-terminated ASCII checksum-domain prefixes and a fixed 16-byte world UUID in chunk
  hash input. Full container headers follow Q37; metadata payloads follow Q36.
- Q36: What are the concrete metadata payload layouts and resulting byte limits?
  A36: CONFIRMED by the user: serialize construction markers as u16 cell indices and timers
  as u16 cell index, u8 kind, and u64 deadline, with counts inferred from section length.
  Adaptive-road custom records contain a u8 type and u8 state; formed slopes additionally
  retain their high endpoint as three u32 coordinates, u8 downhill direction, u32 formation
  length, and u32 section index. Derive heights as today rather than storing floats. Preserve
  formation ownership for later edits. These layouts yield the section and combined bounds
  in R54; they do not imply worst-case preallocation. Recalculate bounds for future schemas.
- Q37: What are the base/WAL containers, world/player records, and full checksum coverage?
  A37: CONFIRMED by the user: use the exact fixed/versioned headers, world descriptor,
  global/player records, streaming WAL transaction/footer, and BLAKE3-256 coverage below.
  Base layout is header, descriptor, global state, chunk index, player records, chunk records,
  and physical checksum. Each WAL transaction carries full global/player state plus changed
  chunks. Its total byte length is written in the commit footer, without backpatching WAL
  bytes. Include all generator settings and preserve historical players. Snapshot zero hashes
  the canonical logical contents; compaction preserves the incorporated logical digest.
- Q38: What minimal UI and retry behavior should shutdown draining failures have?
  A38: CONFIRMED by the user: one responsive dialog for finishing pending actions, saving,
  and finalizing. Retry transient failed dependency I/O once after a provisional one second;
  then expose Retry, Cancel exit, or Quit without saving. After a provisional five seconds
  without progress, show Keep waiting instead of Retry while work is still in flight.
  Never duplicate outstanding work, silently replay rejected edits, or discard actions on
  a timeout. Cancel exit preserves state and resumes gameplay. Explicit unsaved exit may
  use process-interruption semantics if a worker is stalled, retaining recoverable files.
  Final-WAL success followed by compaction failure permits reported exit with WAL retained.
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
  A41: CONFIRMED on 2026-10-19: start without persistence COW, pause all simulation during
  capture, keep player edits pending with optimistic visuals, prioritize their chunks,
  and normally cancel capture safely after a bounded wait if needed. Q46 records the later
  confirmed exception for overdue saving. Catch up against current conditions. The
  approximately 99.9% simulation-update assumption and wire-compatible
  player interactions come from the user's requirements. Concrete state/queue APIs, numeric
  thresholds, and the evaluation gates below are proposals or measurement work; none are
  claims of measured responsiveness. Unaffected confirmed decisions remain in force.
- Q42: Does a global pause last through WAL synchronization or compaction?
  A42: No. DERIVED from the selected policy: it lasts only while captured source contents
  must stay unchanged. Resume after normal release or accepted cancellation's safe handoff.
  Bounded output buffers can fill behind slow disk writes and extend capture; prioritize
  players and normally cancel safely rather than assuming encoding and disk throughput are
  independent. Under R73, accept a visible capture pause so an overdue save can progress.
- Q43: Must catch-up reconstruct every historical intermediate world?
  A43: CONFIRMED by the user: no; use current conditions while preserving logical-time
  progress and preventing duplicate effects. Future courier transfers must conserve goods
  atomically across their full affected state, workers cannot manufacture output for periods
  without eligible inputs, and builders must revalidate blueprints/resources. These are
  future simulation constraints, not an NPC implementation or a new save schema in this PR.
  CONFIRMED deferral: decide economic event ordering in the future simulation spec, including
  whether a delivery due before food expiry must be processed first after a capture pause.
  Current-conditions catch-up does not settle that ordering or guarantee unchanged economic
  outcomes across persistence delays. R47 terrain-timer semantics remain unchanged.
- Q44: Can simulation mutate service chunks directly from another thread?
  A44: The same-process clarification permits considering that optimization; it does not
  establish its synchronization design. PROPOSAL: retain the existing service mutation worker
  initially, allow in-process intent/batch submission, and defer exclusive mutation leases.
  Any later lease must cover dependencies and authoritative publication, not only block bytes.
- Q45: What remains open before calling the design validated?
  A45: UNRESOLVED by measurements: acceptable player confirmation latency and observable
  near-player simulation pause in normal mode; normal capture duration and overdue-save
  escalation threshold; cancellation/checkpoint backoff; catch-up service capacity; and
  buffer/queue sizes for the R74 target workloads. The global-pause baseline must be tested
  against the normal no-noticeable-freeze requirement, with the explicit Q46 exceptional
  saving pause assessed separately. If normal operation fails, revisit per-chunk scheduling,
  near-player continuation, eager capture, or selective near-player COW rather than silently
  weakening that requirement. No finite-memory policy guarantees uninterrupted successful
  saves and edits under an indefinitely stalled disk or unbounded workload.

- Q46: May overdue saving visibly pause world-changing actions?
  A46: CONFIRMED by the user on 2026-10-19: eventually prioritize completing a save and allow
  an exceptional saving pause, including player edits, with responsive rendering, camera,
  and UI. This supersedes cancellation-at-any-cost during active play. The R73 elapsed-age
  policy prevents retry attempts from resetting escalation; numeric thresholds and concrete
  mode/gate APIs remain proposals to tune. Source release and WAL durability remain distinct.
  Storage failure is still reported, never converted into a false success or unlimited memory.
- Q47: What workload and machine sizes should the first usable version target?
  A47: CONFIRMED by the user: about 10,000 simultaneously active chunks, 2,000-4,000 distinct
  changes per 60-second save interval, and 16 GB RAM, with smaller worlds on 8 GB machines.
  The smaller-world size and memory/latency defaults remain measurement work under R66/R74.
  Whole-capture buffering remains a review proposal; the bounded streaming baseline stays.
  Custom pools are now explicitly deferred under the separate user-confirmed Q22 decision.

- Q48: Does each capture or pending player request need its own timer/retry loop?
  A48: CONFIRMED by the user: use one coordinator watchdog checking the earliest applicable
  capture-related deadline, and retry waiting admissions on meaningful source-release events.
  Preserve each request's original wait timestamp across retries and capture epochs. R75
  defines the contract; timer APIs, deadline data structures, and numeric thresholds remain
  engineering choices. This does not select future simulation event scheduling.

- Q49: Do normal gameplay deadlines cancel the final shutdown save?
  A49: CONFIRMED by the user: no. Producers are stopped; let the final save continue within
  the same memory limits while completion handling and the existing wait/cancel-exit/quit
  choices remain responsive. Actual failures retain their existing handling. Cancel exit
  restores gameplay capture policy through safe ownership handoff, preserving wait timestamps,
  unsaved age, and R30 commit boundaries; overdue-save priority remains applicable under R73.

- Q50: Must every capture wait produce a client-visible pending message?
  A50: CONFIRMED by the user: no. Keep pending primarily an internal state in v1; brief waits
  retain the existing optimistic operation until a terminal response arrives. Longer-delay
  status may be coalesced; required exceptional-saving and failure status remains visible.
  Preserve identities, ordering, bounded outstanding work, and pending/rejected distinctions.
  Networking, reconnect handling, and a persisted deduplication ledger remain deferred.

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
- AC11: GIVEN an older generator version and changed world dimensions WHEN reopening THEN
  saved settings/version determine untouched terrain, or loading explicitly rejects an
  unsupported generator/topology instead of silently producing different terrain.
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
- AC27: GIVEN a resident chunk with pending terrain transformations WHEN eviction is
  considered THEN the initial implementation retains it until those transformations are
  consumed/cancelled and the other eviction conditions are satisfied.
- AC28: GIVEN saved nonresident chunks with pending terrain transformations WHEN opening,
  recovering, or compacting a world THEN those persistence operations do not materialize
  live chunks or activate their timers solely because unfinished timers exist.
- AC29: GIVEN a saved timer-bearing chunk not loaded at startup WHEN ordinary streaming or
  gameplay dependency access later loads it THEN its original timer records are restored,
  pending timers pin it, and existing due-event processing handles them without resetting
  their deadlines.
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
- AC68: GIVEN a pass whose eligibility list includes A at tick T WHEN processing A loads B
  with an overdue timer THEN B is not added to that pass, no recursive pass is launched, and
  B becomes eligible at a later normal pass. A snapshot before B executes retains its timer
  and original deadline while including A's completed effects.
- AC69: GIVEN a selected chunk with an overdue dirt-compaction timer WHEN its grass-growth
  follow-up is also due by T and current terrain permits it THEN both existing transitions
  may complete in the same pass using the original deadline relationship. A follow-up after
  T remains pending even if world time advances while the pass waits for dependencies.
- AC70: GIVEN a selected timer waiting for dependencies WHEN it is cancelled/replaced or
  authoritative conditions change before execution THEN revalidation prevents stale effects.
  Dependency/resource failure consumes no pending timer or publishes a partial operation;
  snapshots remain valid with overdue pending work and retries obey R39 backoff rules.
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
- AC77: GIVEN an incompatible material/schema change without retained legacy decoding WHEN
  the minimum readable version advances THEN older files are rejected without reinterpretation;
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
  float widths and 52-byte empty-inventory framing. Reject nonfinite coordinates/angles;
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
  a queue entry per skipped tick, or an unlimited burst. Existing R47 timer tests still pass;
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
Timer residency pins apply only after ordinary chunk loading. Opening a world does not
eagerly load saved timer-bearing chunks or activate a global scheduled-event system.

## Out of Scope

Manual-save UI is deferred; v1 uses autosave and save-on-exit.
Linux/Windows durability adapters and durability guarantees for network filesystems or
actively cloud-synchronized save directories are deferred.
Implementation during the current planning iteration; multiplayer networking; an inventory
implementation; offline simulation catch-up; nibble RLE; delta chunk journals; per-chunk
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
Unchanged format/durability sections retain their prior confirmed status. The new capture
mechanics, transport outline, and evaluation stages are implementation proposals constrained
by the requirements above. Concrete interfaces and measured defaults remain implementation
work; unresolved gameplay/performance choices are listed in Q45. This plan does not authorize
starting implementation.

### Approach

New-world initialization first follows the snapshot-zero protocol below; existing-world
opening validates and recovers the existing history rather than taking the creation path.

1. Establish an authoritative snapshot boundary after a complete request batch and its
   timer pass under R47, before accepting the next batch. Pending/overdue timers, including
   deferred operations and newly loaded chunks, remain represented under R1/R39. Do not
   extend the pass to drain all overdue work. Assign snapshot sequence/world tick.
   Completion is defined by terminal operation outcomes, not queue removal; satisfy the
   save barrier's required command prefix and player-checkpoint dependencies before capture.
   Pause new simulation dispatch and finish already executing authoritative operations.
   Swap the dirty candidate set, freeze its chunk identities/revisions, and copy small
   global/player state under the same authority. This is O(number of candidates), so measure
   the worker cost. Blocks/metadata/flags stay immutable until source release; v1 does not
   detach/copy them. Player operations on writable sources can continue; conflicting complete
   write sets remain pending. Save barriers are resolved before establishing this boundary,
   not by waiting for post-boundary edits that are themselves capture-blocked.
2. The persistence worker encodes only captured changed chunks and appends one framed
   transaction to the active segment. A commit covers the entire captured set and global
   state; its hash includes the prior committed hash and protected transaction bytes.
   Flush/sync before acknowledging. Prioritize sources needed by pending player edits.
   Release sources progressively after complete encoding into independent owned output,
   before unrelated disk waits; resume simulation when the last source hold clears.
   Failed attempts keep changes eligible for a fresh snapshot. Repair a possibly written suffix by truncation and synchronization
   before subsequent appends or rotation, even if the failed attempt wrote a complete footer.
3. The service receives completion messages, advances its durable watermark, and reconciles
   dirty identities by captured version. Centralize writable access for every mutation path,
   including road helpers, flag revelation, metadata-only timer changes, and transformations.
   WAL-durable chunks remain resident until the base-install acknowledgment proves that
   their exact current version can be reloaded from the installed base.
4. At a committed boundary, establish a new active segment durably. Seal older segments and
   dispatch immutable input handles and a target sequence to one background compactor.
5. The compactor merges the base index with latest committed overrides through that sequence.
   Verify source base/WAL integrity while copying compatible encoded records without decoding
   untouched chunks. Write a complete new base, validate/sync/install it only after input
   verification succeeds, and publish an immutable generation/index handle to the service.
   Retire only incorporated segments after directory durability. The service reconciles
   base-backed versions and may evict eligible chunks; new edits in the active WAL remain
   resident. Readers using older file-generation handles can finish safely.
6. Startup validates the base and journal chain and classifies any failure under R55 before
   publishing recovery output. Apply recoverable journals before entering gameplay. Ignore
   only a clearly incomplete final append with no dependent successor. Preserve evidence
   and exit with a save-path/error message to stderr and nonzero status for committed
   corruption, missing dependencies, or ambiguous damage. Do not load an older snapshot or
   run the normal final-save path after fatal recovery failure.
   Commit records identify the previous committed sequence; abandoned snapshot attempts may
   consume sequence numbers without creating a broken dependency. Check dependency links,
   not numerical adjacency of attempted snapshots.
7. Treat encoded chunk caching as optional: unchanged durable chunks already have reusable
   encoded records on disk. Add a bounded in-memory cache only if profiling justifies it;
   key it by persistent content identity including metadata, not age or mesh revision.
8. Shutdown stops simulation/command producers, drains accepted operations and ordered player
   state including outstanding dependency loads, waits for any current saver/compactor,
   writes the final snapshot, and compacts all
   remaining committed segments. Publish/sync the final base before removing journals.
   A durable final snapshot permits exit with reported compaction failure and retained WALs.
   A final snapshot durability failure requires retry/cancel-exit/explicit-unsaved-exit choices.
9. Memory pressure can coalesce an early checkpoint followed by compaction instead of
   waiting for the normal intervals. Background work keeps the same concurrency limits,
   bounded buffers, and cancellation/yield behavior.

### Decision Impact Relative to PR #28

Stable requirement/criterion IDs are preserved; revised items replace their earlier COW
wording in place. New requirements start at R67 and new criteria at AC117.

| Existing decisions | Effect of the revised requirement |
| --- | --- |
| R2, R5, R20, R29, R31; Q7/Q12/Q19 | Replace mandatory COW with frozen-source admission, pending mutations, safe release, and capture limits. |
| R32-R35; Q20-Q22 | Keep logical field categories, empty metadata, budget accounting, and fallible preparation; retain the existing `WorldChunk` layout and restricted views. Defer custom pools; remove the mandatory physical split, combined owner/block slot, and version cloning. |
| R37-R43; Q24-Q26 | Keep in-place mutation, atomicity, resource failure, command prefixes and shutdown ordering; distinguish capture-pending work from terminal rejection. |
| R47/R18; Q29 | Retain original terrain deadlines, fixed-pass semantics and no offline time; pause dispatch for capture and preserve current-conditions catch-up. |
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
world. A courier must not remove goods from A and add them to B twice or in different
transactions. Worker output requires eligible inputs and cannot blindly multiply a production
rate by all skipped time if inputs only arrived later. A builder rechecks remaining blueprint
work/resources and records completed progress once. A resumed player edit or another actor may
have invalidated earlier plans; revalidation can change what work is still possible. Actor
identity, inventory, resource eligibility, cross-chunk transfers, and progress must eventually
be captured together with terrain to avoid loss/duplication after restart. Those schemas and
scheduler semantics belong to the future simulation feature; the current demo private phase
remains explicitly excluded. No elapsed time while the application is closed is added.

### Staged Evaluation Without Format Changes

These are proposed implementation stages after separate implementation authorization:

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
   circular hashing. Use the exact Snapshot Integrity anchor encoding below.
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

Represent an operation's lifetime explicitly:

```text
Waiting for dependencies / capture / resources
             -> Ready -> Validate / prepare / commit -> Applied or rejected
                  ^                |
                  +-- revalidate after additional dependencies or waits
```

Dependencies are loaded outside the authoritative worker's mutation path and pinned while
needed. The worker continues servicing load/ownership completions while commands wait.
Becoming ready does not itself grant permission to overtake earlier commands whose order
must be preserved. Validate against current authoritative contents at execution time, reuse
still-valid preparation results, and commit with R31 atomicity. Further dependency discovery
or resource deferral produces no partial effects. R26's generation/stale-completion rules
apply throughout. Load errors produce an explicit failure or retained wait/retry state;
missing data never means empty terrain or permission to skip validation.

A capture wait retains the logical operation and its command identity. Do not repeatedly
submit a new command, retire its optimistic effect, or advance its resolved prefix on a
pending notification. Required command ordering remains intact; only independent work whose
ordering allows it may proceed. Simulation dispatch is gated before it floods the service
queue. Completion processing, cancellation, and player reads remain runnable.

Distinguish request admission, terminal command outcome, and durable WAL acknowledgment.
Only an applied or explicitly rejected operation resolves its command dependency. Track
player-command sequences within their client/session, separately from snapshot sequences,
world ticks, and chunk revisions. Player checkpoint messages include a dependency watermark;
the service retains bounded pending checkpoint state and makes a record eligible only when
the entire required command prefix is resolved. A highest-completed ID with a gap is not a
resolved prefix. Use the latest eligible record at capture; optimistic terrain is never a
snapshot source. Rejection still resolves ordering and follows normal client reconciliation.

When a save request is ordered after commands, retain its required boundary across dependency
waits. Do not silently fulfill it with an earlier state just because earlier commands left
the inbound queue. A snapshot of an earlier completed prefix, if requested as such, can use
only player records eligible for that prefix and must not claim the waiting commands are
included. Snapshot capture itself stays between complete operations.

Shutdown stops new producers but keeps loaders and completion handling available until
admitted commands have resolved and the final player checkpoint is eligible. Count queued,
waiting, ready, and executing work when deciding whether draining is finished. A load failure
must resolve explicitly or keep shutdown in a reported failure/wait state. Future scheduled
events and resource-deferred timers represented in persistent metadata need not all execute
before exit; preserve their pending records. Do not discard an admitted command by treating
it as a saved timer unless its pending state is actually represented by that policy.

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

While capture holds sources, do not start a terrain-timer pass. Existing executing operations
finish before the snapshot boundary. On resume, original deadlines remain due against the
current logical world time; capture does not reset them or add offline wall time. Do not
start a new pass just to erase backlog before a save. Pace resumed dispatch under R69.

At each normal pass start, capture T from authoritative logical world time and gather the
resident chunks whose timer queues have work due by T. Freeze that eligible-chunk list;
it is not a list of every overdue timer in the saved world. Consider each selected chunk
once, validate its current timer/terrain state when ready, and use the captured T throughout
that pass. Async dependency completion does not widen the cutoff or authorize stale timer
execution. A cancelled/replaced event must be re-evaluated rather than executed from a saved
pointer or copied observation. Preparation and publication follow the normal atomicity rules.

Preserve the existing finite `dirt -> packed dirt -> grass` chain: grass timing derives from
the dirt timer's original deadline, so an already-overdue follow-up can execute in the same
selected chunk's pass if due by T. Evaluate exposure and other conditions against current
authoritative terrain. This is lazy catch-up, not historical simulation of the period while
the chunk was unloaded. It does not add elapsed wall time while the game is closed.

Chunks loaded after list capture, including validation dependencies loaded by a transformation,
become candidates on the next normal pass, not recursively during the current one. Failed or
resource-deferred work remains pending under R39 and is not retried every tick merely because
its deadline is overdue. Completing a pass does not assert that all now-resident timers are
caught up. Do not run extra passes solely to reach a state with no overdue timers before saving.

For example, a pass at T=100 selects resident A with a deadline of 30. If processing A loads
B with a deadline of 40, B waits for a later pass. A's existing follow-up at 60 may complete
in this pass if valid; a follow-up at 120 may not. A snapshot after the pass includes A's
completed operations and B's still-pending deadline of 40. Such a snapshot is consistent:
world time records the clock, while timer metadata records outstanding work.

This is a persistence-v1 scheduling clarification. Global timer discovery, generalized event
chains, fairness, general catch-up limits, and an independent scheduler remain deferred.

### Large-File Format and Arithmetic

The initial format uses the following widths; no 4-GiB save-size preflight is required.

| Field | Serialized width |
| --- | --- |
| Chunk ID | u32, unchanged from the world layout |
| Absolute file offset, including chunk index and WAL positions | u64 |
| Declared base-file size; aggregate section/index/transaction byte length | u64 |
| Aggregate counts, including chunk-index entries, WAL records, and players | u64 |
| Bounded individual chunk-record, block-payload, and metadata-section byte lengths | u32 |
| Block type and literal RLE count | u8, unchanged |

Each on-disk chunk index entry is exactly 12 bytes: a u32 chunk ID followed by a u64
absolute offset from the beginning of the base file, with no native alignment padding.
Bounded per-chunk lengths do not limit the combined file size. Their totals must fit the
individual record framing; enforce codec-specific bounds before allocation. Other bounded
record fields retain explicitly specified widths when the exact section layouts are frozen.

The current world layout permits 2^32 distinct chunks. IDs fit u32, but their count needs
u64. Widen operands before computing dimension products, count * entry_size, or accumulated
output lengths. Use checked u64 arithmetic for file extents, WAL commit boundaries, read/
write cursors, and compaction accounting. Validate a range using offset <= file_size and
length <= file_size - offset (or an equivalent checked addition), including nested sections.
Do not increment a u32 chunk ID as a loop counter past its maximum value.

Keep file positions separate from in-buffer indices. Check conversions to usize and any
signed or narrower platform file-offset type; neither truncation nor floating-point size
accounting is valid. Stream payloads/checksums in bounded buffers, and check index/cache
allocation arithmetic and resource limits separately from on-disk sizes. Large-file support
does not require loading the entire file into memory. Report platform/filesystem limits and
I/O failures through the existing save/load failure paths without discarding durable files.

### Enum IDs and Reader Compatibility

Use explicit material enum values rather than relying on declaration order, and numeric u8
codec IDs as assigned below.
Keep air at 0 and custom-cell storage at 255. The current application also has a placement-only
adaptive-road material; existing behavior stores those cells as custom plus metadata, not as
the placement selector. Preserve that distinction in the encoder.

Each base/WAL file records the version it was written with. Engine constants define
`current_write_version` and `minimum_readable_version`. Accept only the supported inclusive
range, with actual decoding support for every accepted version. These are distinct from
snapshot sequences, world ticks, and generator versions. The minimum is an engine support
policy; a second per-file version field is not required for this initial design.

For example, adding a material in format 2 can leave the minimum at 1: the updated engine
reads versions 1 and 2 but writes version 2. An engine supporting only version 1 rejects
version 2 before interpreting any chunk bytes. An incompatible change in version 3 without
legacy decoding sets the minimum to 3. A version bump alone does not implement compatibility:
when layout/defaults change, retain the required old decoding logic or raise the minimum.

Initially perform no material-enum membership checks, either per raw cell or per RLE run.
Retain file/record checksums and structural bounds, and reject unsupported codec IDs at the
per-record dispatch point. Once version/integrity checks succeed and decoding yields exactly
32,768 bytes, reinterpret the owned buffer directly as `[32][32][32]BlockType` in x-fast order.
For standard RLE, expand material bytes and initialize omitted trailing air without first
converting each run's material to an enum. Validate custom metadata using byte-level custom
markers before publishing the typed chunk. Temporary decoding buffers do not change the
enum-based runtime representation.

Verify the assumed one-byte `BlockType` layout and array size at compile time, and preserve
required alignment and buffer ownership/lifetime. A cast must not leave the live chunk pointing
into recycled I/O scratch storage. The accepted trust assumption is that a compatible writer
emitted valid values and verified bytes retain them. Version/checksum checks do not logically
establish membership in the exhaustive enum. Invalid values from a writer bug, an incorrect
compatibility declaration, or a file with matching recomputed checksums can still produce
undefined behavior; safe handling of that case is explicitly not guaranteed in v1.

### Section Compatibility and Extensions

All serialized integers use little-endian encoding and explicit widths. Section layouts are
wire contracts, not native Zig structs: omit compiler padding and serialize each field in
the defined order. Each metadata section has this confirmed layout:

| Field, in order | Encoding |
|---|---|
| Section type | u16 |
| Section schema version | u16 |
| Section flags | u8 |
| Payload length, excluding header | u32 |
| Payload | Declared number of bytes |

The header is exactly 9 bytes. Flag bit 0 means required; other bits are reserved and
initially zero. Initial section schema versions are 1, with these stable type assignments:

| Section type | Meaning |
|---|---|
| 0 | Invalid/reserved |
| 1 | Custom-block records |
| 2 | Construction markers |
| 3 | Pending transformations |

All three initial section types are required to understand when present. Emit only nonempty
sections, once each, in ascending type order; reject duplicates or out-of-order sections.
An absent section denotes an empty collection. Custom records must still match custom cells
exactly, so their section cannot be absent when custom cells exist. The enclosing metadata
payload length determines the end; there is no terminator or section count. Payload schemas
and their derived byte limits are defined under Metadata Semantics and Size Bounds.

Each metadata section identifies its type and schema version, declares whether it is required
or optional, and gives its payload byte length. Parse known supported sections with their
declared schema and require exact payload consumption. Unknown types or unsupported schema
versions fail when required. Only sections explicitly defined as optional and safe to ignore
may be skipped; length framing alone is not permission to discard unknown state. A section's
schema defines whether absence is allowed and the resulting defaults; do not invent defaults
for missing required gameplay data.

Even skipped payloads remain within validated section/record bounds and enclosing checksum
coverage. Check their lengths before seeking/advancing. Optionality is a format compatibility
promise that gameplay remains valid without interpreting that extension; it is not a general
guarantee of lossless preservation of unknown data when rewriting saves. Custom-block types
are required semantic data and must be recognized; the material-enum trust policy does not
permit skipping unknown custom payloads or guessing their sizes.

The file-version gate runs before section interpretation. An older engine still rejects a
newer overall save version even if that file's new sections happen to be optional. An updated
engine may read supported older schemas or skip permitted optional extensions, but must never
apply a new interpretation to old bytes without explicit version-aware decoding. Incompatible
changes follow R49's minimum-readable-version policy.

### Initial Block Encoding

Use standard byte-pair RLE or raw bytes only, with numeric u8 codec IDs:

| Codec ID | Meaning |
|---|---|
| 0 | Raw: exactly 32,768 block bytes |
| 1 | Standard RLE: `(u8 material, u8 count)` pairs |
| 2-255 | Reserved; reject at per-record dispatch |

Flatten blocks in x-fast `[z][y][x]` order;
there are exactly 32,768 cells. Standard emits a material byte and a literal count in 1-255
for each run fragment. Adjacent fragments may have the same material when splitting a long
run. Zero is never a count/sentinel. The explicit payload length delimits the pairs.

Standard may omit trailing air; the decoder initializes the remainder to air. A zero-byte
standard payload denotes an all-air chunk, still an explicit override when indexed. Validate
that payload length is even and the sum of counts does not exceed 32,768; explicit cells plus
implicit trailing air must fill the chunk exactly. Raw requires all 32,768 material bytes,
including trailing air. Apply R49/R50's version and enum policy and validate custom-cell
metadata in both modes; no separate full-block material-ID scan is required.

Select standard if its encoded block payload is <=32,768 bytes; select raw otherwise. Codec
selection does not need a separate histogram pass or persistent per-chunk statistics. Encode
with bounded scratch storage, stopping the RLE attempt once committed output would exceed
the raw size. When omitting trailing air, defer a pending air run until a subsequent non-air
cell proves it is internal; omitted final air must not incorrectly trigger the raw fallback.
On fallback, use the original immutable block array for raw output. Metadata/framing/checksum
remain the same in either case; release snapshot ownership only after all required reads finish.

### Binary Container Layouts

The initial save-format version is 1, with engine current-write/minimum-readable versions
both initially 1. All integer fields are explicitly sized and little-endian; f32/f64 use
their IEEE-754 little-endian bit representation. Serialize fields individually without
native struct padding. UUIDs are fixed 16-byte sequences carried unchanged between records
and hash inputs, not text or platform-native UUID structs. Header sizes must match the
supported version's layout; a length alone does not authorize unknown fields or schemas.

#### Base file

The physical order is:

```text
Base header
World descriptor
Global state
Chunk index
Player records
Chunk records
Base physical checksum (32 bytes)
```

| Header field, in order | Encoding |
| --- | --- |
| Magic: `ZGWORLD\0` | 8 bytes |
| Save-format version | u32 |
| Header size | u32, initially 120 |
| Total file size, including checksum | u64 |
| World UUID | 16 bytes |
| Incorporated snapshot sequence | u64 |
| Incorporated snapshot digest | 32 bytes |
| World descriptor byte length | u32 |
| Global-state byte length | u32 |
| Chunk count | u64 |
| Player count | u64 |
| Player-record section byte length | u64 |
| Chunk-record section byte length | u64 |

The header is exactly 120 bytes. Section positions follow from these lengths and the
`chunk_count * 12` index length, using checked arithmetic; no separate section directory
is stored. The total must equal the actual file size, including the final 32-byte checksum.
Sections and records must consume their extents exactly, without overlaps, gaps, or trailing
unaccounted bytes. The index and base chunk records are sorted by chunk ID with no duplicates;
each index identity and absolute offset must select the matching complete chunk record.
Player records are sorted by player ID with no duplicates.

Compaction writes a seekable temporary file: reserve the index, stream records, and finalize
index offsets and header lengths before computing the base physical checksum. Initially use
a final bounded streaming read of finalized bytes for that checksum. This adds a read but
avoids retaining the whole base in memory. Source verification under R45 remains required;
hashing the output does not replace it. Validate/synchronize the finished candidate before
installation, and preserve the incorporated logical snapshot digest independently of this
new physical checksum.

#### Immutable world descriptor

| Field, in order | Encoding |
| --- | --- |
| Descriptor schema version | u16, initially 1 |
| Coordinate/chunk-ID layout version | u16, initially 1 |
| Chunk edge length | u16, initially 32 |
| World dimensions in chunks, X/Y/Z | [3]u32 |
| Topology flags | u8; bit 0 = wrap X, other bits initially zero |
| Generator ID | u16; 0 flat, 1 terrain |
| Generator implementation version | u32, initially 1 |
| Seed | u64 |
| Generator-settings byte length | u32 |
| Generator settings | Declared bytes |
| Logical ticks per second | u32, initially 60 |

The descriptor occupies 41 bytes plus settings. Layout version 1 defines the existing
centered coordinate convention and chunk-ID packing; reconstruct derived masks/shifts from
validated dimensions rather than serializing them. Reject unsupported layout, chunk size,
topology, tick rate, generator identity/version, or settings. In particular, a saved topology
must match what the running engine supports. Settings are immutable for the world's lifetime.
Do not substitute runtime defaults for saved values. Changes to generator behavior that
alter generated terrain require advancing the generator implementation version and retaining
compatible generation or an explicit migration under Q1.

Terrain generator version 1 settings are exactly 39 bytes, in this order:

| Field | Encoding |
| --- | --- |
| noise_scale | f64 |
| octaves | u8 |
| lacunarity | f64 |
| persistence | f64 |
| base_height_present | u8; 0 automatic, 1 explicit |
| base_height | u32; zero when automatic |
| height_amplitude | f64 |
| dirt_depth | u8 |

Preserve the automatic-height choice rather than substituting today's explicit default.
Validate settings with the supported generator's parameter/layout rules. Flat generation
uses seed zero and an empty settings payload. Terrain descriptors therefore occupy 80 bytes,
and flat descriptors 41 bytes, for these initial schemas.

#### Global and player records

Global schema 1 contains `u16 schema_version = 1` followed by `u64 world_tick`, exactly
10 bytes. Future persistent globals require an explicit schema/format change. Resume this
tick without adding offline time; the tick rate is in the immutable descriptor.

Each player record has this layout:

| Field, in order | Encoding |
| --- | --- |
| Total player-record size, including its size field | u32 |
| Player schema version | u16, initially 1 |
| Player ID | u64 |
| Feet position, X/Y/Z | [3]f64 |
| Yaw and pitch, radians | [2]f32 |
| Inventory schema version | u16 |
| Inventory payload length | u32 |
| Inventory payload | Declared bytes |

Empty-inventory records occupy 52 bytes. Initially inventory schema and length are both
zero; inventory contents await a future supported schema. Reject unsupported schemas and
nonfinite coordinates/angles. Restore feet position/view under R17's motion-reset and
authoritative collision-validation rules. The record has no individual checksum: its
container's physical checksum or transaction digest covers it.

Persist all known players, including offline players, sorted by unique player ID. The
future 16-player concurrency limit is not a limit on historical records. Each WAL transaction
contains complete global state and the complete player array, plus only changed chunks.
Player eligibility still follows R42; client/session command dependency watermarks are
resolved before capture and are not serialized as persistent session counters. Validate
record counts and exact section consumption before publishing recovered state.

#### WAL segment and transaction framing

Each segment begins with this immutable header:

| Field, in order | Encoding |
| --- | --- |
| Magic: `ZGWAL\0\0\0` | 8 bytes |
| Save-format version | u32 |
| Header size | u32, initially 120 |
| World UUID | 16 bytes |
| Segment UUID | 16 bytes |
| Predecessor snapshot sequence | u64 |
| Predecessor snapshot digest | 32 bytes |
| Header checksum | 32 bytes |

The header is exactly 120 bytes. Generate a new unique segment UUID at rotation. There is
no mutable total-WAL-size field. The predecessor is the committed snapshot immediately
before this segment; its first transaction must name that predecessor, and each subsequent
transaction must name the preceding commit. Recovery follows validated links rather than
filenames, modification times, or numerical adjacency of attempted snapshot sequences.
Verify the header checksum even when no transactions follow. Establish and synchronize the
header and directory entry under the existing creation/rotation durability contract.

Each transaction consists of header, complete global state, complete player array, changed
chunk records, and commit footer. The transaction header is exactly 84 bytes:

| Field, in order | Encoding |
| --- | --- |
| Begin marker: `ZGTXBEG1` | 8 bytes |
| Snapshot sequence | u64 |
| Previous committed sequence | u64 |
| Previous committed digest | 32 bytes |
| Global-state byte length | u32 |
| Player count | u64 |
| Player-record section byte length | u64 |
| Changed-chunk count | u64 |

The commit footer is exactly 56 bytes:

| Field, in order | Encoding |
| --- | --- |
| Commit marker: `ZGTXEND1` | 8 bytes |
| Total transaction size, including header and footer | u64 |
| Snapshot sequence, repeated | u64 |
| Transaction digest | 32 bytes |

The changed-chunk count is known at capture, while compressed sizes become known during
encoding. Put the total transaction size only in the footer, allowing streaming without
WAL backpatching or retaining all encoded chunks. Release snapshot references under R29.
Parse the declared global/player sections and exactly the declared number of length-framed
chunk records before expecting a footer; never search payload bytes for magic markers.
Reject duplicate chunk IDs within a transaction. Chunk records use the identical base/WAL
representation already defined; WAL chunk ordering need not match the sorted base order.

The footer's size must equal bytes consumed from the transaction start through its digest,
and its repeated sequence must match the header. Validate all framing, predecessor links,
checksums, and payload semantics before accepting a recoverable snapshot. A marker alone
does not establish a commit. Writer success still requires synchronization before
acknowledgment; partial writes and failure repair remain governed by R23/R30/R55.

### Snapshot Integrity

Use these literal ASCII checksum-domain prefixes, each including exactly one trailing zero
byte (`\0` below denotes that byte, not two printable characters):

| Checksum purpose | Domain prefix |
|---|---|
| Chunk record | `ZGW-CHUNK-1\0` |
| WAL segment header | `ZGW-WALHDR-1\0` |
| WAL transaction | `ZGW-WALTX-1\0` |
| Snapshot-zero anchor | `ZGW-INIT-1\0` |
| Base physical checksum | `ZGW-BASE-1\0` |

Prefixes are hash inputs, not repeated serialized record fields. The suffix `1` versions
the hashing contract, independently of the overall save-format version; adding a material
does not itself change these prefixes. Use BLAKE3-256 for all five checksum purposes; the
algorithm is a format contract, not a runtime setting. Exact coverage, with `||` meaning
byte concatenation, is:

| Digest | BLAKE3-256 input |
| --- | --- |
| Chunk | Chunk domain prefix `||` world UUID `||` record bytes preceding its checksum |
| WAL header | WAL-header domain prefix `||` header bytes preceding its checksum (88 bytes initially) |
| WAL transaction | Transaction domain prefix `||` complete validated WAL header (120 bytes initially, including its checksum) `||` transaction bytes preceding its digest |
| Base physical | Base domain prefix `||` every base-file byte preceding its final 32-byte checksum |
| Snapshot-zero anchor | Initial-anchor domain prefix `||` canonical initial fields listed below |

Transaction coverage includes its header, global state, full player records, chunk records
with their checksums, and the commit footer's marker, total length, and repeated sequence.
Only its final digest is excluded. The included segment header binds world, segment, format,
and segment predecessor; the transaction header binds the immediately previous committed
sequence/digest. Verify the segment header independently before using it in this input.
The base physical checksum includes the finalized header, incorporated logical digest,
descriptor, global state, index, and all player/chunk records with their record checksums.

Use one chained digest per committed snapshot transaction. Validate footer identity/length
as well as the digest. Append hashing processes the fixed segment header and new transaction
bytes, without rereading prior transactions; recovery verifies each retained transaction.
The chain proves a valid linked prefix; stored predecessor digests cannot replace validation
of earlier payloads. Base compaction preserves the incorporated logical snapshot digest as
the chain anchor, while a separate physical checksum protects the rewritten base contents.

The snapshot-zero anchor hashes the following concatenation in order, with all integer
fields encoded little-endian and all variable contents using the confirmed record schemas:

```text
ZGW-INIT-1\0 (including its trailing zero byte)
World UUID (16 bytes)
Save-format version (u32)
Snapshot sequence (u64 = 0)
World descriptor length (u32), followed by descriptor bytes
Global-state length (u32), followed by global-state bytes
Player count (u64)
Player-section length (u64), followed by player records sorted by player ID
Initial override count (u64), followed by chunk records sorted by chunk ID
```

The domain is included once. Counts, record lengths, and canonical ordering make the input
unambiguous. Initial chunks retain their independent checksums, which do not depend on this
anchor. Exclude physical offsets/index, base total size, the anchor field itself, and the
base physical checksum to avoid self-reference and physical-placement dependencies. An
untouched generated world has zero initial overrides. Store the resulting digest in the
snapshot-zero base and reference it from the first WAL segment; install both with the
existing synchronization protocol before acknowledging journal snapshots.

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

The initial chunk-record checksum layout is confirmed: a 32-byte BLAKE3-256 footer inside
the length-framed chunk record, using the same record representation in base and WAL.
The exact hash input is `domain_prefix || world_uuid || record_bytes_before_checksum`.
Use `ZGW-CHUNK-1\0` including its trailing zero and the fixed 16-byte world UUID representation
from the validated container, never a textual UUID or native struct representation. Include
all record lengths; exclude the checksum itself. The record layout is:

| Field, in order | Encoding |
|---|---|
| Total record size, including checksum | u32 |
| Chunk ID | u32 |
| Persistent chunk revision | u64 |
| Persistent flags | u8 |
| Block codec | u8 |
| Block payload length | u32 |
| Block payload | Declared number of bytes |
| Metadata payload length | u32 |
| Metadata sections | Declared number of bytes |
| Chunk checksum | 32-byte BLAKE3-256 |

Fixed overhead is exactly 58 bytes, with no padding. Persistent flag bit 0 stores historical
`is_unreachable`; remaining bits are reserved and initially zero. Base and WAL use identical
records. Index entries remain `(u32 ChunkId, u64 offset)`, exactly 12 bytes, and are not part
of the chunk hash input. The container supplies world identity; offsets and segment/snapshot
identities are excluded so compatible records can retain their checksum when copied.
Source checksum verification remains required during copying.

A footer permits streaming without backpatching the checksum. Preserve this algorithm and
layout as part of the format-version contract, not a runtime setting. Hash-cost measurements and
alternative algorithms are follow-up improvements, not prerequisites for this initial choice.

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

The user permits an exceptional visible pause of world-changing actions to complete an
overdue save. The confirmed R75 coordinator watchdog checks normal capture/player-wait
limits and elapsed unsaved age, selecting the earliest actionable deadline for the current
mode. Track monotonic age while dirty work exists: use time since the latest durable save,
or the first subsequent dirty transition if the world was clean in between. Retrying, partial writes, encoding, and source release do not
reset it. Numeric thresholds are selected under R66, not fixed by this document.

On escalation, keep a viable active capture instead of aborting it merely to change modes.
If cancellation is already accepted, finish its handoff/required repair before a fresh
attempt; do not revive a cancelled transaction. Gate new world-changing work between
complete operations, preserving queued requests and any commands required by the chosen
save/checkpoint boundary. Loading/read dispatch, completions, rendering, camera, and UI stay
active; disk-dependent requests may still await I/O. If the overdue attempt has already
released all sources and is only writing/synchronizing, do not introduce a new mutation pause.
Show a stable status such as "Saving: world changes temporarily paused". Bound admitted work
and client predictions; refuse/backpressure new submissions before capacity is exhausted.
Do not turn a retained pending request into a terminal rejection or silently replay it.

Keep encoding/streaming within the same bounded workspace and prioritize pending players'
sources. A full output queue waits for writer progress instead of repeatedly cancelling on
the normal timeout. An actual inability to reserve the minimum record/manifest/completion
workspace is still a reported resource failure, not permission to exceed the budget. Do
not require the entire encoded capture to fit in RAM or split a consistent snapshot into
independently committed subsets. Prioritization changes neither the boundary nor the format.

Clear the capture-related mutation pause when all sources are safely released, even if the
WAL write/synchronization is still running. Save priority and unsaved-age tracking continue
until successful durability; they are not reasons to keep source ownership or pause gameplay
afterward. Independent pressure gates may still apply. Resume with existing revalidation,
ordering and paced catch-up. Storage errors release sources safely and follow R23 repair;
failed repair suspends appends rather than cycling captures. Indefinitely stalled storage
has no completion guarantee: keep status and the existing explicit exit choices usable.
Automatic escalation is not permission to fake success, drop work, or ignore accepted
cancellation/commit boundaries. Final shutdown saving follows the same exemption from normal
gameplay timeouts, with its existing wait/cancel-exit/quit choices.

### Player Pending State, Retries, and Resource Failure

Capture contention is an ordinary pending state. Retain the request and optimistic effect;
promote its required frozen write sources and retry admission on meaningful release progress.
In normal mode the elapsed player-wait limit initiates safe capture cancellation, not a
terminal rejection or a speculative second application. R73 save priority instead permits
longer visible waiting with bounded backpressure; it does not reset request wait timestamps.
For multi-chunk writes, prioritize the complete blocked set. Revalidate after release and
preserve required command order. No fixed number of retries
can cover an arbitrarily long capture. Normal cancellation supplies an escape path; overdue
saving explicitly trades action latency for completion. Rendering/input and service
completions remain responsive while the request waits.

If preparation then genuinely lacks allocation capacity, keep the prior failure policy: one
automatic retry after a useful ownership handoff, otherwise `resource_exhausted`, no partial
effects, optimistic reconciliation, and concise status. Do not replay a terminal rejected
request later. With no releasable capture retention, reject directly. Cancellation does not
free live-world memory merely because it removes a pin; only eligible allocations/output can
actually be reclaimed. Already applied requests are not retried.

The current client reconciles terminal failures, but is not already a general retry protocol.
Its acknowledgment path removes both successful and failed requests. Keep capture-pending
primarily inside the service in v1: defer the terminal response during a brief wait, leaving
that same optimistic operation outstanding. No new per-request pending message is required.
For longer delays, coalesce advisory status rather than notifying on each wait/retry; keep
required exceptional-saving and failure status visible. Any nonterminal status must bypass
terminal acknowledgment handling and cannot retire predictions or resolve command prefixes.
Neither service progress nor client correctness depends on receiving a pending notification.
Model stable `(session, request)` identities and a resolved command prefix now; wire encoding,
reconnect handling, and a persisted deduplication ledger remain future networking work.
The future wire contract must distinguish:

| Outcome | Meaning for client and authority |
| --- | --- |
| Pending/admitted | The same request remains outstanding; keep prediction and checkpoint dependency. |
| Applied | Effects published once; this does not itself mean WAL-durable. |
| Terminal rejected | No effects from this operation; remove/reconcile prediction and resolve the prefix. |
| Not admitted/busy | Authority retained no executable request; explicit resubmission/status rules are needed. |
| Unknown after timeout/disconnect | Query or resend the same identity within a supported session; never assume failure or mint a new identity blindly. |

Retry-after hints and in-process wakeups are advisory. Recheck readiness when acting, include
capture generations to prevent missed/stale wakeups, and provide bounded backoff when a signal
is lost. Bound both server waiting state and client predictions; backpressure/reject before
admission when capacity is unavailable. A future bounded deduplication cache cannot silently
forget an ID while its session may still retransmit it; expiry needs an explicit stale-session
outcome/resynchronization contract. Do not promise exactly-once execution across crashes with
unpersisted request IDs.

Simulation retains compact pending progress or existing events, pauses dispatch, and catches
up gradually after release. It must not emit a request per skipped tick. Diagnostic reasons
separate capture contention, configured-budget exhaustion, allocator failure, and invalid data.
Reserve completion/status capacity before admission. No policy promises recovery from arbitrary
process-wide OOM. Player-visible frame time, confirmation lag, and corrections are distinct
metrics: an optimistic view can conceal a short wait but cannot prove prolonged delays invisible.

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

### Metadata Semantics and Size Bounds

The initial independent section limits are:

| Section | Entry limit | Identity/correspondence rule |
| --- | --- | --- |
| Construction markers | 32,768 per chunk | Unique cell index in 0-32,767 |
| Pending transformations | 32,768 per chunk | Unique cell index in 0-32,767, irrespective of event kind |
| Custom-block records | Number of custom cells, at most 32,768 | One record per byte-255 cell in x-fast block order |

Uniqueness is local to a section. A construction marker and a timer for the same cell are
valid together; do not impose a shared 32,768-entry limit across all sections. Multiple
timer records for one cell are invalid; rescheduling replaces the prior pending event
under the existing gameplay semantics. Custom record association follows block order,
rather than requiring a second stored cell-index list. Validate the schema of each custom
type and reject missing, extra, truncated, or unsupported records.

Schema version 1 uses these payload records, in the stated field order, little-endian and
without padding:

| Section | Entry fields | Serialized entry size |
| --- | --- | --- |
| Construction markers | Cell index u16 | 2 bytes |
| Pending transformations | Cell index u16, transformation kind u8, deadline tick u64 | 11 bytes |
| Custom blocks: unformed adaptive road | Custom type u8, road state u8 | 2 bytes |
| Custom blocks: formed adaptive road | Custom type u8, road state u8, high endpoint [3]u32, downhill direction u8, formation length u32, section index u32 | 23 bytes |

Construction and timer payloads contain no additional entry count: divide the section length
by 2 or 11 respectively, rejecting a remainder or count above 32,768 before allocation.
Cell indices use x-fast order and must be below 32,768 despite their u16 storage width.
Transformation kinds are explicitly 0 compact_dirt and 1 grow_grass; reject unknown kinds.

Custom type 0 denotes an adaptive road. Road state 0 is unformed/adaptive and has no further
fields; state 1 is a formed slope and has the remaining 21 bytes listed above. Reject unknown
types/states. Direction IDs are 0 positive_x, 1 negative_x, 2 positive_y, 3 negative_y;
reject other values. The high endpoint uses world block coordinates in x/y/z order and must
fit the saved world layout. A formed length must be positive and the section index must be
less than that length. Retain the formation ownership fields for correct later edits; derive
heights from length and section as in the current road model, without storing floats. Custom
cell indices remain implicit in block order. Parse exactly the expected number of custom
records and consume the section exactly, rejecting truncation or extra bytes.

The initial serialized bounds are:

| Section | Maximum entries | Maximum payload | Including its 9-byte header |
| --- | ---: | ---: | ---: |
| Construction markers | 32,768 | 65,536 bytes | 65,545 bytes |
| Pending transformations | 32,768 | 360,448 bytes | 360,457 bytes |
| Custom blocks (all formed roads) | 32,768 | 753,664 bytes | 753,673 bytes |

The conservative combined bound is `32,768 * (2 + 11 + 23) + 3 * 9 = 1,179,675` bytes,
about 1.125 MiB. It allows every section to reach its independent limit and does not assert
that every such combination is valid gameplay state. All existing semantic checks remain
required. Empty collections omit their sections, so entirely empty metadata is zero bytes.
These caps concern serialized data, not native array capacity or expected chunk usage;
never preallocate the maximum solely because it is permitted. For reference, the maximum
initial chunk-record bound is `58 + 32,768 + 1,179,675 = 1,212,501` bytes.

Use checked arithmetic and retain the u32 local-length/record framing constraints. Native
struct padding and allocated capacities do not determine serialized size. Validate
declared lengths/counts before allocating and require exact section consumption. Derive
version-specific byte bounds again when custom types or section schemas change; these
initial caps must not accidentally reject future supported schemas or optional extensions.

Existing allocators serve valid metadata within the allocation budget; allocation strategy
and budget do not change semantic limits. The trusted material-enum policy in R50 does not
waive these metadata structural checks.

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

For initial sweeps, try additional capture-working-memory budgets of 16, 32, and 64 MiB, and
streaming buffers of 64, 256, and 1,024 KiB. These are experiment inputs, not shipping
defaults, guarantees, or upfront allocation requirements. Account for buffers within the
appropriate persistence working-memory budget, including per-record staging above normal
stream-buffer size; report capture-pinned live capacity separately without double-counting it;
varying one knob does not exempt other allocations from accounting. Existing live-world
memory and the future whole-system controller remain separate from this experiment.

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

Measure frame time and authoritative-operation latency, with p95, p99, and observed maxima
as well as typical values. Separately record capture bookkeeping, source hold time, player
confirmation delay, global/near-player simulation pause, catch-up debt/CPU, encoding time,
worker CPU, copied bytes by cause, allocation counts, allocated capacity, queue occupancy, retained capacity, save
cancellations, retry frequency, cancellation request-to-handoff latency, successful save
age/rate, and time/actions deferred in save-priority mode. Separate queue
waiting from execution and gate/preparation from existing client copies. For a later COW
experiment, report its detach/copy/retention costs separately and measure saving-inactive
overhead with the policy enabled but unused. Measure eager encoding with metadata and
multiple write dependencies, not only a hot 32 KiB memcpy-versus-RLE loop.
Do not use averages alone to judge pauses. Record hardware/build configuration, workload,
settings, and run duration so results and regressions can be reproduced.

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
Keep normally loaded timer-bearing chunks pinned for the initial design; do not preload
them solely because a saved timer exists. Restore original timer queues on ordinary load
and use existing due-event handling. Preload persisted construction and road dependencies
before an edit rather than silently ignoring nonresident metadata. Persistence-only reads
for integrity checking/recovery/compaction do not register gameplay chunks or timers.

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
- Evaluate buffering a complete encoded capture before disk writes against bounded streaming.
  R74 makes this plausible for ordinary saves: 2,000-4,000 raw block payloads use 62.5-125 MiB
  before metadata. Experimental 64/128/256 MiB output budgets are hypotheses, not defaults
  or reservations. Metadata-heavy records and accumulated dirty state can exceed them;
  1-2 KiB average encoded chunks are not a bound. Any adopted policy needs a reviewed bounded
  overflow path and the same consistent boundary. Do not add a second capture pipeline to v1
  merely for this experiment. Extracting format tables remains a review proposal, not an
  adopted requirement change.
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
- An independent scheduler could retain just transformation deadlines and arrange loading
  before execution, permitting eviction of timer-bearing block data. Preserve logical-time
  deadlines and define how late I/O affects execution before adopting it. The initial
  implementation keeps already-loaded chunks with pending terrain transformations resident
  and does not preload unfinished timers at startup. Revisit activation, loading, and timer
  semantics together when additional kinds of scheduled events are introduced.

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
during implementation planning. None authorize starting implementation in this planning conversation.

- [ ] T1: Translate the agreed contracts into module boundaries, ownership/message APIs,
  operation-specific reservation paths, and storage/fault-injection interfaces. Specify the
  restricted snapshot view and existing block/all-air allocation lifetimes; assign explicit
  material constants under R49. Use R66 for measured parameters; preserve the agreed binary
  layouts and failure policies.
- [ ] T2: Implement the agreed container, descriptor, chunk/global/player codecs, and
  checksum coverage with strict validation, byte-layout fixtures, and round-trip tests.
- [ ] T3: Implement framed journal commits, indexes, storage synchronization, and recovery.
  Implement the macOS/APFS storage adapter and R63-R65 barrier order, with explicit failures
  for unsupported primitives and native filesystem tests alongside the fault-injected model.
  Establish snapshot zero and the first segment durably, with distinct create/open paths
  and crash tests covering initialization before the first periodic compaction.
- [ ] T4: Integrate service snapshot boundaries, frozen-source admission, bounded capture output, dirty
  acknowledgments, generation-safe base loading, and base-backed eviction/dependency pins.
  Preserve the current `WorldChunk` layout and construct restricted views with copied
  identity/history/descriptors and pinned const block/metadata buffers. Exclude live headers,
  packed flags, and caches from encoder access; preserve cache consistency across edits,
  failed preparation, loading, and gameplay/client copies.
  Add budget accounting/reservations to existing block/metadata allocation paths and
  fallible metadata operations with partial-allocation cleanup; defer custom pools. Expose
  configurable local limits, capacity counters, and resource-failure/status hooks for later RAM budgeting.
  Reuse validation/discovery results and bounded operation scratch storage; preserve in-place
  mutation for exclusive prepared chunks and use private staging only where necessary.
  Track dependency-wait/ready/terminal stages and preserve command order across async loads.
  Define timer passes with a fixed tick/resident due-chunk list, preserve finite local
  catch-up, and save overdue/deferred timer state without recursive catch-up passes.
- [ ] T5: Implement segment rotation and streaming background compaction with source checksum/
  lineage verification and safe publication; inject source corruption during consumed reads.
- [ ] T6: Integrate load/save lifecycle, autosave/final-save, player restore, and save status.
  Integrate capture-pending player state, priority encoding, normal elapsed-wait cancellation,
  R73 overdue-save escalation and visible exceptional pause, the R75 coordinator watchdog,
  genuine resource retry/rejection and optimistic reconciliation; global simulation capture gating,
  paced resume, deferral/backpressure; and pre-reserved completion/status reporting.
  Gate player checkpoints/save barriers on resolved command prefixes and drain outstanding
  dependency I/O before final capture.
  Add the single shutdown phase/error dialog, bounded dependency-read retry, delayed-status
  choices, safe cancel-exit handling, and explicit unsaved-exit path under R60-R62.
- [ ] T8: Add stable exclusive world ownership before recovery through final shutdown.
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
  Keep replayable seeds/traces and explicit critical-boundary cases in the regular CPU test suite.
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
  Verify pressure behavior with tiny configured budgets/fault injection, not physical OOM.
- [ ] T-val: Run acceptance criteria verification, crash/failure injection, relevant CPU
  regression tests, and application builds; document durability/performance limits.
