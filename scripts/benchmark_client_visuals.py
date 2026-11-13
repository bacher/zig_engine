#!/usr/bin/env python3
"""Run the real, windowed voxel client and compare visual scheduling policies.

Build the installed client with ReleaseFast first. Each process creates the same
fresh ephemeral world internally. This script does not build or control the UI.
Raw client summaries, frame/event CSVs, and stdout/stderr logs are retained.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


POLICIES = ("immediate", "budgeted")
METRICS = (
    "frame", "interval", "update", "draw", "prepare", "upload",
    "terrain_submit_latency", "miniature_submit_latency",
)
QUANTILES = ("p50_ms", "p95_ms", "p99_ms", "max_ms", "mean_ms")
COUNTERS = (
    "frame_count", "planned_edits", "admitted_edits", "accepted_edits",
    "rejected_edits", "unresolved_visuals", "frames_over_16_7ms",
    "frames_over_33_3ms", "peak_queue",
)


def number(value: Any, label: str, *, integer: bool = False) -> int | float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a number")
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"{label} must be finite and nonnegative")
    if integer and not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    return value


def validate_summary(summary: Any, *, policy: str, rate: int,
                     duration: float, camera: str) -> None:
    """Reject incomplete workloads before producing performance comparisons."""
    if (not isinstance(summary, dict) or type(summary.get("schema_version")) is not int
            or summary["schema_version"] != 1):
        raise ValueError("unsupported or missing summary schema_version")
    if summary.get("valid") is not True:
        raise ValueError(f"client marked run invalid: {summary.get('invalid_reason')}")
    for key, expected in (("policy", policy), ("rate", rate), ("camera", camera)):
        if summary.get(key) != expected:
            raise ValueError(f"{key}: expected {expected!r}, got {summary.get(key)!r}")
    actual_duration = number(summary.get("duration_seconds"), "duration_seconds")
    if not math.isclose(actual_duration, duration, rel_tol=1e-9, abs_tol=1e-9):
        raise ValueError(f"duration_seconds: expected {duration}, got {actual_duration}")
    resolution = summary.get("resolution")
    if not isinstance(resolution, list) or len(resolution) != 2:
        raise ValueError("resolution must contain width and height")
    for dimension in resolution:
        if number(dimension, "resolution", integer=True) == 0:
            raise ValueError("resolution dimensions must be positive")
    for key in COUNTERS:
        number(summary.get(key), key, integer=True)
    if summary["frame_count"] == 0:
        raise ValueError("run contains no frames")
    if summary["planned_edits"] != rate * duration:
        raise ValueError("planned edits do not match the requested rate * duration")
    if not (summary["planned_edits"] == summary["admitted_edits"] ==
            summary["accepted_edits"] > 0):
        raise ValueError("planned, admitted, and accepted edits must match and be positive")
    if summary["rejected_edits"] != 0:
        raise ValueError("run rejected edits")
    if summary["unresolved_visuals"] != 0:
        raise ValueError("run has unresolved visuals after draining")
    acceptance_window = number(summary.get("acceptance_window_seconds"), "acceptance_window_seconds")
    if acceptance_window <= 0 or acceptance_window < duration:
        raise ValueError("acceptance_window_seconds must be positive and at least the input duration")
    throughput = number(summary.get("accepted_edits_per_second"), "accepted_edits_per_second")
    if not math.isclose(throughput, summary["accepted_edits"] / acceptance_window,
                        rel_tol=1e-6, abs_tol=1e-9):
        raise ValueError("accepted_edits_per_second does not match accepted edits / acceptance window")
    if not isinstance(summary.get("final_checksum"), str) or not summary["final_checksum"]:
        raise ValueError("missing final_checksum")
    number(summary.get("drain_ms"), "drain_ms")
    metrics = summary.get("metrics")
    if not isinstance(metrics, dict):
        raise ValueError("missing metrics")
    for metric in METRICS:
        values = metrics.get(metric)
        if not isinstance(values, dict):
            raise ValueError(f"missing metrics.{metric}")
        number(values.get("count"), f"metrics.{metric}.count", integer=True)
        for quantile in QUANTILES:
            number(values.get(quantile), f"metrics.{metric}.{quantile}")
    if metrics["frame"]["count"] != summary["frame_count"]:
        raise ValueError("frame metric count does not match frame_count")
    for metric in ("terrain_submit_latency", "miniature_submit_latency"):
        if metrics[metric]["count"] != summary["accepted_edits"]:
            raise ValueError(f"{metric} count does not match accepted_edits")


def validate_equivalence(summaries: list[dict[str, Any]]) -> None:
    """All repetitions for one camera must execute an equivalent workload."""
    if not summaries:
        raise ValueError("no runs to compare")
    reference = summaries[0]
    for summary in summaries[1:]:
        for key in ("camera", "rate", "duration_seconds", "resolution", "planned_edits",
                    "admitted_edits", "accepted_edits", "rejected_edits", "final_checksum"):
            if summary[key] != reference[key]:
                raise ValueError(
                    f"non-equivalent runs: {key} differs "
                    f"({reference[key]!r} vs {summary[key]!r})")


def aggregate(summaries: list[dict[str, Any]]) -> dict[str, Any]:
    """Take medians of run statistics; never pool frames across processes."""
    if not summaries:
        raise ValueError("no runs to aggregate")
    result: dict[str, Any] = {"runs": len(summaries)}
    for key in (*COUNTERS, "drain_ms", "acceptance_window_seconds", "accepted_edits_per_second"):
        result[key] = statistics.median(summary[key] for summary in summaries)
    result["metrics"] = {
        metric: {
            key: statistics.median(summary["metrics"][metric][key] for summary in summaries)
            for key in ("count", *QUANTILES)
        }
        for metric in METRICS
    }
    return result


def compare(baseline: dict[str, Any], budgeted: dict[str, Any]) -> dict[str, Any]:
    def delta(before: float, after: float) -> dict[str, Any]:
        return {"delta": after - before,
                "percent": (after / before - 1) * 100 if before else None}

    return {
        metric: {key: delta(baseline["metrics"][metric][key], budgeted["metrics"][metric][key])
                 for key in QUANTILES}
        for metric in METRICS
    }


def execution_order(repetitions: int, cameras: list[str]):
    for camera in cameras:
        for repetition in range(1, repetitions + 1):
            policies = POLICIES if repetition % 2 else tuple(reversed(POLICIES))
            for policy in policies:
                yield camera, repetition, policy


def validate_workload(rate: int, duration: int) -> None:
    number(rate, "rate", integer=True)
    number(duration, "duration", integer=True)
    if not 1 <= rate <= 8192:
        raise ValueError("rate must be between 1 and 8192 edits per second")
    if not 1 <= duration <= 60:
        raise ValueError("duration must be between 1 and 60 whole seconds")
    if rate * duration > 65536:
        raise ValueError("rate * duration must not exceed 65536 edits")


def build_command(binary: Path, prefix: Path, *, policy: str, rate: int,
                  duration: int, camera: str) -> list[str]:
    validate_workload(rate, duration)
    return [str(binary), "--benchmark-visuals", str(prefix),
            "--visual-policy", policy, "--benchmark-rate", str(rate),
            "--benchmark-duration", str(duration), "--benchmark-camera", camera]


def save_report(root: Path, report: dict[str, Any]) -> None:
    (root / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")


def run(args: argparse.Namespace) -> int:
    validate_workload(args.rate, args.duration)
    binary = args.binary.expanduser().resolve()
    if not binary.is_file():
        raise ValueError(f"client binary does not exist: {binary}; build ReleaseFast first")
    if args.output_dir:
        root = args.output_dir.expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        if any(root.iterdir()):
            raise ValueError(f"output directory must be empty: {root}")
    else:
        root = Path(tempfile.mkdtemp(prefix="voxel-client-visuals-"))
    cameras = ["orbit", "travel"] if args.camera == "both" else [args.camera]
    timeout = args.timeout if args.timeout is not None else max(120.0, args.duration * 4 + 60)
    report: dict[str, Any] = {
        "schema_version": 1, "valid": False, "status": "running", "binary": str(binary),
        "rate": args.rate, "duration_seconds": args.duration, "cameras": cameras,
        "repetitions": args.repetitions, "timeout_seconds": timeout, "runs": [],
        "aggregation": "median of per-run statistics; frames are not pooled",
        "baseline": "immediate: same visual FIFO, unlimited per-frame admission",
    }
    save_report(root, report)
    print(f"Artifacts: {root}", flush=True)
    print("Launching the real windowed client sequentially; leave its windows running.", flush=True)
    try:
        for camera, repetition, policy in execution_order(args.repetitions, cameras):
            prefix = root / f"{len(report['runs']) + 1:02d}-{camera}-r{repetition:02d}-{policy}"
            command = build_command(binary, prefix, policy=policy, rate=args.rate,
                                    duration=args.duration, camera=camera)
            paths = {kind: str(prefix) + suffix for kind, suffix in (
                ("summary", ".summary.json"), ("frames", ".frames.csv"),
                ("events", ".events.csv"), ("log", ".log"))}
            record: dict[str, Any] = {
                "camera": camera, "repetition": repetition, "policy": policy,
                "command": command, "artifacts": paths, "status": "running",
            }
            report["runs"].append(record)
            save_report(root, report)
            print(f"  {camera} repetition {repetition}/{args.repetitions}: {policy}", flush=True)
            try:
                with Path(paths["log"]).open("wb") as log:
                    process = subprocess.run(command, cwd=binary.parent, stdout=log,
                                             stderr=subprocess.STDOUT, timeout=timeout, check=False)
                record["returncode"] = process.returncode
                if process.returncode != 0:
                    raise ValueError(f"client exited with status {process.returncode}; see {paths['log']}")
                for kind in ("summary", "frames", "events"):
                    if not Path(paths[kind]).is_file():
                        raise ValueError(f"client did not write {paths[kind]}")
                summary = json.loads(Path(paths["summary"]).read_text())
                validate_summary(summary, policy=policy, rate=args.rate,
                                 duration=args.duration, camera=camera)
                record["summary"] = summary
                comparable = [item["summary"] for item in report["runs"]
                              if item["camera"] == camera and "summary" in item]
                validate_equivalence(comparable)
                record["status"] = "valid"
            except (ValueError, OSError, subprocess.TimeoutExpired) as error:
                record["status"] = "failed"
                record["error"] = str(error)
                raise
            save_report(root, report)

        report["results"] = {}
        for camera in cameras:
            by_policy = {
                policy: aggregate([record["summary"] for record in report["runs"]
                                   if record["camera"] == camera and record["policy"] == policy])
                for policy in POLICIES
            }
            report["results"][camera] = {
                "policies": by_policy,
                "budgeted_minus_immediate": compare(by_policy["immediate"], by_policy["budgeted"]),
            }
        report.update(valid=True, status="complete")
    except (ValueError, OSError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        report.update(status="failed", error=str(error) or "interrupted")
        save_report(root, report)
        print(f"FAILED: {report['error']}\nRaw artifacts and failure report: {root}", file=sys.stderr)
        return 1

    save_report(root, report)
    print("\nMedian per-run timings (ms; negative comparison deltas mean lower):")
    print(f"{'camera':<8} {'policy':<10} {'frames':>8} {'accepted/s':>10} "
          f"{'interval p95':>12} {'interval p99':>12} {'frame p95':>10} {'frame p99':>10} "
          f"{'frame max':>10} {'upload p95':>11} {'terrain p95':>12} {'mini p95':>10}")
    for camera in cameras:
        for policy in POLICIES:
            result = report["results"][camera]["policies"][policy]
            metrics = result["metrics"]
            print(f"{camera:<8} {policy:<10} {result['frame_count']:8.0f} "
                  f"{result['accepted_edits_per_second']:10.3f} "
                  f"{metrics['interval']['p95_ms']:12.3f} {metrics['interval']['p99_ms']:12.3f} "
                  f"{metrics['frame']['p95_ms']:10.3f} {metrics['frame']['p99_ms']:10.3f} "
                  f"{metrics['frame']['max_ms']:10.3f} {metrics['upload']['p95_ms']:11.3f} "
                  f"{metrics['terrain_submit_latency']['p95_ms']:12.3f} "
                  f"{metrics['miniature_submit_latency']['p95_ms']:10.3f}")
    print(f"Equivalent admitted/accepted workloads and final checksums verified. Report: {root / 'report.json'}")
    return 0


def positive_float(value: str) -> float:
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return result


def positive_int(value: str) -> int:
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] /
                        "zig-out/bin/zig_engine_voxel_app", help="installed ReleaseFast voxel client")
    parser.add_argument("--output-dir", type=Path, help="empty output directory (default: retained temporary directory)")
    parser.add_argument("--repetitions", type=positive_int, default=3)
    parser.add_argument("--rate", type=positive_int, default=512,
                        help="intended edits per second, at most 8192 (default: 512)")
    parser.add_argument("--duration", type=positive_int, default=8,
                        help="whole workload seconds per launch, at most 60 (default: 8); rate * duration <= 65536")
    parser.add_argument("--camera", choices=("orbit", "travel", "both"), default="both")
    parser.add_argument("--timeout", type=positive_float, help="maximum seconds per process, including startup and drain")
    args = parser.parse_args()
    try:
        return run(args)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    sys.exit(main())
