---
service: zig_engine
created: 2026-11-05
---

# Persist unfinished world work

## Intent

Save a world's unfinished simulation work so saving does not wait for all derived road
updates to finish. A reopened world resumes the outstanding reconciliation against its
current saved state, preserving road ownership and ordinary save consistency.

## Context

Blueprint fulfillment commits material, inventory, and progress together, then coalesces
road-shape reconciliation by chunk. The current road queue has 4,096 entries, volatile
cursors and revision observations, fair repeat passes, and a 16-work-unit service budget.
Saves currently require this entire queue to drain, holding later mutations once the
selected command prefix is ready. Persisted chunks already include formed road state and
ownership; the missing state is the obligation to revisit unfinished chunks.

This feature replaces that global road-drain requirement, including blueprint AC114's
capture barrier. It retains resolved-command prefixes, source ownership, bounded capture,
and normal dependency/read/compaction conditions. Earlier road-drain validation reports
remain historical evidence for the implementation they measured.

## Requirements

- R1: Represent outstanding world work with a finite typed key, initially
  `Key{ kind: Kind.road_shape, chunk_id: u32 }`. A key records an obligation to reconcile
  a chunk, without recording individual historical commands or arbitrary job payloads.
- R2: Keep the existing road queue as the authoritative membership owner. Deduplicate
  keys, retain the 4,096-entry limit and producer backpressure, and track membership
  changes with a membership generation rather than maintaining a second generic live map.
- R3: Capture the complete outstanding key set once for each save, in canonical order,
  with a bound of 4,096 keys and a five-byte wire representation per key. Include it in
  the same committed world state as chunks, players, blueprint progress, and global state.
- R4: Reserve capacity before accepting a mutation that creates an obligation. Publish
  its world effects and mark together, so neither admission failure nor recovery can
  expose accepted effects without the required outstanding work.
- R5: Retire a key only after its current reconciliation pass and any coalesced repeat
  are complete. Persist completed world effects and key removal atomically; a save that
  retains the key may retain partial, already committed reconciliation effects as well.
- R6: Persist formed road state and ownership in chunks as today. Discard runtime cursor,
  observed revision, and dirty-repeat bookkeeping on restart; restore each saved key at
  the beginning of a new pass against the current world.
- R7: Repeated reconciliation must preserve valid saved ownership and current materials.
  It must safely revisit previously processed cells and observe edits accepted while work
  was delayed, rather than replaying historical effects or choosing a new owner blindly.
- R8: Ordinary, autosave, overdue, final, and internal journal-prefix saves must not require
  the global road queue to become empty or hold later mutations solely to drain it. Preserve
  the selected resolved-command prefix and all existing source-hold and capture gates.
- R9: Restore outstanding keys before the service can capture a save or advertise ready
  operation. Populate scheduling directly from the saved key set; load chunks and their
  dependencies as required without scanning or preloading the whole world.
- R10: Preserve the road scheduler's 16-work-unit default, counting seeds and entry
  completion/requeue. Preserve fair tail requeue, bounded repeat state, dependency/source
  wait yielding, publication atomicity, and existing read/failure/backpressure behavior.
- R11: Mark-only and clear-only changes must make the world unsaved even when no chunk
  material or shape changes. A successful older save must not acknowledge newer membership
  changes as saved, and failed or canceled saves must not lose outstanding work.
- R12: Advance the world writer and minimum readable version together. Reject earlier
  development worlds, unknown work kinds, malformed keys, duplicates, out-of-order keys,
  out-of-world chunk IDs, and excessive counts through the normal persistence errors.
- R13: Keep the common mechanism small and reusable by future typed subsystems. Optimize
  for simulation throughput: constant bounded per-fill marking, no full-set sorting or
  copying per fill, and no extra broad road validation or per-world scan.

- R14: A queued chunk may unload and reload without a revision change, while serialization
  reorders sparse road metadata. Reset its runtime pass cursor, revision observation, and
  repeat bookkeeping on loaded-chunk installation so reconciliation revisits every seed.
  Do not retain all queued chunks in memory merely to preserve cursor validity.

## Clarifications

- Q1: Is this a durable generic job queue?
  A1: No. It is a finite set of typed reconciliation obligations; only road shape work is
  implemented. Each future subsystem defines its own state, progress semantics, and handler.
- Q2: Which progress is saved?
  A2: Current world state, saved road ownership, and outstanding keys. Runtime iteration
  state is deliberately restarted; reconciliation uses the current world repeatedly.
- Q3: Must a final save finish roads before exiting?
  A3: No. Final saves commit unfinished keys with the world and retain normal final-save
  command/read/compaction and source-ownership conditions.
- Q4: How are capture cost and membership tracked?
  A4: The queue owns live membership and its membership generation. Each save takes one
  canonical complete snapshot, bounded to 4,096 keys of five wire bytes each.
- Q5: Are existing development saves migrated?
  A5: No. Bump the writer and minimum readable versions together; reject older formats.

## Acceptance Criteria

- AC1: GIVEN an accepted fulfillment that requires road reconciliation WHEN a save commits
  before the queue drains and volatile state is discarded THEN a fresh service restores
  both fulfillment effects and the outstanding key and eventually produces the valid slope.
- AC2: GIVEN a road mutation whose mark reservation cannot succeed WHEN it is attempted
  THEN material, inventory, progress, and outstanding membership remain unchanged.
- AC3: GIVEN partially processed road work WHEN saving and reopening THEN formed state and
  ownership survive, the key restarts at cursor zero, and repeated reconciliation converges
  without undoing current edits or reassigning a valid saved crossing owner.
- AC4: GIVEN a current pass made dirty again by accepted edits WHEN saving before its repeat
  completes THEN the saved key survives and a reopened service revisits the complete chunk.
- AC5: GIVEN a completed reconciliation and key retirement WHEN recovering a committed
  transaction or its prior durable prefix THEN the world contains either the committed
  result with its key cleared or the earlier state with its outstanding key retained.
- AC6: GIVEN pending road work WHEN ordinary, overdue, final, or internal-prefix capture
  becomes otherwise ready THEN capture starts with the saved key set without waiting for
  global road completion or applying the former road-drain-only mutation hold.
- AC7: GIVEN capture-held sources or unresolved commands within a selected save prefix WHEN
  road work or capture attempts to proceed THEN ordinary source protection and command
  ordering still prevent inconsistent mutation or premature prefix completion.
- AC8: GIVEN a world with sparse saved work keys and unloaded chunks WHEN reopening THEN
  scheduling comes from those keys, dependency loads remain demand driven, and unrelated
  world chunks are neither scanned nor preloaded.
- AC9: GIVEN busy and quiet queued chunks, full/wrapped queue slots, or a blocked dependency
  WHEN processing road turns THEN the 16-unit budget, fair repeat passes, deduplication,
  capacity bound, and yield/resume behavior remain effective without dropping keys.
- AC10: GIVEN a mark or clear with no shape change, or newer membership changes during an
  older save WHEN the save completes, fails, or is canceled THEN unsaved generation tracking
  reflects only the membership actually committed and all remaining work can be saved again.
- AC11: GIVEN valid and malformed persisted work sets WHEN encoding, decoding, or replaying
  base/WAL state THEN valid sets roundtrip canonically and invalid kinds, keys, counts,
  ordering, duplication, and unsupported world versions fail before service publication.
- AC12: GIVEN the representative dense/spread blueprint road workload WHEN comparing the
  implementation with the previous bounded road scheduler THEN fulfillment keeps its five
  physical-support-read bound and zero ordinary-validation calls, save admission no longer
  waits for the road drain, and measured throughput/capacity results are documented.
- AC13: GIVEN an in-progress road pass and same-revision metadata reordering after chunk
  unload/reload WHEN the loaded chunk is installed THEN the runtime pass restarts completely,
  preserves valid saved ownership, and visits all remaining seeds without pinning all queued
  chunks in memory.

## Constraints

Preserve whole-operation atomicity, compatible current-world road rules, save-prefix order,
exact-version source ownership, bounded capture memory, and explicit persistence failures.
Use the existing queue and persistence pipeline rather than a second scheduler or live
membership index. The bounded canonical set is copied once per capture. Saving may still
wait on admitted commands, required reads, compaction, and frozen sources for their existing
reasons. Offline time and historical replay policy do not change.

## Out of Scope

NPC or economy implementation, actor-state serialization, arbitrary durable task payloads,
historical event replay, new scheduling policies, road gameplay/rule changes, save migration,
global resource budgeting, per-frame guarantees, and project-values documentation.

## Plan

### Approach

Add a small shared typed-key codec and canonical bounded saved set. Let the road queue expose
its membership and generation, while retaining cursors and repeat state only at runtime.
Capture the set with the world and restore it before service readiness. Remove the former
global road-empty capture condition and its road-drain-only admission machinery. Continue
ordinary bounded reconciliation under existing source and dependency gates.

### Affected Components

- `src/voxel_app/deferred_world_work.zig`: finite kinds, keys, canonical validation and codec.
- `src/voxel_app/blueprint_road_updates.zig`: authoritative membership, generation, snapshot
  and restoration, preserving the existing scheduler.
- `src/voxel_app/world_data_service.zig` and `persistence/save_lifecycle.zig`: capture state,
  dirty tracking, startup restoration, and removal of the road-drain barrier.
- `src/voxel_app/persistence/`: global/base/WAL/capture ownership and format-version change.
- Feature, format, architecture, and persistence/blueprint validation docs: current contract
  and test evidence, preserving historical measurements with explicit scope.

### Data Model Changes

Persist a bounded canonical full set of `(kind: u8, chunk_id: u32)` keys in every committed
world-state capture. Initially the sole kind is road shape reconciliation. Runtime queue
entries retain their current per-pass state, but only membership is serialized.

### API Changes

Expose queue membership/generation snapshots and restore saved road keys into fresh runtime
entries. Extend the existing persistence capture/global state APIs with owned typed-key state;
retain the existing public save and world-mutation APIs.

### Risks

Clearing a key without recording global dirty progress can resurrect or lose work after
restart. Capturing a live slice instead of an owned snapshot can mix generations. Partial
road processing must be safe to repeat; saved ownership and newer edits constrain each pass.
Removal of the old barrier must not weaken source-hold, read-failure, or save-prefix behavior.

## Tasks

### Phase 1 — Durable representation

- [x] T1: Add the finite work-key schema, canonical bounded codec, and world format bump.
- [x] T2: Carry the full saved set through owned capture, base/WAL recovery, and compaction.
- [x] T3: Add queue membership generations and save/restore APIs without a duplicate live map.

### Phase 2 — Service integration

- [x] T4: Couple accepted effects/marks and completed reconciliation/clears with dirty tracking.
- [x] T5: Restore scheduling before readiness and remove global road-drain-only save holds.
- [x] T6: Preserve source/dependency gates, fair bounded work, and capacity backpressure.

### Validation

- [x] T7: Cover interrupted/repeated work, atomic membership publication, and all save paths
  with real save/reopen and fault-boundary regressions mapped to AC1–AC11 and AC13.
- [x] T8: Run the representative ReleaseFast dense/spread throughput fixture and document
  observed costs, fulfillment read bounds, and save admission behavior for AC12.
- [x] T9: Update current feature/format/runtime docs and identify superseded drain guarantees.
- [x] T-val: Run acceptance criteria verification, appropriate persistence/service/full build
  tests, formatting, and diff checks; record results and remaining limitations.


Final verification passed: `zig build test -Doptimize=Debug --summary all` completed
47/47 steps with 1,768 tests passed and one existing skip; `zig build install test
-Doptimize=ReleaseFast --summary all` completed 55/55 steps with 1,761 tests passed and
eight existing skips. Both applications built. The service component passed 508/508 tests,
world 324/324, and persistence 72/72; separate queue/codec and lifecycle checks each passed
13/13. Formatting and `git diff --check` passed. Source review and regressions cover
background-read isolation/foreground promotion and same-revision metadata reload restart.
AC1–AC13 are verified within the current bounded road implementation; no required checks
remain for this feature.

The [current validation and measurement report](../../docs/blueprints-validation.md#persisted-unfinished-work-verification-and-measurements)
records the comparison with `6c1d74c`; [raw results](../../docs/benchmarks/deferred-world-work-2026-11-05/results.json)
include every warm run, exact invariants, source hashes, and maximum-key snapshot costs.

| Criteria | Verification mapping |
| --- | --- |
| AC1, AC3, AC4 | Service ordinary/final save, loss of all volatile owners, fresh reopen and slope comparison; partially processed formed-history restart, saved cursor/dirty-repeat restart, and road ownership/crossing regressions. |
| AC2 | Service full-queue reservation rejection checks unchanged terrain, inventory, progress, and membership. |
| AC5 | Storage modeled uncertain-commit result/clear atomicity, snapshot-zero/torn replacements, full-set replacement across concurrent compaction. |
| AC6 | Service ordinary/final restart plus internal-prefix/overdue/final capture-start tests with nonempty work. |
| AC7 | Service pending-road player/NPC/timer source-hold regression, foreground/shared-read promotion, and retained lifecycle command/read/compaction gates. |
| AC8 | Queue restoration without world data; service background asynchronous base-read scheduling and foreground promotion. |
| AC9 | Queue full/wrapped/singleton/fair-repeat tests and service 16-unit budget, blocked-source/error, async-read yield/resume tests. |
| AC10 | Service no-op clear dirty state, immutable in-flight capture/new membership, failed/canceled save identity; queue snapshot allocation-failure cleanup. |
| AC11 | Shared codec canonical/bounds/allocation checks, storage checksummed invalid kinds, truncated length/keys, whole-world version gates, and owned capture budget tests. |
| AC12 | Identical dense/spread ReleaseFast fixture, three alternating warm runs per variant; 4,096-key snapshot allocation/timing benchmark. |
| AC13 | Queue loaded-metadata restart and service same-revision unload/reload reordering regression. |
