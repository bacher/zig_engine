---
service: zig_engine
created: 2026-10-13
---

# Add country roads and persistent slopes

## Intent
Add solid and adaptive country road blocks. Supported straight runs become walkable slopes and retain their orientation until a member or endpoint is removed.

## Context
Chunks store byte-sized block types, sparse construction metadata, and separate exposed-face meshes. The world-data service owns revisions and sends atomic response packages; the client previews and replays optimistic edits. Player collision currently uses full cubes.

## Requirements
- R1: Keys 7 and 8 select solid and adaptive country road blocks, using temporary atlas textures.
- R2: Solid roads are ordinary cubes. Adaptive roads and slope sections occupy cells encoded as 255, with their state in sparse chunk metadata, and render individually after ordinary geometry.
- R3: Custom blocks never occlude ordinary neighboring faces, including boundary masks and enclosure flags.
- R4: An unformed adaptive road has full-cube player collision despite its temporary custom geometry.
- R5: A straight same-level run of N adaptive blocks, 4 <= N <= 12, between a solid road at that level and a solid road one level below forms an N:1 slope in any horizontal cardinal direction, including across chunk boundaries.
- R6: Formation snapshots orientation, endpoints, length, and section index. Existing sections cannot be claimed by a crossing. Ambiguous unformed intersections remain unformed.
- R7: Removing either endpoint or any section reverts surviving sections of that run to unformed adaptive roads; the removed cell remains empty.
- R8: Every road block needs occupied solid support directly underneath. Roads have no additional foundation or span restrictions. Removing required support is rejected.
- R9: Grounded walking follows slopes continuously in both directions without jumping or climbing. Collision still handles walls, ceilings, jumping, falling, and player placement overlap.
- R10: Metadata survives authoritative snapshots and subscription eviction; cross-chunk changes are delivered and applied consistently.

## Clarifications
- Q1: How long may a run be? A1: 4 <= N <= 12 adaptive sections, with exactly one block of elevation change. The upper bound keeps dependencies inside the loaded 3x3x3 chunk neighborhood.
- Q2: Which shapes are supported? A2: Straight cardinal runs; parallel lanes form wider roads. Ambiguous junctions remain unformed.
- Q3: What removal invalidates a slope? A3: Either solid endpoint or any adaptive member, not unrelated lateral neighbors.
- Q4: What support is required? A4: A solid occupied cell directly underneath each road block; no other construction constraints. Existing cube-colliding materials count as support; custom roads can support only when unformed and full-cube.
- Q5: What happens at an existing crossing? A5: Formed sections retain their saved orientation and cannot be reassigned until their run is invalidated.

## Acceptance Criteria
- AC1: GIVEN putting mode WHEN 7 or 8 is pressed THEN the respective road material is selected and held-item display updates.
- AC2: GIVEN a supported cardinal run with 4 <= N <= 12 WHEN the last needed block is placed THEN every section has persistent slope metadata and joins both endpoint heights continuously.
- AC3: GIVEN a short, overlong, incomplete, unsupported, or ambiguous run WHEN evaluated THEN adaptive members remain full-cube unformed blocks.
- AC4: GIVEN a formed run WHEN a crossing is added THEN existing orientation and ownership remain unchanged.
- AC5: GIVEN a formed run WHEN an endpoint or member is removed THEN all surviving members revert and the removed cell stays empty.
- AC6: GIVEN a custom block next to an ordinary cube WHEN mesh and boundary masks are built THEN the cube's adjacent face remains visible and no custom cube faces are emitted.
- AC7: GIVEN a road block WHEN placement lacks direct support or required support is removed THEN the edit is rejected with shared client/service diagnostics.
- AC8: GIVEN a supported slope WHEN a grounded player walks uphill, downhill, or diagonally across its sections THEN feet follow the surface without climbing, penetration, or loss of contact.
- AC9: GIVEN a run crossing a chunk boundary or the wrapped x seam WHEN it forms, reverts, or reloads THEN metadata, meshes, and collision agree across all affected chunks.
- AC10: GIVEN custom geometry WHEN visible and shadow pipelines are exercised THEN it renders with scene depth, lighting, atlas UVs, and shadows.

## Constraints
Preserve byte block storage and the existing ordinary voxel face layout. Keep metadata sparse, update revisions for metadata changes, and avoid global chunk scans for routine edits. Missing streamed cells are unknown, never air. Custom geometry participates in the normal scene depth and post-processing.

## Out of Scope
Speed boosts, additional road materials, diagonal roads, curves, junction geometry, texture artwork, inventory, and disk persistence.

## Plan
Use a shared custom-block shape descriptor in the engine and sparse road records in application chunk metadata. Share a road formation/reversion helper between client and service. Persist slope descriptors instead of recomputing the chosen axis at render time. Include custom draw descriptors in both local and service mesh payloads. Extend collision with convex slope volumes and grounded surface following; retain cube collision for unformed adaptive roads. Add support checks to the shared validator.

### Affected Components
- `src/engine/voxel/` and rendering pipelines: custom shape descriptors and instanced draws in a separate pass.
- `src/voxel_app/world*`, chunk metadata, and block rules: storage, revisions, support, and persistent run updates.
- `src/voxel_app/terrain_collision.zig`, player controller, and targeting: shape-aware queries and walking.
- `src/voxel_app/main.zig`: key bindings, held items, and streamed geometry updates.

### Data Model Changes
Reserve block value 255 for custom blocks; add country road material selections and sparse road descriptors keyed by local block index. A formed descriptor stores high endpoint, downhill direction, run length, and section index.

### API Changes
Chunk mesh payloads also carry custom block draw records; shared shape queries distinguish occupied, occluding, and colliding cells.

### Risks
Optimistic replay and cross-chunk formation must not restore stale slope ownership. Shape collision must preserve fast sweeps, seam wrapping, and ordinary cube behavior. Reversion while a player occupies a newly restored cube uses existing player recovery.

## Tasks
- [x] T1: Add custom shape storage and persistent road formation/reversion.
- [x] T2: Integrate support validation, service revisions, and client reconciliation.
- [x] T3: Add custom geometry rendering, meshing exclusions, and road selection.
- [x] T4: Add shape collision, surface following, and targeting.
- [x] T5: Document road behavior and complete regression coverage.
- [x] T-val: Run acceptance criteria verification, CPU tests, build, and GPU pipeline checks.

### Validation

`zig build test test-gpu install --summary all` completed successfully: 54/54 build steps,
529 tests passed and 1 skipped. Both applications built. GPU checks passed on Apple M4 Max
with Metal for both compiled wrapping configurations. Modified Zig sources were formatted,
and `git diff --check` passed.

| Criterion | Status | Evidence |
| --- | --- | --- |
| AC1 | Passed | The tool-shortcut regression in `src/voxel_app/main.zig` verifies keys 7/8 select the two road materials. Source review and application builds cover the held-item display using the selected material. |
| AC2 | Passed | `src/voxel_app/road_tests.zig` verifies saved direction, custom cell encoding, and continuous section heights for lengths 4, 7, and 12 in all cardinal directions. |
| AC3 | Passed | Road regressions reject lengths 3/13 and unsupported placement, preserve ambiguous crossings, check incomplete-run rollback, and verify full-cube unformed collision. |
| AC4 | Passed | Crossing regressions verify existing and pending snapshotted ownership survives perpendicular construction, unrelated removal, and snapshot rebasing; newer authoritative ownership takes precedence. |
| AC5 | Passed | The removal regression verifies both endpoints and first, interior, and last members revert surviving sections across chunk boundaries while keeping the removed cell empty. |
| AC6 | Passed | The custom-cell mesh regression verifies separate draw records, no ordinary custom faces, and an exposed ordinary face across a chunk boundary; boundary-mask and enclosure checks also pass. |
| AC7 | Passed | Direct-support regressions verify rejected placement and support removal with shared diagnostics; client/service validation checks pass. |
| AC8 | Passed | Player regressions cover uphill/downhill travel in every direction, diagonal parallel lanes, continuous contact, jumping, fast falls, standing-space searches, ceiling clearance, and a clear uphill ceiling exit with a clipped lift. |
| AC9 | Passed | Road snapshot/replay and rejected-edit regressions verify cross-chunk and wrapped-seam metadata, duplicate placement/removal rejection after newer snapshots, coherent pending formation, and preservation of later pending edits. The service regression verifies atomic formation/reversion and custom mesh reload after subscription eviction. |
| AC10 | Passed | Dawn validates visible and shadow pipelines. Production GPU geometry readback verifies every section of lengths 4/7/12 in all directions, including zero-height ends, normals, actual atlas UVs, and the unformed marker; source review covers atlas, scene depth, lighting, and shadow draw integration. |

Validation is automated and supplemented by source review. No interactive gameplay smoke
test or rendered-image comparison was performed.

### Refinement decisions

| Improvement | Decision and rationale |
| --- | --- |
| Custom-buffer work | Implemented: ordinary-only chunk changes no longer dirty custom data. Per-chunk upload ranges remain deferred until profiling justifies their allocation/bookkeeping cost. |
| Custom draw batching | Implemented: one instanced draw per pass reduces submission from 4N calls to four across the forward pass and three shadow cascades. Each block retains its own descriptor and geometry outside ordinary chunk meshes. No end-to-end frame-time claim is made. |
| Collision metadata lookup | Implemented: read material and optional shape together, scanning sparse metadata only for custom cells. A block-index map remains deferred until dense-road profiling demonstrates a need. |
| Footprint surface calculation | Implemented: standing-space and player collision share the clamped-footprint height helper. |
| GPU evidence | Expanded geometry/normal/UV checks to every section of 4/7/12 runs in every direction. A full forward/shadow raster harness remains deferred because it needs new scene, texture, lighting, and image-readback fixtures. |
| Consistency | Implemented: document eight specialized pipelines and use the GPU_ payload prefix in shader readback. |

The snapshot fixes rebase only pending edits and the road sections they changed. Saved
pending formations retain their chosen direction, with bounded endpoint/member/support
checks before replay; a newer authoritative owner wins. There is no global world scan or
full-chunk baseline copy. The ceiling fix reuses the existing lift, sweep, and settle queries.
