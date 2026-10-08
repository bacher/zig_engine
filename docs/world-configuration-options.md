# World dimensions and wrapping: configuration options

Research on 2026-10-07 against commit `aaa3e58`, following the engine/application-boundary review point. This records the comparison before implementation. The accepted contract was subsequently revised to **runtime immutable dimensions and compile-time per-application x wrapping**, always enabled in `voxel_app`, with a period assumed much larger than render distance. [World configuration](world-configuration.md) describes the implemented API, ownership, and production code-generation checks. The recommendation and axis-capable sketches below belong to the original exploration.

## Original recommendation

Make world dimensions and an optional single wrapped axis runtime settings chosen by the application when creating a world. Keep them immutable for that world's lifetime. Retain fixed 32³ chunks and power-of-two world dimensions initially. Derive and validate one world layout, then specialize the relevant GPU pipelines for that layout at creation time.

This gives per-world choice without requiring per-frame changes, arbitrary chunk formats, or a branch on world settings in every vertex. CPU arithmetic does lose some compiler specialization, but power-of-two masks and precomputed layout values preserve the important inexpensive operations. The isolated compiler experiment below demonstrates that a direct runtime-modulo rewrite and a deliberate runtime implementation have different costs.

Static application configuration is a sound lower-scope alternative if per-world choice is not actually wanted. Hardcoding in the engine has the least immediate work, but no performance advantage over equivalent static application settings. Fully dynamic dimensions do not require arbitrary non-power-of-two dimensions or settings that can be modified while a world is running; those are separate scope decisions.

## Dependencies at the research baseline

| Dependency | Implementation at `aaa3e58` | Consequence of configuration |
| --- | --- | --- |
| Dimensions and ID layout | [`chunk_utils.zig`](../src/engine/chunk_utils.zig) defines `WORLD_SIZE_LOG2 = {9,8,3}`, yielding 512×256×8 chunks. Masks/shifts derive from those exponents. | Validate dimensions and derive masks, shifts, block extents, and origin together. The ID layout is tied to its world. |
| World position conversion | `getChunkCoords` offsets by half the world dimensions, wraps x in f64, then narrows to i32. | Conversion needs the appropriate world's origin and wrapping rule; preserve normalization before narrowing. |
| Relative rendering/streaming distance | CPU `getChunkDelta`, `ChunkTransform.relativeTo`, and WGSL `chunkOffset` use the shortest wrapped x delta. | One shared topology policy must drive object rendering, camera/shadows, billboards, voxel face selection, and streaming. |
| Shader source | Six pipeline modules prepend a compile-time WGSL fragment containing world width. | Supply a layout-specific shader prefix or pipeline constants at GPU pipeline creation. |
| Stored-world bounds | [`world.zig`](../src/voxel_app/world.zig) wraps x and rejects y/z outside storage. | Centralize normalization/bounds per axis instead of spreading axis checks through callers. |
| Protocol and caches | Service requests validate against global dimensions; maps use u32 chunk IDs. | Bind each service/cache to one layout. Messages may keep their existing coordinate/ID types when scoped to that world. |
| Terrain | Generation is periodic in x, bounded in y/z, and derives default height from world height. | Change the generator and enclosure rules alongside topology. Bounds alone do not make a new wrapped axis correct. |
| Tools and simulation | Tools add the global world origin; simulation allocates a fixed-size array for the full vertical chunk column. | Use the world's origin; replace the simulation's height-sized compile-time array with runtime storage if height varies. |
| Build graph | Both executables share one engine module/library. | Static per-app settings require distinct engine module/library configurations, rather than only adding options to each executable. |

The current change to contiguous chunk IDs already centralizes packing. X now occupies 9 bits, y the next 8, and z the next 3, using 20 of 32 bits. This research uses that current layout, not the previous fixed offsets described in older history.

## Which optimizations actually need constants?

### Fixed chunk format

The most consequential structural constants are the chunk size and GPU formats:

- Dense blocks use 32³ entries and local coordinates use `u5`.
- Boundary planes use 32 rows of 32 bits: 128 bytes per plane.
- GPU face records are four bytes; chunk metadata is 112 bytes.
- Face-buffer slots are 1024 bytes, with fixed span/allocation classes.
- Face extraction loops over one chunk's blocks, independently of total world size.

These remain unchanged with runtime world dimensions. Configuring world size is substantially easier than configuring chunk size. The latter is outside the requested change and would affect those layouts and algorithms directly.

### Power-of-two world extents

Powers of two give compact contiguous bit fields for IDs and allow integer wrapping with masks. Both still work with runtime sizes: derive bit counts/shifts/masks once at world creation, then use register shifts and masks. A runtime mask does not require integer division.

Current validation requires positive dimension exponents, total ID bits at most 32, positive i32 chunk extents, and u32 block extents. Equivalent runtime validation is needed. With chunk size 32 and power-of-two extents, the block-coordinate constraint limits an individual exponent to at most 26; the total bit budget imposes a further combined limit. The flat generator and tests also have assumptions about minimum heights and particular coordinates that need review.

Arbitrary dimensions are possible, but they are an additional decision. They could use bit fields sized with ceil(log2(size)), leaving unused encodings and requiring bounds checks, or a linear ID `x + size_x * (y + size_y * z)` after validating that the total fits. The latter uses multiplication, not a required division, when encoding; decoding introduces division/remainder. There is no need to incur those changes to obtain per-world choice among power-of-two sizes.

### CPU and GPU specialization are independent

Zig knows static application settings during CPU compilation. GPU shaders are compiled when `Pipelines.init` calls `createWgslShaderModule` and creates WebGPU pipelines, even though their source strings currently originate at Zig compile time.

Therefore a runtime world setting can still become a literal constant in that world's WGSL source. An unwrapped variant can omit wrapping entirely; a wrapped variant can select one axis and a constant period. The GPU compiler receives much the same specialization opportunity as it does now. Exact GPU code generation and speed require a GPU check; this is not a measured GPU equivalence claim.

The concrete initial route is runtime construction of the shared WGSL prefix, passed into the affected pipeline factories. The existing source-module API accepts a string. WGSL overrides are another possible specialization mechanism, but their integration into the pinned zgpu pipeline API has not been validated in this research.

Specializing both dimensions and axis creates pipeline sets keyed by layout. Cache/reuse them and create them when loading a world, not during frame drawing. This adds world-load compilation and GPU resource ownership work. Specializing only axis and placing dimension masks in a uniform is another tradeoff if many layouts are switched frequently; it keeps fewer pipeline variants but changes bindings and requires GPU measurement.

## Comparing the three choices

| Choice | Readability and code changes | Performance | Product consequences |
| --- | --- | --- | --- |
| Hardcoded engine settings | Least immediate work. Global dependencies remain implicit and examples share the same topology. | Current constant-folding and shader specialization. | Every size/topology experiment requires source changes/rebuild; another app inherits voxel assumptions. |
| Static application settings | Moderate refactor: inject a settings module into each engine module/library and relevant test root. Coordinate/terrain helpers express optional wrapping using compile-time decisions. | Equivalent optimization opportunities to hardcoding for the same settings; zero required runtime topology branch. Extra configurations add build work/code variants. | One layout per compiled engine configuration; rebuild for experiments. Several presets in one executable require explicit variants or generic machinery. |
| Runtime immutable world settings | Larger refactor: explicit layout ownership, coordinate context, validated derived values, world-specific pipelines, and runtime height storage. Ordinary model/scene types can remain shared. | Small extra CPU loads/register operations in a deliberate power-of-two path; naive runtime modulo can be more expensive. Specialized GPU pipelines preserve constant settings. No FPS result established. | Different worlds in one binary, fast configuration experiments, world metadata ready for eventual saves. Requires complete world-load/unload boundaries. |

Static settings do not inherently require making every engine type generic. Build-generated/imported settings are enough for separate executable engine configurations. However, attaching `build_options` only to an application root does not automatically provide those options to the separately created engine root module in the current build graph.

Runtime settings similarly do not require conditional logic throughout the engine. Most callers can ask a layout for position conversion, coordinate normalization, neighbor lookup, or relative delta. The conditional is contained in those operations. Rendering can select a pipeline set once per active scene/world. General f64 matrix composition, object parenting, asset loading, animation data, and voxel slot allocation need no topology-specific branching.

## Compiler experiment

The reproducible standalone source is [`research/world-configuration-kernels.zig`](research/world-configuration-kernels.zig). It compares scalar versions of the current x-delta, position-to-chunk, and ID operations with dynamic alternatives. Runtime parameters are exported so the compiler cannot assume the default dimensions at their entry points.

Compiled with Zig 0.16.0, `-O ReleaseFast`, on the local AArch64 macOS target:

| Isolated operation | Observed generated code |
| --- | --- |
| Integer delta, constant width 512 | Immediate masks; no division. |
| Integer delta, runtime modulo width | Two signed integer divisions. |
| Integer delta, runtime power-of-two mask | Register masks; no division. |
| Packed ID, fixed shifts 9/17 | Two shifted OR instructions for the core arithmetic. |
| Packed ID, runtime shifts | Two register shifts and two ORs for the core arithmetic. |
| Position-to-chunk, constant f64 width 512 | Inline floating arithmetic; no remainder library calls. |
| Position-to-chunk, direct runtime f64 modulo | Two `_fmod` library calls. |
| Position-to-chunk, runtime power-of-two size and precomputed reciprocal | Inline multiply/floor/subtract; no division or remainder library calls. |

The reciprocal candidate operates on `floor(position / 32) + origin` and computes `value - floor(value * reciprocal) * size`, with size/reciprocal from validated powers of two. It needs dedicated correctness tests before production use; the sample checks are not a proof across all f64 inputs. Nonfinite positions and unsupported unwrapped coordinate ranges remain invalid inputs.

Two ReleaseSafe tests passed: 2166 integer delta pairs across six widths, including both i32 limits and half-period ties; and 120 finite position cases across six sizes, including negative boundaries and large wrapped positions. The default-size results also match their static counterparts in these cases.

Reproduce from the repository root:

```sh
zig test docs/research/world-configuration-kernels.zig -O ReleaseSafe
zig build-obj docs/research/world-configuration-kernels.zig -O ReleaseFast \
  -femit-asm=/tmp/world-configuration-kernels.s \
  -femit-bin=/tmp/world-configuration-kernels.o
```

This is compiler-output evidence, not an elapsed-time or frame-rate benchmark. These scalar kernels do not include surrounding vector code, map operations, cache misses, meshing, or GPU execution. They show which optimizations are lost by a direct rewrite and which can be retained explicitly; they do not quantify the application's overall speed difference.

## Wrapping semantics and terrain

At most one wrapped axis is a useful scope constraint. It can be represented by one enum or optional axis rather than independent booleans, making invalid combinations unrepresentable.

Multiple periodic axes are not mathematically required to create teleportation: a two-axis periodic space is locally Euclidean, and crossing a coordinate seam can be continuous. Even one wrapped axis changes global topology. Visible jumps arise when rendering, neighbor lookup, physics, or interpolation disagree about the seam. Supporting more axes would still enlarge the implementation and test surface, so the proposed one-axis restriction is reasonable.

For this particular terrain model, the meaningful initial settings are no wrapping, x wrapping, and y wrapping:

- **None:** use bounded neighbors on all axes and nonperiodic horizontal noise. The existing Perlin implementation already exposes `sample2D`.
- **X:** preserve the current periodic noise, seam-neighbor sampling, and shortest-image rendering.
- **Y:** periodize the other horizontal coordinate and update neighbor-strip sampling/enclosure. The same noise machinery can be adapted by choosing which coordinate is periodic.
- **Z:** coordinate math can express it, but a heightmap's grass/air surface and deep stone bottom do not provide a smooth vertical seam. Reconsider top/bottom enclosure, terrain meaning, tools, and any future gravity/collision rules before accepting it for the voxel generator. The engine can have an axis-capable layout while the generator rejects unsupported vertical wrapping explicitly.

Very small periods deserve separate tests. The current renderer selects one nearest image of each chunk/object; it does not draw arbitrary repeated images when the view spans several periods. A small wrapped dimension can also cause several streaming offsets to identify the same stored chunk. The accepted policy assumes the period is much larger than render distance, with no runtime check or repeated-image rendering. Static settings have these same semantic concerns.

## Proposed ownership and API shape

A sketch of the input is:

```zig
const WorldSettings = struct {
    size_in_chunks: [3]u32,
    wrap_axis: ?Axis = null,
};
```

Validation creates an immutable `WorldLayout` containing dimensions, storage origin, block extents, ID masks/shifts, and selected wrapping values. `Axis` represents x/y/z; the voxel generator can separately constrain supported modes. This is an illustrative shape, not a committed API.

One scene/world keeps a stable layout, shared with its camera, local cache, service, and generator. Methods such as `layout.chunkCoords(position)`, `layout.normalize(coords)`, `layout.adjacent(coords, side)`, `layout.delta(a, b)`, and `layout.encode/decode` contain the policy. Transform construction/relative projection need the layout; general matrix math does not. All objects drawn in one scene use that scene's coordinate topology.

Keep the GPU instance/face formats unchanged by specializing shader source, and preserve one coordinate origin for visible and shadow passes. The current engine singleton and one-active-scene loop do not prevent sequential runtime-configured worlds. Multiple differently configured scenes would require selecting the matching layout/pipeline set; rendering mixed worlds in one pass is a separate feature.

IDs remain meaningful only within a world/layout. Changing dimensions in place could reinterpret existing IDs and offsets, invalidate cached/generated terrain, and admit inconsistent pending responses. Create a new world with fresh caches and subscriptions instead. Dimension-dependent seed generation also means the same seed can produce different terrain when circumference changes; future save/world identity should include dimensions, wrapping, seed, and generation version.

World memory is currently sparse: streamed blocks/geometry, bounded generated caches, and retained edits. Total world volume does not allocate a dense full-world array, so larger dimensions do not directly enlarge the resident GPU buffer. More explored/edited terrain and full-height simulation startup can still increase memory/work. Runtime settings must not be presented as removing the existing fixed GPU capacity limits.

## Implementation and evaluation sequence

If the runtime direction is accepted:

1. Introduce and validate the layout with the current dimensions/x wrapping. Centralize bounds, IDs, neighbors, and delta policy while preserving current output.
2. Make camera, transform conversion, cache/service, generator, tools, and simulation use that world's layout. Keep size/wrapping fixed after creation.
3. Construct the affected GPU shader sources/pipeline sets from that layout; keep camera/shadow math in agreement.
4. Test several sizes and none/x wrapping, extreme signed positions, negative seams, half-period ties, ID bit budgets, boundary edits, neighbor masks, and enclosure certification. Make existing tests avoid assumptions about one global world.
5. Test two layouts in the same process to catch leaked global settings, stale replies, and world-switch cleanup.
6. Compare optimized CPU kernels, generation/streaming latency, world-load pipeline compilation time, and GPU frame time on the same scene/workload. Expand arbitrary-size or vertical-wrap support only when the need and semantics are clear.

The research itself added this note and an isolated compiler experiment. The later implementation combines validated runtime dimensions with compile-time per-application x wrapping, an engine-owned reference-counted cache of specialized pipelines, and regression coverage; see [world configuration](world-configuration.md). Full workload performance remains unmeasured.
