# Block placement and timed soil changes

The client and `WorldDataService` use the same structural validator. The client previews an
edit against received blocks; the service checks it again against authoritative contents
within the same fixed support window. Missing
client data produces `missing_data`, never an assumption that the missing cells are air.

## Materials and mining

| Material | Origin and behavior |
| --- | --- |
| Natural stone (`stone`) | Generated rock; cannot be placed. Mining yields `crushed_stone`. |
| Crushed stone | Placeable masonry; cannot become natural stone. |
| Loose soil (`dirt`) | The soil placement/mining item. Needs a filled 3x3 support layer. |
| Packed soil (`packed_dirt`) | Generated soil or compacted loose soil. Mining yields loose soil. |
| Grass-covered packed soil (`grass`) | A surface appearance/state of packed soil, never a placeable item. |
| Tree trunk | Vertically supported wood. |
| Planks | Wood with limited horizontal support propagation. |
| Rebar and reinforced concrete | Share horizontal support and the mineral height group. |
| Solid country road | Ordinary cube; requires solid support directly below. |
| Adaptive country road | Custom cell (255); full-cube collision until a supported 4–12-section run forms a slope. |
| Sand | Placeable/minable; retains a filled 3×3 footprint, has no soil timers, and fills soil/sand footprints without providing construction support. |
| Leaves | Opaque colliding foliage; removable without an item, with no structural support or decay. |
| Ore, limestone, coal | Natural-rock support; mining disabled until usable resource results are configured. |
| Clay | Packed-soil support, without compaction/grass timers; mining disabled pending resource mechanics. |
| Deeprock | Immutable seeded bottom formation; one exposed top supplies a direct stable foundation. |

Water and standalone snow may be placed above sand, air, or other materials. They require
no structural support and cannot supply earth/sand footprints or stable platforms. Construction materials and unformed adaptive roads have full-cube collision;
formed roads follow their inclined surfaces. See [country roads](country-roads.md).

`BlockType.miningPolicy()` is the shared explicit allowlist used by prediction and authority:
forbidden, remove without an item, or yield a configured placeable item. New unconfigured
resources default to forbidden mining. `mined_type` is optional even on success; clearing
leaves keeps an empty player slot empty. An occupied slot still rejects all player mining.
Deeprock has an independent mutation guard covering all direct and indirect writes.

### Blueprint normalization

The [blueprint specification](../specs/features/blueprints.md) describes capture and
construction behavior. Captured materials are normalized into supported
construction materials, then the completed design is certified under the ordinary rules in this
document, with assumed stable platforms beneath its globally lowest occupied cells. Source blocks
outside the box supply no support. Normalization changes only the saved design, not source terrain
or general construction rules.

Natural stone and crushed stone are **not structurally interchangeable**. Natural stone
provides direct wood/mineral support through a full stable platform; crushed stone also
has mineral/column/bridge limits and does not
directly support rebar/concrete outside the existing platform and lateral-support routes.
Blueprint validation must examine the converted arrangement. The feature spec defines the
material allowlist and initial conversions in [R19](../specs/features/blueprints.md#full-validation-and-portability),
the narrowly gated reinforced-support fallback and height diagnostics in
[R47/R49/Q21](../specs/features/blueprints.md#conditional-concrete-support-conversion), and
selection/definition limits in [R54/Q25](../specs/features/blueprints.md#horizontal-size-and-wrapped-target-uniqueness).

### Approved blueprint application follow-up

The approved hybrid destination-admission change below is pending runtime implementation. The
current service still uses FIFO admission and rechecks dependency versions before publication.
Existing implementation and validation reports describe that behavior; they do not verify this
follow-up.

Apply is an infrequent player operation, with at most one active preparation attempt. NPC simulation
fills already published sites and does not initiate Apply. Before the first terrain or index copy,
each candidate attempt protects every whole chunk intersecting the rotated full bounding box,
including blueprint-empty cells, cavities, and empty chunks. Protection covers that chunk footprint,
not the 56-block structural halo, and lasts until atomic publication, rejection, or invalidation
of that candidate attempt.

Prolonged journal/disk waits or storage failures release admission protection and discard or
invalidate its snapshot and prepared publication. The submitted operation identity/request and
existing save, fence, and retry semantics survive; a late helper result cannot publish. Recovery
must reacquire protection and copy/reprepare fresh data, without reusing stale snapshot contents or prepared
index records from before release. R62–R64 require a finite configurable hold/expiry policy and
implementation measurements; no numeric timeout has been selected.

All actual or conservative writes into protected terrain, metadata, and index chunks must wait.
This includes indirect adaptive-road effects, timer writes to soil below an edited cell, and cleanup
of an entire site even when its last fill occurred outside the protected footprint. Reads may cross
the boundary. Independent work outside it must progress while preserving producer order, contiguous
resolution, and the exact membership of selected save fences. A bypassed later request cannot
satisfy an earlier unresolved fence. Existing persistence source holds remain separate from Apply
protection, and final publication stays short and sequential on the single authoritative worker.

Application still validates full real bottom platforms and the completed design's composition with
nearby constructions using immutable observations. Exterior observations may be mixed-time and
roughly one to two seconds old through publication, including helper and queue waits; this is not a
real-time completion promise. Changes outside the protected chunks do not trigger full structural
revalidation. In particular, external fills or cleanup alone must not cause rejection through a
global blueprint-overlay revision check.

Every nonempty target must be physically empty, even if an existing block has the required type.
The authority checks target occupancy once under protection; the write gate preserves that
result, so publication needs no final O(N) target scan. The helper prepares entire footprint
`ChunkIndex` records for atomic swapping, without merging them with current indexes. Current owner,
ID, resource, overlap, recipient, inventory, and progress bookkeeping must remain live and atomic;
stale structural evidence does not authorize stale publication bookkeeping. Failure publishes no
partial site.

At atomic publication, a real non-`none` block must be directly below **every target in the globally
lowest occupied layer**. Any real block type qualifies, never a miniature. A protected checked
support can supply this proof without rereading it; unprotected supports below a Z chunk boundary
must be rechecked. Unknown required current cells cannot establish support. This does not recheck
the surrounding 3×3×3 platforms, every column's lowest target, or the full composed structure, and
adds no O(N) work to fulfillment.

The initial observations still require full platforms and composition checks. Exterior staleness
can make the published completed arrangement ordinary-rule-invalid. Such a violation can last
after construction finishes; there is no automatic repair or completion-time structural scan. The
guarantees below distinguish initial cheap-rule assemblability from ordinary structural validity.

### Blueprint fulfillment

Full designs are validated at creation and composed with earlier destination observations
at application under the approved follow-up above.
Subsequent blueprint-directed structural approval must inspect no more than the real block
directly below and four immediate XY neighbors. Any real block below passes this cheap rule;
with air below, an eligible real XY neighbor is required. This deliberately permits temporarily
unsupported intermediate states without repeating ordinary height/span or dependent searches.

For cheap fulfillment with air below, an eligible real XY neighbor is a matching logical
material, either reinforced type for a rebar/concrete target, or natural rock for a
crushed-stone target. Reuse the ordinary `isNaturalRock()` family: stone, metal_ore,
limestone, coal, and deeprock; clay is not in that family. This directed support exception
matches ordinary crushed-bridge routes and prevents a legal foundation removal from
stranding a crushed miniature between real stone sides. It uses the same four XY reads,
adds no recursive validation, and does not change the target's required inventory material.
Normal dirt aging preserves its blueprint fulfillment identity across dirt, packed dirt, and grass.
Miniatures never count as real support. Filling a target and completing the last target require
no full-design scan; the detailed structural/performance contract is in
[R27–R32 and R51](../specs/features/blueprints.md#assembly-and-completion).

Blueprint fills queue coalesced adaptive-road work by chunk. Road shapes may update after
a short delay. Formation/reversion preserve structural capabilities, so shape-only updates
need no completed-world target/dependent validation or queries above the road. Planning still
checks the road pattern and section support, preserving ownership and immutable-write guards.
Saving persists unfinished road obligations without waiting for the queue to drain. Road
planning does not run inside the five-neighbor structural approval path.

### Blueprint extraction view

Extraction remains forbidden throughout an unfinished blueprint's box, including preexisting
blocks in nontarget cells. Outside all such boxes, the general extraction check sees
pending miniature targets as if they were completed blocks. It uses the same ordinary
support rules and fixed windows, with all affected planned cells included as constructions.
Checking only real construction metadata would miss an instance whose blocks are still
miniatures.

There is no permanent foundation lock. Full 3×3×3 platforms remain a requirement of the earlier
application observations. Under the approved pending follow-up, publication requires only the real
block directly below each globally lowest occupied target, using protected proof or a current
recheck for unprotected supports. Later ordinary extraction keeps its completed-world support
checks. Collision, mining/item transfers, and cheap blueprint
fulfillment use real terrain; miniatures cannot be mined and never count as real support for filling
another target. Replacing a miniature with its required real block leaves the completed
logical view unchanged, so that operation needs no dependent revalidation.

Application reuses the current compiler's portable certificate and verifies physical target
emptiness, immutability, overlap and real bottom platforms. Existing valid real/planned cells
retain their support witnesses under a finite batch of empty-cell additions, so application
performs no structural target searches or old-dependent scan. Its versioned chunk input covers
the rotated box expanded by one cell horizontally and three cells downward, with no upward
extension; whole box chunks remain publication sources through cavities. The spec gives the
[certificate proof](../specs/features/blueprints.md#portable-certificate-admission) and
[batch argument](../specs/features/blueprints.md#monotone-batch-admission). An ordinary placement first
validates its new target against physical terrain,
then validates that target in the completed logical view. Physical approval ensures miniatures
supply no real support; completed approval establishes the new block's completed-world
validity. Both views include the proposed placement. Insertion preserves already-valid
constructions by the additive contract below, so ordinary placements collect no dependent
candidates and perform no dependent revalidation. Removals still discover and check real and
planned dependents using the actual support predicates of every world material, including
types excluded from capture. Water/snow have no support dependencies. [R39/R40](../specs/features/blueprints.md#assembly-and-completion)
record composition examples, and the [constraints](../specs/features/blueprints.md#constraints)
define cache separation and safe approval reuse. These checks add no work to blueprint fulfillment.

### Blueprint world-mutation invariant

The current implementation requires every gameplay world modification to preserve ordinary
structural validity of affected real and planned constructions in the resulting logical world
where all pending targets are completed. The approved application follow-up is an explicit
exception to that publication-time invariant, pending runtime implementation as described above.
Ordinary placements, extractions, simulation/timer edits, debug/service commands, batch edits,
and indirect side effects retain their existing affected-construction checks. Generated-terrain
exemptions and bounded affected regions remain; a proven logical no-op needs no repeated search.
These retained checks do not repair an invalid arrangement already admitted by stale application
validation or restore a universal completed-world invariant.

Unfinished construction may temporarily violate ordinary physical construction rules internally
and in its surroundings, including completed neighboring buildings. Each fulfillment replaces
one planned type with an equivalent real type and leaves the completed logical arrangement
unchanged. If that arrangement is ordinary-rule-valid, a constructed cell becomes physically
valid once no pending target remains in its support window. The current window is an inclusive
cube of ±28 cells on each axis, using shortest wrapped-X displacement; recursive support checks
do not move its center. For a whole building the condition applies around every constructed cell.

Under the approved follow-up, absence of nearby pending targets alone no longer proves ordinary
physical validity: stale application composition can leave the completed arrangement invalid,
and filling the remaining targets preserves that violation. No unconditional eventual-validity
promise, automatic repair, completion check, per-fill neighbor-site search, or persistent stability
flag is added. [R50/Q22](../specs/features/blueprints.md#world-mutation-invariant-and-eventual-physical-validity)
record the scoped guarantees. Future cancellation and its effects require separate design.

### Blueprint global completion order

At publication under the approved pending follow-up, the newly applied site has an initial
completion sequence under the cheap fulfillment rule. The creation-time R20 certificate proves
reachability from its globally lowest occupied targets; a current real non-`none` block directly
below every such target makes those starting targets immediately placeable. This proves initial
assemblability, not ordinary structural validity of the destination or progress through an endless
stream of later edits. Materials, data, access, and scheduling remain separate conditions.

Later ordinary checks remain in place, and sites may rely on a neighboring site's targets being
filled first. Placements can interleave sites; an NPC scheduling guarantee and a universal
completion-order guarantee after stale application are not established by this relaxation.
The [completion-order argument](../specs/features/blueprints.md#global-completion-order-argument)
and deferred [per-instance-reader alternative](../specs/features/blueprints.md#deferred-preferred-alternative-per-instance-logical-readers)
retain their stated assumptions. The five-neighbor fulfillment bound remains, with no runtime
support graph, reachability scan, or final validation pass.

## Stable platforms

A stable platform is a completely filled 3x3x3 cube immediately below a candidate block.
The cube covers x/y offsets -1 through +1 and z offsets -1 through -3. The candidate must
be directly above the center of the cube's top layer. Every cell must contain loose or
packed soil, natural or crushed stone, rebar, or reinforced concrete. Mixtures are allowed;
ore, limestone, coal, clay, and deeprock also qualify; wood, water, sand, snow, foliage, and air do not qualify.

A single exposed deeprock cell is also a direct foundation, without requiring a surrounding platform. Soil and sand still require all nine footprint cells. A stable platform supplies a foundation and resets height counters. It can be constructed;
it does not require natural stone underneath it. Repeatedly building a new platform to
restart the counters is an intentional building compromise. This also resets the counted
crushed-stone run at the platform, rather than counting through it.

## Local support and height

Loose soil and sand need nine qualifying blocks in the 3x3 layer directly beneath them. Earth,
stone, geological resources, rebar/concrete, trunks, planks, and sand can fill this layer. Water,
standalone snow, foliage, and air cannot. Sand remains nonstructural despite filling a footprint. A constructed soil block
retains this footprint requirement after compaction (and constructed sand retains its own footprint), so removing temporary supports cannot
leave a previously placed soil block floating. Generated terrain is exempt from building
validation; natural cliffs and hills remain mineable.

Trunks and planks can rest on structural materials. Crushed stone can rest on crushed
stone. Rebar and concrete can rest on either reinforced material. A stable platform is
an additional valid foundation for all these materials. Literal natural `stone`, soil
and clay provide direct support only through the centered full 3x3x3 stable platform.
Stone remains a qualifying platform material, and mixtures are allowed. Ore, limestone,
coal and deeprock retain their single-block natural-foundation shortcut. Wood retains
its existing direct support on mineral construction. Height/span limits are unchanged.
An incompatible occupied block underneath supplies no direct support; an independently
valid lateral route can still support the target.

### Independent support routes

Downward-support eligibility is distinct from occupancy.
Failure of the direct route does not veto another support route already permitted for the
material. In particular, laterally supported planks may have dirt/packed dirt/grass directly
below without requiring that earth to form a stable platform. The same independent-route
principle applies to materials with their own lateral support mechanisms; it grants no new
lateral mechanism to trunks, soil, sand, or roads.

Keep the actual block below in the reader and test the alternative route, rather than
globally reporting that cell as air. Preserve footprint, span, height, crushed-column, and
bridge-side restrictions. Unknown cells remain unknown. A valid lateral route accepts the
block without treating the unsuitable below material as its foundation; absence of any
valid route still rejects it. This changes general construction validation, including
ordinary placement/removal and blueprint certification/composed admission, not just the
blueprint shortcut.

| Construction group | Maximum height | Horizontal reach from a vertically supported block |
| --- | --- | --- |
| Trunks and planks | 12 levels | Planks: 2 steps; trunks: none |
| Crushed stone, rebar, concrete | 20 levels | Rebar/concrete: 4 steps |
| Crushed stone alone | At most 6 consecutive cells before a foundation or independently supported bridge | One-cell bridge exception below |
| Natural stone | Unrestricted | Generated terrain |

Wood starts a fresh 12-level count above an eligible non-wood foundation. Rebar and concrete
inherit the shared mineral counter across material changes. Vertical moves increment the
relevant counter; horizontal moves inherit it. Air does not reset height: an overhang must
inherit a valid foundation through its horizontal supports. When several routes exist, a
valid route within the span limit can support the block. Choose the minimum supported
height across the direct route and all eligible lateral routes, including both crushed-bridge
orientations; adding another route cannot replace a better existing route.

Horizontal transmission stays in the same z layer and material family: planks transmit
to planks; rebar and concrete transmit to each other. Face-neighbor steps cost one. A
diagonal also costs one, but both intermediate face-neighbor cells must fill the corner
with that family. A face-connected two-step route can still work when only one intermediate
cell is present; it does not receive the diagonal discount.

This gives a 5x5 plank platform or a 9x9 reinforced platform on a central support. A span
with two vertically supported endpoints can contain 4 unsupported plank cells (6 cells
including endpoints), or 8 unsupported reinforced cells (10 including endpoints).

Crushed stone can fill one unsupported cell between two opposite horizontal stone
neighbors. Both neighbors must have direct vertical support; another unsupported bridge
cell cannot act as one of these sides. This exception does not permit an unlimited stone
bridge. Multi-cell gaps need temporary supports, which are a separate future feature.

Natural-rock bridge sides retain their separate immediate-below support predicate;
the platform-only direct-stone rule does not require a full cube beneath each side.
Such a cube would also fill the cell below the middle gap. Soil/sand keep their
nine-cell footprints, roads keep their immediate-below predicate, and blueprint
fulfillment keeps its five-neighbor path.

An independently supported bridge stops the downward six-cell run count, including when
crushed stone is subsequently placed below it. Seven vertically adjacent crushed cells are
therefore legal if a suitable bridge or foundation interrupts that count. A narrow seven-cell
column with no such support still rejects. This is independent of the mineral-height proof:
a bridge does not itself reset the 20-level counter, which inherits the best eligible route.
The bridge-side predicate and the one-cell gap limit remain unchanged.

### Additive validity

With unchanged source data apart from the insertion, adding a block into an empty cell preserves
the support witnesses of every previously valid constructed cell, including cells on the
same level and below the insertion. Each cell retains its own fixed support window. Direct
and lateral routes remain available, platform/footprint occupancy can only improve, and
newly available routes cannot increase the minimum height. The bridge run reset preserves the independent support
of a crushed bridge when a lower column grows into it.

Same-level connections can only gain eligible routes; lower cells do not read upwards,
so their support data is unchanged. This guarantee preserves already-valid cells and does
not repair any construction that was invalid before the insertion.

Formation and reversion of adaptive roads also preserve these support witnesses: structural
rules use the road material, independently of its shape. A road above a slope receives the
same support as above an unformed adaptive block. Other material-support families stay as
specified above. Shape changes still update collision/render geometry and preserve road
ownership, immutable writes, and instance progress.

The property does not validate the new block or permit occupied-cell replacement. Removals
and material replacements retain their normal checks. Blueprint fulfillment can place
temporarily unsupported new cells and keeps its existing five-neighbor rule. Ordinary
insertions validate only their new target, retaining both physical/completed checks when
sites exist. Removals retain dependent checks. Application uses the finite-batch witness
argument and target-only read envelope [described above](#blueprint-extraction-view), with
its existing version barriers and publication guards. The original
[additive-validity feature](../specs/features/monotone-block-additions.md) left Apply unchanged;
the target-only follow-up applies that rule property to admission.

## Fixed support window

The new block's structural support check has a fixed inclusive read envelope centered on
that block: `abs(dx) <= 28`, `abs(dy) <= 28`, and `-28 <= dz <= 0` (Z is vertical).
The horizontal limit uses Chebyshev distance, so an offset `(28, 28)` is inside it. This is
an invariant for current and future support rules, including platform corners and diagonal
intermediate cells. The check needs no cells above its root. Searches do not recenter on
intermediate supports: stacked overhangs accumulate horizontal displacement across floors.
Stable platforms reset height counters, but do not reset the window.

This envelope describes structural approval of the new target. It does not bound whole-chunk
loading/copying, diagnostics, soil state bookkeeping, road discovery, or the removal-dependent
checks below. Those are separate from the new target's support proof.

Each revalidated dependent also keeps a 28-cell cube centered on itself. Its support must
be proved within the intersection of that cube and the edit's cube. Validation accepts any
known legal route in these bounds. It never queries cells outside them or treats those
cells as air. If remaining support cannot be proved without looking outside, the edit is
rejected conservatively, even when a farther alternative foundation actually exists.

The window uses block coordinates, independently of chunk boundaries, with shortest x
displacements across the wrapped seam. Translating the same construction and its foundation
does not change the result, provided the translated construction fits the finite y/z world
bounds. Loading extra chunks cannot extend a legal support route or change the decision.

With 32-cell chunks, a target within four cells of the player's cell on each axis has its
whole window inside the player's loaded 3x3x3 chunk neighborhood. This assumes those chunks
have arrived; missing cells inside the window still produce `missing_data`. Camera reach
measures the edited cube as described below. At an exact cell boundary, nearest-vertex
reach can include a cube whose lower cell coordinate is five indices away, so its support
window may extend beyond that loaded neighborhood. Edits still require every cell used
by their support checks to have arrived.

## Camera reach

Reach is inclusive: at least one of the edited cube's eight vertices must be within
four metres of the camera.

Both modes first find the first occupied cube under the crosshair. Removing measures that
cube; putting measures the face-adjacent candidate cube. The hit face itself is not subject
to the four-metre check. Ray traversal is bounded by four metres plus one cube diagonal,
which includes every potentially reachable candidate. Unknown chunks
still stop the ray. Cube distances use the nearest wrapped x copy.

Highlighting and actual keyboard/mouse edits call the same targeting function and
nearest-vertex reach check in player and spectator control. The world service checks
occupancy and building rules; it has no camera state and does not independently check reach.

Removing a reachable cube and aiming at a block directly behind it allows placement into
the same slot without moving: removal and placement measure the same cube. Replacement
still requires a face-adjacent target, received support data, valid construction, and no
player overlap. An isolated removed cube is not remembered as an empty-air target.

## Edits and diagnostics

Validation evaluates hypothetical contents before mutation. Empty-cell placements check
the new target and preserve existing validity by monotonicity, without collecting or checking
dependents. Removals revalidate potentially affected constructions, including changes to
platform cubes away from a vertical support column, and reject atomically if required
support would be lost. Occupied-cell replacement still requires removal followed by placement.
An unsuitable new block below a valid overhang cannot suppress its independent lateral support.
Natural terrain cells are not themselves revalidated as constructions.

Operation results carry status, an optional mined material, and an optional failure:
reason, underlying cause, affected cell, measured value, limit, and up to 32 involved cell
coordinates with an explicit truncation flag. The client retains the latest preview/result.
In putting mode, while aiming at a face with a reachable adjacent candidate, an opaque cyan cube outline previews an allowed
placement; an opaque red outline marks a rejected placement. Both match the green removal
target's three-pixel width and opacity. Translucent orange outlines show the affected
construction and involved cells, including empty spaces that need support. Putting mode
hides green focus edges. Missing cells beyond finite world edges retain
their signed positions, while x coordinates wrap across the seam. Diagnostics show at most
32 involved cells plus the affected cell and candidate; truncation is reported in the error text.

Hints reuse the focus outline's procedural edges and instance buffer. They retain all twelve
edges. Occupied diagnostic cells correct the depth of camera-facing edges to preserve full
stroke width over their own tilted surfaces; rear edges and empty/unknown hints retain their
actual edge depth. Visible strokes use alpha blending; strokes hidden behind
scene geometry use 30% of that opacity, so buried support remains identifiable. Neither
pass writes scene depth. Diagnostics use two instanced draws, with all hidden strokes before
all visible strokes and one upload of the active cell records. There is no solid ghost mesh.

`World.previewOperation` checks hypothetical placement without changing blocks, pending
commands, or the latest actual edit result. Its result is cached by target, selected material,
and the contents/availability of chunks intersecting the 28-cell support window (at most
27 distinct chunks). Each update compares their local validation stamps; this allocates
nothing and runs no support searches. Missing chunks also participate, so their arrival
invalidates a missing-data result. Accepted snapshots, eviction, and optimistic block
changes within the window invalidate it; changes outside it preserve the cached result.
Local stamps are independent of authoritative revisions, so same-revision snapshots and
eviction/reload between updates cannot retain stale previews. Rejected stale snapshots and
no-op edits preserve the cache. Invalidation is conservative at chunk granularity.
Changing the target or material still runs full synchronous validation; actual edits always
validate independently of preview caching. Player overlap is checked every frame, including
the frozen player while spectating. Removing mode only targets and highlights the focused
block: it does not
call placement validation. Switching modes clears cached previews and hints. Losing focus,
reaching empty air, or losing targeting data also clears the hints.
The zgui overlay shows the current rejection reason, underlying cause, measured/required
values, and diagnostic truncation in small orange text at the bottom centre, below the aim
point. Its dark background is translucent and rounded. Allowed placement, lost targeting,
lost focus, and switching to removing mode immediately clear this hint.

Actual edit failures, including player overlap and authoritative service rejections, show
medium red text with a dark 1.5px outline at the top centre, with no background, for four
seconds. The outline follows the text's wrapping and DPI scale. A new failure
replaces the previous message and restarts its timer. Successful edits and preview changes
do not erase this feedback; both messages can appear together. Text wraps to the viewport
width and follows the existing zgui DPI scale. These gameplay diagnostics no longer print
to the console; other debug output is unchanged.

`support_search_limit` reports the 28-cell limit and an attempted cell outside the window.
For a dependent edit rejection it appears as the underlying cause of `would_remove_support`
or `would_invalidate_structure`. This distinguishes an unproved remaining foundation from
a definite height or span violation.

The implementation visits construction indices only in chunks intersecting the edit window
(at most 27 chunk IDs), filters cells to the window, and sorts them in target-relative z/y/x
order for deterministic diagnostics. Conservative downward support envelopes skip unrelated
cells. Soil depends
only on its immediate 3x3 footprint; wood and mineral envelopes include horizontal routes
at each lower level and off-center platform cells. Missing data within an affected envelope
still blocks client approval; incomplete constructions outside it do not veto edits. Time events
do not run structural validation because the soil states have the same support properties.
Support states and memoization exist only during validation; no support graph or dependency
information is added to stored chunk metadata. A dependency index could be a separate future
optimization, but is not required for correctness.

Within one edit, each cached evaluation records a bounding box of all consulted cells,
including nested reads, absent neighbors, platform corners, and diagonal intermediates.
A successful result can be reused for another dependent only if the search had no missing
or out-of-window reads and the entire box fits the new dependent's window. Rejected and
incomplete results remain scoped to their original root. This preserves the window and
lowest-height rules while avoiding repeated overlapping searches during synchronous previews.

## Simulation time and transformations

Simulation time uses 60 ticks per second. The application advances it from frame elapsed
time; the service processes monotonic `advanceTo` requests in the same queue as edits.
Stopping game-time advancement pauses deadlines. Subscription eviction has no effect.

- Placing loose soil schedules compaction 30 minutes later.
- Soil placed beneath an existing block is packed immediately, without a pending timer.
- Placing any block directly above loose soil compacts the covered soil immediately.
- Newly compacted exposed soil schedules grass 30 minutes after compaction.
- Covering soil clears grass and cancels its pending surface timer.
- Exposing packed soil schedules grass 30 minutes after the exposure.
- Generated soil is already packed, with climate cover on its exposed surface immediately.
- The saved `grass` state renders green in temperate/desert columns, yellow in steppe, and snowy on top in frozen columns. Loose and packed soil retain their ordinary appearance until the existing timer grows cover.
  Generation schedules no soil transformations, regardless of when a chunk is discovered.
- Grass may grow underground. Light and sky access are not checked.

Each chunk has sparse, independently owned metadata for constructed indices and a sorted
array of pending transformations. Each event stores a cell index, kind, and deadline tick;
block cells carry no timestamps. A cell has at most one pending event. Removing/replacing
it cancels its event, and a new placement receives a fresh deadline.

Time processing checks the first deadline, takes a due prefix, and updates only those cells.
A large time step can compact soil and grow grass in one update using the original deadlines,
without adding another 30-minute delay at reload or catch-up. Type changes advance chunk
and mesh revisions and reach both block and mesh subscribers in complete update packages.

Chunks with pending transformations are retained by the service alongside committed edits;
this retention is independent of client streaming and currently has no separate memory budget.
There is still no disk save/load system. Deadlines and constructions last for the service's
lifetime, as do other world edits.

## Tools and validation

Keys 1-8 select loose soil, crushed stone, trunk, planks, rebar, reinforced concrete, solid
country road, and adaptive country road.
Tab toggles removing (the initial mode) and putting, independently of player/spectator
control. Left click performs the active mode's action. In putting mode E places against
the hit face of the first occupied block; in removing mode X mines that block. The opposite
mode's keyboard shortcut is ignored. Reach is four metres to the edited cube's nearest vertex,
and each press edits once.
Unknown chunks and empty air produce no edit. Player-overlap checks and structural validation
still apply to actual edits. Green edges show focus only in removing mode; putting mode
shows colored translucent outlines for placement and
support diagnostics and on-screen error text. Material selection UI remains a follow-up.

`zig build test` covers footprints, centered platforms, diagonal connectivity, square
platforms, span limits, inherited/group heights, protected platform edits, crushed-stone
bridges, mining conversions, timer ordering, covering/exposure, chunk boundaries, eviction,
time catch-up, inclusive support windows, stacked overhangs, conservative dependent edits,
root-specific caches, translated/wrapped constructions, and client/service agreement with
only a 3x3x3 neighborhood. Preview tests count actual validation invocations to verify reuse,
relevant invalidation, distant streaming changes, and per-frame player-overlap updates.
Targeting tests cover the inclusive boundary at every vertex, aimed-face independence,
backing faces beyond reach, the full traversal bound, wrapped distances, and unchanged-camera
removal and replacement. Game tests check preview/action agreement in player and spectator
control.
`zig build test-gpu` checks the shared voxel shader pipelines when a graphics adapter is available.

`zig build bench-outlines -Doptimize=ReleaseFast` measures CPU instance preparation for one
focused outline and 20/34 diagnostic cells, including occupied-cell classification. With a
graphics adapter, it also compares individual and instanced CPU command encoding for 1,
20, 34, and 64 cells. It excludes structural validation, uploads, queue submission, and GPU
execution. See [rendering costs and benchmark scope](rendering.md#voxel-rendering).

`zig build bench-placement -Doptimize=ReleaseFast` also measures allocation-free cache checks
for the benchmark's support window and a full 27-chunk window (11 samples of 10,000 checks),
excluding raycast, structural validation, and rendering. It reports reader calls and the
median/minimum time for ten `World.previewOperation` calls beside a 200-block (5x5x8) plank
building over natural stone. The CPU suite enforces a reader-call budget for that reproduction, also at
a translated position across the wrapped seam; elapsed time is reported rather than asserted
because it depends on the machine and build mode.

On the local Apple M4 Max, ReleaseFast cache checks measured median times of 0.009 µs for
8 chunks and 0.050 µs for the maximum 27 chunks. Full validation beside the 200-block building
measured 2.64 ms in that run. These are CPU microbenchmarks, not full-frame timings. Window
invalidation avoids rerunning validation after distant updates; a new target or material,
or a change anywhere in an intersecting chunk, can still incur full synchronous validation.

## Potential performance follow-ups

Asynchronous preview validation and per-frame work budgets may help if synchronous validation
causes gameplay hitches. Both require investigation; neither is a committed implementation
plan. First measure ReleaseFast full-frame times and preview completion latency, including
tail latency, around large, deep, and branching constructions while aiming, changing materials,
and streaming chunks. Record validation frequency, CPU time, and allocation/memory costs.
The existing microbenchmark shows potential cost but does not establish in-game frame spikes.

- **Asynchronous validation:** investigate moving preview searches to a worker using immutable,
  thread-safe world snapshots. Coalesce or cancel obsolete requests, bound the worker queue,
  and verify target, material, and chunk content/availability stamps before applying results.
  Measure whether snapshot and scheduling costs are justified by reduced frame spikes, and
  how quickly useful results arrive during continuous aim changes.
- **Per-frame work budgets:** investigate resumable searches with elapsed-time, reader-call,
  or visited-node limits. Preserve the validation snapshot, memoization, and root-specific
  rules across yields, and discard stale work. Measure budget overshoot, retained memory,
  and completion latency; continuous aim changes must not leave useful previews perpetually
  unfinished. A reader-call or node limit alone does not guarantee a frame-time limit.

Either approach needs defined pending-preview behavior: incomplete work must remain unknown,
never imply approval or a definite rejection. Player overlap must still be checked every frame,
and actual edits must remain independently fully validated. Adopt either approach only if
measured frame spikes or preview delays justify the added state and scheduling complexity.
