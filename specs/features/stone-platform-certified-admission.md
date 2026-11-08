---
service: zig_engine
created: 2026-11-08
status: in-progress
---

# Require stone platforms and reuse blueprint certification

## Intent

Require a full stable platform when natural `stone` supplies a direct foundation for
wood or mineral construction. Use the resulting portable blueprint certificate to
avoid repeating structural searches when applying a saved blueprint.

## Context

The compiler currently assumes synthetic stone platforms. Stone can reset support
with one below-cell read, while a real soil platform needs off-center probes. A
compiler-valid staircase can reach its stone source at distance 28 yet need a soil
platform probe at distance 29. Embedding that staircase in a larger certified box
also shows that checking only targets on the box faces is insufficient.

PR #52 already removed validation of old dependents. This follow-up starts from
`main` and does not depend on PR #48's publication scheduling design.

## Requirements

- R1: Literal `stone` provides direct support and a height/run reset for wood and
  mineral construction only through the existing complete centered 3×3×3 stable
  platform. Preserve independent legal lateral and crushed-bridge routes.
- R2: Keep stone in the stable-platform material family. Platforms may mix any
  existing qualifying materials. Preserve height/span/run limits and the fixed
  target-relative support window of 28 blocks.
- R3: Preserve the direct-foundation shortcuts of ore, limestone, coal and
  deeprock, natural-rock bridge-side eligibility, soil/sand footprints, road
  support, and the five-neighbor blueprint fulfillment path.
- R4: Certify final normalized immutable definitions under the same current
  structural rules. A successful witness must remain available after translation,
  quarter-turn rotation and replacement of virtual platforms by any qualifying
  real platform mixture, including wrapped-X placement.
- R5: Apply may trust a definition produced by the current compiler or restored
  from a compatible game save. Omit repeated per-target structural searches;
  retain well-formedness, bounds, physical emptiness, immutability, overlap,
  complete physical bottom platforms, ownership/resources and atomic publication.
- R6: Capture complete rotated box-index sources and the bottom-platform read
  envelope: one cell in X/Y and three cells downward, rounded to canonical chunks.
  Retain cavity sources, deduplication, budgets and every captured revision gate.
- R7: Preserve the existing mutation FIFO, asynchronous preparation and source/
  journal waits. Do not implement PR #48's scheduling or chunk protection here.
- R8: Advance both the world write version and minimum readable version to 5.
  Reject older development saves through existing base/WAL gates; add no migration,
  historical rules, per-definition versions or automatic recertification.
- R9: Measure admission preparation and ordinary placement costs separately.
  Preserve zero ordinary-validator work and at most five physical support reads
  for blueprint fulfillment.

## Clarifications

- Q1: Does the restriction include every geological material?
  A1: No. It applies to literal `stone`. Other natural-rock shortcuts are preserved;
  they can only provide additional real support relative to the certificate.
- Q2: Must natural-rock sides of a crushed bridge each have a full cube?
  A2: No. That would also fill the cell below the middle gap and remove the usual
  air-below bridge. This separate support route remains unchanged.
- Q3: Does every operation above stone require 27 cells?
  A3: No. Soil/sand keep their nine-cell footprint and roads keep their immediate
  below-cell predicate, just as they do above soil today.
- Q4: Are manually fabricated structurally invalid recipes certified?
  A4: No. Shape validation alone is not certification. Apply's internal input
  contract relies on the normal immutable compiler/library/save ownership path.

## Acceptance Criteria

- AC1: GIVEN an isolated stone below wood or mineral construction WHEN direct
  support is checked THEN it rejects without a full qualifying cube or another
  legal route, while a complete mixed cube accepts.
- AC2: GIVEN the former reach-28 staircase with a required off-center platform
  probe at distance 29 WHEN capture compiles it THEN capture rejects, including
  when the failing target lies strictly inside a larger box.
- AC3: GIVEN existing legal lateral routes, bridges, resource/deeprock foundations,
  soil footprints or roads WHEN the shared rules run THEN their preserved routes
  still work and empty-cell additions preserve existing valid support witnesses.
- AC4: GIVEN current compiler-certified definitions on full mixed real platforms
  WHEN translated/rotated cases at chunk edges and the X seam are admitted THEN an
  independent completed-world structural reference accepts every new target and
  narrow/oversized captures prepare the same semantic publication.
- AC5: GIVEN occupied/immutable targets, overlapping sites, invalid bounds, missing
  target/platform/box-index data or exceeded budgets WHEN Apply runs THEN it rejects
  without partial state, while later captured revision changes still reject commit.
- AC6: GIVEN sparse definitions with cavity chunks WHEN dependencies are collected
  THEN complete box-index sources and physical platforms are included without a
  structural halo, including finite clipping and canonical seam deduplication.
- AC7: GIVEN a version-4 development save or WAL WHEN the new game opens it THEN
  existing version gates reject it; version-5 persistence round trips still work.
- AC8: GIVEN the reference admission and multi-site fulfillment workloads WHEN
  benchmarks run THEN admission reports zero structural target/dependent checks,
  allocation/counter assertions pass, and fulfillment keeps its five-read bound.

## Constraints

Reuse the shared structural validator for ordinary edits and compiler certification.
The portability argument preserves complete positive support witnesses inside each
root's unchanged window; do not widen the window or add persistent support metadata.
Keep ordinary resource accounting, progress and removal-dependent validation intact.

## Out of Scope

PR #48 scheduling/protection, save migration, old-rule execution, geological material
family redesign, bridge removal, collapse/physics, independent per-site completion,
NPC logistics, and changes to the cheap fulfillment predicate.

## Plan

Gate every direct/reset stone shortcut, including wood's generic vertical reset.
Prove foundation substitution using complete in-window cubes, footprint cells and
road support; then use finite-addition monotonicity for cavity/exterior contents.
Remove Apply's structural validator and shrink the shared chunk collector. Keep
complete box sources and dependency rechecks. Advance the compatibility gates and
update the existing specification and validation reports. Compare admission against
an independent full-validator test oracle and measure current/baseline costs.

## Tasks

- [x] T1: Implement platform-only stone support and focused shared-rule regressions.
- [x] T2: Verify certificate portability against an independent structural reference.
- [x] T3: Remove repeated Apply structural searches and narrow dependency collection.
- [x] T4: Advance save gates and update affected specifications/documentation.
- [x] T5: Record admission and ordinary-placement measurements against `main`.
- [x] T-val: Run relevant Debug suites, full ReleaseFast builds/tests, formatting,
  document checks and independent review.
