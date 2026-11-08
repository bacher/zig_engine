# Generated support chunk reuse

The authority's five-neighbor blueprint rule bounds structural probes, not the work
behind each probe. Previously a nonresident untouched chunk was generated once per
operation and then discarded. Successive fills above the same chunk boundary could
repeatedly generate identical support data. Rejected edits could also regenerate
their target to construct a response, and successful edits regenerated it on promotion.

## Runtime ownership and limits

`WorkerState.generated_chunks` keeps immutable generated chunks across operations.
Its default 128-entry cap retains up to 4,194,304 raw block bytes plus bounded hash
index/header capacity. A miss can temporarily own one additional incoming chunk.
Empty chunks still consume an entry, preventing an unbounded air-only index.
Eviction uses a round-robin cursor and expected O(1) indexed lookup/removal. Cache
hits do not maintain an LRU list or allocate per-operation chunk maps.

Cached data uses the stable service allocator independently of the persistence
live-state allocator. Promotion moves a cached value when both allocators match;
otherwise it clones the data through the live budget before releasing its source.
This avoids terrain regeneration without bypassing the budget or freeing a backing
allocation through its wrapper. Clone/index failure leaves cached ownership intact.

Modified residents always win. Nonresident reads check the saved catalog before
using generated data; a pending/failed saved read cannot fall back to generated
terrain. Loaded saved chunks invalidate their generated entry. Cache entries are
excluded from authoritative residents, save sources, timers, and source holds.
Cache-index OOM and disabled caching retain the former operation-local fallback.

This reduces repeated generation for a fitting working set. A wider working set can
still miss and regenerate chunks; the cache does not guarantee a constant generation
cost for every support read or retain the supports of all active sites.

## Workload

`blueprint_cold_support_tests.zig` compares the same worker fulfillment path with a
zero-entry cache and the production 128-entry setting. It uses the natural generator
with seed 12345 and the 2048×1024×32 chunk layout. Sixteen 8×8 plank-floor sites have
1,024 targets, interleaved by local cell index. Every site crosses X/Y chunk boundaries
and the Z boundary between its targets and support; one also crosses the periodic X
seam. The 64 target chunks model already excavated cavities. Their 64 support chunks
remain nonresident and contain naturally generated stone. Untimed oracle checks
confirm complete stone platforms for the recipe before the fill loop.

Each pair must produce identical physical/progress digests, exactly one structural
support probe per fill, zero ordinary-validator calls, and no resident support chunks.
Caching disabled must generate 1,024 chunks; the fitting cache must generate exactly
64. An eight-entry run checks eviction, the memory bound, and the same final digest
without imposing a hit-rate or timing requirement.

ReleaseFast runs three alternating pairs and reports wall time, thread CPU time,
successful generations, hits/misses, evictions, retained block bytes, and results.
Timing includes fulfillment, mutation/progress bookkeeping, and fixture assertions
inside the loop. It excludes natural-world preparation, recipe compilation, source
selection/platform-oracle checks, destination admission, endpoint queues, inventory,
roads, client delivery/rendering, persistence, and final digest verification. These
measurements do not establish whole-game throughput or a latency bound.

## Isolated ReleaseFast observations

Measured on 2026-11-08, Apple M4 Max, arm64, macOS 26.7.1, Zig 0.16.0. The direct
worker benchmark ran without other builds/tests in progress:

```sh
zig build bench-generated-support -Doptimize=ReleaseFast --summary all
```

| Pair | Cache disabled, wall ms | 128 entries, wall ms | Disabled, thread CPU ms | 128 entries, thread CPU ms |
| --- | ---: | ---: | ---: | ---: |
| 1 | 374.082 | 23.610 | 373.877 | 23.611 |
| 2 (cached first) | 391.478 | 24.339 | 389.392 | 24.340 |
| 3 | 371.928 | 23.485 | 371.893 | 23.476 |

Median fill-loop wall time fell from 374.082 to 23.610 ms, about 15.8× faster in
this generation-dominated scenario. Every disabled run generated 1,024 chunks;
every fitting-cache run generated 64, retained 2,097,152 raw block bytes, and had
1,984 hits, 64 misses, and no evictions. Hits include the ordinary second below-cell
read for earth-aging handling as well as the structural support probe.

The eight-entry run regenerated 1,024 chunks and evicted 1,016, retaining 262,144
raw block bytes. It produced the same digest as every other run. Its 363.230 ms
wall time is an observation, not an over-capacity speedup guarantee. This working
set deliberately does not fit; the result shows the cache's locality requirement.
All variants kept exactly 1,024 structural support probes and zero ordinary calls.
The [raw results](generated-support-cache-benchmark.txt) include counters and digests.

## Correctness coverage

Service regressions cover reuse across rejected edits, exact ownership transfer,
modified-data precedence, distinct live/cache allocation domains, zero live budget,
promotion allocation failures, pending and failed saved reads, persisted installation,
and subsequent unload. Cache unit tests cover disabled/reduced capacities, replacement,
eviction without further index allocation, exact data/flags, insertion allocation
failure, and balanced cleanup through the testing allocator.

Verification passed:

- `zig build test-blueprint-service -Doptimize=Debug --summary all`: 549/549 tests.
- `zig build install test -Doptimize=ReleaseFast --summary all`: 55/55 steps,
  1,873 tests passed and eight existing skips; both applications built.
- `zig build bench-generated-support -Doptimize=ReleaseFast --summary all`:
  15/15 steps, 4/4 tests, including the filtered cold-support fixture.
- Formatting and `git diff --check`.
