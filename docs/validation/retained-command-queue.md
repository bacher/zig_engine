# Retained world-command queue

The world-data service retained mutations behind loading, capture, detached blueprint
admission, or journal backpressure in an `ArrayList(Pending)`. Each
`orderedRemove(0)` shifted every later payload; retry insertion at index zero
shifted them again. A full drain moved N(N−1)/2 payloads. `std.Deque(Pending)`
removes these shifts: front removal/retry and tail insertion take constant time
when reserved capacity is available. The request mailbox already swapped buffers;
this change does not optimize its transport or add a batch submission API.

On this arm64 build, `Pending` is 976 bytes. Both containers reserve the same exact
`limits.pending_commands` capacity at startup: 256 entries, or 249,856 bytes
(244 KiB), by default. Deque metadata is 32 bytes versus ArrayList's 24 bytes,
adding eight bytes to the service. Drain, refill, and retry reuse the element
buffer allocation. Existing growth/error behavior remains available for request
paths that can exceed the initial reservation. This is not a new queue admission
policy: each ordinary operation still consumes its existing admission slot until
its result is collected; blueprint Save/Apply admission remains unchanged.

## Reproduce

```sh
zig build bench-pending-commands -Doptimize=ReleaseFast --summary all
zig build test --summary all
zig build --summary all
```

`zig build test` includes the persistence suite.

Measured with Zig 0.16.0, native arm64, macOS 26.7.1 (25G241). The benchmark
uses the production private `Pending` type and compares the previous ArrayList
operations with the deque in the same executable. Each trial processes 65,536
commands. Two runs each used three samples with alternating execution order;
the table reports median elapsed milliseconds and ratios from the refreshed run
that also records the container metadata sizes. Both variants reserve
identical capacity before timing; assertions verify unchanged buffers and equal
order-sensitive result digests. Allocation and compilation are excluded.

`drain` repeatedly fills and completely drains the queue. `retry` additionally
returns every fourth popped command to the front and pops it again. `rotate`
keeps the queue full, replacing each removed command at the tail. Depth 1 tests
repeated empty/refill transitions; depth 256 is the production default; 1024 is
an explicit larger-capacity scenario, without changing the default.

| Depth | Workload | ArrayList ms | Deque ms | Ratio |
| ---: | --- | ---: | ---: | ---: |
| 1 | drain | 2.905 | 2.345 | 1.24× |
| 1 | retry | 5.286 | 5.030 | 1.05× |
| 1 | rotate | 1.707 | 1.705 | 1.00× |
| 64 | drain | 18.077 | 1.444 | 12.52× |
| 64 | retry | 27.372 | 2.150 | 12.73× |
| 64 | rotate | 35.209 | 1.348 | 26.12× |
| 256 | drain | 102.357 | 1.726 | 59.30× |
| 256 | retry | 143.291 | 2.281 | 62.82× |
| 256 | rotate | 231.076 | 1.563 | 147.84× |
| 1024 | drain | 451.544 | 1.820 | 248.10× |
| 1024 | retry | 662.117 | 2.401 | 275.77× |
| 1024 | rotate | 909.675 | 1.585 | 573.93× |

At default depth, the old full-drain workload shifts 8,155,299,840 redundant
payload bytes across its 256 bursts; deque removal shifts none. These are
mechanism counts derived from the queue operations, not measured memory traffic.
Depth 1 has no tail to move: its drain medians changed from 2.684 → 2.895 ms
(about 8% slower) in the initial run to 2.905 → 2.345 ms in the refreshed run.
This corner is sensitive to timing variability; no gain is claimed there, and
the other depth-1 comparisons remain near parity. No timing threshold is asserted.

These measurements concern retained-queue bookkeeping only. They exclude
request synchronization, physical validation, terrain/progress/inventory mutation,
meshing, snapshots, persistence I/O, and client publication. They do not establish
whole-service throughput, NPC capacity, or an improvement for edits that never
enter the retained queue. All per-command result, ordering, retry, save-prefix,
and payload ownership semantics remain unchanged.

Regression coverage exercises wrapped queues through an allocation-failed Save
publication and recovery, preserves request identity/wait age/save-fence counts,
checks sequential Put/duplicate/Remove validation with a later edit outside a
saved prefix, and shuts down with live owned Save payloads across both ring spans.
Existing persistence and service regressions cover asynchronous loading, journal
failures, checkpoints, admission, pause, shutdown, snapshots, and publication.

Executed validation: `zig build test --summary all` passed 48/48 build steps
with 1,920 tests passed and three skipped; `zig build --summary all` passed all
25 steps and built both applications. The refreshed ReleaseFast benchmark passed
all 16 build steps and all three test entries.

See [raw benchmark output](retained-command-queue-benchmark.txt). Future bounded
batch submission and simulation resource/task integration are separate changes.
