# Warehouse specification model checks

Run from the repository root with Python 3; no packages are required:

```sh
python3 docs/validation/warehouse_model.py
```

Expected output:

```text
PASS: 3 hash fixtures; all 16 selectors across 32768 local origins; wrapped X
PASS: 25 footprint dimensions; 196 distinct center/direction layouts
PASS: 2053700 aggregate N/A/C/I states; packing, admission, demand, handover
PASS: 25 halo geometries; full-body fit and vertical chunk-boundary case
Specification model only; no runtime, concurrency, persistence, or performance validation.
```

The [dependency-free verifier](warehouse_model.py) retains the executable arithmetic checks
used during specification review. Any failed invariant exits with an error, including when
Python runs with optimization enabled. It covers:

- [Q5](../../specs/features/warehouses.md#q5--exact-center-and-ordering): pinned SplitMix64
  fixtures, all local-origin selector combinations, wrapped-address equivalence, all dimension/
  center/direction variants, unique columns, inner-layer priority, late corners, the preferred
  second column where applicable, the exact east-facing 5×5 reference, and the 4×4 item 16/17
  boundary. It checks buffer-level order and physical slot coverage for each active prefix.
- [Q2](../../specs/features/warehouses.md#q2--what-does-active-capacity-restrict): every
  N in 1..25, A in 0..N, C in 0..6N, and I in 0..6N-C. All stock prefixes have contiguous
  stacks, preserve quantity, and drain disabled columns first. Aggregate checks cover demand,
  one-item and maximum-batch admission, reserved handover after capacity reduction, and the
  documented N=9 example. Some N values cannot form an allowed rectangle; testing them still
  checks the general count-based formulas.
- [Q26](../../specs/features/warehouses.md#q26--reserved-halo-displacement-fallback): all
  25 footprints have at most 24 halo cells and fit the current 0.6×0.6×1.8 player body.
  Feet at local z=31 require body data from a second vertical chunk. These geometric facts
  do not establish floor support, loaded data, or an actual runtime recovery path.

The warehouse spec remains normative. Update this model deliberately when its formulas
change, and reuse its pinned vectors when implementing Zig/client agreement checks. This is
an independent reference model, not a parser or a test of the future runtime. It cannot prove
concurrency safety, save/recovery coherence, command deduplication, collision integration,
rendering correctness, or sustainable throughput. No timing here is a game benchmark.
