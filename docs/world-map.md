# World map

Press **M** in the voxel app to open or close the whole-world overview. The panel
keeps margins around the screen and preserves the world's horizontal aspect
ratio. North (+Y) is up. A gold arrow marks the player's position and heading;
spectator mode adds a cyan arrow while dimming the original player arrow. The
original arrow remains visible when both positions coincide.

The map captures movement controls, mouse look, block tools, and control-mode
switching. Opening or closing it cancels unfinished block actions and pending
jumps, and discards mouse look deltas. World time and background simulation
continue while the map is open. Player physics also continue: an airborne player
completes its jump and falls onto the terrain, with the camera and map marker
following the player. The world behind the panel stays at its normal brightness.
Close it with M, Escape, or the Close button. The game menu and map are exclusive;
Escape closes the map first. Exiting the game also closes it.

Debug builds add **Mouse1** teleportation on the terrain image. A click moves the
actor currently under control and closes the map on success. The destination is
the centre of the selected block column, with north-up coordinates and a half-block
inset at the world edges. Holding or dragging the mouse does not repeat the
request; the margins, Close button, and unavailable-map placeholder do not
teleport. Release builds omit this debugger control and its hint.

For the player, teleportation looks up the current surface asynchronously at the
exact selected column, including terrain edits, and places the player only when
a safe standing position is available. The map shows progress or a failure.
M, Escape, Close, and further terrain clicks are unavailable while the player
teleport is pending. Success closes the map. Failure leaves the player where
they were, keeps the map open, and permits another attempt or closing the map.
While waiting for edit acknowledgments, a reported world-data failure ends the
teleport attempt. Any attempt also times out after 30 seconds of real time.
Both failures preserve pending edits and restore map controls.
Quitting still cancels the pending request. For a spectator, the destination is
four metres above the generated land or water surface; the original player
stays in place. Both modes preserve the actor's heading.

The overview samples immutable generated terrain, climate, forests, and mountains;
it does not reflect player terrain edits or show underground deposits. Sampling
uses the prepared generator without loading chunks. A raster's longest side is
at most 1024 pixels (1024×512 for the default world), with at most 4 MiB of RGBA
pixels. The image is created on first opening, uploaded once, and cached until
shutdown; temporary CPU pixels are freed after upload. Marker poses are projected
on each frame, using centred world coordinates, north-up Y, and the compiled X
wrapping policy. Markers retain their exact positions at the map edges, with room
for the arrow in the surrounding gutter.

CPU tests cover raster bounds and deterministic sampling, wrap seams and heading
projection, panel margins/aspect, Close-button hit testing at normal and Retina
framebuffer density, pending teleport controls, Debug-only terrain clicks and
held-button suppression, teleport column selection, modal transitions,
edit acknowledgment ordering, corrupt saved dependencies, timeouts and late replies,
player/spectator poses, continued jump and terrain collision physics, and
suppression of movement controls, look, and stale block actions. They run as part
of `zig build test`.

## Deferred work

These items from [PR #41](https://github.com/bacher/zig_engine/pull/41) remain
open and are tracked in [TODO.md](../TODO.md). The measurements below were taken
during the review on 2026-10-26.

### P2: Map generation stalls the first frame

On the first M press, `State.draw` calls `State.prepare`, which builds the entire
raster synchronously before drawing the panel. The default 1024×512 raster
samples 524,288 terrain columns on the application thread, blocking rendering
and event polling. This also delays frame-based player physics despite the map
not pausing gameplay time.

With the natural generator already prepared, seed 12345, and the default
2048×1024×32-chunk world, local `Raster.init` measurements were approximately
776 ms in Debug and 75 ms in ReleaseFast. These timings exclude generator
preparation and GPU upload; they are evidence of the stall, not a portable
performance budget.

Avoid building the full CPU raster in the first render callback: prepare it
before gameplay, build it incrementally within a frame budget, or use a worker while
displaying a loading panel. Keep GPU upload on the render thread, retain the
cache, and avoid loading voxel chunks. If a worker borrows the prepared
generator, join it before destroying the world-data service during shutdown.
Verify that first opening remains responsive and reopening reuses the texture;
keep timing measurements in a benchmark.

Source: [world_map.zig](../src/voxel_app/world_map.zig),
[world_map_data.zig](../src/voxel_app/world_map_data.zig).
[Original finding](https://github.com/bacher/zig_engine/pull/41#discussion_r4375176868).

### P3: Header overlaps in narrow windows at high UI scale

With a zgui display size of 400×400 and `font_scale_dpi = 2`, a focused UI probe
measured the title at x=60..193, the north label at x=96, and the Close button at
x=148..340. Both the label and button overlap the title. `panelLayout` clamps
the requested minimum panel width to the available space, while the header
continues to use fixed scaled offsets.

Use a compact or wrapped header, or measure the title and reserve the button's
width. Verify that the title, north label, and Close button remain readable and
the button remains clickable at narrow sizes and 200% UI scale. Extend the UI
tests to vary actual font/UI scale independently of framebuffer density; the
current Retina click test keeps UI scale at 1.

Source: [world_map.zig](../src/voxel_app/world_map.zig).
[Original finding](https://github.com/bacher/zig_engine/pull/41#discussion_r4375176872).

### Test improvement: Natural terrain and downsampling

The raster determinism test covers flat and legacy terrain generators in a
64×128-block world, where every pixel represents one block. It does not exercise
the default natural generator or cell-centre sampling when a pixel represents
many blocks. The palette tests use synthetic column environments.

Add a fixed-seed natural-world regression with a valid layout large enough to
require downsampling. Check repeated output, independently calculated sample
locations at the north/south edges and X seam, and representative generated land
and water colors. Keep wall-clock assertions out of unit tests; use a separate
benchmark to track raster generation cost.

Source: [world_map_data.zig](../src/voxel_app/world_map_data.zig).
[Original suggestion](https://github.com/bacher/zig_engine/pull/41#discussion_r4375176883).
