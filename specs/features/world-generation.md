---
service: zig_engine
created: 2026-10-22
updated: 2026-10-24
status: implemented
---

# Generate continents, climate belts, mountain ranges, deposits, and forests

## Intent

Give geography a useful role in settlement, construction, and transport: continents separate
regions, climate changes working conditions, forests concentrate wood, and finite deposits
justify building extraction and delivery infrastructure. Establish one deterministic source
of environmental data for generation, rendering, and future simulation.

Implementation of G1–G5 was authorized on 2026-10-23. Confirmed requirements remain the
acceptance contract; numeric tuning and the explicitly deferred follow-ups remain separate.
Implementation evidence and measured defaults are recorded in the
[validation report](../../docs/validation/world-generation/README.md).

## Context

- [Game vision](../../docs/game-vision.md) defines one-metre voxels, periodic X, finite Y/Z,
  physical logistics, and large exhaustible deposits. This feature adopts 60% land / 40%
  ocean, superseding the vision's earlier approximate half-ocean suggestion. Its candidate
  Voronoi algorithm is background, not an implementation constraint.
- Before this feature, [world configuration](../../docs/world-configuration.md) selected
  `512 × 256 × 8` **chunks**, each `32³` blocks. `WorldLayout` is immutable, coordinates are
  centred, and positive Y points north. Large storage Y therefore means north.
- [Voxel world](../../docs/voxel-world.md) describes a seeded, cave-free heightmap generator,
  prepared immutable noise tables, a bounded column cache, and regeneration of untouched
  chunks. The pre-feature generator had no continents, climate, deposits, or generated trees.
- [Block placement](../../docs/block-placement.md) already distinguishes loose soil,
  packed soil, and grass-covered packed soil. Compaction and surface timers are authoritative
  state. Sand previously bypassed structural placement checks; a stable soil platform can
  reset construction support counters without proving support down to underlying natural rock.
- [Country roads](country-roads.md) previously allowed cube-colliding materials as direct
  support. The sand and foliage restrictions deliberately narrow that rule.
- [World persistence](world-persistence.md) records dimensions, generator identity, seed,
  settings, changed blocks, construction metadata, and timers. Saved changes override
  generation. Existing storage bounds descriptor bytes to 4 KiB; a macro map must not be
  inserted into that descriptor without a separately designed format change.
  Legacy flat worlds used generator ID 0 with seed 0 and empty settings; terrain used ID 1.
  Both identities predate deeprock and must not be silently assigned the new output.
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
  requiring a full-world land-area census. Protected water gaps separate distinct islands
  from one another and from all continents; islands cannot merge into an extra large
  landmass or bridge two continents.
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
  only**; other continents and later spawns receive no equivalent guarantee. This guarantees
  physical placement/access, not permission to mine an unconfigured resource before its
  usable mining result and interaction flow are implemented (R36–R37).
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
  planting are deferred. Mining a trunk yields the existing trunk item. Leaves have an
  explicitly configured removal-without-item policy, distinct from forbidden resource
  mining; removing them leaves the inventory empty and requires null-safe prediction and
  authoritative handling (R36–R37).

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
  remain authoritative within mutable cells and never regenerate mined material or removed
  vegetation. They cannot override the canonical immutable deeprock layer (R38–R39). Untouched
  chunks may be generated arbitrarily many times and are not persisted merely to stabilize
  random outcomes. Beaches and islands obey the same determinism contract.
- R31: Use generator ID 2, generator version 1, with a mandatory settings profile tag
  (`natural` or `flat`); this identity versions the settings schema and layer algorithms.
  Both playable profiles persist a seed and use the canonical deeprock floor. Reject legacy
  ID 0 (seedless flat), ID 1 (old terrain), and unknown versions/profiles explicitly before
  preparation or worker startup; never reinterpret their descriptors as the new profiles.
  Backward compatibility and migration of old worlds are not required. Within a supported
  version, reopening must reproduce the same unmodified world and environmental queries.
  Persist compact inputs and deterministically rebuild prepared macro data. The selected
  runtime generator, settings, seed, and layout must match the persisted descriptor.
- R32: World creation and routine queries must not allocate block-resolution global maps
  or arrays for all possible chunks. Bound preparation memory, candidate lists, retries,
  feature-index occupancy, column caches, and per-chunk generation work. Preserve existing
  residency/backpressure behavior rather than assuming the enlarged world fits in memory.
- R33: Rework generation shortcuts so they cannot omit water, crowns, deposits, or deeprock.
  Empty shortcuts require bounds on all generated occupancy; stone shortcuts require proof that
  no material overlay intersects. Enclosure/occlusion certification must remain conservative
  for every new material and use the same generation source as actual chunks.
- R34: Provide reproducible diagnostic maps and seed-batch measurements for continent
  connectivity, land coverage, climate areas over world and land, relief, vegetation,
  deposit locations/effective sizes, starting access, preparation cost, and forest mesh
  pressure. Full/fine land-coverage measurements are optional offline diagnostics, not a
  runtime dependency of climate queries or chunk regeneration. Statistical tuning claims
  must be distinguished from deterministic invariants. Preparation reports distinguish
  invalid configuration, rejected candidates, terminal failures, and exhausted seeds (R42).
- R35: Treat repeated regeneration of untouched chunks as a normal measured workload.
  Expensive bounded macro preparation happens once per prepared-world lifetime, never per
  chunk or cache refill. Benchmark cached and evicted column generation separately, retaining
  existing bounded caches; performance must not depend on eventual disk persistence or an
  indefinitely warm column cache. Measure the beach overlay separately before enabling it.

### Mining capability and immutable world floor

- R36: Mining/removal eligibility is an explicit material capability, independent of
  placement, collision, face occlusion, and structural support. Default newly added or
  unconfigured materials to forbidden mining rather than yielding their own block ID.
  Ore, limestone, clay, and coal remain visible, solid geological resources but cannot be
  mined until their usable result and interaction flow are explicitly configured. Existing
  configured materials, including sand, retain their mining conversions. A separately
  configured non-resource removal without an item, such as clearing foliage, is permitted;
  an absent result alone never grants permission to delete a block. Share this policy
  between client prediction and authoritative player, spectator-edit, and simulation
  removal paths. Rejection changes no blocks, inventory, timers, metadata, or revisions.
- R37: A successful item-yielding extraction must produce an item supported by the current
  inventory/persistence schema with an implemented way to use it and empty the slot.
  For the current single-block inventory, only its configured placeable mining results
  satisfy that contract; do not insert new unplaceable raw resources and strand the slot.
  Future resource features must configure the complete use/transfer flow before enabling
  their mining. Preserve the current empty-slot prerequisite for player mining, including
  foliage clearing: an occupied slot rejects removal without changing the carried item.
  Explicit removal without an item succeeds with `mined_type = null`, keeps the initially
  empty slot empty, and follows ordinary acknowledgement/reconciliation and save/reopen.
  Prediction and authority must not unconditionally unwrap successful removal results.
- R38: Add a distinct `deeprock` material at the world's absolute storage bottom. For each
  canonical horizontal column, choose deterministic irregular thickness `B(x,y)` in [1,3]
  blocks and fill **every** storage cell `0 <= z < B(x,y)` with deeprock. Thus z=0 is a
  complete sealed layer and no deeprock cell has a hole or different material underneath.
  The formation lies wholly in the lowest Z chunk and covers the entire X/Y footprint,
  including oceans, islands, and inaccessible polar strips. X wrapping and regeneration
  preserve exactly the same thickness. Deeprock is opaque, full-cube-colliding, non-placeable,
  yields no item, and is a stable direct foundation under R41. Ordinary rock above it stays subject
  to its configured mining policy.
- R39: Deeprock is permanently immutable by every supported world-changing operation, not
  merely unavailable to the player's mining tool. Canonical deeprock cells cannot be removed,
  replaced, moved, or transformed by player/spectator edits, NPC/simulation actions, timers,
  road/bulk/indirect writes, or runtime debug tools. Generation and resource/surface overlays
  must preserve them. Validate complete authoritative write sets before committing effects,
  and keep optimistic replay subject to the same invariant. Planners may deliberately
  exclude immutable cells; a rejected transaction cannot commit partial effects. Saved/WAL
  data cannot override the layer: conflicting restored deeprock is rejected as invalid world
  data before publishing or using that restored chunk, with no silent regeneration of
  modified chunks or loss of valid edits above the layer. Validate lazily loaded records
  without requiring an all-world scan on reopen.
- R40: Keep the finite lower-Z boundary as an independent impassable guard, in addition to
  deeprock collision. No player body may cross below storage Z=0 through falling, climbing,
  high-speed motion, teleport, mode changes, recovery,
  or unavailable terrain. Validate destinations/restored poses before activation or resolve
  them to valid standing space. Apply layout-origin conversion correctly: negative centred
  world Z can be valid, while below the layout's storage bottom is always forbidden.
- R41: A single exposed deeprock cell provides a stable direct foundation for wood/mineral
  construction and roads resting on its top. No surrounding `3 × 3` area or centred
  `3 × 3 × 3` platform is required; irregular neighboring deeprock heights do not invalidate
  that contact. Construction height counters restart above the foundation, with the first
  placed block at level one; ordinary height/span limits still apply. Soil and sand retain
  their separate filled `3 × 3` support footprints, in which deeprock qualifies as structural
  support and one cell fills one position. Blocks placed above deeprock keep their own
  material, support rules, and mutability.

### Preparation failure contract

- R42: Validate profile/settings/layout independently of candidate generation. Unsupported
  identities and invalid configuration fail with zero candidate attempts; no retry can fix
  impossible climate widths, unsafe arithmetic, invalid parameters, or provably inadequate
  configured capacities. Candidate-specific topology, placement, deposit, index-occupancy,
  or starter-access failure consumes one of at most eight natural-layout attempts. Allocation,
  cancellation, work/memory-budget exhaustion, and internal invariant failures abort rather
  than trigger another candidate. After eight candidate rejections, return `SeedRejected`
  with the reasons; never silently change settings, seed, or capacities. Record stable failure
  category/reason, stage, profile/identity, original seed, attempt index/count, and relevant
  limits/observed values. Rebuilding selects the same first accepted candidate in index order.

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
  deferred; original natural-rock surface heights do not substitute for future live support.
  This ordinary foundation rock is distinct from the immutable bottom `deeprock` material.
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
  A13: IMPLEMENTED: reuse the refined coast/terrain samples and a small retained neighbor strip
  for slope, then change only a shallow surface material. This adds bounded arithmetic
  rather than recursive terrain generation or neighbor-chunk reads. Enabled/disabled
  regeneration measurements show location-dependent cost; beaches remain optional and
  disabled by default. See the validation report. Deterministic regeneration is
  a confirmed requirement, including with empty caches and after restart.
- Q14: What happens to new resources without an implemented use?
  A14: CONFIRMED on 2026-10-23, addressing [PR #37's inventory review comment](https://github.com/bacher/zig_engine/pull/37#discussion_r4349879370):
  they cannot be mined until explicitly configured with a supported usable result/flow.
  This is a temporary resource-development state, not an intended finished-game dead end.
  Use an explicit default-deny mining capability that also supports permanently unmineable
  materials. Foliage clearing is an explicit no-item removal, not an implicit exception for
  arbitrary unconfigured resource types, and must handle a null result safely.
- Q15: What seals the absolute world bottom?
  A15: CONFIRMED on 2026-10-23: a permanently indestructible `deeprock` formation, 1–3 blocks
  thick per column with deterministic irregular top height. All cells below its top are
  deeprock down to storage z=0; no voids. Mining, replacement, indirect mutation, or traversal
  cannot create a route below the world. The thickness rule is shared by generation and
  restoration validation and does not need a stored full-world map.
  The confirmed material name is `deeprock`; a single exposed cell is a stable direct
  foundation without a `3 × 3` area/platform requirement, as detailed in R41.
- Q16: Does the new generator identity cover playable flat worlds?
  A16: DESIGN DECISION: yes, ID 2 / version 1 has explicit `natural` and `flat` profiles.
  Flat is no longer the seedless legacy ID 0; it persists its seed and profile settings,
  reproduces deeprock, and skips natural geography/climate-width preparation. Reject old
  identities rather than migrating or silently changing their generated output.

- Q17: How does generated clay support construction?
  A17: CONFIRMED on 2026-10-23: use packed-soil support, including the complete stable
  platform requirement, without compaction or grass timers. Clay remains unmineable until
  its resource flow is configured.
- Q18: Which continental construction should the implementation use?
  A18: CONFIRMED on 2026-10-23 after reviewing analytic prototype seed maps: retain
  coarse-grid growth with protected cores. The analytic prototype was too regular.

## Acceptance Criteria

The milestones below separate generator delivery from future gameplay consumers. They are
verification requirements; executed checks and their limits are recorded in the validation report.
All listed criteria cover generation delivery, including current environmental flags and
the temporarily allowed soil platform. Future foundation/NPC execution and material
consolidation tasks remain separate.

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
  without ocean crossing, and the final standing-space check accepts current blocks.
  Physical reachability does not enable mining of unconfigured clay/coal. [R23, R29, R36]
- AC15: GIVEN trees spanning all three chunk axes and the X seam WHEN generating chunks
  separately, in reverse order, and after eviction THEN complete 4–5-trunk-block trees
  reassemble identically, with no overlaps, terrain intersections, or forbidden climate
  occupancy. [R25–R27, R30]
- AC16: GIVEN temperate forest and meadow regions WHEN sampling tree density and biome
  boundaries THEN forests contain substantially more trees, boundaries cut across chunks,
  frozen columns contain no trees/bushes, and steppe/desert match configured scarcity. [R26]
- AC17: GIVEN foliage WHEN colliding, building, mining, and meshing THEN it has the agreed
  opaque cube behavior, provides no structural support or useful item, and configured
  no-item clearing succeeds without a constructed-tree rejection or a null-result panic;
  trunk mining continues to yield the trunk item. [R27, R36–R37]
- AC18: GIVEN an actor approaching either polar inset at any height WHEN moving, climbing,
  spawning, teleporting, or recovering THEN the whole body remains in playable Y, with no
  stored wall blocks or blocked-chunk loads required to establish the barrier. [R28–R29]
- AC19: GIVEN modified/mined chunks and an unchanged world descriptor WHEN saving,
  evicting, and reopening THEN current blocks/metadata override regeneration and climate
  stays identical within mutable cells; canonical deeprock remains unchanged and an
  unsupported generator version is reported explicitly. Mining fixtures use sand or an
  explicitly configured usable test resource. [R30–R31, R36–R39]
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
  worker startup with a clear configuration error and zero candidate attempts; small flat
  fixtures use the explicit new flat identity and zero inset without weakening natural-profile
  bounds. [R8, R28, R31–R32, R42]
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
- AC28: GIVEN an unconfigured material or an unconfigured ore/limestone/clay/coal block
  WHEN player prediction, authority, spectator edits, or simulation requests its removal
  THEN the operation is explicitly rejected and its block, inventory, timers, metadata,
  and revisions remain unchanged. A newly added material receives this default without
  inheriting a self-yielding mining fallback. [R36]
- AC29: GIVEN an empty player inventory, configured ordinary mining, and explicit foliage
  removal without an item WHEN completing, acknowledging, saving, and reopening those
  operations THEN item-yielding extraction produces only a usable supported inventory item
  that can be placed to free the slot; foliage clearing succeeds with an empty slot and no null unwrap,
  reconciliation deadlock, phantom item, or save failure. With an occupied slot, foliage
  removal is rejected and both the leaf block and carried item remain intact. [R27, R37]
- AC30: GIVEN fixed seeds and columns including ocean, islands, poles, and the wrapped seam
  WHEN generating/revisiting the lowest Z chunk THEN each thickness is in [1,3], all cells
  below its top through z=0 are deeprock, the top varies over the fixture, and reordered
  requests, cache eviction, and restart reproduce the same filled layer. [R30, R38]
- AC31: GIVEN bottom chunks and overlapping deposits/surface overlays WHEN comparing all
  optimized generation paths with a slow material reference THEN deeprock has priority,
  no air/water/resource replaces it, and stone shortcuts preserve its exact irregular
  shape while ordinary mineable stone above remains available. [R24, R33, R38–R39]
- AC32: GIVEN a protected deeprock cell and a multi-cell operation with valid mutable targets
  WHEN removal/replacement/transformation is attempted through direct, indirect, optimistic,
  timer, road, simulation, or runtime debug paths THEN the protected layer is unchanged,
  a rejected transaction commits no partial effects or item grants, and a clear
  immutable-material failure is reported. An explicitly filtered bulk plan may change its
  remaining mutable targets while leaving deeprock intact. [R36, R39]
- AC33: GIVEN a valid edited bottom chunk and an invalid record removing/replacing deeprock
  WHEN saving/reopening or restoring base/WAL contents THEN valid upper edits and the
  canonical layer survive, while the invalid record is rejected before that restored chunk
  is published/used rather than overriding deeprock or regenerating the modified chunk.
  Lazy restoration does not scan all world records on reopen. [R31, R38–R39]
- AC34: GIVEN exposed deeprock, missing terrain, or a pose/destination below the storage floor
  WHEN falling quickly, climbing, teleporting, restoring/recovering, or switching to/from
  spectator mode THEN the active player body stays at or above the valid world lower bound;
  no missing chunk, tunnelling, origin-conversion error, or return from a debug camera
  permits the player to enter below it. [R40]
- AC35: GIVEN an exposed deeprock top with lower neighboring cells and no centred
  `3 × 3 × 3` platform WHEN placing wood/mineral construction or a road directly on it
  THEN the shared client/service rules accept that direct foundation without a `3 × 3`
  area check, start applicable height counters at level one, and retain ordinary height/span
  limits above it. Soil/sand still require their complete `3 × 3` footprint, and placed
  blocks do not inherit deeprock's immutability or foundation privileges. [R41]
- AC36: GIVEN ID 2 / version 1 descriptors for natural and flat profiles WHEN creating,
  saving, and reopening their worlds THEN the profile/settings/seed/layout and canonical
  deeprock match. Legacy ID 0 with empty settings, legacy ID 1, unknown versions/profiles,
  malformed or cross-profile settings, and mismatched runtime generator/seed/layout are
  rejected before preparation or service-worker startup, without fallback dispatch. [R31, R38]
- AC37: GIVEN adversarial final-column topology fixtures WHEN comparing their cylindrical
  four-neighbor land graph with the protected cores THEN diagonal-only mainland connections
  fail, minimum-width necks retain a protected path under maximal allowed coast displacement,
  seam-crossing islands count once, and islands near two continents preserve both water gaps.
  Deliberately severed necks, orphan mainland fragments, and forced island bridges, merged
  island chains, or gap breaches are detected even when macro owner labels still look valid.
  [R3, R30, R34]
- AC38: GIVEN invalid settings, retryable candidate failures, and terminal failure injection
  WHEN preparing a world THEN invalid settings use zero attempts, each candidate rejection
  consumes exactly one of at most eight attempts, and terminal errors stop without retry.
  Identical inputs produce the same first accepted candidate or `SeedRejected` trace; no
  partial prepared world is published and diagnostics identify category, reason, stage,
  identity/seed, attempt, and relevant bounds. [R32, R34, R42]

## Constraints

- Keep generation immutable after preparation and safe for independent consumers. No global
  advancing PRNG, generated-neighbor dependency, observation-dependent resource creation, or
  GPU-owned biome truth. New stochastic layers use named seed streams and canonical X.
- Climate queries describe location; material/support queries use **current authoritative
  blocks**. A generated deposit descriptor is not remaining stock, a generated height is
  not current clearance, and an original natural-rock horizon does not prove a current
  foundation. Canonical bottom deeprock is a separate immutable coordinate/material invariant.
- Preserve byte-sized block storage and the four-byte ordinary voxel face record where
  practical. Palette/render IDs need a separate type and must not enter persistence or block
  operations. Custom road sentinel 255 remains reserved.
- Preserve missing-data handling, authoritative edit checks, atomic response packages,
  persistence revisions, and the fixed support-window discipline. Any expansion of support
  dependencies requires a separate reviewed construction design.
- Preparation validates identity/profile, finite parameters, safe arithmetic, periodic noise
  bounds, climate widths, and capacity feasibility before attempts in all build modes. Keep
  retryable candidate capacity/topology checks separate from terminal allocation/budget errors
  under R42; do not silently publish a world that fails its geography contract.
- Performance numbers below are proposed engineering gates to measure, not observations.
  Cross-platform regeneration must have a documented numerical/determinism contract before
  its generator version is frozen; pin algorithm/hash/rounding and test supported targets.

## Out of Scope

Old-save migration; spherical or
toroidal topology; seasons; altitude-driven climate; jungle; bushes; multiple tree species;
texture/color blending between climates; dynamic water, swimming, ice, rivers, hydrology,
erosion, and caves; extraction buildings,
processing recipes, prospecting UI, and transport simulation; research gates; farming/NPC
work execution and supply accounting; complete foundation/pile mechanics; tree growth,
automatic felling, leaf decay, and physical collapse. Optional beaches may be deferred.

Full consolidation of material behavior definitions and predicates is a follow-up after
G1–G5 (F3); the material rules and shared safety checks required below remain in scope.

## Plan

G1–G5 are implemented. The result below records the delivered design; remaining proposed
tuning values describe design experiments rather than confirmed economic balance.

### Implementation result

The natural generator uses weighted cardinal macro-grid growth, erosion-only row-interval
coasts with protected cell-center bridges, and separated connected island footprints.
Distinct continent owners cannot occupy neighboring macro cells, including diagonals.
This construction replaces the draft's provisional two-macro-cell neck heuristic with
explicit surviving cardinal paths. Final-column reduced and adversarial fixtures verify
the core/component and water-gap contracts. The 61% coarse target produces approximately
60.74% sampled final land across seeds 12345–12408; normal preparation performs no fine census.

Fixed-point integer fields and named SplitMix64 streams drive climate, terrain, one winding
ridge per mainland, geology, and vegetation. Bounded deposit descriptors use exact integer
per-column ellipsoid span counts; complete tree candidates use global priority and conflict
halos. Preparation retains compact immutable data, categorized failures, and an eight-attempt
cap. Natural generation deliberately has no uniform-stone shortcut; conservative bounds
and the slow material oracle protect deposits, crowns, water, and deeprock.

Generator ID 2/version 1 has mandatory natural/flat settings profiles and seeded deeprock.
Runtime integration shares climate queries, mining policy, and canonical mutation guards;
render-only soil appearances do not enter saves. Both profiles reject invalid restored floors
before publishing chunks. Clay uses packed-soil-style support without soil timers, and new
raw resources remain unmineable. Beaches are implemented as a bounded optional overlay and
remain disabled by default after measuring location-dependent regeneration cost.

The [validation report](../../docs/validation/world-generation/README.md) contains all
AC1–AC38 evidence, seed maps/raw measurements, memory and regeneration timings, CPU/GPU
results, and execution limits. F1–F3 remain deferred: stronger foundations/piles, NPC/farm
execution, and material-definition consolidation.

### Approach

For the natural profile, use this dependency order, without conflating layers:

```text
generator ID/version + profile + dimensions + seed + settings
  -> immutable bottom mask (independent per column)
  -> connected continental layout + islands / coast / ocean
  -> periodic climate + geological provinces
  -> relief ranges + detailed terrain + surface cover
  -> first-start region + indexed deposits + starter pockets
  -> vegetation fields + deterministic tree candidates
  -> generated blocks / climate-aware render material
  -> saved edits override mutable generated cells; validate immutable bottom on restoration
```

Climate is also directly queryable from prepared inputs; it does not require the intervening
block-generation stages. First-start selection and starter deposits happen before trees,
so tree exclusion around the spawn/access patches does not create a circular dependency.
The bottom mask is independently queryable and has priority over every material overlay;
geography, climate, and feature preparation do not depend on enumerating that mask.

### Continental layout and height

At default dimensions, start with a `512 × 256` macro grid: one cell covers `128 × 128`
blocks (four horizontal chunks per side), only 131,072 cells. Use compact fields for land
ownership, coastal distance, geological province, and growth/protection flags. This grid
guides large-scale geography, never assigns a whole chunk its climate or vegetation.

1. Choose K in [3,5] and well-separated seeds on the cylindrical macro grid. Use
   deterministic weighted cardinal growth to allocate influence areas.
2. Grow connected land cores from the K seeds while reserving water corridors between
   continents. Prefer irregular broad shapes, bays, and nonuniform mainland sizes. Protect
   a connected interior spine and avoid narrow accidental isthmuses.
3. Grow toward 61% macro land, leaving approximately 60% after coast erosion. Validate actual
   component
   connectivity, not just K different owner labels. Across X, neighbors use modulo width;
   north/south do not connect. Reject a growth cell adjacent to another owner in its
   eight-neighbor macro neighborhood. Keep connected row intervals containing each owned
   cell's center and shared cardinal bridges during 8–24-block coast erosion. Smaller islands
   add a bounded amount of land; no exact final-area quota or per-continent percentage is required.
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
   protected straits where they could join continents and preserve water gaps between
   distinct island descriptors. Their coasts, resources, vegetation,
   and climate follow the same field/material rules as mainland terrain.
6. Use at most eight deterministic candidate layouts, with stable growth/tie-break IDs.
   Validate configuration first, then consume an attempt only for candidate-specific
   rejection under R42. Reject preparation explicitly if none meets validity/capacity gates.
   Do not run full-resolution land counting or coverage-driven fine sampling on this path;
   approximate coverage comes from coarse construction targets. No unbounded seed loop or
   fallback to a single continent.

#### Continuous mainland coast proximity

Ownership and bounded erosion decide the land/water footprint. A separate approximate
coast coordinate drives rolling relief, ridge fading, deposit sizing, and optional beaches.
It must not reset at internal macro-cell edges.

Prepare one packed `u16` per macro cell: four exposed-edge bits and the maximum erosion
trim across its exposed edges. Vertical-edge trim is monotone within a 128-block cell
because its noise scale is 256; endpoint samples therefore bound it. Horizontal trims are
constant within the cell. Represent each exposed fringe by a finite edge rectangle of that
maximum width, including its endcaps. These rectangles contain the actual eroded water
fringes and extend inland by at most 16 blocks.

For a column, query the surrounding `3 × 3` macro records and calculate
`C = min(128, max(0, nearest_rectangle_distance_L_infinity - 1))`. Any omitted rectangle is
already beyond this cap, so a feature cannot disappear prematurely at a neighborhood join.
For inland depth, derive each shared macro vertex from the minimum BFS distance of its four
incident cells, multiplied by 128 and capped at 4098. Bilinearly interpolate these shared
vertices with one final integer floor to obtain `B`. Use
`F = min(4096, C + max(0, B - 130))` as the mainland coast coordinate.

`C` and `B` each change by at most one per cardinal column step; `F` changes by at most two,
including across the X seam. `F` is zero at every real mainland shore. Its zero-valued land
collar may be up to 16 blocks wider than the actual shore; inland values are an approximate
relief coordinate, without an exact-distance guarantee. Keep the existing analytic island
coast coordinate separate from this mainland proof. These coordinates describe generated
geography, not the distance to current player-edited water.

Queries have a fixed ceiling of nine records and 36 rectangle checks, without a tree walk,
new noise evaluations, or allocations. Preparation adds at most six trim probes per macro
cell. Free growth/BFS scratch before allocating the records: retained geography is `5N`
bytes and peak geography remains `16N` bytes for `N` macro cells, plus the prepared-world
object. Share these bounds between preparation, preflight, and tests.

#### Adversarial topology fixtures

Use exhaustive bounded/reduced fixtures of final generated columns, not just macro owner
labels. A land vertex is a column satisfying `H >= S`; edges are cardinal X/Y neighbors,
with X modulo width and no Y wrapping. Each intended mainland column must reach its assigned
protected core; every mainland component contains exactly one core, and an intended island
component contains none. Each island ID maps to one separate connected component; distinct
island IDs cannot merge. Check protected water gaps separately from graph connectivity.

| Fixture | Required result on final columns |
| --- | --- |
| Two mainland lobes joined only at a corner | No cardinal path: reject a candidate claiming both belong to one core. Distinct diagonal-touching components remain distinct; separately reject any required water-gap violation. |
| Neck at the configured minimum width, with maximal permitted coast displacement | The protected cardinal spine survives. Include a deliberately severed/below-minimum result that must fail despite unchanged macro labels; incompatible width/displacement settings fail preflight instead. |
| An island straddling X=0 | One connected island, counted once, with identical samples at X and X±width. Opposite Y edges never connect. |
| An island approaching two different continents | Preserve both protected gaps and both mainland components; reject forced face-connected bridges or clearance breaches, including diagonal approaches. |
| Mainland fragment detached by refinement, plus multiple islands in a strait | Detect the orphan mainland fragment instead of relabeling it as an island. An island chain cannot bridge protected mainland cores; distinct islands must retain water gaps, including when merging would create an extra large landmass without a core. |

Compare the final component/core membership against the intended protected-core and island
assignments, including valid controls and deliberately invalid variants. Run these in tests
and offline diagnostics; they do not add a full-resolution world scan to normal preparation.

Offline diagnostic exports measure final coverage, including islands, with a deterministic
jittered sample in each `128 × 128` block tile and an independently offset pass (131,072
samples per pass at default size). Report estimator disagreement; this is not an
independent-trial statistical confidence bound. Reduced topology fixtures enumerate final
columns exactly to verify connectivity separately from sampled coverage.
These scans run in the diagnostic tool, never during ordinary world preparation, column
cache refill, or regeneration. Climate construction always uses total X/Y extent directly.

Define `terrain_height` as the first cell above terrain: ground occupies `0 <= z < H`.
Water occupies `H <= z < S` only where `H < S`, with sea surface at S. Land columns satisfy
`H >= S`; protected land uses `H >= S+1` and protected water uses `H <= S-1` to leave margin.
Track terrain height, water surface, and maximum generated occupancy separately.

Implemented tuning at default height: sea level 384 blocks, ocean depth 8–148 blocks,
ordinary rolling-land component 1–49 blocks before coast/detail, mountain uplift up to 320
blocks. Clamp all results with room above for full tree crowns; retain solid bottom terrain. Shape continental shelf
and inland relief without making a vertical cliff around every coast.

### Preparation validation and failure reporting

Validate identity, profile payload, layout, and settings before any candidate work. Check
finite/range-safe arithmetic, periodic-field bounds, climate width/displacement feasibility,
coast protection widths, positive feature limits, and any statically provable capacity or
preparation-budget impossibility. In particular, frozen/intermediate belts that cannot fit
are invalid settings even if some seed happens to produce narrower boundary excursions.
Flat validates its own fields and finite floor/headroom; natural-only climate/geography
constraints do not apply to it.

Use named categories with stable reason codes; names below are the intended API semantics:

| Category | Examples/reasons | Action |
| --- | --- | --- |
| `UnsupportedGenerator` | Legacy/unknown generator ID, version, or profile | Fail before preparation; zero attempts. |
| `InvalidConfiguration` | `MalformedSettings`, `InvalidLayout`, `UnsafeNumericRange`, `InvalidClimateWidths`, `InvalidCoastBounds`, `InfeasibleCapacity`, descriptor/runtime mismatch | Fail preflight; zero attempts. |
| `CandidateRejected` | `TopologyConflict`, `RequiredFeaturePlacement`, `FeatureIndexCapacity`, `DepositValidity`, `StartAccessUnavailable` | Discard that candidate and consume one attempt; try the next index. |
| `PreparationAborted` | `AllocationFailed`, `Cancelled`, `WorkBudgetExceeded`, `MemoryBudgetExceeded`, `InternalInvariantFailure` | Clean up and stop immediately; do not resample or report the seed as exhausted. |
| `SeedRejected` | Eight `CandidateRejected` results with no accepted layout | Stop and report the complete bounded rejection trace. |

A positive index capacity that overflows only because of a particular feature distribution
is `CandidateRejected.FeatureIndexCapacity`. A capacity below a proven mandatory minimum is
`InvalidConfiguration.InfeasibleCapacity`; allocation failure is `PreparationAborted`.
Do not hide implementation bugs, failed immutable-cell guards, or budget overruns inside
the topology/candidate retry path.

For natural candidate i in [0,7], derive layout and dependent feature streams from the
original world seed, named tags, and i. Keep independent climate/deeprock streams unchanged.
Accept the lowest valid candidate index, regardless of parallel task completion order.
All local placement/access searches are separately bounded; they do not create additional
outer sets of eight attempts. Flat performs no layout search. Never publish partially
prepared data, enlarge limits, or switch to a different user seed as a fallback.

Diagnostics and seed-batch reports retain identity/profile, original seed, stage, category,
reason, optional candidate index, attempts started, candidates rejected, and applicable
observed values/limits. Exhaustion records all eight rejection reasons; preflight records
zero attempts. Reopen uses the same deterministic selection and reports failure explicitly.

### Immutable bottom formation

For each canonical storage column, compute the thickness directly:

```text
B(x,y) = 1 + stableHash(seed ^ DEEPROCK_TAG, canonicalX, storageY) % 3
material(x,y,z) = deeprock for every 0 <= storageZ < B(x,y)
```

Pin the hash, named layer tag, coordinate encoding, and unsigned wrapping arithmetic to
the generator version. This is one hash per horizontal column in the lowest Z chunk;
no noise halo, neighboring chunk, global map, or additional random stream state is needed.
Require original terrain height to be at least three blocks. Apply the same sealed-floor
rule to playable natural and flat profiles; isolated test fixtures must state their own
material setup explicitly rather than accidentally relying on a floor-free playable profile.

Resolve deeprock before ordinary rock, deposits, soil, sand/beaches, water, and vegetation.
Host replacement cannot target it. The existing `initSolid(stone)` shortcut must fill the
canonical bottom mask when used in the lowest chunk; higher uniform rock chunks retain
their shortcut. A slow reference uses the identical mask and makes this priority testable.
This material is distinct from ordinary natural rock used in desert foundation discussions.

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

Use one seeded winding ridge field per mainland, with periodic X, varying uplift, coast
taper, and zero strength in frozen columns. Reuse the displaced climate boundaries to fade
uplift linearly over the nearest `max(128, min(1024, world_height / 32))` nonfrozen rows;
both nonfrozen rows immediately adjoining frozen climate have zero uplift. This avoids
a height step when the climate ID changes. Geography can split a ridge into segments.
Branched polylines are not required by the first version. Store a mountain-strength
field distinct from final height; low rolling terrain is not a mountain merely because its
absolute elevation is high.

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

Use explicit immutable descriptors: stable ID, resource, size class, centre, radii,
host restrictions, priority, and effective block count. The first version uses connected
axis-aligned ellipsoids, with deterministic placement streams and disjoint bounding boxes,
rather than scattered per-block ore chance.
The majority of a large deposit should be a connected resource body. Do not fill a huge
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
Cap candidate descriptors per bin and total references; placement-dependent overflow rejects
the candidate as `FeatureIndexCapacity` under R42. Large descriptors may use a second index
level rather than referencing every small bin. Query candidate overlays once per chunk/column
where possible, not all world deposits for every voxel.

Resolve overlap by an explicit total order `(priority, stable_deposit_id)` and validate
effective remaining volume/connectivity after host clipping and competing overlays. Resource
blocks never replace deeprock, water, air, or tree voxels. Preserve the desert sand surface
except intentional rocky outcrops; underground clay does not create a grass/soil desert surface.
Startup proves large-host boxes from every covered macro cell and counts exact vertical
ellipsoid spans per XY column, without enumerating every 3D voxel. Small/starter pockets
also validate clipping and connected center planes. All work is bounded by the preparation
budget; fingerprints hash descriptors/prepared data, not all resource voxels. Diagnostics
distinguish exact counts from sampled spatial allocation and eligible-host volume.

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
Descriptors and physical starter access do not grant mining permission: resource materials
remain forbidden until their complete usable-result flow is configured under R36–R37.

### Vegetation and trees

Use a periodic moisture/vegetation field and broad thresholds for temperate forest versus
meadow. Scale broad patches in blocks, with finer edge variation, rather than assigning
chunk labels. Proposed forest coverage is 35–55% of eligible temperate land; no global
quota is required in the first prototype.

Implemented density parameters per 10,000 eligible ground columns: forest 100, meadow 5,
steppe 1, desert 0, frozen 0. Mountains reduce density through slope/soil eligibility.
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

Add block types for leaves, deeprock, and resource materials with explicit collision, occlusion,
mining, placement, and foundation categories. Do not let an enum addition accidentally gain
all soil timers or construction privileges. Proposed consolidated ore/limestone/coal host
blocks act as natural rock for support; clay is cohesive natural ground with an explicitly
chosen soil-like support category, without grass/compaction timers.
New raw resources need not be placeable building materials before their material design.
Sand is the already placeable exception. Ore, limestone, clay, and coal remain unmineable
until explicitly configured with supported usable results. Deeprock is opaque, colliding,
non-placeable stable direct support, with forbidden removal and permanent mutation protection.
These categories require review in the material phase; generic non-air occupancy is not a
foundation contract.

Recognize deeprock directly in the shared foundation validator before testing for a centred
`3 × 3 × 3` stable platform. A single supporting deeprock top is sufficient for ordinary
wood/mineral construction and road contact even along the formation's irregular surface;
the foundation check must not request a complete box below the world's floor. Preserve
height/span accounting above that contact and separate soil/sand footprint validation:
deeprock fills an individual structural footprint cell but does not waive the other eight.

Establish one production mining policy and one mutation guard, shared by prediction and
authority, before integrating new material edit paths (T20/T21). Callers use those shared
implementations from the start; local copies pending F3 are not an acceptable intermediate
implementation. F3 consolidates the wider material definitions after G1–G5.

Make the mining outcome explicit, separately from placement and immutability:

```zig
const MiningPolicy = union(enum) {
    forbidden,
    remove_without_item,
    yields: BlockType, // Current inventory representation; not a future item-system design.
};
```

Material lookup defaults to `.forbidden`; enumerate configured conversions explicitly rather
than using `else => self`. Keep existing dirt/grass/packed-soil conversions, sand, stone,
and other configured current results. Leaves explicitly use `.remove_without_item`.
Neither `isPlaceable()` nor a null yield grants permission to remove a block. Item-yielding
policies must agree with current inventory validation and offer an implemented way to place
the result. Registering a future raw resource alone cannot activate its mining.

Check the same policy before optimistic removal and authoritative commit. Preserve the
occupied-slot gate even for no-item clearing. Successful no-item removal still has the
ordinary success/acknowledgement path but no inventory assignment; replace unconditional
`mined_type.?` handling in prediction and authority with explicit outcome handling. Test
acknowledgement, rollback, the next interaction, and saving an empty slot after leaf removal.

For rendering, prefer a distinct `RenderMaterialId` in the existing face type byte: resolve
soil appearance from the column when meshing, preserve authoritative `BlockType`, and reserve
the render palette independently. Select the ordinary green, steppe yellow, or frozen snow
appearance from the single climate ID, with no transition weights, interpolated palette,
or extra GPU climate binding. This is a rendering derivation, never a saved block conversion.
Keep climate resolution shared by service meshing and optimistic client remeshing. Loose
soil in hand keeps its ordinary loose-soil appearance. The desert branch uses baseline
appearance for imported soil as specified in R15, rather than an undefined palette case.

#### Follow-up improvement — material behavior matrix

After the first G1–G5 implementation, consolidate the material rules into one behavior
matrix here, alongside the runtime data model. Cover soil states, sand, water, foliage,
deeprock, and each resource separately. List collision, face occlusion, mining policy/result
(forbidden, no item, or a usable item), placeability, required placement footprint and ability
to support soil/sand footprints, direct construction/road support, stable-platform eligibility,
and timers. Include permanent immutability for deeprock. Preserve the intentional differences
across R13–R19, R27, and R36–R41 rather than deriving every property from one structural flag.

Use a shared material definition to drive simple `BlockType` predicates and the material
categories consumed by road and soil/sand validators. Keep neighborhood-dependent geometry
and support checks in shared algorithms. Add table-driven invariant checks across these
consumers so collision, placement, support, mining, and timers cannot silently drift apart.
Treat this as a behavior-preserving refactor, using the first implementation's focused tests
as a baseline; it does not enable resource mining or introduce processing recipes. Deferring
the consolidation does not defer shared mining policies, immutable-floor protection, or
client/service validation already required for G1–G5.

### Persistence, caches, and shortcuts

Use the explicit generator identity and profile dispatch below, with compact settings and
independent layer seed tags:

| Descriptor field | New-world contract |
| --- | --- |
| `generator_id` / `generator_version` | `2` / `1`; the pair versions algorithms and settings encoding. Retain/validate the wire version when decoding. |
| `seed` | Persisted `u64` for both profiles, including flat; it determines deeprock. |
| `settings.profile` | Required `natural` or `flat` discriminator, followed by only that profile's payload. Empty settings and unknown/cross-profile fields are invalid. |
| `settings` payload | Natural carries the generation inputs above; flat has no profile-specific tuning in this version. Its tag is still mandatory. |

The new flat profile keeps a dimension-derived flat surface, a uniform temperate/meadow
environment, zero polar inset, and seeded deeprock. It does not prepare continents, islands,
ranges, deposits, or trees and is not subject to natural minimum climate widths. Playable
flat generation and save/reopen use this profile; isolated material fixtures need not be
serialized worlds. Never relabel a saved legacy ID 0 world as flat with deeprock. Legacy
ID 1 terrain is also unsupported; migration is out of scope. The runtime flat representation
must retain its seed/identity rather than remain a seedless enum tag.

Update descriptor encode/decode/validation and both new-world and saved-world construction
with exhaustive ID/version/profile dispatch. Replace the current 39-byte legacy-terrain
settings cap with bounded profile-aware validation; do not interpret every nonzero ID as
terrain or discard its version. Before preparation, ensure any separately supplied runtime
generator, profile/settings, seed, and layout agree with the store's descriptor.

Keep the complete persisted descriptor within the existing 4-KiB limit; rebuild macro grids,
indices, and starting candidates deterministically during preparation. No full-resolution
climate map or generated deposit contents are saved up front.
Changes to material IDs, rounding, candidate order, or field semantics require version review.
Compare prepared-data fingerprints on reopen in tests to detect accidental drift.
Prepared macro maps, island/ridge/deposit indices, and climate-boundary inputs belong to
the prepared-world lifetime; evicting a column must not rebuild them. Cache contents are
derived accelerators, never inputs to generation decisions. Repeated generation of pristine
chunks must produce identical block bytes without writing those chunks to disk.

Validate the canonical bottom mask before publishing each restored lowest-Z chunk, including
its base record and replayed WAL edits. A conflicting record is an explicit data error;
never repair it by discarding valid upper edits or silently regenerating a modified chunk.
This is a bounded check on the loaded chunk, not a global saved-world scan.

Use a shared immutability check on complete planned write sets before effects/revisions are
committed. Cover authoritative edits, optimistic application/replay, timers/`changeType`,
road/bulk operations, and runtime debug/service setters, including paths that currently skip
ordinary construction checks. Bulk planners may exclude protected cells deliberately; a
failed transaction cannot grant items or partially change mutable targets. Original-world
generation and validated restoration are distinct from gameplay mutation, but both must
produce the canonical mask. Keep finite lower-Z collision independent of loaded terrain,
and validate player destinations/recovery and mode return against the layout's storage floor.

Extend `ColumnGenerator` to cache the 32×32 environment data needed for its vertical chunks.
Keep current bounded caches (presently 64 column generators and 512 boundary entries) unless
measurement justifies a separately budgeted change. Do not duplicate the macro map per
column/client. Consumers can share immutable prepared data with explicit lifetime ownership.
During chunk filling, evaluate floor thickness and the deposit-index candidate slice once
per horizontal column and reuse them for its vertical cells, without retaining additional
cache fields. The slow point oracle evaluates those inputs independently. Direct and
allocating natural-world preparation share settings validation, memory preflight, and
failure mapping before either begins candidate work or allocates owned preparation data.

Track maximum terrain, water, and tree occupancy separately for empty shortcuts. Resource
intersection tests and the deeprock mask precede uniform-rock shortcuts. Enclosure needs only
solid/occluding occupancy, but any new shortcut proof must agree with generated boundary
strips and material rules. Retain the cave-free invariant; leaf canopies cannot certify an
underground enclosure.

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

| Milestone | Scope | Components |
| --- | --- | --- |
| G1: Environment foundation | Versioned natural/flat profiles, classified preparation failures, larger default, pure climate queries, polar inset and finite floor, diagnostics | `src/voxel_app/consts.zig`, `world_generator.zig`, `world_environment.zig`, `generation_preparation.zig`, `terrain_collision.zig`, `standing_space.zig`, `main.zig` |
| G2: Land and relief | Connected continents and smaller islands, ocean, ranges, surface layering, deterministic deeprock, safe first-start region | `natural_generator.zig`, `generation_geography.zig`, `generation_hash.zig`, `world_data_service.zig` |
| G3: Materials and geology | Shared mining policy and mutation guard before material edit integration; opaque water, climate soil palette, sand local rules, deeprock direct foundations, indexed deposits, starter resources | `src/engine/voxel/voxel_chunk.zig`, `src/engine/shaders/voxel/`, `src/voxel_app/block_rules.zig`, `world_engine_glue.zig`, `player_interaction.zig`, `world_data_service.zig`, `world.zig` |
| G4: Vegetation | Forest/meadow fields, leaves with null-safe no-item clearing, complete cross-chunk trees, mesh pressure checks | `generation_vegetation.zig`, `world_generator.zig`, voxel/collision/render material code, `player_interaction.zig` |
| G5: Integration | Mutation guard verification, validated bottom restoration, both-profile save/reopen and legacy rejection, edited-chunk authority, bounded caches, shortcut oracle, regeneration benchmarks, debug maps | `src/voxel_app/world.zig`, `src/voxel_app/persistence/format.zig`, `main.zig`, `world_data_service.zig`, generator/service/GPU tests |
| F1: Later construction | Revisit the temporarily allowed soil platform over sand; foundation-to-rock rules and piles | Separate construction specification, then shared validator and support dependencies |
| F2: Later simulation | Farming prohibition, clothing/water services, action food cost | Future simulation specification, consuming the shared environmental API |
| F3: Material behavior consolidation | After G1–G5, add one behavior matrix near the runtime data model, shared material definitions, and table-driven invariant checks | `src/engine/voxel/voxel_chunk.zig`, `src/voxel_app/block_rules.zig`, road/collision/render/mining/timer consumers and tests |

G1–G5 together are the implemented generation
delivery; F1–F3 do not block exploring the generator, and must not be reported as implemented
merely because their environmental inputs exist.

### Risks and validation strategy

- **Topology versus visual coast detail:** protect land/water cores, prove refinement bounds,
  and compare adversarial final-column fixtures and exact reduced worlds with the protected
  cores/island assignments. Simplify unconstrained
  shoreline noise if necessary, while retaining the required first-iteration islands.
- **Geographic scale:** a four-chunk minimum frozen belt is small relative to this default
  world, while a 10% belt is approximately 3.3 km deep. Use overview maps and player-scale
  slices together; neither alone establishes good travel/resource balance.
- **Temporary sand foundation policy:** soil platforms above sand are explicitly allowed by
  R18, while sand stays outside broad structural predicates. Do not accidentally reject the
  permitted platform route or claim a foundation-to-rock proof that does not exist.
- **Inventory dead ends:** material presence and placement/support categories must not enable
  mining implicitly. Keep unknown resources forbidden, and exercise both item-yielding and
  explicit no-item acknowledgement/save paths with the current single-slot inventory.
- **Bottom-layer bypasses:** a mining-only guard misses indirect writes, optimized generation,
  optimistic replay, and restored chunks. Use the shared canonical mask, validate mutation
  write sets and lazy restoration, and retain finite lower-Z collision without loaded data.
- **Forest face budget:** trees add substantial ordinary voxel faces. Exercise dense mixed
  forest/coast chunks against existing 4-MiB face capacity and 64-KiB per-chunk allocation,
  boundary invalidation, shadows, and capacity fallback. Do not silently truncate trees to
  hide a mesh-capacity failure.
- **Precision and reproducibility:** use canonical integer feature coordinates and stable
  hashes, validated periodic noise, explicit tie breaks, and bounded numerical operations.
  Golden outputs are versioned; supported builds must agree at material/boundary decisions.
- **False confidence from samples:** statistical appearance targets are measured on a
  published deterministic suite (proposed 64 seeds including the default 12345), with all
  failures and categorized rejection traces reported. Exact connectivity/spacing/polar
  minima are checked structurally or exhaustively at the appropriate representation,
  not inferred from screenshots.

For implementation, combine focused generator/reference tests, client/service edit and
persistence regressions, the existing CPU/build suite, and relevant headless GPU tests.
Add visual overview layers for climate, continents, relief, vegetation, and resources;
inspect close views of transitions, sand/rock contact, water, and seam-crossing forests.
Record hardware/build mode, memory/candidate maxima, preparation time, query throughput,
and observed mesh allocation pressure. Do not claim the current 8/16-GB gameplay budget
merely from a compact macro map; complete residency remains separately measured.

## Tasks

### Phase 0 — Review the draft

- [x] T1: Review remaining material-support categories and continent/island shape invariants;
  use seed maps to tune numeric terrain, forest, and resource settings, keeping settled
  climate, cover-timer, foliage, and temporary platform decisions fixed. [R3–R14, R18, R21–R27]
- [x] T2: Prototype geography/refinement including islands and publish overview diagnostics
  before freezing the new generator settings/version. [R3–R8, R32, R34]

### Phase 1 — Shared environment and world bounds

- [x] T3: Add versioned settings validation, pure climate/environment queries, and point/map
  equivalence plus seam/ordering tests. Define ID 2 / version 1 natural/flat dispatch and
  preflight validation with legacy rejection and named failure categories. [R7–R12, R30–R32, R42]
- [x] T4: Change the voxel default dimensions; add shared playable-Y bounds to movement,
  climb, standing-space/recovery, and mode return, plus the independent lower-Z player guard.
  Retain explicit flat fixtures. [R1–R2, R28, R40]
- [x] T5: Add environment diagnostic export, bounded preparation accounting, and categorized
  failure/retry traces for preparation and seed-batch reports. [R32, R34, R42]

### Phase 2 — Continents, water, and ranges

- [x] T6: Implement connected macro continents, indexed smaller islands, bounded coast
  refinement, coarse land target, optional offline coverage estimator, and bounded
  deterministic retry/failure policy with at most eight candidate attempts after preflight.
  Keep candidate index/selection stable and distinguish capacity rejection from allocation
  or budget failure. [R3–R4, R30, R32, R42]
- [x] T24: Add the adversarial final-column topology fixtures: diagonal-only contacts,
  minimum-width/severed necks, seam-crossing islands, and islands/chains near two continents.
  Compare cardinal component/core membership and water gaps against protected assignments,
  including valid and invalid variants without a full-world startup scan. [R3, R34, AC37]
- [x] T7: Add shared sea level, ocean filling, sand/soil layering, indexed ranges, and
  conservative terrain/water occupancy bounds; generate the canonical 1–3-block deeprock
  floor in playable profiles and bottom-chunk solid shortcuts. [R5–R6, R15, R33, R38]
- [x] T8: Select/validate a safe first-start region; add spawn/access exclusions for later
  trees without relying on world origin. [R23, R29]

### Phase 3 — Materials, rendering, and resources

- [x] T20: Introduce shared default-deny mining policies independently of placement/support;
  preserve configured conversions and the occupied-slot gate, validate yielded inventory
  items, and handle explicit no-item success safely in prediction/authority. Integrate one
  production policy rather than parallel client/service copies. [R36–R37]
- [x] T21: Protect deeprock through shared write-set validation, including indirect edits,
  optimistic replay, timers, roads/bulk plans, and debug/service setters. Establish this
  shared guard alongside T20 before integrating new material edits; verify rejected
  transactions have no partial effects and filtered plans preserve the floor. [R39]
- [x] T9: Add render-only climate soil appearances and opaque blue water, preserving saved
  soil and timers; verify CPU/GPU material layout and optimistic remeshing. [R13–R14, R19]
- [x] T10: Implement distinct granular footprints, constructed-sand dependencies, and sand
  support rejection for buildings/roads, including seam and missing-data cases. [R16–R17]
- [x] T22: Recognize one exposed deeprock cell as a stable direct foundation in shared
  client/service construction and road rules, without a `3 × 3` area/platform check;
  preserve ordinary height/span limits and separate soil/sand footprints. [R41, AC35]
- [x] T11: Define resource material behavior, indexed deposit shapes/precedence, geology
  weights, effective-volume validation, and finite resource persistence. Exclude deeprock
  hosts and leave unconfigured resources unmineable. [R21–R24, R30–R33, R36–R39]
- [x] T12: Reuse/insert the three starter pockets and verify local access on the final
  generated terrain. [R23, R29]
- [x] T13: Prototype the bounded shallow beach overlay using retained terrain samples;
  measure enabled/disabled regeneration and include by default only within the measured
  budget, explicitly recording deferral otherwise. [R20, R35]

### Phase 4 — Vegetation and integration

- [x] T14: Add leaves and forest/meadow fields; implement bounded globally prioritized tree
  candidates and complete-form clipping into chunks; explicitly enable no-item foliage
  clearing and verify empty/occupied-slot behavior. [R25–R27, R36–R37]
- [x] T15: Update column caches, boundary/enclosure/empty/rock shortcuts, and client/service
  generation paths; compare them with a slow reference including deeprock priority in
  bottom chunks. [R10–R11, R30, R32–R33, R38–R39]
- [x] T16: Integrate new descriptor/material serialization and new-world save/reopen tests
  with sand or explicitly configured usable resource mining and no-item foliage removal.
  Cover natural and seeded flat profiles, malformed/legacy identity rejection, profile-aware
  settings bounds, and runtime descriptor/seed/layout mismatch before service startup.
  Validate canonical deeprock before publishing each restored bottom chunk/base/WAL result;
  preserve valid upper edits and report invalid records without regeneration. [R30–R31, R36–R39]

### Follow-up specifications

- [ ] T17: Revisit the temporarily allowed soil-platform-over-sand route in a separate
  foundation/pile specification; any future restriction must explicitly supersede R18,
  while current generator delivery verifies the permitted platform behavior. [R18, AC23]
- [ ] T18: Specify NPC/farm/action consumers of environment profiles and their supply/cost
  accounting; keep exact economic multipliers outside generator geometry. [R11–R12]

### Follow-up improvements after the first implementation

- [ ] T23: After G1–G5, consolidate material rules into the behavior matrix beside the
  runtime data model, covering soil states, sand, water, foliage, deeprock, and every resource.
  Introduce shared material definitions and migrate predicates/validator categories with
  table-driven invariant checks, preserving the first version's behavior. This F3 refactor
  does not block G1–G5 or postpone their required shared validation. [R13–R19, R27, R36–R41]

### Validation

- [x] T25: Inject preflight, retryable candidate, and terminal preparation failures. Verify
  zero attempts for invalid inputs, deterministic first-valid selection, the shared eight-
  attempt cap, cleanup/no partial publication, and complete `SeedRejected` diagnostics.
  [R32, R34, R42, AC36, AC38]
- [x] T19: Implement the deterministic regeneration hash oracle and benchmark cached versus
  evicted columns, including the beach toggle and actual bounded-cache churn. Publish
  measured preparation/query/generation/meshing costs and owned scratch limits. [R30–R35]
- [x] T-val: Verify all AC1–AC38 for G1–G5, including current AC22 environmental flags,
  AC23 permitted platforms, AC28–AC35 mining/floor/foundation contracts, and AC36–AC38
  profile identity/topology/failure handling; keep future F1–F3 tasks
  separate. Publish seed-suite maps/metrics
  and run relevant CPU/build/GPU/persistence checks, repeated-regeneration benchmarks, and
  player-scale visual inspection. [AC1–AC38]
