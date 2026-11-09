# Construction visual measurements

Measured on 2026-11-09 to separate miniature caching, preparation scheduling, and
coherent deferred publication in [PR #57](https://github.com/bacher/zig_engine/pull/57).
The implementation under test is `951054a`, based on `72ad9de`, plus the dynamic
buffer size correction described below. The [feature spec](../../specs/features/incremental-construction-visuals.md)
continues to define behavior; these measurements do not change its defaults.

## Decision supported by the evidence

Miniature caching removes substantial repeated CPU packing and source uploads in the
large renderer fixture. A four-chunk preparation limit reduces CPU peaks and repeated
mesh builds in the busy CPU fixture, at the cost of older visual observations. The
additional two-frame minimum age provides almost no further work reduction in these
traces and delays otherwise cheap isolated edits.

Neither benchmark measures the complete application's frame smoothness or the cost or
benefit of persistent paired terrain/miniature publication. That machinery implements
the spec's strict per-chunk visual coherence requirement, including failure, capacity,
and streaming cases. Its complexity cannot be justified as a measured performance win
from the results below. Removing scheduling and relaxing that coherence requirement
are separate decisions: immediate cached rendering still needs invalidation and safe
resource lifetimes.

## Environment and method

- Apple M4 Max, 16 CPU cores, 64 GiB system memory; Metal; macOS 26.7.1.
- Zig 0.16.0, ReleaseFast, wrapped-X build. CPU and GPU timings ran separately.
- Three repetitions with alternating variant order. Tables use the median of the
  three per-run percentiles or maxima, rather than a pooled percentile.
- This machine is faster than the game's proposed 4–8-core reference PC. No result
  establishes performance on that target hardware or whole-world simulation throughput.

Reproduce from the repository root, running the commands separately:

```sh
zig build bench-construction-visuals -Doptimize=ReleaseFast
zig build bench-blueprint-visual-gpu -Doptimize=ReleaseFast
zig build bench-blueprint-visual-gpu -Doptimize=ReleaseFast -- --targets 320000 --offset 31 --scenario camera
```

Raw logs: [CPU](../benchmarks/construction-visuals-2026-11-09/cpu-results.log),
[GPU, aligned](../benchmarks/construction-visuals-2026-11-09/gpu-results.log),
[GPU, 50 chunks](../benchmarks/construction-visuals-2026-11-09/gpu-offset31-results.log).

## CPU preparation replay

The standalone replay uses 27 local block chunks with stone floors, existing rebar
walls, and 19,872 initial unfinished plank-wall targets. Each chunk has an eight-course
24×24 perimeter, without a roof. The trace represents already accepted fills; it does
not run blueprint admission. Changes stay away from chunk boundaries, so this fixture
does not measure boundary-driven extractions. Each trace supplies four seconds of input
at nominal 60 Hz and then drains outstanding work.

The four variants use current production mesh extraction, target lookup, physical
occupancy checks, and instance/source packing:

- **Dynamic immediate:** rebuild dirty meshes immediately; repack camera-relative
  48-byte miniature instances every frame. This reconstructs the previous policy using
  current primitives; it is not an archived full-client executable.
- **Cache immediate:** rebuild dirty meshes and 16-byte miniature sources immediately.
- **Cache + budget, age 0:** coalesce dirty chunks through the production queue and
  limit preparations to four chunks/two milliseconds, without minimum age.
- **Cache + budget, age 2:** use the current defaults, including two-frame minimum age.

| Fills/second | Dynamic immediate CPU p95, ms | Cache immediate CPU p95, ms | Budget age 0 CPU p95, ms | Budget age 2 CPU p95, ms |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0.338 | <0.001 | <0.001 | <0.001 |
| 32 | 0.327 | 0.065 | 0.066 | 0.066 |
| 128 | 0.382 | 0.184 | 0.187 | 0.186 |
| 512 | 0.579 | 0.588 | 0.264 | 0.261 |

These are percentiles over all input/drain frames. At 1 Hz the cached variants have
only four active frames; their active-frame p95 is about 0.065–0.068 ms. Near-zero
all-frame percentiles represent idle frames and are not estimates of rebuild cost.

At 512 fills/second the 2,048 fills produce:

| Variant | Mesh builds | Total measured CPU, ms | Latest dirty age p95, ms | First dirty age p95, ms |
| --- | ---: | ---: | ---: | ---: |
| Dynamic immediate | 2,048 | 129.38 | 15.8 | 15.8 |
| Cache immediate | 2,048 | 126.31 | 15.8 | 15.8 |
| Budget age 0 | 974 | 60.65 | 49.5 | 110.2 |
| Budget age 2 | 970 | 59.84 | 50.0 | 110.0 |

The count limit drives this result: four chunk preparations cost much less than the
two-millisecond soft limit on this fixture. The budget roughly halves total work by
combining changes while chunks wait. Minimum age 2 saves only four further builds
versus age 0. At 1, 32, and 128 fills/second it saves no builds while adding about
33 ms of scheduled age.

A separate burst changes all 27 chunks once in one nominal frame:

| Variant | Maximum measured frame CPU, ms | Maximum scheduled dirty age, ms | Build frames |
| --- | ---: | ---: | ---: |
| Dynamic immediate | 1.118 | 0 | 1 |
| Cache immediate | 1.688 | 0 | 1 |
| Budget age 0 | 0.263 | 100 | 7 |
| Budget age 2 | 0.262 | 133 | 7 |

For the immediate cache this burst has only one active sample per repetition. The
larger maximum versus dynamic is consistent with packing dirty sources in addition
to meshes in that frame; caching is not a guarantee that every update is cheaper.
No run exceeded 16.667 ms for this component. One cache-immediate 512 Hz repetition
had four frames above 2 ms, with a maximum of 2.820 ms; its other maxima were 0.889
and 0.577 ms. The small sample set cannot establish rare-stall rates.

All 60 runs passed exact final mesh/source and revision checks and produced the
same final-world checksum for each scenario. The raw logs also record target reads,
CPU record bytes, backlog, and drain frames. CPU record bytes are not measured GPU
traffic.

**Scope:** the replay directly applies accepted fills and records CPU publication;
it bypasses `Game` reconciliation, prepared GPU ownership, upload capacity, terrain
uploads, cancellation, and streaming. Dirty ages are fixed-tick ages sampled once
per chunk publication, not per edit. They omit actual build completion and display
time, and are not event-to-present latency. CPU overruns do not slow the input trace.
No full-game frame contains only this work, so staying below 16.667 ms here does not
prove a 60 FPS game.

## Renderer/cache comparison

The headless benchmark uses the production renderer, a 256×256 color/depth target,
32,000 or 320,000 miniature cells, 12 warmup frames, and 100 measured frames per run.
The 320,000-cell fixture is 100×100×32: it spans 16 chunks when aligned and 50 when
offset by 31 cells on all axes. Both paths receive the same camera and removal trace.
Cached sources are committed immediately, isolating the renderer from scheduling
and persistent publication waits.

CPU includes synthetic grouped-cell scanning/packing, source preparation/uploads,
uniform updates, command encoding, and submission. It excludes completion waiting.

| Scenario | Dynamic CPU p95, ms | Cached CPU p95, ms | Dynamic source bytes/frame | Cached source bytes/frame | Dynamic/cached draws/frame |
| --- | ---: | ---: | ---: | ---: | ---: |
| 32k, camera movement, 12 chunks | 0.154 | 0.024 | 1,536,000 | 0 | 1 / 12 |
| 320k, camera movement, 16 chunks | 2.158 | 0.030 | 15,360,000 | 0 | 1 / 16 |
| 320k, one changed chunk/frame | 2.151 | 0.073 | 15,357,000 | 309,178 | 1 / 16 |
| 320k, one quarter of chunks changed/frame | 2.149 | 0.167 | 15,348,000 | 1,263,495 | 1 / 16 |
| 320k, camera movement, 50 chunks | 2.231 | 0.060 | 15,360,000 | 0 | 1 / 50 |

Source bytes exclude transform uniforms: cached draws add 1,536, 2,048, or 6,400
uniform bytes per frame for 12, 16, or 50 chunks. Changed chunks remove one target
per attempt and conservatively rebuild their whole source. Cold cache seed calls
cost about 0.13 ms for 32k and 0.67–0.82 ms for 320k, excluding renderer initialization
and the completion wait.

The aligned 320k camera trace's serialized total p95 falls from 3.992 to 1.366 ms;
the 50-chunk trace falls from 8.047 to 1.361 ms. These totals include a GPU completion
fence **after every frame**. They are component wall times, not GPU timestamps,
steady-state pipelined frame times, or application FPS. The method intentionally
excludes terrain, site frames, UI, world hash lookups, service traffic, and full
publication ownership. Do not add its times to the separate CPU replay percentiles.

All 27 dynamic/cache final color-image pairs matched and were nonempty; no GPU
validation errors were reported. This is a final-image sanity check, not per-frame
visual correctness proof. The existing GPU readback suite separately exercises
color/depth parity and resource lifetimes in both wrapping modes.

The 320k run exposed a pre-existing dynamic allocation bug: `@min` inferred a `u21`
capacity, making `48 * 524288` overflow when growing the instance buffer. The baseline
and cached comparison both include the explicit `usize` capacity correction. This
correctness fix is not counted as a caching benefit. A 320k dynamic upload regression
compares visible color/depth against a two-instance reference.

## What remains unmeasured

Persistent publication retains old geometry while matching replacements wait for
snapshots, GPU capacity, or a current subscription lifetime. These cases are covered
by correctness tests, but neither benchmark exercises the complete lifecycle. Its
CPU overhead, memory pressure, streaming effects, and actual visual latency remain
unmeasured. For example, terrain capacity preflight scans resident allocations and
pending uploads and may run repeatedly in one application update; that cost is absent
from these harnesses. It is an investigation candidate, not a demonstrated bottleneck.

A decisive full-client comparison should replay the same accepted edits and camera
path with cache-immediate, cache-budget age 0, and current settings. Measure whole-frame
CPU/GPU p50/p95/p99, missed frame deadlines, event-to-visible age, backlog convergence,
and peak retained memory. Include quiet manual edits, busy local construction, a
streamed mesh ring around the local block core, travel/representation handoffs, and
capacity pressure. Run it on the target PC class with realistic competing simulation
and service load. The current local block core has 27 chunks; treating 343 locally
meshed block chunks as ordinary gameplay would overstate the default workload.

A policy-preserving ownership cleanup is possible independently of that experiment:
consolidate parallel per-chunk visual maps, centralize cancellation/retirement, and
make terrain-upload success explicit before miniature commit. Removing strict paired
publication could simplify further, but permits transient missing/overlapping visuals
and requires an explicit design decision. These results alone select neither change.
