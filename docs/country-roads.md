# Country roads

In putting mode, **7** selects a solid country road and **8** selects an adaptive country
road. Solid roads are ordinary textured cubes. Unformed adaptive roads fill the cell's
horizontal footprint with a faceted uneven top around three quarters of the cell height,
using the existing atlas texture. Opposite top edges match so adjacent blocks join in
either horizontal direction, including across chunks.
The top ranges from 11/16 to 13/16 of a block high, and all geometry stays inside the
1×1×1 cell. This relief is visual only; movement collision remains a regular full cube.
Formed slopes retain their original appearance.
Neither type changes movement speed.

The adaptive road item held by the player or previewed in spectator putting mode uses the
same unformed model, atlas UVs, and faceted normals as a placed adaptive block.

Every road cell needs a solid block immediately underneath it. Existing cube-colliding
materials, including an unformed adaptive road, supply that support. Formed slopes cannot
support a road stacked directly above them. Roads otherwise have no foundation, height, or
horizontal span restrictions. Removing required support is rejected by the shared
client/service validator.

## Forming a slope

Place a solid road followed by **4–12 adaptive roads at the same level**, in a straight
horizontal row. Place another solid road immediately beyond the last adaptive cell, one
level lower. The completed row becomes a slope descending one block over the adaptive run.
Placement order does not matter. A twelve-section run has a 12:1 slope; the two solid
endpoints are outside the section count.

The four horizontal cardinal directions work, including rows across chunk boundaries and
the wrapped x seam. Wider roads can be built as parallel rows. Shorter, longer, incomplete,
or ambiguous intersecting rows remain unformed adaptive blocks.

Formation saves the high endpoint, downhill direction, run length, and each section's
position in the run. A section belongs to one formed run. Adding a crossing cannot rotate
or reclaim it. Removing either solid endpoint or any adaptive section reverts all remaining
sections of that run to their initial adaptive state; the removed cell remains empty.
Unrelated lateral road edits do not break the run. Reversion does not immediately form a
different crossing road; a later placement can complete an unclaimed pattern.

Grounded players walk continuously up and down the surface without climbing or jumping.
The player's rectangular footprint rests on the highest part of the surface beneath it.
Jumping, falling, walls, and ceilings still use collision checks. Targeting a formed section
hits its actual surface and passes through empty space above it; selection outlines retain
the block's cell bounds. If reversion restores a cube around the player, the existing
controller recovery finds a clear position.

## Storage and rendering

The selected adaptive material is not stored as an ordinary voxel material. Its occupied
cell contains **255**, and sparse chunk metadata records the custom road and optional
saved slope. Each section's high and low heights are fractions of its original cell.
Unformed sections use full-cube collision; formed sections use a solid convex volume from
the cell floor to the inclined surface.

Custom cells neither emit ordinary voxel faces nor hide neighboring ordinary faces.
Boundary masks and enclosure flags follow the same rule. Both local and authoritative mesh
payloads carry separate custom draw descriptors. Each descriptor defines one independent
block, submitted as an instance after ordinary geometry, with scene depth, atlas textures,
normals, post-processing, and directional shadows. Custom-only chunks remain renderable
even when they have no ordinary faces.

Custom descriptors use a separate 4 MiB GPU buffer with 48-byte records. They do not consume
ordinary voxel face slots. Upload preflight checks both buffers; removals refresh custom
draws even if ordinary uploads are waiting for capacity. Custom records are rebuilt only
when resident custom descriptors change; ordinary-only chunk changes leave the buffer clean.
Instances share up to two draws per pass, grouping formed slopes (36 vertices) separately
from unformed blocks (198 vertices). Both groups use the custom renderer in the forward
pass and three shadow cascades. Their geometry stays outside chunk meshes.

Formation and reversion update every affected chunk's revision and travel in the service's
atomic response packages. Saved orientations survive subscription eviction in service
memory. Optimistic edits pin affected road chunks, preserve undo metadata for rejected
commands, and replay after snapshots. Disk persistence remains unimplemented.

Before an accepted snapshot replaces any chunk, pending changes are undone in reverse order
across all their edited cells and affected road sections. Each edited cell retains a sparse
baseline containing its material, road record, construction marker, and scheduled timer.
Commands then replay in order: capture the cell's current road ownership, apply its material
mutation, and restore/evaluate its road transition before advancing to the next command.
Undo records are rebuilt against that baseline. Earlier commands cannot acquire formations
caused by later materials, and removing a member revokes ownership before a later replacement
can form a crossing. Rejections use the same rebase for remaining commands and invalidate
the edited cell's neighboring meshes. Successful acknowledgments retire commands in service
submission order, retaining their effects as the baseline for later pending commands.

Pending formations retain their chosen direction when later crossings make the final pattern
ambiguous; a newer authoritative crossing owner takes precedence. The extra work and storage
are bounded by pending edits and their changed sections, with sparse chunk metadata lookups.
There are no full-chunk baseline copies or global world scans. Internal material rollback and
replay preserve validation stamps for unchanged chunks outside the received/rejected chunk.

Alongside the explicit road scenarios, `world_data_service.zig` retains a deterministic
client-versus-authoritative-worker regression with 32 fixed seeds and 512 local intents.
It varies road/snow/dirt placements, removals, conflicting edits, delayed snapshots, related
chunk ordering, and batched successful/failed replies. It compares every fully acknowledged
prefix and the final state, using only snapshots produced by those operations. Materials,
occupancy counts, boundary masks, road records, construction markers, and ordered timers
must match the worker; allocator checks detect leaks. Failures print the seed and edit trace.
The harness uses synchronous fixtures and adds no gameplay work or testing dependencies.

Collision reads material and custom shape together, querying sparse road metadata only for
cells with value 255. Standing-space and player support share the clamped-footprint surface
calculation. A ceiling can clip an uphill lift; the valid partial lift continues through
horizontal sweeping and settling, so a player can leave the ceiling when the path is clear.

GPU geometry readback covers every section of 4-, 7-, and 12-section runs in all directions,
including zero-height ends, and verifies actual atlas UVs and normals. Unformed geometry
checks cover cell bounds, lowered tops, triangle winding, faceted normals, and matching
top edges in a 2x2 patch across chunk boundaries and the wrapped x seam. A full raster/image
regression harness, per-chunk upload ranges, and a road-index map are deferred: they add
resource or bookkeeping complexity, and the latter two need profiling evidence first.
