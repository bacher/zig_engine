# Blueprint compiler and admission measurements

Measured on Apple M4 Max, arm64, macOS 26.7.1, Zig 0.16.0, ReleaseFast.
These are individual synthetic fixture runs, with no discarded warmup or tail
latency estimate. They establish helper costs for the stated contents; they do
not establish application frame latency or a complete capture/application SLO.

```sh
zig build bench-blueprint -Doptimize=ReleaseFast \
  --cache-dir /private/tmp/zig-blueprint-local \
  --global-cache-dir /private/tmp/zig-blueprint-global
```

The runner is `src/voxel_app/blueprint_benchmark.zig`. Its allocation meter counts
requested live allocation bytes and allocation calls. It excludes backing
allocator page overhead and is not RSS. `helper_peak_requested` includes retained
output, so retained bytes must not be added to that peak.

## Compiler

The compiler receives a borrowed, dense, x-fastest block array. Each cell is one
byte. The configured raw selected-volume limit is 1,048,576 cells, including air;
the validator cache limit is 8,192 entries. A successful cache entry is 128 bytes;
the complete failure diagnostic type is 1,088 bytes and rejection details use a
separate bounded pool. The benchmark has a ten-second cancellation watchdog,
which is a runner guard rather than a runtime latency promise.

The sparse fixture has a full rebar ground floor and two rebar towers, with
included reinforced-concrete platform resets. Dense contents are all rebar.
Invalid contents are all natural stone, which normalize to crushed stone and
exceed the ordinary structural limits.

| Size | Case | Raw cells | Targets | Copy ms | Compile ms | Helper peak bytes | Retained definition bytes | Allocation calls | Rule reads | Validated cells | Result |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 10×10×8 | sparse | 800 | 162 | 0.000 | 0.322 | 62,800 | 800 | 10 | 25,758 | 162 | valid |
| 10×10×8 | dense | 800 | 800 | 0.000 | 0.460 | 248,272 | 800 | 12 | 39,708 | 800 | valid |
| 10×10×8 | invalid | 800 | 0 | 0.000 | 0.694 | 248,272 | 0 | 12 | 51,536 | 601 | structural rejection |
| 100×100×32 | sparse | 320,000 | 10,110 | 0.020 | 3.820 | 4,316,808 | 320,000 | 16 | 48,606 | 10,110 | valid |
| 100×100×32 | dense | 320,000 | 320,000 | 0.006 | 101.478 | 4,317,872 | 320,000 | 16 | 9,876,264 | 320,000 | valid |
| 100×100×32 | invalid | 320,000 | 0 | 0.005 | 39.765 | 4,316,808 | 0 | 16 | 3,821,660 | 60,001 | structural rejection |

Copy time measures only one `memcpy` into an already allocated detached array.
It excludes client cache and optimistic-overlay lookup, full-block residency,
source loading, pin/subscription management, and the actual one-pass client
snapshot operation. Times rounded to 0.000 ms are below displayed precision.
The borrowed raw input adds 320,000 bytes to the large compiler helper's working
set, independently of the measured allocation peak.

An immediate-platform fast path in the shared validator preserves the existing
support route set and minimum mineral height while avoiding recursive descent
through tall direct chains when a known height-one lateral route already exists.
The dense reference compilation completes in 101.478 ms with this implementation;
this run does not characterize every structurally valid arrangement.

## Destination admission

Both fixtures use a 256³-block world, a 100×100×32 definition at origin
`(87,87,87)`, and a 56-cell dependency halo. That alignment copies 384 chunks,
the maximum for this fixture's halo dimensions. The definition's actual footprint
touches 32 chunks at that origin; a differently aligned 100×100×32 footprint can
touch 50 chunks. The physical platform occupies Z=84…86. No existing planned
targets, construction metadata, custom roads, or immutable-floor indices are
present in this synthetic snapshot.

| Case | Targets | Snapshot chunks | Footprint chunks | Foundation reads | Prepare ms | Snapshot requested bytes | Snapshot estimate bytes | Helper peak bytes | Retained publication bytes | Helper allocation calls |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sparse | 10,110 | 384 | 32 | 31,212 | 7.363 | 12,651,032 | 12,651,072 | 5,116,872 | 977,240 | 219 |
| dense | 320,000 | 384 | 32 | 31,212 | 390.134 | 12,651,032 | 12,651,072 | 29,536,792 | 25,397,160 | 471 |

The separate snapshot and helper meters make their simultaneously live storage
visible. The helper clones footprint indexes and builds the complete publication
before returning. Its retained publication contains target lookup/list storage
and the new instance. The deduplicated bottom platform union uses 31,212 actual
foundation reads in each case.

Admission timings start with a ready immutable snapshot and end with a prepared
publication. They exclude dependency acquisition/generation, the service's staged
four-chunk-per-turn snapshot copying, final dependency/overlay version checks,
authority publication, per-client response preparation and delivery, client index
installation, meshing, and persistence. In particular, the direct admission
benchmark does not include the service helper's per-client instance response
clones. Many concurrent sites, dense preexisting indexes, near-floor immutable
lookups, and source churn need separate measurements.

The current dependency snapshot allowances are 1,024 chunks and 128 MiB of
estimated requested ownership. Source index capacities are included in the
estimate; allocator page overhead is additional. These are technical admission
resource settings, independent of the selected-volume and geometric limits.

## Client copy and interleaved fulfillment

The headless main integration fixture copied 320,000 predicted cells from 50
retained full-block source chunks into a 320,000-byte snapshot in **14.090–15.041 ms**
in three ReleaseFast runs. This measures the actual single client lookup/copy pass, rather
than the compiler runner's memcpy baseline. It excludes source loading and
helper validation. These were runs under concurrent app/test load, not a
frame-time percentile or guarantee. Debug took 104.001 ms in an earlier run.

The service fixture `interleaved fulfillment across 128 sites keeps bounded
support work and coalesces replies` builds 128 adjacent 4×4×4 sites in an
interleaved bottom-up order. All chunks are resident, each target has a real
below block, and the single client subscribes to two affected chunks. One
controlled batch of 8,192 fills measured:

| Work | Observed result |
| --- | ---: |
| Authority fill path, including index/metadata updates and acknowledgment preparation | 8.075 ms |
| Physical support reads | 8,192; exactly one per fill |
| Ordinary structural validation calls | 0 |
| Deferred road entries | 0; fixture has no adaptive roads |
| Final response flush | 0.271 ms |
| Block snapshots | 2, totaling 65,536 raw block bytes |
| Individual acknowledgments | 8,192 |
| Encoded fulfillment records | 106,496 bytes; exactly 13 per fill |

Additional runs measured 7.544–13.722 ms for fills and 0.265–0.292 ms for the flush under varying concurrent app/test load. These observations are not a percentile estimate.

This is an authority-function fixture using the test allocator. It excludes
library/site admission, NPC logic, material delivery and player inventory
transfers, endpoint command admission, frame scheduling, client reconciliation,
meshing/GPU work, and disk writes. Its controlled batch bypasses the default
256-operation endpoint capacity to isolate fulfillment and coalescing. Normal
batch boundaries can produce more snapshots. It establishes neither full-game
throughput nor a per-frame budget. Separate integration tests cover player
inventory atomicity and persistence/restart.

## Focused correctness checks

The following commands passed during implementation:

```sh
zig build test-blueprint
zig build test-blueprint-service
zig build test-capture
```

Compiler/admission fixtures cover cancellation and allocation failures, raw
bounds, material normalization, virtual versus real platforms, deterministic
support conversion, the 20/21-level boundary, composed real/planned dependents,
unknown dependencies, and the five-neighbor fulfillment support bound. Service
fixtures also check that accepted fulfillment queues road work without entering
ordinary structural validation, delayed safe road plans publish atomically,
unsafe plans preserve the accepted fill, and a full road queue rejects before
terrain/progress mutation. These checks do not replace the complete acceptance
matrix or native UI playtesting.
