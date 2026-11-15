# Construction client and rendering validation

The selected renderer keeps separate terrain and construction layers in the existing voxel
grid. Full construction blocks use culled voxel faces; pending miniatures retain their
existing renderer. The implementation follows construction ownership Q3–Q5 and the approved
renderer decision. Mesh-only clients may retain invisible overlap faces against static
terrain, while construction-to-construction faces are culled across chunk/site boundaries.

## Reference geometry measurement

`construction reference geometry has 32800 faces for 320000 filled targets` builds a fully
fulfilled 100×100×32 definition at storage coordinate (31,31,12), crossing 50 target-bearing
chunks. It measures five complete CPU geometry builds, including face-list allocation and
deallocation, using the testing allocator. It excludes world/definition setup, GPU upload,
command encoding, draw execution, and full client-frame work.

On the local arm64 macOS host, the 2026-11-14 ReleaseFast run measured a median of
24.853 ms and minimum of 23.933 ms per complete build. The exact output was 32,800 quads,
131,200 bytes of four-byte face records before allocator capacity/metadata, and 196,800
generated vertices if all six directional lists are submitted. Independent full cubes would
generate 11,520,000 vertices. This is a 58.5× reduction in that vertex count; it is not a
measured frame-rate, GPU-time, or simulation-throughput improvement. Fills that leave the
site building rebuild the affected loaded chunk and face neighbors, and refresh only the
affected miniature source. Actual phase changes, including the last fill, and full discovery
or resync snapshots can still invalidate the loaded site footprint.

Reproduce the optimized sample with:

```sh
zig build test-construction-geometry -Doptimize=ReleaseFast -Dtest-filter='construction reference geometry'
```

## Correctness coverage

`construction_geometry.zig` checks exterior counts for adjacent cells across a chunk seam,
separate sites, the wrapped x seam, a dense 8³ cube, an enclosed unfulfilled cavity, and the
320,000-target reference workload. A 32×32 checkerboard of 512 independent 20-high rebar
columns on limestone validates every column's support and produces 41,472 exposed faces
in one chunk. It visits chunk target groups rather than rescanning the
whole definition for each output chunk. One derived hash set indexes pending optimistic
fulfillments per rebuild; neighbor checks reuse it.

`construction_client.zig` checks full-snapshot and delta revision chains, gaps, stale sessions
and object types, definition reuse, unknown discovery, allocation failures, bounded discovery,
coherent terrain before lifecycle, reference removal, retirement composition watermarks,
sticky static selection after ordinary edits, and eviction followed by fresh discovery.

`main.zig` exercises the actual package callback and both physical/render transitions. A
materialized chunk and subsequent ordinary removal arrive before the progress stream:
collision and targeting immediately use the coherent raw data, while the displayed source
remains resident through a mesh-preparation allocation failure and GPU-budget failure.
The real successful empty-layer install path replaces both resident stamps together and
selects static ownership. A newer ordinary publication keeps that selection. A mesh-only
subscription outside the visible set with unresolved construction state reports missing
collision data and rejects targeting.
A known placement target also invalidates its cached successful preview when a separate
support chunk develops a construction revision gap. A scalar construction-read epoch
covers availability/composition changes without rescanning dependencies each frame.

Terminal retirement without the final progress update retains display through coherent
terrain arrival and geometry installation, then removes that site's pending lookup entries
within the four-footprint-chunk cleanup budget and refreshes the affected miniature sources.
Application package regressions cover a later site at the same cell both after cleanup and
in the package carrying the terrain needed for handoff. Snapshot preparation can replace
pending entries owned by an inactive, completed source while retaining its runtime and
geometry; active or missing owners still reject overlap. Runtime tests cover chunk budgets,
allocation-free cleanup, shared live targets, and cleanup preserving a replacement's target.

`construction progress stays local through actual service packages and resync refreshes the
footprint` saves and admits a sparse 129-wide, five-target site through public service APIs,
then subscribes the application to its five footprint chunks. Four successive fills in the
first chunk each deliver a building-phase delta without terrain/composition responses to the
observer. Through the actual package callback and geometry builder, these fills produce
eight construction chunk rebuilds (the changed chunk and its one loaded face neighbor per
fill) and four miniature source replacements. The distant last chunk stays clean and retains
its installed construction geometry stamp throughout. Initial discovery builds five sources;
a requested full resync refreshes all five, and the final fill still invalidates all miniature
sources for its lifecycle transition. These are deterministic CPU work counts; local nonempty
meshes are prepared but not uploaded, so this check does not measure GPU or frame latency.

Before the fix, the transport regression produced five metadata responses on the first
ordinary fill. With only that server fan-out removed, the application regression still found
five dirty miniature sources because an unchanged phase was treated as a lifecycle change.
Run the package regression with:

```sh
zig build test-app -Dtest-filter='construction progress stays local' --summary all
```

`voxel_grid.zig` checks independent terrain/construction replacement, queued supersession,
cancellation without resident removal, maximum packed face offsets and vertex counts, and
an oversized upload's capacity failure retaining resident and queued geometry. Allocator
tests cover ten simultaneous size classes, oversized allocation/free/reuse, and exhaustion
of the unchanged buffer.

The final integrated headless Dawn/Metal run passed 126/126 GPU checks and all 20 build
steps in both compiled wrapping modes. Its construction readback compares complete color/depth
attachments before replacement, while replacements are queued, and after a successful
nonempty terrain/construction handoff. The oversized readback uses a 98,304-face checkerboard
with the larger allocation and all six face lists, retaining identical color/depth through
the same queued handoff. Both tests check resource cleanup and WebGPU validation errors.

## Budgets and limits

The client cache bounds registrations to 4,096 sites and 4,096 definitions, 8,192 chunks,
65,536 retained discovery references, 65,536 entries in each portion-ownership/selection
map, and 16,384 coalesced pending requests. Capacity/allocation failure keeps the previous
coherent state and retries/resynchronizes. Optimistic world edits retain the existing
4,096-operation and 8 MiB limits. Cached source eviction processes at most four footprint
chunks per frame, and completed source reclamation uses the same footprint budget.

The face buffer remains 4 MiB: 4,096 slots of 1 KiB, with 256 four-byte records per slot.
The allocator retains its 64 base spans of 64 KiB and the existing packing for allocations
up to 16,384 faces. Larger allocations reserve two, four, or eight contiguous empty base
spans, supporting up to 131,072 records without changing the GPU metadata/shader layout or
splitting a logical chunk. All ten size classes can coexist; there is no eight-class limit.

Opaque 32³ voxel meshing emits at most 16,384 faces per direction, 98,304 total, and 49,152
per three-direction view. Packed shader counts/offsets remain within `u16`; CPU list
prefixes and draw vertex multiplication use wider integers. The supported column fixture's
41,472 records contain 165,888 bytes and round to a 256 KiB allocation. The maximum
98,304-record checkerboard contains 393,216 bytes and rounds to 512 KiB.

Power-of-two rounding and size-class packing still waste some buffer space. Oversized
allocations additionally require contiguous free base spans, so fragmentation can reject
an upload despite enough free bytes in separate ranges. Capacity failure retains the
displayed and queued geometry for retry; visibility reduction can release resident ranges.
Allocator compaction and mesh subdivision are not implemented.

The loaded-chunk readiness/selection sweep is still per frame, and every dirty construction
chunk rebuild visits its entire target group. Worst-case repeated fills in a dense chunk,
many separate sites sharing chunks, saturated optimistic edits, sustained GPU capacity
pressure and recovery, shadow/SSAO appearance, and whole-frame memory/latency under streaming pressure
remain performance/visual workloads to measure. The complete reference build timing does
not establish a frame budget or an end-to-end throughput gain.
