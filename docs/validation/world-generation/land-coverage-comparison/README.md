# Soft land coverage: geography preparation comparison

The old generator filled exactly 61% of macro cells. The new one stops at a
deterministic cost horizon tuned for approximately 35% final land. Stronger
regional costs deform growth fronts, and each accepted cell's cost is evaluated
once for its four outgoing edges. Connectivity, water gaps, islands, memory
bounds, and feature validity remain required.

| Geography preparation | Before | After |
| --- | ---: | ---: |
| Median | 8.336 ms | 4.195 ms |
| p95 | 8.907 ms | 5.197 ms |
| Total, 256 seeds | 2149.348 ms | 1082.916 ms |
| Accepted | 256/256 | 256/256 |
| Retained requested bytes | 655,360 | 655,360 |
| Peak requested bytes | 2,097,152 | 2,097,152 |
| Allocation requests | 7 | 7 |

The median fell 49.7% in this experiment. This isolates `Geography.init`, not
complete world preparation or chunk regeneration. Outputs intentionally differ;
the comparison combines less land growth with fewer cost-field evaluations.
It does not isolate the contributions of those changes. The retained arrays
still cover the entire macro grid, so their sizes are unchanged.

Both runs used the same 256 seeds (12345, then 0–254), default dimensions,
ReleaseFast on an Apple M4 Max, and three warmups. The runs executed serially.
The timer includes geography allocations and coast preparation, excludes
deinitialization and diagnostic printing, and does not include deposits,
first-start selection, meshing, disk, or GPU work. These measurements on one
platform do not establish a latency guarantee.

The separate [full seed suite](../README.md#seed-suite-measurements) measures
final land coverage over seeds 12345–12600. The [before/after map](../land-before-after.png)
shows the changed footprint with identical climate boundaries. Highly elongated
custom worlds receive no special growth adjustment; the default profile is the
coverage tuning target.

## Reproduce

[Before](before.txt) and [after](after.txt) retain individual timings and coarse
areas. [Summary](summary.json) uses empirical percentiles with linear
interpolation at `(n−1)p`. [Manifest](manifest.json) records source hashes and
the baseline commit; [benchmark.zig](benchmark.zig) is the common harness.
The baseline commit is `9717832bdf8efa98760b9f215d403105425f0348`. The after
sources are the production files checked in with this report; verify their
hashes against the manifest when using another checkout.

From the repository root, export the five modules listed in the manifest into
separate temporary before/after directories: use `git show <baseline>:src/voxel_app/<module>`
for before and copy `src/voxel_app/<module>` for after. Copy `benchmark.zig` to
`main.zig` in each directory. Run each directory serially with Zig 0.16.0:

```sh
zig run -O ReleaseFast /tmp/land-before/main.zig 2> /tmp/land-before.txt
zig run -O ReleaseFast /tmp/land-after/main.zig 2> /tmp/land-after.txt
```

When sandboxed, pass `--global-cache-dir /private/tmp/zig-worldgen-cache`.
Do not include compilation time in the reported per-seed preparation timings.
