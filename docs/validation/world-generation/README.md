# World generation validation

Updated on 2026-10-24 for G1–G5 and AC1–AC38 of the
[world generation specification](../../../specs/features/world-generation.md).
The default profile is generator **2 / version 1**, natural, seed **12345**, with
**2048 × 1024 × 32 chunks**. Beaches are available but disabled by default.

## Delivered behavior

Preparation grows 3–5 cardinally connected continents on a 512 × 256 macro grid
(128 × 128 blocks per cell), refines their coasts by bounded erosion, and places
12 smaller, separated islands. A 61% macro growth target leaves approximately
60% final land after refinement. It prepares compact geography and feature data
once; regenerating a column does not repeat this work.

Periodic integer fields provide winding climate boundaries, geology, rolling
terrain, mountain ridges, and forest/meadow regions. Climate belts run north to
south in proportions 10/10/25/10/25/10/10 over the entire horizontal area,
including water. Sea level is 384 blocks at the default height. Ridges uplift
existing land and fade to zero before both displaced frozen boundaries.

Finite, disjoint ellipsoidal deposits supply eight large sources of each of
metal ore, limestone, clay, coal, and sand; twelve small sources each of clay,
coal, and sand; and three pockets near the first start. Exact effective counts
use integer vertical spans per deposit column. Trees use a jittered global
8-block lattice, complete candidate-conflict neighborhoods, and stable priority
to preserve whole, separated crowns across chunks and the X seam.

The runtime shares allocation-free climate queries, default-deny mining policy,
and canonical mutation guards. Climate changes soil rendering while saved soil
and timers retain their existing meaning. Water and foliage are opaque,
colliding cubes. Ore, limestone, clay, and coal remain unmineable pending usable
resource flows. Both playable natural and flat profiles have seeded, contiguous
1–3-block deeprock; invalid saved floors are rejected before publication.
Legacy generator IDs 0/1 are rejected explicitly.

## PR review corrections

The mainland coast coordinate now combines finite conservative coastal rectangles
with a shared bilinear inland field. It crosses internal macro edges continuously,
with a cardinal step bound of two. Land ownership and coast erosion are unchanged.
The approximation may flatten up to 16 extra blocks beside the real shore; its
inland values do not promise exact water distance. Islands retain their separate
analytic taper. At the reported seed-12345 join `(36735,13632)` → `(36736,13632)`,
height **454 → 385** becomes **405 → 405**. An independent fine-grid distance BFS
checks 514,882 mainland columns in concave, neck, corner, and seam fixtures,
including maximally conservative trim records. Maximum adjacent-land height delta
in those reduced fixtures is four blocks.

Mountain uplift uses the same displaced climate boundaries as classification and
reaches zero on both nonfrozen border rows. The reported frozen/steppe join at
`(11647,3212)` → `(11647,3213)` changes from **408 → 555** to **408 → 408**.
Tests cover both poles, both horizontal axes, seam equivalence, and nonzero inland
attenuation; these are not a universal height-gradient guarantee for all settings.

Both optional review improvements are included: direct and allocating preparation
share one settings/memory preflight and failure mapping, and chunk filling reuses
floor thickness and deposit candidates once per XY column. The point oracle
recomputes its inputs independently. Tests cover direct/wrapper report parity,
all seven geography allocation failures, cleanup, and exact memory boundaries.

The [coast prototype comparison](coast-comparison/README.md) records the exact-index
experiment and the chosen approximation, including a cross-section and complete
regeneration measurements. The separate [chunk-fill comparison](column-fill-comparison/README.md)
isolates material-input reuse with identical terrain. The final production
measurements below include both changes.

## Connectivity evidence

Macro growth adds each cell next to a cardinal same-owner predecessor, preserving
a path to its continental seed. Fine land is confined to owned cells. Within
each cell, retained Y rows are consecutive and every row is one X interval
containing local X=64; retained Y includes Y=64. Thus every fine land column
reaches the cell center. Same-owner horizontal neighbors share a bridge at
Y=64, and vertical neighbors share one at X=64. Macro paths survive refinement,
including across the periodic X seam.

Growth prohibits another owner in the surrounding 3 × 3 macro neighborhood.
Erosion cannot add land into the resulting water buffer. An island consists of
consecutive Y rows, each with a wrapped X interval containing its center
meridian. Its complete bounding box plus 24-block padding must be in macro
water, with separate pairwise island clearance checks. Relief preserves the
land/water classification, so these properties apply to the final H/S column
graph rather than only to macro labels.

[Generation tests](../../../src/voxel_app/generation_tests.zig) exhaustively
check actual refined columns on reduced worlds, including production growth
for seeds 12345 and 87. Adversarial fixtures detect diagonal-only contacts,
severed necks, orphan fragments, seam-crossing islands, island chains, forced
bridges, and lost water gaps. This is a construction argument supported by
bounded exhaustive tests; it is not an exhaustive census of the default world
or a proof of walking routes or connectivity of all water.

## Tests and inspection

Platform: Apple M4 Max, aarch64 macOS, Zig 0.16.0. The Metal driver reports
macOS 26.7.1 (25G241).

| Check | Result |
| --- | --- |
| `zig build` | Passed; both applications and installed content built |
| `zig build test` | 45/45 steps; 897 passed, 1 skipped of 898 registered tests |
| `zig build test-generation` | 15/15 steps; 221/221 passed |
| `zig build test-persistence` | 42/42 passed; also included in the full suite |
| `zig build test-capture` | Passed on 2026-10-23 |
| `zig build test-gpu` | 2026-10-23: 19/19 steps; 90/90 passed on Metal, both wrapping configurations |
| ReleaseFast / ReleaseSafe regeneration | All 24 representative hashes agree between builds |
| 64-seed diagnostic suite | 64 accepted; no exhausted seeds |
| Player-scale inspection | 2026-10-23: safe grass spawn, complete trunks/crowns, opaque foliage and shadows |

The CPU skip is the existing nonwrapping counterpart of a wrap-specific
coordinate test. See the [final CPU transcript](cpu-suite.txt).
The 2026-10-24 rerun covers the build, full CPU suite (including persistence),
generation diagnostics, both benchmark modes, and overview maps. GPU and
player-scale results above are retained from 2026-10-23; shaders and material
rendering were unchanged by these review corrections. Those GPU checks compile
production shaders and read back material colors; climate soil meshing and
saved-material identity also have CPU tests. Prior manual inspection covered
spawn terrain and nearby forest, not every climate or water configuration.

| Acceptance criteria | Evidence |
| --- | --- |
| AC1–AC5, AC11, AC22, AC24 | Layout/bounds tests, climate ordering and map/point equivalence, environment flags, configuration validation, seed-suite area measurements |
| AC2, AC37 | Protected-path construction above; final-column reduced and adversarial topology tests |
| AC6–AC10, AC17, AC23, AC35 | Shared material/support tests, timer regressions, render-only climate meshing, GPU material/shadow checks, sand and single-cell deeprock foundation tests |
| AC12–AC16 | Effective deposit counts and distribution below; starter dry-route checks; tree density, full-form overlap, XYZ-chunk and seam tests |
| AC18, AC30–AC34 | Whole-body polar/lower-Z bounds, independent collision guard, canonical floor oracle, shared write-set guard, indirect/optimistic edit and corrupt base/WAL restoration tests |
| AC19, AC28–AC29, AC36 | Shared forbidden/no-item mining tests; natural and flat save/reopen, inventory/climate/fingerprint equality, legacy/profile/runtime mismatch rejection |
| AC20–AC21, AC25–AC27 | Slow material oracle, conservative occupancy/enclosure checks, beach overlay fixtures, cached/evicted generation and mesh benchmark below |
| AC38 | Zero-attempt preflight, deterministic candidate rejection, eight-attempt exhaustion, terminal allocation/budget/cancellation injection, categorized diagnostics |

The natural save/reopen integration test mines real starter sand and ordinary
rock, then reopens a fresh store/service and compares edited chunk blocks,
revisions, metadata, carried inventory, climate, prepared fingerprint, and floor.

## Seed-suite measurements

[Raw JSONL](seeds-12345-12408.jsonl), [run log](seed-suite.txt), and
[summary](summary.json) cover seeds **12345–12408**. Each seed uses two
deterministically jittered 512 × 256 sampling grids: 131,072 columns per pass.
The second offset measures sensitivity to the sampling grid, not a statistical
confidence interval. Reduced topology fixtures separately enumerate final
land columns exactly to verify connectivity.

- Mean estimated land: **60.7438%**; individual pass estimates
  **60.6796–60.8116%**. Maximum disagreement between offsets: **0.0397 percentage
  points**. Normal preparation does not run this coverage scan.
- Mean belt areas are approximately **9.99 / 9.99 / 25.00 / 10.03 / 24.99 /
  10.00 / 10.00%**, within the specified one-percentage-point tolerance.
  Per-seed world and land-only climate counts are retained in the JSONL.
- 63 seeds accepted attempt 0. Seed **12365** rejected its first candidate for
  `start_access_unavailable` and accepted attempt 1; the full trace is retained.
- Preparation took **31.33–76.06 ms**, mean **38.39 ms**. Peak requested owned
  allocation was **2,122,272 bytes**, below the 32-MiB preparation gate.
  Maximum indexed feature references: **94**; maximum bucket occupancy: **9**
  against the configured per-bucket limit of 64.

Every seed has eight large deposits per resource. Large sources account for at
least **99.9461%** of descriptor resource volume for every resource in every
seed. Spatial allocation is estimated separately: per-deposit accepted samples
are weighted by exact effective block counts, and eligible host volume is
estimated from the two column passes. These estimates place **100%** of metal
in mountains in both passes (mountain host density approximately 0.000279,
sampled lowland density zero). Non-metal resources are at least approximately
**99.17% sedimentary** and **99.77% lowland**. Exact totals and sampled spatial
fractions are separate fields in the summary. Desert surface sand is not
included in descriptor totals. Extraction lifetimes and transport balance remain
untuned until production rates and recipes exist.

## Regeneration and memory

Seed 12345 was benchmarked for nine rounds in
[ReleaseFast](benchmark-release-fast.txt) and three in
[ReleaseSafe](benchmark-release-safe.txt), with beaches off/on. All 24 snapshot
hashes and both full prepared-world fingerprints agree across those builds.
Eleven representative sites also agree after
actual 96-column cache churn, reverse traversal, and fresh preparation; hashes
include blocks, climate, boundary masks, and derived mesh data. Enclosure is
checked separately by generator tests and conservative generation bounds.

| ReleaseFast workload | Beaches off | Beaches on |
| --- | ---: | ---: |
| Cold column + surface chunk + hash, median | 0.372 ms | 0.309 ms |
| 32 vertical chunks from a cached column, median | 5.346 ms | 5.419 ms |
| Mainland shore column initialization, median | 0.112 ms | 0.176 ms |
| 96-column forward traversal | 18.975 ms | 18.881 ms |
| Reverse traversal after eviction | 15.324 ms | 15.053 ms |

These small workloads show timing noise and location-dependent beach cost;
they do not establish a general speedup. Beaches remain **off by default**.
The logs separately report column, chunk-fill, and meshing times, throughput,
allocation calls/resizes, and p95. Retained environment/border sample counts
explicitly exclude internal feature probes. Mesh timing uses already prepared
chunks/neighbors; neither disk nor GPU uploads are included.

Preparation makes eight allocation requests and retains **680,480 bytes**,
including the 262,144-byte coast records. Growth/BFS scratch is freed before
those records are allocated, so peak geography stays at 16 bytes per macro cell.
A cached column is
**27,200 bytes**; the unchanged 64-column limit retains at most **1,740,800
bytes** of columns per cache. Chunk scratch is **32,768 bytes**. Requested
allocation accounting excludes allocator overhead and RSS, and these numbers
do not establish the whole game's 8/16-GB residency budget.

The dense-forest fixture retains 23 complete tree descriptors and emits
**2,278 faces / 9,112 face bytes**, below the existing 64-KiB per-chunk limit.
The buried deposit fixture correctly emits no exposed faces; its mountain
surface is measured separately. These fixtures do not prove that every forest
chunk fits, so existing GPU capacity handling remains necessary.

## Overview maps

Each map has four panels, top to bottom: continent/island ownership, climate,
relief/vegetation, and deposit locations. North is up; X wraps between the left
and right edges. Water is blue, islands yellow, and the magenta cross marks
first start. Climate colors are pale blue (frozen), yellow-brown (steppe),
green (temperate), and tan (desert); ocean climate is tinted blue. Relief uses
brown mountains, dark-green forest, and light-green meadow. Resource markers
are red (metal), cream (limestone), rust (clay), near-black (coal), and yellow
(sand). Marker sizes aid visibility and are not deposit footprints.

[Seed 12345](seed-12345.png) · [12346](seed-12346.png) ·
[12347](seed-12347.png) · [12348](seed-12348.png)

## Reproduction and limits

```sh
zig build -j2
zig build test -j2 --summary all
zig build test-capture -j2
zig build test-gpu -j2 --summary all
zig build generation-map -Doptimize=ReleaseFast -j2 -- /tmp/overview.ppm 12345 64
zig build benchmark-generation -Doptimize=ReleaseFast -j2 -- 12345 9
zig build benchmark-generation -Doptimize=ReleaseSafe -j2 -- 12345 3
```

The map command writes PPM maps and a `.jsonl` report. PNGs here are lossless
conversions. Sandboxed build/test checks used
`--global-cache-dir /private/tmp/zig-worldgen-cache` before `--` where needed;
the recorded diagnostic and benchmark runs used the same seeds and build modes
shown above.

Natural generator decisions use integer fields, explicit division/rounding,
SplitMix64 streams, stable candidate order, canonical X, and explicit
little-endian prepared fingerprints. ReleaseFast/ReleaseSafe agreement was
executed on aarch64 macOS; another architecture has not been executed in this
validation. Algorithm/material/rounding changes require generator-version review.

Coast refinement preserves row intervals and bridges; the shoreline footprint
still uses bounded macro-cell trims. The approximate relief coordinate crosses
internal joins continuously but can add a flat coastal collar up to 16 blocks.
The existing abrupt seabed-height step at the actual shore is unchanged. Ridges
taper with coast/climate and are not branched tectonic networks. No exact final
60% quota or equal continent-size
guarantee is claimed. F1 foundation/pile rules, F2 NPC/farm execution, and F3
material-definition consolidation remain deferred. Clay currently supports a
packed-soil-style stable platform without soil timers, while its mining remains
forbidden until its use flow exists.
