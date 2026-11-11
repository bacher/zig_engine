# Bounded world-command submission

`Client.trySubmitOperations` adds an optional 1–64 operation transport path.
All intents enter the existing mailbox as individual requests under one lock,
with one condition signal and one checked admission-counter addition per packet.
It reserves capacity before changing slots or request IDs and copies intents
inline into the mailbox; there is no separate batch payload or large temporary
array of `Request` values. Mailbox growth remains fallible and amortized as before.

All operation reservations now share that mailbox lock, including the compatible
single-operation API. Result collection can concurrently decrease the count.
Checking `count <= limit -| used` before the addition avoids overflow and reserves
one slot per operation. Independently applied commands keep existing physical
validation, result identity, retries, checkpoint/save fencing, and owned responses.
See the [API contract](../voxel-world.md#bounded-operation-submission).

## Reproduce

```sh
zig build bench-command-submission -Doptimize=ReleaseFast --summary all
zig build test --summary all
zig build --summary all
```

The timing workload has a dedicated root and explicit benchmark option; ordinary
tests never run it, including ReleaseFast tests. Measured with Zig 0.16.0, native
arm64, macOS 26.7.1 (25G241). Each trial admits 131,072 operations in windows of
256, matching the default outstanding-operation limit. Three samples alternate
single/batch trial order. The table reports medians and ratios of those medians.

This compares the updated single-operation API with the new batch API in the
same executable; it does not compare the previous main revision with this revision.
Both use the actual Client method, admission counter, and request mailbox. Both
swapped request buffers are preallocated to 256 outside timing, so admission does
not allocate in these measurements. The workload repeatedly removes an empty
high-altitude cell. Between timed windows, a manual service driver runs the real
`processRequest`, package publication, and client result collection. It verifies
every per-command status and request ID, a rolling result digest, and that every
reserved slot was released. Those service/consumer costs are excluded from timing.

| Packet size | Single ms | Batch ms | Ratio | Batch lock/signal/reservation calls |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1.654 | 1.617 | 1.02× | 131,072 |
| 4 | 1.479 | 0.836 | 1.77× | 32,768 |
| 16 | 1.499 | 0.624 | 2.40× | 8,192 |
| 64 | 1.468 | 0.562 | 2.61× | 2,048 |

The single path makes 131,072 lock/signal/reservation calls in every case; these
call counts follow from the source operations, rather than instrumented OS events.
At size 64, batching reduces those calls 64-fold and measured submission time
about 2.6-fold. Payload copies, individual requests, validation, response preparation,
per-result counter release, and publication rules remain. Size 1 has no
amortization: its samples vary between a small regression and small improvement,
and no size-one speedup is claimed.

This is a single-producer, uncontended, submission-only measurement with warmed
request capacity. It excludes cold mailbox growth, allocator failures, queue-wait
latency, concurrent producer/worker contention, and service execution cost. It
establishes neither whole-service throughput nor NPC capacity. A packet holds the
producer lock while copying at most 64 intents; scheduling/fairness under contention
has not been benchmarked. No timing threshold is asserted.

## Deferred mixed-load validation

The [PR #62 review follow-up](https://github.com/bacher/zig_engine/pull/62#discussion_r4537167593)
is deferred until integration of bulk simulation producers, before enabling their
use of this queued batch path. The preparatory API currently has no gameplay batch
callers; its tests cover admission correctness, and its benchmark measures only
uncontended submission savings. Neither establishes fairness or interactive
latency under concurrent load.

Run an ordinary single-operation endpoint alongside one or more batch endpoints,
with the actual world-data service worker and result consumers running concurrently.
Compare a single-operation-only baseline with packet sizes 1, 4, 16, and 64 under
documented offered loads and retry policies, including near-capacity pressure.
Report the ordinary endpoint's p95/p99 submission latency, Busy/retry rate, and
elapsed time from its first attempt to successful admission, so quick Busy returns
cannot hide prolonged waiting. Also report sustained completed-operation throughput
and progress of each producer class. Longer mailbox critical sections and whole-packet
slot reservations may affect these independently of uncontended submission cost.

Use the results to choose packet sizes and admission/retry budgets under **SIM-03**
and **SIM-06** in the [simulation question list](../simulation-open-questions.md).
Client latency improvements must preserve sustainable simulation throughput; this
follow-up establishes no player-priority rule or numeric latency target. If the
simulation selects a different mutation path, validate that path's mixed workload
before enabling it rather than treating this queued-path benchmark as evidence.

## Correctness coverage

Executed validation: the focused `zig build test-blueprint-service --summary all`
passed 567/567 tests and 16/16 build steps. The final `zig build test --summary all`
passed 1,930 tests with one skipped and 48/48 build steps, including service,
application, persistence, and the new packet regressions. `zig build --summary all`
passed 25/25 steps and built both applications. The opt-in ReleaseFast benchmark
passed 5/5 tests and 17/17 build steps. Formatting and diff checks passed.

- Empty/oversized packets, Busy, allocation failure, stopped/closed service, and
  counter/request-ID exhaustion preserve prior requests, slots, and identities.
- Four distinct endpoints compete for 129 slots with maximum-size packets: exactly
  two 64-operation packets enter, with contiguous identities and no interleaving.
- Caller buffer overwrite cannot change admitted intents; mixed single/batch
  requests and a following checkpoint preserve endpoint order and the final ID.
- A seven-operation real-service chain places supports, rejects a duplicate and an
  invalid support removal, and still processes later successful removals in order.
  Waiting releases each slot; retrying a previously Busy packet keeps its first ID.
- A post-batch checkpoint and final Save persist every edit and player position.
  Unread results still occupy all slots until collected through the take API.
- A captured-prefix regression submits a batch into a wrapped retained queue and
  verifies the saved prefix excludes a later removal while that removal sees the
  preceding physical edit. Existing service/persistence regressions also run.

The change adds no simulation task acceptance, resource payment, logistics,
warehouse authority, scheduler, or exclusive-access mechanism. Packet admission
is separate from the future coherent task-start transition. Existing example NPC
behavior and single-operation callers remain compatible.

See [raw benchmark output](world-command-batches-benchmark.txt).
