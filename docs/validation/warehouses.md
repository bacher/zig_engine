# Warehouse validation

Run from the repository root with Python 3; no packages are required:

```sh
python3 docs/validation/warehouse_model.py
```

Expected output:

```text
PASS: 3 hash fixtures; all 16 selectors across 32768 local origins; wrapped X
PASS: 25 footprint dimensions; 196 distinct center/direction layouts
PASS: 2053700 aggregate N/A/C/I states; packing, admission, demand, handover
PASS: 25 halo geometries; full-body fit and vertical chunk-boundary case
Specification model only; no runtime, concurrency, persistence, or performance validation.
```

The [dependency-free verifier](warehouse_model.py) retains the executable arithmetic checks
used during specification review. Any failed invariant exits with an error, including when
Python runs with optimization enabled. It covers:

- [Q5](../../specs/features/warehouses.md#q5--exact-center-and-ordering): pinned SplitMix64
  fixtures, all local-origin selector combinations, wrapped-address equivalence, all dimension/
  center/direction variants, unique columns, inner-layer priority, late corners, the preferred
  second column where applicable, the exact east-facing 5×5 reference, and the 4×4 item 16/17
  boundary. It checks buffer-level order and physical slot coverage for each active prefix.
- [Q2](../../specs/features/warehouses.md#q2--what-does-active-capacity-restrict): every
  N in 1..25, A in 0..N, C in 0..6N, and I in 0..6N-C. All stock prefixes have contiguous
  stacks, preserve quantity, and drain disabled columns first. Aggregate checks cover demand,
  one-item and maximum-batch admission, reserved handover after capacity reduction, and the
  documented N=9 example. Some N values cannot form an allowed rectangle; testing them still
  checks the general count-based formulas.
- [Q26](../../specs/features/warehouses.md#q26--reserved-halo-displacement-fallback): all
  25 footprints have at most 24 halo cells and fit the current 0.6×0.6×1.8 player body.
  Feet at local z=31 require body data from a second vertical chunk. These geometric facts
  do not establish floor support, loaded data, or an actual runtime recovery path.

The warehouse spec remains normative. Update this model deliberately when its formulas
change, and reuse its pinned vectors when implementing Zig/client agreement checks. This is
an independent reference model, not a parser or a test of the future runtime. It cannot prove
concurrency safety, save/recovery coherence, command deduplication, collision integration,
rendering correctness, or sustainable throughput. No timing here is a game benchmark.

## Native implementation checks, 2026-11-15

The model report above records the specification checks and their limits. The native Zig
implementation now has separate layout, recognition, claims, aggregate state, delivery,
authority, client and persistence checks:

```sh
zig build test-warehouse -Doptimize=ReleaseSafe
zig build test-world-service -Dtest-filter=warehouse -Doptimize=Debug
zig build test-world-service -Dtest-filter=warehouse -Doptimize=ReleaseSafe
zig build test-persistence -Dtest-filter=warehouse -Doptimize=ReleaseSafe
zig build test-world-service -Dtest-filter='warehouse authority representative' -Doptimize=ReleaseFast
```

The focused authority run passed 56 tests in ReleaseSafe, with its one ReleaseFast-only
measurement skipped. The focused persistence run passed 28 tests. Imported invariant checks
are included in those counts, so they are not counts of independent gameplay scenarios.
The real-service dispatcher test also passed in Debug. These checks cover:

- Current-world registration recognition, full six-level clearance, support, active blueprint
  target conflicts, shared member/halo claims, and support protection after unregister.
- One-slot player transfers, incoming-room admission, capacity reduction and stopped warehouses,
  command retry/retirement, captured viewpoint evaluation, and stock/inventory publication fences.
- Local batches of accepted delivery start/handover, repeated completion, retained completed
  IDs behind an unfinished task, and fresh-session recovery without duplicate cargo.
- Frozen terrain/player/cargo capture, later mutations staying dirty, unchanged-domain retention,
  generation exhaustion before mutation, capture-memory rejection, write failure and retry.
- A partial construction handback saved beside a player put and accepted delivery: reopening
  preserves source stock, destination promise, delivery cargo, empty player inventory, raw and
  composed floor ownership, and both warehouse claims. Later handover/take effects stay outside
  that cut. Replayed start/handover does not charge or deliver twice; take/put remains legal before
  and after completion, and the final capture restores the completed delivery frontier.
- Real construction soil supporting a pallet and soil stored as cargo share one fixture. Only
  exposed real soil gains a growth deadline and grass; pallet-covered and target-covered soil
  remain bare. Cargo supplies no structural support or timer, and the warehouse record,
  generation and player inventory remain unchanged through completion and grass work.
- Recovery rejects missing members, missing floor and obstructed envelopes before worker startup.
  Codec truncation, malformed aggregate promises, highwaters, duplicate IDs and every-allocation
  failure paths also reject safely.
- Complete loose/member base-pallet sources for both mesh and block subscriptions, no terrain
  pallet faces, unchanged terrain on stock-only mutation, and a full-chunk 64 KiB source cap
  with release/retry and explicit empty replacement.

Version 8 also round-trips a pallet in the persisted player slot. Warehouse metadata is a
complete compact domain snapshot only when changed, sharing the terrain/construction/player
commit footer. Unchanged warehouse state costs an eight-byte WAL retention prefix.

## Native memory and capture

Measured with Zig 0.16.0 on macOS arm64, Apple M4 Max, 16 logical CPUs and 64 GiB RAM.
Allocator counters count requested native allocations and capacities; they exclude allocator
headers and the rest of the process. These are local prototype results, not the 4–8-core
target-PC validation campaign.

The maximum-record fixture uses 4,096 five-by-five warehouses placed across eight chunks
each, 32,768 exact-sized discovery references and 4,096 retained delivery records. An
unfinished first task pins the later completed records. Retained warehouse/layout/task/claim
allocations total **5,947,488 bytes**. The canonical image is **405,552 bytes**:
`48 + 51*4096 + 48*4096`. This comparison replaces any assumption that encoded bytes equal
native memory; it excludes terrain, clients, command ledgers and visual caches.

A synchronous allocation-metered capture experiment retains that source state, encodes one
image, retains a replacement image, and decodes/validates/rebuilds a temporary derived state.
Encoding peaks at **471,088 additional bytes**. The combined image/replacement/validation peak
is **7,656,152 additional bytes**, below the admitted **11,297,376-byte** bound. The bound is
`2*encoded_size + 512 + 2048*warehouse_count + 512*task_count`. Every allocation is released
and no budget rejection occurs. This measures codec/preparation overlap separately from
terrain capture pins and asynchronous writer timing.

## Service workload reference

The ReleaseFast representative test uses 4,096 two-by-two warehouses, initially 12 items
each. It runs 65,536 accepted start/handover transitions in batches of 128, alternating pairs
to preserve stock, beside 16 legal terrain pallet put/remove operations. The observed case
has one subscriber for every warehouse and prepares publications after each batch. It then
accepts 2,048 deliveries, captures 290 terrain sources and a 307,248-byte warehouse image,
hands over those deliveries while the real writer runs, captures the later state, performs
an unchanged capture and validates recovery. Total warehouse transitions are 69,632.

One local reference run produced these elapsed milliseconds. Isolated CPU rows measure the
service thread around that operation; they do not include background encoder/writer CPU.

| Work | Unobserved | Observed |
| --- | ---: | ---: |
| Seed state/terrain and initial publication, wall | 11.156 | 21.117 |
| 65,536 claim plus occupied-slot queries, wall | 3.787 | 3.811 |
| 65,536 transitions plus terrain/publication, wall | 9.123 | 27.536 |
| Batch authority transitions, isolated CPU | 7.845 | 7.928 |
| Publication preparation, isolated CPU | 0 | 18.392 |
| Sixteen terrain operations, isolated CPU | 0.729 | 0.612 |
| Changed capture setup, wall | 0.714 | 0.618 |
| Writer completion plus 2,048 handovers, wall | 24.340 | 23.493 |
| Unchanged capture setup, wall | 0.041 | 0.031 |
| Decode/rebuild and coherent terrain validation, wall | 32.174 | 31.298 |

The claim/occupancy phase allocated nothing. The combined transition phase made 86
allocations, retained 624,834 additional bytes and peaked at 625,042 additional bytes in each
case; this includes ordinary terrain/reply preparation. The observed run prepared 73,728
warehouse snapshots across the whole workload and coalesced them into 4,096 retained latest
snapshots. Observation added 1,351,704 retained bytes in this fixture. Its current subscription
revision scans dominate the measured authority-transition cost; these results do not establish
that publication is free or select a future incremental protocol.

Capture admitted 10,254,429 working bytes, with a 64 KiB output cap and a measured output
peak of 65,386 bytes. The compact two-by-two warehouse state itself held 1,767,936 estimated
native bytes at capture; its fewer chunk references explain why it is smaller than the
maximum eight-chunk fixture. Full accounting validation uses one warehouse pass and one
delivery pass, with linear temporary aggregates; ordinary transitions use their local records.

This is controlled service/codec execution with the production WAL writer, not a complete
logistics scheduler or economy. It does not measure rendered frame latency, GPU work, network
transport, food/workforce payment, route planning, sustained 100,000-task operation, many
clients or lower-core hardware. Peak counters during concurrent writing are diagnostic; the
synchronous experiment above supplies the reproducible capture-overlap bound check.
