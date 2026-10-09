# Scenes, objects, and input

This document describes the current implementation. For system boundaries and unresolved intent, start with [architecture](architecture.md).

## Scene state

A `Scene` holds ordinary game objects, separately owned root groups, directional lights, a camera and spectator controller, a voxel grid, and a CPU/GPU instance buffer. It also holds a dedicated cubemap skybox object. Only the engine's active scene is updated and rendered.

Ordinary objects are individually allocated and retained in `scene.game_objects`. A regular object's model is looked up by `LoadedModelId` in the engine's registry. Special objects receive a borrowed engine-owned model pointer from the caller.

The ordinary-object limit is 4096. Creation assigns the next instance index and initializes an 80-byte chunk transform entry. Indices increase as objects are added; there is no general scene removal method that removes an object from all collections and reclaims its index. Calling `GameObject.deinit` alone is not a complete scene removal operation because the scene still holds its pointer.

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

## Transform hierarchy

Each object or group has a local position, quaternion rotation, and uniform scalar scale. Root positions are world positions. Child positions are relative to their transform parent.

```text
local = translation(position) * rotation * uniform_scale
aggregated_matrix = parent.aggregated_matrix * local
```

CPU positions and accumulated matrices use `f64`; quaternion and scale inputs use `f32`. The engine derives chunk-local GPU transforms from the accumulated matrix. See [coordinates](coordinates.md) for the exact conversion rules.

Groups can contain objects and other groups. Creating a child group attaches it immediately. Creating an object with a parent registers it for that parent's updates. Setters rebuild accumulated transforms, propagate group changes through descendants, refresh object visibility registration, and mark affected instance entries dirty.

Reparenting preserves the local transform. Consequently, world position may change. It does not implement a keep-world-position operation. Repeated attachment is deduplicated, and group reparenting asserts that the parent chain would not introduce a cycle.

Transform parenting and allocation ownership are separate. A group created by another group stays in its creator's `owned_groups` list even after reparenting. Scene-created groups stay owned by the scene. Recursive destruction follows allocation ownership, not the current transform tree.

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

The scene then releases groups, cameras, lights, voxel resources (binding before buffers), instance resources, layout, and its reference to the engine's world pipeline cache. The final scene reference evicts the shared pipeline set. Engine teardown asserts that no scenes remain. Destroying the active scene leaves no active scene; the application can explicitly select another or create a new one.

Models survive scene destruction and are released at engine teardown. Calling `GameObject.deinit` directly still does not remove an ordinary object from the scene's owning collection or reclaim its instance index; a complete public object-removal API remains a separate review point.

## Sources and tests

- [`scene.zig`](../src/engine/scene.zig): creation, ownership, instance updates, and scene update.
- [`game_object.zig`](../src/engine/game_object.zig) and [`game_object_group.zig`](../src/engine/game_object_group.zig): transforms, attachment, and animation lifetime.
- [`engine.zig`](../src/engine/engine.zig): `runLoop`, `update`, `draw`, and `getRenderTransform`.
- [`input_controller.zig`](../src/engine/input_controller.zig), [`spectator_camera.zig`](../src/engine/spectator_camera.zig), [`camera.zig`](../src/engine/camera.zig): controls and projection.
- [`resource_lifetime_tests.zig`](../src/engine/resource_lifetime_tests.zig): headless shared-model and scene/engine resource lifetime checks, including allocation failures.
- [`hierarchy_tests.zig`](../src/engine/hierarchy_tests.zig): nested transforms, parent updates, reparenting, ownership, and dirty instances at large positions.
- [`render_coordinates_tests.zig`](../src/engine/render_coordinates_tests.zig): camera precision and rendering-frame invariance.
- [`naive_space_tree.zig`](../src/engine/naive_space_tree.zig): query, deduplication, and removal test for the active visibility index.
