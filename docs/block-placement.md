# Block placement and timed soil changes

The client and `WorldDataService` use the same structural validator. The client previews an
edit against received blocks; the service checks it again against authoritative contents,
including generated and modified chunks outside every client's subscriptions. Missing
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

Water, sand, and snow retain their existing placement/collision behavior. They are outside
the structural material families and cannot supply earth footprints or stable platforms.
All new materials currently have full-cube collision. The existing atlas supplies temporary
tiles for the new construction materials; no new texture assets or overlay pipeline are added.

Mining results include `mined_type`. There is no inventory, recipe, or dropped-item system
yet; this result provides the conversion contract for a future inventory.

## Stable platforms

A stable platform is a completely filled 3x3x3 cube immediately below a candidate block.
The cube covers x/y offsets -1 through +1 and z offsets -1 through -3. The candidate must
be directly above the center of the cube's top layer. Every cell must contain loose or
packed soil, natural or crushed stone, rebar, or reinforced concrete. Mixtures are allowed;
wood, water, sand, snow, and air do not qualify.

A stable platform supplies a foundation and resets height counters. It can be constructed;
it does not require natural stone underneath it. Repeatedly building a new platform to
restart the counters is an intentional building compromise. This also resets the counted
crushed-stone run at the platform, rather than counting through it.

## Local support and height

Loose soil needs nine structural blocks in the 3x3 layer directly beneath it. Earth,
stone, rebar/concrete, trunks, and planks can fill this layer. A constructed soil block
retains this footprint requirement after compaction, so removing temporary supports cannot
leave a previously placed soil block floating. Generated terrain is exempt from building
validation; natural cliffs and hills remain mineable.

Trunks and planks can rest on structural materials. Crushed stone can rest on natural or
crushed stone. Rebar and concrete can rest on natural stone or either reinforced material.
A stable platform is an additional valid foundation for all these materials. Resting on
either soil state requires the centered stable platform, rather than just one soil cell.
An incompatible occupied block underneath cannot be treated as air to bypass the hierarchy.

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

## Edits and diagnostics

Validation evaluates hypothetical contents before mutation. Both placements and removals
are checked against constructed cells, including changes to platform cubes away from a
vertical support column. An edit that invalidates a construction is rejected atomically.
This prevents support-removal exploits and adding an incompatible material beneath an
existing overhang. Natural terrain cells are not themselves revalidated as constructions.

Operation results carry status, an optional mined material, and an optional failure:
reason, underlying cause, affected cell, measured value, limit, and up to 32 involved cell
coordinates with an explicit truncation flag. The client retains the latest preview/result.
These are CPU data for future text and 3D hints. There is no ghost block, dependency outline,
or transparent rendering pass in this change.

The current implementation revalidates constructed cells on edits rather than maintaining
a dependency index. This favors consistent results over incremental complexity. Time events
do not run structural validation because the soil states have the same support properties.

## Simulation time and transformations

Simulation time uses 60 ticks per second. The application advances it from frame elapsed
time; the service processes monotonic `advanceTo` requests in the same queue as edits.
Stopping game-time advancement pauses deadlines. Subscription eviction has no effect.

- Placing loose soil schedules compaction 30 minutes later.
- Placing any block directly above loose soil compacts the covered soil immediately.
- Newly compacted exposed soil schedules grass 30 minutes after compaction.
- Covering soil clears grass and cancels its pending surface timer.
- Exposing packed soil schedules grass 30 minutes after the exposure.
- Generated soil is already packed, with grass on its exposed surface immediately.
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

Keys 1-6 select loose soil, crushed stone, trunk, planks, rebar, and reinforced concrete.
Z uses the existing vertical-column placement tool with that selection; X mines the column.
The existing reach and player-overlap checks still apply. Arbitrary-cell operations and
previews support the structural rules; crosshair targeting and 3D placement hints are separate
follow-ups.

`zig build test` covers footprints, centered platforms, diagonal connectivity, square
platforms, span limits, inherited/group heights, protected platform edits, crushed-stone
bridges, mining conversions, timer ordering, covering/exposure, chunk boundaries, eviction,
and time catch-up. `zig build test-gpu` checks the shared voxel shader pipelines when a
graphics adapter is available.
