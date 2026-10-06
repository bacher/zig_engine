# Coordinates and rendering precision

CPU world positions use `f64`. GPU positions use `f32` after removing a chunk origin. Chunks are a rendering and voxel-storage representation; game code can continue to use ordinary world coordinates.

## CPU positions and parent transforms

`world_math.Position` is `@Vector(3, f64)`. Cameras, game objects, groups, and scene object-creation parameters use this type. `world_math.Mat` contains four `@Vector(4, f64)` columns, using the same column convention as WGSL and zmath.

Coordinate operations use elementwise vector arithmetic, including camera movement (`position + delta`), chunk division/modulo, and voxel lookup. Use `@as(world_math.Position, @splat(value))` to broadcast a scalar across all three axes. Matrix composition already uses four-component vector arithmetic. These expressions let Zig lower operations to SIMD where the target supports it; they do not imply a measured speedup, and a three-component vector may use multiple instructions. The special x-axis wrapping remains separate from y/z bounds handling.

An object's or group's `position`, `rotation`, and `scale` describe its transform relative to its parent. A root's position is in world space. Its `aggregated_matrix` is the accumulated world transform:

```text
local = translation(position) * rotation * uniform_scale
world = parent.world * local
```

Translations and matrix composition stay in `f64`. Quaternions and scalar scale inputs remain `f32`; they contain no world-origin translation and are widened before composing matrices. Asset vertices, mesh bounds, and skeletal joint transforms remain in model-local `f32` space.

Creating a child group attaches it to its parent immediately. Creating an object with a parent registers it for parent updates. Changes to a parent rebuild descendant world matrices and mark descendant GPU instances dirty without changing their local positions. Reparenting preserves the local transform, so the object's world position can change. Repeated attachment does not add duplicate child entries. Group allocation ownership stays with its creator independently of transform parenting, so reparenting does not duplicate destruction.

Use setters to update transforms. Directly modifying `position` bypasses matrix updates and GPU invalidation. `Camera.translate` accumulates movement into its `f64` position; the spectator controller uses this path.

## Conversion to GPU coordinates

`ChunkTransform.init` is the boundary between an accumulated CPU world matrix and GPU instance data:

1. Read the world translation as `f64`.
2. Compute integer chunk coordinates from `floor(position / 32)` plus the voxel-world chunk offset. Wrap x before narrowing its chunk index to `i32`.
3. Remove the chunk origin using `mod(position, 32)` **in f64**. Floor/modulo also handle negative positions.
4. Convert that local translation to `f32`. Convert the rotation/scale columns separately; never convert the absolute translation column.

An instance still occupies 80 bytes: a chunk-local `f32` matrix and a padded integer chunk coordinate. Before applying the camera or cascade matrix, the shader subtracts integer chunks, applies x wrapping, and then converts the small chunk delta to meters. CPU per-object paths use `ChunkTransform.relativeTo` for the same operation.

For example, `1_000_000_000.125` retains the `.125` offset in the CPU transform and uploads it as a local coordinate. Casting the absolute value directly to `f32` would discard that offset. Likewise, an f32 absolute matrix cannot be repaired by widening it to f64 afterward.

## Camera and shadows

The camera builds its translation matrix from `getLocalPosition`, which removes the origin in `f64` before returning local `f32` coordinates. Its view, projection, inverse projection, and frustum calculations use that local frame. The old absolute-world `f32` camera matrices and world-frustum helpers have been removed; use `getChunkFrustumPoints` for rendering queries.

Directional cascades are fitted to this chunk-local camera frustum and record the camera chunk as their origin. Shadow casting and sampling both use that frame. Terrain rebases its model transform to each cascade's origin before composing the light matrix; meshes and voxels subtract chunks in the shaders. Window-box camera calculations, billboard directions, and wireframe bounds also operate on rebased transforms. Skyboxes use camera rotation only.

The fields ending in `_world_chunked` refer to coordinates relative to the camera chunk, not absolute world coordinates. Normals and rotation/scale values can be converted directly because they carry no origin-dependent translation.

## API and range notes

- Position setters and object-creation parameters accept `world_math.Position` (`@Vector(3, f64)`). Three-component literals such as `.{ 1, 2, 3 }` still work; use the shared type for named positions and movement deltas. `getLocalPosition` in `chunk_utils` returns `@Vector(3, f32)` after removing the origin.
- `GameObject.getModelMatrix` and `aggregated_matrix` return f64 matrices. Use `ChunkTransform.init` to prepare one for rendering. `world_math.fromFloat32` widens asset-local matrices before CPU composition.
- The GPU chunk encoding remains signed `i32`, and unwrapped y/z chunks must fit it. This migration does not make the world unbounded. The voxel world still wraps only x.
- Scenes still use the temporary ArrayList visibility index. It returns all registered objects and needs no absolute-world f32 bounding boxes. The retained, unused original SpaceTree still assumes f32 matrices and requires migration before it can index these objects again.

## Verification

Run `zig build` and `zig build test`. The hierarchy tests exercise nested translation, rotation, scale, later parent updates, reparenting, GPU invalidation, and local-position preservation around ±1 billion meters. Coordinate tests verify small accumulated camera movements, negative boundaries, repeated x wrapping, origin removal before f32 conversion, and identical camera/shadow projections before and after translating a scene by a billion meters. All three shadow cascades are checked, including agreement between the per-object CPU and per-vertex GPU-style projection paths.
