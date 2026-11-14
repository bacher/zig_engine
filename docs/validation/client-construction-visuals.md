# Windowed client construction benchmark

This opt-in benchmark runs the voxel application's real update, terrain, miniature,
upload, and draw paths. `immediate` retains the same FIFO and miniature cache while
removing the preparation budget limits. `budgeted` uses the production defaults:
four whole chunk visits per update, a two-millisecond soft preparation budget,
and no minimum queue age. One visit can exceed the time budget. This comparison
isolates budget limits within the current implementation; it does not measure the
whole change against an earlier client. Direct accepted service meshes and terrain
GPU uploads remain outside the preparation budget.

## Run

Build once, then run the Python standard-library driver from the repository root:

```sh
zig build install -Doptimize=ReleaseFast
python3 scripts/benchmark_client_visuals.py
```

The driver opens real windows sequentially. Keep the desktop unlocked and each
client window focused until it exits. It defaults to 512 intended fills/second for
eight whole seconds, three repetitions for each of `orbit` and `travel`, with
policy order AB, BA, AB per camera. It creates a retained temporary output directory
and prints its path. For a shorter or differently sized run:

```sh
python3 scripts/benchmark_client_visuals.py --camera orbit --repetitions 1 --rate 512 --duration 8 --output-dir /tmp/client-visuals-run
```

`--output-dir` must be empty. `--binary` selects another installed ReleaseFast client;
the driver does not build it. `--timeout` overrides the per-process timeout, which
defaults to `max(120, duration * 4 + 60)` seconds including startup and draining.
Input bounds are 1–8,192 fills/second, 1–60 integer seconds, and at most 65,536
fills (`rate * duration`). Repetitions must be positive. The client also reserves
at most 65,536 active frame samples and rejects a run that exhausts them.

The equivalent single-client command is:

```sh
zig-out/bin/zig_engine_voxel_app --benchmark-visuals /tmp/client-visuals-immediate --visual-policy immediate --benchmark-rate 512 --benchmark-duration 8 --benchmark-camera orbit
```

Change the policy to `budgeted` for the other arm. Direct-client defaults are
`budgeted`, `orbit`, 512, and 8. Benchmark mode implies a fresh ephemeral flat world;
its CLI accepts only the benchmark option/value pairs, without saved-world flags.
The parent directory of the output prefix must exist. The client requests a
960×540 logical window; a 2× Retina display produces 1920×1080 physical pixels.
Compare the recorded physical `resolution`, which the driver requires to match.

## Fixture and readiness

Each launch creates the same 16×16×4-chunk flat world, without persistence or the
ordinary simulation worker. A separate public service endpoint saves and applies
nine identical blueprints, then submits ordinary batched fulfillment operations;
the game receives normal authoritative subscriptions. Each site has 28×28×49
cells with three-cell-thick rebar walls: 14,700 targets/site, 132,300 total. The
3×3 site arrangement spans 27 chunks. Fills visit matching cells round-robin across
the nine sites in bottom-up order. The default 4,096 fills complete the first
2,700-cell wall course and part of the second.

Warmup requires at least one uninterrupted second with window focus, all loaded
subscriptions satisfied, no pending packages/preparations/uploads, current-token
block snapshots backed by client chunks, and all 132,300 target miniature sources
cached. Readiness resets when these conditions change. Warmup times out after
60 seconds; fixture setup has a separate 60-second deadline. Losing focus,
changing physical resolution, or reducing the render radius invalidates the run.

Arrivals follow elapsed wall time rather than frame count. Busy admission retains
the due backlog; at most 256 operations are outstanding. After input duration,
the client drains acknowledgements and both visual representations, with a
30-second drain allowance. Camera motion is deterministic from elapsed time;
`travel` crosses chunk boundaries and returns to its center position during drain.
Final verification requires every planned fill accepted, correct client block
materials, the exact remaining miniature count, no unresolved visual observations,
and a checksum of the filled cells/materials. The driver stops on invalid runs or
workload, checksum, or resolution differences across repetitions and policies.
Different frame counts are expected for these equal wall-time workloads.

## Timings and artifacts

Active frame samples are buffered in memory and exported after the run; warmup
and later drain-only frames are excluded. Per-event latency samples can finish
during drain. Benchmark mode suppresses ordinary per-upload diagnostic logging.
Summary percentiles use nearest rank; the driver reports medians of per-run
statistics without pooling frames.

| Field | Meaning |
| --- | --- |
| `interval` | Start-to-start host frame interval, including the previous observation callback and loop overhead. |
| `frame` | Poll/update/draw/resize/input-flush elapsed host time, ending before the observation callback. |
| `update`, `draw` | Host update and full draw call; draw includes submit and present calls. |
| `prepare`, `upload` | Host time around the visual preparation pass and terrain `uploadToGPU` call. |
| `terrain_submit_latency`, `miniature_submit_latency` | Client fulfillment receipt to the first submitted chunk representation carrying the corresponding update. |
| `acceptance_window_seconds` | Maximum of configured input duration and the latest collected acknowledgement time minus input start. |
| `accepted_edits_per_second` | Accepted count divided by that acceptance window, including acknowledgement backlog. |

Submission latency ends at the engine's actual host `submitted_ns`, captured after
`gctx.submit` returns and before `present`. Chunk watermarks track independently
prepared terrain/miniature contents; coalesced fills can share a submission.
Chunks can be offscreen or occluded: this is chunk representation submission
latency, not first visible-pixel or physical display latency. All timings are host
elapsed measurements, not GPU execution timestamps. There are no added GPU fences
or readbacks. Throughput describes this finite workload, not maximum service capacity.

Each prefix produces `.summary.json`, `.frames.csv`, and `.events.csv`; the driver
also retains a combined stdout/stderr `.log` per launch and `report.json`. Frame
CSV includes poll/update/draw/submit/present, fulfillment, preparation, upload, and
queued-chunk samples in nanoseconds. Event CSV includes scheduled, admitted,
acknowledged, received, and both submission timestamps. Summary reports p50/p95/p99,
maximum and mean, frame counts above 16.67/33.33 ms, end-of-frame peak queue count,
drain time, edit counts, physical resolution, checksum, and validity. Threshold
counts use `frame`, not `interval`. The driver verifies latency sample counts equal
accepted edits and checks reported throughput against accepted count/window.

## Validation status

`zig build install test -Doptimize=ReleaseFast -j4 --summary all` passed 58/58 steps,
2,041 tests, with eight skips. Debug tests passed 50/50 steps, 2,048 tests, with
one skip. Zig regressions cover bounded CLI parsing, wall-time scheduling and
fixture certification, public service admission/fulfillment, independent coalesced
watermarks, and actual block contents after representation handoffs.

```sh
python3 -m unittest discover -s scripts -p 'test_benchmark_client_visuals.py' -v
```

All 22 Python tests pass. They cover strict summary validation, complete workloads
and latency observations, acknowledgement-window throughput, checksum/resolution
equivalence, medians, execution order, and client argument bounds/formatting.

## Windowed results — 2026-11-14

The [retained report](../benchmarks/client-visuals-2026-11-14/report.json) contains
12 successful ReleaseFast runs at commit `4ece726`, on Apple M4 Max, 16 CPU cores,
64 GiB RAM, Metal, macOS 26.7.1, Zig 0.16.0, and a 1920×1080 framebuffer. The default
driver command ran sequentially with no concurrent builds or tests. Each camera used
three repetitions per policy in AB/BA/AB order, with 512 intended fills/second for
eight seconds. These are medians of per-run statistics; each reported maximum is
the median of the three run maxima.

Every run accepted all 4,096 planned commands, rejected none, and resolved all 4,096
terrain and 4,096 miniature latency observations. All final checksums were
`5f17fb35aea0ce85`; resolution and logical/miniature final state matched. Independent
raw-data verification recomputed all reported quantiles from 11,520 frame rows and
49,152 event rows and checked timestamp ordering, frame nesting and threshold counts.
There were no focus, resolution, timeout or render-radius invalidations. The earlier
locked-desktop smoke failure was excluded; a fresh unlocked smoke run also passed.

| Camera | Policy | Preparation mean, ms | Preparation p95, ms | Interval p95, ms | Interval p99, ms | Terrain latency p95, ms | Miniature latency p95, ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Orbit | Immediate | 2.068 | 2.820 | 10.814 | 12.443 | 10.706 | 10.706 |
| Orbit | Budgeted | 1.957 | 2.069 | 10.993 | 12.438 | 24.758 | 24.758 |
| Travel | Immediate | 1.932 | 2.551 | 10.572 | 11.039 | 10.462 | 10.424 |
| Travel | Budgeted | 1.752 | 2.080 | 10.976 | 12.556 | 26.140 | 27.314 |

Budgeting reduced preparation p95 by 26.6% in orbit and 18.5% in travel; mean
preparation fell by 5.4% and 9.3%, respectively (about 0.11/0.18 ms per frame).
The complete client showed no pacing improvement: both policies ran near 120 host
frames/second, orbit interval p99 was effectively unchanged, and travel interval
p99 was higher with budgeting. All immediate runs had zero active frames over
16.67 ms; every budgeted travel run had one. No arm had frames over 33.33 ms.
Three short repetitions do not establish a general frame-pacing regression either.

Receipt-to-submission p95 increased from roughly 10–11 ms to 25–27 ms. In travel,
budgeted terrain/miniature p99 reached 75.7/77.4 ms; the medians of run maxima were
135.2/156.6 ms. These tails also occurred during active travel, not only at its end.
The median final drain was 24.8 ms immediate versus 183.7 ms budgeted; the median
end-of-frame sampled queue peak was 0 versus 73. All queues converged.

Observed accepted throughput was about 511.4 commands/second for both policies on
this finite input stream. This does not measure maximum service capacity. Host
draw/submit timings also do not identify a GPU bottleneck or physical display rate.

The result supports smaller preparation spikes with added graphical delay. It does
not demonstrate improved whole-client smoothness or simulation throughput. On this
evidence, defer merging the scheduling PR until a representative workload demonstrates
a material client benefit, particularly on the proposed 4–8-core reference hardware.
The GPU miniature cache already merged in PR #58 has separate component evidence.
This recommendation does not change the proposed default budget in the open PR.

Raw CSVs, individual summaries and logs are in the checksummed
[archive](../benchmarks/client-visuals-2026-11-14/raw.tar.gz); the
[run table](../benchmarks/client-visuals-2026-11-14/runs.csv),
[manifest](../benchmarks/client-visuals-2026-11-14/manifest.json) and
[runner output](../benchmarks/client-visuals-2026-11-14/runner.log) accompany it.
