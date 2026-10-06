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

## Signed chunk coordinates and storage

`world_math.ChunkCoords`, also exported as `engine.ChunkCoords`, is `@Vector(3, i32)`. Camera and light origins, voxel chunks, streaming messages, and terrain chunk APIs use this shared spatial type. Negative coordinates are valid outside the stored terrain zone. Two-dimensional terrain columns use `@Vector(2, i32)`, and chunk height ranges use `i32` endpoints. Neighbor offsets and comparisons use vector arithmetic.

The engine's `chunk_utils` module defines the shared limits. `WORLD_SIZE` is a `ChunkCoords` vector (`@Vector(3, i32)`) measured in chunks, with positive dimensions checked at compile time. `WORLD_ORIGIN_CHUNK` is derived by halving that vector, and `WORLD_SIZE_IN_BLOCKS` contains unsigned storage extents derived from the chunk dimensions and `CHUNK_SIZE`. The voxel application imports these constants from the engine. The engine's voxel code and generated WGSL also use this source, so chunk size and world width agree across game logic and rendering.

Packed chunk IDs remain unsigned. `world.normalizeChunkCoords` wraps x with modulo (including repeated trips around the world) and rejects y/z outside the stored dimensions. Normalize spatial coordinates before calling `encodeChunkCoords`; packing asserts that all axes are inside the stored world before converting them to unsigned fields. The existing 12/8/3-bit chunk ID format is unchanged. Block-operation coordinates and local block coordinates remain unsigned storage addresses; negative spatial chunks cannot be used to index stored blocks directly.

`chunk_utils.getChunkDelta` widens both inputs before subtracting and returns `@Vector(3, i64)`: the difference of two valid `i32` coordinates need not fit in `i32`. It normalizes x before choosing the shortest wrapped displacement. Streaming distances use these wide deltas; bounded neighborhood queries saturate at the signed coordinate limits. On the GPU, x is normalized separately, while y/z distances are computed as unsigned magnitudes with their signs restored after conversion. This supports the full signed range while preserving small integer differences before converting to `f32`.

CPU vectors are not serialized as raw bytes: three-component vectors may have padding. GPU instances retain their padded `@Vector(4, i32)` chunk field and 80-byte stride. Voxel GPU records use an explicit `[3]i32` field matching WGSL `vec3i`, retaining their 112-byte stride and existing field offsets. Camera/light chunk uniforms retain their explicit 12-byte `[3]i32` layout.

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

Run `zig build` and `zig build test`. The hierarchy tests exercise nested translation, rotation, scale, later parent updates, reparenting, GPU invalidation, and local-position preservation around ±1 billion meters. Coordinate tests verify small accumulated camera movements, negative boundaries, repeated x wrapping, origin removal before f32 conversion, and identical camera/shadow projections before and after translating a scene by a billion meters. All three shadow cascades are checked, including agreement between the per-object CPU and per-vertex GPU-style projection paths. Signed-coordinate tests cover deltas across both `i32` limits, local camera matrices at those limits, negative voxel upload coordinates, terrain bounds, and packed-ID compatibility.
