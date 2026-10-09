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

`InputController` retains held keys. Press/repeat events update that state, but the application key-press callback fires only for a press. Releases are removed at the end of the frame, so a key released during event polling remains visible to that frame's movement update. Mouse state is polled each frame; unusually large deltas are suppressed at short frame intervals.

## Lifetime

Applications destroy their scenes before the engine. `Scene.deinit` clears `engine.active_scene` if it points to that scene and decrements the engine's live-scene count. It destroys both ordinary objects and the dedicated skybox through `GameObject.deinit`, while parent groups and the visibility index still exist. That path detaches objects, removes their visibility entries, and stops animations; it never destroys borrowed models.

The scene then releases groups, cameras, voxel resources (binding before buffers), instance resources, layout, and its reference to the engine's world pipeline cache. The final scene reference evicts the shared pipeline set. Engine teardown asserts that no scenes remain. Destroying the active scene leaves no active scene; the application can explicitly select another or create a new one.

Models survive scene destruction and are released at engine teardown. For individual gameplay removal, use `Scene.removeObject` or `Scene.removeGroup`, which also update scene ownership and instance-slot bookkeeping.

## Sources and tests

- [`scene.zig`](../src/engine/scene.zig): creation, ownership, instance updates, and scene update.
- [`game_object.zig`](../src/engine/game_object.zig) and [`game_object_group.zig`](../src/engine/game_object_group.zig): transforms, attachment, and animation lifetime.
- [`engine.zig`](../src/engine/engine.zig): `runLoop`, `update`, `draw`, and `getRenderTransform`.
- [`input_controller.zig`](../src/engine/input_controller.zig), [`spectator_camera.zig`](../src/engine/spectator_camera.zig), [`camera.zig`](../src/engine/camera.zig): controls and projection.
- [`resource_lifetime_tests.zig`](../src/engine/resource_lifetime_tests.zig): headless shared-model and scene/engine resource lifetime checks, including allocation failures.
- [`hierarchy_tests.zig`](../src/engine/hierarchy_tests.zig): nested transforms, parent updates, reparenting, ownership, and dirty instances at large positions.
- [`render_coordinates_tests.zig`](../src/engine/render_coordinates_tests.zig): camera precision and rendering-frame invariance.
- [`naive_space_tree.zig`](../src/engine/naive_space_tree.zig): query, deduplication, and removal test for the active visibility index.
