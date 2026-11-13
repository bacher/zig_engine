# Blueprint compiler and admission measurements

Measured on Apple M4 Max, arm64, macOS 26.7.1, Zig 0.16.0, ReleaseFast.
These are individual synthetic fixture runs, with no discarded warmup or tail
latency estimate. They establish helper costs for the stated contents; they do
not establish application frame latency or a complete capture/application SLO.

```sh
zig build bench-blueprint -Doptimize=ReleaseFast \
  --cache-dir /private/tmp/zig-blueprint-local \
  --global-cache-dir /private/tmp/zig-blueprint-global
```

The runner is `src/voxel_app/blueprint_benchmark.zig`. Its allocation meter counts
requested live allocation bytes and allocation calls. It excludes backing
allocator page overhead and is not RSS. `helper_peak_requested` includes retained
output, so retained bytes must not be added to that peak.

## Compiler

The compiler receives a borrowed, dense, x-fastest block array. Each cell is one
byte. The configured raw selected-volume limit is 1,048,576 cells, including air;
the validator cache limit is 8,192 entries. A successful cache entry is 128 bytes;
the complete failure diagnostic type is 1,088 bytes and rejection details use a
separate bounded pool. The benchmark has a ten-second cancellation watchdog,
which is a runner guard rather than a runtime latency promise.

The sparse fixture has a full rebar ground floor and two rebar towers, with
included reinforced-concrete platform resets. Dense contents are all rebar.
Invalid contents are all natural stone, which normalize to crushed stone and
exceed the ordinary structural limits.

| Size | Case | Raw cells | Targets | Copy ms | Compile ms | Helper peak bytes | Retained definition bytes | Allocation calls | Rule reads | Validated cells | Result |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 10×10×8 | sparse | 800 | 162 | 0.000 | 0.322 | 62,800 | 800 | 10 | 25,758 | 162 | valid |
| 10×10×8 | dense | 800 | 800 | 0.000 | 0.460 | 248,272 | 800 | 12 | 39,708 | 800 | valid |
| 10×10×8 | invalid | 800 | 0 | 0.000 | 0.694 | 248,272 | 0 | 12 | 51,536 | 601 | structural rejection |
| 100×100×32 | sparse | 320,000 | 10,110 | 0.020 | 3.820 | 4,316,808 | 320,000 | 16 | 48,606 | 10,110 | valid |
| 100×100×32 | dense | 320,000 | 320,000 | 0.006 | 101.478 | 4,317,872 | 320,000 | 16 | 9,876,264 | 320,000 | valid |
| 100×100×32 | invalid | 320,000 | 0 | 0.005 | 39.765 | 4,316,808 | 0 | 16 | 3,821,660 | 60,001 | structural rejection |

Copy time measures only one `memcpy` into an already allocated detached array.
It excludes client cache and optimistic-overlay lookup, full-block residency,
source loading, pin/subscription management, and the actual one-pass client
snapshot operation. Times rounded to 0.000 ms are below displayed precision.
The borrowed raw input adds 320,000 bytes to the large compiler helper's working
set, independently of the measured allocation peak.

An immediate-platform fast path in the shared validator preserves the existing
support route set and minimum mineral height while avoiding recursive descent
through tall direct chains when a known height-one lateral route already exists.
The dense reference compilation completes in 101.478 ms with this implementation;
this run does not characterize every structurally valid arrangement.

## Destination admission

Both fixtures use a 256³-block world, a 100×100×32 definition at origin
`(87,87,87)`, and a 56-cell dependency halo. That alignment copies 384 chunks,
the maximum for this fixture's halo dimensions. The definition's actual footprint
touches 32 chunks at that origin; a differently aligned 100×100×32 footprint can
touch 50 chunks. The physical platform occupies Z=84…86. No existing planned
targets, construction metadata, custom roads, or immutable-floor indices are
present in this synthetic snapshot.

| Case | Targets | Snapshot chunks | Footprint chunks | Foundation reads | Prepare ms | Snapshot requested bytes | Snapshot estimate bytes | Helper peak bytes | Retained publication bytes | Helper allocation calls |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sparse | 10,110 | 384 | 32 | 31,212 | 7.363 | 12,651,032 | 12,651,072 | 5,116,872 | 977,240 | 219 |
| dense | 320,000 | 384 | 32 | 31,212 | 390.134 | 12,651,032 | 12,651,072 | 29,536,792 | 25,397,160 | 471 |

The separate snapshot and helper meters make their simultaneously live storage
visible. The helper clones footprint indexes and builds the complete publication
before returning. Its retained publication contains target lookup/list storage
and the new instance. The deduplicated bottom platform union uses 31,212 actual
foundation reads in each case.

Admission timings start with a ready immutable snapshot and end with a prepared
publication. They exclude dependency acquisition/generation, the service's staged
four-chunk-per-turn snapshot copying, final dependency/overlay version checks,
authority publication, per-client response preparation and delivery, client index
installation, meshing, and persistence. In particular, the direct admission
benchmark does not include the service helper's per-client instance response
clones. Many concurrent sites, dense preexisting indexes, near-floor immutable
lookups, and source churn need separate measurements.

The current dependency snapshot allowances are 1,024 chunks and 128 MiB of
estimated requested ownership. Source index capacities are included in the
estimate; allocator page overhead is additional. These are technical admission
resource settings, independent of the selected-volume and geometric limits.

## Client copy and interleaved fulfillment

The headless main integration fixture copied 320,000 predicted cells from 50
retained full-block source chunks into a 320,000-byte snapshot in **14.090–15.041 ms**
in three ReleaseFast runs. This measures the actual single client lookup/copy pass, rather
than the compiler runner's memcpy baseline. It excludes source loading and
helper validation. These were runs under concurrent app/test load, not a
frame-time percentile or guarantee. Debug took 104.001 ms in an earlier run.

The service fixture `interleaved fulfillment across 128 sites keeps bounded
support work and coalesces replies` builds 128 adjacent 4×4×4 sites in an
interleaved bottom-up order. All chunks are resident, each target has a real
below block, and the single client subscribes to two affected chunks. One
controlled batch of 8,192 fills measured:

| Work | Observed result |
| --- | ---: |
| Authority fill path, including index/metadata updates and acknowledgment preparation | 8.075 ms |
| Physical support reads | 8,192; exactly one per fill |
| Ordinary structural validation calls | 0 |
| Deferred road entries | 0; fixture has no adaptive roads |
| Final response flush | 0.271 ms |
| Block snapshots | 2, totaling 65,536 raw block bytes |
| Individual acknowledgments | 8,192 |
| Encoded fulfillment records | 106,496 bytes; exactly 13 per fill |

Additional runs measured 7.544–13.722 ms for fills and 0.265–0.292 ms for the flush under varying concurrent app/test load. These observations are not a percentile estimate.

This is an authority-function fixture using the test allocator. It excludes
library/site admission, NPC logic, material delivery and player inventory
transfers, endpoint command admission, frame scheduling, client reconciliation,
meshing/GPU work, and disk writes. Its controlled batch bypasses the default
256-operation endpoint capacity to isolate fulfillment and coalescing. Normal
batch boundaries can produce more snapshots. It establishes neither full-game
throughput nor a per-frame budget. Separate integration tests cover player
inventory atomicity and persistence/restart.

## Focused correctness checks

The following commands passed during implementation:

```sh
zig build test-blueprint
zig build test-blueprint-service
zig build test-capture
```

Compiler/admission fixtures cover cancellation and allocation failures, raw
bounds, material normalization, virtual versus real platforms, deterministic
support conversion, the 20/21-level boundary, composed real/planned dependents,
unknown dependencies, and the five-neighbor fulfillment support bound. Service
fixtures also check that accepted fulfillment queues road work without entering
ordinary structural validation, delayed safe road plans publish atomically,
unsafe plans preserve the accepted fill, and a full road queue rejects before
terrain/progress mutation. These checks do not replace the complete acceptance
matrix or native UI playtesting.

## Ordinary edits away from pending targets

The shared client/authority dispatcher now reuses physical validation when no
pending targets occur in any chunk intersecting the edit's inclusive ±28 cube.
It uses the existing finite-clipped, wrapped chunk window: at most 27 index
lookups, without allocating or enumerating targets/sites. Validator reads are
bounded by the edit even during dependent checks. Target identity and active-box
extraction guards precede the shortcut; nearby targets retain completed checks.
Shared physical preflight runs before the locality query, rejecting immutable
cells, unavailable target data, occupancy conflicts and forbidden mining. An
accepted preflight passes its resolved edit into structural validation without
repeating physical reads.

`test-world` compares complete results, physical reads, allocation calls and bytes
against ordinary validation for placements and removals with no sites, a library
only, distant active sites and retired sites awaiting cleanup. Its 11 edit cases
include occupied placement, empty removal, unavailable target/support data,
immutable cells, forbidden mining and structural allocation failure. Early
refusals require zero allocations; structural cases and induced allocation
failures have separate work assertions. A nearby-site regression also pins the
complete unavailable-target diagnostic and its allocation-free return. Additional
regressions cover all 27 intersecting chunks, inclusive boundary faces, wrapped
seams in small/large worlds, finite edges, custom reader topology, sparse active
cavities, planned dependents and real dependents supported by planned blocks.

The [maintained placement benchmark](../../src/voxel_app/ordinary_edit_benchmark.zig)
and [raw paired results](blueprint-ordinary-edit-locality-benchmark.txt) compare
`c0ecb6c` with the original locality shortcut in `21764da`. Distant-site plank
placement drops from 96 reads and two allocations to 49 reads and one allocation,
matching ordinary validation.
Removal avoids two affected-set allocations in both measured fixtures. Three
warmed process pairs observed 1.859 → 0.852 µs for placement, 0.727 → 0.587 µs for
rejected support removal, and 1.712 → 1.232 µs for accepted side-plank removal.
These detached synthetic checks exclude collection, service commits, rendering
and persistence. That version's query added roughly 0.07–0.08 µs versus no sites,
including about 64 ns before rejecting an occupied target.

The shared-preflight follow-up removes locality work from those early refusals.
Three warmed interleaved process pairs against `21764da` measured occupied-target
rejection at 0.113 → 0.057 µs with distant sites. Valid placement, rejected support
removal and accepted side-plank removal measured 0.835 → 0.874, 0.584 → 0.602 and
1.222 → 1.227 µs respectively, with unchanged physical reads and allocations.
Physical-only controls also shifted between runs; these small timing changes do
not isolate locality cost. These are fixture observations rather than full-game
throughput or latency guarantees.

Original locality verification on 2026-11-08 passed: `zig build test-world
test-blueprint-service
-Doptimize=Debug --summary all` (325 world and 542 authority tests), `zig build
test -Doptimize=Debug --summary all` (47/47 steps, 1,870 passed and one skipped),
and `zig build bench-placement -Doptimize=ReleaseFast --summary all` (15/15 steps;
maintained fixture results and allocation balance matched). The shared-preflight
follow-up also passed the 325 world and 542 authority tests and the maintained
benchmark (15/15 build steps). With the expanded early-exit/OOM coverage, the
focused command passes 326 world and 543 authority tests (18/18 steps), and the
full command passes 1,873 tests with one existing skip (47/47 steps). Formatting
and `git diff --check` passed. This
changes validation dispatch only; gameplay rules, world-save format, and the
five-neighbor fulfillment contract remain the same.

## Loose-soil support revision

The current rules exclude loose soil from upward support and stable platforms.
Blueprint fulfillment skips a loose block below and tries the same four real XY
neighbors, preserving the five-read bound. Filling a target leaves loose soil beneath
it unchanged; manual or timed compaction preserves target identity and adds
support capabilities without structural revalidation. Covering grass still converts
it to packed soil and cancels pending surface-growth timers.

Capture still normalizes packed soil and grass to loose dirt before certification.
A design that depends on those cells supporting higher included blocks therefore
rejects capture. Laterally supported planks above an included loose-soil cell
remain valid, and the saved cell remains loose. World format 6 rejects older
worlds with certificates that relied on loose-soil support.

Verified with:

```sh
zig build --global-cache-dir /private/tmp/zig-engine-global-cache \
  test-blueprint test-blueprint-admission
```

The deterministic admission comparison still accepts 16 of 32 seeded candidates,
including eight multilayer designs, and checks 128 rotated/wrapped applications
against 5,184 independent full target validations. Regression cases also cover
loose platform rejection, acceptance after compaction, and physical lateral
fulfillment above loose soil.

Final integration validation passed `zig build install test test-world test-blueprint
test-blueprint-admission -Doptimize=ReleaseFast -j2 --summary all` with the writable
global cache above: 65/65 build steps, 2,498 tests passed and eight skipped. This
includes mouse2 hold/cancellation, inventory preservation, stale-target rejection,
optimistic rollback, restart, unchanged loose-soil deadlines under ordinary and
blueprint placement, and preserved grass clearing. Formatting and diff checks pass.

## Grass coverage at application

Application now clears real grass to packed soil and cancels grass-growth timers
directly below every occupied miniature target. This includes elevated targets
over existing cavity contents, rotated definitions, wrapped X, and chunk
boundaries. Empty definition cells and the box/frame alone do not cover soil.
Loose dirt and its compaction deadline remain unchanged.

The helper prepares a detached surface plan from the same versioned admission
snapshot, including a per-chunk grass-timer bitset. Its exact changed-chunk set
drives source holds, resource reservations, revisions, and publication. Commit
rechecks dependency revisions and publishes the terrain/timer effects and new
instance atomically. Allocation or quota failure leaves both unpublished; a
capture source hold waits without partial writes. An evicted clean source is
loaded again and the retained plan is reused after the normal revision check.
The plan also retains exact per-chunk cancellation masks. Commit consumes those
decisions in one timer-list pass per changed chunk, without reconstructing cover
from terrain or blueprint indexes. Each mask uses 4 KiB, with bounded hash-table
capacity over at most the admitted source chunks.

The success-result queue reserves its slot before the first soil write and keeps
the queue locked through publication. A consumer cannot drain away that reserved
allocation. The result read may wait for this commit; publishing accepted terrain
and then allocating the response would permit a late OOM failure.

Fulfillment now writes only its target terrain/block metadata, inventory, and
incremental progress. The authority fill routine shrank from 89 to 50 source
lines; this is a code-size observation rather than a runtime benchmark. The
structural path still reads at most five neighbors, and completion remains O(1).
It can read the soil below but never writes that soil or its timers. R29's
separate deferred adaptive-road work can still update shapes in other road
cells; that existing behavior is outside these direct soil writes.

All grass scheduling and execution treat a pending target immediately above as
cover, even if the target's chunk is not resident. Manual and timed compaction
remain unconditional with respect to surrounding structure and still complete
under miniatures. The suppression concerns grass only. This follow-up stays
within world format 6 and adds no further save-version change.

Focused helper and authority regressions cover target-only soil/timer writes,
cavities, rotation, wrapping, chunk boundaries, holes, loose-soil preservation,
allocation/source-read failure, quota denial, capture holds, stale dependency
rejection, source eviction and reloading, grass suppression, and a save/reopen
that retains both the cleared surfaces and pending targets. They also preserve
the separate deferred-road checks. A canonical immutable-floor regression rejects
the complete application even if captured physical grass or packed soil looks mutable.
The commit allocation sweep tries every failure index through a successful commit
for resident soil and two initially nonresident generated chunks. Each failure
preserves terrain, timers, cell histories, revisions, overlay, journal and subscriber
notifications, then retries the same prepared task successfully. It also covers
failure after one or both generated chunks have been promoted without changing
their authoritative contents, and joins detached cleanup before allocator teardown.

Verified with:

```sh
ZIG_GLOBAL_CACHE_DIR=/private/tmp/zig-engine-global-cache zig build \
  install test test-world test-blueprint test-blueprint-admission \
  -Doptimize=ReleaseSafe -j2 --summary all
zig build --global-cache-dir /private/tmp/zig-engine-global-cache \
  test-blueprint-service -Doptimize=ReleaseSafe -j2 --summary all
```

The integration command passed 65/65 build steps, with 2,560 tests passed and
eight skipped. The standalone ReleaseSafe authority suite passed 597 tests.
Formatting and diff checks pass.
