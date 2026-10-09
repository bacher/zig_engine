# Scene and model lifetime

The ownership policy investigated on 2026-10-09 is implemented. Applications control scene lifetime; the engine owns shared models created through its helpers.

## Built-in and application-requested models

`Engine.init` creates one built-in model: `cube_wireframe_model`, used by `drawDebugCubeWireframe` for debug bounds. The regular-model registry starts empty. Applications request every other model load.

| Model | Creation trigger | Destruction owner | Example purpose |
| --- | --- | --- | --- |
| Wireframe cube | Engine initialization | Engine | Debug object bounds. |
| Regular glTF model | Application via `loadModel` | Engine | Characters and imported scene meshes. |
| Cubemap skybox | Application helper | Engine | Scene background. |
| Older skybox | Application helper; disabled in examples | Engine | Scene background. |
| Window box | Application helper | Engine | Textured geometry example. |
| Primitive | Application via `loadPrimitive` | Engine | Coordinate axes; the API accepts arbitrary geometry. |
| Height-map terrain | Demo via `createTerrainHeightMapModel` | Engine | Scene terrain. |

The UV-test texture is an engine-initialized debug/fallback asset. The voxel atlas, render targets, samplers, and pipelines are rendering resources rather than models. The built-in model is diagnostic; registered regular models are ordinary application content.

## Ownership contract

- Applications own the window/graphics context and scenes. Destroy every scene before its engine, and the engine before the graphics context. Stop workers that use scene state before destroying scenes.
- The engine owns every model returned by its creation/loading helpers. IDs and pointers are borrowed references valid until engine teardown. Applications choose which assets to load without taking over destruction.
- Scenes own objects, every scene-created group independently of parenting, cameras, lights, voxel resources, and instance resources. Objects borrow models and own only instance state, including animation players. `GameObject.deinit` never destroys a model.
- Models own geometry and textures they create. Regular descriptors track whether their color texture was loaded from a material or borrowed as a fallback. Engine samplers and the wireframe's line bind group are borrowed dependencies.
- `loadTexture` returns a caller-owned texture. Terrain creation borrows all input textures, and custom regular-model fallback textures are borrowed. Their owners must keep them alive until every borrowing model is gone, normally until after engine teardown, then call `TextureDescriptor.deinit(gctx)`. Descriptor copying does not transfer ownership.

A scene is a replaceable collection of instances, while a model can be shared by several scenes. This is why scene and model owners differ. Regular and special models now follow the same ownership contract.

## Cleanup behavior

Scene teardown clears its active-scene pointer, destroys objects while groups and the visibility index are alive, releases voxel and instance bindings before their buffers, and releases its world-pipeline reference. Engine teardown checks the live-scene count and empty pipeline cache before releasing models and common resources.

Regular models are retained in the ID registry; special models are retained in a separate typed union list. Teardown releases each model's owned binding, geometry, material texture, and animation data. The wireframe releases its geometry while leaving its shared line binding for the engine to release once. Engine cleanup includes render/shadow textures and views, seven common bindings, samplers, pipelines, layouts, identity joints, and the SSAO kernel. Input cleanup disconnects the GLFW callback and clears the controller singleton.

Screen resize releases the old screen bindings before their textures and constructs replacement bindings against the new targets. Loading failures roll back successful acquisitions. Cubemap filename/image arrays use completed-element counts; skybox geometry and animation-data construction also clean up partial allocations.

The examples no longer destroy model pointers. The demo releases standalone terrain textures after the engine. The voxel application stops workers before scene teardown, including partial world initialization.

## Retention tradeoff

Models remain allocated until engine teardown. Replacing a skybox or destroying a scene retains its assets, allowing other scenes to share them. Reclaiming assets during long-running scene switching would require an explicit unloading API, asset scopes, or retained handles. The subsequent [scene mutation implementation](scenes.md#scene-mutation-contract) adds gameplay object/group removal, reusable slots, and growing ordinary-instance storage while preserving engine ownership of shared models. Automatic scene destruction, model unloading, and a texture cache remain separate concerns. Voxel residency is unchanged; its [capacity and lifetime follow-ups](voxel-world.md#deferred-capacity-and-lifetime-work) are deferred.

## Verification

CPU hierarchy tests check that terrain instances borrow a shared model. Headless Dawn tests under both wrapping configurations count live handles with the graphics context still alive, exercise two scenes sharing terrain and an animated regular model, tear down animation players, and repeat engine resource teardown/recreation. Allocation-failure injection covers scene construction and regular/special model loading. The graphics context's mipmap cache and uniform staging buffers are retained separately from engine resources.

The headless fixture constructs engine resources without a GLFW window and invokes the real scene/model/engine teardown paths. It does not establish interactive rendering appearance, actual `Engine.init` window setup, or input callback behavior. The existing pipeline and coordinate readback checks remain part of `zig build test-gpu`.

## Sources

- [`engine.zig`](../src/engine/engine.zig), [`model.zig`](../src/engine/model.zig): shared model ownership, helper rollback, engine teardown.
- [`scene.zig`](../src/engine/scene.zig), [`game_object.zig`](../src/engine/game_object.zig): instance ownership and teardown order.
- [`display_object_descriptors/`](../src/engine/display_object_descriptors), [`types.zig`](../src/engine/types.zig): geometry/texture cleanup and borrowed fallbacks.
- [`world_pipeline_cache.zig`](../src/engine/world_pipeline_cache.zig): final-reference eviction.
- [`resource_lifetime_tests.zig`](../src/engine/resource_lifetime_tests.zig), [`hierarchy_tests.zig`](../src/engine/hierarchy_tests.zig): lifetime and failure checks.
- [`src/demo_app/main.zig`](../src/demo_app/main.zig), [`src/voxel_app/main.zig`](../src/voxel_app/main.zig): application cleanup order.
