# Additive block rules: validation

Date: 2026-11-08. Branch: `codex/monotone-block-additions`, based on
`72880e8` (`origin/main` when the branch was created). See the
[feature spec](../../specs/features/monotone-block-additions.md).

The original checks and timings below describe commit `8b5e47a`. The road follow-up at the
end of this report supersedes its fixed-road-shape assumption and road-shape validation;
the recorded measurements remain historical evidence for that commit.

## Scope and reasoning

With unchanged road shapes and support data, adding to an empty cell cannot remove a
previously valid support witness. Footprints/platforms use positive occupancy predicates;
wood/reinforced connectivity retains its old routes. Direct recursion decreases Z, and
same-level routes require direct sources rather than self-supporting cycles. Selecting the
minimum height prevents a newly available route from increasing inherited height.

Crushed stone has a separate geometric run test. Previously, filling air below an existing
bridge could extend that run past six before the bridge was considered. The bounded scan
now recognizes the existing independent bridge as an endpoint. This retains the witness
which supported the earlier short column. The mineral counter still inherits the minimum
eligible route; a bridge is not an unconditional mineral reset. Bridge-side eligibility is
unchanged.

The new fallback examines at most six bridge positions, each with two orientations and two
direct side sources. Known short columns take the existing geometric path without these
extra probes. Recursive evaluated dependencies remain below the bridge, all probes use the
existing read/evidence machinery, and the successful cache-entry representation is unchanged.

This does not establish that every legal target passes all edit preconditions: dependent
checks can still conservatively reject when their edit/root window intersection hides an
old support. Existing composed admission, dependent checks, road-shape validation, and
snapshot halos remain. Removals/replacements require their ordinary checks. No save format
or migration changes were needed.

## Correctness checks

The focused Debug run passed **968/968 tests**:

```sh
zig build test-world test-blueprint test-blueprint-admission test-blueprint-service -Doptimize=Debug --summary all
```

The final source expands the core matrix to **264 scenarios**: two translations (including
the wrapped seam where enabled), both bridge axes, six heights, and eleven placeable
materials. Each scenario fills the gap below a valid crushed column, then checks each old
cell with fresh and shared caches in both traversal orders. Flat worlds use a second
interior translation. Separate regressions exercise worse newly available bridge/direct
routes at the mineral-height boundary, missing lower data with a known bridge, and failure
when the required independent sides are absent.

World tests preview and optimistically commit supported seventh bridges above six pending
targets without changing their progress. Water/snow and sand are committed in both orders,
with and without active sites. Removing required bridge sides or sand-footprint cells is
still rejected atomically. Detached admission accepts both real and foreign pending bridges
and preserves existing terrain/targets; broken-side controls still reject. Existing tests
retain unsupported seven-cell rejection, span/height/footprint limits, missing/window/cache
bounds, road-shape guards, authority inventory, and restart coverage.

Final verification passed: **58/58 build steps**, **1,861 tests passed, 8 skipped** out
of 1,869. Both applications built successfully. The CPU suite includes both engine topology
configurations; construction rules run through the voxel application's wrapped engine.
Seven skips are debug-teleport tests disabled in ReleaseFast; one is a wrap-only coordinate
test in the flat configuration. GPU execution was not needed for these structural changes.

```sh
zig build install test test-blueprint-admission -Doptimize=ReleaseFast --summary all
zig fmt --check src/voxel_app/block_rules.zig src/voxel_app/world.zig src/voxel_app/blueprint_admission.zig src/voxel_app/block_placement_benchmark.zig
git diff --check
```

## CPU measurements

Command: `zig build bench-placement -Doptimize=ReleaseFast`, Zig 0.16.0, same local Mac.
Three baseline/current pairs ran sequentially without concurrent test builds. The baseline
is exact `72880e8` with only the added benchmark fixtures copied in, omitting the new-only
20-cell reset fixture. Common inputs are accepted by both versions. Each crushed sample
contains 100 fresh validation checks; there are eleven samples per process. The table uses
the median of the three process medians, with deterministic reader calls per validation.

| Workload | Reads before → after | Median µs before → after |
| --- | ---: | ---: |
| 25 plain six-cell crushed columns | 5,460 → 5,460 | 236.533 → 238.540 |
| Nine run-six crushed bridges | 2,257 → 2,262 | 98.934 → 99.894 |
| Direct and two bridge routes, root only | 1,845 → 1,865 | 78.903 → 79.645 |
| New 20-cell independently bridged column | unsupported before; 3,563 after | 148.663 after |

The common crushed workloads changed by about 1% in these measurements. Plank validation
retains 42,386 reads, with paired process medians of 2.242–2.320 ms before and 2.241–2.283 ms
after. The eight-/27-chunk unchanged-preview cache checks remain about 0.013–0.014 µs and
0.072–0.073 µs respectively. These local synthetic measurements do not bound full simulation
throughput or worst-case latency. The newly explored fallback on rejected long columns is
bounded as described above but is not included in these timing fixtures.

[Raw paired outputs](monotone-block-additions-benchmark.txt) retain all measurements.

## Shape-neutral road follow-up, 2026-11-08

Formed slopes and unformed adaptive roads now provide identical structural support. All
support rules depend on material rather than road geometry. Roads still support roads;
wood, mineral, earth, and stable-platform material families are unchanged. Shape transitions
therefore retain existing support witnesses while changing render/collision geometry.
Overhead obstructions use ordinary collision behavior and do not veto slope formation.

Removed the final road-plan structural validation from preview, ordinary publication,
optimistic replay, and deferred processing. The planner still checks candidate patterns,
section support, ownership, and immutable writes. Deferred publication retains read-error
and discovered-dependency waits, source holds, capacity reservations, checked revisions,
persistence, and atomic commit. Ordinary material admission/removal still checks dependents.
Optimistic replay retains its existing intent/occupancy policy; authority remains the source
of material admission, with no new full-validation pass added to each replay.

The target-support invariant is documented at `Validator.checkPlacement` and in the rules
and feature specs: fixed Chebyshev XY radius 28, at most 28 below, and zero above the target.
A supported seven-floor reinforced staircase reaches its only foundation 28 cells away,
so radius 20 or 24 would remove allowed arrangements. Recursive searches do not recenter.
This is the target's support proof, not the whole operation: existing dependent checks can
still read above the edited block. Road discovery reads endpoints, candidate sections, and
immediate support; a low-endpoint edit may discover a road one level above that edit, without
reading above that road. Blueprint admission checks and snapshot halos remain unchanged.

| Coverage | Evidence |
| --- | --- |
| Unchanged material families, no geometry callback | Core regression uses a callback that panics if structural validation queries shape; only road targets accept immediate solid/adaptive/custom-road support in the isolated fixture. |
| Formation/reversion and removal | Stacked solid/adaptive roads remain supported through lower-road formation and reversion; removing a required support still rejects. An upper adaptive run can form above a formed run. |
| Planner/replay read bounds and guards | Instrumented formation and saved replay succeed when all above-road cells are unreadable, with zero above-road reads and zero reads beyond 14 XY cells of the edit. Immutable member writes fail without partial mutation. |
| Integration | Ordinary preview/commit, fresh-baseline replay, actual client/authority convergence, and deferred publication preserve real overhead roads and planned-target identity/progress. An unrelated invalid construction in the former shape-validation halo no longer vetoes formation. Source-held deferred work waits and resumes. |
| Queue/persistence and throughput | Full service suite retains fair bounded queue processing, saved unfinished obligations, recovery, reservations, and five-neighbor fulfillment regressions. The 128-site fixture verifies 8,192 fills, exactly 8,192 support reads, zero ordinary-validation calls, and 512 road seeds in both dense/spread layouts. |

Focused Debug verification passed **892/892 tests**: 300 world, 77 admission, and 515 service.
Final ReleaseFast verification passed **58/58 build steps**, **1,861 tests**, with eight
existing skips. Both applications built. Target totals overlap through imports and must
not be interpreted as distinct gameplay scenarios.

```sh
zig build test-world test-blueprint-admission test-blueprint-service -Doptimize=Debug --summary all
zig build install test test-blueprint-admission -Doptimize=ReleaseFast --summary all
zig fmt --check src/voxel_app/block_rules.zig src/voxel_app/roads.zig src/voxel_app/road_tests.zig src/voxel_app/world.zig src/voxel_app/world_data_service.zig
git diff --check
```

The existing resident throughput fixture reported 7.690–7.935 ms for 8,192 fills and
4.336–4.667 ms for 512 road seeds across its two imported runs and dense/spread layouts.
The dense layout took 33 processor turns/520 work units; the spread layout took 40/640,
with a 16-unit budget. These are observations from the full build, without paired warm
baseline measurements; they do not demonstrate a timing improvement. Deterministic read
checks establish removal of the above-road and surrounding structural work. No per-fill
work, serialized state, collision geometry, or GPU code was added. GPU execution and
interactive gameplay were not rerun for this follow-up.
