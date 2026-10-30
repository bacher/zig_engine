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
| Sand | Placeable/minable; retains a filled 3×3 footprint, has no soil timers, and directly supports only soil/sand. |
| Leaves | Opaque colliding foliage; removable without an item, with no structural support or decay. |
| Ore, limestone, coal | Natural-rock support; mining disabled until usable resource results are configured. |
| Clay | Packed-soil support, without compaction/grass timers; mining disabled pending resource mechanics. |
| Deeprock | Immutable seeded bottom formation; one exposed top supplies a direct stable foundation. |

Water and standalone snow keep their existing placement/collision behavior except that
neither can be placed directly on sand. They cannot supply earth/sand footprints or stable
platforms. Construction materials and unformed adaptive roads have full-cube collision;
formed roads follow their inclined surfaces. See [country roads](country-roads.md).

`BlockType.miningPolicy()` is the shared explicit allowlist used by prediction and authority:
forbidden, remove without an item, or yield a configured placeable item. New unconfigured
resources default to forbidden mining. `mined_type` is optional even on success; clearing
leaves keeps an empty player slot empty. An occupied slot still rejects all player mining.
Deeprock has an independent mutation guard covering all direct and indirect writes.

### Planned blueprint normalization

The [blueprint specification](../specs/features/blueprints.md) describes a future exception to ordinary
per-edit structural validation. It is not implemented. Full normalized designs are validated
once at creation; subsequent blueprint-directed structural approval must inspect no more than
one below and four XY neighbors, intentionally allowing temporarily unsupported intermediate
states. Ordinary structural rules remain the ones in this document, with a planned logical
view for extraction outside unfinished blueprint boxes, as described below.

Natural stone and crushed stone are **not structurally interchangeable**. Natural stone is
an unrestricted foundation; crushed stone has mineral/column/bridge limits and does not
directly support rebar/concrete outside the existing platform and lateral-support routes.
The earlier proposed general rule allowing that direct support has been withdrawn.
Blueprint validation must examine the converted arrangement, not certify the original and
then replace its bytes.

Capture first converts every included stone to crushed stone and validates. Only a concrete
fallback for an actual reinforced-on-crushed support conflict is allowed: replace the
conflicting crushed-stone support with reinforced concrete, continuing down that necessary
support chain until the new concrete has a legal support route, then fully validate the result.
The original logical snapshot, including miniature types, must already contain rebar or
reinforced concrete. Their presence alone does not authorize repairs elsewhere, and a valid
normalized design needs no fallback. This changes the saved blueprint only, not source
terrain or general support rules. Other material/geometry repairs, added supports, removed
occupied cells, and relaxed limits remain excluded. In particular, a seven-cell stone-only
column without an intermediate platform reset still fails after conversion. The assumed
bottom platforms are validation fixtures, not added blueprint blocks.

A seven-cell stone support under original rebar may become seven concrete cells and pass;
an unrelated rebar cell elsewhere cannot authorize that conversion. Replacing support
materials does not reset mineral height: a reinforced path reaching level 21 without a
platform reset or other valid route rejects capture with an explicit 20-level-limit error.
Highlight the lower source cells of that offending support chain, prioritizing replaced
supports rather than only its uppermost cell. All fallback work happens during capture;
the five-neighbor fulfillment rule is unchanged.

The approved first-iteration set is dirt, sand, crushed stone, tree trunk, planks, rebar,
reinforced concrete, and solid country road. Capture also maps grass/packed dirt to dirt;
the three earth states retain one blueprint fulfillment identity after normal dirt aging.
Leaves, geological resources, clay, deeprock, water, snow, and adaptive/custom roads are
excluded. XY support permits the rebar/concrete pair without making their target materials
interchangeable.

For cheap fulfillment with air below, an eligible real XY neighbor is a matching logical
material, either reinforced type for a rebar/concrete target, or natural rock for a
crushed-stone target. Reuse the ordinary `isNaturalRock()` family: stone, metal_ore,
limestone, coal, and deeprock; clay is not in that family. This directed support exception
matches ordinary crushed-bridge routes and prevents a legal foundation removal from
stranding a crushed miniature between real stone sides. It uses the same four XY reads,
adds no recursive validation, and does not change the target's required inventory material.

### Planned blueprint extraction view

Extraction remains forbidden throughout an unfinished blueprint's box, including preexisting
blocks in nontarget cells. Outside all such boxes, the planned general extraction check sees
pending miniature targets as if they were completed blocks. It uses the same ordinary
support rules and fixed windows, with all affected planned cells included as constructions.
Checking only real construction metadata would miss an instance whose blocks are still
miniatures.

There is no extra foundation lock. Actual full 3×3×3 platforms are an application requirement;
later ordinary extraction may remove their cells when the completed logical arrangement
still has valid support. Collision, mining/item transfers, and cheap blueprint fulfillment
use real terrain; miniatures cannot be mined and never count as real support for filling
another target. Replacing a miniature with its required real block leaves the completed
logical view unchanged, so that operation needs no dependent revalidation.

One-time composed admission and ordinary edits must reject incompatible compositions after
correcting the support-eligibility rule described below. An ordinary placement first validates
its new target against physical terrain, then validates that target and affected dependents
in the completed logical view. Physical approval ensures miniatures supply no real support;
completed target approval catches conflicts in the new block itself, which dependent checks
skip. Both views include the same proposed placement.

Joining a six-cell crushed-stone blueprint column to an existing crushed-stone bridge above
creates an illegal seven-cell run. The reverse order is also forbidden: after applying six
miniatures, an ordinary bridge above them can be physically supported by stone sides but
would become the seventh consecutive crushed cell. Completed target validation rejects that
ordinary placement before mutation. A sand target below constructed water/snow is another
conflict. The dependent filter must cover those direct dependencies, including material
classes that cannot themselves be captured in this blueprint iteration.

Share the completed target/dependent validator cache within one ordinary edit, keeping it
separate from the physical cache. If the planned-cell index proves no pending targets can
occur in the target validator's conservative read region, physical target approval can be
reused. This adds no full-design scan or extra checks to five-neighbor blueprint fulfillment.

### Planned blueprint world-mutation invariant

Every gameplay world modification must preserve ordinary structural validity of affected
real and planned constructions in the resulting logical world where all pending targets
are completed. This applies to player/NPC actions, blueprint application, simulation,
timers, debug/service commands, batch edits, and indirect side effects. A modification that
would invalidate that resulting arrangement must not commit. Preserve ordinary
generated-terrain exemptions and bounded affected-region checks; this does not require
scanning the whole world or repeating validation for a proven logical no-op.

Unfinished construction may temporarily violate ordinary physical construction rules both
internally and in its surroundings. This includes partially built structures and already
completed buildings affected by the unfinished work. Finishing one blueprint removes its
own frame and restrictions; it does not promise ordinary physical validity while nearby
targets from other sites remain pending. For example, a valid crushed-stone bridge may
temporarily become a forbidden seventh crushed cell when construction below first fills a
six-cell column, then become valid again when the surrounding stable platform is finished.

Each fulfillment replaces one planned type with an equivalent real type, leaving the
completed logical arrangement unchanged. Once a constructed cell's ordinary
support window contains no pending target from any active site, physical and completed
reads coincide and its ordinary physical validity follows. The current window is an
inclusive cube of ±28 cells on each axis, using shortest wrapped-X displacement; recursive
support checks do not move its center. For a whole completed building, the sufficient
condition applies around every constructed cell, not just its origin or former box center.

Eventual physical validity is a consequence of the mutation admission invariant. It adds no
completion check, repair operation, per-fill search for neighboring sites, or persistent
stability flag. A new nearby site may introduce temporary physical invalidity again while
preserving the completed logical arrangement. Future cancellation and its effects on
remaining or surrounding structures are excluded from this contract and require separate design.

### Planned blueprint global completion order

All active sites must remain structurally completable in some shared order. Placements may
interleave sites: after a legal removal below plank target A, A may rely on a neighboring
site's plank target B being filled first. Cross-site dependencies are accepted. Independent
completion of each site is deferred as a potential improvement, with per-instance logical
readers preferred over the alternative support-component graph for future exploration.

The global guarantee follows from the valid all-sites-completed arrangement and cheap
support covering ordinary routes. At the lowest pending Z, an occupied below cell is
already real; lateral plank/reinforced routes lead to a real contact or a pending target
with such a below cell, while crushed bridges have qualifying real or directly supported
sides. Thus at least one target can fill; filling it leaves the completed view unchanged,
and the argument repeats. This assumes materials/data and nonstructural placement
conditions are available. It adds no scheduler, runtime graph, per-site-view check,
reachability scan, or final validation pass; the five-neighbor bound remains.

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

Trunks and planks can rest on structural materials. Crushed stone can rest on natural or
crushed stone. Rebar and concrete can rest on natural stone or either reinforced material.
A stable platform is an additional valid foundation for all these materials. Resting on
either soil state requires the centered stable platform, rather than just one soil cell.
The current implementation also rejects an incompatible occupied block underneath even
when a separate lateral support route could suffice. The planned correction below replaces
that occupancy veto; it does not make the incompatible block provide support.

### Planned correction: independent support routes

The blueprint iteration must distinguish downward-support eligibility from occupancy.
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
blueprint shortcut. It is planned behavior, not yet implemented.

| Construction group | Maximum height | Horizontal reach from a vertically supported block |
| --- | --- | --- |
| Trunks and planks | 12 levels | Planks: 2 steps; trunks: none |
| Crushed stone, rebar, concrete | 20 levels | Rebar/concrete: 4 steps |
| Crushed stone alone | At most 6 consecutive cells before a platform or material change | One-cell bridge exception below |
| Natural stone | Unrestricted | Generated terrain |

Wood starts a fresh 12-level count above an eligible non-wood foundation. Rebar and concrete
inherit the shared mineral counter across material changes. Vertical moves increment the
relevant counter; horizontal moves inherit it. Air does not reset height: an overhang must
inherit a valid foundation through its horizontal supports. When several routes exist, a
valid route within the span limit can support the block.

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

## Fixed support window

Every edit uses an inclusive cube centered on its target cell: at most 28 cells away on
each axis. All support reads, including platform corners and diagonal intermediate cells,
must fit inside this cube. Searches do not recenter on intermediate supports: stacked
overhangs accumulate horizontal displacement across floors. Stable platforms reset height
counters, but do not reset the window.

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

Validation evaluates hypothetical contents before mutation. Both placements and removals
are checked against potentially affected constructed cells, including changes to platform
cubes away from a vertical support column. An edit that invalidates a construction is rejected atomically.
This prevents support-removal exploits and adding an incompatible material beneath an
existing overhang. Natural terrain cells are not themselves revalidated as constructions.

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
