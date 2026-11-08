# Target-only blueprint admission: validation

Historical report for PR #52. Current Apply behavior and measurements are recorded
in [portable certificate admission](blueprint-certified-admission.md).

Date: 2026-11-08. Baseline: `b73e671` (merged PR #51). Branch: `codex/blueprint-target-only-admission`.

This follow-up removes existing-dependent enumeration from Apply and stops copying construction-marker lists used only by that pass. Detached admission also omits road geometry, which structural validation does not read; road block materials remain in the snapshot. New completed targets and full physical bottom platforms are still validated. The service uses a shared pure region collector: the rotated box expanded by 28 along X/Y and downward, with no upward support extension, rounded to canonical deduplicated chunks. Every whole box record remains available for publication, including cavities.

The mutation FIFO, chunk/global-overlay version checks, retries, atomic publication, inventory/progress accounting, persistence and five-neighbor fulfillment retain their existing behavior. This does not implement the hybrid admission/scheduling design in PR #48.

The [batch argument](../../specs/features/blueprints.md#monotone-batch-admission) explains why existing support witnesses survive the complete addition without an ordinary-legal intermediate fill order. It preserves already-valid roots; it does not certify or repair pre-existing invalid surroundings.

## Correctness

Original focused Debug verification at `6fbf948`:

- `zig build test-blueprint-admission -Doptimize=Debug --summary all`: 84 tests passed.
- `zig build test-blueprint-service --cache-dir /private/tmp/blueprint-target-admission-zig-cache --summary all`: 532 tests passed.

The admission fixtures compare old real/planned roots before and after the whole proposed overlay using fresh and shared validator caches. They cover both crushed-bridge orientations and six-cell prefixes, independent plank/mixed-reinforced routes at height limits, earth/sand footprints, roads, water/snow and cavity contents. All allowed new materials retain target checks; malformed support, occupancy, missing data, immutable targets, overlap, physical-platform and allocation-failure cases remain guarded.

Region fixtures cover all four rotations, exact chunk boundaries, wrapped-X seams and deduplication before the cap, finite Y/Z clipping, bottom platforms and cavity-only publication sources. The service fixture checks full-index preservation and rejection after support-only chunk, cavity-index chunk or global-overlay revision changes, with no partial instance or journal mutation.

The review follow-up adds a differential fixture using the production collector and an independently enumerated whole-world snapshot of the same 128³ resident world. Eight rotation/translation cases exercise a 28-cell reinforced support route at chunk edges and the X seam. An upper target depends on its outermost source chunk; a separate lowest target has a full physical platform. Both snapshots must accept with the same semantic instance, footprint, target identities/materials and retained index memberships, or reject a broken source with the same code. Removing the required outer chunk from only the narrow snapshot must also reject. The restored, well-formed test definition deliberately needs external support, so internal blueprint support cannot hide a collector omission.

Road geometry independence is covered by the existing structural-rule fixture that panics if its shape callback is read, across road/custom supports and nine target material families. Removing the detached road slice removes its clone/free/accounting and the unused shape callback together; block materials, immutable masks, complete indexes and revision checks remain.

## Benchmark method

The ReleaseFast admission harness uses the same 100×100×32 sparse/dense definitions at `(87,87,87)` in a 256³ world. Real stone foundations occupy Z=84…86. Resident source setup and definition compilation are excluded from the measured region collection, snapshot copying and helper preparation stages. Snapshot copying clones complete chunk data and planned indexes; only the baseline clones constructed-marker lists. The compiler-only matrix can be skipped with `--admission-only`.

The three neighbor cases are empty surroundings, 14,336 real rebar cells, and 14,336 pending rebar targets in six nonoverlapping rectangular sites. The ring lies at Z=87, XY=59…214 outside the new box's XY=87…186 footprint; all cells have real platforms. Planned targets include complete lookup/list/instance entries and valid slots. Both versions preserve full-index cloning for the new site's footprint chunks.

For comparison only, `--legacy-region` selects the old symmetric 56-block collector inside the benchmark; production always uses the target-only collector. The harness detects the baseline snapshot's constructed-marker field at compile time so the same benchmark source compiles against both revisions. This adds no runtime game ruleset or admission switch.

Run environment: Apple M4 Max, macOS 26.7.1, Zig 0.16.0. Each version had one warmup; three measurement pairs alternated version order, with pair 2 reversed. No test/build job ran concurrently with timed cases. Reported timings are medians of three runs, rounded to microsecond resolution. Requested ownership excludes backing allocator pages and is not RSS. All counter and leak assertions passed. [Raw runs](blueprint-target-admission-benchmark.txt) include warmups and sample labels.

To reproduce, run the current harness with:

```sh
zig build bench-blueprint -Doptimize=ReleaseFast -- --admission-only --sample target-1
```

For the baseline, archive `b73e671` into a separate directory, copy this revision's `blueprint_benchmark.zig` and `blueprint_admission_region.zig` into its `src/voxel_app/`, and run:

```sh
zig build bench-blueprint -Doptimize=ReleaseFast -- --admission-only --legacy-region --sample baseline-1
```

## Paired results at `6fbf948`

These paired measurements predate the review follow-up removing the road-geometry slice from each snapshot record. The fixtures contain no road records; they do not measure the saving from avoiding road-record copies in road-rich chunks. The current harness verification is recorded separately below.

All six cases reduce input from **384 to 108 chunks**, retaining **32 footprint chunks**, **31,212 physical foundation reads**, and **10,110 / 320,000 validated new targets** for sparse/dense designs. Existing dependent checks change from 14,336 to zero in the real/planned-neighbor cases. No-neighbor cases had zero dependents in both versions.

| Definition | Neighbors | Snapshot copy before → after, ms | Helper prepare before → after, ms | Snapshot requested before → after, MiB |
| --- | --- | ---: | ---: | ---: |
| sparse | none | 0.602 → 0.190 | 6.252 → 6.451 | 12.065 → 3.404 |
| sparse | real | 0.191 → 0.062 | 8.609 → 6.198 | 12.092 → 3.404 |
| sparse | planned | 0.406 → 0.270 | 9.058 → 6.352 | 13.025 → 4.364 |
| dense | none | 0.244 → 0.071 | 329.216 → 322.810 | 12.065 → 3.404 |
| dense | real | 0.247 → 0.074 | 323.545 → 320.915 | 12.092 → 3.404 |
| dense | planned | 0.435 → 0.275 | 324.827 → 323.230 | 13.025 → 4.364 |

No-neighbor snapshot ownership falls from 12,651,032 to 3,568,920 bytes (71.8%); real-neighbor copies also omit 28,672 bytes of constructed markers. Planned-neighbor indexes still need cloning: ownership falls from 13,657,956 to 4,575,844 bytes (66.5%), while complete footprint index contents are retained. Region collection takes roughly 5–7 µs after the change versus 11–17 µs before it in these medians.

Sparse helper preparation with existing neighbors improves by about 28–30%. Dense preparation remains around 321–329 ms because validating 320,000 new targets and building their publication still dominate; differences of roughly 1–2% here are too small to treat as a demonstrated helper speedup. The sparse no-neighbor helper median rises from 6.252 to 6.451 ms, within the 6.100–7.119 / 6.200–6.957 ms observed ranges; its snapshot copying improves. There is no claim of a uniform helper-time reduction in every case.

The unchanged four-chunk-per-turn copy budget would require 27 rather than 96 copy turns for this fully resident input. This is a work-count consequence, not a measured service latency. Timings exclude source loading/generation, world-service scheduling, journal/source waits, final version/recipient preflight, authority publication, client copies/meshing/rendering and persistence. They do not establish whole-server throughput or FPS. Helper peak and retained publication allocations remain dominated by the new target index and are recorded in the raw output.

## Full verification at `6fbf948`

`zig build install test test-blueprint-admission -Doptimize=ReleaseFast --summary all` passed all 58 steps: **1,912 tests passed, eight existing tests skipped**. Both applications build. Focused Debug suites above additionally exercise allocation failures and service behavior. Formatting, diff checks, spec schema/stable IDs and local document links were checked before publication. No graphical playtest was needed for this service/helper-only change.

## Review follow-up verification

- Focused Debug admission suite: **90 tests passed**, including the differential matrix and the collector tests it imports.
- Focused Debug service suite: **533 tests passed**.
- `zig build install test test-blueprint-admission -Doptimize=ReleaseFast --summary all`: **58 steps succeeded, 1,926 tests passed, eight existing skips**; both applications build.
- Formatting and diff checks passed.

All six current ReleaseFast benchmark cases passed counter and allocation-cleanup assertions. They retain 108 source chunks, 32 footprint chunks, 31,212 platform reads and the same target/dependent counts. Snapshot requested ownership is now **3,564,824 bytes** without planned neighbors and **4,571,748 bytes** with planned neighbors: 4,096 bytes less than `6fbf948` in each case because the snapshot records no longer contain a road slice. The fixtures contain no road records; avoiding the additional record copies and nonempty-slice allocations in road-rich chunks is not timed here. No new runtime validation or traversal is added.

The [current raw run](blueprint-target-admission-review-benchmark.txt), sample `review-follow-up`, is a single harness verification after the test jobs finished, without a dedicated warmup or paired baseline. Its timings are not used to claim a further speedup; the paired results above remain attached to their measured revision.
