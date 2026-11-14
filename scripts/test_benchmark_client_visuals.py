"""Pure summary validation/aggregation tests; no client processes or windows."""

import copy
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import benchmark_client_visuals as benchmark


def summary(policy="immediate", frame_p95=5.0, render_radius=3):
    return {
        "schema_version": 1, "valid": True, "invalid_reason": None,
        "policy": policy, "rate": 512, "duration_seconds": 8.0, "camera": "orbit",
        "render_radius": render_radius, "resolution": [1280, 720], "frame_count": 100,
        "planned_edits": 4096, "admitted_edits": 4096, "accepted_edits": 4096,
        "acceptance_window_seconds": 8.0, "accepted_edits_per_second": 512.0,
        "rejected_edits": 0, "final_checksum": "0123456789abcdef", "unresolved_visuals": 0,
        "metrics": {metric: {"count": 4096 if metric.endswith("_submit_latency") else 100,
                             "p50_ms": 2.0, "p95_ms": frame_p95,
                             "p99_ms": 8.0, "max_ms": 10.0, "mean_ms": 3.0}
                    for metric in benchmark.METRICS},
        "frames_over_16_7ms": 0, "frames_over_33_3ms": 0, "peak_queue": 2, "drain_ms": 3.0,
    }


def validate(value, **kwargs):
    options = dict(policy="immediate", rate=512, duration=8.0, camera="orbit", render_radius=3)
    options.update(kwargs)
    benchmark.validate_summary(value, **options)


class ValidationTests(unittest.TestCase):
    def test_accepts_complete_run(self):
        validate(summary())

    def test_accepts_requested_render_radius(self):
        validate(summary(render_radius=5), render_radius=5)

    def test_rejects_missing_or_wrong_render_radius(self):
        for wrong in (None, 3, 5.0, True):
            with self.subTest(render_radius=wrong):
                value = summary(render_radius=wrong)
                if wrong is None:
                    del value["render_radius"]
                with self.assertRaisesRegex(ValueError, "render_radius"):
                    validate(value, render_radius=5)

    def test_rejects_client_invalidity(self):
        value = summary()
        value.update(valid=False, invalid_reason="drain timed out")
        with self.assertRaisesRegex(ValueError, "drain timed out"):
            validate(value)

    def test_rejects_mismatched_metadata(self):
        for key, wrong in (("policy", "budgeted"), ("rate", 128), ("camera", "travel"),
                           ("duration_seconds", 3), ("schema_version", 2)):
            with self.subTest(key=key):
                value = summary()
                value[key] = wrong
                with self.assertRaises(ValueError):
                    validate(value)

    def test_rejects_incomplete_or_rejected_workload(self):
        for key, wrong in (("planned_edits", 5000), ("admitted_edits", 3000),
                           ("accepted_edits", 3000), ("rejected_edits", 1),
                           ("unresolved_visuals", 1), ("frame_count", 0)):
            with self.subTest(key=key):
                value = summary()
                value[key] = wrong
                with self.assertRaises(ValueError):
                    validate(value)

    def test_rejects_missing_negative_or_nonfinite_metrics(self):
        for wrong in (None, -1, float("nan"), float("inf"), True):
            with self.subTest(value=wrong):
                value = summary()
                value["metrics"]["frame"]["p95_ms"] = wrong
                with self.assertRaises(ValueError):
                    validate(value)

    def test_rejects_equally_truncated_planned_admitted_and_accepted_counts(self):
        value = summary()
        value.update(planned_edits=4000, admitted_edits=4000, accepted_edits=4000)
        with self.assertRaisesRegex(ValueError, "requested rate"):
            validate(value)

    def test_rejects_frame_count_mismatch(self):
        value = summary()
        value["metrics"]["frame"]["count"] = 101
        with self.assertRaisesRegex(ValueError, "frame_count"):
            validate(value)

    def test_accepts_throughput_measured_through_acknowledgement_drain(self):
        value = summary()
        value.update(acceptance_window_seconds=16.0, accepted_edits_per_second=256.0)
        validate(value)

    def test_rejects_missing_latency_timestamps(self):
        for metric in ("terrain_submit_latency", "miniature_submit_latency"):
            with self.subTest(metric=metric):
                value = summary()
                value["metrics"][metric]["count"] = 4095
                with self.assertRaisesRegex(ValueError, metric):
                    validate(value)

    def test_rejects_invalid_acceptance_window(self):
        for wrong in (None, 0, 7.9, -1, float("nan"), float("inf")):
            with self.subTest(value=wrong):
                value = summary()
                value["acceptance_window_seconds"] = wrong
                with self.assertRaisesRegex(ValueError, "acceptance_window_seconds"):
                    validate(value)

    def test_rejects_inconsistent_or_nonfinite_throughput(self):
        for wrong in (None, 0, 511, float("nan"), float("inf")):
            with self.subTest(value=wrong):
                value = summary()
                value["accepted_edits_per_second"] = wrong
                with self.assertRaisesRegex(ValueError, "accepted_edits_per_second"):
                    validate(value)

    def test_allows_different_frame_counts_for_same_workload(self):
        immediate = summary()
        budgeted = summary("budgeted")
        budgeted["frame_count"] = 150
        budgeted["metrics"]["frame"]["count"] = 150
        validate(budgeted, policy="budgeted")
        benchmark.validate_equivalence([immediate, budgeted])

    def test_rejects_checksum_resolution_or_workload_mismatch(self):
        for key, wrong in (("final_checksum", "different"), ("resolution", [640, 480]),
                           ("render_radius", 5),
                           ("admitted_edits", 4000), ("accepted_edits", 4000),
                           ("rejected_edits", 1), ("planned_edits", 4000)):
            with self.subTest(key=key):
                different = summary("budgeted")
                different[key] = wrong
                with self.assertRaisesRegex(ValueError, key):
                    benchmark.validate_equivalence([summary(), different])


class AggregationTests(unittest.TestCase):
    def test_uses_median_per_run_statistics_without_frame_weighting(self):
        values = [summary(frame_p95=1.0), summary(frame_p95=9.0), summary(frame_p95=5.0)]
        values[0]["frame_count"] = 100000
        values[0]["metrics"]["frame"]["count"] = 100000
        result = benchmark.aggregate(values)
        self.assertEqual(result["runs"], 3)
        self.assertEqual(result["metrics"]["frame"]["p95_ms"], 5.0)
        self.assertEqual(result["frame_count"], 100)
        self.assertEqual(result["accepted_edits_per_second"], 512.0)

    def test_aggregation_preserves_input(self):
        values = [summary()]
        original = copy.deepcopy(values)
        benchmark.aggregate(values)
        self.assertEqual(values, original)

    def test_aggregates_actual_acceptance_throughput_without_recomputing_input_rate(self):
        values = [summary(), summary(), summary()]
        for value, window in zip(values, (8.0, 16.0, 32.0)):
            value["acceptance_window_seconds"] = window
            value["accepted_edits_per_second"] = value["accepted_edits"] / window
            validate(value)
        result = benchmark.aggregate(values)
        self.assertEqual(result["accepted_edits_per_second"], 256.0)
        self.assertEqual(result["acceptance_window_seconds"], 16.0)

    def test_comparison_has_signed_delta_and_handles_zero_baseline(self):
        before = benchmark.aggregate([summary(frame_p95=10.0)])
        after = benchmark.aggregate([summary("budgeted", frame_p95=5.0)])
        result = benchmark.compare(before, after)
        self.assertEqual(result["frame"]["p95_ms"], {"delta": -5.0, "percent": -50.0})
        before["metrics"]["frame"]["p95_ms"] = 0.0
        result = benchmark.compare(before, after)
        self.assertEqual(result["frame"]["p95_ms"], {"delta": 5.0, "percent": None})

    def test_empty_run_sets_are_rejected(self):
        for function in (benchmark.aggregate, benchmark.validate_equivalence):
            with self.assertRaises(ValueError):
                function([])

    def test_reverses_execution_order_on_even_repetitions(self):
        order = list(benchmark.execution_order(3, ["orbit"]))
        self.assertEqual([policy for _, _, policy in order],
                         ["immediate", "budgeted", "budgeted", "immediate", "immediate", "budgeted"])
        self.assertEqual([repetition for _, repetition, _ in order], [1, 1, 2, 2, 3, 3])


class WorkloadTests(unittest.TestCase):
    def test_command_passes_duration_as_integer_seconds(self):
        command = benchmark.build_command(Path("/tmp/client"), Path("/tmp/output"),
                                          policy="budgeted", rate=512, duration=8, camera="orbit",
                                          render_radius=5)
        self.assertEqual(command[command.index("--benchmark-duration") + 1], "8")
        self.assertEqual(command[command.index("--benchmark-rate") + 1], "512")
        self.assertEqual(command[command.index("--benchmark-render-radius") + 1], "5")

    def test_command_defaults_to_render_radius_three(self):
        command = benchmark.build_command(Path("/tmp/client"), Path("/tmp/output"),
                                          policy="budgeted", rate=512, duration=8, camera="orbit")
        self.assertEqual(command[command.index("--benchmark-render-radius") + 1], "3")

    def test_rejects_render_radii_outside_client_limits(self):
        for render_radius in (2, 6, 0, -1, 3.0, True):
            with self.subTest(render_radius=render_radius):
                with self.assertRaisesRegex(ValueError, "render_radius"):
                    benchmark.build_command(Path("/tmp/client"), Path("/tmp/output"),
                                            policy="budgeted", rate=512, duration=8,
                                            camera="orbit", render_radius=render_radius)

    def test_accepts_supported_render_radii(self):
        for render_radius in (3, 4, 5):
            with self.subTest(render_radius=render_radius):
                benchmark.validate_render_radius(render_radius)

    def test_cli_defaults_to_render_radius_three_and_accepts_five(self):
        for arguments, expected in (([], 3), (["--render-radius", "5"], 5)):
            with self.subTest(arguments=arguments):
                with mock.patch("sys.argv", ["benchmark_client_visuals.py", *arguments]), \
                        mock.patch.object(benchmark, "run", return_value=0) as run:
                    self.assertEqual(benchmark.main(), 0)
                    self.assertEqual(run.call_args.args[0].render_radius, expected)

    def test_cli_rejects_unsupported_or_noninteger_render_radius(self):
        for render_radius in ("2", "6", "3.5"):
            with self.subTest(render_radius=render_radius):
                with mock.patch("sys.argv", ["benchmark_client_visuals.py", "--render-radius", render_radius]), \
                        contextlib.redirect_stderr(io.StringIO()), \
                        mock.patch.object(benchmark, "run") as run:
                    with self.assertRaises(SystemExit) as error:
                        benchmark.main()
                    self.assertEqual(error.exception.code, 2)
                    run.assert_not_called()

    def test_run_records_requested_render_radius_and_passes_it_to_client(self):
        def fake_client(command, **kwargs):
            prefix = command[command.index("--benchmark-visuals") + 1]
            policy = command[command.index("--visual-policy") + 1]
            render_radius = int(command[command.index("--benchmark-render-radius") + 1])
            Path(prefix + ".summary.json").write_text(json.dumps(summary(policy, render_radius=render_radius)))
            for suffix in (".frames.csv", ".events.csv"):
                Path(prefix + suffix).touch()
            return mock.Mock(returncode=0)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "client"
            binary.touch()
            output = root / "output"
            with mock.patch("sys.argv", ["benchmark_client_visuals.py", "--binary", str(binary),
                                        "--output-dir", str(output), "--camera", "orbit",
                                        "--repetitions", "1", "--render-radius", "5"]), \
                    mock.patch.object(benchmark.subprocess, "run", side_effect=fake_client) as client, \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(benchmark.main(), 0)
            report = json.loads((output / "report.json").read_text())
            self.assertTrue(report["valid"])
            self.assertEqual(report["render_radius"], 5)
            self.assertEqual(client.call_count, 2)
            self.assertTrue(all(record["summary"]["render_radius"] == 5 for record in report["runs"]))

    def test_rejects_workloads_outside_client_limits(self):
        for rate, duration in ((8193, 1), (1, 61), (8192, 9), (0, 8), (512, 0), (512, 8.0)):
            with self.subTest(rate=rate, duration=duration):
                with self.assertRaises(ValueError):
                    benchmark.validate_workload(rate, duration)

    def test_accepts_workload_limits(self):
        benchmark.validate_workload(8192, 8)
        benchmark.validate_workload(1, 60)


if __name__ == "__main__":
    unittest.main()
