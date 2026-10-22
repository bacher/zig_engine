---
service: zig_engine
created: 2026-10-22
status: draft
---

# Generate continents, climate belts, mountain ranges, deposits, and forests

## Intent

Give geography a useful role in settlement, construction, and transport: continents separate
regions, climate changes working conditions, forests concentrate wood, and finite deposits
justify building extraction and delivery infrastructure. Establish one deterministic source
of environmental data for generation, rendering, and future simulation.

This document is a design draft and an implementation roadmap. The current request authorizes
writing and discussing the specification; it does not start engine implementation. Confirmed
decisions, proposed defaults, and deferred mechanics are distinguished below.

## Context

- [Game vision](../../docs/game-vision.md) defines one-metre voxels, periodic X, finite Y/Z,
  physical logistics, and large exhaustible deposits. This feature adopts 60% land / 40%
  ocean, superseding the vision's earlier approximate half-ocean suggestion. Its candidate
  Voronoi algorithm is background, not an implementation constraint.
- [World configuration](../../docs/world-configuration.md) currently selects
  `512 × 256 × 8` **chunks**, each `32³` blocks. `WorldLayout` is immutable, coordinates are
  centred, and positive Y points north. Large storage Y therefore means north.
- [Voxel world](../../docs/voxel-world.md) describes a seeded, cave-free heightmap generator,
  prepared immutable noise tables, a bounded column cache, and regeneration of untouched
  chunks. The current generator has no continents, climate, deposits, or generated trees.
- [Block placement](../../docs/block-placement.md) already distinguishes loose soil,
  packed soil, and grass-covered packed soil. Compaction and surface timers are authoritative
  state. Sand currently bypasses structural placement checks; a stable soil platform can
  reset construction support counters without proving support down to bedrock.
- [Country roads](country-roads.md) currently allow cube-colliding materials as direct
  support. The proposed sand restriction is a deliberate exception to that rule.
- [World persistence](world-persistence.md) records dimensions, generator identity, seed,
  settings, changed blocks, construction metadata, and timers. Saved changes override
  generation. Existing storage bounds descriptor bytes to 4 KiB; a macro map must not be
  inserted into that descriptor without a separately designed format change.
- [Resource budgeting](resource-budgeting.md) remains a follow-up. Enlarging the coordinate
  space does not authorize materializing the entire world or enlarging residency budgets.

## Requirements

### World shape and geography

- R1: The default voxel-world dimensions become `2048 × 1024 × 32` chunks, confirmed by
  the user. With `32³` chunks this is `65536 × 32768 × 1024` blocks, approximately
  `65.536 × 32.768 km` horizontally. The 67,108,864 possible chunks use 26 ID bits;
  chunk size and `u32` chunk IDs remain unchanged. The demo app need not change its preset.
- R2: X wraps; Y and Z do not. All procedural fields, feature distances, neighborhood
  searches, and connectivity checks respect the cylindrical topology. Climate belts extend
  predominantly along X and vary with Y. The equator is the horizontal midpoint of Y.
- R3: Generate 3–5 substantial continents, selected deterministically from the seed. Each
  is one connected landmass, including connectivity across the X seam, separated from the
  others by continuous water. A landmass crossing that seam counts once. Smaller detached
  islands are required in the first iteration and do not count toward the 3–5 continents.
  Distinguish continent cores from bounded smaller island footprints structurally, without
  requiring a full-world land-area census. Islands must not bridge two continents.
- R4: Target approximately 60% dry land in horizontal projection, counting every `(X,Y)`
  once, regardless of elevation, including both continents and islands. Use this as a
  construction/tuning target, not a reason to count every final land column or run an
  expensive fine-resolution coverage pass during preparation/regeneration. Offline seed
  diagnostics may estimate coverage; proposed tuning range is 58–62%. Ocean and inaccessible
  polar strips are included in the denominator; tree canopies are not land. Climate area
  allocation is independent of land coverage and needs no land-area normalization.
- R5: Mountains form coherent ranges, independently of climate and vegetation. They may
  overlap steppe, temperate, and desert climates, but no frozen column is classified as
  mountain. Ocean floors do not become land merely because a ridge crosses them.
- R6: Keep generated terrain cave-free in the first version. Use a common sea level,
  solid ground below each terrain surface, and water filling the space between a submerged
  surface and sea level. Rivers, dynamic lakes, erosion simulation, and tectonics are not
  prerequisites.

### Climate and environmental queries

- R7: The north-to-south sequence is frozen → steppe → temperate → desert → temperate →
  steppe → frozen. Confirmed normalized area targets: 10%, 10%, 25%,
  10%, 25%, 10%, 10%, respectively. The desert straddles the equator, approximately 5% per
  hemisphere. Targets describe total horizontal map area, including ocean; the climate
  proportions of actual land are reported separately and need not match.
- R8: Each polar frozen belt occupies approximately 10% of the default map and extends
  at least four chunks (128 blocks) inward from its pole **at every X**. Boundaries vary
  smoothly and periodically along X, do not cross, and are not aligned to chunk borders.
  Both hemispheres follow the same ordering but need not be exact mirrors.
- R9: Climate is a per-column property, not a chunk property or a property of a carried
  block. Smoothly varying boundary positions produce exactly one `ClimateId` per column.
  A single chunk can contain several climate IDs. Rendering and game rules use that same
  ID; texture/color blending and neighboring-climate weights are deferred. Smooth transition
  means winding boundaries at column resolution in this iteration.
- R10: Provide allocation-free `climateAt(x,y)` and a `32 × 32` climate-map query for any
  horizontal chunk coordinate. Both use the same prepared world identity and return
  identical results for the same column, independently of chunk residency. Querying climate
  must not generate blocks, enumerate deposits, or read GPU data. Its work is bounded by a
  fixed number of periodic-field evaluations.
- R11: Keep climate, relief, vegetation biome, and geology separate. A column can be
  temperate + mountain + sparse vegetation, or temperate + lowland + forest. Expose enough
  environmental information for future farming, clothing, water, food, and other rules
  without inferring climate from textures or material IDs. Excavation and construction do
  not change the column's climate.
- R12: Frozen climate has no generated trees or bushes, prohibits future farming, requires
  clothing for future NPC work, and increases food cost for all future NPC actions performed
  there. Desert work requires additional water. Steppe and desert have almost no trees;
  temperate climate has baseline conditions. This milestone provides the environmental
  contract; NPC supplies, farming, research, and action accounting require later features.

### Surface materials and water

- R13: Preserve saved soil states and the existing compaction/grass timers. For a state
  that displays grass in temperate climate, render yellow grass in steppe and a snow-covered
  top surface in frozen climate. These are render appearances, not new saved soil types.
  Moving and placing soil changes its eventual appearance according to the destination
  column; mining continues to yield ordinary loose soil.
- R14: Confirmed surface interpretation: freshly placed loose soil stays loose, and exposed
  packed soil receives its climate cover on the same schedule that currently grows grass.
  Generated exposed soil receives its cover immediately. Covering soil still removes the
  cover. Frozen climate does not replace soil with the existing standalone `snow` block.
  “Exposed” means no block immediately above, preserving today's underground grass eligibility
  without adding light/sky checks. Digging into soil reveals its ordinary material.
- R15: Desert terrain has sand over rock instead of a generated soil/grass layer. Bare
  rock outcrops and exposed geological resources are permitted. Desert sand is the same
  material as sand elsewhere; placed soil in a desert remains soil and does not turn into
  sand. Until a dedicated desert-soil palette is designed, imported soil retains baseline
  soil/green-grass appearance there and follows normal timers. Frozen appearance likewise
  cannot turn sand into soil or a snow block.
- R16: Sand never compacts, grows grass, or acquires soil timers. Placing sand requires a
  filled `3 × 3` support layer directly below it; placed sand retains that requirement.
  Each footprint cell must be an existing structural material or sand; air, water, standalone
  snow, and foliage do not qualify. Soil may also use sand in its `3 × 3` support footprint,
  without making sand structural. Natural generated terrain remains exempt from construction
  validation, as it is today.
- R17: Sand cannot directly support buildings, trunks, planks, masonry, reinforced
  materials, or either road type. Of currently relevant placeable blocks, only soil and
  sand may be placed directly on sand, subject to their footprint rules. Water and foliage
  do not supply such footprints. Sand is never a stable-platform material.
- R18: Temporarily allow construction on a valid soil platform above remaining sand,
  confirmed by the user. Preserve existing platform resets and bounded support validation;
  this iteration requires no proof of a continuous foundation down to rock. R17 still
  prohibits building directly on sand. Stronger foundation rules, excavation/replacement
  workflows, and piles reaching rock remain a separate future construction design.
- R19: Render water as fully opaque blue cubes in the visible opaque pass, with alpha 1
  independently of atlas alpha. Depth and shadow passes treat it as a fully solid cube;
  internal faces stay culled. The user confirmed
  retaining current full-cube collision, so walking on water is temporarily possible.
  Swimming and fluid behavior are separate work. Initial polar oceans remain water;
  ice is not introduced implicitly.
- R20: A thin sandy shore is optional for the first milestone. If included, it replaces
  only a shallow, low-slope coastal surface band, follows the actual coastline across
  chunks and the X seam, and uses ordinary sand in every climate. It does not alter climate
  classifications, heights, or water occupancy. Prefer a bounded material overlay using
  already computed terrain/coast samples, with no neighboring chunk loads, recursive feature
  generation, or per-voxel water search. Benchmark enabled/disabled cold-column regeneration
  before including it by default. Starter sand does not depend on beaches.

### Deposits and vegetation

- R21: Generate finite underground deposits of metal ore, limestone, clay, coal, and sand,
  with a resource-definition model that can be extended. Large, spatially concentrated
  deposits are the normal industrial source, including bulk materials. They cross chunk
  boundaries naturally and have no per-chunk replenishment. Every accepted default world
  has a nonzero configured large-source population of every listed resource; there is no
  per-continent guarantee.
- R22: Metal ore is rare outside mountains and substantially more common within them.
  Limestone, clay, coal, and bulk sand favor appropriate sedimentary lowlands, basins,
  and coastal/desert settings and are less frequent in mountain interiors. Placement uses
  geological preference rather than copying real-world geology in full detail.
- R23: Small deposits of clay, sand, and coal also occur for early production. Metal and
  limestone have only the large-deposit population in this version. The user confirmed a
  guarantee of accessible small clay/sand/coal deposits near the **first starting position
  only**; other continents and later spawns receive no equivalent guarantee.
- R24: Resource blocks replace compatible solid host material below the actual surface,
  with shallow exposures allowed. Define stable overlap precedence, resource IDs, depth
  ranges, and size classes. Published quantities mean effective resource-block counts after
  clipping and overlap, rather than bounding-box volume. No claim about hours of production
  is made before extraction rates and recipes exist.
- R25: Add one generated tree species with a 4–5-block trunk and a compact cubical green
  crown. Trees must not intersect one another, terrain, water, finite Y/Z bounds, or forbidden
  climate columns. Complete forms can span horizontal/vertical chunk boundaries and the
  wrapped X seam without clipping or depending on which chunk was requested first.
- R26: In temperate climate, use coherent meadow/plain and forest biomes that cross chunk
  boundaries at arbitrary columns. Forests have substantially more trees than meadows.
  Steppe trees are exceptional; desert trees may be entirely absent in the first version.
  No generated bushes are needed yet. Mountain slope and exposed rock reduce tree density.
  Steppe scarcity should encourage non-wood construction or wood import; the generator
  itself does not implement research prerequisites or prohibit imported wood.
- R27: Confirmed first-version foliage is an opaque green, full-cube-colliding, nonstructural
  block. It cannot support buildings, either road type, soil footprints, sand footprints,
  or stable platforms; road validation must explicitly respect this despite cube collision.
  Generated trunks and leaves are natural blocks, not constructed placements. Trees can be
  mined block by block; automatic felling, falling trunks, leaf decay, regrowth, and sapling
  planting are deferred. Mining a trunk yields the existing trunk item; leaves have no
  useful harvest item in this version.

### Playable bounds, persistence, and scale

- R28: For natural playable worlds, prevent entry into the two outermost chunk rows at
  **each** Y edge: playable storage Y is `[64, height_in_blocks - 64)`. The invisible barrier
  applies to the whole actor body at every height and is shared by movement, climbing,
  spawn, teleport/recovery, and future pathfinding. Outer strips still generate and render;
  no wall voxels are stored. X retains ordinary wrapping. Debug spectator movement may be
  exempt, but returning to player mode must find a legal position.
- R29: Choose the first starting position on safe temperate mainland, preferably a meadow,
  outside mountains, water, trees, and the polar exclusion strips. Prepare a suitable region
  before the existing authoritative standing-space check; do not rely on searching only a
  few cells around world origin. Reopening uses saved player state and current blocks.
- R30: Generation is deterministic for dimensions, generator version, seed, and serialized
  settings. Reordering chunk requests, parallel work, cache eviction, restart, or crossing
  the X seam must not change generated blocks, climate, trees, or deposits. Saved edits
  remain authoritative and never regenerate mined material or removed vegetation. Untouched
  chunks may be generated arbitrarily many times and are not persisted merely to stabilize
  random outcomes. Beaches and islands obey the same determinism contract.
- R31: Use a new generator identity/settings schema; unsupported versions fail explicitly.
  Backward compatibility and migration of old worlds are not required. Within a supported
  version, reopening must reproduce the same unmodified world and environmental queries.
  Persist compact inputs and deterministically rebuild prepared macro data.
- R32: World creation and routine queries must not allocate block-resolution global maps
  or arrays for all possible chunks. Bound preparation memory, candidate lists, retries,
  feature-index occupancy, column caches, and per-chunk generation work. Preserve existing
  residency/backpressure behavior rather than assuming the enlarged world fits in memory.
- R33: Rework generation shortcuts so they cannot omit water, crowns, or deposits. Empty
  shortcuts require bounds on all generated occupancy; stone shortcuts require proof that
  no material overlay intersects. Enclosure/occlusion certification must remain conservative
  for every new material and use the same generation source as actual chunks.
- R34: Provide reproducible diagnostic maps and seed-batch measurements for continent
  connectivity, land coverage, climate areas over world and land, relief, vegetation,
  deposit locations/effective sizes, starting access, preparation cost, and forest mesh
  pressure. Full/fine land-coverage measurements are optional offline diagnostics, not a
  runtime dependency of climate queries or chunk regeneration. Statistical tuning claims
  must be distinguished from deterministic invariants.
- R35: Treat repeated regeneration of untouched chunks as a normal measured workload.
  Expensive bounded macro preparation happens once per prepared-world lifetime, never per
  chunk or cache refill. Benchmark cached and evicted column generation separately, retaining
  existing bounded caches; performance must not depend on eventual disk persistence or an
  indefinitely warm column cache. Measure the beach overlay separately before enabling it.

## Clarifications

- Q1: Are the requested dimensions chunks or blocks?
  A1: CONFIRMED on 2026-10-22: chunks, matching the existing preset's units.
- Q2: How do the climate percentages add up?
  A2: CONFIRMED on 2026-10-22: north-to-south distribution is
  `10 / 10 / 25 / 10 / 25 / 10 / 10`. Totals are 20% frozen, 20% steppe,
  50% temperate, and 10% desert. The user also confirmed the denominator: total horizontal
  world area, including ocean. No land-area count is needed to allocate climate belts.
- Q3: Does “smooth transition” require continuous simulation rules?
  A3: CONFIRMED on 2026-10-22: winding boundaries and exactly one climate per column.
  No texture/color blending or climate-weight API in the first iteration. Rendering and
  future rules read the same climate ID.
- Q4: What does snowy soil mean for compaction and grass growth?
  A4: CONFIRMED on 2026-10-22: retain the existing state machine and timers; snow appears
  when grass would appear in temperate climate. This is a visual interpretation of the
  same saved soil state, including ordinary covering/uncovering behavior.
- Q5: Is early access to resources guaranteed?
  A5: CONFIRMED on 2026-10-22: small clay, sand, and coal deposits near the first start;
  no corresponding guarantee for metal, limestone, other continents, or later starts.
- Q6: What happens when the player reaches water before swimming exists?
  A6: CONFIRMED on 2026-10-22: retain current solid-cube water collision, including walking
  on it. Opaque rendering alone does not establish a transport barrier between continents.
- Q7: Are mountains a mutually exclusive climate biome?
  A7: PROPOSED: relief overlays climate. Forest/meadow is a separate vegetation layer. No
  high-altitude freezing is added yet; a frozen climate column cannot have mountain relief.
- Q8: Can buildings be supported indirectly by sand through a soil platform?
  A8: REVISED/CONFIRMED on 2026-10-22: allow the soil-platform workaround for this iteration.
  A valid `3 × 3 × 3` soil platform may support construction even with sand below it.
  Direct building on sand is still prohibited. Foundation-to-rock checks and piles are
  deferred; generated bedrock heights are not used as a substitute for future live support.
- Q9: What remains to be balanced?
  A9: CONFIRMED approach: use visual maps of several seeds to tune mountain heights,
  forests, and resource distributions before fixing numbers. UNRESOLVED numeric tuning:
  coastline scale, boundary roughness, mountain heights, forest coverage/density,
  deposit counts/yields, starter radius, and NPC supply
  multipliers. Proposed values below are inputs for visual and performance experiments,
  not confirmed player-economy balance. NPC rule locations and supply types are settled.
- Q10: How are small layouts handled?
  A10: PROPOSED: retain a flat/test profile with zero polar inset. Natural profiles validate
  that two 128-block frozen belts and intervening minimum belt widths fit under the maximum
  boundary displacement. Reject
  incompatible dimensions/settings before creating the service; do not change generic
  `WorldLayout` minima or silently erase biomes. The four-chunk minimum overrides approximate
  frozen percentages in supported smaller natural worlds.
- Q11: Are islands part of the first iteration?
  A11: CONFIRMED on 2026-10-22: yes, in addition to 3–5 major continents. Islands receive
  climate from their coordinates, with no recalculation of climate shares by land area.
  Retain the original approximate 60% total-land target as coarse tuning; exact land-column
  counting is unnecessary. Island size/count is tuned from seed maps.
- Q12: What happens to foliage after felling?
  A12: CONFIRMED on 2026-10-22: opaque green colliding cubes, without automatic removal
  after trunk mining. Natural floating leaf blocks are allowed until a later tree feature.
- Q13: Can sandy beaches be cheap enough for repeated deterministic regeneration?
  A13: PROPOSED: reuse the refined coast/terrain samples and a small retained neighbor strip
  for slope, then change only a shallow surface material. This adds bounded arithmetic
  rather than recursive terrain generation or neighbor-chunk reads. Actual timing overhead
  is unmeasured; compare beaches enabled/disabled in the regeneration benchmark below.
  Beach inclusion remains conditional on that measurement. Deterministic regeneration is
  a confirmed requirement, including with empty caches and after restart.

## Acceptance Criteria

The milestones below separate generator delivery from future gameplay consumers. They are
verification requirements for implementation, not tests claimed to have run during drafting.
All listed criteria cover generation delivery, including current environmental flags and
the temporarily allowed soil platform. Future foundation/NPC execution tasks remain separate.

- AC1: GIVEN a new default voxel world WHEN its layout is created THEN dimensions are
  `2048 × 1024 × 32` chunks, ID round trips fit `u32`, X wraps, and Y/Z remain finite. [R1–R2]
- AC2: GIVEN an accepted prepared layout WHEN continent connectivity is checked on its
  final block-column cylindrical land graph THEN K separate major components exist for
  K in [3,5], additional smaller island components exist, and seam-crossing components count
  once. Refinement keeps each intended core connected and islands cannot join two
  continents; macro labels alone are insufficient. Structural invariants plus exhaustive
  reduced-world checks establish this without a full-world land census on startup. [R3]
- AC3: GIVEN the default profile and a recorded seed suite WHEN final-column land coverage
  is sampled offline THEN continents and islands together approach the 60% target, with
  58–62% as the proposed tuning range, and sampling/error checks are reported. Climate
  allocation and normal preparation/regeneration do not require that fine-resolution
  measurement or reject a world solely for an unmeasured final fraction. [R4, R34]
- AC4: GIVEN any X in an accepted natural world WHEN traversing Y from north to south THEN
  primary climate follows the agreed belt order, both polar extents are at least 128 blocks,
  no boundaries cross, and boundary positions vary away from chunk-aligned straight lines;
  default-profile seed-suite belt areas meet the agreed targets within the proposed one
  percentage-point tolerance, including approximately 5% desert per hemisphere. [R7–R9]
- AC5: GIVEN a chunk crossing a climate transition WHEN comparing all 1024 point queries
  with the chunk climate map THEN every single climate ID agrees, multiple climate IDs can
  occur in the chunk, wrapped-equivalent coordinates give identical results, and no blending
  weights or neighboring climate IDs are needed. [R9–R11]
- AC6: GIVEN the same grass-covered soil state in temperate, steppe, and frozen columns
  WHEN rendering, mining, saving, and reloading THEN its appearance follows the column,
  its saved soil type is not replaced by a climate-specific material, mining yields dirt,
  and existing compaction/cover deadlines and eligibility remain unchanged. [R13–R14]
- AC7: GIVEN generated desert land and an ordinary soil block placed there WHEN generating
  and editing THEN natural cover is sand or exposed rock/resource, the placed soil stays
  soil, and sand receives no soil transformations in any climate. [R15–R16]
- AC8: GIVEN sand or loose soil placement WHEN its complete `3 × 3` footprint is absent,
  present, missing from the client, or later removed THEN shared client/service validation
  respectively rejects, accepts, waits/rejects as unknown, or rejects support removal;
  generated sand remains mineable under the existing natural-terrain exemption. [R16]
- AC9: GIVEN a direct sand support WHEN placing roads or construction materials THEN
  placement is rejected, while properly supported soil/sand placement is allowed and sand
  never qualifies as a stable platform. [R17]
- AC10: GIVEN water adjacent to air and other water WHEN rendering visible and shadow
  passes THEN visible exposed faces are blue with alpha 1, depth/shadow coverage is solid,
  internal faces are culled, and existing full-cube collision remains in effect. [R19]
- AC11: GIVEN accepted relief descriptors WHEN sampling all macro cells and focused fine
  boundaries THEN mountain regions form ranges, occur in the permitted climates, taper
  outside frozen columns, and do not raise protected ocean corridors into land. [R5–R6]
- AC12: GIVEN resource descriptors WHEN materializing intersecting chunks in different
  orders THEN the same finite resource blocks appear below valid surfaces, deposit overlap
  precedence is stable, and deep-rock shortcuts do not erase deposits. [R21, R24, R30, R33]
- AC13: GIVEN the recorded seed suite WHEN measuring effective deposits by relief/geology
  THEN every listed resource has its configured nonzero large-source population, large
  deposits dominate total resource volume, metal density per eligible host
  volume is substantially higher in mountains, and non-metal deposits favor their stated
  non-mountain settings; no small metal/limestone population is introduced. [R21–R24]
- AC14: GIVEN a new world's first starting candidate WHEN preparation accepts it THEN
  shallow small clay/sand/coal deposits are reachable in the configured local land region
  without ocean crossing, and the final standing-space check accepts current blocks. [R23, R29]
- AC15: GIVEN trees spanning all three chunk axes and the X seam WHEN generating chunks
  separately, in reverse order, and after eviction THEN complete 4–5-trunk-block trees
  reassemble identically, with no overlaps, terrain intersections, or forbidden climate
  occupancy. [R25–R27, R30]
- AC16: GIVEN temperate forest and meadow regions WHEN sampling tree density and biome
  boundaries THEN forests contain substantially more trees, boundaries cut across chunks,
  frozen columns contain no trees/bushes, and steppe/desert match configured scarcity. [R26]
- AC17: GIVEN foliage WHEN colliding, building, mining, and meshing THEN it has the agreed
  opaque cube behavior, provides no structural support or useful item, and natural trees
  can be mined without triggering a constructed-tree dependency rejection. [R27]
- AC18: GIVEN an actor approaching either polar inset at any height WHEN moving, climbing,
  spawning, teleporting, or recovering THEN the whole body remains in playable Y, with no
  stored wall blocks or blocked-chunk loads required to establish the barrier. [R28–R29]
- AC19: GIVEN modified/mined chunks and an unchanged world descriptor WHEN saving,
  evicting, and reopening THEN current blocks/metadata override regeneration and climate
  stays identical; an unsupported generator version is reported explicitly. [R30–R31]
- AC20: GIVEN forest, coastline, mineral, and high-altitude fixtures WHEN comparing optimized
  generation/enclosure with an unoptimized reference THEN blocks, exposed faces, boundary
  masks, and enclosure decisions agree or conservatively retain extra geometry. [R33]
- AC21: GIVEN the default huge coordinate space WHEN preparing and sampling a bounded
  chunk workload THEN memory/work counters stay within declared preparation/cache/index
  limits, no full-resolution global maps or all-world block arrays are allocated, and GPU
  pressure follows existing capacity handling. [R10, R32, R34]
- AC22: GIVEN environmental queries before NPC/farm implementation WHEN reading rule data
  THEN frozen columns report no farming, clothing need, and increased food cost, desert
  columns report additional water need, and no consumer needs texture inspection. [R11–R12]
- AC23: GIVEN a valid soil platform built above remaining sand WHEN placing a compatible
  construction block on the platform THEN existing platform rules allow it without proving
  a foundation down to rock, while direct placement of that block on sand is rejected.
  This is the confirmed temporary construction behavior. [R17–R18]
- AC24: GIVEN an incompatible natural profile WHEN preparing the world THEN it fails before
  worker startup with a clear configuration error; small flat fixtures can explicitly use
  zero inset without weakening production bounds. [R8, R28, R32]
- AC25: GIVEN optional beaches are enabled WHEN sampling a low coastal band and seam-crossing
  mainland/island neighbors THEN sand follows the refined generated shore, preserves
  climate/heights/water occupancy, and has ordinary sand behavior. Classification performs
  no neighbor-chunk reads or recursive feature generation; disabling beaches does not remove
  guaranteed starter sand. [R20, R23]
- AC26: GIVEN untouched coastline, island, forest, and deposit fixtures WHEN regenerating
  them after column-cache eviction, fresh preparation/restart, and reordered requests THEN
  complete block hashes, climate IDs, and derived boundary/mesh data agree, without saving
  pristine chunks or relying on shared advancing random state. [R30–R31, R35]
- AC27: GIVEN the same prepared geography with beaches enabled/disabled WHEN running cached
  and cache-evicted regeneration workloads THEN sample counts, allocations/scratch, column
  build and chunk/mesh times are reported separately, and any enabled beach default meets
  the measured regeneration budget without increasing residency to hide its cost. [R20, R32, R35]

## Constraints

- Keep generation immutable after preparation and safe for independent consumers. No global
  advancing PRNG, generated-neighbor dependency, observation-dependent resource creation, or
  GPU-owned biome truth. New stochastic layers use named seed streams and canonical X.
- Climate queries describe location; material/support queries use **current authoritative
  blocks**. A generated deposit descriptor is not remaining stock, a generated height is
  not current clearance, and a generated bedrock height is not proof of a current foundation.
- Preserve byte-sized block storage and the four-byte ordinary voxel face record where
  practical. Palette/render IDs need a separate type and must not enter persistence or block
  operations. Custom road sentinel 255 remains reserved.
- Preserve missing-data handling, authoritative edit checks, atomic response packages,
  persistence revisions, and the fixed support-window discipline. Any expansion of support
  dependencies requires a separate reviewed construction design.
- Preparation validates finite parameters, safe arithmetic, periodic noise bounds, minimum
  climate widths, feature capacities, and allocation failure in all build modes. Bound retries
  and expose failure; do not silently publish a world that fails its geography contract.
- Performance numbers below are proposed engineering gates to measure, not observations.
  Cross-platform regeneration must have a documented numerical/determinism contract before
  its generator version is frozen; pin algorithm/hash/rounding and test supported targets.

## Out of Scope

Engine implementation during this planning discussion; old-save migration; spherical or
toroidal topology; seasons; altitude-driven climate; jungle; bushes; multiple tree species;
texture/color blending between climates; dynamic water, swimming, ice, rivers, hydrology,
erosion, and caves; extraction buildings,
processing recipes, prospecting UI, and transport simulation; research gates; farming/NPC
work execution and supply accounting; complete foundation/pile mechanics; tree growth,
automatic felling, leaf decay, and physical collapse. Optional beaches may be deferred.

## Plan

Provisional technical design for review. No task below is marked implemented by this draft.

### Approach

Use this dependency order, without conflating layers:

```text
version + dimensions + seed + settings
  -> connected continental layout + islands / coast / ocean
  -> periodic climate + geological provinces
  -> relief ranges + detailed terrain + surface cover
  -> first-start region + indexed deposits + starter pockets
  -> vegetation fields + deterministic tree candidates
  -> generated blocks / climate-aware render material
  -> saved edits override generated blocks
```

Climate is also directly queryable from prepared inputs; it does not require the intervening
block-generation stages. First-start selection and starter deposits happen before trees,
so tree exclusion around the spawn/access patches does not create a circular dependency.

### Continental layout and height

At default dimensions, start with a `512 × 256` macro grid: one cell covers `128 × 128`
blocks (four horizontal chunks per side), only 131,072 cells. Use compact fields for land
ownership, coastal distance, geological province, and growth/protection flags. This grid
guides large-scale geography, never assigns a whole chunk its climate or vegetation.

1. Choose K in [3,5] and well-separated seeds on the cylindrical macro grid. Use seeded
   Voronoi regions or deterministic weighted growth to allocate influence areas.
2. Grow connected land cores from the K seeds while reserving water corridors between
   continents. Prefer irregular broad shapes, bays, and nonuniform mainland sizes. Protect
   a connected interior spine and avoid narrow accidental isthmuses.
3. Grow/erode coast cells toward approximately 60% macro land. Validate actual component
   connectivity, not just K different owner labels. Across X, neighbors use modulo width;
   north/south do not connect. Proposed minimum strait/neck width is two macro cells before
   refinement, with local coast displacement strictly below half the protected width. Leave
   some land budget for the separately generated smaller islands; no exact final-area quota
   or per-continent percentage is required.
4. Derive coastal distance and refine only a bounded coastal band with periodic low-frequency
   noise. Mandatory water corridors stay submerged; mandatory land interiors stay connected.
   Each mainland column retains a four-neighbor land path to its protected continental
   core; displacement bounds alone do not establish this. Mainland refinement cannot create
   bridges between continents. Prototype a construction that enforces these invariants
   without a full-resolution global scan before freezing the algorithm.
5. Add a bounded nonzero population of smaller island descriptors in offshore and open-ocean
   locations. Use connected radial/elliptical footprints with irregular coast detail, a
   configured diameter cap, and protected water gaps. The cap is substantially smaller than
   the minimum continental-core extent; classify by construction, not an expensive census
   of all final connected components. Fine island shapes can be smaller than a macro cell;
   index their complete possible extents for local terrain queries. Keep islands out of
   protected straits where they could join continents. Their coasts, resources, vegetation,
   and climate follow the same field/material rules as mainland terrain.
6. Use at most eight deterministic candidate layouts, with stable growth/tie-break IDs.
   Reject preparation explicitly if no candidate meets structural validity/capacity gates.
   Do not run full-resolution land counting or coverage-driven fine sampling on this path;
   approximate coverage comes from coarse construction targets. No unbounded seed loop or
   fallback to a single continent.

Offline diagnostic exports can measure final coverage, including islands, with a deterministic
jittered sample in each `32 × 32` block tile and an independently offset pass (2,097,152
samples per pass at default size). Report estimator disagreement and compare with exact
counts on reduced worlds; this is not an independent-trial statistical confidence bound.
These scans run in the diagnostic tool, never during ordinary world preparation, column
cache refill, or regeneration. Climate construction always uses total X/Y extent directly.

Define `terrain_height` as the first cell above terrain: ground occupies `0 <= z < H`.
Water occupies `H <= z < S` only where `H < S`, with sea surface at S. Land columns satisfy
`H >= S`; protected land uses `H >= S+1` and protected water uses `H <= S-1` to leave margin.
Track terrain height, water surface, and maximum generated occupancy separately.

Proposed tuning at default height: sea level 384 blocks, ocean depth 32–160 blocks,
ordinary land 1–64 blocks above sea level, mountain uplift 64–384 blocks. Clamp all results
with room above for full tree crowns; retain solid bottom terrain. Shape continental shelf
and inland relief without making a vertical cliff around every coast.

### Climate boundaries and transitions

The confirmed normalized targets are:

| From north to south | World area | Total for this climate |
| --- | ---: | ---: |
| Northern frozen | 10% | 20% frozen |
| Northern steppe | 10% | 20% steppe |
| Northern temperate | 25% | 50% temperate |
| Equatorial desert | 10%, split 5% + 5% | 10% desert |
| Southern temperate | 25% | Included above |
| Southern steppe | 10% | Included above |
| Southern frozen | 10% | Included above |

Represent the six boundaries as smooth periodic functions `b_i(x)` around their nominal
latitudes, using fixed low-frequency components with approximately zero-mean displacement.
Use bounded amplitudes and validate minimum separation analytically/conservatively, rather
than fixing crossings after the fact. Small independent north/south fields avoid mirror
symmetry. Proposed boundary displacement is 1–4 chunks, tuned as a length in blocks rather
than quantizing boundary positions to chunks. No transition-band blending width is needed.

Compare Y to the six boundary positions to return exactly one `ClimateId`; tie-break exact
equality explicitly. Low-frequency variation makes boundaries curved at macro scale and
irregular within affected chunks. Green/yellow/snow appearance switches according to the
column's climate ID, as does the desert sand/soil material choice. Color interpolation,
weights, and a separate GPU climate map are deferred.

For smaller natural worlds, frozen nominal depth is at least 128 blocks plus the possible
inward displacement, so **every** X meets the minimum. Remaining belts must retain positive
core widths under the maximum boundary displacement; configuration fails otherwise. Default
world target area error is measured per belt; proposed initial tolerance is one percentage
point. Do not promise identical land-climate proportions or mirrored coastlines.

### Relief and geology

Prepare a small indexed set of seeded ridge curves/polylines with varying width, height,
branches, and gaps. Periodic images handle seam-crossing ranges. Evaluate distance to nearby
segments, modulate with ridged noise, and taper uplift at protected coasts and before frozen
boundaries. Store a mountain-strength field distinct from final height; low rolling terrain
is not a mountain merely because its absolute elevation is high.

Use broad sedimentary basin / rocky mountain province masks as geological preferences.
No plate simulation is required. A sedimentary lens may reach a mountain foothill, but the
overall distribution must still favor the specified hosts. Mountains alter resource weights
and vegetation; they do not silently change climate IDs or introduce a second polar biome.

### Optional beach overlay and its cost

Compute beaches from the base terrain result, before resources and vegetation. Reuse the
refined land/coast field, including island coasts, that produced final terrain height:

```text
beach = generated_land
     && land_side_coast_coordinate within configured narrow band
     && terrain_height close to sea_level
     && slope_from_cardinal_neighbor_heights <= configured_limit
```

Replace only the upper one or two ground blocks with ordinary sand; do not change heights,
water cells, or climate. The refined coastal coordinate can be an approximate signed
distance after warping, so band width is a visual tuning parameter rather than a promise
of an exact metre-distance to every water block. Skip beach work for clearly inland/ocean
columns and avoid a separate beach noise field.

For interior terrain columns, the existing path evaluates 1024 interior heights plus 128
cardinal border-strip heights for enclosure (1152 total). Retain those strips to derive local
slope without additional terrain samples; a simpler full `34 × 34` height halo needs 1156
samples, only four more than that existing path. Cache the beach mask/depth alongside column
environment data and reuse it for all vertical chunks. The overlay itself adds comparisons,
small arithmetic, and shallow material writes, not another terrain/feature generation pass.

`baseTerrainAt` must not call beach classification, climate-aware materials, deposits, or
trees. The beach overlay consumes that base result and retained heights; it never requests
neighbor chunks or recursively evaluates complete environments. All feature queries remain
bounded by the base terrain's existing spatial indices. X halo coordinates wrap and Y halo
handling respects finite bounds.

If exact local proximity to water is later needed, evaluate a bounded terrain/water halo
once and derive a local distance field. For radius four, a `40 × 40` halo needs 1600 height
samples, about 39% more than the current 1152 samples per cold column; that is a sample-count
comparison, not a measured time estimate. Such a change needs separate justification.
Do not scan a radius-four neighborhood independently for every output column.

Beaches follow original generated geography. Player changes to terrain or water do not
automatically create/move sand; saved block overrides win. The optional overlay is included
by default only after its measured cache-evicted regeneration overhead is acceptable.

### Deposits and starting access

Use explicit immutable descriptors: stable ID, resource, size class, centre, orientation,
shape parameters, depth/host restrictions, priority, and local seed. Prefer connected lenses,
seams, and irregular ellipsoids with bounded noise over scattered per-block ore chance.
The majority of a large deposit should be a connected mineable body. Do not fill a huge
bounding box with a negligible density of disconnected resource specks and call it large.

Proposed initial ranges and settings, to validate against effective volumes:

| Resource | Preferred setting | Large footprint / thickness in blocks | Small population |
| --- | --- | --- | --- |
| Metal ore | Mountain interiors and rocky foothills | 256–1024 long, 64–256 wide, 8–48 thick | None |
| Limestone | Sedimentary plains, basin margins | 512–2048 long, 128–512 wide, 8–48 thick | None |
| Clay | Shallow lowland/coastal sediment | 256–768 long, 64–256 wide, 2–12 thick | Yes |
| Coal | Sedimentary basins, broad shallow/deeper seams | 256–1024 long, 64–256 wide, 2–12 thick | Yes |
| Sand | Desert fields and non-desert sandy sediment | 256–1024 long, 128–512 wide, 4–24 thick | Yes |

These are shape ranges, not independently guaranteed yields. Proposed small-pocket effective
size is 64–512 blocks; industrial bodies should typically contain at least tens of thousands
of resource blocks and can contain millions. Target at least 90% of each resource's generated
volume in large sources, counting extensive desert sand as a large finite source. Counts per
map area and minimum/maximum effective yield belong in resource definitions and the seed
report before implementation approval; they are not inferred from voxel world volume.
Proposed metal preference gate: at least 4× deposit-block density per eligible host volume
in mountains compared with non-mountains, with most metal volume in mountain regions.

Use a bounded spatial index; bucket references cover the complete possible noisy extent.
Cap candidate descriptors per bin and total references, rejecting/regenerating overfull
preparation. Large descriptors may use a second index level rather than referencing every
small bin. Query candidate overlays once per chunk/column where possible, not all world
deposits for every voxel.

Resolve overlap by an explicit total order `(priority, stable_deposit_id)` and validate
effective remaining volume/connectivity after host clipping and competing overlays. Resource
blocks never replace water, air, or tree voxels. Preserve the desert sand surface except
intentional rocky outcrops; underground clay does not create a grass/soil desert surface.
Startup uses bounded shape/core proofs, conservative effective-volume bounds, and sampling;
exact voxel counting is an optional diagnostic over selected deposits/reduced worlds. Do
not silently enumerate millions of blocks per deposit on every prepare/reopen. Any exact
startup scan must have an explicit work budget; fingerprints hash descriptors/prepared
data, not all resource voxels. Diagnostics identify estimates versus exact quantities.

Select a temperate, low-slope mainland start, then reuse or insert the three small starter
pockets. Proposed access radius: 256 blocks by shortest wrapped distance, with at most four
blocks of cover and a dry traversable route within the local land region. Validate routes
against the implemented movement/climb limits and final generated trees, not only Euclidean
distance. Prefer selecting an already suitable plain over flattening a large area. Reserve
spawn clearance and access patches from tree placement. Bound local searches and include
their failure in preparation retries. No general NPC routing system is required.

Large desert cover is itself a substantial sand source. Separate non-desert sand deposits
and starter pockets ensure early sand access does not require reaching the equator or an
optional beach. Resource descriptors describe the original world; remaining stock always
comes from current authoritative blocks. Mining methods are later consumers of the same
deposit geometry and do not change its generation.

### Vegetation and trees

Use a periodic moisture/vegetation field and broad thresholds for temperate forest versus
meadow. Scale broad patches in blocks, with finer edge variation, rather than assigning
chunk labels. Proposed forest coverage is 35–55% of eligible temperate land; no global
quota is required in the first prototype.

Proposed tree densities per 10,000 eligible ground columns: forest 60–120, meadow 2–8,
steppe 0–2, desert 0, frozen 0. Mountains reduce density through slope/soil eligibility.
Record both candidate and accepted density, since collision rejection lowers the result.

Generate one jittered candidate per cell of a global eight-block placement lattice, with
the cell identity normalized around X. Eligibility depends on original terrain, full shape
clearance, climate, vegetation, slope, and exclusion patches. Candidate priority is a stable
hash. A candidate is accepted only if no eligible overlapping candidate has a higher
priority, with cell ID breaking ties. Compare against the complete local candidate set,
including candidates that themselves lose another comparison; this avoids recursive,
load-order-dependent greedy placement. Reserve a one-block gap between canopy bounds.

Trunks occupy 4 or 5 cells from the terrain top. Proposed crown: two lower `5 × 5` leaf
layers around the upper trunk and two upper `3 × 3` layers, excluding trunk cells. Exact
shape is versioned. Reject the entire tree if its shape crosses a frozen/desert column,
intersects terrain/water, or lacks headroom. Adjacent meadow/forest boundaries may pass
under a crown; those vegetation labels do not forbid tree overhang.

For a chunk, enumerate every candidate whose complete form can intersect it, using the
maximum crown radius/height and a conflict halo. Generate the accepted complete form in
world coordinates and write only its intersection with this chunk. Generated trunk cover
leaves the soil directly beneath it packed rather than grass-covered. No persistent tree
entity or dependency on already loaded neighbor chunks is needed. Removed blocks stay
removed through ordinary persisted chunk overrides; natural leaf blocks otherwise remain
after felling until a later decay mechanic is introduced.

### Runtime API and data model

Proposed interfaces, names subject to Zig integration:

```zig
const ClimateId = enum(u8) { frozen, steppe, temperate, desert };

// Coordinates are storage block X/Y; X is normalized, Y must be in range.
fn climateAt(prepared: *const PreparedWorldGenerator, x: i64, y: u32) ClimateId;
fn fillClimateMap(prepared: *const PreparedWorldGenerator,
    column: HorizontalChunkCoords, out: *[32][32]ClimateId) void;
fn columnEnvironmentAt(prepared: *const PreparedWorldGenerator,
    x: i64, y: u32) ColumnEnvironment;
```

`ColumnEnvironment` includes climate, original terrain height, water level/presence,
mountain strength/class, vegetation class, and surface-cover intent. Query results are
derived values, not per-voxel metadata. Rich queries may evaluate indexed relief descriptors;
the cheap climate-only query does not. Map indexing is `[local_y][local_x]`, independent of Z.
Environmental profiles expose future work/farming flags and tunable multipliers. Clothing
and water needs are distinct flags; a later actor entering both conditions must not lose
one requirement merely because a rendering enum changes.

Add block types for leaves and resource materials with explicit collision, occlusion,
mining, placement, and foundation categories. Do not let an enum addition accidentally gain
all soil timers or construction privileges. Proposed consolidated ore/limestone/coal host
blocks act as natural rock for support and mine to their resource; clay is cohesive natural
ground with an explicitly chosen soil-like support category, without grass/compaction timers.
New raw resources need not be placeable building materials before their material design.
Sand is the already placeable exception. These categories require review in the material
phase; generic non-air occupancy is not a foundation contract.

For rendering, prefer a distinct `RenderMaterialId` in the existing face type byte: resolve
soil appearance from the column when meshing, preserve authoritative `BlockType`, and reserve
the render palette independently. Select the ordinary green, steppe yellow, or frozen snow
appearance from the single climate ID, with no transition weights, interpolated palette,
or extra GPU climate binding. This is a rendering derivation, never a saved block conversion.
Keep climate resolution shared by service meshing and optimistic client remeshing. Loose
soil in hand keeps its ordinary loose-soil appearance. The desert branch uses baseline
appearance for imported soil as specified in R15, rather than an undefined palette case.

### Persistence, caches, and shortcuts

Introduce a new generator ID (provisionally 2), schema version, compact explicit settings,
and independent layer seed tags. Keep the persisted descriptor within the existing 4-KiB
limit; rebuild macro grids, indices, and starting candidates deterministically during
preparation. No full-resolution climate map or generated deposit contents are saved up front.
Changes to material IDs, rounding, candidate order, or field semantics require version review.
Compare prepared-data fingerprints on reopen in tests to detect accidental drift.
Prepared macro maps, island/ridge/deposit indices, and climate-boundary inputs belong to
the prepared-world lifetime; evicting a column must not rebuild them. Cache contents are
derived accelerators, never inputs to generation decisions. Repeated generation of pristine
chunks must produce identical block bytes without writing those chunks to disk.

Extend `ColumnGenerator` to cache the 32×32 environment data needed for its vertical chunks.
Keep current bounded caches (presently 64 column generators and 512 boundary entries) unless
measurement justifies a separately budgeted change. Do not duplicate the macro map per
column/client. Consumers can share immutable prepared data with explicit lifetime ownership.

Track maximum terrain, water, and tree occupancy separately for empty shortcuts. Resource
intersection tests precede uniform-rock shortcuts. Enclosure needs only solid/occluding
occupancy, but any new shortcut proof must agree with generated boundary strips and material
rules. Retain the cave-free invariant; leaf canopies cannot certify an underground enclosure.

Proposed preparation memory gate: at most 32 MiB peak owned generator data/scratch for the
default profile, excluding live chunks and existing persistence/render allocations. Measure
preparation time and climate/column/chunk throughput before setting latency gates. The
one-million stored-chunk limit currently refers to stored records, not all possible world
coordinates; audit for any code that conflates these counts.

### Repeated-regeneration benchmark

Compare beaches enabled/disabled over identical prepared base geography in a stated release
build on the same machine. Separate the following costs instead of hiding them in a single
average or relying only on cached results:

- One-time preparation, including coarse geography and immutable feature indices.
- Cold column initialization: terrain/coast/climate, retained border samples, and beach mask.
- Repeated vertical chunk generation from one cached column.
- Revisit more than 64 distinct horizontal columns and regenerate their chunks after the
  current bounded column cache has actually discarded them; repeat the traversal.
- Complete generation/meshing workloads on plains, mainland/island coasts, steep shores,
  desert, dense forests, deposits, and the X seam.

Record terrain/feature sample counts, candidate maxima, allocations, peak owned scratch,
median/p95 wall time, and throughput. Separate generator work from meshing, disk, and GPU
upload costs. The beach comparison holds terrain heights/water occupancy fixed; differing
surface sand and resulting tree eligibility are expected, with stable layer seed streams.
Publish the measured budget before enabling beaches by default; no numerical speedup or
small percentage overhead is claimed by this design alone.

Hash original blocks and derived boundary/mesh results across repeated requests, explicit
cache eviction, different traversal orders, and fresh preparation/restart. Include negative/
wrapped-equivalent X coordinates and vertical chunks sharing a crown/deposit. Saved edited
chunks separately verify override authority. The benchmark must run without persisting
pristine chunks, enlarging cache limits, or redoing global preparation on each revisit.

### Milestones and affected components

| Milestone | Scope | Likely components |
| --- | --- | --- |
| G1: Environment foundation | New version/settings, larger default, pure climate queries, polar inset, diagnostics | `src/voxel_app/consts.zig`, `world_generator.zig`, proposed environment module, `terrain_collision.zig`, `standing_space.zig`, `player_controller.zig`, `main.zig` |
| G2: Land and relief | Connected continents and smaller islands, ocean, ranges, surface layering, safe first-start region | `world_generator.zig`, `perlin_noise.zig`, proposed geography/relief modules, `world_data_service.zig` |
| G3: Materials and geology | Opaque water, climate soil palette, sand local rules, indexed deposits, starter resources | `src/engine/voxel/voxel_chunk.zig`, `src/engine/shaders/voxel/`, `src/voxel_app/block_rules.zig`, `world_engine_glue.zig`, material/collision/mining code |
| G4: Vegetation | Forest/meadow fields, leaves, complete cross-chunk trees, mesh pressure checks | Proposed vegetation module, `world_generator.zig`, voxel/collision/render material code |
| G5: Integration | New-world save/reopen, edited-chunk authority, bounded caches, shortcut oracle, regeneration benchmarks, debug maps | `src/voxel_app/persistence/format.zig`, `main.zig`, `world_data_service.zig`, generator/service/GPU tests |
| F1: Later construction | Revisit the temporarily allowed soil platform over sand; foundation-to-rock rules and piles | Separate construction specification, then shared validator and support dependencies |
| F2: Later simulation | Farming prohibition, clothing/water services, action food cost | Future simulation specification, consuming the shared environmental API |

Module paths not already present are proposals. G1–G5 together are the planned generation
delivery; F1/F2 do not block exploring the generator, and must not be reported as implemented
merely because their environmental inputs exist.

### Risks and validation strategy

- **Topology versus visual coast detail:** protect land/water cores, prove refinement bounds,
  and compare exact reduced worlds with the macro/island result. Simplify unconstrained
  shoreline noise if necessary, while retaining the required first-iteration islands.
- **Geographic scale:** a four-chunk minimum frozen belt is small relative to this default
  world, while a 10% belt is approximately 3.3 km deep. Use overview maps and player-scale
  slices together; neither alone establishes good travel/resource balance.
- **Temporary sand foundation policy:** soil platforms above sand are explicitly allowed by
  R18, while sand stays outside broad structural predicates. Do not accidentally reject the
  permitted platform route or claim a foundation-to-rock proof that does not exist.
- **Forest face budget:** trees add substantial ordinary voxel faces. Exercise dense mixed
  forest/coast chunks against existing 4-MiB face capacity and 64-KiB per-chunk allocation,
  boundary invalidation, shadows, and capacity fallback. Do not silently truncate trees to
  hide a mesh-capacity failure.
- **Precision and reproducibility:** use canonical integer feature coordinates and stable
  hashes, validated periodic noise, explicit tie breaks, and bounded numerical operations.
  Golden outputs are versioned; supported builds must agree at material/boundary decisions.
- **False confidence from samples:** statistical appearance targets are measured on a
  published deterministic suite (proposed 64 seeds including the default 12345), with all
  failures reported. Exact connectivity/spacing/polar minima are checked structurally or
  exhaustively at the appropriate representation, not inferred from screenshots.

For implementation, combine focused generator/reference tests, client/service edit and
persistence regressions, the existing CPU/build suite, and relevant headless GPU tests.
Add visual overview layers for climate, continents, relief, vegetation, and resources;
inspect close views of transitions, sand/rock contact, water, and seam-crossing forests.
Record hardware/build mode, memory/candidate maxima, preparation time, query throughput,
and observed mesh allocation pressure. Do not claim the current 8/16-GB gameplay budget
merely from a compact macro map; complete residency remains separately measured.

## Tasks

### Phase 0 — Review the draft

- [ ] T1: Review remaining material-support categories and continent/island shape invariants;
  use seed maps to tune numeric terrain, forest, and resource settings, keeping settled
  climate, cover-timer, foliage, and temporary platform decisions fixed. [R3–R14, R18, R21–R27]
- [ ] T2: Prototype geography/refinement including islands and publish overview diagnostics
  before freezing the new generator settings/version. [R3–R8, R32, R34]

### Phase 1 — Shared environment and world bounds

- [ ] T3: Add versioned settings validation, pure climate/environment queries, and point/map
  equivalence plus seam/ordering tests. [R7–R12, R30–R32]
- [ ] T4: Change the voxel default dimensions; add shared playable-Y bounds to movement,
  climb, standing-space/recovery, and mode return. Retain explicit flat fixtures. [R1–R2, R28]
- [ ] T5: Add environment diagnostic export and bounded preparation accounting. [R32, R34]

### Phase 2 — Continents, water, and ranges

- [ ] T6: Implement connected macro continents, indexed smaller islands, bounded coast
  refinement, coarse land target, optional offline coverage estimator, and bounded
  deterministic retry/failure policy. [R3–R4, R30, R32]
- [ ] T7: Add shared sea level, ocean filling, sand/soil layering, indexed ranges, and
  conservative terrain/water occupancy bounds. [R5–R6, R15, R33]
- [ ] T8: Select/validate a safe first-start region; add spawn/access exclusions for later
  trees without relying on world origin. [R23, R29]

### Phase 3 — Materials, rendering, and resources

- [ ] T9: Add render-only climate soil appearances and opaque blue water, preserving saved
  soil and timers; verify CPU/GPU material layout and optimistic remeshing. [R13–R14, R19]
- [ ] T10: Implement distinct granular footprints, constructed-sand dependencies, and sand
  support rejection for buildings/roads, including seam and missing-data cases. [R16–R17]
- [ ] T11: Define resource material behavior, indexed deposit shapes/precedence, geology
  weights, effective-volume validation, and finite mining persistence. [R21–R24, R30–R33]
- [ ] T12: Reuse/insert the three starter pockets and verify local access on the final
  generated terrain. [R23, R29]
- [ ] T13: Prototype the bounded shallow beach overlay using retained terrain samples;
  measure enabled/disabled regeneration and include by default only within the measured
  budget, explicitly recording deferral otherwise. [R20, R35]

### Phase 4 — Vegetation and integration

- [ ] T14: Add leaves and forest/meadow fields; implement bounded globally prioritized tree
  candidates and complete-form clipping into chunks. [R25–R27]
- [ ] T15: Update column caches, boundary/enclosure/empty/rock shortcuts, and client/service
  generation paths; compare them with a slow reference. [R10–R11, R30, R32–R33]
- [ ] T16: Integrate new descriptor/material serialization and new-world save/reopen tests
  with edited/mined resources and removed tree blocks. [R30–R31]

### Follow-up specifications

- [ ] T17: Revisit the temporarily allowed soil-platform-over-sand route in a separate
  foundation/pile specification; any future restriction must explicitly supersede R18,
  while current generator delivery verifies the permitted platform behavior. [R18, AC23]
- [ ] T18: Specify NPC/farm/action consumers of environment profiles and their supply/cost
  accounting; keep exact economic multipliers outside generator geometry. [R11–R12]

### Validation

- [ ] T19: Implement the deterministic regeneration hash oracle and benchmark cached versus
  evicted columns, including the beach toggle and actual bounded-cache churn. Publish
  measured preparation/query/generation/meshing costs and owned scratch limits. [R30–R35]
- [ ] T-val: Verify all AC1–AC27 for G1–G5, including current AC22 environmental flags and
  AC23 permitted platforms; keep future F1/F2 tasks separate. Publish seed-suite maps/metrics
  and run relevant CPU/build/GPU/persistence checks, repeated-regeneration benchmarks, and
  player-scale visual inspection. [AC1–AC27]
