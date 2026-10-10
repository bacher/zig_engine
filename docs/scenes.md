# Scenes, objects, and input

This document describes the current implementation. For system boundaries and unresolved intent, start with [architecture](architecture.md).

## Scene state

A `Scene` holds ordinary game objects, a flat registry of owned groups, one optional directional-light value, a camera and spectator controller, a voxel grid, and a CPU/GPU instance buffer. It also holds a dedicated cubemap skybox object. Only the engine's active scene is updated and rendered. Configure its directional light with `addDirectionalLight` before drawing; a second addition is rejected. See the [lighting contract](rendering.md#lighting-contract-and-extension-plan) for current requirements and future point/spot support.

Ordinary objects are individually allocated and retained in `scene.game_objects`. A regular object's model is looked up by `LoadedModelId` in the engine's registry. Special objects receive a borrowed engine-owned model pointer from the caller.

Ordinary-object storage starts with up to 64 transform slots and grows as needed. Each slot holds an 80-byte chunk transform entry. The maximum capacity is derived from the device's buffer and storage-binding size limits, bounded by the index representation and CPU address space; CPU allocation can fail earlier. The old arbitrary 4096-object cap has been removed. Deleted objects' indices return to a free list and are reused before more slots are added. Storage retains its capacity for future objects.

Use `Scene.removeObject` for individual removal. It detaches the object from its transform parent and visibility index, removes it from the scene's owning collection, stops animation, releases instance state, and returns its transform slot to the free list. `GameObject.deinit` is low-level teardown for construction rollback and scene cleanup; calling it directly on a scene-owned object bypasses collection and slot bookkeeping.

The cubemap skybox is an exception: it has no instance index, bypasses the visibility index, and is replaced/destroyed through `setSkyBoxCubemapObject`. The older skybox path creates an ordinary scene object with an instance index.

## Object types

`GameObject.model` is a tagged union selecting the render path:

| Type | Data and behavior |
| --- | --- |
| Regular model | Indexed mesh, texture, optional skin and loaded animations. Multiple objects share model data. |
| Colorized primitive | Generated vertex geometry and per-object `debug.color`. |
| Window box | Box geometry and a texture, with camera position supplied in model space. |
| Height-map terrain | GPU bindings for texture-based terrain generation. |
| Skybox | Older textured skybox mesh. |
| Cubemap skybox | Dedicated background object using six texture faces. |

Voxels are held in `scene.voxel_grid`, outside the ordinary object collection. Block contents, revisions, and streaming are application/service responsibilities.

## Scene mutation contract

The owner confirmed the gameplay requirements on 2026-10-09. Applications can create and delete ordinary objects throughout a scene's lifetime. Repeated creation/deletion reuses available slots, so the total number of objects ever created does not impose a capacity limit.

Use `Scene.removeGroup` to delete a group and all of its current transform descendants, including nested groups and their objects. Objects and groups reparented out of that subtree survive; those reparented into it are deleted. Objects and their parents must belong to the same scene. Group creation through `Scene.addGroup` or a scene group's `addGroup` registers every new group with the scene, independently of its parent.

```zig
const enemy = try scene.addObject(.{
    .model_id = enemy_model_id,
    .position = .{ 0, 0, 0 },
    .parent = null,
});
// Later, during gameplay update:
try scene.removeObject(enemy);
try scene.removeGroup(car_group); // Also removes its current parts and subgroups.
```

Mutations run synchronously on the application thread before drawing, including `onUpdate` and key-press callbacks. Addition/removal during drawing returns `SceneMutationDuringDraw`; reparenting during drawing panics because the existing setter API has no error return. Apply changes requested by `onRender` in the next update. Scene teardown during drawing is prohibited. These APIs are not thread-safe.

Successful removal immediately invalidates every application-held pointer to the deleted object/group, including pointers held in application maps. Applications must clear those references and must not use them again. Removal with a live object/group from another scene returns `ObjectNotInScene`/`GroupNotInScene`; creation or attachment with a foreign parent returns `GroupBelongsToAnotherScene`, while the void reparenting setters enforce same-scene parenting as a precondition. Removal does not destroy shared models, which remain engine-owned. The dedicated cubemap skybox uses its replacement API and cannot be attached to an ordinary group.

Deletion does not allocate. Free-list capacity is reserved with instance storage, and freed CPU transform entries are cleared so uploads spanning holes read initialized data. Allocation failures during creation roll back partial object/animation state, parent attachment, visibility registration, and slot reservation. Existing objects remain valid; storage or draw scratch capacity may have grown before a later construction step fails.

Capacity grows geometrically up to the device-derived maximum. Growth allocates CPU transforms and dirty-index tracking, creates a new GPU buffer and binding, and seeds it with existing transforms. The old binding/buffer references are released, allowing submitted GPU work to retain the old buffer. Draw preparation refreshes dirty entries and uploads the affected range. Renderer visibility lists also grow, and their counts use `usize` rather than a 16-bit count. `SceneCapacityReached` reports exhaustion of the supported slot count; CPU storage/scratch allocation failures return `OutOfMemory`. The pinned zgpu resource-creation API does not provide synchronous recovery from GPU out-of-memory or device loss; those remain graphics-context concerns.

CPU tests cover 5,000 create/delete cycles, hierarchy and visibility detachment, recursive deletion after reparenting, foreign membership, drawing guards, allocation-free removal, capacity exhaustion, and visibility lists exceeding 65,535 entries. Headless Dawn tests cover growth past 4096 live regular objects, GPU transform readback after growth and reuse, animation cleanup, shared-model survival, and injected allocation failures in scene and draw storage under both wrapping configurations. These do not replace an interactive rendering check.

Voxel chunks use separate residency and upload allocators. Their behavior is unchanged; see the [deferred voxel capacity and lifetime work](voxel-world.md#deferred-capacity-and-lifetime-work).

## Transform hierarchy

Each object or group has a local position, quaternion rotation, and uniform scalar scale. Root positions are world positions. Child positions are relative to their transform parent.

```text
local = translation(position) * rotation * uniform_scale
aggregated_matrix = parent.aggregated_matrix * local
```

CPU positions and accumulated matrices use `f64`; quaternion and scale inputs use `f32`. The engine derives chunk-local GPU transforms from the accumulated matrix. See [coordinates](coordinates.md) for the exact conversion rules.

Groups can contain objects and other groups. Creating a child group attaches it immediately. Creating an object with a parent registers it for that parent's updates. Setters rebuild accumulated transforms, propagate group changes through descendants, refresh object visibility registration, and mark affected instance entries dirty.

Reparenting preserves the local transform. Consequently, world position may change. It does not implement a keep-world-position operation. Repeated attachment is deduplicated, and group reparenting asserts that the parent chain would not introduce a cycle.

Transform parenting and allocation ownership are separate. A scene owns all its groups in one flat registry, including groups created through other scene groups. Reparenting does not transfer scene ownership. Gameplay group deletion follows current transform descendants; whole-scene teardown releases every registered group, including detached groups. Standalone groups created directly with `GameObjectGroup.init` retain creator-based `owned_groups` cleanup and must not be mixed into a scene hierarchy; `deinit_recursively` is for those standalone groups.

Use setters for changes. Assigning `position`, `rotation`, or `scale` directly bypasses matrix recomputation and GPU invalidation.

## GPU transform updates

Object creation writes the CPU instance entry and marks it dirty. `prepareForRendering` uploads the initial populated range before the loop. During drawing, queried objects have their dirty entries recomputed; billboards are recomputed regardless of the dirty flag because their orientation depends on the camera.

The engine uploads one contiguous range from the lowest updated index to the highest. This can include unchanged entries between dirty objects. The `instances_written_count` statistic counts that range, not just changed objects.

Regular objects can request spherical or cylindrical billboarding. Rendering replaces their rotation using the camera-relative direction while preserving translation and extracted scale. A `mesh_y_up` option then applies the model's Y-up to engine Z-up conversion. These are render-transform adjustments; they do not rewrite the stored local transform.

## Visibility behavior

The active scene imports `naive_space_tree.zig`. It is an ArrayList of object pointers: add is deduplicated, removal uses swap removal, and every bounding-box query returns every registered object. Camera and shadow queries therefore perform no spatial culling.

The original `space_tree.zig` remains in the repository and has a separate test target. It is not the active implementation. It still uses assumptions from the older float coordinate path and needs migration before replacing the temporary index.

Voxels use a separate residency loop and directional face selection. The absence of ordinary-object spatial culling does not mean that hidden voxel faces are generated.

## Input and camera controls

The camera uses a right-handed view with engine Z as up. Its current projection is a 45-degree vertical field of view, near distance 0.01, and far distance 200. Aspect ratio changes rebuild projection matrices.

The default scene has a spectator controller:

| Input | Behavior |
| --- | --- |
| W / S | Move forward/backward in the camera's orientation. |
| A / D | Strafe left/right. Horizontal diagonal input is normalized. |
| Space / C | Move along world +Z / -Z. |
| Hold left mouse button and move mouse | Capture the cursor and change yaw/pitch. Release restores the cursor. |
| Escape | Leave the engine loop. |
| E | Toggle SSAO; exits SSAO debug mode if it was active. |
| R | Toggle SSAO debug display, enabling SSAO when entering it. |
| B | Toggle SSAO blur. |
| Z / X in the voxel app | Place dirt / remove a block below the camera within tool reach. |

Movement uses a base speed of 5 world units per second and elapsed frame time. There is no collision, gravity, or terrain constraint in `SpectatorCamera`; it can move through solid terrain. Pitch is not explicitly clamped.

`InputController` retains held keys. Press/repeat events update that state, but the application key-press callback fires only for a press. Released keys are excluded from held-key queries immediately and removed from storage at frame end. Press edges survive a same-frame release, so short Escape taps still exit. Mouse state is polled each frame. Cursor capture can follow the left button or remain enabled continuously; supported platforms use raw mouse motion while captured. Capture/focus transitions reset cursor deltas, and focus loss clears held keys.

## Player controls and timing

The voxel application owns `PlayerController`; the engine renders its camera and exposes input/time. The voxel app disables the scene's default spectator updates in player mode. Ordinary scene objects and groups have no player colliders.

One block/world unit is one metre. The default body is an upright 0.6m-wide, 1.8m-tall box with eyes 1.6m above its feet. W/A/S/D move horizontally relative to yaw at 5m/s, with normalized diagonal input; pitch only affects the view and is clamped near vertical. Mouse movement controls view continuously without a held button. Gravity is 10m/s² and a grounded Space press gives 5m/s upward velocity, reaching about 1.25m. A press/release between rendered frames still produces one jump.

Holding Space for 0.25 seconds enables automatic one-block climbing while walking. Pressing Space while already airborne enables climbing immediately, only while the key remains held. This branch experiments with a collision-safe S-shaped approach: a bounded preview finds a step up to 0.25 seconds of walking ahead (1.25 metres at full speed), then the body rises with easing at both ends while moving forward. Grounded step ascents take 0.25 seconds. Airborne lip catches shorten the ascent to target 90% of walking speed, with a minimum duration proportional to the rise so late catches still limit upward speed. The feet reach the top one millimetre before the full box meets the block face, followed by a 0.1-metre level exit onto supporting terrain. Ordinary approaches keep close to walking speed throughout; starting the climb late slows its forward approach, and starting already against the face still requires a vertical rise. The box collider and camera offset remain unchanged, and the body never intentionally overlaps terrain.

Climbing can start without ground support, allowing held Space to catch the far lip of a deep one-metre hole when both sides have the same ground level. The top must be within the horizontal preview range and at most one metre above grounded feet or half a metre above airborne feet. Ascents exceeding half a metre also require footing just before the block face, preventing a grounded preview from carrying the player across a hole onto a raised far edge. A far edge one block higher requires jumping first; release Space, then press and hold it again in flight to enable climbing immediately. Every landing is capped at one metre above the last standing surface, so a jump cannot enable climbing a two-block column. A clear swept path up/across/down and a landing are required, and low ceilings still obstruct movement. The remaining path and landing are rechecked against current block data every movement substep, with ordinary axis sweeps also checking the actual ascent. Releasing Space or movement, turning more than 30 degrees away from the planned direction, losing the landing, or encountering an obstruction cancels the ascent and resumes gravity. A canceled climb can restart after ground contact or a fresh airborne Space press. Smaller mouse-look adjustments preserve the short planned path. Missing chunks block the preview and ascent as solid terrain and continue to report missing data. Holding Space does not repeatedly jump. C has no player movement action.

The player consumes the full monotonic frame interval using internal steps at most 1/120 second, including the last partial step. Steps also split at held-Space activation, entry into climb preview range, and climb completion, keeping ascent timing consistent across frame rates and fractional frames. Input therefore updates every frame at any frame rate rather than waiting for a fixed player tick. Axis sweeps stop at cube faces and allow wall sliding, including during long movements/fast falls. World-service replies and GPU geometry do not gate movement. See [simulation timing](architecture.md#initialization-and-frame-order) for the independent future world tick.

Q enters debug spectator mode at the player's current eye position and orientation. The player and its velocity freeze, and its surrounding block chunks remain subscribed. Q returns to that player's position and view; it does not teleport the body to the spectator camera. Every later excursion starts at the player again. Player history continues to expire during spectating. Focus loss freezes controls, releases capture, and clears jump/held input; focus regain resumes without integrating the paused frame interval.

Movement collision is a fixed property of `BlockType` in `terrain_collision.zig`. Air has none; stone, dirt, grass-covered ground, water, sand, and snow currently use full cubes. Water remains solid pending fluid movement. Future decorative types can map to no collision independently of rendering/occupancy. No per-block instance collision state exists. X wraps using the current world layout; finite y/z storage edges act as walls.

Unknown chunks act as fully solid and stderr reports the encountered chunk, once per continuous contact with that chunk. When the body's starting volume is unknown, movement waits in place until data arrives. Recovery searches only accept known clear body-sized space.

When an optimistic edit, worker snapshot, or reconciliation embeds the body in solid terrain, recovery tries nearby foot cells first, then the newest still-clear position from at most five seconds of history, then the nearest clear candidate within eight metres. History stores foot-cell coordinates and timestamps, deduplicating consecutive visits to the same cell. Restoration centres the body horizontally in that cell with feet on its bottom face and resets vertical velocity. All candidates are checked against current block data and the entire body. If none fits, movement freezes, stderr warns, and recovery retries on delivered terrain changes or once per second. A final failure policy is deferred in `TODO.md`.

The initial voxel player spawns above the generated terrain and falls onto it. Column placement validates the candidate block against the body before changing the optimistic cache, also while the body is frozen during spectating.

CPU regressions cover frame-time movement/gravity, short frames, diagonal/yaw movement, fast falls/wall sliding, jump edges/ceilings, anticipated forward/upward climbing across frame rates, speed during airborne lip catches over deep one-cell holes, jumping before climbing onto raised far edges, immediate airborne Space activation and cancellation on release, climb height limits and rejection of jump-assisted two-block climbs, full-box clearance at every substep, diagonal and consecutive stairs, climb cancellation on input/terrain changes, missing-data blocking, recovery ordering/expiration/bounds, periodic seams, Q transitions, player streaming pins, and placement rejection. Cursor capture and interactive movement still require a windowed check.

## Lifetime

Applications destroy their scenes before the engine. `Scene.deinit` clears `engine.active_scene` if it points to that scene and decrements the engine's live-scene count. It destroys both ordinary objects and the dedicated skybox through `GameObject.deinit`, while parent groups and the visibility index still exist. That path detaches objects, removes their visibility entries, and stops animations; it never destroys borrowed models.

The scene then releases groups, cameras, voxel resources (binding before buffers), instance resources, layout, and its reference to the engine's world pipeline cache. The final scene reference evicts the shared pipeline set. Engine teardown asserts that no scenes remain. Destroying the active scene leaves no active scene; the application can explicitly select another or create a new one.

Models survive scene destruction and are released at engine teardown. For individual gameplay removal, use `Scene.removeObject` or `Scene.removeGroup`, which also update scene ownership and instance-slot bookkeeping.

## Sources and tests

- [`scene.zig`](../src/engine/scene.zig): creation, ownership, instance updates, and scene update.
- [`game_object.zig`](../src/engine/game_object.zig) and [`game_object_group.zig`](../src/engine/game_object_group.zig): transforms, attachment, and animation lifetime.
- [`engine.zig`](../src/engine/engine.zig): `runLoop`, `update`, `draw`, and `getRenderTransform`.
- [`input_controller.zig`](../src/engine/input_controller.zig), [`spectator_camera.zig`](../src/engine/spectator_camera.zig), [`camera.zig`](../src/engine/camera.zig): controls and projection.
- [`player_controller.zig`](../src/voxel_app/player_controller.zig), [`terrain_collision.zig`](../src/voxel_app/terrain_collision.zig): player physics/recovery and terrain collision regression tests. [`main.zig`](../src/voxel_app/main.zig) contains Q, streaming-pin, and placement integration tests.
- [`resource_lifetime_tests.zig`](../src/engine/resource_lifetime_tests.zig): headless shared-model and scene/engine resource lifetime checks, including allocation failures.
- [`hierarchy_tests.zig`](../src/engine/hierarchy_tests.zig): nested transforms, parent updates, reparenting, ownership, and dirty instances at large positions.
- [`render_coordinates_tests.zig`](../src/engine/render_coordinates_tests.zig): camera precision and rendering-frame invariance.
- [`naive_space_tree.zig`](../src/engine/naive_space_tree.zig): query, deduplication, and removal test for the active visibility index.
