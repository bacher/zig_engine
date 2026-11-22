# Extraction zone save and reopen benchmark

```sh
zig build bench-extraction-save -Doptimize=ReleaseFast
```

The benchmark uses the default capture and store limits, the Zig test allocator, and the
flat generator with seed zero in a 512×256×8-chunk world. Each case creates three
disposable worlds under `.zig-cache/tmp`. The fixture registers the zones and prepares
their starting occupancy directly in the zone state, then saves and compacts the initial
world. It applies one stone removal through the ordinary authority edit and measures the
second capture. Every second capture has exactly one dirty terrain chunk. Registration,
setup excavation, that single removal, and teardown are outside the measured intervals.

Occupied cases start with all marked cells filled. Partial cases keep alternating X
columns before the final removal. Exhausted cases start with one remaining cell across
all claims and remove it. The zero-zone control removes the same cell from ordinary
terrain. Every reopened world is checked for the expected claim count, remaining cell
count, and the removal at the target.

Capture wall and CPU times cover the synchronous `WorldDataService.beginCapture` call
on the executor, including the detached zone image and writer startup. The benchmark
waits for the WAL commit before measuring reopen. Store open includes WAL recovery and
base compaction. Service restore measures rebuilding the authoritative state from the
opened store. The two are timed consecutively on a fresh service with the OS page cache
left intact.

Zone bytes count the encoded replacement image. WAL bytes count the second transaction,
including its footer and changed terrain, with the segment header excluded. Base bytes
give the compacted base file length after reopen. These are logical file sizes.

## Measurements

Run on macOS 26.7.1 (25G241), arm64, with Zig 0.16.0 and `ReleaseFast`.
Times are medians of three independent samples. Byte counts were identical within each case.

| Zones | Bounds per zone | Occupancy case | Cells remaining | Capture wall ms | Capture CPU ms | Store open ms | Service restore ms | Reopen ms | Zone bytes | WAL bytes | Base bytes |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | — | control | 0 | 0.057 | 0.057 | 22.759 | 0.109 | 22.875 | 0 | 502 | 568 |
| 1 | 16×16×4 | occupied | 1,023 | 0.216 | 0.215 | 26.983 | 0.669 | 27.672 | 3,132 | 3,868 | 3,934 |
| 1 | 16×16×4 | partial | 511 | 0.178 | 0.177 | 27.099 | 0.726 | 27.697 | 1,596 | 2,332 | 2,398 |
| 1 | 16×16×4 | exhausted | 0 | 0.107 | 0.105 | 25.470 | 0.487 | 25.957 | 49 | 785 | 851 |
| 32 | 16×16×4 | occupied | 32,767 | 1.299 | 1.298 | 32.552 | 11.080 | 43.680 | 99,573 | 100,309 | 117,921 |
| 32 | 16×16×4 | partial | 16,383 | 0.939 | 0.926 | 29.588 | 9.019 | 38.463 | 50,421 | 51,157 | 68,769 |
| 32 | 16×16×4 | exhausted | 0 | 0.095 | 0.093 | 28.948 | 4.360 | 33.308 | 824 | 1,560 | 19,172 |
| 256 | 16×16×4 | occupied | 262,143 | 9.464 | 9.463 | 71.222 | 63.234 | 135.089 | 796,437 | 797,173 | 941,569 |
| 256 | 16×16×4 | partial | 131,071 | 5.016 | 5.008 | 63.869 | 54.076 | 117.322 | 403,221 | 403,957 | 548,353 |
| 256 | 16×16×4 | exhausted | 0 | 0.077 | 0.076 | 56.426 | 26.878 | 83.080 | 6,424 | 7,160 | 151,556 |
| 1 | 128×128×64 | occupied | 1,048,575 | 81.765 | 81.746 | 85.597 | 93.897 | 179.147 | 3,146,222 | 3,146,462 | 3,148,698 |
| 1 | 128×128×64 | partial | 524,287 | 42.811 | 42.793 | 58.889 | 53.548 | 112.250 | 1,573,358 | 1,573,598 | 1,575,834 |
| 1 | 128×128×64 | exhausted | 0 | 0.045 | 0.044 | 25.317 | 11.684 | 37.001 | 49 | 289 | 2,525 |

Service restore validates world-data for every reserved cell, including the full
volume of an exhausted zone.
[World-data recovery](../../src/voxel_app/world_data_service.zig)
