# Voxel world, streaming, and editing

The voxel application combines deterministic terrain generation with an in-memory authoritative service, a small editable block cache on the main thread, and GPU face geometry for a larger neighborhood. The engine's voxel grid handles upload/residency; it does not own the world's block contents or command protocol.

## Space and contents

Chunks remain fixed at 32 by 32 by 32 blocks. The application chooses world dimensions at scene creation; its current preset is 512 by 256 by 8 chunks: 16384 by 8192 by 256 blocks. Each block occupies one world-coordinate unit. Only x wraps. Positions beyond y/z storage boundaries cannot index terrain; outer faces at those boundaries remain exposed.

World coordinates are centered using the immutable layout's half-dimension `origin_chunk`. With the current preset, world position zero corresponds to stored block coordinates (8192, 4096, 128). Spatial chunk coordinates are signed vectors; normalize x and validate y/z before encoding a storage ID through that world's layout. Its dimension exponents determine the packed ID widths: the current preset uses 9/8/3 bits, or 20 of the available 32 bits. The cache and service retain immutable copies of the scene's validated layout and reject unwrapped x. See [world configuration](world-configuration.md) and [coordinates](coordinates.md).

`WorldChunkData.blocks` is indexed `[z][y][x]` and contains one `BlockType` per block. Types are air (`none`), stone, dirt, grass, water, sand, and snow. Current occupancy tests treat every non-air type as solid; water does not have a separate transparent/fluid occupancy rule.

`WorldChunk` contains block content, solid count, flags, own boundary masks, and authoritative chunk revision. Content is either allocation-free `empty` or a dense block array. A solid chunk still stores individual blocks; there is no separate uniform-solid representation. Removing the final solid block releases the dense allocation.

The six solid-face flags describe whether every block of one of the chunk's own boundary planes is solid. `is_unreachable` instead describes enclosure by neighboring chunks. It is not an empty-content marker.

## Terrain generation

`WorldGenerator` supports a flat world and seeded heightmap terrain. The running voxel app selects terrain with seed 12345. A column generator computes heights for one horizontal chunk column and reuses them across its vertical chunks.

Terrain height combines periodic-x Perlin noise octaves, rounds the result, and clamps it between 1 and the world's block height. X periods use whole numbers of noise cells so both height values and slopes meet at the wrap seam. Default settings use noise scale 192, four octaves, frequency multiplier 2, amplitude multiplier 0.5, base height at half the selected world height (128 with the preset), height amplitude 48, and four dirt blocks below the surface.

The generated column has grass at the surface, dirt immediately below, stone deeper down, and air above. There are no generated caves. Fully above-surface chunks are empty; sufficiently deep chunks use a shortcut to fill stone. The flat generator supplies solid lower chunks and a half-filled surface chunk near the world midpoint.

Generation is deterministic for the same layout, coordinates, seed, and parameters. Untouched chunks can therefore be discarded and regenerated. Committed modifications override generated data.

## Authoritative service and client protocol

`WorldDataService` runs one worker that serializes requests from all clients. Each client endpoint belongs to one producer/consumer thread and has its own request-ID sequence and response mailbox. The main thread and simulation worker use different endpoints.

| Request | Meaning |
| --- | --- |
| Load a column/range in block mode | Subscribe each chunk to full block snapshots and neighbor occupancy planes. |
| Load a column/range in mesh mode | Subscribe each chunk to exposed-face geometry or unreachable status. |
| Evict a chunk with its token | End that subscription only if the supplied token is still current. |
| Submit a block operation | Apply one `put(type)` or `remove` at validated global storage block coordinates. |

A load is a continuing subscription, not just a one-time fetch. Its request ID becomes the subscription token for the requested chunks. Loading a different representation or reloading replaces the token; delayed replies and eviction requests from an older generation must not affect the new subscription.

Commands carry intent, never replacement chunk snapshots. A put succeeds only when the target is air; a remove succeeds only when it is solid. Status is `success`, `already_exists`, or `already_removed`. Each command gets an acknowledgment, including conflicts. Commands from one endpoint preserve submission order; commands from different endpoints are ordered by the shared request queue, without a separate cross-client ordering promise.

The service sends independently owned snapshots/face arrays. Consumers must free rejected or unused payloads. Client endpoints remain owned by the service until it is destroyed. Request/reply mailboxes are unbounded: producers briefly lock to enqueue, but there is no queue-size backpressure policy.

## Revisions and invalidation

| Value | What it identifies |
| --- | --- |
| `subscription_id` | Current request/subscription generation and representation. |
| `chunk_revision` (`u32`) | Authoritative block contents and flags; advances on successful edits and permanent reveals. Optimistic edits do not advance it. |
| `mesh_revision` (`u64`) | Meshing-input invalidation, including neighbor changes. Zero means untouched inputs; later values come from the service's increasing invalidation sequence. |

An interior edit changes its own chunk/mesh. A face/edge/corner edit additionally invalidates the one/two/three touched face neighbors. A neighbor's mesh revision may change without its block contents or chunk revision changing. This is why chunk revision alone cannot certify reusable geometry.

The worker batches currently queued requests, coalesces affected mesh builds, builds once for the relevant final state, and distributes owned copies to mesh subscribers. It sends unchanged blocks again only when needed for a block snapshot, such as a flag-changing reveal; neighbor-only occupancy updates use boundary payloads.

For each client, related snapshots, boundary updates, mesh results, and command acknowledgments are placed in one `ResponsePackage`. Final block snapshots are certified against final neighbor inputs before publication. Render consumers apply whole packages before any local rebuild/upload, so related updates cannot be partly applied across rendered frames. Several packages may be consumed in one frame before the one local rebuild phase.

Initial distant mesh loads are queued. The worker performs at most one between request batches, checking for newly queued edits/block loads again afterward. A mesh build is synchronous on that worker; this is prioritization between builds, not preemption inside a build.

## Optimistic cache and frame reconciliation

`World` on the main thread holds authoritative snapshots with outstanding local operations replayed on top. A locally valid edit changes that cache immediately and appends a pending operation. Conflicting local edits are no-ops. The next world update submits unsubmitted commands in their original order and records request IDs.

The world update sequence is:

1. Submit pending local operations.
2. Refresh camera-driven subscriptions and chunks pinned by pending operations.
3. Take complete response packages.
4. For each package, retire all acknowledged commands first, including failed commands, then accept payloads with current tokens/modes/revisions.
5. Replace accepted block snapshots and replay remaining pending operations over them.
6. Refresh streaming/pinning again after responses.
7. Rebuild dirty local meshes once from the resulting cache and neighbor inputs.
8. Preflight and upload queued face geometry.

A failed operation's snapshot rolls back that edit without losing later pending edits. An acknowledgment remains useful even after the corresponding subscription was evicted: it retires pending work, but its stale payload cannot resurrect the evicted chunk. Older chunk/mesh/boundary revisions are rejected within their relevant cache paths.

This is asynchronous reconciliation. Local cached blocks may temporarily differ from the service because they include pending edits. GPU geometry represents the state available to the last completed upload.

## Streaming and representation handoffs

The normal camera neighborhood uses Chebyshev distance: the largest axis chunk delta, with the shortest wrapped x delta. Chunks at distance at most 1 are requested as blocks (a 3-by-3-by-3 core); distance at most 3 is the total display neighborhood (7 by 7 by 7), with the rest requested as meshes. Neighborhoods are clipped at y/z storage boundaries. Requests proceed from nearest shells outward.

27 block chunks is a steady-state target. Outstanding edits pin the edited chunk and any touched face neighbors in block mode until acknowledgment. Pins can extend beyond the current display box. In-flight representation changes can also retain more CPU blocks temporarily.

For demotion from blocks to mesh, the old blocks, masks, and display remain available until the new mesh/unreachable response arrives. Then the CPU blocks and fallback masks are released. Retained demoted blocks no longer override authoritative neighbor planes because their block subscription has ended.

For promotion from mesh to blocks, the old display remains until blocks and neighbor masks arrive. The application can reuse the authoritative geometry if both revisions match and there are no pending edits affecting its own or neighboring meshing inputs. Otherwise it rebuilds locally. Mesh-mode state on the main thread retains version metadata; received face arrays move directly to the upload queue.

A chunk with zero extracted faces still has a live subscription. It may contain solid blocks, and later edits can expose geometry. Empty chunks, zero-face chunks, and unreachable chunks are different states.

## Neighbor masks and face extraction

The service and local cache use the same face extractor. It walks solid blocks and emits each outward face whose adjacent block is air. Interior neighbors come from the block array; cross-chunk neighbors come from boundary occupancy masks.

A boundary plane has one bit per block, represented as 32 rows of 32 bits: 128 bytes per plane and 768 bytes for six planes. Opposite faces use matching, unmirrored coordinates. Own masks update at most three bits per block edit and also derive the six solid-face flags. Masks stay on the CPU.

Block subscriptions receive authoritative neighbor masks with their initial snapshot and coalesced updates when neighbor boundary occupancy changes, even if the changed neighbor lies outside the client's requested box. For local meshing, a loaded block-mode neighbor's own masks take precedence, including optimistic edits. Other neighbors use the service's fallback masks. Missing dependencies temporarily count as air and expose faces.

Every accepted fallback update is retained, even when it currently changes no geometry. The application rebuilds only if changed occupancy meets a solid boundary block and that plane is not overridden by a loaded optimistic neighbor. This preserves inputs for later placements/handoffs without needless rebuilds.

The extractor does not depend on camera position or merge adjacent faces into larger quads. It emits individual block faces grouped by six directions. The visible pass selects directional subsets; the shadow pass covers all six directions from the same resident records. See [rendering](rendering.md).

## Unreachable chunks

A generated chunk can be marked unreachable when all six neighboring walls enclosing it are fully solid. Terrain certification uses the column heightmap plus a one-block strip beyond each horizontal face. Outer y/z boundary chunks remain reachable, since an enclosing wall is absent; x is periodic.

Unreachable block-mode chunks still receive full blocks but skip rendering. Unreachable mesh-mode chunks receive status and revisions without face arrays/GPU uploads. Both remain subscribed. Opening a neighboring wall reveals the chunk locally immediately and authoritatively when the edit commits, triggering the appropriate payload for each subscriber.

Reveals are permanent: rebuilding the enclosing wall does not set the unreachable flag again. The service increments the revealed chunk's revision and retains that state even if it had not previously been subscribed.

This optimization depends on cave-free, solid generated terrain. It is not general visibility testing. The noclip spectator camera can enter enclosed chunks; rendering from inside them would require an exception or a different policy.

## GPU storage and capacity

`VoxelGrid` owns a face buffer of 4 MiB and a separate chunk-metadata buffer with 4096 slots. Faces use four-byte local-coordinate/type records; chunk metadata uses 112 bytes. GPU vertices are generated from those records in WGSL.

Face allocations use power-of-two multiples of a 1024-byte slot. Sixty-four spans each contain 64 slots; a span uses one allocation size at a time until emptied. The maximum per-chunk allocation is 64 KiB, or 16384 face records. Total free bytes alone do not establish capacity because rounding, size classes, and fragmentation matter.

`hasUploadCapacity` copies both allocator states and simulates the actual queued allocation sequence before any upload writes. The voxel app reduces the outer radius from 3 to 2 (5 by 5 by 5) on capacity pressure. If the remaining batch still cannot fit, it retains pending uploads and prints a diagnostic; it does not partially upload the batch or expand the buffer. Radius is not automatically restored to 3 in the current code. This policy also applies when one chunk exceeds the per-chunk allocation limit.

Replacing/removing a chunk releases its resident slots and frees any superseded queued face arrays. After successful upload, all queued arrays are freed. Zero-face uploads consume no GPU residency slot. Capacity checks do not make arbitrary voxel patterns fit the fixed per-chunk and total limits.

## Persistence, caches, and shutdown

The service retains committed modified chunks, permanent reveal flags, and mesh invalidation revisions independently of subscriptions. Untouched blocks and built meshes are temporary. Generated boundary masks and column heights have bounded caches (512 chunks and 64 columns respectively); these caches are cleared when their thresholds are reached rather than managed as an LRU.

There is no disk persistence. Edits survive client eviction/reloading during one service lifetime and disappear when the application/service is destroyed. Modified-state storage is not bounded by the streaming box.

Stop every client worker before destroying the service. Shutdown closes the request mailbox, drains submitted edits while skipping pending loads, waits for the service worker, and frees endpoints and queued replies. The voxel game's teardown stops the simulation first and submits any remaining local commands before service destruction.

## Tools and simulation example

Z places dirt and X removes the top solid block in the vertical column below the camera. These tools search at most 20 blocks beneath the actual camera position; they are not crosshair raycasts. Placement requires support within reach, except that the world bottom can provide the floor. Unreceived chunks produce no edit, and no support within the bounded search produces no floating placement.

The simulation worker initially loads the central chunk column, finds the surface at its horizontal midpoint, then evicts those subscriptions. It submits one dirt put, waits for the result, and waits two seconds between subsequent operations. A successful put switches the next action to remove; a failed put retries a put. Removal switches back to putting. It communicates only through its own service endpoint, so visible changes arrive on the main thread through ordinary subscriptions. This is a concurrency example, not a broader NPC simulation system.

## Sources and regression coverage

| Source/test file | Behavior to inspect |
| --- | --- |
| [`world.zig`](../src/voxel_app/world.zig) | Contents, edit preconditions, replay/rollback, stale snapshots, column tools, and reveals. |
| [`world_data_service.zig`](../src/voxel_app/world_data_service.zig) | Queue ordering, conflicts, tokens, broadcasts/packages, revisions, masks, eviction, caches, and shutdown. |
| [`main.zig`](../src/voxel_app/main.zig) | Streaming/pinning, handoffs, package application, mesh reuse, mask precedence, bounded tools, and capacity fallback. |
| [`world_generator.zig`](../src/voxel_app/world_generator.zig), [`perlin_noise.zig`](../src/voxel_app/perlin_noise.zig) | Determinism, surface/shortcut consistency, periodic x, and enclosure certification. |
| [`boundary_mask.zig`](../src/voxel_app/boundary_mask.zig), [`world_engine_glue.zig`](../src/voxel_app/world_engine_glue.zig) | Mask coordinates/sizes and cross-chunk face extraction. |
| [`simulation_worker.zig`](../src/voxel_app/simulation_worker.zig) | Surface selection, result-dependent action changes, cancellation, and subscription updates. |
| [`voxel_tests.zig`](../src/engine/voxel_tests.zig), [`voxel_grid.zig`](../src/engine/voxel/voxel_grid.zig), [`voxel/`](../src/engine/voxel) | GPU data preparation, slot allocation/reuse, exact preflight, and fixed limits. |

Run `zig build test` for the root build's registered tests. The descriptions here are based on current implementations and existing regression cases; no new test run was part of this documentation extraction. Runtime-layout regressions additionally cover two differently sized services, periodic terrain, and streaming/edits across each x seam. Rendering appearance requires separate visual validation.
