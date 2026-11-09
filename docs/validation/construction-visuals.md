# Construction visual measurements

The [feature spec](../../specs/features/incremental-construction-visuals.md) now delivers
two PRs: immediate miniature caching, then FIFO preparation with four chunks per update,
a two-millisecond soft budget and no minimum age. The user approved brief terrain/miniature
mismatches; strict paired publication and persistent GPU staging are removed.

[PR #58](https://github.com/bacher/zig_engine/pull/58), commit `0df6e85`, is based on main
`b223e01`. It replaces sources synchronously and retains main's terrain/service-mesh paths. GPU resource retirement, subscription checks, source
limits and cache invalidation remain required independently of visual coherence.

## Immediate cache — PR #58

`replaceMiniatureChunk` validates data and capacity, reserves metadata, creates/uploads
one replacement, swaps it into the cache and releases the old source in the same call.
There is no external prepared handle or pending terrain/miniature transaction. Resident
sources are capped at 1,100,000 cells and 4,096 nonempty chunks; one temporary replacement
adds at most 32,768 records. The accounted source-byte ceiling is 18,124,288, excluding
transforms, bindings, container capacity, other buffers and driver/in-flight overhead.

Fresh measurements below use main `b223e01` plus the simplified synchronous cache,
not the former prepared API. Raw logs: [aligned sources](../benchmarks/construction-visuals-2026-11-09/gpu-immediate-results.log)
and [50-chunk sources](../benchmarks/construction-visuals-2026-11-09/gpu-immediate-offset31-results.log).
They ran on the M4 Max/Metal environment described below, separately from CPU tests.

| Scenario | Dynamic CPU-side p95, ms | Cached CPU-side p95, ms | Dynamic/cached source bytes per frame | Dynamic/cached draws per frame |
| --- | ---: | ---: | ---: | ---: |
| 32k, camera, 12 chunks | 0.1723 | 0.0244 | 1,536,000 / 0 | 1 / 12 |
| 320k, camera, 16 chunks | 2.0673 | 0.0325 | 15,360,000 / 0 | 1 / 16 |
| 320k, one changed chunk/frame | 2.3852 | 0.1054 | 15,357,000 / 309,178 | 1 / 16 |
| 320k, quarter of chunks changed/frame | 2.3937 | 0.2077 | 15,348,000 / 1,263,495 | 1 / 16 |
| 320k, camera, 50 chunks | 2.2243 | 0.0676 | 15,360,000 / 0 | 1 / 50 |

CPU-side time includes synthetic scanning/packing, synchronous replacement calls,
uniform updates, encoding and submission. It excludes completion waiting. The source
metric now measures replacement/upload calls. Source-byte counts exclude the 128-byte
transform per draw. Cold source seed calls cost 0.114 ms at 32k and 0.678–0.857 ms for
the listed 320k traces, excluding renderer initialization and completion waiting.
The aligned 320k camera trace's serialized total p95 is 4.0541/1.3943 ms for dynamic/cache;
the 50-chunk trace is 8.0520/1.6153 ms. These are not full-client frame times. Differences
from the historical prepared-API runs do not isolate an API simplification speedup.

All 27 final dynamic/cache color-image pairs matched and were nonempty, with no GPU
validation errors. `zig build test-gpu -Doptimize=ReleaseFast -j2 --summary all` passed
all 20 steps and 108 tests across both wrapping modes after the review follow-up. Readbacks cover color/depth parity,
camera reuse, full-cache replacement and shrink, empty removal, invalid/allocation
failures and resource release, including the dynamic 320k allocation regression.

The cache-first branch passed `zig build install test -Doptimize=ReleaseFast -Dblueprint-render-stats=true -j4 --summary all`:
56/56 steps, 1,909 tests passed and eight existing skips. `zig build test -Doptimize=Debug -j4 --summary all` passed 48/48 steps, 1,916 tests and one existing skip. Formatting and
`git diff --check` passed. Client regressions cover own versus neighbor/camera changes,
committed/no-op blueprint events, prediction rejection and cross-chunk replay, accepted
versus stale snapshots, mesh-only fulfillment, failure/shrink progress and eviction/reload.
The FIFO follow-up is not included in these branch totals.

Reproduce current renderer measurements from the repository root, running separately:

```sh
zig build bench-blueprint-visual-gpu -Doptimize=ReleaseFast
zig build bench-blueprint-visual-gpu -Doptimize=ReleaseFast -- --targets 320000 --offset 31 --scenario camera
```

The renderer harness uses production cache/draw calls, a 256×256 offscreen color/depth
target, 12 warmup frames and 100 measured frames per run. It alternates dynamic/cache
order across three repetitions and reports medians of per-run percentiles. It fences
after every frame: completion/total are serialized component wall times, not GPU
timestamps, pipelined frame times or application FPS. Packing is a synthetic grouped
cell scan, without world hash lookups, terrain, site frames, UI or service work. A final
color-image match is a sanity check, not per-frame visual correctness proof.

### Sparse remaining targets

The review follow-up adds `--fixture sparse`: exactly 512 unchanged targets distributed
over 1, 8, 27, 125 or 343 nonempty chunks. Every case uses the same wide camera and
1024×1024 target so quarter-size blocks remain visible across the full 7×7×7 footprint.
All chunks are supplied to the draw call; individual cubes may occlude each other.
This isolates the cost of increasing source/draw count within the sparse sweep, rather
than claiming those chunks are simultaneously unobstructed in a running game.

Fresh ReleaseFast results on the same M4 Max/Metal machine, with counters disabled,
12 warmup frames, 100 measured frames and three alternating-order repetitions. Entries
are medians of the per-run p95 values:

| Nonempty chunks | Dynamic CPU p95, ms | Cached CPU p95, ms | Dynamic/cached draws per frame | Dynamic/cached uniform bytes per frame |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0.0205 | 0.0193 | 1 / 1 | 128 / 128 |
| 8 | 0.0189 | 0.0223 | 1 / 8 | 128 / 1,024 |
| 27 | 0.0204 | 0.0377 | 1 / 27 | 128 / 3,456 |
| 125 | 0.0190 | 0.1234 | 1 / 125 | 128 / 16,000 |
| 343 | 0.0195 | 0.3170 | 1 / 343 | 128 / 43,904 |

Dynamic source uploads remain 24,576 bytes per frame; cached source uploads are zero.
At 343 chunks, transform bytes exceed the dynamic source-plus-transform bytes, and
CPU p95 is about 0.30 ms higher. Cold cache seeding costs 0.025–1.618 ms across the sweep.
Caching is therefore not a universal speedup: sparse sources expose per-chunk uniform,
binding and draw overhead. These measurements guide a later batching decision if
representative full-client workloads make that cost material; this PR keeps chunk caching.

All 15 final image pairs matched and were nonempty, with no GPU validation errors.
Raw data and the exact command are in [the sparse log](../benchmarks/construction-visuals-2026-11-09/gpu-sparse-results.log).
The same serialization and synthetic-packing limits apply. At 343 chunks, dynamic/cached
serialized total p95 is 0.2337/0.7020 ms; these are not game frame times. Sparse and dense
GPU wall times should not be compared directly because their resolutions/views differ.

```sh
zig build bench-blueprint-visual-gpu -Doptimize=ReleaseFast -- --fixture sparse
zig build bench-blueprint-visual-gpu -Doptimize=ReleaseFast -- --fixture sparse --chunks 343
```

### Optional renderer counters

`zig build -Doptimize=ReleaseFast -Dblueprint-render-stats=true` enables cumulative
blueprint renderer counters in either application; the option works in Debug too.
`miniatureCacheStats()` then measures source builds, source bytes, releases, uniform
bytes and draws. `previewCacheStats()` measures preview source builds, bytes and releases.
These are renderer events, not GPU timestamps or end-to-end client timings.

Both snapshots expose `counters_enabled`. Without the option this flag is false and
cumulative fields are unavailable, rather than measured zeros; live cached instance/chunk
counts remain valid. Counter storage and increments are compiled out of ordinary builds.
GPU tests always enable counters for lifecycle assertions. The benchmark checks enabled
and disabled counter semantics in its ordinary executable; performance runs omit the
option unless explicitly marked as instrumented.

All eight ordinary-executable smoke checks passed: Debug/ReleaseFast × default/enabled
counters × dense changing sources/sparse 343-chunk camera movement. Each includes one
warmup and three measured frames. Assertions check the gate, disabled cumulative fields,
enabled build/upload activity, exact draw/uniform totals including warmup, live occupancy
and balanced releases after clear. Their [correctness-only log](../benchmarks/construction-visuals-2026-11-09/gpu-counter-checks.log)
is separate from performance evidence.

## Shared FIFO preparation — follow-up to PR #58

The follow-up builds on the cache-first PR. One FIFO entry per loaded chunk coalesces
terrain/miniature dirty flags and reads the latest client state when visited. Default
minimum age is zero. Each update visits at most four chunks and stops starting visits
after two milliseconds of elapsed preparation time, checked between whole visits. Stale
or failed visits also consume a count slot; one visit may exceed the soft time limit.
Successful work for either representation can publish while the other remains dirty.
There is no paired staging or VoxelGrid change.

The budget covers local terrain extraction and miniature collection/replacement.
Reconciliation, direct accepted service meshes and terrain GPU uploads stay outside it.
It therefore bounds work started in this preparation pass, not complete frame time or
visual age. Unload and new subscription identities cancel obsolete queue membership;
failed dirty flags remain retryable and yield to other chunks.

The [fresh CPU replay](../benchmarks/construction-visuals-2026-11-09/cpu-budget-age0-results.log)
uses the current queue, World and extraction code atop `0df6e85`. All 60 runs converged to
matching final mesh/source/world checksums. The fixture remains 27 chunks with 19,872
initial targets, four seconds of fixed 60 Hz input and a final drain. Initial allocations
are warmed outside timing, and three alternating repetitions produce these medians of
per-run statistics at 512 accepted fills/second:

| Variant | Mesh builds | CPU-side p95, ms | Total CPU-side time, ms | First dirty age p95, ms | Latest dirty age p95, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cache immediate | 2,048 | 0.5722 | 125.495 | 15.7552 | 15.7552 |
| Cache + budget, age 0 | 974 | 0.2568 | 59.529 | 110.1563 | 49.4792 |

A 27-chunk burst has median per-run maximum preparation time of 1.7063 ms with immediate
caching and 0.2572 ms with the budget; maximum scheduled dirty age increases from 0 to
100 ms. At 1, 32 and 128 fills/second, age zero adds no scheduled delay or extra builds.
The optional age-two comparison produces 970 builds at 512 Hz, only four fewer than age
zero, and is not product policy. The count limit drives this fixture; four preparations
fit well below two milliseconds. This is a throughput-versus-freshness tradeoff within
preparation work, not evidence of improved whole-game smoothness.

Six focused client tests cover immediate count-limited FIFO/fairness and idle handling,
one whole visit beyond a soft zero time limit, initial-count retry bounds and independent
completion in both failure directions, stale subscriptions/eviction, direct service meshes
outside the budget and extraction allocation failure preserving older queued geometry.
Read-only review of the production integration and queue helper found no issue.
The branch's Debug aggregate passed **49/49 steps, 1,946 tests and one existing skip**.
ReleaseFast install/test passed **57/57 steps, 1,939 tests and eight existing skips**,
building both applications. Aggregate counts include imported queue cases in multiple
runners. Formatting and whitespace checks passed.
Renderer code is unchanged from PR #58, whose **19/19 GPU steps and 108 passing tests**
remain the renderer evidence; those GPU tests were not rerun for scheduling alone.

The [fresh queue-only fixture](../benchmarks/construction-visuals-2026-11-09/queue-age0-results.log)
passed with default age zero. Four input frames each issue 2,048 marks; work then drains
before 1,024 idle frames:

| Chunks | Marks | Visits with immediate draining | Budgeted visits | Coalesced marks | Peak pending | Total work frames | Head inspections |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 128 | 8,192 | 512 | 140 | 8,052 | 128 | 35 | 140 |
| 343 | 8,192 | 1,372 | 355 | 7,837 | 343 | 89 | 355 |

Both runs start at most four visits per frame and inspect zero heads during idle frames.
Total work frames include the four input frames. These are deterministic queue counts;
they contain no geometry generation, CPU/GPU timings or game-throughput measurement.
The historical age-zero/age-two results below remain separate evidence for earlier code.
Reproduce the standalone evidence from the follow-up branch, running separately:

```sh
zig build bench-chunk-visual-queue -Doptimize=ReleaseFast
zig build bench-construction-visuals -Doptimize=ReleaseFast
```

The CPU replay uses production extraction, target/solid lookups, CPU record packing and
queue/budget helpers. It bypasses the complete `Game` lifecycle, GPU uploads, service and
streaming work. Its publication ages use nominal 60 Hz ticks sampled per chunk update;
they omit actual build completion/display and are not event-to-present latency. Any
age-two variant is a comparison only; the product default is age zero.

## Historical prepared-API measurements (2026-11-09)

These results were recorded before the split, on Apple M4 Max (16 CPU cores, 64 GiB),
Metal, macOS 26.7.1, Zig 0.16.0 ReleaseFast with wrapped X. Timings ran separately.
The measured implementation was `951054a` plus the dynamic buffer-size correction
`eb794a0`; benchmark sources and the report were saved in `c4766a9` on
`codex/incremental-construction-visuals`. Those sources use the former prepared API.
Raw files are retained unchanged:

- [CPU replay](../benchmarks/construction-visuals-2026-11-09/cpu-results.log).
- [Prepared-API GPU, aligned](../benchmarks/construction-visuals-2026-11-09/gpu-results.log).
- [Prepared-API GPU, 50 chunks](../benchmarks/construction-visuals-2026-11-09/gpu-offset31-results.log).

### CPU preparation replay

The standalone replay has 27 block chunks with stone floors, existing rebar walls and
19,872 initial unfinished plank-wall targets. It directly applies accepted fills away
from chunk boundaries, supplies four seconds of nominal 60 Hz input and drains. It uses
production extraction, target/solid lookups, instance packing and the former queue;
it bypasses `Game` reconciliation, GPU/upload, capacity, cancellation and streaming.
Dynamic immediate reconstructs the previous policy with current primitives, rather
than running an archived full client. All 60 runs converged to matching final state.

At 512 fills/second, the 2,048 fills produce these medians of three per-run statistics:

| Variant | Mesh builds | CPU p95, ms | Total CPU, ms | Latest dirty age p95, ms | First dirty age p95, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Dynamic immediate | 2,048 | 0.579 | 129.38 | 15.8 | 15.8 |
| Cache immediate | 2,048 | 0.588 | 126.31 | 15.8 | 15.8 |
| Cache + budget, age 0 | 974 | 0.264 | 60.65 | 49.5 | 110.2 |
| Cache + budget, age 2 | 970 | 0.261 | 59.84 | 50.0 | 110.0 |

The four-chunk count limit drives this result; four preparations cost much less than
two milliseconds in this fixture. Waiting combines changes and roughly halves measured
CPU work. Age two saves only four more builds. At 1, 32 and 128 fills/second it saves
none while adding approximately 33 ms of scheduled age.

A burst changes all 27 chunks in one nominal frame:

| Variant | Maximum frame CPU, ms | Maximum scheduled dirty age, ms | Build frames |
| --- | ---: | ---: | ---: |
| Dynamic immediate | 1.118 | 0 | 1 |
| Cache immediate | 1.688 | 0 | 1 |
| Cache + budget, age 0 | 0.263 | 100 | 7 |
| Cache + budget, age 2 | 0.262 | 133 | 7 |

For the immediate cache, that maximum comes from one active sample per repetition.
Near-zero sparse-trace percentiles include idle frames and do not estimate rebuild
cost. One 512 Hz cache-immediate repetition had four frames above two milliseconds,
with a 2.820 ms maximum; the other maxima were 0.889 and 0.577 ms. No component run
exceeded 16.667 ms, but this small sample cannot establish rare-stall rates or game FPS.

Dirty ages are fixed-tick timestamps sampled once per chunk publication, not per edit.
They omit actual build completion and display time; CPU overruns do not slow the input
trace. CPU record-byte counts are not measured GPU traffic. The replay measures neither
the former persistent publication lifecycle nor the new second-PR implementation.

### Prepared-API renderer comparison

The historical GPU harness immediately commits each prepared cache replacement. It
compares identical camera/removal traces at 32,000 or 320,000 targets. A 100×100×32
320k source spans 16 aligned chunks or 50 when offset by 31 cells on every axis.

| Scenario | Dynamic CPU p95, ms | Cached CPU p95, ms | Dynamic/cached source bytes per frame | Dynamic/cached draws per frame |
| --- | ---: | ---: | ---: | ---: |
| 32k, camera, 12 chunks | 0.154 | 0.024 | 1,536,000 / 0 | 1 / 12 |
| 320k, camera, 16 chunks | 2.158 | 0.030 | 15,360,000 / 0 | 1 / 16 |
| 320k, one changed chunk/frame | 2.151 | 0.073 | 15,357,000 / 309,178 | 1 / 16 |
| 320k, quarter of chunks changed/frame | 2.149 | 0.167 | 15,348,000 / 1,263,495 | 1 / 16 |
| 320k, camera, 50 chunks | 2.231 | 0.060 | 15,360,000 / 0 | 1 / 50 |

CPU includes packing, source calls, uniform updates, command encoding and submission;
it excludes the completion wait. Source bytes exclude transform uniforms: cached draws
add 1,536/2,048/6,400 uniform bytes per frame for 12/16/50 chunks. Cold seed calls cost
about 0.13 ms at 32k and 0.67–0.82 ms at 320k, excluding renderer initialization and
completion waiting. The serialized total p95 is 3.992/1.366 ms for dynamic/cache at
320k aligned camera movement, and 8.047/1.361 ms at 50 chunks. Do not add these times
to separate CPU replay percentiles.

All 27 final dynamic/cache color-image pairs matched and were nonempty, with no GPU
validation errors. Separate readbacks verify color/depth parity and resource lifetimes.
The comparison includes the dynamic capacity correction in both paths: inferred `u21`
arithmetic overflowed `48 * 524288` during buffer growth. Correcting its type to `usize`
is a correctness fix, not a cache performance benefit.

## Conclusions and remaining work

Fresh synchronous renderer results support removing repeated miniature packing/uploads.
The fresh CPU replay supports a count budget to combine busy preparation work while
showing the resulting increase in scheduled visual age. Historical and comparison runs
provide little support for an additional minimum age. The approved split takes immediate
caching first and zero-age FIFO preparation second; it drops strict paired publication
rather than carrying its unmeasured complexity into either PR.

Neither component harness establishes complete-client smoothness, actual edit-to-visible
latency or whole-world simulation throughput. The M4 Max is faster than the proposed
4–8-core reference PC. A full-client comparison should hold accepted edits/camera motion
fixed and measure whole-frame CPU/GPU percentiles, missed deadlines, event-to-visible age,
backlog convergence and peak retained memory under realistic simulation/service load.
Include quiet manual edits, busy local construction, the streamed mesh ring, travel,
representation handoffs and capacity pressure. The ordinary local block core contains
27 chunks; treating 343 locally meshed chunks as the default would overstate that workload.
