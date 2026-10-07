# World configuration

Applications choose world dimensions and whether x wraps when creating a scene. Settings stay fixed for that scene's lifetime. The engine supports ordinary space or periodic x; y and z never wrap. The voxel application always enables x wrapping, and its terrain, neighbors, streaming, and tools assume that topology.

## Creating a world

```zig
const scene = try engine.createScene(.{
    .size_in_chunks = .{ 128, 64, 16 },
    .wrap_x = true,
});
defer scene.deinit();
```

`WorldSettings` and `WorldLayout` are exported by `engine`. Settings can come from runtime application state. `Engine.createScene(settings)` validates them before creating GPU resources and exposes the resulting layout through `scene.layout`, a `*const WorldLayout`. Different scenes may have different layouts and pipeline sets; the engine renders its active scene.

Validation requires:

- Each dimension is a power of two and at least two chunks.
- Each dimension's block extent fits `u32`. With 32-block chunks, the largest accepted axis is 2²⁶ chunks.
- The sum of the dimensions' base-2 exponents is at most 32, so every storage coordinate fits one `u32` chunk ID.

Invalid settings return `InvalidWorldDimension`, `WorldDimensionTooLarge`, or `TooManyChunkIdBits`. Chunk size remains fixed at 32³; block formats, voxel face formats, GPU buffer capacities, and instance strides remain fixed too.

The voxel app's current preset is in [`consts.zig`](../src/voxel_app/consts.zig): 512×256×8 chunks with `wrap_x = true`. The demo selects the same dimensions with wrapping disabled. The engine has no implicit dimension or wrapping defaults.

## Coordinates and IDs

`WorldLayout` derives chunk dimensions, unsigned block extents, the origin at half each dimension, and contiguous ID masks/shifts. World position zero maps to the storage midpoint. Dimensions bound stored terrain and IDs; they do not clip ordinary engine objects or camera movement to that storage zone.

Use the layout belonging to the world:

```zig
const coords = scene.layout.getChunkCoords(position);
const stored = scene.layout.normalizeChunkCoords(coords) orelse return;
const id = scene.layout.encodeChunkCoords(stored);
const decoded = scene.layout.decodeChunkId(id);
const delta = scene.layout.getChunkDelta(coords, scene.camera.chunk);
```

`normalizeChunkCoords` wraps x when enabled and rejects out-of-bounds coordinates on every unwrapped axis. Encoding accepts only normalized storage coordinates. IDs belong to their layout: the same number can identify different chunks in different worlds. Never transfer an ID between worlds without decoding with its original layout and validating against the destination.

`getChunkCoords` preserves f64 positions, wrapping x before narrowing to GPU i32 coordinates. `getChunkDelta` subtracts in i64 and selects the nearest x image when wrapping is enabled. Exact half-period ties retain their signs. Unwrapped coordinates must fit signed i32, even outside storage bounds. [Coordinates and rendering precision](coordinates.md) describes rebasing and GPU formats.

A wrapped period is assumed to be much larger than camera render distance. Rendering selects one nearest image of a chunk or object. It neither validates that assumption nor draws repeated images when a view spans multiple periods.

## Rendering and ownership

Each scene owns six pipelines specialized when the scene is created: regular and skinned meshes, voxels, and their three shadow variants. `WorldLayout.shaderSource` writes literal chunk-size/width/mask constants and includes either the wrapped or unwrapped coordinate helper. Wrapped WGSL normalizes x with a bit mask. Unwrapped WGSL omits periodic arithmetic. Both subtract unwrapped integer coordinates safely across the full signed i32 range before converting distances to f32.

Cameras, transforms, billboards, voxel face selection, visible projections, and shadows use the same scene layout. Other pipelines remain engine-owned because their input transforms are already rebased on the CPU or independent of world topology. Scene destruction releases its specialized pipelines and layout. Pipeline compilation occurs at scene creation, not during frames; switching the active scene selects its existing pipelines.

`World.init(allocator, layout)` and `WorldDataService.create(io, allocator, layout, generator)` take validated layouts and retain their own immutable copies. They return `XWrappingRequired` when wrapping is disabled. The service's worker and generated columns use its copy; the main-thread cache uses the equivalent scene configuration. Each service has its own subscriptions, IDs, and caches. `ColumnGenerator` borrows a const layout which must outlive the column.

Terrain remains periodic in x. Its default base height is half the selected block height (`base_height = null`); an explicit base height is still supported. Height bounds, flat surface placement, enclosure certification, and neighbor strips use the selected dimensions. Simulation startup allocates its received-chunk bookkeeping using the selected height.

Changing dimensions or topology requires creating a new scene/world and fresh caches/services. Existing IDs, geometry, pending responses, and generated terrain cannot be reinterpreted under a different layout. The same seed may produce different terrain when dimensions change; eventual save metadata needs to retain the layout alongside generator settings.

## Verification

`zig build` builds both applications. `zig build test` covers dimension validation, 32-bit ID packing, several simultaneous layouts, modulo equivalence at seams and signed limits, repeated wrapped positions, wrapped/unwrapped camera and object coordinates, dimension-dependent generation, and live streaming/edit/eviction across two differently sized x seams. Existing camera/shadow precision and voxel protocol regressions remain registered.

`zig build test-gpu` is an optional headless Dawn check requiring a graphics adapter. It creates all six production world pipelines for both wrapped and unwrapped layouts at two sizes, with Dawn validation enabled. It does not replace visual checks or measure performance.

The [configuration research](world-configuration-options.md) records the original alternatives and isolated compiler measurements. It is historical context; this document describes the accepted implementation.

Implementation checks on 2026-10-07: both applications built; all 141 registered CPU tests passed; the four isolated layout tests also passed in ReleaseSafe. The optional Dawn suite passed on Apple M4 Max/Metal, creating 24 production pipelines (six pipelines × two sizes × two wrapping modes). The windowed applications did not reach graphics initialization in the sandbox, so rendered appearance was not verified.
