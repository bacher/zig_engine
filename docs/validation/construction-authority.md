# Construction authority validation

Measured on 2026-11-14, Apple M4 Max (arm64), macOS 26.7.1 (25G241), Zig 0.16.0,
`ReleaseFast`. This host is stronger than the target 4–8-core, 32 GiB PC (16 GiB desirable). These
numbers establish completed-work behavior on this host; they do not establish a target-PC
frame budget or an improvement over another construction ownership design.

## Workloads and execution

The opt-in `construction authority representative workload measurement` test in
`src/voxel_app/world_data_service.zig` executes authority work directly. It calls actual
fulfillment, publication, bounded scheduler, persistence Job/Store, filesystem save and
reopen paths. Timings end after the named work completes. No enqueue-only result is used.

| Case | Shared definitions / sites | Definition shape | Fills | Target groups | Observers |
| --- | --- | --- | ---: | ---: | ---: |
| Dense planks | 1 / 128 | 4×4×4, 64 plank targets; many sites share a chunk | 8,192 | 128 | 2 |
| Sparse soil | 1 / 128 | 129×1×1, dirt only at indices 0 and 128; five box chunks, two target chunks per site | 256 | 256 | 2 |

Both cases keep 128 materializing sites together, read 100,000 resident cells (90%
ordinary empty terrain, 10% composed targets), transfer the first group for half the sites,
perform a real partial save/reopen/resubscription, drain completion and grass initialization,
then save/reopen again and verify every material. The sparse case verifies all 256 resulting
grow-grass timers and their common completion-based deadline. It does not execute their later
scheduled grass growth. Dense completion takes 48 scheduler turns; sparse completion plus
initialization takes 320. Both runs finish with no active sites or outstanding initialization
obligations. The meter returns to zero retained capacity and records no allocation rejection.

Setup inserts fixture definitions/sites directly, so destination admission and compilation
costs are excluded. External command admission, retry-ledger lookup and mailbox dispatch are
also excluded; the fulfillment timing begins at the authority handler. Fulfillment invokes the real authority handler, with actual
per-operation acknowledgments; it uses the simulation client to isolate construction from
economy availability. There is no renderer, GPU, player movement, operating-system RSS
measurement, multiplayer network transport, or historical-design baseline in this experiment.

## Completed phase measurements

Two completed runs are reported as min–max milliseconds. CPU is the service caller thread's
CPU time, so asynchronous writer CPU is excluded from the save rows; their wall time includes
waiting for the real writer. Allocation calls count successful raw allocations throughout
the instrumented service/store lifetime, including asynchronous work. Resizes/remaps affect
capacity but are not counted as additional allocation calls. Retained and peak-extra bytes
are requested allocator capacity, including container spare capacity, rather than RSS.
Peak-extra is the phase maximum minus its starting retained capacity.

### Dense planks

| Completed phase | Wall ms | Caller CPU ms | Allocations | Retained B | Peak extra B |
| --- | ---: | ---: | ---: | ---: | ---: |
| fills | 11.933–11.997 | 11.933–11.997 | 35 | 31948195 | 50174256 |
| reads-90pct-ordinary | 3.801–3.828 | 3.801–3.828 | 0 | 31948195 | 0 |
| progress-publication | 6.262–6.356 | 6.262–6.356 | 279 | 3181987 | 131456 |
| partial-transfer | 0.140–0.143 | 0.140–0.143 | 14 | 3194003 | 15600 |
| partial-save | 7.755–7.759 | 0.253–0.255 | 607 | 2812261 | 335800 |
| partial-reopen-and-resubscribe | 32.857–33.683 | 13.919–13.956 | 2669 | 225525 | 372706 |
| completion-and-grass-burst | 0.184–0.187 | 0.184–0.187 | 15 | 1827669 | 1613520 |
| final-save | 6.090–6.092 | 0.088–0.089 | 86 | 2031877 | 56683–65000 |
| final-reopen | 24.962–25.103 | 5.575–5.716 | 539 | 120713 | 183833 |

### Sparse soil

| Completed phase | Wall ms | Caller CPU ms | Allocations | Retained B | Peak extra B |
| --- | ---: | ---: | ---: | ---: | ---: |
| fills | 0.415–0.426 | 0.415–0.426 | 20 | 3399492 | 3449296 |
| reads-90pct-ordinary | 2.896–2.968 | 2.896–2.968 | 0 | 3399492 | 0 |
| progress-publication | 1.490–1.511 | 1.490–1.511 | 360 | 2290500 | 254336 |
| partial-transfer | 0.086–0.090 | 0.086–0.090 | 24 | 2295044 | 5080 |
| partial-save | 9.112–9.146 | 0.105–0.125 | 643 | 6397127 | 108642–108756 |
| partial-reopen-and-resubscribe | 38.097–38.395 | 18.661–18.700 | 2996 | 691471 | 1198165 |
| completion-and-grass-burst | 1.407–1.422 | 1.407–1.422 | 437 | 2347055 | 1694884 |
| final-save | 6.103–6.104 | 0.100–0.102 | 215 | 6510111 | 134115–134127 |
| final-reopen | 29.622–29.747 | 10.631–10.677 | 809 | 631519 | 664490 |

The dense fill batch deliberately retains 8,192 acknowledgment responses before a flush.
They dominate its 31.95 MB retained capacity and 50.17 MB extra peak. The fixture raises the
command batch limit to 16,384; this result must not be presented as the memory cost of
construction bitmaps or as a typical default-sized batch. The 100,000 reads allocate zero
bytes in both cases.

## Encoded persistence and publication payloads

Byte counts below are identical across both completed runs. Persistence rows are actual
encoded bytes. Construction stream rows are in-memory publication-owned bytes under the
publication budget; no canonical network encoder exists, so these are not wire-byte claims.

| Payload | Dense planks B | Sparse soil B |
| --- | ---: | ---: |
| WAL through all fills: definition, sites and progress | 114,909 | 11,806 |
| WAL after the partial save: handback, completion and initialization | 4,032 | 10,048 |
| Partial encoded checkpoint | 9,631 | 12,384 |
| Final encoded checkpoint | 159 | 224 |
| Partial encoded chunk records | 8,572 | 5,674 |
| Baseline publication-owned capacity, both observers | 120,282 | 69,468 |
| Progress publication-owned capacity, both observers | 110,592 | 47,104 |
| Fulfillment-index bytes within progress publications | 65,536 | 2,048 |
| Partial-transfer publication-owned capacity | 25,600 | 25,600 |
| Completion publication-owned capacity | 93,184 | 99,328 |

Progress sends 128 site deltas per observer in the dense case (8,192 indices per observer)
and no raw target block payload. Completion sends four raw block payloads in the dense case,
32 in the sparse case, plus site transfer/retirement updates. Those final terrain payloads
are required when world data accepts ownership. These rows do not include a network framing
or compression estimate.

## Runtime memory policies

`persistence.coordinator.Limits.construction_state_bytes` defaults to 256 MiB and governs
a tunable conservative estimate of native construction containers. It includes definition
names/cells, definition/instance/chunk hash-map capacities, fulfillment bytes, box-chunk
arrays, target groups, target indices, retained per-chunk pending lists/lookups/instance
lists, and cleanup capacity. Removing a pending lookup entry does not reduce the estimate
while its allocation remains retained. It also includes detached instance copies,
publication replacements, snapshot index/directory/mask copies, soil plans and retiring
preparation ownership. Hash metadata and alignment receive conservative padding.

Admission reserves the remaining native allowance before the helper runs. A local allocator
window bounds actual new helper allocations, including temporary maps, copied instances,
prepared publications and soil staging, before they can exceed that allowance. Save,
admission start, source-copy acquisition, commit reservations and restore recheck their
applicable boundary before publishing accepted state. Map growth charges old and new
allocations while they coexist. A failed operation can retain harmless reserved capacity;
it cannot publish an instance or apply soil writes. Rejected new work does not discard
previously accepted construction. The helper reservation can temporarily exhaust capacity
for a concurrent new Save; callers receive the existing resource-exhausted result.

This is not a process-RSS cap. Allocator pages/bookkeeping, command/result queues, world
terrain, persistence buffers and consumer publication buffers are separate. The encoded
blueprint-state policy remains independently 64 MiB. Raw source snapshots retain their
independent 128 MiB bound per preparation; raw restore-validation cache allocations also
have that bound and evict cached source chunks while validation continues across larger worlds.
Existing admission throttling permits at most eight active/retiring tasks
combined, so the theoretical retained raw snapshot bound is eight times 128 MiB, not a
global 128 MiB. Source decode/generation scratch remains governed by its existing per-chunk
paths. No per-fill global scan was added.

The checkpoint policy counts definition metadata, fulfillment bitmaps, target portions and
outstanding grass obligations through the same conservative sizing helpers used by
persistence preparation. Each active site reserves the larger of its active checkpoint
footprint and its eventual grass obligations. Save and Apply check the aggregate reservation
before publication, and restore checks it before accepting the loaded state. Completion
replaces its reservation with actual obligations; completed grass work releases its bytes.
The cached scalar is preserved by fills and transfers, avoiding a global scan per operation.
A site whose soil groups exceed the configured grass-work quota is rejected before Apply.

Focused native-limit tests cover exact equality and one-byte-under rejection for Save,
pre-helper Apply rejection, helper allocation exhaustion, commit rejection before soil
writes, and restore-copy limits. The allocation-window unit test checks equality, rejection,
cleanup and transfer of successful output to its ordinary backing allocator.
Checkpoint-limit regressions cover a sparse 1,409-cell definition with 12 target portions,
exact shared-policy equality, rejection before Apply identity/inventory/terrain changes,
and Save while materializing, partially transferred, or awaiting grass initialization.
They verify rejection one byte below the reservation, acceptance at equality, actual
checkpoint preparation, and subsequent completion under that same cap. Grass-quota tests
cover impossible-site rejection and retirement retry after older work releases capacity.

## Persistence correctness evidence

The authority tests cover raw-air ownership until group transfer, retained materializing
sites, cross-site composed support, completed portion retry, fixed lifetime grass markers,
coherent partial saves, later replacement protection and saved terrain-revision validation.
The public lifecycle harness consumes actual discovery/definition/snapshot/delta/retirement
messages, including restart completion.

`persistence/blueprints.zig` sweeps allocation failure through partial transfer, completion,
grass initialization and checkpoint/replay; duplicate transfers and premature completion
reject the complete prepared transition. The storage failed-sync test independently covers
transfer, completion and grass activation, with both loss and survival of unsynced bytes.
Each of its six scenarios verifies WAL recovery followed by compacted-base recovery,
including raw timer token/deadline and obligation membership. This adds new-operation
coverage to the existing generic crash harness; it does not enumerate every possible
filesystem write cut or constitute a power-loss claim for physical hardware.

## Alternative comparison and reproduction

Q2's alternative of keeping fulfilled cells in ordinary world data was not implemented or
measured here. The observed allocation-free reads and grouped handback do not establish
that the chosen design is faster or smaller than that alternative. A meaningful comparison
needs the same two workloads, observer behavior, source residency, save durability and
hardware, with both implementations completing the same work.

```sh
zig build test-world-service -Dtest-filter='construction authority representative workload' -Doptimize=ReleaseFast --summary all --cache-dir /private/tmp/construction-measure-cache --global-cache-dir /private/tmp/construction-global-cache
zig build test-world-service -Dtest-filter='construction native' --summary all
zig build test-persistence -Dtest-filter='construction transfer completion' --summary all
```

The workload skips outside ReleaseFast. Re-execute its emitted test binary for independent
repetitions because a repeated Zig build may replay a cached test result. The two raw logs
for this report are `/private/tmp/construction-authority-final-5.log` and
`/private/tmp/construction-authority-final-6.log`; they are local validation artifacts.
