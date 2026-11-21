# Rendering as implemented

The engine has a fixed sequence of WebGPU passes assembled in `Engine.draw`. It renders the active scene into intermediate textures, applies screen-space ambient occlusion (SSAO), composites to the swapchain, then draws application/GUI overlays. This document describes that sequence and its current constraints.

## Frame data and pass order

Before encoding passes, the engine fits directional-light cascades, collects object candidates for every cascade and the camera, refreshes dirty/billboard instance transforms, and uploads the changed instance range. The scene-object index returns every registered GameObject for each query. Chunk-owned geometry has a separate spatial index.

```mermaid
flowchart LR
    Shadow[Three shadow layers] --> Forward[Forward color and normal pass]
    Forward --> Color[Color texture]
    Forward --> Normal[View-space normal texture]
    Forward --> Depth[Depth texture]
    Normal --> SSAO[SSAO pass]
    Depth --> SSAO
    Color --> Final[Final composite]
    SSAO --> Final
    Final --> Focus[Block outlines and translucent cell hints]
    Focus --> Held[Camera-space 3D overlay]
    Held --> Overlay[Application and GUI overlay]
    Overlay --> Present[Submit and present]
```

| Stage | Current behavior |
| --- | --- |
| Shadows | One pass for each of three cascades per scene light; writes an `r32_float` layer with a separate depth attachment. |
| Forward scene | Clears and renders color (`rgba8_unorm`), encoded view-space normals (`rgb10_a2_unorm`), and depth. Some pipelines disable normal writes. |
| SSAO | Full-screen pass reconstructs view-space positions from depth and uses the normal texture to estimate occlusion; output is `r16_float`. |
| Final composite | Full-screen pass copies scene color or multiplies it by SSAO. Optional blur/debug display are applied here. |
| Block outlines | Loads swapchain color and scene depth. Draws green focus edges and colored translucent cell hints as three-pixel-wide triangle pairs, with faint occluded hints and no depth writes. |
| 3D overlay | If `onRenderOverlay3D` exists, loads swapchain color and clears the reused scene depth attachment for camera-space geometry, including held blocks and empty hands. |
| Overlay | If `onRender` exists, loads the swapchain color without a depth attachment, invokes the application callback, and renders GUI when enabled. |

The SSAO pass is still encoded when SSAO is disabled. The final shader bypasses its result in that case. GUI frame creation and the engine debug window currently occur inside the optional `onRender` branch.

## Geometry paths

Regular meshes use position, normal, UV, and index buffers. Skinned meshes additionally use four joint indices and weights per vertex. Models share GPU mesh data, while each object references its own instance index. Each object/mesh is submitted separately; the current renderer does not combine all instances of one model into one draw.

Colorized primitives and window boxes use their own pipeline/bindings. A window box receives the camera position transformed into model space. Height-map terrain constructs vertices in WGSL from a sampled integer height texture; the grid side is currently fixed to 64. It is a different terrain representation from the voxel application's generated block world.

Skyboxes use camera rotation and projection, omitting translation. The dedicated cubemap skybox is drawn separately before voxels and the queried ordinary objects. Skyboxes are excluded from shadow casting.

CPU world transforms remain in `f64`. GPU paths use chunk-local matrices plus integer chunk coordinates, with a camera/cascade chunk origin. Integer chunk subtraction and optional x wrapping happen before conversion to meters. The application selects wrapping at compile time. Scenes acquire a reference to eight specialized pipelines in the engine cache: unwrapped scenes share one set, and wrapped scenes share by x width. Unwrapped shaders omit periodic arithmetic and width/mask constants. Common pipelines stay engine-owned. See [world configuration](world-configuration.md) and [coordinates](coordinates.md); using an absolute-world `f32` matrix would break the large-position guarantees.

## Zig/WGSL type naming agreement

Use the `GPU_` prefix for every project-defined Zig type whose values represent
the byte layout consumed or produced by WGSL. This includes uniform, storage,
and vertex records, packed shader settings, named array payloads, and GPU readback
types in tests. Keep the prefix on imports, aliases, and re-exports of these types.

Examples are `GPU_ChunkTransform` (also exposed as `GPU_InstanceBufferEntry`),
`GPU_BlockInfo`, `GPU_ChunkInfo`, `block_outline.GPU_Instance`,
`held_block.GPU_Uniform`, `GPU_SceneShaderRuntimeSettings`,
`GPU_PostEffectShaderRuntimeSettings`, and `GPU_JointMatrixUniform`.

The prefix identifies a shader layout contract. Keep field order, sizes,
alignment, padding, and array stride compatible with the corresponding WGSL
declarations, and retain layout assertions and GPU readback coverage when
changing a payload. Zig and WGSL type names can differ; the prefix is required
on the Zig side.

CPU domain types and resource owners such as `WorldLayout`, `Overlay`,
`BufferDescriptor`, and `JointMatrixBuffer` keep their ordinary names. A CPU
collection of GPU records, such as `BlockCoordList`, is not itself a shader
payload. Built-in scalar/vector/array types and third-party math types used
directly in uploads do not need new aliases solely to add the prefix.

## Voxel rendering

The voxel app starts in removing mode, which shows green focus edges and skips placement
preview validation. Tab switches to putting mode, which hides green focus edges and uses
colored placement hints. Block mode is shared across player and spectator control.

The player carrying a block, or the spectator in putting mode, draws a camera-space held
block through [`held_block.zig`](../src/engine/held_block.zig) in the application's 3D overlay
callback, before the GUI. Ordinary materials share cube geometry and atlas UV helpers with
world voxels. Adaptive roads share the placed block's faceted model, normals, and UVs through
[`adaptive_geometry.wgsl`](../src/engine/shaders/voxel/adaptive_geometry.wgsl), including its
uneven top around three quarters of a block high. The 3D overlay clears the scene depth
attachment after all world-depth consumers finish. Held geometry uses back-face culling
and depth testing for self-occlusion, staying visible over terrain and cell hints. It has
steady camera-space shading and does not participate in world shadows or SSAO. Spectator
removing mode submits no held-block draw. Its projected position, rotation,
and scale are configured together in the voxel app's `held_block_pose`. The resting pose uses
the active camera's projection and no world position or orientation. Shared held-item motion
adds camera-space offsets to this pose. The application owns and releases its renderer before
engine teardown.

With an empty player inventory, [`empty_hands.zig`](../src/engine/empty_hands.zig) draws two
4:4:12 cuboids in the same overlay pass, at the lower left and right. Each arm maps the
corresponding base arm region of the 64×64 `content/default-skin.png` skin, using nearest
sampling and the held block's steady camera-space lighting. Both arms consume the existing
held-item motion offset around their own resting grips. They appear only in player mode
with empty inventory; carrying a block replaces them with the held block, and spectator
removing mode draws neither. The application owns the skin texture and releases it after
the hands renderer and before engine teardown.

The voxel app refreshes `Scene.highlighted_block` using the editing raycast after camera updates, optimistic edits, and subscription changes. The engine's independent [`block_outline.zig`](../src/engine/block_outline.zig) pipeline draws it after post-processing and before GUI overlays. It emits 72 procedural vertices, clips edges against the near plane, and expands them in screen space to keep their width constant when distance or window size changes. It excludes edges whose adjacent faces both face away from the camera. For each stroke pixel overlapping the target cube, the fragment shader reconstructs the cube's front surface depth to prevent the target's own sloped faces from cutting into the stroke.

The shader also extends each edge's visible adjacent face planes across the narrow stroke margin to keep coplanar neighboring blocks from trimming it. This continuation is limited to 0.25 metres beyond the unit face bounds: a small screen-space margin can otherwise extrapolate metres forward at grazing angles and leak through foreground blocks. Plane intersections outside that bounded neighborhood leave the reconstructed target/edge depth unchanged. This deliberately allows the outer stroke to be clipped on nearly edge-on coplanar surfaces when preserving it would require a more distant intersection. Scene depth still hides the outline behind other geometry; an eight-epsilon f32 allowance handles depth rounding, and the pass never writes scene depth. The pipeline reads each cell's transforms, viewport, masks, and color from a shared read-only instance buffer. The outline's storage cell is rebased to the camera chunk, including the wrapped x seam, before conversion to f32. No voxel face or shadow shader contains highlighting logic.

`Scene.block_overlays` also carries a bounded, value-owned set of signed storage cells and
RGBA colors and whether the cell contains a received block. Placement previews reuse the
same outline shader and bind group layout, retaining all twelve edges. For occupied cells,
edges touching camera-facing faces use the focus outline's bounded surface-depth correction,
so the block's own tilted faces do not trim the expanded stroke. Rear edges, empty cells,
unknown cells, and cells beyond finite world bounds retain their actual edge depth.
The regular pipeline alpha-blends visible strokes with a `less_equal` depth test; a second
pipeline uses `greater` and 30% opacity for hidden strokes. Both leave depth unchanged.
All hidden overlays draw before all visible overlays, using two instanced draws and two pipeline selections for
the overlay set. This prevents a later faint stroke from tinting an earlier bright stroke
where diagnostic cells overlap on screen. Each cell's instance data is prepared once and
uploaded once; a shader pipeline constant applies the hidden pass's lower opacity.
Diagnostic colors take precedence when an overlay also covers the focused cell. The voxel
app uses opaque cyan/red for the placement candidate, matching the green removal target's
three-pixel width and opacity, and translucent orange for involved blocks or missing
support cells. See [placement diagnostics](block-placement.md#edits-and-diagnostics).

The correction adds one cached block lookup per distinct diagnostic cell and a six-bit
camera-facing face mask. It adds no world support searches or surface rebuilds. A persistent
11,440-byte storage buffer holds up to 65 instances (64 engine overlays plus an optional
ordinary focused cell). The shader selects records with `instance_index`; fragments receive
the same index without interpolation. Only the active prefix is uploaded, using 176 bytes
per cell. Ordinary green focus uses one instance in the visible draw and no hidden draw.
Both depth passes reuse one transform/inverse-transform preparation per cell. GPU correction
runs only for rasterized strokes touching camera-facing surfaces; its cost depends on their
screen coverage, including overlap between cells. The current 34-cell preview bound submits
two outline draws rather than 68, with the same 4,896 vertices.
`zig build bench-outlines -Doptimize=ReleaseFast` measures CPU classification and instance
preparation for one focused outline and 20/34 diagnostic cells (11 samples of 10,000 frames
with a changing camera transform). It then compares individual versus instanced command
encoding using the same shader/pipelines and actual Dawn API, alternating paths after warmup
(11 samples of 1,000 frames). The latter includes encoder/pass creation, finish, and release,
and excludes preparation, buffer uploads, queue submission, and GPU execution. Commands are
never submitted. If no graphics adapter is available, only command encoding is skipped.

On the local Apple M4 Max, the ReleaseFast benchmark measured median CPU preparation
times of 0.035 µs for one focused cell, 0.778 µs for 20 diagnostic cells, and 1.360 µs for 34
diagnostic cells. The diagnostic group contains received occupied cells and the candidate.
Command-encoding medians on the Metal adapter were:

| Cells | Individual draws | Instanced draws |
| --- | ---: | ---: |
| 1 focused | 0.802 µs | 0.826 µs |
| 20 diagnostic | 3.197 µs | 0.840 µs |
| 34 diagnostic | 4.922 µs | 0.845 µs |
| 64 diagnostic | 8.407 µs | 0.828 µs |

This saves about 4 µs of CPU command encoding at the current 34-cell bound: a modest absolute
improvement, with better scaling as the batch grows. These are CPU microbenchmarks, not
full-frame timings. GPU vertex and fragment counts are unchanged; storage-buffer access
differs from the former per-cell uniforms, and GPU timing remains unmeasured. GPU image
regressions compare instanced and individual draws at 20, 34, and 65 cells, including mixed
correction masks and a visible-only focused cell. Profile GPU stroke coverage before raising
the application preview bound; instancing does not reduce screen-space overdraw.

The voxel grid uses the `surface` representation through `ChunkSurfaceData`: exposed-face records containing local block coordinates and a render-material ID in four bytes, plus separate custom block draw records. Six lists group face records by outward direction; fully occluded ordinary blocks contribute no face records. The vertex shader generates six vertices per face and selects atlas UVs using the render material and direction. This compact payload reduces GPU storage and upload bandwidth.

Its 4 MiB face buffer uses 1 KiB slots grouped into 64 KiB base spans. Ordinary allocations
retain their size-class packing within a base span. Oversized chunk layers reserve two,
four, or eight contiguous base spans as one allocation, supporting every culled opaque
32³ chunk without changing the packed shader layout. These ranges can fail under
contiguous-space fragmentation; capacity preflight preserves resident geometry for retry.

World storage uses [`BlockType`](../src/engine/voxel/voxel_chunk.zig), with IDs 0–20 (7 reserved), `pallet = 23`, and
`custom = 255`; carried items have a narrower persistence schema. `GPU_BlockInfo.block_type`
uses the separate `RenderMaterial` enum. Shared IDs retain the same meanings, and surface extraction
adds two climate appearances for saved `grass = 3` cells:

| Column climate | Render material | Appearance |
| --- | --- | --- |
| Temperate or desert | `grass = 3` | Existing grass top and soil faces. |
| Steppe | `grass_steppe = 21` | Yellow grass top with ordinary soil sides and bottom. |
| Frozen | `grass_frozen = 22` | Snow-textured top with ordinary soil sides and bottom. |

[`world_engine_glue.zig`](../src/voxel_app/world_engine_glue.zig) applies the generator's
column climate during both local and service surface extraction. Saved cells remain grass;
bare soil and sand keep their material appearances. The former packed-soil slot 7 is reserved;
soil uses `dirt = 2` with optional grass cover. IDs 21 and 22 belong only
to render payloads and are rejected by block and inventory persistence validation.

[`material_color.wgsl`](../src/engine/shaders/voxel/material_color.wgsl) supplies the shared
world/held-block colors. Water (ID 4) is opaque blue and leaves (ID 15) are opaque green:
both return alpha 1 before the visible shader's alpha-discard check, even when the sampled
atlas texel is transparent. Their cube faces write depth and cast solid shadows. Geological
materials (IDs 16–20) use tinted existing atlas tiles. Climate cover changes the top
appearance without changing stored soil or its interaction rules.

Chunk metadata describes eight combinations of three directions, one direction from each axis.
The instance index encodes the chunk metadata slot and a four-bit mode. The forward pass
chooses a three-side combination (0–7) from the signed camera/chunk delta. When any component
is zero, mode 8 covers all six sides. The vertex shader reads combination 0 followed by
combination 7 in the same draw. Each selected terrain or construction layer costs at most one draw.

Each pass queries a bounding volume hierarchy (BVH) over resident chunk coordinates. Voxel layers, packed sources and blueprint miniatures maintain separate indexes because their residency changes independently. Nodes enclose their entries in chunk-aligned boxes and split along the longest axis. A query rejects an outside subtree, accepts every entry in a fully contained subtree, and descends through intersecting nodes. Camera movement reuses the hierarchy. Voxel edits reuse the resident layer slot. The voxel index rebuilds when a layer gains or loses geometry, or when removal moves a drawable layer to a new slot. Packed and miniature indexes rebuild when source coordinates or membership change.

The six planes come from the matrix used to render that pass, including WebGPU’s zero-to-one depth interval. Bounds use the same integer chunk delta and wrapped-X image as the vertex shader. A box touching a plane stays eligible. Each of the three shadow cascades queries its own orthographic volume and draws all six sides of surviving voxel layers. An off-camera chunk can therefore cast a shadow. Cached blueprint miniatures use only the camera query in their overlay pass.

Custom cells (block value 255) do not enter the face lists and do not occlude neighboring
ordinary faces. Separate descriptors accompany local/service surface payloads. A custom-only
chunk can have zero ordinary faces. `VoxelGrid` retains its descriptors and uploads 48-byte
records to a separate 4 MiB storage buffer. Each chunk owns an instance range in each shape
batch. The camera and shadow passes select whole chunks, including those that touch the
frustum. Each shape takes at most one draw, from the first selected instance through the
last. Roads in any gaps go to the GPU in that draw. Both passes share the custom vertex function and restore the scene
bindings after ordinary object rendering. Road slope planes match CPU collision; unformed
adaptive roads use temporary inset marker geometry. See [country roads](country-roads.md).

The CPU/WGSL layouts are part of the contract: chunk metadata is 112 bytes, face records are four bytes, custom block records are 48 bytes, ordinary instances are 80 bytes. Changes must keep the shader declarations and upload layout synchronized.

### Packed goods and pallets

The [packed renderer](../src/engine/packed_renderer.zig) is an owner-neutral scene layer with
its own color/shadow pipelines. Ordinary terrain shaders do not sample packaging. Application
[packed geometry](../src/voxel_app/packed_geometry.zig) derives warehouse sources from the same
presentation snapshot as empty-pallet icons and disabled crosses. Stock changes do not rebuild
terrain. Logical collision and player recovery follow current stock independently of GPU work.

Cube goods use a flat exposed-face list carrying local coordinates, material and direction:
20 bytes at the application boundary, 24 bytes on the GPU including a source-table index.
There are no directional groups or camera-view index tables. The vertex shader expands each
face into six vertices; hardware backface culling rejects away-facing triangles. Interior
faces are culled during source preparation. A full 5×5×6 cubic warehouse has 170 exterior
unit faces. This count is geometric, not a measured frame-time result.

A warehouse has one visibility box covering its registered footprint and all six storage levels
(up to 5×5×6 cells), including member pallets and empty-base markers. Its pieces share that
box across chunk boundaries and the wrapped-X seam. Each pass queries the covered chunks,
tests a boundary warehouse once and selects all of its pieces together. Loose pallets share
their chunk's box. Visibility queries work on these boxes and cached ranges of instances.

Irregular cargo and its packaging have separate instanced batches. Each pass merges adjacent
visible ranges within each category, including ranges owned by different warehouses. The camera and each shadow cascade issue
at most three draws per category. They skip the two largest internal gaps by instance count
and submit any smaller gaps along with the visible records. Records before the first visible
range and after the last are excluded. Moving the camera or selecting a shadow
cascade only changes the arguments to the draws. Instance buffers stay on the GPU.
The shared 288-vertex goods template represents either the standard 198-vertex unformed adaptive
road (90 unused vertices form degenerate triangles) or an eight-cuboid pallet. Pallet cargo is
uniformly scaled to 90% at cell center. Packaging supplies a full-size bottom pallet plus six
cutout strap faces, 324 vertices per item. Straps surround the full cell and render from both
sides; the packaging pipeline disables face culling. Cube goods instead composite pallet/strap
artwork only on their exterior faces. No semitransparent blending is used. Empty pallets share
the real pallet geometry, and advisory top markers do not cast shadows onto their own pallet.

Dense buffers batch faces, goods models, packaging, empty pallets and markers separately.
A source update replaces only its records; swap-removal repairs reverse references for moved
records, and uploads affected spans. Geometric buffer growth can copy existing records. The
source table stores chunk coordinates so shaders rebase before converting local positions to
floating point, including wrapped X. Unchanged sources need no upload for a camera-only frame.
The renderer exposes counts, capacity bytes, uploaded bytes/calls, moved records and submitted
vertices; these distinguish update costs from draw counts and GPU execution time.

The [shared contract](packed-blocks.md) separates appearance from full-cell collision and lack
of construction support. [Warehouse Q29](../specs/features/warehouses.md#q29--explicit-packed-faces-and-instanced-irregular-goods)
records the selected representation and validation expectations.

### Construction geometry and terrain handoff

Fulfilled construction targets use a separate `construction` layer in the existing voxel
grid. [`construction_geometry.zig`](../src/voxel_app/construction_geometry.zig) emits the
same four-byte exposed-face records as terrain. Both layers use the ordinary visible and
shadow draw loops, so construction needs no additional shader or render pass. Pending
miniatures retain their existing renderer. The progress bitmap and simulation's ownership do
not prescribe the GPU layout.

Construction surface extraction visits precomputed target groups for the changed chunk. It removes
internal faces between fulfilled targets across chunks, separate sites, and the wrapped x
seam. When local terrain cells are available it also removes faces hidden by that terrain.
Surface-only subscriptions may retain invisible faces against static terrain whose interior
cells are unavailable; they still remove internal construction faces. This conservative
rendering rule does not permit collision or interaction through unknown world data.

An ordinary progress-only fill while a site remains building dirties its loaded chunk and
at most six face neighbors; repeated changes coalesce in the dirty-chunk map. Full snapshots,
resync and lifecycle/transfer changes may invalidate the larger site footprint. A chunk rebuild visits only its registered sites
and their target groups. Face-neighbor lookups inspect the neighbor chunk's registered sites,
and one temporary set indexes bounded optimistic fulfillments for that rebuild. Readiness
and successful-install reconciliation currently scan the loaded chunks and their site
references each frame. These are client presentation costs, separate from simulation work.

Terrain publication includes subscription, chunk, surface, and composition revisions. Client
collision and interaction can use coherent materialized terrain before the progress or GPU
streams catch up. A transferred reference, removal of a previously known reference, or a
matching retirement watermark proves the target's terrain owner; an old empty snapshot
received before admission does not.

Visible construction remains resident until a matching terrain replacement and the dynamic
replacement have both been prepared. `VoxelGrid` keeps resident layers while queued jobs
are superseded, and checks GPU capacity and CPU metadata allocation before changing either
layer. A failed build/upload retains the displayed geometry and retries. On success the
terrain replacement and dynamic removal install in the same frame, then miniature state
and retained sources can retire. Once a portion has switched to static geometry, newer
ordinary edits cannot reactivate its old construction source. Visibility eviction starts a
new selection lifetime. Retirement also clears pending targets when the final fill publication
was missed, without dropping geometry before its handoff. Snapshot installation starts local
cleanup from zero; the cleanup cursor is never part of the published payload. See [construction rendering validation](validation/construction-rendering.md)
for measured geometry counts, costs, budgets, and remaining limits.

## Held-item motion

[`held_item_motion.zig`](../src/engine/held_item_motion.zig) owns the tool-independent motion
state and outputs camera-space translation in metres and rotation in degrees.
[`held_item_pose.zig`](../src/engine/held_item_pose.zig) composes these offsets around a configurable
model-space grip point while preserving its resting position, scale, and rotation. The `pivot`
defaults to the unit cube's centre `(0.5, 0.5, 0.5)`; other tools can choose their own grip point.
Neither module depends on block types, material selection, or placement validation. Future
tool renderers can consume the same `Offset` and choose their own resting pose. The voxel app
updates one motion state each frame, including when no held item is visible.

Hybrid combines a small walking bob with acceleration-driven lag and spring recovery.

Movement velocity comes from actual camera-position differences in f64, so pressing into a
wall does not create walking motion. A short velocity filter smooths abrupt controller starts
and stops. Acceleration is computed in world space before transforming into camera space;
turning the camera cannot invent a braking force. The spring follows
`offset'' = spring_force - damping * offset' - acceleration * lag_strength`, using substeps of
at most 1/240 second. Braking therefore reverses the inertial response even while velocity
still points in the original direction. Direction lean is a separate, smaller speed-based
component.

The gait phase advances with horizontal distance travelled, and its amplitude scales with
speed relative to `gait_reference_speed` (5 m/s by default) and fades when stopped or airborne.
Airborne player motion retains inertia and vertical lean; landing adds a small downward impulse.
Spectator motion samples its own moving camera,
with horizontal flight driving the same bob and vertical flight driving the spring.
Yaw/pitch changes add brief look sway, with angle wrapping handled across +/-pi. Absolute
pitch also shifts the item vertically: looking down raises it to reveal more above the bottom
of the viewport, and looking up lowers it. The target is `-sin(pitch) * pitch_shift`, clamped
to +/-90 degrees, and follows with exponential smoothing. The default maximum shift is
0.10 metres with a 0.18-second response time (63% of a change; about 95% after 0.54 seconds).
It persists at a held angle and affects translation only, preserving the resting rotation.
Both player and spectator controllers restrict pitch to the vertical range; the player stops
just short of +/-90 degrees and the spectator stops at +/-90 degrees.
Changing camera mode, losing focus, recovery teleports, invalid frame durations, and large position
jumps reset transient motion to prevent discontinuity kicks. Initial samples and teleports
establish the grip height for the current pitch without an inertial impulse. Focus changes and
invalid frame durations also retain this height for valid camera samples, discarding the movement
baseline so resuming cannot create a kick. Invalid positions or look angles clear the motion state.
At rest the transient tail settles to exactly zero while retaining the pitch offset; looking straight
ahead restores the exact approved pose. There is no idle breathing motion.

The shared `Tuning` defaults provide these adjustment controls:

| Knob | Effect |
| --- | --- |
| `strength` | Overall motion amount; zero shows the resting pose. |
| `bob_amplitude`, `stride_length` | Walking bounce size and cadence (shorter stride means faster cycles). |
| `gait_reference_speed` | Speed in m/s at which walking bob reaches its normal amplitude; independent of stride cadence. |
| `acceleration_lag` | Weight felt on starts, turns, and braking. |
| `direction_lag` | Steady lean opposite the movement direction. |
| `spring_frequency`, `damping_ratio` | Grip stiffness/recovery speed and how much it rebounds. |
| `look_sway` | Lag during mouse look. |
| `pitch_shift` | Maximum persistent vertical shift; more reveals more of the item when looking down. |
| `pitch_follow_time` | Pitch response delay in seconds; smaller follows faster, larger feels smoother and heavier. |
| `landing_strength` | Additional touchdown dip. |
| `rotation_strength` | Angular motion independently of translation. |

Regression tests cover the approved idle pose, acceleration versus braking, vertical impulses,
settling, persistent pitch displacement and slow pitch ramps, camera turns, angle wrapping,
pitch preservation across pause/focus resets, invalid camera samples, spectator pitch limits,
configurable gait speed and model pivots, large world positions, and 30/60/120/240 FPS comparisons.
Application tests cover actual camera and pitch sampling in both modes, blocked movement,
focus/pause transitions, and preserving motion through material selection.

## Directional shadows and light limitations

A light records a direction, color, and intensity, and has three cascades. Each cascade is anchored at the camera chunk. Its orthographic projection is fitted to a camera-frustum extent in light space, using fixed depth parameters and a light-height range of 300. Each shadow layer is 1024 by 1024.

Regular meshes, skinned meshes, primitives, window boxes, height-map terrain, and resident voxel geometry cast shadows. Terrain's visible and shadow shaders share the height-derived vertex function; voxel shaders likewise share face-derived geometry. Shadow sampling uses the same chunk frame as casting.

The mesh (including skinned meshes), voxel, and height-map fragment shaders share [`shadow_map/sampling.wgsl`](../src/engine/shaders/shadow_map/sampling.wgsl). Each pipeline prepends it to its fragment source using Zig's compile-time `@embedFile` and string concatenation, with no runtime preprocessing or source allocation. Its `shadowFactor` function takes the texture, sampler, and three light-space positions, keeping it independent of the pipeline's bind group indices. New fragment shaders can embed the same file and call the function before alpha discard.

The shared function samples all three layers before cascade-dependent branches, keeping implicit texture derivatives in uniform control flow. It selects the tightest applicable cascade (2, then 1, with 0 as the fallback), compares sampled depth with biases of 0.002, 0.008, and 0.02 respectively, and returns 0.5 for shadowed color or 1.0 otherwise. The callers multiply RGB by this factor, preserve alpha, and discard fragments with alpha below 0.25 in the visible pass. The mesh shadow path renders geometry without sampling that alpha texture, so transparent cutouts and shadows need separate validation.

## Lighting contract and extension plan

The current renderer supports one directional light per rendered scene. Call `try scene.addDirectionalLight(params)` during setup, before the scene is drawn. The scene stores the light by value in `scene.directional_light`; a second addition returns `error.DirectionalLightAlreadyExists` and leaves the existing light and cascades unchanged. Scene creation starts with no light so setup and teardown can run without one. Drawing an active scene without a configured light is a programming error and panics with a setup instruction, before any passes are encoded.

Both shadow and forward passes use this same directional light. Its three cascades own the three shared shadow layers for the current scene's frame. Lights need no separate allocation or teardown. To change the configured light, update `scene.directional_light.?.params`; the next draw refits the cascades. Color and intensity are stored in `DirectionalLightParams`, but current shading uses only shadow attenuation and does not consume those fields. This contract does not yet provide diffuse/specular lighting.

The intended future contract is **at most one directional light, plus multiple point lights and multiple spot lights in the same scene**. Point and spot lights are planned, with no immediate implementation priority. Keep the directional slot separate from future collections of local lights; a list of directional lights does not express this contract.

Adding local lights will require:

- Point and spot parameters and scene collections, including positions, ranges, and spot cones.
- GPU light data and shading that accumulates contributions from all supported lights, including their color and intensity.
- A shadow allocation strategy for lights that cast shadows: directional cascades, point-light faces, and spot-light projections must have distinct allocations. The existing three directional layers cannot be reused by every light.
- Defined behavior for scenes without a directional light, practical local-light limits, and regression coverage for mixed light types and shadows.

The accumulation method, local-light limits, and which local lights cast shadows remain decisions for that work. This refactor enforces the current contract without adding speculative local-light APIs or reserving GPU storage for them.

## SSAO and final composition

SSAO uses a 16-sample kernel and a repeated 4-by-4 noise pattern. Depth is reconstructed into view space using the inverse projection. The sample radius is 0.5 and bias is 0.025. Normal values are encoded from [-1, 1] into [0, 1] and decoded in the SSAO shader.

The final shader optionally applies a weighted 3-by-3 blur to the SSAO texture, multiplies RGB by the resulting occlusion factor, and preserves alpha. Debug mode displays the factor as grayscale. E, R, and B control enablement, debug display, and blur respectively.

## Resize and diagnostics

After presentation reports a swapchain resize, the loop updates screen size/aspect ratio and recreates the depth, color, normal, and SSAO textures. The next scene update refreshes the camera projection.

Before each GUI frame, the engine reads the window's current content scale and framebuffer density. On macOS, GUI layout and mouse input use GLFW logical window units, with framebuffer density applied during rendering; layout scaling accounts for that density so Retina scaling is applied once. For example, a 1280×820 window can have a 2560×1640 framebuffer while the mouse center is (640, 410). zgui's combined `backend.newFrame` wrapper prepares both backends, but then replaces GLFW's logical display size with framebuffer dimensions and forces framebuffer scale to 1, causing widget hit tests to disagree with the visible cursor. The application calls the WGPU and GLFW frame preparation functions directly, then `zgui.newFrame` to start the core ImGui frame with GLFW's matching display and mouse units. The core call alone does not prepare either backend. This behavior is present in both the previous and updated zgui revisions; updating the dependency alone does not fix it.

Other platforms retain the existing combined wrapper. A separate, pre-existing issue remains in zgui's GLFW mouse conversion: it multiplies cursor positions by content scale on Windows even though GLFW window size, framebuffer size, and cursor positions already use matching client pixel units. At 200% content scale, a cursor at (640, 410) is therefore submitted to ImGui as (1280, 820) without a corresponding change to display dimensions. The macOS workaround does not address this Windows issue, and the menu's injected display-unit mouse tests do not exercise the native backend conversion. Switching frame preparation calls alone would not remove that multiplication.

DPI changes restore GUI dimensions from the unscaled style before resizing them, avoiding rounding drift during repeated monitor changes. The voxel crosshair and message layout use this same scale; message fonts keep their unscaled 14px and 20px sizes, which the GUI scales and rasterizes for the current display.

**Review point:** `recreateScreenDependantTextures` recreates those textures, but does not recreate the SSAO/final bind groups that were constructed with their original views. The static code path therefore does not establish correct rebinding after resize. This is an implementation concern to verify, not a documented promise that resizing is complete.

Frame statistics include candidate object count, uploaded instance-range size, visibility-index counters, and shadow/main-pass elapsed times. The timers wrap CPU pass encoding; they are not GPU timestamp measurements. The object count is the queried ordinary-object list length, excluding voxel face draws and the separate cubemap skybox.

## Sources and verification

- [`engine.zig`](../src/engine/engine.zig): `draw`, `drawGameObject`, `drawGameObjectToShadowMap`, transform adjustment, and resize handling.
- [`light.zig`](../src/engine/light.zig): cascade fitting and camera-relative origins.
- [`lighting_tests.zig`](../src/engine/lighting_tests.zig): single-light setup and rejection of a second directional light without changing existing state.
- [`pipelines.zig`](../src/engine/pipelines.zig), [`pipelines/`](../src/engine/pipelines), and [`bind_group_layouts/`](../src/engine/bind_group_layouts): pipeline and binding configuration.
- [`shaders/basic/`](../src/engine/shaders/basic), [`shaders/voxel/`](../src/engine/shaders/voxel), [`shaders/shadow_map/`](../src/engine/shaders/shadow_map), and [`shaders/quad/`](../src/engine/shaders/quad): vertex generation, shadow comparisons, and post-processing.
- [`render_coordinates_tests.zig`](../src/engine/render_coordinates_tests.zig): agreement of camera/shadow projections and translation invariance across all cascades.
- [`world_shader_tests.zig`](../src/engine/world_shader_tests.zig), [`world_coordinate_readback.zig`](../src/engine/world_coordinate_readback.zig): headless production-pipeline validation, cache lifetimes, and numerical GPU/CPU coordinate comparison through compute/readback.
- [`material_readback.zig`](../src/engine/material_readback.zig): production WGSL color/UV readback with a transparent atlas sample, checking opaque water/leaves, the steppe top tint, and frozen top/soil UVs.
- [`world_engine_glue.zig`](../src/voxel_app/world_engine_glue.zig), [`persistence/format.zig`](../src/voxel_app/persistence/format.zig): climate appearance selection without changing saved materials, and rejection of render-only IDs from saved blocks and inventories.
- [`voxel_tests.zig`](../src/engine/voxel_tests.zig): face/upload data and allocator behavior without creating a GPU device.
- [`construction_layer_readback.zig`](../src/engine/construction_layer_readback.zig): production voxel color/depth comparison before, during, and after a nonempty terrain/construction layer handoff.

`zig build test` exercises the registered CPU tests under both application wrapping configurations. `zig build test-gpu` separately validates the eight specialized pipelines and their cache sharing, reference lifetimes, and allocation cleanup with headless Dawn in each compiled wrapping mode. It also validates the height-map pipeline, covering every pipeline that embeds the shared shadow sampler, and executes the production coordinate helper to compare GPU readback with CPU results at seams, half-period ties, f32 precision boundaries, and signed i32 limits, using three world widths. Its material readback executes the shared production color and UV helpers for all ordinary material IDs and all six face directions. These checks do not replace a runtime visual check of rendering, alpha/shadow agreement, SSAO, or resize.
