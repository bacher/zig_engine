# Portable blueprint certificate admission

Date: 2026-11-08. Baseline: `47fd39d` (merged PR #52). Branch:
`codex/blueprint-certified-admission`, based directly on `main`.

## Rules and proof

Literal `stone` now supplies direct wood/mineral support and height/crushed-run
resets through a full centered 3×3×3 stable platform. All qualifying mixtures
remain allowed. Other natural-rock direct foundations, natural-rock crushed-bridge
sides, soil/sand footprints, road support and five-neighbor fulfillment retain
their existing rules. The fixed target-relative support window remains 28.

The old compiler could accept a reinforced staircase reaching a natural-stone
source at distance 28. Replacing that source with a full soil platform required
an off-center read at distance 29. An independent wood column can place the
failing target strictly inside the box while every occupied face target remains
valid, so face-only checks would not solve that mismatch. Under the new shared
rules, the compiler rejects that recipe because the complete stone platform must
fit inside the same window too.

For an accepted current-rule recipe, every virtual-foundation witness consists
of complete in-window platform cubes, eligible soil/sand footprint cells or road
support. Replacing virtual cells by any qualifying real platform mixture preserves
those witnesses. Other natural rocks can add cheaper routes. Translation and
quarter-turn rotation preserve material connectivity and window distances; the
existing short wrapped footprint prevents target aliasing. Additional real/planned
contents fill isolated air, so the existing finite-addition argument preserves
both certified new targets and old valid roots. The [specification proof](../../specs/features/blueprints.md#portable-certificate-admission)
states the assumptions and exceptions.

Apply therefore retains physical empty/immutable/overlap/bounds/platform checks
and complete box-index sources, but performs zero structural target/dependent
searches. Snapshot input shrinks to rotated box plus XY ±1/downward 3. Whole-box
cavity sources and their revision gates remain. Mutation FIFO, asynchronous
preparation, source/journal waits, publication and resource/progress accounting
retain their existing behavior. This does not implement PR #48.

World write/minimum-readable version 5 rejects older development worlds and their
weaker certificates through the existing base/WAL gates. No migration, per-recipe
version or load recertification is added. The internal Apply contract trusts
normal immutable compiler/library contents; shape validation alone does not make
a fabricated definition certified.

## Verification

Focused Debug verification passed:

- Shared-rule module: 43 tests, covering isolated/full/mixed stone foundations,
  missing platform corners/data, removal protection, lateral alternatives, resource
  shortcuts, crushed bridges, roads/footprints and fixed-window boundaries.
- `zig build test-blueprint-admission -Doptimize=Debug --summary all`: 94 tests.
- `zig build test-world -Doptimize=Debug --summary all`: 320 tests.
- `zig build test-blueprint-service -Doptimize=Debug --summary all`: 537 tests.

The admission differential matrix compiles two actual recipes, including the
concrete-support fallback, and tests four rotations at two origins (16 cases).
It independently enumerates the whole resident world and validates every new
target with both fresh and shared ordinary-validator caches. Narrow and full
snapshots must produce the same semantic instance, targets, footprint indexes and
retained memberships. Mixed real platforms cover every qualifying material.
Missing platform/cavity sources reject, and existing service tests preserve
support/cavity/global-overlay revision rejection without partial publication.
The old reach-28 recipe now rejects at compilation; a separate reference still
demonstrates why checking only occupied faces would miss its interior failure.

`zig build install test test-blueprint-admission -Doptimize=ReleaseFast --summary all`
passed all 58 build steps: **1,942 tests passed, eight existing skips**. Both
applications build. The persistence suite rejects the immediately previous
development version through both base and WAL gates and retains current-version
round trips. Multi-site tests retain zero ordinary-validator calls and at most
five physical support reads per fulfillment. Formatting, diff checks, spec schema,
local document links and independent code/proof/document reviews passed. No
graphical behavior changed in this follow-up.

## Measurement method

Environment: Apple M4 Max, macOS 26.7.1, Zig 0.16.0, ReleaseFast. The baseline is
an archive of `47fd39d`. Copy this revision's `blueprint_benchmark.zig` and
`block_placement_benchmark.zig` into that archive, retaining its original production
region collector and rules. The identical harness detects the admission API at
compile time; this adds no runtime game rule selector. The ordinary mixed-route
fixture uses limestone for its explicit single-cell source in both versions;
flat stone foundations in the other workloads still measure the new cube cost.

For each benchmark, warm both versions, then run three alternating pairs, reversing
pair 2. No test or build job ran concurrently with timed cases. Report medians of
the three runs. Raw [admission runs](blueprint-certified-admission-benchmark.txt)
and [ordinary-placement runs](blueprint-certified-placement-benchmark.txt) include
sample order, commands and common harness hashes. Use these commands in each tree:

```sh
zig build bench-blueprint -Doptimize=ReleaseFast -- --admission-only --sample baseline-1
zig build bench-placement -Doptimize=ReleaseFast
```

Do not use `--legacy-region` for this baseline: `main` already uses the smaller
XY ±28/downward 28 collector from PR #52.

Admission measures the same sparse/dense 100×100×32 definitions at `(87,87,87)` in
a 256³ world, with 384 resident source chunks and real stone at Z=84…86. Neighbor
cases have no nearby constructions, 14,336 real rebar cells, or 14,336 pending rebar
targets in six nonoverlapping sites. Definitions and resident-world setup are
excluded. Timed stages are detached region collection, snapshot cloning and helper
preparation. They exclude loading/generation, service scheduling, journal/source
waits, final preflight/publication, persistence, client meshing and rendering.
These are helper measurements, not whole-server throughput or FPS measurements.

## Admission results

| Definition | Neighbors | Snapshot copy before → after, ms | Helper prepare before → after, ms |
| --- | --- | ---: | ---: |
| sparse | none | 0.183 → 0.053 | 6.597 → 3.521 |
| sparse | real | 0.066 → 0.019 | 6.521 → 3.340 |
| sparse | planned | 0.288 → 0.114 | 6.816 → 3.497 |
| dense | none | 0.072 → 0.022 | 334.482 → 27.864 |
| dense | real | 0.072 → 0.025 | 326.791 → 27.161 |
| dense | planned | 0.275 → 0.115 | 331.193 → 28.020 |

All cases reduce snapshot input from **108 to 32 chunks**, retaining the same
**32 footprint chunks** and **31,212 physical platform reads**. Structural target
checks fall from 10,110/320,000 to zero; existing-dependent checks remain zero.
Sparse helper time falls by 47–49%; dense helper time falls by about 92% (roughly
12× faster). Building the target indexes/publication still costs O(N).

Snapshot requested ownership falls from **3,564,824 to 1,055,064 bytes** without
planned neighbors (70.4%) and **4,571,748 to 1,508,264 bytes** with planned neighbors
(67.0%). These are requested owned bytes, not backing allocator pages or RSS.
Retained publication ownership is unchanged: 977,240/1,512,192 bytes for sparse
and 25,397,160/26,234,968 bytes for dense without/with planned neighbors. Full
footprint-index cloning remains necessary. All allocation/counter assertions pass.
The unchanged four-chunk copy slice needs eight rather than 27 turns for this
resident case; this is a work-count consequence, not measured service latency.

## Ordinary-placement cost

| Workload | Reader calls before → after | Median before → after, µs/check |
| --- | ---: | ---: |
| 25 six-cell crushed columns | 604 → 793 | 26.836 → 34.952 |
| Nine run-six crushed bridges | 1,850 → 2,363 | 81.560 → 103.295 |
| Direct + two bridge routes, root only | 1,865 → 2,378 | 83.133 → 103.103 |
| 20-cell independently bridged column | 3,563 → 3,752 | 150.856 → 158.002 |
| Unsupported seventh cell, rejected | 188 → 188 | 8.619 → 8.758 |
| Synthetic unsupported side rails, rejected | 3,055 → 3,354 | 134.424 → 148.760 |

The new platform proof has a measurable ordinary-validation cost: the accepted
crushed workloads above increase by about **5–30%**, or **7–22 µs/check**. The
synthetic rail case is deliberately invalid and is not a worst-case bound. The
plank insertion beside a 200-block building now makes **30 rather than three
reader calls**, including its full stone cube. Its rounded harness time is about
2 rather than 1 µs; the 1-µs output precision does not support a precise timing
ratio. Ordinary insertion does not revalidate all 200 old cells. The unchanged
placement-cache medians remain about 0.013–0.014 µs for eight chunks and 0.074 µs
for 27 chunks; small timing differences there are not an established regression.

The separate 200-block dependent-removal reader-count regression increases from
42,384 to 43,086 reads (1.66%), within its unchanged 200,000-read budget. This is a
different workload from the insertion above, not a global performance estimate.
Blueprint fulfillment keeps its existing physical-neighbor path and never runs
these cube/height/span searches, so this ordinary-validation tradeoff adds no
per-fill structural work to mass construction.

## Review follow-ups

### Shared platform geometry

`block_rules.Platform` now defines the compile-time XY radius, width, depth and
derived cell count. The structural validator/diagnostics, isolated compiler,
physical bottom-platform guard and snapshot collector share these values.
Traversal order, reads and the captured envelope are unchanged; soil/sand
footprints and unrelated support limits remain separate. Test expectations keep
literal coordinates/counts so they independently guard the 3×3×3 contract.

`zig build test-blueprint-admission test-world -Doptimize=Debug --summary all`
passed all 18 steps and 414 tests. Formatting, diff checks and independent review
passed. This refactoring adds no runtime work; the paired measurements above
remain the evidence for the original implementation at `b4065d9`.
