# Windowed construction A/B evidence at radius 5

Measured commit: `01696cd780a5ec1f306243dd3413a2c6117c3a9f` (ReleaseFast).
Machine: Apple M4 Max, 16 CPU cores, 64 GiB, Metal/macOS 26.7.1.
Date: 2026-11-14; physical framebuffer: 1920×1080.

```sh
python3 scripts/benchmark_client_visuals.py --render-radius 5 --output-dir /private/tmp/client-visual-ab-radius5-2026-11-14
```

The scenario supplied 4,096 commands over eight seconds per run, with three
repetitions for each policy and camera (12 runs). All passed validation. Render
radius 5 keeps 484 resident chunks, using the same finite construction fixture and
local block-data radius 1 as the radius 3 measurements.

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
