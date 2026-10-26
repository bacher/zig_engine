# World generation validation

Updated on 2026-10-26 for G1–G7 and AC1–AC52 of the
[world generation specification](../../../specs/features/world-generation.md).
The default profile is generator **2 / version 1**, natural, seed **12345**, with
**2048 × 1024 × 32 chunks**. Beaches are available but disabled by default.

The current natural-generation support scope is **X:Y = 2:1**, targeting
`1024 × 512 × 16`, `2048 × 1024 × 32` (default), and `4096 × 2048 × 64` chunks.
The seed suites, timings, and overview maps in this report use the default size.
Seeds 12345, 0, and 87 pass mountain/spawn/oracle/restart checks at all three sizes.
[Recorded profile examples](supported-profiles.json) and maps cover half/0, default/12345,
and double/87; broad seed-distribution and timing evidence remains default-only. Other shapes and sizes remain experimental;
general engine layout acceptance does not guarantee natural-generation quality.

## Delivered behavior

At the default size, preparation grows 3–5 cardinally connected continents on a
512 × 256 macro grid (128 × 128 blocks per cell), refines their coasts by bounded erosion, and places
12 smaller, separated islands. Land now has a soft 35% target, with roughly 95%
of default-profile seeds within 25–45% considered sufficient. Growth stops at
an integer cost horizon instead of filling an exact occupied-cell quota. Stronger
coherent regional costs make uneven lobes and bays, and the cost at each accepted
cell is evaluated once for all four outgoing edges. Coverage never rejects a
candidate; connectivity and feature validity remain required. Geography and feature
data are prepared once; regenerating a column does not repeat this work.
The [controlled geography benchmark](land-coverage-comparison/README.md) records
a median reduction from 8.336 to 4.195 ms (49.7%) with unchanged requested memory.
This measures geography preparation, not complete preparation or regeneration.

Periodic integer fields provide winding climate boundaries, geology, rolling
terrain and forest/meadow regions; prepared peak kernels provide mountain ranges. Climate belts run north to
south in proportions 10/10/25/10/25/10/10 over the entire horizontal area,
including water. Sea level is exactly half the world depth: 512 blocks at default.
Mountain bodies uplift existing land and fade to zero before both displaced frozen boundaries.

Climate boundaries now combine independently phased periodic fields at 6, 14,
and 30 cells around X, weighted 2:3:1. Automatic displacement scales with height
to 1310 blocks at the default size, replacing the barely visible 96-block
default. Opposite control points have opposite signs, preserving exact boundary
means over all X columns and the target belt areas up to integer rounding of
nominal latitudes. These allocation-free queries need no retained field table.
The [before-and-after climate map](climate-before-after.png) preserves the earlier
61% footprint to isolate the climate change. Current maps below use the soft land target.
New natural worlds use automatic mode; saved nonzero amplitudes retain their
explicit block values.

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

First-start selection tries macro-cell centers nearest the actual curved temperate
belt midpoints, then expands within each belt's middle half. The original scan
accepted the first suitable temperate row, biasing starts toward steppe. Dry mainland,
gentle flatland or rolling-hills terrain, spawn clearance, and starter routes remain
required. Flatland and rolling hills are equally eligible; hilly terrain and all mountain
influence are excluded. Forest labels are allowed because generated trees exclude the
reserved spawn/access patch. Saved
player restoration retains its existing behavior. This bounded search runs only
during preparation and adds no allocations or per-chunk regeneration work.

Desert lowlands now have coherent dunes and gently rolling flats. A regional field
selects approximately equal areas without quotas or seed rejection. A 16-block-high,
1152-block-period broad profile gives flats a characteristic 1:36 grade; a smooth
warp bends its contours. Dunes add winding, 24-block-high ridges with a period of
at least 160 blocks. Their 48-block phase warp varies over 1024 blocks. Only the
dune side blends between profiles, so flat columns receive no dune contribution.
Queries use at most three value fields, skipping dune warping where its weight
is zero, with no extra allocations or retained map. Desert mountains remain
independent and expose stone; lower foothills may retain sand.

The pure field's ideal per-axis gradient is below 0.466320; including integer
interpolation error keeps adjacent changes below 0.491 blocks. Shore elevation
uses the minimum of that field and a coast cap, preserving the slope bound:
mainland coast changes by at most two units per column, so `1 + coast / 4`
changes by at most half a block; islands' `1 + coast / 32` changes by at most
one quarter. One final height quantization gives at most a one-block cardinal
step outside mountain influence. These are construction bounds, not runtime
validation or relaxation passes. Desert terrain blends into the ordinary Q16 baseline
in a 256-block collar outside the curved desert boundary, where the new temperate
contribution is zero.

[Block-scale terrain and profiles](desert-terrain.png) show two actual 512×512
tiles, with [exact profile data](desert-terrain.json). The sampled dune X profile
has 163 height changes over 511 intervals; flat X and Y profiles each have 14,
about one per 36.5 blocks. All four profiles have maximum adjacent delta one.
Regression fixtures also exercise coast ramps, asymmetric islands, internal macro
joins, climate boundaries, biome transitions, and the X seam. Pure-field tests
check flat purity, grade bounds, and approximate balance at all three supported widths.

## Temperate landforms

Temperate lowlands now contain coherent flatland, rolling hills, and hilly regions.
`generation_temperate.zig` evaluates three periodic integer fields at 5120, 1536,
and 384-block scales: a regional selector, slow rolls, and short rounded relief.
At default depth, the profiles have an eight-block floor above sea level and
6/72/32-block peak-to-trough relief. Smoothstep flattens their crests and troughs,
producing broad soil-covered hilltops without pointed peaks. The half-size profile
halves vertical relief; larger profiles cap it at default. These numerical choices
remain provisional terrain tuning, supported by the measurements below.

Two smooth selector transitions blend profiles continuously. A separate climate
weight is zero within 256 blocks of either displaced temperate-belt edge, ramps
over the next 1536 blocks, then reaches full strength. Outside that interior the
ordinary Q16 baseline remains, including the existing 256-block desert collar.
All lowland profiles now use shoreline minima `1 + coast / 4` on mainland and
`1 + coast / 32` on islands before one final quantization. This replaces the old
96-block multiplicative coast ramp for ordinary terrain, including steppe and
frozen lowlands. Mountain kernels and cover rules are unchanged; they receive
the newly composed base height.

The pure temperate sampler's analytical cardinal difference bound, including
conservative fixed-point error, is below **0.64 blocks**. The composed temperate
blend stays below **0.747 blocks** per cardinal step and the separate desert
256-block collar below **0.874** on the supported profiles. These bounds include
the worst-case two-block adjacent-X boundary displacement; Y changes by at most
one. Shoreline minima and final quantization preserve the one-block cardinal step
limit outside every nonzero mountain influence. Final-height regressions cover selector
bands, climate transitions, shores, narrow islands, and wrapped-X joins at supported
profiles. This excludes mountain feet even when their relief enum is still lowland.
`temperate_landform` is nullable and set only on dry temperate columns with zero
mountain strength. The independent forest/meadow field crosses all three landforms.

[Actual terrain, forest overlays, and one-block profiles](temperate-terrain.png)
use [exact export metadata and profile data](temperate-terrain.json). The flatland
and hilly windows each span 512 blocks and contain only their requested landform
in the sampled pixels; their sampled heights are **520–524** and **520–545**.
The rolling example spans **4096 blocks**, with sampled heights **520–580**:
**56.4%** of its pixels are rolling hills and **43.6%** flatland. It is a mixed
transition window, with actual climate influence ranging from **32.7% to 100%**;
78.6% of sampled pixels are at full temperate influence. No sampled pixel in any
of the three windows is submerged or mountain-influenced. Window selection uses
bounded candidate probes and does not guarantee a pure or fully interior window.
Every displayed horizontal/vertical one-block profile has maximum adjacent delta
one. Rendered relief and profile exaggeration are labeled; the figure represents
final generated terrain rather than synthetic versions of the three pure profiles.

Tree eligibility now checks the exact lowest occupied block in each of 25 crown
footprint columns, reusing the root sample. Removing the former flat-neighborhood
restriction allows complete downhill crowns while rejecting uphill collisions.
The independent point oracle no longer discards tree blocks more than eight
blocks above local ground. Fixtures preserve full-footprint water/climate checks,
finite Y/Z bounds, seam continuity, global priorities, whole-form nonoverlap, and
the one-block horizontal canopy gap. Cached reconstruction and point queries agree.

## Mountain refinement

[Terrain views and exact sections](mountain-terrain.png), [profile data](mountain-terrain.json),
and [16-bit sampled heights](mountain-heights.png) show the peak bodies above the separate
temperate lowlands. The [whole-map comparison](mountains-before-after.png) preserves the
earlier mountain-only refinement. Each continent retains 32 peak slots in
inline arrays, and each query evaluates at most five nearby kernels. Separate asymmetric
rational profiles produce gentle feet and pointed, steep upper faces. Peak heights and
base widths vary. A shared piecewise-linear centerline follows the prepared inland anchors,
bending overlapping feet into a range without adding a uniform ridge-height baseline.
Precomputed previous/next links avoid searching the descriptors during regeneration.

The maximum of the overlapping bodies creates saddles and gorges while preserving the
underlying land surface. Gentle feet retain climate cover; higher or steeper faces expose
stone. The cover grade is an analytic mountain-body heuristic, excluding lowland and
coast/climate taper derivatives; it is not a bound on the final terrain gradient.
Metal candidates now follow actual prepared peaks, with the existing footprint/solid-host
checks retained. Spawn candidates and their safety probes exclude all mountain influence.

All 256 default-profile seeds have sea level 512 and actual maximum summit height 972
(`floor(1024 * 95 / 100)`), with at least three such summits per seed. At seed 12345,
51 dry descriptor centers are pointed rock summits; base widths span 807–2095 blocks.
The selected connected saddle is at height 750, 148 blocks below its lower endpoint;
the deeper gorge is at 606 with 255 blocks of wall relief. Exact one-block sections
show these shapes, including a maximum six-block step in the selected gorge section.
The default depth remains 32 chunks. Temperate hills are a separate lowland layer;
the mountain kernels retain their accepted shape, with new lowland base heights.
No walkable-route guarantee was added.

Across the suite, 16,165 of 16,366 adjacent-anchor corridors with mountain endpoints
retain influence at every one of 257 sampled points. Coast and climate masks can split
exposed ranges; a continent is not promised one unbroken range. Seed 12345 has 47/48 such
connections: the remaining corridor crosses the coastal collar at `(14738,7292)`.
The JSONL records the first gap and its reason. These bounded probes are diagnostics,
not an exhaustive connectivity proof, seed acceptance gate, or traversability check.
Controlled fixtures separately test overlapping bodies, centerline knots and seam crossing.

| Example | Chunks | Sea / highest summit | Sampled connections |
| --- | --- | ---: | ---: |
| [Half, seed 0](half-0.png) | 1024 × 512 × 16 | 256 / 486 | 55/55 |
| [Default, seed 12345](default-12345.png) | 2048 × 1024 × 32 | 512 / 972 | 47/48; coastal split |
| [Double, seed 87](double-87.png) | 4096 × 2048 × 64 | 1024 / 1945 | 49/49 |

The nine seed/profile regression worlds additionally compare actual summit, saddle, and
gorge chunks against the point oracle, boundary masks, material counts, X wrapping,
fresh preparation, and derived mesh hashes.

## PR review corrections

The mainland coast coordinate now combines finite conservative coastal rectangles
with a shared bilinear inland field. It crosses internal macro edges continuously,
with a cardinal step bound of two. Land ownership and coast erosion are unchanged.
The approximation may flatten up to 16 extra blocks beside the real shore; its
inland values do not promise exact water distance. Islands retain their separate
analytic taper. In the original seed-12345 review fixture at
`(36735,13632)` → `(36736,13632)`, height **454 → 385** became **405 → 405**.
Those height values are historical coast-comparison results at the previous sea level.
Regressions use fixed mainland fixtures for internal and wrapped joins independently
of current continent growth.
An independent fine-grid distance BFS
checks 514,882 mainland columns in concave, neck, corner, and seam fixtures,
including maximally conservative trim records. Maximum adjacent-land height delta
in the current reduced fixtures is one block after the common lowland shore caps.

Mountain uplift uses the same displaced climate boundaries as classification and
reaches zero on both nonfrozen border rows. The original review fixture at
`(11647,3212)` → `(11647,3213)` changed from **408 → 555** to **408 → 408**
with the previous 96-block climate amplitude. The current regression derives
the actual displaced boundary at X=11647 rather than fixing its old latitude.
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
measurements below include both changes and the stronger climate curves. Those
two comparison experiments retain their original snapshots and measurements.

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
| `zig build test` | 45/45 steps; 962 passed, 1 skipped of 963 registered tests |
| `zig build test-generation` | 258/258 passed in Debug within the full suite; 258/258 also passed in ReleaseSafe |
| `zig build test-persistence` | 43/43 passed; included in the full suite |
| `zig build test-capture` | Passed on 2026-10-23 |
| `zig build test-gpu` | 2026-10-23: 19/19 steps; 90/90 passed on Metal, both wrapping configurations |
| ReleaseFast / ReleaseSafe regeneration | All 36 snapshot hashes and both prepared fingerprints agree between builds |
| 256-seed diagnostic suite | 256 accepted; no exhausted seeds |
| Player-scale inspection | 2026-10-23: safe grass spawn, complete trunks/crowns, opaque foliage and shadows |

The CPU skip is the existing nonwrapping counterpart of a wrap-specific
coordinate test. See the [final CPU transcript](cpu-suite.txt).
The 2026-10-26 rerun covers the build, full CPU suite (including persistence),
generation diagnostics, both benchmark modes, and overview maps. GPU and
player-scale results above are retained from 2026-10-23; shaders and material
rendering were unchanged by these review corrections, climate tuning, and land
growth/spawn/desert/mountain/temperate changes. They were not rerun for this extension.
Those GPU checks compile production shaders and read back material
colors; climate soil meshing and saved-material identity also have CPU tests. Prior manual inspection covered
spawn terrain and nearby forest, not every climate or water configuration.

The subsequent shared coast-fringe and named benchmark-site refactor was checked on
2026-10-26 with all 258 ReleaseSafe generation tests and a one-round ReleaseFast
benchmark at seed 12345/default, beaches off/on. Site order and coordinates, all 36
snapshot hashes, both prepared fingerprints, and preparation allocation/memory records
match the recorded benchmark. Timing was excluded from this comparison; independent
geometry/distance fixtures remain unchanged.

| Acceptance criteria | Evidence |
| --- | --- |
| AC1–AC5, AC11, AC22, AC24 | Layout/bounds tests, climate ordering and map/point equivalence, environment flags, configuration validation, seed-suite area measurements; exact boundary means across eight seeds and ordering/wrapping across 64 seeds and four layouts |
| AC2, AC37 | Protected-path construction above; final-column reduced and adversarial topology tests |
| AC6–AC10, AC17, AC23, AC35 | Shared material/support tests, timer regressions, render-only climate meshing, GPU material/shadow checks, sand and single-cell deeprock foundation tests |
| AC12–AC16 | Effective deposit counts and distribution below; starter dry-route checks; tree density, full-form overlap, XYZ-chunk and seam tests |
| AC18, AC30–AC34 | Whole-body polar/lower-Z bounds, independent collision guard, canonical floor oracle, shared write-set guard, indirect/optimistic edit and corrupt base/WAL restoration tests |
| AC19, AC28–AC29, AC36 | Shared forbidden/no-item mining tests; natural and flat save/reopen, inventory/climate/fingerprint equality, legacy/profile/runtime mismatch rejection |
| AC20–AC21, AC25–AC27 | Slow material oracle, conservative occupancy/enclosure checks, beach overlay fixtures, cached/evicted generation and mesh benchmark below |
| AC38 | Zero-attempt preflight, deterministic candidate rejection, eight-attempt exhaustion, terminal allocation/budget/cancellation injection, categorized diagnostics |
| AC43–AC47 | Pointed/asymmetric profile and derivative fixtures, connected centerline and X-seam fixtures, climate cover, nine seed/profile summit/pass/gorge oracle/restart checks, 256-seed actual heights, recorded sections and memory/timing checks |
| AC39–AC42 | Pure-field slope/purity/patch tests, actual coast/island/seam/climate fixtures, stone desert mountain and biome-eligibility checks, two-pass seed counts, block-scale profiles, dune/flat replay hashes |
| AC48 | Three-field purity/periodicity/selector tests, nullable landform eligibility, two-pass 256-seed 50/30/20 measurements, independent forest counts per landform |
| AC49 | Analytical pure/composed slope budgets, final selector/climate/coast/island/seam fixtures at supported profiles, depth scaling, actual terrain windows and one-block sections |
| AC50 | All-column uphill clearance, downhill crowns above the old eight-block cutoff, full-footprint exclusions, bounds/seam and priority-chain fixtures, cached reconstruction versus independent oracle |
| AC51; extended AC14 | Flatland/rolling-hills and forest-label start fixtures, hilly/mountain exclusions, 256 first-start records, dry starter routes, standing-space and nine seed/profile regressions |
| AC52; extended AC43 | Preserved mountain kernels with new ground heights, supported-profile topology/oracle/restart tests, 17-site replay, 36 cross-mode hashes, recorded memory, timings, maps, and sampling limits |

The natural save/reopen integration test mines real starter sand and ordinary
rock, then reopens a fresh store/service and compares edited chunk blocks,
revisions, metadata, carried inventory, climate, prepared fingerprint, and floor.

## Seed-suite measurements

[Raw JSONL](seeds-12345-12600.jsonl), [run log](seed-suite.txt), and
[summary](summary.json) cover seeds **12345–12600**. Each seed uses two
deterministically jittered 512 × 256 sampling grids: 131,072 columns per pass.
The second offset measures sensitivity to the sampling grid, not a statistical
confidence interval. Reduced topology fixtures separately enumerate final
land columns exactly to verify connectivity.

- Mean estimated land: **35.4650%**; median **35.5570%**. **253/256 seeds
  (98.83%)** fall within 25–45%. Empirical p2.5–p97.5 is **27.0730–43.9271%**;
  p95 is **42.8470%**. Individual pass estimates span **23.6526–46.5591%**.
  Maximum disagreement between offsets is **0.0465 percentage points**.
  [Coverage diagnostics](land-coverage.json) are informational; normal preparation
  does not run this scan or reject seeds for their land ratio.
- Mean belt areas are approximately **10.00 / 10.00 / 25.00 / 10.00 / 25.00 /
  10.00 / 10.00%**, within the specified one-percentage-point tolerance.
  Per-seed world and land-only climate counts are retained in the JSONL.
- All 256 seeds accepted attempt 0, including first-start and deposit preparation.
- Dunes occupy **50.13% / 50.15%** of sampled dry desert lowlands outside mountain
  influence in the two passes; the remainder is flats. Per-seed estimates range
  from **29.43% to 71.46%** dunes. Approximate balance is statistical guidance,
  without a per-seed area gate; the counts and variation remain visible in the JSONL.
- Temperate flatland/rolling-hills/hilly labels occupy **49.35 / 30.92 / 19.73%**
  of sampled dry temperate columns outside mountain influence in both passes.
  Forest coverage per landform is **49.5–49.9%**, showing the independently sampled
  vegetation field across all three labels; these are area estimates, not tree density
  or a per-world quota. Raw counts and the second-offset check are in the summary.
- All 256 first starts lie in the middle half of a temperate belt, within **0.872%**
  of the local belt width from its midpoint. Minimum Y clearance to either neighboring
  climate is **3,345 blocks**. Starts comprise **127 flatland / 129 rolling hills /
  0 hilly**; **112** carry forest labels under the reserved clearing. Seed 12345
  still starts at storage **(1600, 10688, 529)**,
  with steppe/desert boundaries at Y **6945 / 14393**. Raw JSONL records each start's
  climate, actual boundary positions, and distances to both edges.
  A separate regression checks seeds 12345, 0, and 87 at all three supported sizes,
  including the complete horizontal standing-space search/clearance area.
- Preparation took **26.09–38.04 ms**, mean **32.32 ms**. Peak requested owned
  allocation was **2,129,016 bytes**, below the 32-MiB preparation gate.
  Maximum indexed feature references: **98**; maximum bucket occupancy: **14**
  against the configured per-bucket limit of 64.

Every seed has eight large deposits per resource. Large sources account for at
least **99.9380%** of descriptor resource volume for every resource in every
seed. Spatial allocation is estimated separately: per-deposit accepted samples
are weighted by exact effective block counts, and eligible host volume is
estimated from the two column passes. These estimates place **100%** of metal
in mountains in both passes (mountain host density approximately 0.000344,
sampled lowland density zero). Non-metal resources are at least approximately
**98.57% sedimentary** and **99.41% lowland**. Exact totals and sampled spatial
fractions are separate fields in the summary. Desert surface sand is not
included in descriptor totals. Extraction lifetimes and transport balance remain
untuned until production rates and recipes exist.

## Regeneration and memory

Seed 12345 was benchmarked for nine rounds in
[ReleaseFast](benchmark-release-fast.txt) and nine in
[ReleaseSafe](benchmark-release-safe.txt), with beaches off/on. All 36 snapshot
hashes and both full prepared-world fingerprints agree across those builds.
Seventeen representative sites, including all three temperate landforms, both desert
biomes, and actual summit/pass/gorge columns, also agree after
actual 96-column cache churn, reverse traversal, and fresh preparation; hashes
include blocks, climate, boundary masks, and derived mesh data. Enclosure is
checked separately by generator tests and conservative generation bounds.

| ReleaseFast workload | Beaches off | Beaches on |
| --- | ---: | ---: |
| Cold column + surface chunk + hash, median | 0.572 ms | 0.449 ms |
| 32 vertical chunks from a cached column, median | 8.152 ms | 8.080 ms |
| Mainland shore column initialization, median | 0.192 ms | 0.383 ms |
| Desert dune column initialization, median | 0.188 ms | 0.184 ms |
| Desert flat column initialization, median | 0.165 ms | 0.169 ms |
| Mountain summit column initialization, median | 0.191 ms | 0.204 ms |
| Mountain saddle column initialization, median | 0.227 ms | 0.239 ms |
| Mountain gorge column initialization, median | 0.208 ms | 0.199 ms |
| Temperate flatland column initialization, median | 0.336 ms | 0.337 ms |
| Temperate rolling-hills column initialization, median | 0.364 ms | 0.371 ms |
| Temperate hilly column initialization, median | 0.364 ms | 0.369 ms |
| 96-column forward traversal | 32.690 ms | 32.379 ms |
| Reverse traversal after eviction | 27.091 ms | 27.556 ms |

These small workloads show timing noise and location-dependent beach cost;
they do not establish a general speedup or a controlled before/after comparison
with prior regeneration reports. Terrain tuning and the chosen representative sites change;
the temperate extension also changes shore caps in other climates and tree eligibility.
The [before-temperate benchmark](benchmark-before-temperate.txt) preserves the preceding
beaches-off 9.231-ms cached vertical and 0.497-ms cold measurements. The earlier
[before-mountains benchmark](benchmark-before-mountains.txt) preserves the historical
7.606-ms cached vertical result before the mountain/sea-level change. These complete-output
snapshots do not isolate either kernel's cost or establish a general speedup. The separate
geography comparison above isolates preparation at identical seeds and settings; its
improvement does not imply the same gain for regeneration. Inline mountain descriptors
still contribute 6,744 retained/peak bytes without extra allocation requests. The new
landform environment field increases each cached column by 4,096 bytes, as accounted below.
Beaches remain **off by default**.
The logs separately report column, chunk-fill, and meshing times, throughput,
allocation calls/resizes, and p95. Retained environment/border sample counts
explicitly exclude internal feature probes. Mesh timing uses already prepared
chunks/neighbors; neither disk nor GPU uploads are included.

Preparation makes eight allocation requests and retains **687,224 bytes**,
including the 262,144-byte coast records. Growth/BFS scratch is freed before
those records are allocated, so peak geography stays at 16 bytes per macro cell.
A cached column is
**31,296 bytes**, previously 27,200; the unchanged 64-column limit retains at most
**2,002,944 bytes** of columns per cache. Chunk scratch is **32,768 bytes**. Requested
allocation accounting excludes allocator overhead and RSS, and these numbers
do not establish the whole game's 8/16-GB residency budget.

The dense-forest fixture retains 23 complete tree descriptors and emits
**2,278 faces / 9,112 face bytes**, below the existing 64-KiB per-chunk limit.
The new forest-labeled flatland, rolling-hills, and hilly sites retain **14 / 15 / 19**
tree descriptors and emit **1,752 / 1,839 / 2,010 faces**, respectively; their largest
face output is **8,040 bytes**. These are representative site measurements rather than
maximum populations over all landforms.
The buried deposit fixture correctly emits no exposed faces; its mountain
surface is measured separately. These fixtures do not prove that every forest
chunk fits, so existing GPU capacity handling remains necessary.

## Overview maps

Each map has four panels, top to bottom: continent/island ownership, climate,
relief/vegetation, and deposit locations. North is up; X wraps between the left
and right edges. Water is blue, islands yellow, and the magenta cross marks
first start. Climate colors are pale blue (frozen), yellow-brown (steppe),
green (temperate), and tan (desert); ocean climate is tinted blue. Relief uses
brown mountains, gold dunes, and pale-sand desert flats. Dry temperate lowlands use
light green for flatland, ochre for rolling hills, and earth brown for hilly terrain;
forest areas darken each landform color to two-thirds intensity. Other forest/meadow
backgrounds remain dark/light green. Mountain-influenced foothills retain their applicable
background color below the mountain-class threshold. Resource markers
are red (metal), cream (limestone), rust (clay), near-black (coal), and yellow
(sand). Marker sizes aid visibility and are not deposit footprints.

[Before/after land coverage, seed 12345](land-before-after.png) is a historical tuning
snapshot. Climate boundaries are unchanged by that land tuning; their colors over water
differ from dry land. Earlier climate/land comparison images retain their original output;
the four seed maps and half/default/double profile examples show the current terrain.

[Seed 12345](seed-12345.png) · [12346](seed-12346.png) ·
[12347](seed-12347.png) · [12348](seed-12348.png)

## Reproduction and limits

```sh
zig build -j2
zig build test -j2 --summary all
zig build test-generation -Doptimize=ReleaseSafe -j2 --summary all
zig build generation-map -Doptimize=ReleaseFast -j2 -- /tmp/overview.ppm 12345 256
zig build benchmark-generation -Doptimize=ReleaseFast -j2 -- 12345 9
zig build benchmark-generation -Doptimize=ReleaseSafe -j2 -- 12345 9
zig build generation-map -Doptimize=ReleaseFast -j2 -- /tmp/half.ppm 0 1 half
zig build generation-map -Doptimize=ReleaseFast -j2 -- /tmp/double.ppm 87 1 double
python3 docs/validation/world-generation/render_temperate.py /tmp/overview.ppm \
  --output /tmp/temperate-terrain.png
```

The renderer requires Pillow. Historical capture/GPU checks, last executed on
2026-10-23, can be reproduced with `zig build test-capture -j2` and
`zig build test-gpu -j2 --summary all`; they were not part of the current rerun.

The map command writes PPM maps, a first-seed `.desert.ppm` detail view and
`.desert.json` profiles, `.mountains.ppm`, `.mountains.height.pgm`,
`.mountains.sections.ppm`, and `.mountains.json` geometry/profiles. Temperate exports are
`.temperate.ppm` height/forest panels, `.temperate.height.pgm` actual 16-bit heights,
`.temperate.forest.pgm` vegetation masks, and `.temperate.json` window/profile metadata,
including landforms, selector weights, climate influence, water, coast, and mountain values.
The command also writes a per-seed `.jsonl` report and an informational
`.summary.json` with empirical coverage percentiles and the envelope fraction.
Overview, desert, and mountain PNGs are lossless conversions of their PPM exports.
The temperate figure renders the exported actual heights and forest masks, with a
labeled subset of mesh vertices for the isometric view and labeled vertical exaggeration;
its one-block sections retain every exported profile observation. Sandboxed build/test checks used
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
The existing abrupt seabed-height step at the actual shore is unchanged. Peak bodies
taper with coast/climate and are not branched tectonic networks. No exact final
land quota or equal continent-size guarantee is claimed. The soft coverage envelope
is tuned for the default profile. Half/double-size checks cover nine fixed seed/profile worlds and the recorded examples;
broad quality/performance distributions still need separate seed suites; other aspect ratios are outside the current
support scope and receive no special growth handling. The fixed desert transition collar
is tuned for 2:1 maps; on extreme tall/narrow experimental layouts, adjacent X columns
can cross the collar and produce abrupt relief changes. F1 foundation/pile rules, F2 NPC/farm
execution, and F3 material-definition consolidation remain deferred. Clay currently supports a
packed-soil-style stable platform without soil timers, while its mining remains
forbidden until its use flow exists.
