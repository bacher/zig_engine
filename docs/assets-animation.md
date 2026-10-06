# Assets and skeletal animation

Asset loading creates shared model data; scene object creation supplies placement and optional independent animation playback. The current asset path supports a subset of glTF and several engine-specific model types.

## Regular model loading

The usual sequence is:

1. `Engine.initLoader` opens a glTF file relative to `engine.content_dir`.
2. The caller finds a `SceneObject` with a mesh.
3. `Engine.loadModel` uploads geometry and a base-color texture, optionally copies named animations, registers a `Model`, and returns a `LoadedModelId`.
4. The caller can destroy the loader after loading. Runtime animation data owns its own copies; geometry has been uploaded.
5. `Scene.addObject` looks up the ID and creates an instance at an application-supplied transform. The model can be shared by several objects.

`loadModel` handles a selected mesh node, not automatic instantiation of the entire glTF scene hierarchy. The demo has application-specific traversal code for groups/node matrices. Importing an asset's scene placement and importing its mesh data are separate operations.

Options select Y-up conversion, spherical/cylindrical billboarding, animation names to load, and an optional fallback texture. Without a supplied fallback, the engine supplies its UV-test texture. Model geometry stays in asset-local `f32` coordinates; world placement uses the scene's `f64` transform path.

## Loader scope

The local loader reads JSON glTF and external files. The inspected model-buffer path asserts one scene, one primitive per mesh, and one binary buffer. It expects indexed geometry with POSITION, NORMAL, and TEXCOORD_0; JOINTS_0 and WEIGHTS_0 are optional.

Accessors are loaded using buffer/accessor offsets and a contiguous calculated byte range. The path does not implement interleaved accessor strides or a general sparse-accessor expansion. It should not be read as a general-purpose glTF/GLB importer.

The selected primitive's material supplies a base-color image URI, resolved relative to the glTF directory. This path does not build a complete physically based material from all glTF material properties. Joint indices are converted to four `u32` values per vertex; missing joints/weights get default buffers.

## Textures and special models

`Engine.loadTexture` loads the path supplied by the caller directly. Its options specify forced component count, optional GPU format, and mipmap generation. This differs from `initLoader`'s automatic content-directory prefix. Internal UV-test and voxel-atlas loads currently use explicit `content/...` paths.

Material loading generates mipmaps when the image is square. The project has an existing TODO to avoid loading the same texture several times; no shared texture cache is present in this path. Several objects sharing one registered model reuse that model's texture, but separate model loads may duplicate it.

Special helpers return pointers rather than registered model IDs: primitives, window boxes, skyboxes, cubemap skyboxes, and height-map terrain. Their descriptors and bind groups select different pipelines. Height-map terrain receives two layer textures, a mixing texture, and a height texture. The examples clean up special models explicitly.

## Animation data and player state

`SkeletalAnimationData` belongs to a regular model and is created only if the mesh has a skin and the caller requests animation names. It copies node parent relationships, base transforms, joint node indices, inverse-bind matrices, and the selected channels/keyframes.

Each animated object owns a `SkeletalAnimation` player with its own playback start time, working node transforms, global node matrices, joint matrices, GPU palette buffer, and joints bind group. Two objects can share a model/clip and animate independently.

Supported channels are translation, rotation, and scale. STEP and LINEAR interpolation are supported; rotation interpolation uses quaternion interpolation. CUBICSPLINE and morph-weight channels return unsupported errors. Clips loop over their keyframe time range; a zero-duration clip holds its start time. Switching or replaying a clip changes the active clip and resets its start time; there is no blending/crossfade path.

For each new draw time, the player:

1. Restores base node transforms and samples the active clip.
2. Computes global transforms through the imported node hierarchy.
3. Computes each palette entry as `inverse(mesh_global) * joint_global * inverse_bind`.
4. Fills unused GPU entries with identity matrices and uploads the palette.

Evaluation is triggered by visible/shadow draws. Calls repeated at the same time are skipped. The vertex shader weights four transformed positions; the current visible shader transforms normals through the object/view matrices without applying the joint deformation to normals.

The GPU palette has 64 matrices. Upload copies at most 64 computed joint matrices, and shaders index that fixed palette. This is a current format limit, not evidence of safe support for arbitrary larger skins.

`playObjectAnimation` and `switchObjectAnimation` use the same playback operation. Starting a non-regular object returns an unsupported error; requesting animation on a model without copied animation data returns an error. Stopping frees the player's buffer/bind group. **Review point:** pipeline selection still follows the model's `has_skin` flag, and inspected draw paths bind joints only when an object has a player. Rendering a skinned model before playback or after stopping needs validation; the existence of an engine identity buffer alone does not establish that fallback binding in those paths.

## Resource ownership caveats

The engine registry owns regular `Model` allocations and shared animation data. A scene owns per-object player resources. Special model pointers remain outside that registry and are usually cleaned up by the application. A model must remain valid while objects or players reference it.

The cleanup implementation is incomplete: `ModelDescriptor.deinit` is currently a no-op, and `Engine.deinit` does not explicitly destroy every texture, sampler, and bind group created during initialization. `WindowContext` later destroys the overall graphics context. These facts describe the present cleanup boundary; they do not establish leak-free independent engine/model teardown.

Height-map terrain has another asymmetry: `GameObject.deinit` destroys its model allocation, but ordinary `Scene.deinit` directly frees objects and the examples also clean up the terrain model explicitly. Ownership should be settled before adding object removal or model unloading.

## Sources and verification

- [`gltf_loader/src/root.zig`](../gltf_loader/src/root.zig), [`types.zig`](../gltf_loader/src/types.zig): glTF parsing, accessors, images, skins, and channels.
- [`engine.zig`](../src/engine/engine.zig): `initLoader`, `loadModel`, texture/special-model helpers, and teardown.
- [`model_descriptor.zig`](../src/engine/display_object_descriptors/model_descriptor.zig): geometry upload, texture fallback, and skin attributes.
- [`model.zig`](../src/engine/model.zig): shared model data and special-model wrappers.
- [`skeletal_animation.zig`](../src/engine/skeletal_animation.zig): copied data, sampling, hierarchy, palettes, and player lifetime.
- [`game_object.zig`](../src/engine/game_object.zig): start/stop/update playback and player ownership.
- [`shaders/basic/skinned_vs.wgsl`](../src/engine/shaders/basic/skinned_vs.wgsl): vertex position deformation and current normal path.
- [`src/demo_app/main.zig`](../src/demo_app/main.zig): example asset use and application-specific node traversal.

The demo and voxel app load the `walkLikeMan` clip and create separate animated objects. This is an example use, not a complete importer/animation test suite. Static inspection for this extraction did not validate asset compatibility, animation appearance, or GPU cleanup at runtime.
