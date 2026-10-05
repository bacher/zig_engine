# zig-engine

## Build and Run

```shell
zig build run
```

## Voxel app

Run `zig build run_voxel`. Press `Z` to drop a dirt block under the camera and `X` to remove the top block below it.

The world-data service owns block contents and revisions. Each worker uses its own client endpoint to submit one `put` or `remove` operation with global block coordinates. A put fails if the block is occupied; a remove fails if it is already empty. The main thread applies edits optimistically and replays outstanding commands over received snapshots to reconcile failures and concurrent changes. The column tools search at most 20 blocks below the camera and do nothing when no supporting surface is in range.

The camera requests the nearest 3×3×3 chunks as blocks and the surrounding chunks within a 7×7×7 box as meshes. A load subscribes to that representation until eviction or a mode change. Fresh subscription tokens reject obsolete replies, including replies from an earlier mode. Mesh responses carry both `chunk_revision` (blocks and flags) and `mesh_revision` (all meshing inputs). Block responses include the current mesh revision so promotion can reuse matching authoritative GPU geometry when no local edits affect its inputs.

Both representations use the same face extractor with neighbor boundary masks. Each mask holds one occlusion bit per boundary block: 128 bytes per plane, 768 bytes for all six neighbors. Block subscriptions receive those planes with their initial snapshot and receive coalesced updates when neighboring boundary occupancy changes, even outside the subscribed box. Local meshes prefer cached masks from loaded block-mode neighbors, including optimistic edits, and use the authoritative planes for other neighbors. Blocks retained during a neighbor's demotion cannot override newer planes. Missing planes temporarily expose faces. Only x wraps, while faces beyond the y/z world edges remain exposed. A zero-face mesh still has a live subscription and can represent solid blocks.

Each block chunk caches its own six masks, updating at most three bits per edit; solid-face flags also use these masks. The service keeps a bounded cache of generated masks to reuse across mesh builds and block subscribers. Masks stay on the CPU. Outward faces are emitted wherever the neighbor is air, so geometry no longer depends on the camera's position within the core and is shared by the visible and shadow passes. Voxel shadows draw all six face directions from the resident meshes.

Successful edits invalidate their own mesh and, for boundary edits, the touched face neighbors. The service coalesces those mesh builds within each request batch, shares the result across subscribers, and sends related block snapshots, boundary masks, meshes, and acknowledgments in one indivisible package per client. Neighbor-only mask updates carry the receiving chunk's mesh revision and subscription token; unchanged block arrays are not resent unless the update also reveals the chunk and changes its unreachable flag. The main thread retains every accepted mask update but rebuilds only when changed occupancy affects one of its solid boundary blocks; planes overridden by a loaded optimistic neighbor do not trigger a rebuild. It retires acknowledgments, applies the entire package, then rebuilds local meshes once before uploading. Distant initial mesh loads run one at a time between request batches so edits and block loads take priority. Terrain column generation uses a bounded height cache; full neighbor blocks and service mesh arrays are temporary.

The 27-chunk block count is a steady-state target. Blocks, masks, and the existing display remain available during a demotion until its mesh or unreachable status arrives; outstanding edits pin their chunks and affected face neighbors until reconciliation completes. A promotion retains its previous display until blocks and neighbor masks arrive, reusing it when both revisions match. Received face arrays transfer into the GPU upload queue and are freed after upload, leaving only mesh revision metadata for mesh-mode chunks on the main thread.

The GPU face buffer remains 4 MiB. Upload preflight simulates the actual slot allocator, including rounding and fragmentation. Capacity pressure reduces the outer box to 5×5×5. If even that cannot fit (including a mesh exceeding the existing per-chunk allocation limit), uploads remain pending and a diagnostic is printed; buffer expansion is not implemented.

An **unreachable chunk** is enclosed by fully solid adjacent faces of its six neighbors. Generation certifies enclosure using the heightmap plus a one-block strip beyond each horizontal face. Outer y/z boundary chunks remain reachable. This optimization assumes generated terrain has no caves or transparent blocks; a noclip camera inside an enclosed chunk would need a rendering exception. Opening a neighboring wall reveals the chunk immediately in the local cache and authoritatively in the service. Reveals are permanent even if walls are rebuilt, advance the chunk revision, and notify subscribers in their requested representation.

Unreachable chunks in mesh mode receive only status and revision metadata, with no mesh payload or GPU upload. Their subscriptions remain active and receive meshes when revealed. In block mode, unreachable chunks still receive their full block data and skip rendering.

Modified blocks, reveal flags, and mesh invalidation revisions survive subscription eviction in service memory. Disk persistence is not implemented. Stop all client workers before destroying the service, which drains submitted edits and frees its endpoint queues.

A simulation worker places a dirt block at the surface midpoint of the central chunk column, removes it after two seconds, and places it again two seconds later. It communicates only with the world-data service, so the main thread receives these changes through the same subscription mechanism.

Run `zig build test` for the protocol, cache reconciliation, and simulation tests.

## Large-world rendering

Meshes (including skinned models and billboards), primitives, window boxes, height-map terrain, and debug wireframes render relative to the camera chunk. Instance buffers contain a chunk-local model matrix and integer chunk coordinates. The chunk delta is computed before conversion to meters; x wrapping matches the voxel world. Skyboxes continue to use camera rotation only.

Directional shadow cascades are fitted from the camera's chunk-local frustum and share its origin. Shadow casting and sampling use this same frame for meshes, primitives, window boxes, terrain, and resident voxel meshes. Terrain and voxel shadow passes share geometry generation with their visible passes. Shadows can only include voxel chunks currently loaded on the GPU.

Scenes temporarily use `naive_space_tree.zig`, an ArrayList-backed visibility index that returns every registered object for camera and shadow queries. It has no world bounds and performs no spatial culling, so large scenes will submit more draw calls. The original SpaceTree is retained for future work.

CPU positions and group transforms still use `f32`. Chunk-relative rendering preserves vertex precision but cannot recover precision already lost while storing or composing absolute CPU positions. `zig build test` includes regressions for distant translations, negative boundaries, x wrapping, cascade consistency, and the unbounded visibility index.

## Versions

### v0.0.3

* Billboard render mode added

![v0.0.3](screenshots/2026-04-09.png)

### v0.0.2

* Cascade shadow maps added

![v0.0.2](screenshots/2026-03-22.png)

### v0.0.1

![v0.0.1](screenshots/2025-06-05.jpg)

### v0.0.0

![v0.0.0](screenshots/2025-06-04.jpg)

## Funny glitches

![matrix glitch](screenshots/zig-engine-glitch.gif)
