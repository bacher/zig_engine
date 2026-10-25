# Voxel world, streaming, and editing

The voxel application combines deterministic terrain generation with an in-memory authoritative service, a small editable block cache on the main thread, and GPU face geometry for a larger neighborhood. The engine's voxel grid handles upload/residency; it does not own the world's block contents or command protocol.

## Space and contents

Chunks remain fixed at 32 by 32 by 32 blocks. The application chooses world dimensions at scene creation; its current preset is 2048 by 1024 by 32 chunks: 65536 by 32768 by 1024 blocks. Each block occupies one world-coordinate unit, defined as one metre. X wrapping is always enabled by the application's compile-time engine configuration. Positions beyond y/z storage boundaries cannot index terrain; outer faces at those boundaries remain exposed, and the player treats those edges as collision walls.

World coordinates are centered using the immutable layout's half-dimension `origin_chunk`. With the current preset, world position zero corresponds to stored block coordinates (32768, 16384, 512). Spatial chunk coordinates are signed vectors; normalize x and validate y/z before encoding a storage ID through that world's layout. Its dimension exponents determine the packed ID widths: the current preset uses 11/10/5 bits, or 26 of the available 32 bits. The cache and service retain immutable copies of the scene's validated layout. A compile-time guard rejects an engine configuration with wrapping disabled. See [world configuration](world-configuration.md) and [coordinates](coordinates.md).

`WorldChunkData.blocks` is indexed `[z][y][x]` and contains one `BlockType` per block. Types include air, natural/crushed stone, loose/packed soil, grass-covered packed soil, trunks, foliage, planks, rebar, reinforced concrete, water, sand, snow, metal ore, limestone, clay, coal, and deeprock. Current occupancy tests treat every non-air type as solid; water does not have a separate transparent/fluid occupancy rule. Custom cells use value 255 and sparse metadata; country roads save their formed slope ownership there. Occupancy, face occlusion, and collision are separate: custom cells stay occupied, expose neighboring ordinary faces, and use their recorded collision shape. Sparse construction indices and ordered time events also live in chunk metadata. See [block placement and transformations](block-placement.md).

`WorldChunk` contains block content, solid count, flags, own boundary masks, and authoritative chunk revision. Content is either allocation-free `empty` or a dense block array. A solid chunk still stores individual blocks; there is no separate uniform-solid representation. Removing the final solid block releases the dense allocation.

The six solid-face flags describe whether every block of one of the chunk's own boundary planes is solid. `is_unreachable` instead describes enclosure by neighboring chunks. It is not an empty-content marker.

## Terrain generation

Playable generator ID 2/version 1 has seeded `natural` and `flat` profiles. The voxel app
uses natural seed 12345 by default. Old generator IDs 0 and 1 are rejected on reopen;
`.terrain` remains an isolated fixture for the existing noise regressions.

`WorldDataService.create` prepares immutable world data before starting workers. Preparation
validates configuration, builds a bounded coarse continental map and feature data, selects a
safe temperate start, and prepares finite deposits. Allocation-free climate point and 32×32
map queries share the same periodic field used for generation and rendering. The prepared
generator borrows its layout and is owned by the service; columns and render clients must
not outlive it.

Direct and allocating natural-world preparation use the same settings/memory preflight and
failure reporting before candidate attempts. Chunk filling evaluates deeprock thickness and
the deposit-index candidate slice once per horizontal column, then reuses those inputs for
its vertical cells. These inputs live only during filling; persistent column-cache sizes
are unchanged. The slow point oracle computes its own inputs afresh.

```zig
var prepared = try generator.prepare(allocator, layout);
defer prepared.deinit(allocator);
const column = ColumnGenerator.init(&prepared, .{ chunk_x, chunk_y });
```

Natural worlds have 3–5 connected continents, detached islands, a shared sea level,
cave-free terrain, climate belts, mountain ranges, finite geological deposits, and forests
separated by meadows. The north-to-south belts occupy approximately 10/10/25/10/25/10/10%
of the whole map. Each column has one climate, independent of chunk boundaries. Desert
cover is sand; other covered soil renders green, yellow, or snowy according to climate.
Soil types and timers are saved unchanged. Water and foliage render opaque cubes and retain
full-cube collision.
Land has a soft 35% target: roughly 95% of default-profile seeds within 25–45% is sufficient.
Weighted macro growth stops at a cost horizon, so coherent regional costs can form uneven
lobes and bays without filling to an exact area quota. Only topology and feature validity
cause candidate rejection; land coverage is measured offline and never gates regeneration.
Climate boundaries combine broad periodic bends and smaller irregularities. Their default
amplitude scales with world height (1310 blocks at the default size); centered fields retain
the agreed belt areas. In natural settings, zero `climate_displacement` selects this
automatic amplitude, while nonzero values specify an explicit block amplitude.
Mountain uplift tapers before both displaced frozen boundaries, reaching zero on the
adjoining nonfrozen rows. Classification and uplift use the same climate-boundary sample.

Mainland shore proximity combines a capped distance to conservative coastal rectangles
with a shared bilinear inland field. It crosses internal macro-cell boundaries without
resetting and uses a fixed `3 × 3` record query. The approximation can flatten up to 16
extra blocks beside a shore; islands retain their analytic taper. This coordinate describes
original geography and does not track player edits to water.

Every playable profile has contiguous seeded deeprock from storage z=0 through an irregular
1–3-block thickness. The same pure mask protects prediction, authority, indirect edits,
and lazy saved-chunk restoration. Invalid floor data is rejected rather than regenerated.
Flat profiles skip natural features, use temperate climate and zero polar inset, and retain
a simple dimension-derived surface. Natural worlds reserve the outer two Y chunk rows at
each pole as an invisible player wall. The finite lower-Z collision boundary is independent
of terrain residency.

Untouched chunks are discarded and deterministically regenerated from the compact identity;
only modified chunks need persistence. Generation order, column eviction, and restart do
not advance a shared random stream. See the [generation spec](../specs/features/world-generation.md)
for feature bounds, failure categories, and validation requirements.

## Authoritative service and client protocol

`WorldDataService` runs one worker that serializes requests from all clients. Each client endpoint belongs to one producer/consumer thread and has its own request-ID sequence and response mailbox. The main thread and simulation worker use different endpoints.

| Request | Meaning |
| --- | --- |
| Load a column/range in block mode | Subscribe each chunk to full block snapshots and neighbor occupancy planes. |
| Load a column/range in mesh mode | Subscribe each chunk to exposed-face geometry or unreachable status. |
| Evict a chunk with its token | End that subscription only if the supplied token is still current. |
| Submit a block operation | Apply one `put(type)` or `remove` at validated global storage block coordinates. |

A load is a continuing subscription, not just a one-time fetch. Its request ID becomes the subscription token for the requested chunks. Loading a different representation or reloading replaces the token; delayed replies and eviction requests from an older generation must not affect the new subscription.

Commands carry intent, never replacement chunk snapshots. A put requires air and valid structural support; a remove requires an occupied cell and must preserve constructed blocks' support. Status is `success`, `already_exists`, `already_removed`, `constraint_violation`, or `missing_data`. Results include structured failure diagnostics and the mined material where applicable. Each command gets an acknowledgment, including conflicts. Commands from one endpoint preserve submission order; commands from different endpoints are ordered by the shared request queue, without a separate cross-client ordering promise. Simulation-time advancement shares this queue.

Structural validation reads only the inclusive 28-cell cube around the edited target. Recursive support searches keep that center, and revalidated dependents must also stay within their own 28-cell cubes. Construction indices are collected from at most 27 intersecting chunk IDs in deterministic target-relative order. Support outside the bounds cannot justify approval; edits are rejected conservatively if no remaining route can be proved inside them. This requires no persistent support/dependency metadata. See [placement windows](block-placement.md#fixed-support-window).

The service sends independently owned snapshots/face arrays. Consumers must free rejected or unused payloads. Client endpoints remain owned by the service until it is destroyed. Request/reply mailboxes are unbounded: producers briefly lock to enqueue, but there is no queue-size backpressure policy.

## Revisions and invalidation

| Value | What it identifies |
| --- | --- |
| `subscription_id` | Current request/subscription generation and representation. |
| `chunk_revision` (`u32`) | Authoritative block contents and flags; advances on successful edits and permanent reveals. Optimistic edits do not advance it. |
| `mesh_revision` (`u64`) | Meshing-input invalidation, including neighbor changes. Zero means untouched inputs; later values come from the service's increasing invalidation sequence. |

An interior edit changes its own chunk/mesh. A face/edge/corner edit additionally invalidates the one/two/three touched face neighbors. A neighbor's mesh revision may change without its block contents or chunk revision changing. This is why chunk revision alone cannot certify reusable geometry.

When replacing cached blocks with a snapshot, the render client compares the old and reconciled boundary occupancy masks. It rebuilds face neighbors only for changed planes; interior edits and material-only changes rebuild the edited chunk. The first accepted block snapshot in each subscription, including a promotion that still retains old blocks, conservatively invalidates all loaded face neighbors. Removing a local meshing dependency does the same.

The worker batches currently queued requests, coalesces affected mesh builds, builds once for the relevant final state, and distributes owned copies to mesh subscribers. It sends unchanged blocks again only when needed for a block snapshot, such as a flag-changing reveal; neighbor-only occupancy updates use boundary payloads.

For each client, related snapshots, boundary updates, mesh results, and command acknowledgments are placed in one `ResponsePackage`. Final block snapshots are certified against final neighbor inputs before publication. Render consumers apply whole packages before any local rebuild/upload, so related updates cannot be partly applied across rendered frames. Several packages may be consumed in one frame before the one local rebuild phase.

Initial distant mesh loads are queued. The worker performs at most one between request batches, checking for newly queued edits/block loads again afterward. A mesh build is synchronous on that worker; this is prioritization between builds, not preemption inside a build.

## Optimistic cache and frame reconciliation

`Client.findStandingSpace` requests a supported surface directly from the authority. Callers specify a preferred x/y, an empty clearance volume, a separate real contact footprint, and a horizontal search radius of up to fifteen blocks per axis. The worker reads current chunk contents through its normal authoritative block reader, preferring retained edits. It returns the nearest fitting surface as a position or error through a separate value-only mailbox. Searches create no terrain subscriptions, transfer no chunks, and preserve existing chunk packages. `requestStandingSpace` and `waitStandingSpace` expose the same operation separately. Only one search should be outstanding per client; cancellation abandons the wait, and later waits filter late replies by request ID. A result is not a reservation against subsequent edits.

`World` on the main thread holds authoritative snapshots with outstanding local operations replayed on top. A locally valid edit changes that cache immediately and appends a pending operation. Conflicting local edits are no-ops. The next world update submits unsubmitted commands in their original order and records request IDs.

The world update sequence is:

1. Submit pending local operations.
2. Refresh camera-driven subscriptions and chunks pinned by pending operations.
3. Take complete response packages.
4. For each package, retire all acknowledged commands first, including failed commands, then accept payloads with current tokens/modes/revisions.
5. Replace accepted block snapshots and replay remaining pending operations over them.
6. Advance local player movement/recovery against the resulting cache, then refresh streaming/pinning again.
7. Rebuild dirty local meshes once from the resulting cache and neighbor inputs.
8. Preflight and upload queued face geometry.

A failed operation's snapshot rolls back that edit without losing later pending edits. An acknowledgment remains useful even after the corresponding subscription was evicted: it retires pending work, but its stale payload cannot resurrect the evicted chunk. Older chunk/mesh/boundary revisions are rejected within their relevant cache paths.

This is asynchronous reconciliation. Local cached blocks may temporarily differ from the service because they include pending edits. GPU geometry represents the state available to the last completed upload.

## Streaming and representation handoffs

The normal camera neighborhood uses Chebyshev distance: the largest axis chunk delta, with the shortest wrapped x delta. Chunks at distance at most 1 are requested as blocks (a 3-by-3-by-3 core); distance at most 3 is the total display neighborhood (7 by 7 by 7), with the rest requested as meshes. Neighborhoods are clipped at y/z storage boundaries. Requests proceed from nearest shells outward.

27 block chunks is a steady-state target around each relevant position. The player's 3-by-3-by-3 collision neighborhood is pinned in block mode, including while its camera is detached for spectating. Outstanding edits also pin the edited chunk and any touched face neighbors until acknowledgment. Pins can extend beyond the current display box. A distant spectator camera therefore retains both its display/block neighborhood and the player's collision neighborhood. In-flight representation changes can retain more CPU blocks temporarily.

For demotion from blocks to mesh, the old blocks, masks, and display remain available until the new mesh/unreachable response arrives. Then the CPU blocks and fallback masks are released. Retained demoted blocks no longer override authoritative neighbor planes because their block subscription has ended.

For promotion from mesh to blocks, the old display remains until blocks and neighbor masks arrive. The application can reuse the authoritative geometry if both revisions match and there are no pending edits affecting its own or neighboring meshing inputs. Otherwise it rebuilds locally. Mesh-mode state on the main thread retains version metadata; received face arrays and separate custom block descriptors move directly to the upload queue.

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

`VoxelGrid` owns a face buffer of 4 MiB and a separate chunk-metadata buffer with 4096 slots. Faces use four-byte local-coordinate/type records; chunk metadata uses 112 bytes. GPU vertices are generated from those records in WGSL. Custom blocks use another 4 MiB buffer of 48-byte records and instanced draws; custom-only chunks do not require ordinary face slots. See [country roads](country-roads.md).

Face allocations use power-of-two multiples of a 1024-byte slot. Sixty-four spans each contain 64 slots; a span uses one allocation size at a time until emptied. The maximum per-chunk allocation is 64 KiB, or 16384 face records. Total free bytes alone do not establish capacity because rounding, size classes, and fragmentation matter.

`hasUploadCapacity` copies both allocator states and simulates the actual queued allocation sequence before any upload writes. The voxel app reduces the outer radius from 3 to 2 (5 by 5 by 5) on capacity pressure. If the remaining batch still cannot fit, it retains pending uploads and prints a diagnostic; it does not partially upload the batch or expand the buffer. Radius is not automatically restored to 3 in the current code. This policy also applies when one chunk exceeds the per-chunk allocation limit.

Replacing/removing a chunk releases its resident slots and frees any superseded queued face arrays. After successful upload, all queued arrays are freed. Zero-face uploads consume no GPU residency slot. Capacity checks do not make arbitrary voxel patterns fit the fixed per-chunk and total limits.

## Deferred capacity and lifetime work

The ordinary scene-object mutation work leaves voxel code and behavior unchanged. Voxels already reclaim residency slots when chunks are replaced or removed; they do not use `Scene.removeObject`, `Scene.removeGroup`, or the ordinary instance free list. The voxel metadata limit of 4096 is independent of the removed ordinary-object cap.

Follow-up work should address these separate decisions and implementation tasks:

- Define a voxel memory budget bounded by device buffer/storage-binding limits and CPU memory allocation. Decide whether to grow the current 4 MiB face buffer and 4096-entry metadata buffer or use explicit budgets with eviction. Available bytes alone are insufficient because the face allocator also has size classes and fragmentation.
- Define how to handle chunks exceeding the current 64 KiB face-allocation limit: split their geometry across allocations or revise the allocation scheme. Shrinking the visible neighborhood cannot make a single oversized chunk fit.
- Define recovery after temporary capacity pressure. The current radius reduction from 3 to 2 is permanent for that run; consider restoring the requested radius once sufficient capacity returns, without repeated shrink/grow oscillation.
- If buffers grow, replace voxel bindings together with both residency allocators, preserve resident face records and metadata, and retain resources needed by submitted frames. Keep the existing queued-batch preflight guarantee so failure preserves resident geometry and pending uploads.
- Extend tests for repeated chunk load/replace/evict cycles, pending uploads for removed chunks, fragmentation, oversized chunks, budget exhaustion/recovery, and GPU readback after any future buffer replacement. Preserve token/revision checks so delayed worker responses cannot resurrect evicted data.

All GPU residency mutation must continue on the application thread; the world-data worker must not manipulate GPU resources. Scene-group deletion does not affect voxel chunks. Changes to authoritative modified-world retention or persistence need their own policy and are outside ordinary instance removal.

## Persistence, caches, and shutdown

The service owns authoritative blocks, construction/road metadata, block timers, historical reveal flags, and persistent revisions. Persistent worlds save these together with logical time and player checkpoints. See [persistence](persistence.md) for startup selection, storage, failure handling, and test commands; the normative contracts remain in the [feature spec](../specs/features/world-persistence.md) and [binary format](../specs/formats/world-persistence-v1.md).

Capture pauses simulation dispatch and block-timer passes. The encoder reads restricted frozen views with copied identities and borrowed immutable buffers; it releases each source when an independent encoded record exists. Player conflicts stay pending with optimistic visuals and prioritize encoding. Normal wait deadlines request safe cancellation; an overdue save can instead prioritize completion and show a saving status. Source release allows mutation before WAL synchronization completes. There is no persistence COW.

Runtime reload uses the installed base. A modified chunk can unload only when its current persistent revision equals the installed base revision and other ownership pins clear; a WAL acknowledgement alone is insufficient. All-lazy timer queues do not independently pin residency. Ordinary loading restores and registers their original deadlines; the next eligible bounded block-timer pass catches up against current local state. Players may observe or edit the old state first. Timer preparation revalidates material/event identity and executes through a fixed logical cutoff without adjacent-chunk reads. No offline elapsed time is added.

Existing allocators provide block and metadata storage. Local persistence limits and bounded queues do not establish a process-wide RAM limit. Accumulated dirty chunks retained until compaction must be measured separately from encoded capture output. Custom pools, selective COW, and the global [resource-budgeting controller](../specs/features/resource-budgeting.md) remain follow-ups.

Shutdown stops producers, admits remaining local intents, publishes their dependent player checkpoint, and drains authoritative work before the final save. The render loop continues while saving. Ordinary gameplay capture deadlines do not cancel the final save; delayed or failed completion exposes wait/retry, cancel-exit, and explicit unsaved-exit choices. Worker and file ownership remains alive until safe completion or process exit.

## Tools and simulation example

In player mode, an empty one-slot inventory selects extraction; carrying a block selects placement. Hold E or mouse1 on the same target for three seconds to extract, or one second to place. Releasing the initiating control cancels immediately, including release/repress events between frames. Looking away, leaving reach, losing target data, a changed target cell/material, loss of focus, changing control mode, or beginning exit cancels unfinished work. No world edit is submitted until the hold completes. Both controls must be released before another press can start work; presses while awaiting acknowledgment are consumed.

Completion predicts the terrain and inventory transfer together. One transfer may be pending at a time, including queue-admission retries. The service validates the player's slot and material, and extraction also checks the target cell's edit history captured at hold start. Each chunk keeps the last 16 material/occupancy changes in a transient ring, so unrelated edits do not cancel work and removing/replacing the same material is detected. A hold older than that bounded history is conservatively canceled. Snapshots carry the history; saves omit it because partial holds never survive loading. Accepted transfers change terrain and inventory in the same service turn; rejected transfers return authoritative inventory alongside the existing terrain reconciliation. Results apply even after a terrain subscription expires. Movement checkpoints cannot overwrite inventory. Mining conversions remain unchanged. Save snapshots capture authoritative inventory and terrain together, and loading restores inventory without restoring partial holds.

In observer mode, keys 1-8 select loose soil, crushed stone, trunk, planks, rebar, reinforced concrete, solid country road, and adaptive country road. Tab toggles putting/removing, with removing selected initially. This observer block mode persists across Q excursions independently of player inventory. Left click performs the active action instantly; E places only in putting mode, and X mines only in removing mode. A voxel-boundary raycast finds the first occupied block under the crosshair before checking reach. Removal measures that cube; placement measures the cube adjacent to its hit face. The inclusive four-metre limit uses distance to the nearest of the edited cube's eight vertices. Highlighting and actual edits share this targeting check. Traversal extends to four metres plus one cube diagonal so a reachable candidate can use a backing face beyond four metres. It follows the current frame’s camera view, crosses chunk boundaries and the wrapped x seam, and stops at unreceived chunks. Empty air produces no edit. Each observer press edits once. Observer keyboard and mouse presses share an ordered queue and retain their action and selected material from press time, including presses separated by Tab switches; all queued commands run after the camera update. Ctrl+E and Ctrl+R retain their SSAO shortcuts. Actual edits still pass structural validation, and placements check player overlap, including while spectating. Removing mode shows green, three-pixel-wide edges around the focused block and skips placement validation entirely during targeting. Putting mode hides green focus edges. The outlines have a separate render pass; material selection still has no UI.

In putting mode a translucent cyan outline previews allowed placement; red marks rejection, and orange
marks involved constructions or missing support cells. Hints hidden by terrain remain
faintly visible. The preview uses the shared validator without editing the world and caches
its structural result until the target, material, or world data changes. Player overlap is
checked each frame. Rejected placement shows small orange text at the bottom centre on a
translucent rounded background. Actual edit failures show medium red text at the top centre
without a background for four seconds, independently of the preview hint. Both overlays use
zgui and can appear together. See [placement diagnostics](block-placement.md#edits-and-diagnostics).

The simulation worker initially loads the central chunk column, finds the surface at its horizontal midpoint, then evicts those subscriptions. It submits one dirt put, waits for the result, and waits two seconds between subsequent operations. A successful put switches the next action to remove; a failed put retries a put. Removal switches back to putting. It communicates only through its own service endpoint, so visible changes arrive on the main thread through ordinary subscriptions. This is a concurrency example, not a broader NPC simulation system.

## Sources and regression coverage

| Source/test file | Behavior to inspect |
| --- | --- |
| [`world.zig`](../src/voxel_app/world.zig) | Contents, edit preconditions, replay/rollback, stale snapshots, and reveals. |
| [`world_data_service.zig`](../src/voxel_app/world_data_service.zig) | Queue ordering, conflicts, tokens, broadcasts/packages, revisions, masks, eviction, caches, and shutdown. |
| [`standing_space.zig`](../src/voxel_app/standing_space.zig), [`block_collision.zig`](../src/voxel_app/block_collision.zig) | Supported-space search, clearance versus real support, finite bounds, nearest offsets, and shared collision geometry. |
| [`main.zig`](../src/voxel_app/main.zig) | Streaming/pinning, handoffs, package application, mesh reuse, mask precedence, camera tools, and capacity fallback. |
| [`block_targeting.zig`](../src/voxel_app/block_targeting.zig) | Camera rays, candidate cube reach by nearest vertex, hit faces, bounds, missing chunks, and wrapped seams. |
| [`world_generator.zig`](../src/voxel_app/world_generator.zig), [`natural_generator.zig`](../src/voxel_app/natural_generator.zig), [`generation_tests.zig`](../src/voxel_app/generation_tests.zig) | Natural/flat profiles, deterministic geography, material oracle, periodic X, and enclosure certification. |
| [`boundary_mask.zig`](../src/voxel_app/boundary_mask.zig), [`world_engine_glue.zig`](../src/voxel_app/world_engine_glue.zig) | Mask coordinates/sizes and cross-chunk face extraction. |
| [`simulation_worker.zig`](../src/voxel_app/simulation_worker.zig) | Surface selection, result-dependent action changes, cancellation, and subscription updates. |
| [`voxel_tests.zig`](../src/engine/voxel_tests.zig), [`voxel_grid.zig`](../src/engine/voxel/voxel_grid.zig), [`voxel/`](../src/engine/voxel) | GPU data preparation, slot allocation/reuse, exact preflight, and fixed limits. |

Run `zig build test` for the root build's registered tests. Runtime-layout regressions cover
two differently sized services, periodic terrain, and streaming/edits across each X seam.
The [generation validation report](validation/world-generation/README.md) records executed
CPU/GPU tests, natural save/reopen checks, maps, regeneration measurements, and visual inspection.
