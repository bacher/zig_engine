---
service: zig-engine
created: 2026-11-13
---

# Automate real-client construction visual comparisons

## Intent

Measure whether budgeted construction graphics improve complete client frame pacing
at acceptable graphical delay. Run a repeatable construction and camera scenario
through the actual windowed client, retaining raw data and comparable A/B reports.

## Context

PR #58 caches miniature geometry. PR #59 budgets local terrain and miniature
preparation. Existing CPU replays and offscreen GPU benchmarks isolate components;
they do not establish complete-client frame pacing or edit-to-display latency.

## Requirements

- R1: Enable the scenario explicitly by CLI in a fresh ephemeral flat world. Normal
  launches retain their existing rules, persistence, simulation and graphics policy.
- R2: Create valid blueprints and fill them through public world-service APIs;
  use ordinary subscriptions, reconciliation, preparation, GPU uploads and rendering.
- R3: Schedule fills and camera motion by monotonic elapsed time, record admission,
  acceptance and rejection, and drain the same finite workload before comparison.
- R4: Compare immediate and budgeted preparation with the same miniature cache and
  gameplay revision. Immediate removes count/time limits but retains FIFO overhead;
  the comparison isolates the budget and does not measure all overhead of PR #59.
- R5: Buffer frame timings and fulfillment-to-submission records in memory, export
  after the run, and avoid per-frame GPU fences, readbacks and file writes.
- R6: Track terrain and miniature publication separately, including coalesced changes.
  Label the result as submission latency, including offscreen/occluded geometry, not
  physical display latency or a guarantee that an individual block produced pixels.
- R7: Run sequential alternating repetitions with fixed resolution/settings and
  readiness-based warmup. Reject invalid workloads, incomplete publication, changed
  resolution/focus, or differing final checksums before calculating A/B aggregates.
- R8: Allow an explicit benchmark-only render radius of 3–5 chunks, default 3.
  Record it in reports and reject effective-radius changes or mismatched A/B radii.
  This varies the outer mesh ring while keeping the local block-data radius and
  normal gameplay defaults unchanged.

## Clarifications

- Q1: Which comparison is implemented first?
  A1: The user approved the same-client immediate-versus-budgeted comparison. An
  exact main-versus-PR comparison using identical harness patches remains separate.
- Q2: What workload does the first fixture represent?
  A2: Nine valid thick rebar perimeter sites span nine XY columns and three Z chunks.
  Orbit keeps the local neighborhood stable; travel crosses chunk boundaries and
  exercises streaming/representation changes. This is a synthetic construction
  workload, not an implementation or throughput measurement of future NPC AI.

## Acceptance Criteria

- AC1: GIVEN a normal launch WHEN no benchmark option is present THEN no benchmark
  scenario, extra timing clocks, report files or policy override is enabled.
- AC2: GIVEN an opted-in run WHEN the workload executes THEN public API setup and
  fills succeed, the planned finite command count is accepted, graphical work drains
  and raw frame/event files and a validated summary are written automatically.
- AC3: GIVEN equal rate/duration/camera inputs WHEN A/B repetitions run THEN command
  counts, final state checksum and render resolution match; frame counts may differ.
- AC4: GIVEN delayed/coalesced terrain and miniature updates WHEN their containing
  frame is submitted THEN each event receives its first completion timestamp for
  each representation without waiting for GPU completion.
- AC5: GIVEN a failed, incomplete or incomparable run WHEN the automation summarizes
  results THEN it retains artifacts and reports the failure without A/B speedup claims.

## Constraints

Use one set of gameplay rules and the real client/service paths. Keep benchmark-only
state bounded and inactive in ordinary play. Measurements require a working GPU and
graphical session. Keep component results separate from full-client results.

## Out of Scope

Physical monitor latency, GPU timestamp queries, a general replay framework, NPC AI,
save compatibility, production policy changes, headless FPS claims, and merging PR #59.

## Plan

Add an opt-in frame completion callback, a public-service fixture, a bounded client
observer and a stdlib Python runner. Use default four-chunk/two-millisecond preparation
versus unlimited preparation. Save raw per-frame/per-event CSV, summaries and repeated
comparisons. Verify fixture validity, scheduling, measurement bookkeeping and automation
validation, then run sequential ReleaseFast A/B measurements on the local GPU.

## Tasks

- [x] T1: Add opt-in loop, submit and present host timings (R5, AC1).
- [x] T2: Add certified public-service construction fixture and wall-time arrivals (AC2).
- [x] T3: Integrate CLI, warmup, camera paths, per-representation tracking and reports (AC4).
- [x] T4: Add alternating automation and validation tests (AC3, AC5).
- [x] T-val: Verify automatic runs and publish raw results with practical limits.

Debug passed 50/50 build steps and 2,048 tests with one existing skip; ReleaseFast
install/test passed 58/58 steps and 2,041 tests with eight existing skips. Python
runner tests pass. After an excluded locked-desktop smoke failure, the unlocked
smoke and all 12 default windowed A/B runs succeeded on 2026-11-14. Every measured
run accepted 4,096 commands, resolved both representations and matched checksum
`5f17fb35aea0ce85` at 1920×1080. All frame/event statistics were independently
recomputed from raw CSVs. This verifies AC2–AC4, including travel handoffs.

The [windowed report](../../docs/validation/client-construction-visuals.md) records
lower preparation spikes but no demonstrated whole-client pacing benefit, alongside
increased submission latency. These observations do not establish maximum simulation
throughput or physical display latency; they do not authorize merging PR #59.
