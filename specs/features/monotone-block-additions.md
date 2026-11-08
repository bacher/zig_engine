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

- R1: With fixed custom-road shapes, inserting a legal block into an empty cell preserves
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
  data handling, and the fixed support radius. Removals, occupied-cell replacements, and
  road shape changes keep their normal validation.
- R6: Preserve bounded validator memory and cached-read evidence. Do not introduce persistent
  dependency graphs, per-block support versions, or additional blueprint-fulfillment work.

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
- AC7: GIVEN missing support data, span/height limits, required supports, or a road shape
  mutation WHEN validation runs THEN existing conservative guards still apply; no cheap
  blueprint fulfillment gains recursive work.
- AC8: GIVEN representative ordinary and crushed-stone workloads WHEN the existing placement
  benchmark is run before and after THEN validation cost and reader-call changes are recorded,
  including the new bridge-reset path, without claiming a universal latency bound.

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
material families, NPC scheduling, save migrations, and historical rulesets.

## Plan

Update the shared crushed run and bridge-route selection, and remove the negative sand
predicate for water/snow. Cover preserved support witnesses, route-selection regressions,
operation order, ordinary world edits, and real/planned admission. Update superseded examples
in block-placement documentation and the blueprint spec while preserving their stable IDs.
Measure representative costs against `main` before considering separate admission work.
The [validation report](../../docs/validation/monotone-block-additions.md) records passing
CPU suites, the preserved-support argument, and paired benchmark measurements.

## Tasks

- [x] T1: Implement bounded independent-bridge run resets and minimum-height route selection.
- [x] T2: Allow water/snow above sand and remove their obsolete dependency predicate.
- [x] T3: Add core monotonicity/limit/removal/cache regressions and world/admission coverage.
- [x] T4: Update current rules and superseded blueprint examples without changing admission.
- [x] T-val: Run relevant CPU suites and record before/after placement benchmark results.
