# Natural chunk-fill input reuse: isolated comparison

Typed borrowed inputs now hold floor thickness and deposit candidates once per horizontal column while filling its 32 Z cells. The point material oracle still evaluates its own inputs for each call; both paths share the pure material-precedence helper. No persistent `NaturalColumn` fields or cache capacity were added.

## Method

Zig 0.16.0, ReleaseFast, aarch64-macos; seed 12345; default 2048 × 1024 × 32 chunk layout; beaches false and true in every run. Each run records 31 samples for each of 11 representative sites and the existing cold/vertical workloads. Compile each snapshot with `zig build benchmark-generation -Doptimize=ReleaseFast -- 12345 31`, then run the compiled binaries with arguments `12345 31` in baseline, optimized, optimized, baseline order. The four paired direct-binary logs below are the comparison; initial build/run logs were excluded from this comparison. Concurrent CPU-heavy work was avoided during paired runs.

The snapshots have identical source file sets, build files, geography, settings, benchmark and seed. Only `natural_generator.zig` differs, in the per-column input type, material helpers and fill loop. All 211 source files per snapshot were rehashed against the original full manifest. See the [compact source manifest](compact-source-manifest.json) and [exact source diff](column-fill-source.diff).

## Results

Chunk-fill median microseconds. Each cell gives the two run medians in order; these are not pooled statistics.

| Site | Baseline, beaches false | Reuse, beaches false | Baseline, beaches true | Reuse, beaches true |
|---|---:|---:|---:|---:|
| plains | 174, 177 | 136, 137 | 175, 175 | 137, 130 |
| mainland_coast | 38, 35 | 43, 48 | 37, 36 | 48, 43 |
| island_coast | 35, 35 | 43, 45 | 36, 35 | 44, 44 |
| steep_shore | 43, 39 | 42, 43 | 44, 44 | 43, 41 |
| desert | 43, 43 | 43, 46 | 43, 42 | 43, 42 |
| dense_forest | 71, 70 | 60, 61 | 71, 70 | 56, 61 |
| deposit | 248, 249 | 162, 166 | 249, 253 | 169, 163 |
| x_seam | 34, 33 | 34, 34 | 37, 33 | 35, 34 |
| ocean | 34, 33 | 46, 44 | 34, 34 | 40, 44 |
| polar | 39, 38 | 45, 44 | 38, 37 | 44, 44 |
| mountain | 84, 84 | 71, 68 | 84, 85 | 68, 69 |

Workload median milliseconds, again listing both run medians.

| Workload | Beaches | Baseline | Reuse |
|---|---|---:|---:|
| Cold column + surface chunk | false | 0.326, 0.316 | 0.297, 0.294 |
| Cold column + surface chunk | true | 0.318, 0.330 | 0.294, 0.293 |
| Cached column, 32 vertical chunks | false | 6.714, 6.724 | 5.448, 5.297 |
| Cached column, 32 vertical chunks | true | 6.679, 6.745 | 5.248, 5.271 |

Plains, deposit-heavy, forest and vertical fills improve in this comparison. Water/empty-dominated ocean, polar and several coastal fills regress by a few microseconds because the uniform loop prepares floor and candidate inputs for every horizontal column even when all cells take early material exits. This evidence does not support a general speedup claim.

All 22 site digests, face counts and chunk/mesh requested-memory counters match across all four paired runs. Start digests and metadata fingerprints match for both beach settings. Each run also reports matching derived mesh, boundary and climate hashes after eviction and restart. The start digest is `ff545b0034f3e164fa9b6aeca23bcf716fe836a8f51838be17211911a75f4c7a`; metadata fingerprint is `d17867cf8466f4cb`.

Identical size counters: 7 preparation allocations; 2,122,224 peak requested preparation bytes; 418,288 live prepared bytes; 27,200 column bytes, including 27,168 natural-column bytes; 64 cached columns; 1,740,800 retained-column upper-bound bytes; 32,768 chunk scratch stack bytes.

The snapshots use geography from before the final coastline-distance correction. This isolates input reuse with matching terrain; final coastline changes need separate absolute benchmarks. Two runs per variant, 31 samples per site and one seed/platform provide microbenchmark evidence, without confidence intervals or end-to-end gameplay conclusions.

## Evidence

- [Parsed comparison](comparison.json) contains all site/workload medians, parity fields and counters.
- [Log manifest](log-manifest.json) records SHA256 hashes, binary hashes, protocol and run order.
- Paired logs in execution order: [baseline 1](baseline-paired-1.txt), [reuse 1](optimized-paired-1.txt), [reuse 2](optimized-paired-2.txt), [baseline 2](baseline-paired-2.txt).
The log manifest also records hashes of the two initial build/run logs, which are excluded from the comparison and this committed evidence. The temporary full snapshots were used to verify the compact source manifest; the exact source difference is retained here.
