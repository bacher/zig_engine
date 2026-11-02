# Blueprint implementation validation

This report accompanies the implementation of [the blueprint specification](../specs/features/blueprints.md). Capture and application are implemented; planning, rewards, sharing, NPC logistics, and applied-site cancellation remain outside this iteration.

## Implemented paths

- Client selection uses three fresh presses, a fixed XY plane outside the anchor-height camera slab and physical-hit adjacent-cell targeting inside that slab, then a frozen exact-contact/yaw vertical plane with relative height. The fallback skips miniatures and uses the 30-metre raw-contact range from current player feet rather than ordinary four-metre reach. Both paths preserve shortest wrapped X intervals and the world-dependent horizontal cap. Full-block source subscriptions are retained only through the single predicted-view copy. One reusable helper validates detached contents; cancellation generations prevent stale results from owning newer UI.
- The compiler normalizes materials, compacts the definition, applies only the narrowly eligible concrete-support cascade, and checks ordinary validity and cheap-rule assemblability. Successful cache entries no longer retain full failure diagnostics.
- Application copies versioned destination dependencies in bounded service turns, validates/prepares indexes on a helper, and publishes only after dependency/overlay checks. Occupied targets, inadequate real platforms, overlapping active boxes, and incompatible completed-world composition are rejected atomically.
- Dedicated client and authority fulfillment reads at most five physical support cells. It does not call ordinary structural/dependent validation or road planning. Target removal, bit/counter updates, and known-empty construction insertion are incremental; completion does not scan the site.
- Ordinary edits protect real and indexed planned dependents in the completed logical world. Adaptive-road effects from fills use a bounded coalesced queue and independently validated final shapes. Final saving drains this derived queue.
- Definitions, site progress, terrain, and inventory share world transactions. A fulfillment journal record is 13 bytes; progress does not clone the definition or full bitmap per fill. Authoritative acknowledgments remain individual while block snapshots coalesce within each service batch.
- Save supports explicit idempotency keys for the lifetime of a client endpoint. Identical retries return the same definition ID; conflicting payloads/owners are rejected. Automatic fresh saves have a separate key namespace. No reconnect or cross-session request-key protocol is part of this iteration.

## Budgets

These are technical budgets rather than additional material/geometry rules. Resource exhaustion rejects or defers before partial publication.

| Resource | Initial bound |
| --- | --- |
| Selected raw volume, including air | Configurable `Budgets.max_cells`, default 1,048,576; user approved |
| Retained full-block source chunks | Configurable capture budget, default 256 |
| Capture helper concurrency | One reusable worker, one input/result slot |
| Compiler/admission validator cache | 8,192 compact entries plus bounded failure records |
| Application dependency snapshot | 1,024 chunks, 128 MiB conservatively estimated owned data |
| Service snapshot copy slice | Four chunks per turn |
| Concurrent application preparation | One service task, at most eight retiring tasks |
| Deferred road seeds | 4,096 deduplicated chunk entries, one road seed per turn |
| Library/active-instance wire budgets | 4,096 definitions, 4,096 instances, 64 MiB durable state |
| Pending blueprint journal | 16 MiB, at most 1,048,576 operations; backpressure drains earlier accepted work |
| GPU instances | Lazy growth from 1,024 to 1,100,000, 48 bytes each; visible-chunk collection |

The independent horizontal limit remains `min(world_block_size_x / 2 - 1, world_block_size_y)` for each horizontal dimension. The 100×100×32 reference scenario fits the volume/source/snapshot budgets where world dimensions permit it.

## Automated coverage

Focused targets cover compiler normalization and cascades, 20/21-level diagnostics, allocation failures and cancellation, exact-hit selection geometry and wrapped images, names, physical support-read bounds, destination composition, target identity, optimistic reconciliation, package preflight, ownership, inventory atomicity, transactions, restart, save fences, and delayed road validation.

Executed successfully during implementation:

- `zig build test-blueprint`, `test-blueprint-ui`, and `test-blueprint-admission`.
- `zig build test-world`, `test-blueprint-service`, `test-capture`, and `test-persistence`.
- `zig build` and `zig build test-gpu`; GPU tests exercise the instanced shader in wrapping and nonwrapping modes.

Final-source ReleaseFast verification passed **70/70 build steps and 1,799 tests**, with eight existing tests skipped:

```sh
zig build install test test-blueprint-ui test-blueprint-admission \
  test-capture test-persistence test-gpu -Doptimize=ReleaseFast --summary all
```

This includes the AC52 replay/conflict/ownership tests, cross-site completion-order regression, quick-input edges, pending-target preview identity, application save fences, and GPU shader tests. The service target passed 423 tests, the capture/helper target 66, admission 61, storage lifecycle 60, and GPU targets 47 each. Counts include tests imported into more than one runner. `zig fmt` and `git diff --check` also pass. Automated successes do not claim every manual acceptance scenario has been exercised.

The same-height XY fallback and relative-height update add regression cases under AC96–AC101 for camera-slab boundaries, adjacent placement cells versus backing blocks/contact flooring, miniature exclusion, extended reach and raw-contact range, relative Z changes, seam images, and invalid-hit recovery. `zig build install test test-blueprint-ui -Doptimize=ReleaseFast --summary all` passed 58/58 steps and 1,621 tests, with eight existing skips. This includes an application-level distant-target-to-height transition and valid relative heights whose raw plane contact lies beyond the world's Z bounds. The recorded manual walkthrough predates this update and does not verify it.

## Measurements

See [the detailed benchmark report](validation/blueprints.md) for compiler/admission timings, allocation measurements, workload construction, and exclusions. Requested allocations exclude backing allocator pages and GPU/driver memory. Detached compiler/admission measurements exclude source streaming, rendering, meshing, and storage latency; they are not end-to-end frame timings.

The service tests verify coalescing and compact journal size separately from the support-read bound. Terrain meshing, ordinary metadata growth, snapshot delivery at batch boundaries, and persistence still have costs; the five-cell promise applies to structural fulfillment approval.

## Interactive checks

The application launched on Metal and displayed the capture HUD, empty hands, a correctly depth-tested striped frame, and the anchor → XY → height transitions. Moving backward extended the frozen height-plane selection downward. This uncovered a dropped quick-key edge, which is fixed and covered by a regression. The disposable camera-pitch adjustment used for the walkthrough was removed from the source.

After an interruption from macOS screen locking, the walkthrough completed: B opened name entry without toggling blur, empty-name Enter displayed an error, a Unicode name saved successfully, Z exited capture, and F displayed the saved name. Selection opened a textured full-size dirt preview with rails; E applied it, closed the tool, and displayed a centered quarter-size dirt miniature with a world-anchored frame. R produced no error, although the one-cell fixture cannot visually demonstrate rotation. Geometry tests cover the quarter-turn transform and four-turn identity.

The disposable pitched walkthrough binary includes the quick-input fix but predates the final pending-target preview-identity correction and Save ledger. Those final-source changes passed the aggregate automated run above. The walkthrough covers a small site; maximum-site GPU/frame performance, every manual acceptance scenario, and physical power-cut behavior remain unmeasured.

## Compatibility

The world format writes version 3 and requires minimum readable version 3. Earlier development saves are rejected. No migration or historical gameplay-rules dispatch is implemented; see [save compatibility](persistence.md#save-compatibility).
