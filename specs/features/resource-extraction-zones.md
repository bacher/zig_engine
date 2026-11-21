---
service: zig_engine
created: 2026-11-21
status: draft
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
  and show the current step and its controls in the upper-right HUD. Selection clicks are
  consumed by the tool.
- R2. Click a surface block to anchor the first corner. Move the pointer to extend an
  inclusive XY rectangle in either direction on the anchor's horizontal plane. Click to
  fix the opposite corner. Uneven terrain does not change the top Z.
- R3. Start at one layer deep. Vertical mouse movement increases or decreases depth in
  whole blocks while XY and top Z stay fixed. The HUD shows width × length × depth.
  The bottom is top Z − depth + 1. Clamp at the world boundary. Depth selection works
  without a ray hit, a visible bottom face, or a camera move. Click to fix the depth.
- R4. Enter on the finished box opens the resource checklist for automated extraction. Every offered
  category starts checked. Offer soil (including grass-covered soil), sand, natural stone, metal ore,
  limestone, coal, and clay. Match the material in the ground before any yield conversion.
  Air and immutable deeprock are never resource choices. Require at least one checked
  category to confirm. Escape in the dialog returns to the box. Canceling the draft
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

- [ ] T1. Implement selection, depth adjustment, HUD and checklist (AC1–AC3).
- [ ] T2. Implement atomic registration, overlap checks, composed reads and persistence
  (AC4, AC6, AC9).
- [ ] T3. Integrate placement protection and support-safe single-cell extraction
  with manual interaction and the authoritative edit path (AC4, AC5, AC7, AC8, AC10).
- [ ] T-val. Run AC1–AC10 through client and service entry points, including the shaft,
  protected supports, and reload after partial excavation.
