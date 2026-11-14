# Windowed construction A/B evidence

Measured commit: `4ece72690f35d1e79a75bc7d62e50a7ccc1ed854` (ReleaseFast).
Machine: Apple M4 Max, 16 CPU cores, 64 GiB, Metal/macOS 26.7.1.
Date: 2026-11-14; physical framebuffer: 1920×1080.

```sh
python3 scripts/benchmark_client_visuals.py --output-dir /private/tmp/client-visual-ab-2026-11-14
```

The default scenario supplied 4,096 commands over eight seconds per run, with three
repetitions for each policy and camera (12 runs). All passed validation. The command
ran after a successful short smoke, without concurrent builds or test workloads.

- `report.json`: unchanged driver output, including every summary and median comparison.
- `runs.csv`: compact per-run table derived from that report.
- `runner.log`: unchanged driver stdout/stderr.
- `raw.tar.gz`: all 49 original files: report, 12 frame CSVs, 12 event CSVs, 12 summaries
  and 12 process logs. Member basenames match the original report's artifact paths.
- `manifest.json`: SHA-256 hashes of every original file, archive and measured binary.

The report retains original absolute temporary paths; use archive member basenames
when inspecting the data elsewhere. Extraction is unnecessary for verification:
Python's `tarfile` can read members and compare their contents to the manifest hashes.
The archive uses normalized tar metadata and a zero gzip timestamp.

See [method and interpretation](../../validation/client-construction-visuals.md).
Preparation spikes decreased, while complete-client pacing did not improve and
receipt-to-submission latency increased. The comparison isolates the preparation
budget within the same FIFO/cache; it does not compare all PR #59 code against main.
