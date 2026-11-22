---
service: zig_engine
created: 2026-11-21
status: implemented
---

# Designate resource extraction zones

## Intent

A player marks a volume of ground and chooses which resources the simulation may extract there.
Confirmation creates a persistent simulation object. The ground stays in place until
individual extractions succeed.

## Context

Blueprint capture already has a staged box selection, a striped frame, and control hints.
For mining, the top layer is the surface block the player points at. The bottom can be
buried throughout the interaction. [Blueprint capture](blueprints.md)

Construction sites already transfer cell authority to simulation while exposing a composed
world to terrain readers. Warehouses reserve cells, including air. Both precedents matter
here because a mining zone holds real terrain and continues to reserve the space after
a block is removed. [Construction ownership](construction-state-ownership.md) · [Warehouse claims](warehouses.md)

## Requirements

- R1. Pressing G during gameplay enters extraction selection. Use the blueprint-style frame
  and show the current step and its controls in the upper-right HUD. Entering cancels any unfinished ordinary mining or placement hold. The draft
  and dialog own mouse and keyboard interaction (including E). On exit a held control
  must be released and pressed again before it can start an ordinary edit. Already
  submitted commands still receive their authoritative result.
- R2. Click a surface block to anchor the first corner. Move the pointer to extend an
  inclusive XY rectangle in either direction on the anchor's horizontal plane. Click to
  fix the opposite corner. Choose the shorter wrapped X displacement from the anchor
  as blueprint capture does. An exact half-period tie is invalid. Keep the last valid
  frame and disable confirmation until the endpoint is valid again. The frame, stored
  bounds and claim lookups use the same inclusive interval. Uneven terrain does not
  change the top Z.
- R3. Start at one layer deep. Vertical mouse movement increases or decreases depth in
  whole blocks while XY and top Z stay fixed. The HUD shows width × length × depth.
  The bottom is top Z − depth + 1. Clamp at the world boundary. Depth selection works
  without a ray hit, a visible bottom face, or a camera move. Click to fix the depth.
- R4. Enter on the finished box opens the resource checklist for automated extraction. Every offered
  category starts checked. Offer soil (including grass-covered soil), sand, natural stone, metal ore,
  limestone, coal, and clay. Match the material in the ground before any yield conversion.
  Air and immutable deeprock are never resource choices. Require at least one checked
  category to confirm. Before confirmation, tell the player that placement stays blocked
  throughout the box after exhaustion and that v1 has no action to remove the zone. Escape in the dialog returns to the box. Canceling the draft
  before confirmation leaves the world untouched.
- R5. On confirmation the authority validates the current bounds and claims, then commits
  the zone identity, bounds, filter, and transfer of all mutable occupied cells to simulation
  together. This includes unchecked materials and previously placed blocks. Retain material,
  generated/constructed provenance, support participation, and applicable soil timers.
  Canonical deeprock stays under the world floor's immutable authority. A failed registration
  leaves every cell and claim with its original owner.
- R6. Reserve the entire box against placement for the zone's lifetime, including original
  air, unchecked cells, and excavated cells. Enforce this on ordinary placement, blueprint
  admission, and other writers at the authority. Reject a box that
  intersects another zone, an active construction box, or any registered warehouse claim.
  Reject a conflicting registration in the reverse order as well. Face adjacency is allowed.
- R7. Collision, targeting, rendering, and support queries observe the same physical blocks
  before and after handoff. Direct all subsequent edits to the current owner. Save/load
  restores the zone, its filter, remaining blocks and protected air coherently. An excavation
  must not reveal a second terrain copy or regenerate a mined block on reload.
- R8. For each requested extraction, check the current cell, configured mining
  outcome, ownership, and ordinary removal rules against the world with that one cell
  removed. Apply the zone filter only to automated extraction. Protect affected real and planned constructions inside and outside the box.
  If a dependent would lose required support, leave the cell and inventory unchanged and
  return the ordinary diagnostic. Other cells remain eligible for independent checks.
  Designation itself requires no proof that every selected block can eventually be mined.
- R9. Preview and authority independently check the inclusive volume (including air) and
  number of distinct intersected source chunks, accounting for alignment and wrapped X.
  Use checked arithmetic and the shared blueprint capture budgets as initial limits
  (1,048,576 cells and 256 chunks). Reject overflow or either excess before zone-specific
  chunk acquisition, retention, or cell copying. Preview reports the exceeded limit and
  disables confirmation. Authority rejects the whole request without acquiring a claim.
- R10. Transfer each formed adaptive road section's slope descriptor with its cell. The
  road planner reads the composed run and routes shape updates to each section's current
  owner, including surviving sections across a zone boundary. Shape changes on occupied
  road cells are permitted under the placement restriction. [Country roads](country-roads.md)
- R11. The soil cell's owner schedules, cancels, and executes grass growth. Transfer each
  outstanding deadline exactly once at handoff. Subsequent exposure, cover, and removal
  notify the affected owner across zone boundaries. Use composed physical occupancy and
  pending target cover: exposure schedules growth after 30 simulation minutes, cover
  cancels the timer and clears grass, and removal cancels the old cell's timer. At expiry
  recheck soil identity and cover. Unknown cover defers evaluation with the original
  deadline. Persist the deadline with its owning cell.

  A completed construction can release its box before world-data initializes its grass.
  If registration encounters an `initialize_grass` marker, its `due_tick` identifies the
  construction instance. Before handoff, let world-data finish the existing initialization
  for that instance and chunk using the queued completion tick and current composed cover.
  Exposed, still-marked dirt gets a deadline of completion tick plus the ordinary growth
  delay. Covered dirt gets no timer, and a newer edit or timer takes precedence. While
  initialization is pending, keep the cells with world-data and defer registration. Recheck
  bounds, claims and current cell state before committing the transfer. [Timed soil rules](../../docs/block-placement.md)
- R12. Commit manual removal of a zone cell and its inventory effect in one authoritative
  operation. Every durable capture includes both effects or neither. A same-session retry with
  the same identity and intent replays a completed result only while the ledger retains
  that record. Once the acknowledged
  sequence retires, the retry returns `StaleCommand`. Neither path edits the cell or slot.
  After restart, resynchronize from saved state under the existing command contract. [Persistence and inventory](../../docs/persistence.md)

- R13. Near block subscriptions receive the terrain and a baseline for the extraction-owned
  portion of that chunk. The client installs both before exposing the handoff to readers.
  During normal mining, send changed zone cells once per worker publication batch to interested
  near observers. The miner also receives the command result and slot outcome. Reject stale
  tokens and recover a missing base revision for the affected chunk. An unrelated zone portion
  outside the subscription generates no client updates.
- R14. Distant surface subscriptions receive complete geometry for affected chunks. Coalesce
  multiple excavations in a worker batch and rebuild from the final physical state. A removal at
  a chunk face can expose a neighbor's face regardless of which side owns the removed cell.
  Surface visibility here means exposure to air, including enclosed cavities.

## Clarifications

- Q1. **What happens to a vertical shaft?** A temporary Zig test against the current
  `block_rules.Validator` excavated a 5×5 shaft top-down through four layers of soil
  over four layers of natural stone, accepting all 200 removals. The fixture surrounded
  the cut with solid terrain and registered the adjoining soil walls as constructed.
  Beside a straight wall, six of nine cells below remain, including the center. All three
  gaps lie on the shaft-facing edge. At an outside corner only one diagonal cell is
  missing. Each soil course uses the course immediately beneath it, so a fourth course
  adds no wall-height restriction. Generated natural stone is mineable and is not indexed
  as a constructed dependent. The full stone platform rule matters when a construction
  relies on that platform. In the negative control, removing the floor under a pallet
  returned `would_remove_support`. These are structural-validator results for this
  geometry. [Ordinary removal rules](../../docs/block-placement.md)

  A second validator test excavated a 5×5 shaft through 32 layers of natural stone.
  All 800 top-down removals succeeded, leaving the surrounding walls and floor intact.
  A pallet on the rim retained its floor, and a separate attempt to mine that floor
  returned `would_remove_support`. The 20-level limit governs the supported height of
  crushed stone, rebar, and reinforced concrete. Natural stone has no shaft-depth limit
  above the immutable world floor.
- Q2. **What does checking ore enable today?** It selects that resource for future automated extraction. Current mining yields dirt for grass and crushed stone for natural stone.
  Metal ore, limestone, coal, and clay have no configured usable mining result. Preserve
  those choices across reload and leave such cells intact until a usable output exists.
  The checklist should identify these currently unavailable yields. [Mining capability](world-generation.md#mining-capability-and-immutable-world-floor)
- Q3. **Who can extract in v1?** Players can manually extract any ordinarily mineable block in the
  zone, including unchecked resources and materials absent from the checklist. The usual
  reach, timing, inventory, and structural checks apply. Designating ground grants no
  inventory items and starts no work. Zone retirement and handback are deferred, so even
  an exhausted zone keeps its placement restriction in this first version.

## Acceptance Criteria

- AC1. GIVEN gameplay WHEN G is pressed and the player selects opposite corners in either
  XY direction THEN the frame encloses the inclusive footprint at the first block's Z and
  the upper-right hint advances to depth selection.
- AC2. GIVEN a 5×5 footprint WHEN the player moves the mouse to depth 8 with the bottom
  fully buried THEN the frame spans eight layers, the top stays fixed, and the HUD shows
  5×5×8. Reversing mouse movement can reduce it to one layer.
- AC3. GIVEN a fixed box WHEN Enter opens the filter THEN all seven categories are checked.
  Clearing all disables confirmation. Canceling before submission leaves no claim.
- AC4. GIVEN a box containing grass, sand, stone, ore, deeprock, and air WHEN confirmed
  with only soil and ore checked THEN simulation owns every mutable occupied cell, the initial
  physical view is identical, grass matches soil, sand and stone are excluded from automated extraction, and ore
  retains its selected but currently unmineable status.
- AC5. GIVEN a zone WHEN placement targets original air or a mined cell, including via a
  blueprint, THEN authority rejects it. An otherwise legal placement just outside succeeds.
- AC6. GIVEN intersecting zone and construction or warehouse claims, or two intersecting
  zone requests WHEN registration is attempted THEN only the first compatible registration
  commits. A failed or retried request cannot leave partial ownership or duplicate zones.
- AC7. GIVEN the Q1 shaft WHEN ordinary, authorized removals proceed one cell at a time from
  the top THEN the full 5×5×8 interior becomes air, all surrounding wall blocks survive,
  and natural stone yields crushed stone.
- AC8. GIVEN an in-zone cell supplying the only required support for a real pallet or an
  adjacent planned construction WHEN its removal is attempted THEN the authority rejects
  that cell, preserves its material, and issues no item. An independent legal cell in the
  same zone can still be removed.
- AC9. GIVEN a partially mined zone crossing a chunk boundary WHEN chunks unload and the
  world is saved and reloaded THEN the same zone and filter are present, mined cells stay
  empty and protected, and remaining cells still have exactly one authority.
- AC10. GIVEN a zone with only soil checked, an exposed natural stone block (unchecked),
  and a plank block (absent from the checklist) WHEN the player manually mines each under
  ordinary valid conditions THEN the removals yield crushed stone and planks respectively.
  Both cells remain protected against placement and the filter still selects only soil.
- AC11. GIVEN independently configurable cell and chunk ceilings WHEN a box meets both
  limits THEN budget admission succeeds. WHEN a box exceeds either ceiling by one while
  inside the other, or its volume arithmetic overflows, THEN preview disables confirmation
  and an independently submitted request fails before source acquisition or copying. No
  claim or ownership change survives.
- AC12. GIVEN a formed road with an interior section inside the box and endpoints outside
  WHEN the zone is confirmed and reloaded THEN the section retains its rendered slope and
  collision. WHEN an outside endpoint is mined THEN all surviving sections on both sides
  revert to unformed road geometry and collision, and the endpoint stays empty.
- AC13. GIVEN buried zone-owned dirt WHEN the covering block is mined and the world is
  saved and reloaded before grass grows THEN the original deadline fires once and the
  soil becomes grass. Placing cover just above the zone before expiry cancels growth;
  placing it after expiry clears grass. Repeat with a timer already pending at handoff.
- AC14. GIVEN a manual extraction of natural stone into an empty slot has committed and its
  acknowledgment was lost, WHEN the same command is retried while
  the completed record is retained THEN it returns the original result. After save and
  reload the cell is protected air and the slot holds exactly one crushed stone.
- AC15. GIVEN a world of width W WHEN the player selects X from W−1 to 0 THEN the frame
  covers exactly two columns and, after reload, claims at either column conflict while
  an adjacent column remains free. An endpoint exactly W/2 from the anchor cannot commit.
- AC16. GIVEN an unfinished E hold WHEN the player presses G, holds E through cancellation
  and returns to gameplay THEN no ordinary edit is submitted until release and a fresh
  press. Repeat for Mouse1 and for a press that begins inside the checklist.
- AC17. GIVEN a 5×5 footprint in natural stone with a pallet on the rim WHEN 32 layers
  are removed top-down THEN all 800 removals succeed, the walls and floor remain intact,
  and mining the pallet's own support still fails.
- AC18. GIVEN a finished box WHEN the confirmation dialog opens THEN the player can see
  the permanent v1 placement restriction and cancel before any claim is created.
- AC19. GIVEN exposed construction dirt still marked for initialization after its box is
  released WHEN a zone registration reaches the cell before the initialization pass,
  commits after initialization, and the world is saved and reloaded before growth THEN
  the zone owns the dirt and its single deadline. It stays bare until completion tick
  plus the growth delay, then grows once. Use distinct completion and registration ticks.
- AC20. GIVEN AC14's command has been acknowledged and retired, and the player has since
  emptied the slot WHEN the identical command arrives again in the same session THEN it
  returns `StaleCommand`, the cell remains protected air, and the slot remains empty.

- AC21. GIVEN two near clients watching one extraction chunk WHEN ten zone cells are mined
  in one publication batch THEN the observer receives one update containing the ten changes,
  the miner receives its command results, and the batch sends neither client a whole block
  chunk for those removals. A newly subscribed client sees the same final physical state.
- AC22. GIVEN a distant observer at a shared chunk face WHEN ten zone cells are removed in a
  batch THEN one complete surface per affected subscribed chunk exposes the adjoining terrain.
  Mining terrain on the other side exposes the surviving zone cells in the same way.

## Constraints

Use the existing world topology, including wrapped X, finite Y/Z, and unique canonical cells
within a box. Preserve bounded structural checks and generated-terrain exemptions. Ownership
transfer must never turn natural shaft walls into constructed dependents. Missing or stale
data requires authoritative resolution before a mutation commits.

## Out of Scope

Worker assignment, task ordering, accessibility and hauling, extraction rates, new mineral
items or yields, production and recipes, advanced extraction methods, collapse physics,
and UI for editing or retiring a confirmed zone.

## Plan

1. Extend the selection UI using the blueprint frame and hints. Keep the surface anchor and
   screen-space depth calculation in an extraction draft alongside `blueprint_tool.zig`.
2. Define a simulation-owned zone with stable ID, canonical bounds, resource mask and
   chunk-addressable cell state. Coordinate registration with `world_data_service.zig`,
   existing construction ownership, and `warehouse_claims.zig`. Preserve the physical
   view and soil deadlines across the handoff and durable capture.
3. Route placements and removals in `world.zig` through claim and ownership lookup.
   Reuse the ordinary mining outcome and completed-world dependency validator. Include
   zone-owned constructed cells in dependent discovery for edits on either side of the
   boundary. Expose refusal reasons through the existing interaction feedback.

## Tasks

- [x] T1. Implement selection, depth adjustment, HUD and checklist (AC1–AC3, AC11, AC15, AC16, AC18).
- [x] T2. Implement atomic registration, overlap checks, composed reads and persistence
  (AC4, AC6, AC9, AC11–AC15, AC19).
- [x] T3. Integrate placement protection and support-safe single-cell extraction
  with manual interaction and the authoritative edit path (AC4, AC5, AC7, AC8, AC10, AC12–AC14, AC17, AC20).
- [x] T4. Deliver near zone snapshots and deltas, and coalesce distant surfaces (AC21–AC22).
- [x] T-val. Verify AC1–AC22 through client and service entry points, including shafts, protected
  supports, reload after partial excavation, and near and distant publication.

### Validation

The game tests exercise the G sequence from a surface hit through the resource dialog,
including a buried 5×5×8 preview, release of held controls, and confirmation through the
world service. The service tests excavate a 5×5×8 mixed shaft and a 5×5×32 natural-stone
shaft, inspect the resulting walls and floor, and reject mining the pallet's support.

Restart tests cover a partially mined zone spanning the wrapped X seam, a road slope
whose endpoint belongs to terrain, and grass deadlines inherited from terrain or a
completed construction. The inventory test replays a mining command before acknowledgment,
spends the item, rejects the retired command, and reopens the earlier save with the item
and the corresponding hole. Run the full suite with `zig build test`.

The near transport test submits ten removals together to a miner and an observer. Both
receive one exact-base update with ten tombstones. The miner also receives ten command
results. The adjoining near chunk receives its neighbor occupancy update, and fresh
interest in the exhausted zone receives the claim with no occupied cells.

The distant transport workload places the zone along a shared chunk face. Ten batches
remove zone stone, and ten remove adjoining terrain stone. One observer receives 40
complete surfaces for 200 removals. The native face and custom-block arrays total
264,240 bytes, averaging 13,212 bytes per ten-removal batch. At one such batch per second
the geometry payload would average 13.2 kB/s per observer. This excludes metadata, any
future network framing, and the initial load. A ReleaseFast run took 13.0 ms of service
wall time across all 20 batches for building and copying the surfaces. To repeat, run
`zig build test-world-service -Doptimize=ReleaseFast -Dtest-filter='extraction far surfaces'`.

### Follow-up improvements

- Evaluate saving only the extraction-zone chunks changed since the last durable capture.
  Format 9 already saves changed terrain chunks individually. A change to any zone currently
  replaces the complete zone image. After mining one block from a full 128×128×64 zone,
  preparing the capture took 81.8 ms on the service executor and produced 3,146,222 bytes
  of zone data (ReleaseFast, median of three runs). Compare executor time, WAL bytes and
  reopen time on the same workloads. Recovery must preserve the bounds and filter of an
  exhausted zone, clear the last occupied cell of a depleted chunk, and restore the terrain
  and inventory from the same commit. [Measurements and reproduction](../../docs/validation/extraction-zone-persistence.md)
