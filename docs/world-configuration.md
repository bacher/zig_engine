# World configuration

Applications choose x wrapping at compile time and world dimensions at scene creation. Dimensions stay fixed for that scene's lifetime. The engine supports ordinary space or periodic x; y and z never wrap. The voxel application always enables x wrapping, and its terrain, neighbors, streaming, and tools assume that topology.

## Application configuration

Each application provides an `engine_config.zig` module:

```zig
pub const wrap_x = true;
```

[`build.zig`](../build.zig) injects this module into that application's engine module and static library. The demo's [configuration](../src/demo_app/engine_config.zig) sets `wrap_x = false`; the voxel app's [configuration](../src/voxel_app/engine_config.zig) sets it to `true`. Both use the same engine sources and dependency modules. The engine exports the configuration as `engine.config`.

All worlds in one application share its compiled wrapping mode, but may have different dimensions. Changing the wrapping mode requires rebuilding the application. `voxel_app` has a compile-time guard in [`consts.zig`](../src/voxel_app/consts.zig) that rejects an engine configuration with wrapping disabled.

## Creating a world

```zig
const scene = try engine.createScene(.{
    .size_in_chunks = .{ 128, 64, 16 },
});
defer scene.deinit();
```

`WorldSettings` and `WorldLayout` are exported by `engine`. Settings can come from runtime application state. `Engine.createScene(settings)` validates them before creating GPU resources and exposes the resulting layout through `scene.layout`, a `*const WorldLayout`. Different scenes may have different layouts and pipeline sets; the engine renders its active scene.

Validation requires:

- Each dimension is a power of two and at least two chunks.
- Each dimension's block extent fits `u32`. With 32-block chunks, the largest accepted axis is 2²⁶ chunks.
- The sum of the dimensions' base-2 exponents is at most 32, so every storage coordinate fits one `u32` chunk ID.

Invalid settings return `InvalidWorldDimension`, `WorldDimensionTooLarge`, or `TooManyChunkIdBits`. Chunk size remains fixed at 32³; block formats, voxel face formats, GPU buffer capacities, and instance strides remain fixed too.

The voxel app's current dimension preset is in [`consts.zig`](../src/voxel_app/consts.zig): 512×256×8 chunks. The demo selects the same dimensions. `WorldSettings` contains only dimensions; wrapping is supplied by the application's engine configuration. Neither has an implicit engine default.

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

Each scene owns six pipelines specialized when the scene is created: regular and skinned meshes, voxels, and their three shadow variants. `WorldLayout.shaderSource` selects the wrapped or unwrapped coordinate helper at Zig compile time. It writes literal chunk-size constants and, for wrapped builds, width/mask constants from the runtime-selected layout. Wrapped WGSL normalizes x with a bit mask. Unwrapped WGSL omits periodic arithmetic and width/mask declarations. Both subtract unwrapped integer coordinates safely across the full signed i32 range before converting distances to f32.

Cameras, transforms, billboards, voxel face selection, visible projections, and shadows use the same scene layout. Other pipelines remain engine-owned because their input transforms are already rebased on the CPU or independent of world topology. Scene destruction releases its specialized pipelines and layout. Pipeline compilation occurs at scene creation, not during frames; switching the active scene selects its existing pipelines.

`World.init(allocator, layout)` and `WorldDataService.create(io, allocator, layout, generator)` take validated layouts and retain their own immutable copies. The service validates and prepares its generator against its layout before starting the worker. It owns one immutable octave table reused by all column and neighbor-strip generation. Each service has its own subscriptions, IDs, and caches. `ColumnGenerator.init(prepared, coords)` uses the prepared generator's const layout, which must outlive the column. Their x-periodic behavior is guaranteed by the application's compile-time guard. See [terrain generation](voxel-world.md#terrain-generation) for preparation errors and ownership.

Terrain remains periodic in x. Its default base height is half the selected block height (`base_height = null`); an explicit base height is still supported. Height bounds, flat surface placement, enclosure certification, and neighbor strips use the selected dimensions. Simulation startup allocates its received-chunk bookkeeping using the selected height.

An accepted engine layout can still be rejected by a particular terrain configuration. Periods use positive `i64`, but their derivation and the sampled x/y lattice coordinates must remain in range; octave frequencies, amplitudes, and their sum must be finite. Invalid combinations return an error before the service worker starts, including in ReleaseFast.

Changing dimensions requires creating a new scene/world and fresh caches/services. Existing IDs, geometry, pending responses, and generated terrain cannot be reinterpreted under a different layout. Changing topology also requires rebuilding the application. The same seed may produce different terrain when dimensions change; eventual save metadata needs to retain dimensions and topology alongside generator settings.

## Compile-time optimization

Wrapping decisions are centralized in `WorldLayout`. `wrap_x` is a compile-time declaration, with no runtime flag in `WorldSettings` or layout storage. The coordinate helpers use explicit `comptime` branches; callers such as cameras, object transforms, billboards, voxel face selection, and shadows inherit the selected implementation.

| Operation | Unwrapped build | Wrapped build |
| --- | --- | --- |
| Layout creation | No reciprocal calculation or storage (`inverse_width` has type `void`). | Precompute an exact power-of-two width reciprocal. |
| Storage normalization | Check storage bounds. | Mask x, then check bounds. |
| Position to chunk | Floor/divide by fixed chunk size and add the runtime origin. | Also normalize x before narrowing to i32. |
| Relative chunk delta | Widen signed inputs and subtract. | Mask x and select its nearest image using the runtime width. |
| Shader generation | Include ordinary-space helper. | Include periodic-x helper and literal width/mask. |
| Voxel terrain, neighbors, and streaming | Not supported by `voxel_app`'s configuration. | Unconditional periodic-x behavior; no topology flag checks. |

An [assembly probe](research/compile-time-wrapping-kernels.zig) imports the production `WorldLayout` and keeps its dimensions and coordinates runtime. Zig 0.16.0 ReleaseFast output on AArch64 macOS confirms that unwrapped `delta_x` contains widening/subtraction with no layout loads, masks, or comparisons. Unwrapped `chunk_x` omits width/reciprocal loads and periodic floor/multiply/subtract; unwrapped normalization omits the x mask. Wrapped deltas use register masks and conditional selects without division or a runtime topology branch. Wrapped position conversion uses inline floating arithmetic without remainder library calls. This is code-generation evidence; application frame-time performance has not been measured.

Reproduce from the repository root, first with the demo configuration, then with the voxel configuration:

```sh
zig build-obj -O ReleaseFast --dep world_layout \
  -Mroot=docs/research/compile-time-wrapping-kernels.zig \
  --dep engine_config -Mworld_layout=src/engine/world_layout.zig \
  -Mengine_config=src/demo_app/engine_config.zig \
  -femit-asm=/tmp/unwrapped.s -femit-bin=/tmp/unwrapped.o

zig build-obj -O ReleaseFast --dep world_layout \
  -Mroot=docs/research/compile-time-wrapping-kernels.zig \
  --dep engine_config -Mworld_layout=src/engine/world_layout.zig \
  -Mengine_config=src/voxel_app/engine_config.zig \
  -femit-asm=/tmp/wrapped.s -femit-bin=/tmp/wrapped.o
```

## Verification

`zig build` builds both configured engine libraries and applications. `zig build test` runs coordinate and hierarchy tests separately under both compiled wrapping modes. It covers dimension validation, 32-bit ID packing, several simultaneous layouts, modulo equivalence at seams and signed limits, repeated wrapped positions, wrapped/unwrapped camera and object coordinates, dimension-dependent generation, and live streaming/edit/eviction across two differently sized x seams. Existing camera/shadow precision and voxel protocol regressions remain registered.

`zig build test-gpu` is an optional headless Dawn check requiring a graphics adapter. It runs two separately compiled test executables, creating all six production world pipelines at two sizes in each wrapping mode, with Dawn validation enabled. It does not replace visual checks or measure performance.

The [configuration research](world-configuration-options.md) records the original alternatives and isolated compiler measurements. It is historical context; this document describes the accepted implementation.

Implementation checks on 2026-10-07: both applications built; 167 registered CPU tests passed, with one wrapping-only test skipped in the unwrapped build. All four isolated layout tests also passed in ReleaseSafe under each configuration. The optional Dawn suite passed on Apple M4 Max/Metal, creating 24 production pipelines (six pipelines × two sizes × two compiled wrapping modes). The windowed applications did not reach graphics initialization in the sandbox during the earlier runtime-layout checks, so rendered appearance remains unverified.

Terrain preparation checks on 2026-10-08: both applications built; 174 registered CPU tests passed with the same expected skip. The 41 focused generation/noise/cache tests passed in ReleaseSafe and ReleaseFast. Coverage includes 2³² periods in the largest accepted x world, positive i64 period bounds, y lattice limits, nonfinite/overflowing settings, startup rejection, allocation cleanup, and unchanged default/custom terrain snapshots. GPU code was unchanged by this fix.
