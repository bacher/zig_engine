---
service: zig_engine
created: 2026-11-08
status: in-progress
---

# Preserve structural validity when adding blocks

## Intent

Preserve existing valid higher constructions when a legal block is inserted into an empty
cell. Make support rules additive so new support cannot suppress an existing support route,
without adding synchronization or persistent support metadata to the simulation.

## Context

Client previews, authority, blueprint compilation, and destination admission share
`block_rules.zig`. Crushed-stone checks previously rejected any vertical run longer than six
before considering independent bridge support, and selected the first bridge orientation
even if another orientation or the direct route had a lower mineral height. Water/snow were
allowed above air but rejected above sand. These predicates could invalidate existing
constructions solely because a block was added below or beside them.

## Requirements

- R1: Inserting a legal block into an empty cell preserves
  the ordinary structural validity of previously valid higher constructed cells, with each
  cell assessed in its existing support window. Use one shared current ruleset.
- R2: An independently supported crushed-stone bridge interrupts the downward six-cell run
  count. A seventh adjacent crushed cell is allowed when this independent support exists.
  A narrow seven-cell column without such support or a foundation reset still rejects.
- R3: Choose the minimum supported mineral height across the direct route and both crushed
  bridge orientations. Adding a route cannot discard a better existing route. Preserve the
  20-level mineral limit and existing bridge-side material/direct-support requirements.
- R4: Water and standalone snow may be placed directly above sand; adding legal sand below
  existing water/snow is also allowed. They gain no structural-support or platform role.
- R5: Preserve wood height, mineral height, spans, footprints, platform semantics, unknown
  data handling, and the fixed support radius. Removals and occupied-cell replacements
  keep their normal validation; shape-only road changes preserve structural capabilities.
- R6: Preserve bounded validator memory and cached-read evidence. Do not introduce persistent
  dependency graphs, per-block support versions, or additional blueprint-fulfillment work.
- R7: The new target's structural proof reads only the fixed envelope `abs(dx) <= 28`,
  `abs(dy) <= 28`, `-28 <= dz <= 0`, with Z vertical and shortest wrapped-X displacement.
  Both horizontal axes may reach 28 simultaneously. Recursive searches never recenter.
  This invariant applies to new support features; it excludes chunk I/O/copies, diagnostics,
  soil state bookkeeping, and the existing separate dependent checks.
- R8: Formed slopes and unformed adaptive roads have identical structural capabilities.
  A road above either receives the same support. Preserve all other material-support
  families; do not add roads to wood, mineral, earth, or stable-platform support families.
- R9: Overhead real or planned blocks do not veto formation or saved-formation replay.
  Shape-only formation/reversion requires no structural/dependent validation or queries
  above the road. Preserve pattern, section-support, ownership, finite-bound, immutable-write,
  source-hold, persistence, and atomic-publication guards. Do not change collision geometry;
  obstructions affect passage through the normal collision rules.

## Clarifications

- Q1: Does a bridge restart the mineral-height counter too?
  A1: No. It interrupts the geometric crushed run; the mineral counter inherits the lowest
  eligible route. These remain separate existing constraints, rather than requiring a new
  joint run/height path representation.
- Q2: Does this remove blueprint admission's environment checks?
  A2: No. Those checks and their snapshot halo remain in place. This branch changes the
  underlying rules and supersedes old conflict examples; admission optimization is separate.
- Q3: Does every legal target placement now have to be accepted by an ordinary edit?
  A3: The property concerns preservation of existing support, not all operation preconditions.
  Existing dependent checks may conservatively reject when the intersection of the edit's
  and dependent's fixed windows cannot prove support. No window expansion or dependent-check
  bypass is introduced here. Occupancy, inventory, progress, and other checks still apply.
- Q4: Are save migrations or historical gameplay rules needed?
  A4: No. The serialization is unchanged and previously valid arrangements remain valid.
  Retain the current save version and the pre-release compatibility policy.
- Q5: Do roads acquire new support roles for other materials?
  A5: No. The user explicitly confirmed preserving material families and only unifying the
  formed/unformed states. Another road can stand above either; other materials still need
  their existing eligible direct/platform/lateral support.
- Q6: Does R7 describe the whole current placement operation?
  A6: No. Existing ordinary dependent validation may still read above the target. Its removal
  remains separate. Road shape changes no longer trigger extra surrounding validation;
  pattern discovery still reads endpoints, candidate sections, and their immediate support.

## Acceptance Criteria

- AC1: GIVEN an independently side-supported crushed bridge above air WHEN six legal crushed
  cells fill the lower column THEN the bridge and already-valid blocks above remain valid;
  WHEN a necessary side support is removed without another route THEN removal rejects.
- AC2: GIVEN a narrow crushed column without bridge or platform resets WHEN the seventh cell
  is attempted THEN the crushed-column limit still rejects it with useful involved cells.
- AC3: GIVEN direct and two-axis bridge routes of different supported heights WHEN an added
  block enables a worse route THEN the original lower route remains selected and higher
  blocks within the mineral limit remain valid, independent of axis order and cache reuse.
- AC4: GIVEN sand, water, or snow at a prepared site WHEN sand and water/snow are placed in
  either order THEN both placements succeed; removing a required sand-footprint cell rejects.
- AC5: GIVEN the supported seventh bridge and sand/water fixtures WHEN ordinary client edits
  or blueprint admission run with real or pending neighboring targets THEN the revised rule
  agrees across physical/completed views and target progress remains correct.
- AC6: GIVEN representative valid material arrangements WHEN accepted empty-cell additions
  are applied in varied orders/orientations/translations THEN previously valid higher cells
  remain valid when rechecked with fresh and shared validator caches.
- AC7: GIVEN missing support data, span/height limits, required supports, or immutable writes
  WHEN validation/planning runs THEN existing conservative guards still apply; no cheap
  blueprint fulfillment gains recursive work.
- AC8: GIVEN representative ordinary and crushed-stone workloads WHEN the existing placement
  benchmark is run before and after THEN validation cost and reader-call changes are recorded,
  including the new bridge-reset path, without claiming a universal latency bound.
- AC9: GIVEN a supported road with an occupied or planned cell directly above WHEN it forms
  or reverts THEN its structural capabilities and the upper target's identity/progress are
  unchanged, including ordinary preview/commit, authority, deferred updates, and replay.
- AC10: GIVEN a complete adaptive road pattern and an unreadable region above the road or
  an unrelated construction nearby WHEN formation/replay runs THEN the planner does not
  query that upper region or revalidate unrelated constructions; immutable section writes
  still reject without partial publication.
- AC11: GIVEN either road shape as immediate support WHEN target structural checks run THEN
  solid/adaptive roads agree across shapes, other material families keep their old results,
  custom-shape callbacks are not queried, and removal of required support still rejects.

## Constraints

Support proofs use only same-level material connectivity and lower-Z direct sources;
unsupported horizontal cycles cannot create support. The bridge reset reuses the existing
one-cell/direct-side predicate. Keep the six-cell scan bound and use bridge fallback only
when needed to preserve the ordinary short-column path. Minimum-route selection may inspect
both orientations but can return once the minimum possible height is found.

Cache entries retain compact successful states and complete read evidence. Unknown or clipped
reads cannot become air or certify a route that requires them. The new rule relaxes existing
accepted configurations; it does not tighten raw/generated bridge-side semantics.

## Out of Scope

Blueprint snapshot-halo reduction, removal of admission/dependent checks, PR48 publication
scheduling/locking changes, a joint run/height path frontier, physics/collapse, new spans or
material families, new pathfinding/usability flags, NPC scheduling, save migrations, and
historical rulesets.

## Plan

Update the shared crushed run and bridge-route selection, and remove the negative sand
predicate for water/snow. Cover preserved support witnesses, route-selection regressions,
operation order, ordinary world edits, and real/planned admission. Update superseded examples
in block-placement documentation and the blueprint spec while preserving their stable IDs.
Measure representative costs against `main` before considering separate admission work.
Make road structural support independent of geometry, remove above-road formation vetoes
and obsolete final-plan structural validation, and cover overhead targets and replay without
adding new replay admission policy. Record the two agreed locality/monotonicity invariants.
The [validation report](../../docs/validation/monotone-block-additions.md) records passing
CPU suites, the preserved-support argument, and paired benchmark measurements.

## Tasks

- [x] T1: Implement bounded independent-bridge run resets and minimum-height route selection.
- [x] T2: Allow water/snow above sand and remove their obsolete dependency predicate.
- [x] T3: Add core monotonicity/limit/removal/cache regressions and world/admission coverage.
- [x] T4: Update current rules and superseded blueprint examples without changing admission.
- [x] T5: Unify formed/unformed road support and remove shape-only structural validation.
- [x] T6: Verify overhead real/planned roads, formation/reversion/replay, read bounds, unchanged
  material families, immutable writes, and client/authority/deferred publication.
- [x] T-val: Run relevant CPU suites and record road-follow-up validation alongside the
  existing before/after placement benchmark results.
