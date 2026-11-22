# World persistence

The voxel application saves world overrides and player checkpoints using the v1 [feature contract](../specs/features/world-persistence.md) and [binary format](../specs/formats/world-persistence-v1.md). The demo application has no persistent world.

## Select a world

```sh
zig build run_voxel -- --create-world saves/my-world
zig build run_voxel -- --world saves/my-world
zig build run_voxel -- --world saves/my-world --player-id 2
zig build run_voxel -- --ephemeral
```

Opening never implicitly creates or replaces a world. Without arguments, the app opens `saves/default`; create it explicitly first. Paths are relative to the launch directory, before asset startup changes the working directory. Creation creates missing parent directories and refuses an existing save or orphaned persistence artifacts. Existing parent-directory aliases such as macOS `/tmp` work normally; the world directory itself cannot be a symlink. Creation succeeds only after the new directory entries and initial base pass their required durability barriers. A failure can leave empty directories or recovery evidence, which creation preserves. `--ephemeral` deliberately keeps changes only in memory. Player identity is a local u64 (default 1); networking, authentication, and Steam identity are deferred.

Opening takes exclusive ownership through `world.lock`, validates and recovers storage, and uses the saved world dimensions/generator settings. Invalid or incompatible saves report an error with the selected path. Do not delete or edit journals to work around an error: they may contain the only recoverable version. Back up a world while its owning process is closed.

## Save compatibility

### Development and release policy

The game has not had its first release. Until then, do not spend development effort
implementing or maintaining backward compatibility or save migrations between development
builds. Incompatible development saves may be rejected, and starting a new world is
acceptable. Existing support for older encodings describes current behavior, not a commitment
to preserve that support through further development.

After the first release, aim to minimize changes to gameplay logic. Save migrations may be
needed between released game versions; their policy, supported transitions, and implementation
will be discussed and designed separately. That future migration scope covers released game
versions only, not intermediate development builds, including builds between releases.

### Current version gates

The game runs one current gameplay/construction logic. It does not select historical rules
from a world or blueprint. Compatibility with older file encodings is separate: the current
implementation reads and writes format 9. Formats 1–8 are incompatible development
saves and are rejected as whole worlds. The base and WAL readers enforce the supported inclusive
range through `minimum_readable_version` and `current_write_version`.

Under the current pre-release policy, a sufficiently incompatible gameplay or data
interpretation change advances the write version and raises the minimum readable version to
exclude incompatible older worlds. Raising only the write version would leave those old
saves readable. This applies even when the byte layout has not changed, and covers terrain,
saved blueprint libraries, and unfinished construction sites together. Generator
identity/version guards likewise reject unsupported algorithms. All accepted saves use the
current game logic.

Version 9 adds extraction zone bounds, resource filters, occupied cells, road slopes, and
soil deadlines to the coherent terrain/construction/player snapshot. Zone bounds keep
empty cells protected after reload. Version 8 added simulation-owned warehouses and
accepted delivery cargo. Pallet material has explicit ID 23. Version 7 introduced
construction lifecycle, target-chunk ownership transfers, and pending
post-completion grass initialization. Bare and grassy soil share support rules; legacy
packed-soil value 7 and compaction events are rejected.
Platform-only direct stone foundations and portable blueprint certification remain.

## External command sessions

[Warehouse Q23](../specs/features/warehouses.md#q23--command-identity-and-retry-lifetime)
selects duplicate recognition within a live server/world and client session, without requiring
save records for every user command's response. Restart/reload uses fresh sessions and an
authoritative state refresh; uncertain old requests are not automatically replayed as new
commands. A command may be present in the saved state even if its reply was not received.
This preserves the shared coherent save boundary and does not relax persistent delivery/task
recovery. Construction establishes this boundary for external Save/Apply and block operations;
warehouses use the same boundary for registration, stock transfers, configuration and lifecycle.
The service retains at most `pending_commands`
unacknowledged records globally, under a separate 32 MiB command-storage budget. In-process
result collection acknowledges receipt; a future wire adapter uses explicit acknowledgment.
An acknowledged sequence stays below the endpoint's retirement frontier and cannot execute
again. Warehouse results retain their evaluated stock/inventory cut with a resolved command
prefix; client reconciliation uses that fence so a late result cannot overwrite newer state.
Terrain operation retries retain scalar outcomes and immutable IDs. Automatic simulation operations use their own lifecycle and bypass
the external-command ledger.

## Saving and exit

The [construction ownership implementation](../specs/features/construction-state-ownership.md)
moves canonical active-target progress into simulation, with immutable definitions, lifecycle,
and per-target-chunk transfer state in the shared coherent save boundary. Admission/handback
capture matching discovery, resources, and terrain. A fully filled but materializing site
remains saved; recovery resumes untransferred portions without repeating accepted effects.
World-data grass timers and unfinished post-completion initialization share that capture, retaining
completion-based deadlines without duplicate scheduling or resets after restart.
No ownership-marker blocks or independently committed simulation saves are used. Transferred
soil carries a non-executable `initialize_grass` marker whose token identifies the construction;
a later ordinary replacement cancels it. Deferred initialization only converts matching markers,
so an older obligation cannot replace a newer exposure deadline, including after restart.

Autosave attempts run every 60 seconds and compaction is requested every 10 minutes. Only a durable WAL commit establishes saved progress; the interval is not a maximum loss window. Base compaction allows exact-version dirty chunks to unload and retires covered journals after durable installation.

Saved blueprints belong to the selected world's player identity. Immutable definitions are
shared by active construction instances and retained while referenced. Definitions, instance
creation, and individual target completions enter the same WAL transaction as changed real
blocks and player inventory. A fulfillment record occupies 13 bytes; ordinary saves do not
rewrite the definition or fulfillment bitmap for every placed target. Checkpoints encode
the full library, remaining progress, lifecycle and accepted portions, then rebuild derived
runtime indexes after load. Transfer and site-completion records each occupy 21 bytes; a
grass-initialization retirement occupies 13 bytes. Restore verifies transferred revisions
against saved terrain before making the composed world available.
Temporary capture selections, helper jobs, diagnostics, and unconfirmed names have no save
representation. In-memory library acceptance is distinct from a durable save acknowledgment;
storage failures leave accepted state dirty for retry. Ephemeral worlds remain session-only.
Library capacity and exhausted IDs reject a new definition with a terminal resource result.
When the uncommitted journal fills, the service retains the submitted definition, saves
the already accepted prefix, and retries publication after that writer finishes. Ephemeral
worlds allocate no persistence journal.

Every durable capture saves the complete set of unfinished world-work obligations with
terrain, blueprint progress, inventory, and global state. The initial kind is road-shape
reconciliation, keyed by chunk; the queue deduplicates at most 4,096 keys. This replaces
the former requirement to drain every adaptive-road update before ordinary/autosave,
overdue, final, or internal journal-prefix capture. Saving no longer holds later mutations
solely to finish the road queue. Selected command prefixes and normal source holds remain.

A fill reserves its road-work marks before committing material, inventory, and progress.
A completed pass clears its key only when no coalesced repeat remains. Marks and clears
are captured with the corresponding world state, and membership-only changes remain dirty
until their captured generation is committed. Each save owns one canonical full key set;
newer changes remain unsaved after an older writer completes.

Saved road shapes and ownership remain chunk metadata. Runtime cursors, revision
observations, and repeat flags are discarded on restart. The service restores fresh queue
entries directly from saved keys before it is ready, then reconciles current world state
without a whole-world scan or preload. Repeated work preserves valid ownership and current
edits. Processing keeps the 16-work-unit budget, counting seeds and completion/requeue,
with fair repeat passes and immediate yield on dependency, source-hold, or error waits.
See [unfinished world work](../specs/features/deferred-world-work.md).

Warehouse capture freezes one complete compact record set only when the warehouse domain
has changed since its last durable capture. The set includes registration IDs/lifetimes,
geometry, material, enabled/active configuration, stock, incoming capacity promises, obligations,
accepted cargo and task completion highwaters. An unchanged domain writes an eight-byte
retention marker. Its full snapshot shares the terrain, construction, player and global WAL
footer; there is no disk synchronization per transfer or delivery item. Manual transfers commit
stock and the authoritative player slot together. Automatic work uses bounded local batches
on the same service executor, with coherent individual outcomes and ordinary batched publication.

Each warehouse mutation preflights its generation before changing resources. Capture records
that generation; only its durable commit acknowledges it. Later mutations remain dirty when
an older writer finishes, and preparation/write failure leaves the changed generation dirty.
Capture admits the encoded snapshot and conservative validation/replacement memory before
allocating it. Defaults bound records to 4,096 warehouses, 4,096 retained delivery tasks and
2 MiB encoded bytes; these limits are separate from terrain manifests and native state.

Recovery renews the world session, validates linear warehouse/delivery accounting, rebuilds
derived layouts and spatial claims, and checks actual member pallets, the whole reserved
envelope and real support. Support reads compose simulation-owned construction targets with
terrain, including partially materialized sites. Conflicting targets, missing members/support,
obstructions or inconsistent cargo/promises fail before the service starts. Runtime claims,
client subscriptions, visual pallet sources, command responses and GPU caches are derived.
An accepted delivery retains cargo and its reserved capacity across restart; repeated handover
cannot duplicate stock. No full scheduler, workforce-food system or offline simulation is added.

Simulation and block timers pause while snapshot sources are held. The encoder releases sources as independent records become available, allowing gameplay to resume before disk synchronization. Warehouse-only local transitions can continue against their frozen byte snapshot. Conflicting player edits remain pending. Ordinary waits can cancel capture safely; saving that falls sufficiently behind can prioritize completion with visible status. UI/rendering continue, but world-changing actions may wait. Actual disk errors cannot be solved by prioritization; unsaved state stays dirty for retry.

Closing the window or choosing Exit from the Escape menu stops producers and drains existing edits before publishing the final player checkpoint and save. The final capture is exempt from ordinary gameplay wait deadlines. After a failure or five seconds without meaningful progress, the dialog provides retry/wait, cancel exit, or explicit quit without saving. Quitting without saving may lose changes since the last durable snapshot. A durable WAL remains recoverable if final compaction fails.

The exit drain includes submitted blueprint applications while their detached admission is
pending, and preserves their order with later mutations. A failed application resolves its
command fence without publishing an instance.

Saved player state includes identity, feet position, yaw, pitch, and the material in the one-slot inventory. Inventory changes belong to authoritative transfers, including coherent construction fulfillment across the world-data inventory and simulation target owners, and are captured in the same snapshot. Movement checkpoints preserve the service-owned inventory. Velocity, climbing state, partial interaction holds, pending client predictions, and transient movement history are reset on startup. Format 5 uses inventory schema 1. Restored collision is checked against authoritative terrain before gameplay starts.

## Storage and ownership

`format.zig` owns explicit versioned little-endian records and checksum domains. `storage.zig` implements framed WAL transactions, startup verification/recovery, indexed base reads, and compaction. `io.zig` provides stable exclusive locking and checked positional I/O with macOS `F_FULLFSYNC` and directory synchronization. `io_model.zig` models separate content and namespace durability for crash tests. `coordinator.zig` connects restricted source views to bounded encoded output; the service alone mutates live chunks.

`blueprints.zig` owns bounded definition/instance wire records and transaction preflight.
It prepares allocations and validates progress changes before commit authorization, then
publishes them after the same durable footer as terrain/inventory. The loader checks
definition dimensions/materials, ownership/references, progress bits/counts, box overlap,
and stable-ID highwaters. The authority must also verify restored fulfilled and pending
targets against real generated/overridden terrain before exposing rebuilt instances.
Capture computes the exact encoded journal size before its working-memory check, then
allocates that buffer once. A successful durable commit retires only its captured operation
prefix; changes accepted while it was writing remain dirty for the next transaction.

`warehouses.zig` owns the canonical warehouse/delivery codec and its count-based memory
preflight. Store owns the last committed encoded image; an active capture owns a separate
immutable image and the writer prepares its replacement before commit authorization. The
base stores the complete image; WAL uses either a replacement image or the retention marker.
Compaction freezes its own generation while later commits can update the live Store image.

`save_lifecycle.zig` owns save policy on the service thread: the active attempt, a queued drain's command fence and retry allowance, cancellation policy, and watchdog deadlines. An older attempt can still be writing while a newer request drains. The service supplies observations of its source holds, pending reads, queries, and compactor, then executes the lifecycle's decisions. The lifecycle allocates no buffers, starts no workers, and performs no I/O.

The service retains chunk ownership, dependency discovery, revision bookkeeping, and status metrics. Source release resumes simulation independently of durable completion. The encoder/writer still arbitrates cancellation against commit authorization; only its result establishes whether an attempt was cancelled. Application exit retains its existing wait, retry, cancel-exit, and quit choices. The shared typed work-key representation supplies the initial road obligation only; future NPC state and scheduling need their own semantics and handlers.

The durability contract is local APFS on macOS. Network filesystems, other platforms/filesystems, and devices that lie about synchronization are outside that contract. Fault-model tests check the required barrier semantics; native tests exercise the actual adapter. Neither substitutes for a physical power-cut campaign.

Live chunks, temporary preparation, source pins, and encoded output have different ownership lifetimes. A pin does not allocate a second block array. Empty blocks/metadata stay allocation-free; allocated capacities and temporary overlaps matter more than used lengths. Process RSS includes allocator overhead, graphics, client copies, and other storage beyond persistence counters. The separate resource-budgeting feature will provide global policy.

Lazy grass-growth timers and non-executable construction initialization markers may unload once exact-version base and pin rules permit it. Loading registers executable timers; catch-up runs in the next eligible block-timer pass using original deadlines and current composed cover. Unknown cover defers growth. Initialization markers instead wait for construction completion work. No elapsed offline time is added. Economy and cross-chunk NPC scheduling remain separate future work.

## Validation and measurements

```sh
zig build test-persistence
zig build test-world-service -Dtest-filter=warehouse -Doptimize=ReleaseSafe
zig build test-world-service -Dtest-filter='warehouse authority representative' -Doptimize=ReleaseFast
zig build test-blueprint-service
zig build test-capture
zig test src/voxel_app/persistence/save_lifecycle.zig
zig build test
zig build
zig build bench-persistence -Doptimize=ReleaseSafe -- /tmp/new-benchmark-world 10000 4000 5 8 1024 raw
```

Benchmark positional arguments are a **new** save directory, active chunks, changed chunks, cycles, output MiB, working MiB, workload (`terrain`, `raw`, or `heavy`), optional first-write/first-commit-sync delays in milliseconds, and an optional separate capture-working cap in MiB. The earlier working-MiB argument bounds the synthetic workspace including resident block arrays. JSON is emitted on stderr. It uses the production encoder, output queue, WAL, and compactor with reproducible synthetic sources. Its update microbenchmark does not measure the service mutation gate or player/frame latency. Compare repeated runs on the same machine and filesystem; retain workload/capacity settings with reports.

`zig build bench-extraction-save -Doptimize=ReleaseFast` measures capture and reopen after
one edit in a saved world containing extraction zones. [Extraction zone benchmark](validation/extraction-zone-persistence.md)

The [validation report](persistence-validation.md) records tested contracts, measurements, tuning evidence, and remaining validation limits. Advanced capture policies, allocator pools, and a larger hardware campaign should reuse these tests and workloads.
