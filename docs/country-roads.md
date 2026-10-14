# Country roads

In putting mode, **7** selects a solid country road and **8** selects an adaptive country
road. Solid roads are ordinary textured cubes. Adaptive roads initially display an inset
marker using an existing atlas texture; their movement collision still fills the whole cell.
Neither type changes movement speed.

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
payloads carry separate custom draw descriptors. The renderer draws each descriptor
individually after ordinary geometry, with scene depth, atlas textures, normals,
post-processing, and directional shadows. Custom-only chunks remain renderable even when
they have no ordinary faces.

Custom descriptors use a separate 4 MiB GPU buffer with 48-byte records. They do not consume
ordinary voxel face slots. Upload preflight checks both buffers; removals refresh custom
draws even if ordinary uploads are waiting for capacity.

Formation and reversion update every affected chunk's revision and travel in the service's
atomic response packages. Saved orientations survive subscription eviction in service
memory. Optimistic edits pin affected road chunks, preserve undo metadata for rejected
commands, and replay after snapshots. Disk persistence remains unimplemented.
