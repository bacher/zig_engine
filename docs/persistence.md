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
implementation writes format 2 and reads formats 1–2, decoding legacy empty inventories into
the same current player model. The base and WAL readers enforce the supported inclusive
range through `minimum_readable_version` and `current_write_version`.

Under the current pre-release policy, a sufficiently incompatible gameplay or data
interpretation change advances the write version and raises the minimum readable version to
exclude incompatible older worlds. Raising only the write version would leave those old
saves readable. This applies even when the byte layout has not changed, and covers terrain,
saved blueprint libraries, and unfinished construction sites together. Generator
identity/version guards likewise reject unsupported algorithms. All accepted saves use the
current game logic.

## Saving and exit

Autosave attempts run every 60 seconds and compaction is requested every 10 minutes. Only a durable WAL commit establishes saved progress; the interval is not a maximum loss window. Base compaction allows exact-version dirty chunks to unload and retires covered journals after durable installation.

Simulation and block timers pause while snapshot sources are held. The encoder releases sources as independent records become available, allowing gameplay to resume before disk synchronization. Conflicting player edits remain pending. Ordinary waits can cancel capture safely; saving that falls sufficiently behind can prioritize completion with visible status. UI/rendering continue, but world-changing actions may wait. Actual disk errors cannot be solved by prioritization; unsaved state stays dirty for retry.

Closing the window or choosing Exit from the Escape menu stops producers and drains existing edits before publishing the final player checkpoint and save. The final capture is exempt from ordinary gameplay wait deadlines. After a failure or five seconds without meaningful progress, the dialog provides retry/wait, cancel exit, or explicit quit without saving. Quitting without saving may lose changes since the last durable snapshot. A durable WAL remains recoverable if final compaction fails.

Saved player state includes identity, feet position, yaw, pitch, and the material in the one-slot inventory. Inventory changes belong to authoritative terrain transfers and are captured in the same snapshot. Movement checkpoints preserve the service-owned inventory. Velocity, climbing state, partial interaction holds, pending client predictions, and transient movement history are reset on startup. Format 2 writes inventory schema 1; supported format 1 saves load with empty inventories. Restored collision is checked against authoritative terrain before gameplay starts.

## Storage and ownership

`format.zig` owns explicit versioned little-endian records and checksum domains. `storage.zig` implements framed WAL transactions, startup verification/recovery, indexed base reads, and compaction. `io.zig` provides stable exclusive locking and checked positional I/O with macOS `F_FULLFSYNC` and directory synchronization. `io_model.zig` models separate content and namespace durability for crash tests. `coordinator.zig` connects restricted source views to bounded encoded output; the service alone mutates live chunks.

`save_lifecycle.zig` owns save policy on the service thread: the active attempt, a queued drain's command fence and retry allowance, cancellation policy, and watchdog deadlines. An older attempt can still be writing while a newer request drains. The service supplies observations of its source holds, pending reads, queries, and compactor, then executes the lifecycle's decisions. The lifecycle allocates no buffers, starts no workers, and performs no I/O.

The service retains chunk ownership, dependency discovery, revision bookkeeping, and status metrics. Source release resumes simulation independently of durable completion. The encoder/writer still arbitrates cancellation against commit authorization; only its result establishes whether an attempt was cancelled. Application exit retains its existing wait, retry, cancel-exit, and quit choices. This boundary defines no future NPC state, scheduling, or simulation-persistence interface.

The durability contract is local APFS on macOS. Network filesystems, other platforms/filesystems, and devices that lie about synchronization are outside that contract. Fault-model tests check the required barrier semantics; native tests exercise the actual adapter. Neither substitutes for a physical power-cut campaign.

Live chunks, temporary preparation, source pins, and encoded output have different ownership lifetimes. A pin does not allocate a second block array. Empty blocks/metadata stay allocation-free; allocated capacities and temporary overlaps matter more than used lengths. Process RSS includes allocator overhead, graphics, client copies, and other storage beyond persistence counters. The separate resource-budgeting feature will provide global policy.

Lazy dirt/grass timers may unload once exact-version base and pin rules permit it. Loading registers them; catch-up runs in the next eligible block-timer pass using original deadlines and current conditions. No elapsed offline time is added. Economy and cross-chunk NPC scheduling remain separate future work.

## Validation and measurements

```sh
zig build test-persistence
zig test src/voxel_app/persistence/save_lifecycle.zig
zig build test
zig build
zig build bench-persistence -Doptimize=ReleaseSafe -- /tmp/new-benchmark-world 10000 4000 5 8 1024 raw
```

Benchmark positional arguments are a **new** save directory, active chunks, changed chunks, cycles, output MiB, working MiB, workload (`terrain`, `raw`, or `heavy`), optional first-write/first-commit-sync delays in milliseconds, and an optional separate capture-working cap in MiB. The earlier working-MiB argument bounds the synthetic workspace including resident block arrays. JSON is emitted on stderr. It uses the production encoder, output queue, WAL, and compactor with reproducible synthetic sources. Its update microbenchmark does not measure the service mutation gate or player/frame latency. Compare repeated runs on the same machine and filesystem; retain workload/capacity settings with reports.

The [validation report](persistence-validation.md) records tested contracts, measurements, tuning evidence, and remaining validation limits. Advanced capture policies, allocator pools, and a larger hardware campaign should reuse these tests and workloads.
