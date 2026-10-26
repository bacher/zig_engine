# World map

Press **M** in the voxel app to open or close the whole-world overview. The panel
keeps margins around the screen and preserves the world's horizontal aspect
ratio. North (+Y) is up. A gold arrow marks the player's position and heading;
spectator mode adds a cyan arrow while dimming the original player arrow. The
original arrow remains visible when both positions coincide.

The map captures movement, mouse look, block tools, and control-mode switching.
Opening or closing it cancels unfinished block actions and pending jumps, and
discards mouse look deltas. World time and background simulation continue while
the map is open, and the world behind the panel stays at its normal brightness.
Close it with M, Escape, or the Close button. The game menu and map are exclusive;
Escape closes the map first. Exiting the game also closes it.

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
framebuffer density, modal transitions, player/spectator poses, and suppression of
movement, look, and stale block actions. They run as part of `zig build test`.
