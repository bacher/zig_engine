# Persistence v1 validation

This report accompanies the implementation stacked on spec PR #29. The [feature spec](../specs/features/world-persistence.md) remains the contract; this report distinguishes exercised behavior from validation that still needs a larger campaign. [Acceptance evidence](persistence-acceptance.md) maps individual criteria to tests and remaining gaps.

## Reproduce correctness checks

Use Zig 0.16.0 on macOS with the repository's graphics dependencies available:

```sh
zig build test-persistence
zig build test-capture
zig build test-world
zig test src/voxel_app/persistence/save_lifecycle.zig
zig build test
zig build
```

Final full CPU run: **600 passed, 1 skipped** across 601 tests. The skip is the existing wrap-only coordinate test in the unwrapped configuration. The focused capture target also passed 47/47 tests.

The focused targets isolate codec/storage, capture concurrency, and world/timer/client logic. The full suite also exercises the authoritative service and application lifecycle. Tests use temporary worlds and deterministic failure injection; they do not write the default player save.

| Area | Evidence |
| --- | --- |
| Wire format | `persistence/format.zig`: explicit byte layouts and identities, all-air/RLE/raw records, checksums, malformed metadata, round trips, allocation failure cleanup, maximum 1,212,501-byte record. |
| Durable storage | `persistence/storage.zig`: native creation/reopen, WAL repair, complete versus incomplete transactions, rotation, compaction, corruption evidence, immutable generation reads, offsets above 4 GiB. |
| Crash boundaries | `persistence/io_model.zig` through storage tests: separate file/directory durability, uncertain synchronization survival/loss, replacement and retirement, stable lock release, atomic multi-chunk/global/player snapshots. |
| Capture ownership | `persistence/lifecycle_tests.zig`: independent write/sync gates, cancellation before/after commit authorization, source release before durability, exactly-once releases, arbitrary player priority sets, borrowed-source mutation after release, bounded admission/output. |
| Mutation preparation | `world.zig`, `roads.zig`, `world_data_service.zig`: complete write sets, fallible resource preparation, atomic road edits and revision publication, independent origin snapshots and coalesced observer state. |
| Lazy block timers | `timer_kernel.zig` and service tests: fixed cutoff, original deadlines, finite local chains, incremental/large-step equivalence, stale-event consumption, edit-before-catch-up behavior, eviction/reload. |
| Seeded service restart | `persistence_service_tests.zig`: three seeds with four save/restart rounds each; independent blocks/revisions/global/player model, unsaved suffix loss, base/WAL recovery and async reload. |
| Client and shutdown | World/application/service tests: bounded optimistic edits, reconciliation, allocation-failed snapshot renewal, final-save admission fence, persisted players, initialization cleanup. |

The storage model and capture tests execute production paths with controlled faults. They are not a physical power-loss test, an exhaustive scheduler exploration, or a substitute for service-level integration tests.

## PR review regressions

The follow-up to [review comment 6308773667](https://github.com/bacher/zig_engine/pull/30#issuecomment-6308773667) adds focused coverage for these changes:

- Simulation pause now synchronizes with command admission. A gated dispatch test verifies that a preempted producer cannot enqueue after final-save selection; resuming admits the edit and the next save contains it.
- Save requests establish their pending-command fence before restarting both query reads and mutation dependency discovery. Tests cover a dependency failure before final saving, one delayed automatic retry, explicit retry, and permanent corruption. The resumed edit is checked in decoded durable storage. Additional cases cover failed read-only queries, queued save identity after an older writer finishes, and synchronous dependency-preparation allocation failure.
- First-run creation makes missing parent directories and confirms directory barriers before acknowledging creation. Native fault tests cover mkdir, ancestor synchronization and full-flush failures while retaining installed evidence.
- Dense timer restoration reserves and appends validated events, then sorts once. A 32,768-event regression checks uniqueness, original deadlines/kinds and deadline/cell ordering.
- Encoded-output dequeue advances a head index without shifting descriptors. A stalled, failing write verifies that writer-owned bytes remain charged and cleanup frees only unconsumed entries.

The initial fixes centralized save request, drain selection, retry and failure handling in service helpers. The follow-up extraction below moves that policy into an independently testable component. The broader integration and hardware validation gaps below remain open.

## Save lifecycle extraction

`save_lifecycle.zig` now owns active attempt stages, queued command fences, the bounded dependency-retry allowance, cancellation policy, and watchdog deadlines. The service executes its decisions using the existing worker, dependency queues and source ownership. Public status remains compatible; application exit choices and encoder/storage code are unchanged.

Twelve deterministic, standard-library-only tests cover command-prefix fences, queued takeover after an older writer, read-query/compactor readiness, retry exhaustion and replacement, earliest deadline selection, final/overdue exemptions, cancellation versus durable completion, exact failure values, failed finalization after a durable commit, and stale epochs. A completed or cancelled drain retires its retry deadline; the ready-drain test verifies that an obsolete retry cannot fire after capture becomes eligible. These tests run with `zig test src/voxel_app/persistence/save_lifecycle.zig` and through the full suite.

Stage predecessor assertions run in Debug/ReleaseSafe after stale-epoch rejection; failed completion remains legal at any stage. ReleaseFast retains the epoch checks without runtime assertion checks. The twelve standalone lifecycle tests passed in Debug, ReleaseSafe, and ReleaseFast. The extraction adds no worker, allocation, disk operation, file-format change, or future simulation interface. Existing service regressions still exercise actual capture deadlines, dependency-read failures, durable edit recovery, and shutdown admission. No new benchmark or interactive UI campaign was performed for this refactor.

## Native application smoke check

A disposable persistent world was created with the native application. Metal initialized and terrain rendered/continued updating. The process was terminated after autosaving, then the same world reopened and rendered successfully through recovery. This checks process termination and recovery; it does not establish power-loss durability.

The computer-use adapter could not attach to the unbundled GLFW executable. The interactive close/error/cancel dialog was therefore not exercised through UI automation. Its command admission behavior has CPU regression coverage; visual interaction remains a manual check.

## Benchmark runner

```sh
zig build bench-persistence -Doptimize=ReleaseSafe -- \
  /tmp/new-persistence-benchmark 10000 4000 10 32 1024 raw 0 0
```

Arguments are a new world path, active chunks, changed chunks, cycles, output MiB, total synthetic-workspace MiB, workload (`terrain`, `raw`, `heavy`), first transaction write stall in milliseconds, first commit synchronization stall in milliseconds, and an optional separate capture-working allowance in MiB. Omit the last argument to use the total workspace allowance minus resident block-array bytes. Each cycle injects the requested delays independently. Missing WAL segments are established before timing delayed transactions so header synchronization cannot be confused with commit synchronization.

The runner uses production encoding, bounded output, WAL, compaction, and recovery. Every second cycle compacts. A final reopen compares decoded blocks, revisions, global time, and metadata against independently retained logical sources. Reports preserve individual cycles, capacities, seed, phase times, output occupancy, retained source bytes, RSS high-water mark, I/O calls, and the recovery oracle. An error prevents reporting an oracle pass.

`baseline_update_ns` and `update_ns` are synthetic array-update microbenchmarks. They are not player confirmation latency or authoritative mutation-gate overhead. `encode_active_ns` is elapsed encoder work excluding explicit output waits, not measured thread CPU time. Phase work overlaps and must not be summed. `total_ns` includes compaction on compacting cycles. RSS is the process lifetime high-water mark, not current live allocation or a sum of budget counters.

## Recorded scale results

Machine: Apple M4 Max (Mac16,5), 64 GiB RAM, macOS 26.7.1, local APFS, Zig 0.16.0, ReleaseSafe. Runs used seed 1, ten cycles, and no discarded warmup. Nearest-rank p95 is the maximum of ten samples; these runs do not establish a reliable production tail percentile.

The [raw reports and CSV](benchmarks/persistence-2026-10-19/) contain fourteen original scale/capacity cases and four additional capture-working-budget runs. All completed the reopen oracle.

| Workload | Output cap | Release p95 | Durable ACK p95 |
| --- | ---: | ---: | ---: |
| 10,000 active / 4,000 raw changed | 8 MiB | 259.17 ms | 281.50 ms |
| Same | 16 MiB | 220.07 ms | 255.03 ms |
| Same | 32 MiB | 204.60 ms | 240.72 ms |
| Same | 64 MiB | 203.54 ms | 236.41 ms |
| Same | 128 MiB | 204.77 ms | 241.74 ms |
| Same | 256 MiB | 204.29 ms | 239.20 ms |
| Same, 300 ms write stall | 8 MiB | 526.39 ms | 546.03 ms |
| Same, 300 ms write stall | 128 MiB | 198.98 ms | 545.77 ms |
| Same, 300 ms write stall | 256 MiB | 201.25 ms | 540.89 ms |
| 10,000 active / 4,000 terrain changed | 8 MiB | 115.46 ms | 135.26 ms |
| Same, 300 ms write stall | 8 MiB | 106.10 ms | 381.15 ms |
| 2,000 active / 1,000 raw changed | 8 MiB | 71.59 ms | 87.65 ms |
| 256 active / 64 maximum-metadata changed | 8 MiB | 109.53 ms | 123.84 ms |

The original `scale-v2-*` reports predate two metric corrections: their `durable_boundary_age_ns` includes post-commit compaction, and their heavy-workload `source_bytes` counts only block arrays. Use `durable_ack_ns` for commit latency in those reports; neither historical field establishes freshness or complete heavy-source retention. The current runner and `budget-*` reports use the corrected definitions.

The independent sync-stall case is also retained. Source release remains independent of commit synchronization, although scheduling and earlier output contention can change its elapsed time. Controlled gate tests establish the ordering; the timing runs measure a particular machine.

An explicit capture-working-budget sweep held output at 8 MiB and varied working allowance independently of the 1 GiB synthetic workspace. Ten-cycle runs at 16/32/64 MiB all passed, with release p95 of 284.30/275.81/281.95 ms. The chosen 32 MiB output / 64 MiB working configuration also passed (release p95 223.65 ms, durable ACK p95 296.08 ms). This confirms admission and execution at these caps; differences between these later runs and earlier timings are run variability, not evidence that spare working allowance improves throughput. See the `budget-*` reports.

The raw 4,000-chunk capture emits approximately 125.22 MiB. With healthy storage, 32 MiB removes most output backpressure and larger caps add little. A 128 MiB cap can retain that entire encoded capture during a finite write stall, releasing sources earlier at higher memory cost. Compressible terrain fits even in the smaller cap. This supports retaining one streaming pipeline and exposing capacity as a tuning parameter, without adding whole-snapshot buffering policy or COW.

## Initial defaults and limits

| Setting | Initial value | Basis |
| --- | ---: | --- |
| Encoded output | 32 MiB | Healthy-storage capacity sweep reaches a plateau. Includes writer-owned bytes until released. |
| Capture working allowance | 64 MiB | Output plus manifest, completion slots, player records, codec scratch; admission rejects configurations that cannot fit. |
| Authoritative payload allowance | 512 MiB | Holds about 10,000 materialized 32 KiB arrays with payload headroom. Metadata and overlap are charged; this is not a whole-process RAM limit. |
| Outstanding player operations | 256 | Finite service/app admission, including unread terminal replies. Client prediction also has independent item/byte bounds. |
| Normal capture deadline | 500 ms | Above healthy synthetic capture times; finite injected stalls cross it. A starting responsiveness policy, pending real gameplay tuning. |
| Normal player wait deadline | 100 ms | Initial policy for priority/cancellation; not a measured guarantee of invisible delay. |
| Overdue-save escalation | 180 s | Three nominal autosave intervals; attempts/source release do not reset durable progress age. |
| Autosave / compaction | 60 s / 600 s | Agreed baseline cadence. Final saving is exempt from normal gameplay deadlines. |

Local limits are configurable in the service/coordinator APIs. Buffers allocate as needed. Live payload accounting covers owned authoritative blocks/metadata; it does not include graphics, client replicas, every storage/index allocation, or allocator fragmentation. Source pins report retained backing, not additional copies. Installed-base mismatch can retain modified chunks after WAL acknowledgement; lazy timers alone do not pin an otherwise eligible chunk.

## Further validation

These are validation limits, not evidence that a scenario has passed:

- Run the target workload on actual 16 GiB hardware and smaller workloads on 8 GiB hardware. The smaller case on this 64 GiB machine is only a configured workload check.
- Measure player confirmation/correction and frame tails, mutation preparation versus existing client copying, thread CPU, and timer catch-up debt during long service/gameplay traces. Current synthetic update timings cannot answer these questions.
- Extend replay traces that combine faults, progressive release, multi-chunk edits, eviction/reload, and client ordering in a single model. Existing focused models cover these boundaries separately.
- Perform the interactive shutdown/error/cancel matrix and a physical power-cut campaign before expanding durability claims beyond the stated adapter/model evidence.
- Run longer and multi-seed parameter campaigns, including filesystem/device variability and dirty-state growth across many save intervals. Report save success rate and unsaved age as well as responsiveness. Do not choose a new capture policy solely from encoding throughput.

Build reproducibility limitation: the available ignored `zig-pkg` cache already contains compatibility edits for Zig 0.16 graphics dependency build APIs. The implementation was tested with that cache. A pristine dependency fetch is not verified by these results; those external dependency edits are not included in this persistence PR.
