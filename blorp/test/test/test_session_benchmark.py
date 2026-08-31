#!/usr/bin/env python3
"""Contract tests for scripts/bench-blorp-test-session."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "bench-blorp-test-session"
BUILD_LOCK_WRAPPER = ROOT / "scripts" / "with-build-lock"
CONTENTION_WRAPPER = ROOT / "scripts" / "with-compiler-contention-lease"
POLICY = ROOT / "benchmarks" / "blorp_test_session_policy.json"
REGISTERED_WORKLOADS_CONTRACT_SHA256 = (
    "c3ba3ea8e6a4fca1d5a5c53b03e2426e23821ea86f3df6db128425b803a79de0"
)
COMPLETE_RESULT_FIELDS = frozenset(
    {
        "schema_version",
        "generated_at",
        "measurement_status",
        "comparison_order",
        "repository",
        "machine",
        "configuration",
        "common_inputs",
        "route_inputs",
        "warmups",
        "measurements",
        "routes",
    }
)
INCOMPLETE_MEASUREMENT_FIELDS = frozenset(
    {
        "schema_version",
        "measurement_status",
        "failure_stage",
        "failure_type",
        "failure_message",
        "phase",
        "pair_index",
        "order_index",
        "route",
        "command",
        "elapsed_seconds",
        "exit_code",
        "effective_environment_keys",
        "effective_environment_sha256",
        "stdout_bytes",
        "stderr_bytes",
        "stdout_sha256",
        "stderr_sha256",
        "artifact_files",
    }
)


def load_benchmark_module():
    loader = importlib.machinery.SourceFileLoader(
        "blorp_test_session_benchmark",
        str(SCRIPT),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create benchmark module spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def write_fake_test_command(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
import time

label = os.environ["BENCH_ROUTE_LABEL"]
with open(os.environ["BENCH_ORDER_LOG"], "a", encoding="utf-8") as log:
    log.write(label + "\\n")
if os.environ.get("BENCH_ENV_LOG"):
    with open(os.environ["BENCH_ENV_LOG"], "a", encoding="utf-8") as environment_log:
        environment_log.write(json.dumps({
            "timings": os.environ.get("BLORP_TEST_TIMINGS"),
            "gate": os.environ.get("BLORP_GATE_RESULT"),
            "runtime_cache": os.environ.get("BLORP_RUNTIME_CACHE"),
        }) + "\\n")

manifest_suite = "different" if os.environ.get("BENCH_MISMATCH") == "1" else "fixture"
output_suffix = ""
if os.environ.get("BENCH_DRIFT_LOG"):
    drift_path = os.environ["BENCH_DRIFT_LOG"]
    invocation = int(open(drift_path, encoding="utf-8").read()) if os.path.exists(drift_path) else 0
    with open(drift_path, "w", encoding="utf-8") as drift_log:
        drift_log.write(str(invocation + 1))
    output_suffix = " " + str(invocation // 2)
print("ordinary test output" + output_suffix)
print("BLORP_GATE_RESULT gate=test-session-benchmark status=PASS passed=1 failed=0 tests=1")
print("BLORP_TEST_RUN_MANIFEST " + json.dumps({"schema_version": 1, "suites": [manifest_suite], "status": "PASS"}))
print("BLORP_TEST_TIMING phase=discovery group=all suites=1 sources=1 duration_ms=7", file=sys.stderr)
if os.environ.get("BENCH_MALFORMED") == "1":
    print("BLORP_TEST_SESSION_COUNTER not-json", file=sys.stderr)
print("BLORP_TEST_SESSION_COUNTER " + json.dumps({"schema_version": 2, "event": "session_totals", "scope": {"kind": "session"}, "counters": {
    "discovered_runnable_files": 1,
    "unique_discovered_runnable_source_identities": 1,
    "retained_runnable_source_bytes": 100,
    "declared_test_suites": 1,
    "planned_aggregate_suite_harnesses": 0,
    "planned_combined_suite_files": 0,
    "planned_combined_native_executions": 0,
    "planned_individual_source_files": 1,
}}), file=sys.stderr)
if os.environ.get("BENCH_MUTATE_EXECUTABLE") == "1":
    with open(sys.argv[0], "a", encoding="utf-8") as executable:
        executable.write("\\n# changed during measurement\\n")
if os.environ.get("BENCH_MUTATE_INPUT"):
    with open(os.environ["BENCH_MUTATE_INPUT"], "a", encoding="utf-8") as benchmark_input:
        benchmark_input.write("changed during measurement\\n")
if os.environ.get("BENCH_SAMPLE_STARTED"):
    while not os.path.exists(os.environ["BENCH_SAMPLE_STARTED"]):
        time.sleep(0.005)
time.sleep(0.05)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_timeout_command(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import os
import signal
import subprocess
import time

def configure_child():
    os.setpgrp()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen(["sleep", "10"], preexec_fn=configure_child)
with open(os.environ["BENCH_CHILD_PID"], "w", encoding="utf-8") as output:
    output.write(str(child.pid))
print("BLORP_GATE_RESULT gate=test-session-benchmark status=PASS passed=1 failed=0 tests=1", flush=True)
time.sleep(10)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_sleep_command(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import time

time.sleep(10)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_lingering_child_command(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import os
import signal
import subprocess
import time

def configure_child():
    os.setpgrp()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

child = subprocess.Popen(["sleep", "10"], preexec_fn=configure_child)
with open(os.environ["BENCH_CHILD_PID"], "w", encoding="utf-8") as output:
    output.write(str(child.pid))
print("BLORP_GATE_RESULT gate=test-session-benchmark status=PASS passed=1 failed=0 tests=1", flush=True)
time.sleep(0.1)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


class BlorpTestSessionBenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.benchmark = load_benchmark_module()

    def test_observations_exclude_timings_from_semantic_manifest(self) -> None:
        first = self.benchmark.parse_observations(
            b"BLORP_GATE_RESULT gate=bench status=PASS passed=2 failed=0 tests=2\n",
            b"BLORP_TEST_TIMING phase=pipeline group=a suites=2 sources=3 duration_ms=10\n"
            b'BLORP_TEST_SESSION_COUNTER {"schema_version":2,"event":"session_totals","scope":{"kind":"session"},"counters":{"parsed_sources":3,"reused_modules":2}}\n',
        )
        second = self.benchmark.parse_observations(
            b"BLORP_GATE_RESULT gate=bench status=PASS passed=2 failed=0 tests=2\n",
            b"BLORP_TEST_TIMING phase=pipeline group=a suites=2 sources=3 duration_ms=999\n"
            b'BLORP_TEST_SESSION_COUNTER {"schema_version":2,"event":"session_totals","scope":{"kind":"session"},"counters":{"parsed_sources":3,"reused_modules":2}}\n',
        )

        self.assertEqual(first["semantic_manifest_sha256"], second["semantic_manifest_sha256"])
        self.assertEqual(first["timings"][0]["duration_ms"], 10)
        self.assertEqual(first["counters"]["parsed_sources"], 3)
        self.assertEqual(first["counters"]["reused_modules"], 2)

    def test_repeated_versioned_counter_events_are_aggregated(self) -> None:
        observations = self.benchmark.parse_observations(
            b"BLORP_GATE_RESULT gate=bench status=PASS passed=1 failed=0 tests=1\n",
            b'BLORP_TEST_SESSION_COUNTER {"schema_version":2,"event":"batch","scope":{"batch":0},"counters":{"parsed_sources":2}}\n'
            b'BLORP_TEST_SESSION_COUNTER {"schema_version":2,"event":"batch","scope":{"batch":1},"counters":{"parsed_sources":3}}\n'
            b'BLORP_TEST_SESSION_COUNTER {"schema_version":2,"event":"batch","scope":{"batch":0},"counters":{"parsed_sources":4}}\n',
        )

        self.assertEqual(len(observations["counter_events"]), 3)
        self.assertEqual(len(observations["counter_aggregates"]), 2)
        by_batch = {
            aggregate["scope"]["batch"]: aggregate["counters"]["parsed_sources"]
            for aggregate in observations["counter_aggregates"]
        }
        self.assertEqual(by_batch, {0: 6, 1: 3})
        self.assertEqual(observations["counters"], {})

    def test_session_totals_are_required_once_with_mandatory_counters(self) -> None:
        self.assertEqual(
            {
                "discovered_runnable_files",
                "unique_discovered_runnable_source_identities",
                "retained_runnable_source_bytes",
                "declared_test_suites",
                "planned_aggregate_suite_harnesses",
                "planned_combined_suite_files",
                "planned_combined_native_executions",
                "planned_individual_source_files",
            },
            self.benchmark.REQUIRED_SESSION_TOTAL_COUNTERS,
        )
        valid = {
            "schema_version": 2,
            "event": "session_totals",
            "scope": {"kind": "session"},
            "counters": {
                key: 1 for key in self.benchmark.REQUIRED_SESSION_TOTAL_COUNTERS
            },
        }

        self.assertEqual(
            self.benchmark.validate_session_totals([valid]),
            valid["counters"],
        )
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "exactly one"):
            self.benchmark.validate_session_totals([])
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "exactly one"):
            self.benchmark.validate_session_totals([valid, valid])
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "missing mandatory"):
            self.benchmark.validate_session_totals(
                [{**valid, "counters": {"discovered_runnable_files": 1}}]
            )

    def test_malformed_instrumentation_fails_closed(self) -> None:
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "malformed timing"):
            self.benchmark.parse_observations(
                b"",
                b"BLORP_TEST_TIMING phase=broken\n",
            )
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "malformed session counter"):
            self.benchmark.parse_observations(
                b"",
                b"BLORP_TEST_SESSION_COUNTER not-json\n",
            )
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "schema_version"):
            self.benchmark.parse_observations(
                b"",
                b'BLORP_TEST_SESSION_COUNTER {"schema_version":1,"event":"x","scope":"x","counters":{}}\n',
            )
        with self.assertRaisesRegex(
            self.benchmark.BenchmarkError,
            "structured run manifest",
        ):
            self.benchmark.parse_observations(
                b'BLORP_TEST_RUN_MANIFEST {"schema_version":1,"suites":[],"status":"PASS","extra":true}\n',
                b"",
            )
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "nonempty"):
            self.benchmark.validate_run_manifest(
                {"schema_version": 1, "suites": [], "status": "PASS"}
            )
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "duplicate field"):
            self.benchmark.parse_observations(
                b'BLORP_TEST_RUN_MANIFEST {"schema_version":1,"schema_version":1,"suites":["x"],"status":"PASS"}\n',
                b"",
            )
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "schema"):
            self.benchmark.parse_observations(
                b'BLORP_TEST_RUN_MANIFEST {"schema_version":true,"suites":["x"],"status":"PASS"}\n',
                b"",
            )
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "duplicate field"):
            self.benchmark.parse_observations(
                b"",
                b'BLORP_TEST_SESSION_COUNTER {"schema_version":2,"event":"x","scope":"x","counters":{},"counters":{}}\n',
            )
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "schema_version"):
            self.benchmark.parse_observations(
                b"",
                b'BLORP_TEST_SESSION_COUNTER {"schema_version":true,"event":"x","scope":"x","counters":{}}\n',
            )

    def test_gate_result_requires_exact_identity_and_consistent_counts(self) -> None:
        valid = {
            "gate": "test-session-benchmark",
            "status": "PASS",
            "passed": 2,
            "failed": 0,
            "tests": 2,
        }
        self.benchmark.validate_gate_results([valid])

        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "exactly one"):
            self.benchmark.validate_gate_results([valid, valid])
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "unexpected gate"):
            self.benchmark.validate_gate_results([{**valid, "gate": "forged"}])
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "inconsistent"):
            self.benchmark.validate_gate_results([{**valid, "tests": 3}])
        with self.assertRaisesRegex(self.benchmark.BenchmarkError, "at least one"):
            self.benchmark.validate_gate_results(
                [{**valid, "passed": 0, "failed": 0, "tests": 0}]
            )

        failed_manifest_measurement = {
            "timed_out": False,
            "exit_code": 0,
            "unexpected_live_descendants": [],
            "surviving_process_ids": [],
            "cleanup_sampling_errors": [],
            "gate_results": [valid],
            "run_manifests": [
                {"schema_version": 1, "suites": ["fixture"], "status": "FAIL"}
            ],
        }
        self.assertIn(
            "failed suite",
            self.benchmark.measurement_failed(failed_manifest_measurement),
        )

    def test_observations_include_ordinary_output_in_semantic_manifest(self) -> None:
        first = self.benchmark.parse_observations(
            b"first result\nBLORP_GATE_RESULT gate=bench status=PASS passed=1 failed=0 tests=1\n",
            b"",
        )
        second = self.benchmark.parse_observations(
            b"different result\nBLORP_GATE_RESULT gate=bench status=PASS passed=1 failed=0 tests=1\n",
            b"",
        )

        self.assertNotEqual(
            first["semantic_manifest_sha256"],
            second["semantic_manifest_sha256"],
        )

    def test_observations_preserve_binary_output_hashes(self) -> None:
        stdout = (
            b"\xff\x00user output\n"
            b"BLORP_GATE_RESULT gate=bench status=PASS passed=1 failed=0 tests=1\n"
        )
        stderr = b"\x80\x00stderr\n"

        observations = self.benchmark.parse_observations(stdout, stderr)

        self.assertEqual(
            observations["ordinary_stdout_sha256"],
            self.benchmark.sha256_bytes(b"\xff\x00user output\n"),
        )
        self.assertEqual(
            observations["ordinary_stderr_sha256"],
            self.benchmark.sha256_bytes(stderr),
        )

    def test_comparison_alternates_order_and_requires_matching_results(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            write_fake_test_command(command)

            baseline = self.benchmark.BenchmarkRoute(
                label="baseline",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "baseline",
                    "BENCH_ORDER_LOG": str(order_log),
                },
            )
            candidate = self.benchmark.BenchmarkRoute(
                label="candidate",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "candidate",
                    "BENCH_ORDER_LOG": str(order_log),
                },
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=baseline,
                candidate=candidate,
                command_arguments=(),
                measured_pairs=2,
                warmup_pairs=0,
                timeout_seconds=2.0,
                cache_state="isolated-cold",
                poll_interval_seconds=0.01,
                bootstrap_samples=200,
            )

            result = self.benchmark.run_benchmark(config, root=temp_dir)

            self.assertEqual(
                order_log.read_text(encoding="utf-8").splitlines(),
                ["baseline", "candidate", "candidate", "baseline"],
            )
            self.assertEqual(result["measurement_status"], "complete")
            self.assertEqual(result["comparison_order"], "alternating")
            self.assertEqual(len(result["measurements"]), 4)
            self.assertTrue(result["comparison"]["structured_output_parity"])
            self.assertIn("elapsed_paired_change_percent", result["comparison"])
            self.assertFalse(result["comparison"]["confidence_intervals_available"])
            self.assertNotIn("elapsed_paired_95_percent_ci", result["comparison"])
            self.assertGreater(
                result["routes"]["baseline"]["sampled_aggregate_peak_rss_bytes"],
                0,
            )
            self.assertNotIn("statistical_policy", result)
            self.assertNotIn("publication_ready", result)
            self.assertNotIn("publication_blockers", result)

    def test_comparison_rejects_semantically_different_results(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            write_fake_test_command(command)
            baseline = self.benchmark.BenchmarkRoute(
                label="baseline",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "baseline",
                    "BENCH_ORDER_LOG": str(order_log),
                },
            )
            candidate = self.benchmark.BenchmarkRoute(
                label="candidate",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "candidate",
                    "BENCH_ORDER_LOG": str(order_log),
                    "BENCH_MISMATCH": "1",
                },
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=baseline,
                candidate=candidate,
                command_arguments=(),
                measured_pairs=1,
                warmup_pairs=0,
                timeout_seconds=2.0,
                cache_state="isolated-cold",
                poll_interval_seconds=0.01,
                bootstrap_samples=50,
            )

            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "semantic result mismatch",
            ):
                self.benchmark.run_benchmark(config, root=temp_dir)

    def test_comparison_rejects_semantic_drift_across_pairs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            drift_log = temp_dir / "drift.log"
            write_fake_test_command(command)
            common_environment = {
                "BENCH_ORDER_LOG": str(order_log),
                "BENCH_DRIFT_LOG": str(drift_log),
            }
            baseline = self.benchmark.BenchmarkRoute(
                label="baseline",
                executable=command,
                environment={**common_environment, "BENCH_ROUTE_LABEL": "baseline"},
            )
            candidate = self.benchmark.BenchmarkRoute(
                label="candidate",
                executable=command,
                environment={**common_environment, "BENCH_ROUTE_LABEL": "candidate"},
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=baseline,
                candidate=candidate,
                command_arguments=(),
                measured_pairs=2,
                warmup_pairs=0,
                timeout_seconds=2.0,
                cache_state="isolated-cold",
                poll_interval_seconds=0.01,
                bootstrap_samples=50,
            )

            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "semantic result changed across rounds",
            ):
                self.benchmark.run_benchmark(config, root=temp_dir)

    def test_cache_directory_policy_separates_cold_and_warm_runs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            warm_first = self.benchmark.runtime_cache_directory(
                "isolated-warm", root, "baseline", "measured", 0
            )
            warm_second = self.benchmark.runtime_cache_directory(
                "isolated-warm", root, "baseline", "measured", 1
            )
            cold_first = self.benchmark.runtime_cache_directory(
                "isolated-cold", root, "baseline", "measured", 0
            )
            cold_second = self.benchmark.runtime_cache_directory(
                "isolated-cold", root, "baseline", "measured", 1
            )

            self.assertEqual(warm_first, warm_second)
            self.assertNotEqual(cold_first, cold_second)
            self.assertNotEqual(
                warm_first,
                self.benchmark.runtime_cache_directory(
                    "isolated-warm", root, "candidate", "measured", 0
                ),
            )
            self.assertNotEqual(
                self.benchmark.runtime_cache_directory(
                    "isolated-warm", root, "a/b", "measured", 0
                ),
                self.benchmark.runtime_cache_directory(
                    "isolated-warm", root, "a b", "measured", 0
                ),
            )

    def test_comparison_rejects_shared_existing_cache_policy(self) -> None:
        route = self.benchmark.BenchmarkRoute(
            label="baseline",
            executable=Path("baseline"),
        )
        candidate = self.benchmark.BenchmarkRoute(
            label="candidate",
            executable=Path("candidate"),
        )

        with self.assertRaisesRegex(ValueError, "existing cache state"):
            self.benchmark.BenchmarkConfig(
                baseline=route,
                candidate=candidate,
                command_arguments=("test",),
                cache_state="existing",
            )

    def test_isolated_warm_cache_requires_an_unmeasured_warmup(self) -> None:
        route = self.benchmark.BenchmarkRoute(
            label="baseline",
            executable=Path("baseline"),
        )

        with self.assertRaisesRegex(ValueError, "warmup"):
            self.benchmark.BenchmarkConfig(
                baseline=route,
                candidate=None,
                command_arguments=("test",),
                cache_state="isolated-warm",
                warmup_pairs=0,
            )

    def test_counter_medians_require_complete_coverage(self) -> None:
        measurements = [
            {
                "elapsed_seconds": 1.0,
                "sampled_aggregate_peak_rss_bytes": None,
                "timings": [],
                "counters": {"always": 1, "partial": 10},
            },
            {
                "elapsed_seconds": 2.0,
                "sampled_aggregate_peak_rss_bytes": None,
                "timings": [],
                "counters": {"always": 3},
            },
        ]

        summary = self.benchmark.summarize_measurements(measurements)

        self.assertEqual(summary["counter_medians"], {"always": 2.0})
        self.assertEqual(summary["counter_coverage"]["always"], 2)
        self.assertEqual(summary["counter_coverage"]["partial"], 1)

    def test_configuration_rejects_non_finite_durations(self) -> None:
        route = self.benchmark.BenchmarkRoute(
            label="baseline",
            executable=Path("baseline"),
        )
        for invalid in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(ValueError, "finite"):
                    self.benchmark.BenchmarkConfig(
                        baseline=route,
                        candidate=None,
                        command_arguments=("test",),
                        timeout_seconds=invalid,
                    )
                with self.assertRaisesRegex(ValueError, "finite"):
                    self.benchmark.BenchmarkConfig(
                        baseline=route,
                        candidate=None,
                        command_arguments=("test",),
                        poll_interval_seconds=invalid,
                    )
                with self.assertRaises(self.benchmark.argparse.ArgumentTypeError):
                    self.benchmark.positive_float(str(invalid))
        with self.assertRaisesRegex(ValueError, "must not exceed"):
            self.benchmark.BenchmarkConfig(
                baseline=route,
                candidate=None,
                command_arguments=("test",),
                measured_pairs=self.benchmark.MAXIMUM_MEASURED_PAIRS + 1,
            )

    def test_benchmark_rejects_executable_changed_during_measurement(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "mutating_test"
            order_log = temp_dir / "order.log"
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                    "BENCH_MUTATE_EXECUTABLE": "1",
                },
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=route,
                candidate=None,
                command_arguments=(),
                measured_pairs=1,
                warmup_pairs=0,
                timeout_seconds=2.0,
                cache_state="existing",
                poll_interval_seconds=0.01,
                bootstrap_samples=50,
            )

            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "route executable, environment, or explicit input changed",
            ):
                self.benchmark.run_benchmark(config, root=temp_dir)

    def test_benchmark_rejects_explicit_input_changed_during_measurement(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "mutating_test"
            tracked_input = temp_dir / "companion.dat"
            order_log = temp_dir / "order.log"
            tracked_input.write_text("before\n", encoding="utf-8")
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                    "BENCH_MUTATE_INPUT": str(tracked_input),
                },
                inputs=(tracked_input,),
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=route,
                candidate=None,
                command_arguments=(),
                measured_pairs=1,
                warmup_pairs=0,
                timeout_seconds=2.0,
                cache_state="existing",
                poll_interval_seconds=0.01,
                bootstrap_samples=50,
            )

            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "route executable, environment, or explicit input changed",
            ):
                self.benchmark.run_benchmark(config, root=temp_dir)

    def test_git_metadata_hashes_dirty_file_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "benchmark@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Benchmark Test"],
                cwd=root,
                check=True,
            )
            source = root / "input.txt"
            source.write_text("base\n", encoding="utf-8")
            subprocess.run(["git", "add", "input.txt"], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "fixture"], cwd=root, check=True
            )

            source.write_text("first dirty value\n", encoding="utf-8")
            first = self.benchmark.git_metadata(root)
            source.write_text("second dirty value\n", encoding="utf-8")
            second = self.benchmark.git_metadata(root)

            self.assertTrue(first["dirty"])
            self.assertEqual(first["status_sha256"], second["status_sha256"])
            self.assertNotEqual(
                first["content_sha256"],
                second["content_sha256"],
            )

    def test_input_metadata_hashes_names_binary_bytes_and_directory_order(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            (first / "a.bin").write_bytes(b"\x00\xff")
            (first / "b.txt").write_text("value\n", encoding="utf-8")
            (second / "b.txt").write_text("value\n", encoding="utf-8")
            (second / "a.bin").write_bytes(b"\x00\xff")

            first_hash = self.benchmark.input_metadata(first, root)["content_sha256"]
            second_hash = self.benchmark.input_metadata(second, root)["content_sha256"]
            self.assertEqual(first_hash, second_hash)

            (second / "a.bin").write_bytes(b"\x00\xfe")
            changed_hash = self.benchmark.input_metadata(second, root)["content_sha256"]
            self.assertNotEqual(first_hash, changed_hash)
            with self.assertRaisesRegex(self.benchmark.BenchmarkError, "does not exist"):
                self.benchmark.input_metadata(root / "missing", root)

            (first / "link").symlink_to(first / "a.bin")
            with self.assertRaisesRegex(self.benchmark.BenchmarkError, "symlink"):
                self.benchmark.input_metadata(first, root)

    def test_bootstrap_interval_is_deterministic(self) -> None:
        first = self.benchmark.bootstrap_median_interval(
            [-5.0, -4.0, -3.0, -2.0], samples=500
        )
        second = self.benchmark.bootstrap_median_interval(
            [-5.0, -4.0, -3.0, -2.0], samples=500
        )

        self.assertEqual(first, second)
        self.assertLessEqual(first[0], -3.5)
        self.assertGreaterEqual(first[1], -3.5)

    def test_committed_policy_registers_exact_workloads_and_thresholds(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)

        self.assertEqual(policy["schema_version"], 3)
        self.assertEqual(policy["minimum_measured_pairs"], 10)
        self.assertEqual(policy["maximum_measured_pairs"], 30)
        self.assertEqual(policy["minimum_bootstrap_samples"], 10_000)
        self.assertEqual(
            policy["maximum_confidence_interval_width_percentage_points"],
            10.0,
        )
        self.assertEqual(
            policy["contention"]["kind"],
            "advisory_shared_gate_exclusive_benchmark",
        )
        self.assertEqual(
            policy["contention"]["lease_name"],
            "blorp-compiler-evidence-v1.lock",
        )
        self.assertEqual(
            self.benchmark.sha256_bytes(
                self.benchmark.canonical_json_bytes(policy["workloads"])
            ),
            REGISTERED_WORKLOADS_CONTRACT_SHA256,
        )
        self.assertEqual(
            set(policy["workloads"]),
            {
                "compiler-suite",
                "compiler-suite-baseline",
                "doctest",
                "leak",
                "many-tiny-compatible",
                "mixed-isolation",
                "oversized-plus-small",
                "runtime-types",
                "sanitizer",
                "shared-import-fanout",
                "std-dict",
                "tiny-suite",
            },
        )
        self.assertEqual(policy["workloads"]["tiny-suite"]["kind"], "comparison")
        self.assertEqual(
            policy["workloads"]["shared-import-fanout"]["kind"],
            "characterization",
        )
        self.assertEqual(
            policy["workloads"]["tiny-suite"]["command_arguments"],
            [
                "test",
                "--timeout",
                "30",
                "blorp/test/runtime/types/test_bool.brp",
            ],
        )
        self.assertEqual(
            policy["workloads"]["tiny-suite"]["metric"],
            "elapsed_paired_95_percent_ci",
        )
        self.assertEqual(
            policy["workloads"]["compiler-suite"]["metric"],
            "sampled_peak_rss_paired_95_percent_ci",
        )
        fanout = policy["workloads"]["shared-import-fanout"]
        self.assertEqual(
            fanout["command_arguments"][-8:],
            [
                "benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_01.brp",
                "benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_02.brp",
                "benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_03.brp",
                "benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_04.brp",
                "benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_05.brp",
                "benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_06.brp",
                "benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_07.brp",
                "benchmarks/fixtures/blorp_test_session/shared_import_fanout/suite_08.brp",
            ],
        )
        self.assertEqual(fanout["measured_pairs"], 3)
        self.assertEqual(fanout["warmup_pairs"], 1)
        self.assertEqual(fanout["cache_state"], "isolated-warm")
        runtime_types = policy["workloads"]["runtime-types"]
        self.assertEqual(
            runtime_types["command_arguments"][-8:],
            [
                "blorp/test/runtime/types/test_alloc_safety.brp",
                "blorp/test/runtime/types/test_option_result.brp",
                "blorp/test/runtime/types/test_record_cow.brp",
                "blorp/test/runtime/types/test_record_update.brp",
                "blorp/test/runtime/types/test_result.brp",
                "blorp/test/runtime/types/test_struct.brp",
                "blorp/test/runtime/types/test_tuples_and_records.brp",
                "blorp/test/runtime/types/test_variant_alloc.brp",
            ],
        )
        self.assertEqual(
            runtime_types["fingerprint_inputs"],
            runtime_types["command_arguments"][-8:],
        )
        for workload in policy["workloads"].values():
            if workload["kind"] != "characterization":
                continue
            for input_path in workload["fingerprint_inputs"]:
                self.assertTrue((ROOT / input_path).exists(), input_path)

    def test_registered_characterization_validation_is_exact(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)
        workload = policy["workloads"]["many-tiny-compatible"]
        valid = {
            "workload_name": "many-tiny-compatible",
            "candidate_present": False,
            "command_arguments": tuple(workload["command_arguments"]),
            "cache_state": workload["cache_state"],
            "warmup_pairs": workload["warmup_pairs"],
            "measured_pairs": workload["measured_pairs"],
            "timeout_seconds": workload["timeout_seconds"],
            "bootstrap_samples": 10_000,
            "fingerprint_inputs": tuple(Path(path) for path in workload["fingerprint_inputs"]),
        }
        kind, selected = self.benchmark.validate_registered_workload(policy, **valid)
        self.assertEqual(kind.value, "characterization")
        self.assertEqual(selected, workload)
        invalid_cases = (
            ({"candidate_present": True}, "baseline-only"),
            ({"command_arguments": ("test", "different.brp")}, "command arguments"),
            ({"cache_state": "isolated-cold"}, "cache state"),
            ({"warmup_pairs": 0}, "warmup"),
            ({"measured_pairs": 2}, "measured pairs"),
            ({"timeout_seconds": workload["timeout_seconds"] + 1}, "timeout"),
            ({"fingerprint_inputs": ()}, "fingerprint inputs"),
            ({"workload_name": "missing"}, "unknown registered workload"),
        )
        for overrides, message in invalid_cases:
            with self.subTest(overrides=overrides):
                with self.assertRaisesRegex(self.benchmark.BenchmarkError, message):
                    self.benchmark.validate_registered_workload(
                        policy,
                        **{**valid, **overrides},
                    )

    def run_characterization_workload_once(self, workload_name: str) -> dict:
        policy = self.benchmark.load_benchmark_policy(POLICY)
        workload = policy["workloads"][workload_name]
        environment = {
            name: value
            for name, value in os.environ.items()
            if not name.startswith("BLORP_")
        }
        with tempfile.TemporaryDirectory() as temp_name, mock.patch.dict(
            os.environ,
            environment,
            clear=True,
        ):
            measurement = self.benchmark.run_measurement(
                route=self.benchmark.BenchmarkRoute(
                    label=workload_name,
                    executable=ROOT / "bin" / "blorp",
                ),
                command_arguments=tuple(workload["command_arguments"]),
                root=ROOT,
                artifact_root=Path(temp_name),
                phase="fixture",
                pair_index=0,
                order_index=0,
                timeout_seconds=120.0,
                poll_interval_seconds=0.01,
                cache_state="isolated-cold",
            )
        failure = self.benchmark.measurement_failed(measurement)
        self.assertIsNone(failure, measurement)
        self.benchmark.validate_gate_results(measurement["gate_results"])
        return self.benchmark.validate_session_totals(
            measurement["counter_events"]
        )

    def test_compatible_characterization_workloads_run_as_one_harness(self) -> None:
        for workload_name in ("shared-import-fanout", "runtime-types"):
            with self.subTest(workload_name=workload_name):
                counters = self.run_characterization_workload_once(workload_name)
                self.assertEqual(counters["discovered_runnable_files"], 8)
                self.assertEqual(counters["declared_test_suites"], 8)
                self.assertEqual(
                    counters["planned_aggregate_suite_harnesses"],
                    1,
                )
                self.assertEqual(counters["planned_combined_suite_files"], 8)
                self.assertEqual(
                    counters["planned_combined_native_executions"],
                    1,
                )
                self.assertEqual(counters["planned_individual_source_files"], 0)

    def test_policy_schema_and_registered_workload_validation_fail_closed(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)
        tiny = policy["workloads"]["tiny-suite"]

        selected = self.benchmark.validate_registered_workload(
            policy,
            workload_name="tiny-suite",
            candidate_present=True,
            command_arguments=tuple(tiny["command_arguments"]),
            cache_state="isolated-warm",
            warmup_pairs=1,
            measured_pairs=10,
            timeout_seconds=1800.0,
            bootstrap_samples=10_000,
            fingerprint_inputs=(),
        )
        self.assertEqual(selected[0].value, "comparison")
        self.assertEqual(selected[1], tiny)

        invalid_cases = (
            ({"candidate_present": False}, "requires a candidate"),
            ({"command_arguments": ("test", "different.brp")}, "command arguments"),
            ({"cache_state": "isolated-cold"}, "cache state"),
            ({"warmup_pairs": 0}, "warmup"),
            ({"measured_pairs": 9}, "measured pairs"),
            ({"measured_pairs": 11}, "even number"),
            ({"bootstrap_samples": 9_999}, "bootstrap samples"),
        )
        valid = {
            "workload_name": "tiny-suite",
            "candidate_present": True,
            "command_arguments": tuple(tiny["command_arguments"]),
            "cache_state": "isolated-warm",
            "warmup_pairs": 1,
            "measured_pairs": 10,
            "timeout_seconds": 1800.0,
            "bootstrap_samples": 10_000,
            "fingerprint_inputs": (),
        }
        for overrides, message in invalid_cases:
            with self.subTest(overrides=overrides):
                with self.assertRaisesRegex(self.benchmark.BenchmarkError, message):
                    self.benchmark.validate_registered_workload(
                        policy,
                        **{**valid, **overrides},
                    )

        with tempfile.TemporaryDirectory() as temp_name:
            invalid_path = Path(temp_name) / "policy.json"
            invalid_path.write_text(
                json.dumps({**policy, "unexpected": True}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "unexpected fields",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            invalid_path.write_text(
                '{"schema_version":3,"schema_version":3}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "duplicate field",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            invalid_path.write_text(
                json.dumps({**policy, "schema_version": True}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "schema_version",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            traversal_policy = json.loads(json.dumps(policy))
            traversal_policy["contention"]["lease_name"] = ".."
            invalid_path.write_text(json.dumps(traversal_policy), encoding="utf-8")
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "lease_name",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            invalid_kind_policy = json.loads(json.dumps(policy))
            invalid_kind_policy["workloads"]["tiny-suite"]["kind"] = "migration"
            invalid_path.write_text(json.dumps(invalid_kind_policy), encoding="utf-8")
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "kind",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            mixed_comparison_policy = json.loads(json.dumps(policy))
            mixed_comparison_policy["workloads"]["tiny-suite"][
                "timeout_seconds"
            ] = 30.0
            invalid_path.write_text(
                json.dumps(mixed_comparison_policy),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "unexpected fields",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            mixed_characterization_policy = json.loads(json.dumps(policy))
            mixed_characterization_policy["workloads"]["doctest"][
                "metric"
            ] = "elapsed_paired_95_percent_ci"
            invalid_path.write_text(
                json.dumps(mixed_characterization_policy),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "unexpected fields",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            traversal_input_policy = json.loads(json.dumps(policy))
            traversal_input_policy["workloads"]["doctest"][
                "fingerprint_inputs"
            ] = ["../std/bytes.brp"]
            invalid_path.write_text(
                json.dumps(traversal_input_policy),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "normalized relative paths",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            home_input_policy = json.loads(json.dumps(policy))
            home_input_policy["workloads"]["doctest"][
                "fingerprint_inputs"
            ] = ["~/std/bytes.brp"]
            invalid_path.write_text(
                json.dumps(home_input_policy),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "normalized relative paths",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            duplicate_input_policy = json.loads(json.dumps(policy))
            duplicate_input_policy["workloads"]["doctest"][
                "fingerprint_inputs"
            ] = ["std/bytes.brp", "std/bytes.brp"]
            invalid_path.write_text(
                json.dumps(duplicate_input_policy),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "must not contain duplicates",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            boolean_count_policy = json.loads(json.dumps(policy))
            boolean_count_policy["workloads"]["doctest"][
                "measured_pairs"
            ] = True
            invalid_path.write_text(
                json.dumps(boolean_count_policy),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "measured_pairs",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

            nonfinite_timeout_policy = json.loads(json.dumps(policy))
            nonfinite_timeout_policy["workloads"]["doctest"][
                "timeout_seconds"
            ] = float("inf")
            invalid_path.write_text(
                json.dumps(nonfinite_timeout_policy),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "timeout_seconds",
            ):
                self.benchmark.load_benchmark_policy(invalid_path)

    def test_registered_comparison_enforces_ceiling_and_interval_precision(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)

        passed = self.benchmark.assess_registered_comparison(
            policy,
            "tiny-suite",
            {"elapsed_paired_95_percent_ci": [-3.0, 5.0]},
        )
        self.assertEqual(passed["status"], "pass")
        self.assertEqual(passed["reasons"], [])
        self.assertEqual(
            passed["confidence_interval_width_percentage_points"],
            8.0,
        )

        over_ceiling = self.benchmark.assess_registered_comparison(
            policy,
            "tiny-suite",
            {"elapsed_paired_95_percent_ci": [-2.0, 12.0]},
        )
        self.assertEqual(over_ceiling["status"], "fail")
        self.assertTrue(
            any("regression ceiling" in reason for reason in over_ceiling["reasons"])
        )

        too_wide = self.benchmark.assess_registered_comparison(
            policy,
            "tiny-suite",
            {"elapsed_paired_95_percent_ci": [-5.0, 6.0]},
        )
        self.assertEqual(too_wide["status"], "fail")
        self.assertTrue(
            any("interval width" in reason for reason in too_wide["reasons"])
        )

        missing_rss = self.benchmark.assess_registered_comparison(
            policy,
            "compiler-suite",
            {},
        )
        self.assertEqual(missing_rss["status"], "fail")
        self.assertTrue(any("missing" in reason for reason in missing_rss["reasons"]))

    def test_contention_lease_rejects_benchmark_while_shared_gate_is_active(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            ready = temp_dir / "ready"
            stop = temp_dir / "stop"
            holder = temp_dir / "hold.py"
            holder.write_text(
                "from pathlib import Path\n"
                "import sys\n"
                "import time\n"
                "ready = Path(sys.argv[1])\n"
                "stop = Path(sys.argv[2])\n"
                "ready.write_text('ready', encoding='utf-8')\n"
                "while not stop.exists():\n"
                "    time.sleep(0.01)\n",
                encoding="utf-8",
            )
            environment = {
                **os.environ,
                "BLORP_COMPILER_CONTENTION_LOCK_BASE": str(temp_dir / "locks"),
                "BLORP_COMPILER_CONTENTION_ALLOW_TEST_OVERRIDE": "1",
                "BLORP_BUILD_LOCK_BASE": str(temp_dir / "build-locks"),
            }
            gate = subprocess.Popen(
                [
                    str(BUILD_LOCK_WRAPPER),
                    sys.executable,
                    str(holder),
                    str(ready),
                    str(stop),
                ],
                env=environment,
            )
            try:
                deadline = time.monotonic() + 5.0
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), "shared gate did not acquire its lease")
                with mock.patch.dict(os.environ, environment, clear=True):
                    with self.assertRaisesRegex(
                        self.benchmark.BenchmarkError,
                        "compiler gate is active",
                    ):
                        with self.benchmark.compiler_contention_lease(
                            policy,
                            nonblocking=True,
                        ):
                            self.fail("exclusive benchmark lease unexpectedly acquired")
            finally:
                stop.write_text("stop", encoding="utf-8")
                gate.wait(timeout=5.0)
            self.assertEqual(gate.returncode, 0)
            lock_directory = temp_dir / "locks"
            lock_file = lock_directory / "blorp-compiler-evidence-v1.lock"
            self.assertEqual(lock_directory.stat().st_mode & 0o777, 0o700)
            self.assertEqual(lock_file.stat().st_mode & 0o777, 0o600)

    def test_contention_lease_rejects_a_symlinked_namespace(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            target = temp_dir / "target"
            target.mkdir()
            lock_base = temp_dir / "locks"
            lock_base.symlink_to(target, target_is_directory=True)
            environment = {
                **os.environ,
                "BLORP_COMPILER_CONTENTION_LOCK_BASE": str(lock_base),
                "BLORP_COMPILER_CONTENTION_ALLOW_TEST_OVERRIDE": "1",
            }

            with mock.patch.dict(os.environ, environment, clear=True):
                with self.assertRaisesRegex(
                    self.benchmark.BenchmarkError,
                    "symlink",
                ):
                    with self.benchmark.compiler_contention_lease(
                        policy,
                        nonblocking=True,
                    ):
                        self.fail("lease unexpectedly accepted a symlinked namespace")
            wrapper_result = subprocess.run(
                [
                    str(CONTENTION_WRAPPER),
                    "--mode",
                    "shared",
                    "--policy",
                    str(POLICY),
                    "--",
                    "/usr/bin/true",
                ],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertEqual(wrapper_result.returncode, 1)
            self.assertIn("symlink", wrapper_result.stderr)

    def test_registered_workload_rejects_a_contention_namespace_override(self) -> None:
        route = self.benchmark.BenchmarkRoute(
            label="baseline",
            executable=Path("baseline"),
        )
        candidate = self.benchmark.BenchmarkRoute(
            label="candidate",
            executable=Path("candidate"),
        )
        workload = self.benchmark.load_benchmark_policy(POLICY)["workloads"][
            "tiny-suite"
        ]
        config = self.benchmark.BenchmarkConfig(
            baseline=route,
            candidate=candidate,
            command_arguments=tuple(workload["command_arguments"]),
            measured_pairs=10,
            warmup_pairs=1,
            cache_state="isolated-warm",
            workload_name="tiny-suite",
        )

        with mock.patch.dict(
            os.environ,
            {"BLORP_COMPILER_CONTENTION_LOCK_BASE": "/tmp/not-canonical"},
        ):
            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "contention lock override",
            ):
                self.benchmark.run_benchmark(config)

    def test_registered_characterization_rejects_a_candidate_route(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)
        workload_name = "shared-import-fanout"
        workload = policy["workloads"][workload_name]
        config = self.benchmark.BenchmarkConfig(
            baseline=self.benchmark.BenchmarkRoute(
                label="baseline",
                executable=Path("baseline"),
            ),
            candidate=self.benchmark.BenchmarkRoute(
                label="candidate",
                executable=Path("candidate"),
            ),
            command_arguments=tuple(workload["command_arguments"]),
            measured_pairs=workload["measured_pairs"],
            warmup_pairs=workload["warmup_pairs"],
            timeout_seconds=workload["timeout_seconds"],
            cache_state=workload["cache_state"],
            common_inputs=tuple(
                Path(path) for path in workload["fingerprint_inputs"]
            ),
            workload_name=workload_name,
        )

        with self.assertRaisesRegex(
            self.benchmark.BenchmarkError,
            "baseline-only",
        ):
            self.benchmark.run_benchmark(config)

    def test_contention_wrapper_rejects_an_unmarked_test_override(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            environment = {
                **os.environ,
                "BLORP_COMPILER_CONTENTION_LOCK_BASE": str(
                    Path(temp_name) / "locks"
                ),
            }
            environment.pop("BLORP_COMPILER_CONTENTION_ALLOW_TEST_OVERRIDE", None)
            result = subprocess.run(
                [
                    str(CONTENTION_WRAPPER),
                    "--mode",
                    "shared",
                    "--policy",
                    str(POLICY),
                    "--",
                    "/usr/bin/true",
                ],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("ALLOW_TEST_OVERRIDE", result.stderr)

    def test_route_metadata_contains_only_live_fingerprints(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            executable = temp_dir / "blorp"
            explicit_input = temp_dir / "runtime-input"
            executable.write_bytes(b"public cli")
            explicit_input.write_bytes(b"runtime")
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=executable,
                environment={"BENCHMARK_MODE": "current"},
                inputs=(explicit_input,),
            )

            self.assertEqual(
                set(self.benchmark.route_metadata(route, temp_dir)),
                {
                    "label",
                    "executable",
                    "executable_sha256",
                    "base_environment_keys",
                    "base_environment_sha256",
                    "explicit_inputs",
                    "explicit_inputs_sha256",
                },
            )

    def test_registered_run_records_policy_identity_and_assessment(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)
        workload = policy["workloads"]["tiny-suite"]
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            write_fake_test_command(command)
            common_environment = {"BENCH_ORDER_LOG": str(order_log)}
            baseline = self.benchmark.BenchmarkRoute(
                label="baseline",
                executable=command,
                environment={**common_environment, "BENCH_ROUTE_LABEL": "baseline"},
            )
            candidate = self.benchmark.BenchmarkRoute(
                label="candidate",
                executable=command,
                environment={**common_environment, "BENCH_ROUTE_LABEL": "candidate"},
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=baseline,
                candidate=candidate,
                command_arguments=tuple(workload["command_arguments"]),
                measured_pairs=10,
                warmup_pairs=1,
                timeout_seconds=2.0,
                cache_state="isolated-warm",
                poll_interval_seconds=0.01,
                bootstrap_samples=10_000,
                workload_name="tiny-suite",
            )
            with mock.patch.object(
                self.benchmark,
                "compiler_contention_lock_path",
                return_value=temp_dir / "locks" / "registered.lock",
            ):
                result = self.benchmark.run_benchmark(config, root=temp_dir)

            registration = result["registered_workload"]
            self.assertEqual(
                set(result),
                COMPLETE_RESULT_FIELDS | {"registered_workload", "comparison"},
            )
            self.assertEqual(
                set(registration),
                {
                    "kind",
                    "policy_path",
                    "policy_sha256",
                    "workload_name",
                    "contention_lease_path",
                    "assessment",
                },
            )
            self.assertEqual(registration["kind"], "comparison")
            self.assertEqual(registration["workload_name"], "tiny-suite")
            self.assertEqual(registration["policy_sha256"], self.benchmark.sha256_file(POLICY))
            self.assertEqual(registration["assessment"]["metric"], workload["metric"])
            self.assertNotIn("workload", registration)
            self.assertNotIn("statistical_policy", result)
            self.assertNotIn("publication_ready", result)
            self.assertNotIn("publication_blockers", result)
            self.assertNotIn("evidence_level", result)
            self.assertTrue(
                all("evidence_level" not in run for run in result["measurements"]),
            )

    def test_characterization_run_records_policy_identity_without_assessment(self) -> None:
        policy = self.benchmark.load_benchmark_policy(POLICY)
        workload_name = "shared-import-fanout"
        workload = policy["workloads"][workload_name]
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            write_fake_test_command(command)
            for input_path in workload["fingerprint_inputs"]:
                (temp_dir / input_path).mkdir(parents=True)
            baseline = self.benchmark.BenchmarkRoute(
                label="baseline",
                executable=command,
                environment={
                    "BENCH_ORDER_LOG": str(order_log),
                    "BENCH_ROUTE_LABEL": "baseline",
                },
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=baseline,
                candidate=None,
                command_arguments=tuple(workload["command_arguments"]),
                measured_pairs=workload["measured_pairs"],
                warmup_pairs=workload["warmup_pairs"],
                timeout_seconds=workload["timeout_seconds"],
                cache_state=workload["cache_state"],
                common_inputs=tuple(
                    Path(path) for path in workload["fingerprint_inputs"]
                ),
                workload_name=workload_name,
            )
            with mock.patch.object(
                self.benchmark,
                "compiler_contention_lock_path",
                return_value=temp_dir / "locks" / "characterization.lock",
            ):
                result = self.benchmark.run_benchmark(config, root=temp_dir)

            registration = result["registered_workload"]
            self.assertEqual(
                set(result),
                COMPLETE_RESULT_FIELDS | {"registered_workload"},
            )
            self.assertEqual(
                set(registration),
                {
                    "kind",
                    "policy_path",
                    "policy_sha256",
                    "workload_name",
                    "contention_lease_path",
                },
            )
            self.assertEqual(registration["kind"], "characterization")
            self.assertEqual(registration["workload_name"], workload_name)
            self.assertNotIn("workload", registration)
            self.assertNotIn("assessment", registration)
            self.assertNotIn("statistical_policy", result)
            self.assertNotIn("publication_ready", result)
            self.assertNotIn("publication_blockers", result)
            self.assertNotIn("evidence_level", result)

    def test_cli_retains_failed_registered_assessment_and_exits_nonzero(self) -> None:
        failed_result = {
            "schema_version": 2,
            "registered_workload": {
                "kind": "comparison",
                "assessment": {
                    "status": "fail",
                    "reasons": ["upper confidence bound exceeds regression ceiling"],
                }
            },
        }
        with tempfile.TemporaryDirectory() as temp_name:
            output = Path(temp_name) / "result.json"
            arguments = [
                "--baseline",
                str(Path(temp_name) / "baseline"),
                "--candidate",
                str(Path(temp_name) / "candidate"),
                "--workload",
                "tiny-suite",
                "--output",
                str(output),
                "--",
                "test",
                "fixture.brp",
            ]
            stderr = io.StringIO()

            with (
                mock.patch.object(
                    self.benchmark,
                    "run_benchmark",
                    return_value=failed_result,
                ),
                mock.patch("sys.stderr", stderr),
            ):
                exit_code = self.benchmark.main(arguments)

            self.assertEqual(exit_code, 1)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), failed_result)
            self.assertIn("regression ceiling", stderr.getvalue())

    def test_cli_characterization_does_not_require_regression_assessment(self) -> None:
        characterized_result = {
            "schema_version": 2,
            "registered_workload": {
                "kind": "characterization",
                "workload_name": "shared-import-fanout",
            },
        }
        with tempfile.TemporaryDirectory() as temp_name:
            output = Path(temp_name) / "result.json"
            arguments = [
                "--baseline",
                str(Path(temp_name) / "baseline"),
                "--workload",
                "shared-import-fanout",
                "--output",
                str(output),
                "--",
                "test",
                "fixture.brp",
            ]
            with mock.patch.object(
                self.benchmark,
                "run_benchmark",
                return_value=characterized_result,
            ):
                exit_code = self.benchmark.main(arguments)

            self.assertEqual(exit_code, 0)
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                characterized_result,
            )

    def test_timeout_terminates_the_measured_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "timeout_test"
            child_pid_path = temp_dir / "child.pid"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_timeout_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="timeout",
                executable=command,
                environment={"BENCH_CHILD_PID": str(child_pid_path)},
            )

            result = self.benchmark.run_measurement(
                route=route,
                command_arguments=(),
                root=temp_dir,
                artifact_root=artifact_root,
                phase="measured",
                pair_index=0,
                order_index=0,
                timeout_seconds=1.0,
                poll_interval_seconds=0.01,
                cache_state="existing",
            )

            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            self.assertTrue(result["timed_out"])
            self.assertFalse(self.benchmark.process_exists(child_pid))

    def test_timeout_is_enforced_while_rss_sampling_is_slow(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "sleep_test"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_sleep_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="timeout",
                executable=command,
            )
            original_process_rows = self.benchmark.process_rows

            def delayed_sample():
                time.sleep(0.5)
                return original_process_rows()

            with mock.patch.object(
                self.benchmark,
                "process_rows",
                side_effect=delayed_sample,
            ):
                wall_started_at = time.perf_counter()
                result = self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=temp_dir,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=0.1,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )
                wall_elapsed_seconds = time.perf_counter() - wall_started_at

            self.assertTrue(result["timed_out"])
            self.assertGreater(
                wall_elapsed_seconds - result["elapsed_seconds"],
                0.2,
            )

    def test_timeout_uses_sampled_process_groups_when_cleanup_sampling_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "timeout_test"
            child_pid_path = temp_dir / "child.pid"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_timeout_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="timeout",
                executable=command,
                environment={"BENCH_CHILD_PID": str(child_pid_path)},
            )
            original_process_rows = self.benchmark.process_rows
            started_at = time.monotonic()

            def fail_cleanup_samples():
                if time.monotonic() - started_at >= 0.5:
                    return {}, "forced cleanup sampler failure"
                return original_process_rows()

            with mock.patch.object(
                self.benchmark,
                "process_rows",
                side_effect=fail_cleanup_samples,
            ):
                result = self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=temp_dir,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=0.6,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )

            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            self.assertTrue(result["timed_out"])
            self.assertTrue(result["cleanup_sampling_errors"])
            self.assertFalse(self.benchmark.process_exists(child_pid))

    def test_timeout_cleanup_is_session_wide_when_every_sample_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "timeout_test"
            child_pid_path = temp_dir / "child.pid"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_timeout_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="timeout",
                executable=command,
                environment={"BENCH_CHILD_PID": str(child_pid_path)},
            )

            with mock.patch.object(
                self.benchmark,
                "process_rows",
                return_value=({}, "forced continuous sampler failure"),
            ):
                result = self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=temp_dir,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=2,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )

            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            self.assertTrue(result["cleanup_sampling_errors"])
            self.assertFalse(self.benchmark.process_exists(child_pid))

    def test_cleanup_sampler_rejects_empty_malformed_nonzero_and_timeout(self) -> None:
        invalid_results = [
            subprocess.CompletedProcess(["ps"], 0, stdout="", stderr=""),
            subprocess.CompletedProcess(
                ["ps"],
                0,
                stdout="not process data\n",
                stderr="",
            ),
            subprocess.CompletedProcess(["ps"], 2, stdout="", stderr="failed"),
        ]
        for result in invalid_results:
            with (
                self.subTest(returncode=result.returncode, stdout=result.stdout),
                mock.patch.object(self.benchmark.subprocess, "run", return_value=result),
            ):
                _rows, error = self.benchmark.process_rows_from_command("/bin/ps")
                self.assertIsNotNone(error)

        with mock.patch.object(
            self.benchmark.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(["ps"], 2.0),
        ):
            _rows, error = self.benchmark.process_rows_from_command("/bin/ps")
            self.assertIsNotNone(error)

    def test_sampled_process_group_validation_requires_birth_identity(self) -> None:
        session_id = 100
        process_group_id = 200
        process_id = 300
        sampled_groups = {process_group_id: {process_id: "original birth"}}

        with mock.patch.object(
            self.benchmark,
            "process_row_from_command",
            return_value=(
                (1, process_group_id, session_id, 1024, "reused birth"),
                None,
            ),
        ):
            self.assertEqual(
                self.benchmark.validated_sampled_process_groups(
                    session_id,
                    sampled_groups,
                    "/bin/ps",
                ),
                set(),
            )

        with mock.patch.object(
            self.benchmark,
            "process_row_from_command",
            return_value=(
                (1, process_group_id, session_id, 1024, "original birth"),
                None,
            ),
        ):
            self.assertEqual(
                self.benchmark.validated_sampled_process_groups(
                    session_id,
                    sampled_groups,
                    "/bin/ps",
                ),
                {process_group_id},
            )

    def test_final_cleanup_does_not_trust_new_post_reap_identity(self) -> None:
        process = mock.Mock(pid=100)
        retained_groups = {200: {300: "retained birth"}}
        reused_row = (1, 400, 100, 1024, "post-reap birth")

        with (
            mock.patch.object(
                self.benchmark,
                "process_rows",
                side_effect=[({}, None), ({500: reused_row}, None)],
            ),
            mock.patch.object(
                self.benchmark,
                "terminate_process_session",
                return_value=([500], None),
            ) as terminate,
        ):
            self.benchmark.verify_process_session_exited(
                process,
                retained_groups,
                "/bin/ps",
            )

        self.assertEqual(terminate.call_args.args[1], retained_groups)

    def test_route_elapsed_excludes_post_exit_process_verification(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                },
            )
            original_verify = self.benchmark.verify_process_session_exited

            def delayed_verify(*args, **kwargs):
                time.sleep(0.4)
                return original_verify(*args, **kwargs)

            with mock.patch.object(
                self.benchmark,
                "verify_process_session_exited",
                side_effect=delayed_verify,
            ):
                wall_started_at = time.perf_counter()
                result = self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=temp_dir,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=2.0,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )
                wall_elapsed_seconds = time.perf_counter() - wall_started_at

            self.assertGreater(result["post_exit_process_verification_seconds"], 0.39)
            self.assertGreater(
                wall_elapsed_seconds - result["elapsed_seconds"],
                0.35,
            )

    def test_route_elapsed_excludes_slow_rss_sampling(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            sample_started_path = temp_dir / "sample-started"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_fake_test_command(command)
            launched_processes = []
            original_launch = self.benchmark.launch_route_process
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                    "BENCH_SAMPLE_STARTED": str(sample_started_path),
                },
            )
            original_process_rows = self.benchmark.process_rows

            def recording_launch(*args, **kwargs):
                process = original_launch(*args, **kwargs)
                launched_processes.append(process)
                return process

            def delayed_sample():
                sample_started_path.touch()
                process = launched_processes[0]
                deadline = time.monotonic() + 2.0
                while process.returncode is None and time.monotonic() < deadline:
                    time.sleep(0.005)
                if process.returncode is None:
                    raise RuntimeError("route did not finish during delayed sample")
                time.sleep(0.3)
                return original_process_rows()

            with (
                mock.patch.object(
                    self.benchmark,
                    "launch_route_process",
                    side_effect=recording_launch,
                ),
                mock.patch.object(
                    self.benchmark,
                    "process_rows",
                    side_effect=delayed_sample,
                ),
            ):
                wall_started_at = time.perf_counter()
                result = self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=temp_dir,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=2.0,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )
                wall_elapsed_seconds = time.perf_counter() - wall_started_at

            self.assertGreater(
                wall_elapsed_seconds - result["elapsed_seconds"],
                0.25,
            )

    def test_rss_sample_returned_after_completion_is_not_retained(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                },
            )
            launched_processes = []
            original_launch = self.benchmark.launch_route_process

            def recording_launch(*args, **kwargs):
                process = original_launch(*args, **kwargs)
                launched_processes.append(process)
                return process

            def delayed_post_completion_sample():
                process = launched_processes[0]
                deadline = time.monotonic() + 2.0
                while process.returncode is None and time.monotonic() < deadline:
                    time.sleep(0.005)
                if process.returncode is None:
                    raise RuntimeError("route did not complete during delayed sample")
                time.sleep(0.02)
                process_id = process.pid
                return {
                    process_id: (
                        1,
                        process_id,
                        process_id,
                        1024,
                        "post-completion birth",
                    )
                }, None

            with (
                mock.patch.object(
                    self.benchmark,
                    "launch_route_process",
                    side_effect=recording_launch,
                ),
                mock.patch.object(
                    self.benchmark,
                    "process_rows",
                    side_effect=delayed_post_completion_sample,
                ),
                mock.patch.object(
                    self.benchmark,
                    "verify_process_session_exited",
                    return_value=([], [], []),
                ),
            ):
                result = self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=temp_dir,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=2.0,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )

            self.assertEqual(result["sampled_unique_process_count"], 0)

    def test_normal_exit_with_live_descendant_is_rejected_and_cleaned(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "lingering_test"
            child_pid_path = temp_dir / "child.pid"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_lingering_child_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="lingering",
                executable=command,
                environment={"BENCH_CHILD_PID": str(child_pid_path)},
            )

            result = self.benchmark.run_measurement(
                route=route,
                command_arguments=(),
                root=temp_dir,
                artifact_root=artifact_root,
                phase="measured",
                pair_index=0,
                order_index=0,
                timeout_seconds=3.0,
                poll_interval_seconds=0.01,
                cache_state="existing",
            )

            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            self.assertTrue(result["unexpected_live_descendants"])
            self.assertFalse(self.benchmark.process_exists(child_pid))
            self.assertIn("descendant", self.benchmark.measurement_failed(result))

    def test_normal_exit_cleanup_uses_last_groups_when_sampling_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "lingering_test"
            child_pid_path = temp_dir / "child.pid"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_lingering_child_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="lingering",
                executable=command,
                environment={"BENCH_CHILD_PID": str(child_pid_path)},
            )
            original_process_rows = self.benchmark.process_rows

            def fail_after_parent_exit():
                rows, sample_error = original_process_rows()
                if child_pid_path.exists():
                    child_pid = int(child_pid_path.read_text(encoding="utf-8"))
                    child_row = rows.get(child_pid)
                    if child_row is not None and child_row[2] not in rows:
                        return {}, "forced post-exit sampler failure"
                return rows, sample_error

            with mock.patch.object(
                self.benchmark,
                "process_rows",
                side_effect=fail_after_parent_exit,
            ):
                result = self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=temp_dir,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=3.0,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )

            child_pid = int(child_pid_path.read_text(encoding="utf-8"))
            self.assertTrue(result["cleanup_sampling_errors"])
            self.assertFalse(self.benchmark.process_exists(child_pid))
            self.assertIn("cleanup", self.benchmark.measurement_failed(result))

    def test_measurement_records_actual_cache_and_environment_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            environment_log = temp_dir / "environment.log"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                    "BENCH_ENV_LOG": str(environment_log),
                    "BLORP_TEST_TIMINGS": "wrong",
                    "BLORP_GATE_RESULT": "wrong",
                    "BLORP_RUNTIME_CACHE": "wrong",
                },
            )

            first = self.benchmark.run_measurement(
                route=route,
                command_arguments=(),
                root=temp_dir,
                artifact_root=artifact_root,
                phase="measured",
                pair_index=0,
                order_index=0,
                timeout_seconds=2.0,
                poll_interval_seconds=0.01,
                cache_state="isolated-warm",
            )
            second = self.benchmark.run_measurement(
                route=route,
                command_arguments=(),
                root=temp_dir,
                artifact_root=artifact_root,
                phase="measured",
                pair_index=1,
                order_index=0,
                timeout_seconds=2.0,
                poll_interval_seconds=0.01,
                cache_state="isolated-warm",
            )

            child_environments = [
                json.loads(line)
                for line in environment_log.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(
                child_environments[0],
                child_environments[1],
            )
            self.assertEqual(child_environments[0]["timings"], "1")
            self.assertEqual(
                child_environments[0]["gate"],
                "test-session-benchmark",
            )
            self.assertNotEqual(child_environments[0]["runtime_cache"], "wrong")
            self.assertEqual(
                first["runtime_cache_directory"],
                second["runtime_cache_directory"],
            )
            self.assertEqual(
                first["effective_environment_sha256"],
                second["effective_environment_sha256"],
            )

    def test_parse_failure_retains_incomplete_measurement_metadata(self) -> None:
        with (
            tempfile.TemporaryDirectory() as root_name,
            tempfile.TemporaryDirectory() as artifact_parent_name,
        ):
            root = Path(root_name)
            artifact_root = Path(artifact_parent_name) / "retained"
            command = root / "fake_test"
            order_log = root / "order.log"
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                    "BENCH_MALFORMED": "1",
                },
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=route,
                candidate=None,
                command_arguments=(),
                measured_pairs=1,
                warmup_pairs=0,
                timeout_seconds=2.0,
                cache_state="existing",
                poll_interval_seconds=0.01,
                bootstrap_samples=50,
                artifact_directory=artifact_root,
            )

            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "malformed session counter",
            ):
                self.benchmark.run_benchmark(config, root=root)

            measurement_paths = list(artifact_root.glob("runs/*/measurement.json"))
            self.assertEqual(len(measurement_paths), 1)
            failure = json.loads(measurement_paths[0].read_text(encoding="utf-8"))
            self.assertEqual(set(failure), INCOMPLETE_MEASUREMENT_FIELDS)
            self.assertEqual(failure["schema_version"], 2)
            self.assertEqual(failure["measurement_status"], "incomplete")
            self.assertEqual(failure["failure_stage"], "observation_parsing")
            self.assertGreater(failure["stderr_bytes"], 0)

    def test_spawn_failure_retains_incomplete_measurement_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            command = root / "fake_test"
            artifact_root = root / "artifacts"
            artifact_root.mkdir()
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
            )

            with (
                mock.patch.object(
                    self.benchmark,
                    "launch_route_process",
                    side_effect=OSError("forced spawn failure"),
                ),
                self.assertRaisesRegex(OSError, "forced spawn failure"),
            ):
                self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=root,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=2.0,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )

            measurement_paths = list(artifact_root.glob("runs/*/measurement.json"))
            self.assertEqual(len(measurement_paths), 1)
            failure = json.loads(measurement_paths[0].read_text(encoding="utf-8"))
            self.assertEqual(set(failure), INCOMPLETE_MEASUREMENT_FIELDS)
            self.assertEqual(failure["schema_version"], 2)
            self.assertEqual(failure["failure_stage"], "process_execution")
            self.assertEqual(failure["failure_type"], "OSError")

    def test_supervisor_start_failure_terminates_and_reaps_launched_route(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            command = root / "sleep_test"
            artifact_root = root / "artifacts"
            artifact_root.mkdir()
            write_sleep_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
            )
            launched_processes = []
            original_launch = self.benchmark.launch_route_process

            def recording_launch(*args, **kwargs):
                process = original_launch(*args, **kwargs)
                launched_processes.append(process)
                return process

            try:
                with (
                    mock.patch.object(
                        self.benchmark,
                        "launch_route_process",
                        side_effect=recording_launch,
                    ),
                    mock.patch.object(
                        self.benchmark.threading.Thread,
                        "start",
                        side_effect=RuntimeError("forced waiter startup failure"),
                    ),
                    self.assertRaisesRegex(RuntimeError, "forced waiter startup failure"),
                ):
                    self.benchmark.run_measurement(
                        route=route,
                        command_arguments=(),
                        root=root,
                        artifact_root=artifact_root,
                        phase="measured",
                        pair_index=0,
                        order_index=0,
                        timeout_seconds=2.0,
                        poll_interval_seconds=0.01,
                        cache_state="existing",
                    )

                self.assertEqual(len(launched_processes), 1)
                self.assertIsNotNone(launched_processes[0].poll())
            finally:
                for process in launched_processes:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=2.0)

    def test_incomplete_rss_sampling_is_reported_as_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            artifact_root = temp_dir / "artifacts"
            artifact_root.mkdir()
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                },
            )
            original_process_rows = self.benchmark.process_rows
            sample_count = 0

            def fail_first_sample():
                nonlocal sample_count
                sample_count += 1
                if sample_count == 1:
                    return {}, "forced sampler failure"
                return original_process_rows()

            with mock.patch.object(
                self.benchmark,
                "process_rows",
                side_effect=fail_first_sample,
            ):
                result = self.benchmark.run_measurement(
                    route=route,
                    command_arguments=(),
                    root=temp_dir,
                    artifact_root=artifact_root,
                    phase="measured",
                    pair_index=0,
                    order_index=0,
                    timeout_seconds=2.0,
                    poll_interval_seconds=0.01,
                    cache_state="existing",
                )

            self.assertIsNone(result["sampled_aggregate_peak_rss_bytes"])
            self.assertFalse(result["rss_sampling"]["complete"])
            self.assertEqual(result["rss_sampling"]["failed_samples"], 1)

    def test_failed_comparison_retains_raw_artifacts_when_requested(self) -> None:
        with (
            tempfile.TemporaryDirectory() as root_name,
            tempfile.TemporaryDirectory() as artifact_parent_name,
        ):
            root = Path(root_name)
            artifact_root = Path(artifact_parent_name) / "retained"
            command = root / "fake_test"
            order_log = root / "order.log"
            write_fake_test_command(command)
            baseline = self.benchmark.BenchmarkRoute(
                label="baseline",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "baseline",
                    "BENCH_ORDER_LOG": str(order_log),
                },
            )
            candidate = self.benchmark.BenchmarkRoute(
                label="candidate",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "candidate",
                    "BENCH_ORDER_LOG": str(order_log),
                    "BENCH_MISMATCH": "1",
                },
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=baseline,
                candidate=candidate,
                command_arguments=(),
                measured_pairs=1,
                warmup_pairs=0,
                timeout_seconds=2.0,
                cache_state="isolated-cold",
                poll_interval_seconds=0.01,
                bootstrap_samples=50,
                artifact_directory=artifact_root,
            )

            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "semantic result mismatch",
            ):
                self.benchmark.run_benchmark(config, root=root)

            self.assertEqual(len(list(artifact_root.glob("runs/*/stdout.bin"))), 2)
            self.assertEqual(len(list(artifact_root.glob("runs/*/stderr.bin"))), 2)
            self.assertEqual(
                len(list(artifact_root.glob("runs/*/measurement.json"))),
                2,
            )

    def test_sigterm_terminates_active_measurement_process_group(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temp_name,
            tempfile.TemporaryDirectory() as artifact_parent_name,
        ):
            temp_dir = Path(temp_name)
            command = temp_dir / "timeout_test"
            child_pid_path = temp_dir / "child.pid"
            artifact_root = Path(artifact_parent_name) / "retained"
            write_timeout_command(command)
            benchmark_process = subprocess.Popen(
                [
                    str(SCRIPT),
                    "--baseline",
                    str(command),
                    "--baseline-env",
                    f"BENCH_CHILD_PID={child_pid_path}",
                    "--pairs",
                    "1",
                    "--warmup-pairs",
                    "0",
                    "--timeout",
                    "30",
                    "--artifact-dir",
                    str(artifact_root),
                    "--allow-dirty",
                    "--",
                    "ignored",
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                deadline = time.monotonic() + 10.0
                while not child_pid_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(child_pid_path.exists())
                child_pid = int(child_pid_path.read_text(encoding="utf-8"))
                benchmark_process.send_signal(signal.SIGTERM)
                time.sleep(0.05)
                if benchmark_process.poll() is None:
                    benchmark_process.send_signal(signal.SIGTERM)
                stdout, stderr = benchmark_process.communicate(timeout=10.0)
                self.assertEqual(
                    benchmark_process.returncode,
                    128 + signal.SIGTERM,
                    (stdout, stderr),
                )
                deadline = time.monotonic() + 2.0
                while self.benchmark.process_exists(child_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(self.benchmark.process_exists(child_pid))
                self.assertTrue(artifact_root.exists())
                measurement_paths = list(
                    artifact_root.glob("runs/*/measurement.json")
                )
                self.assertEqual(len(measurement_paths), 1)
                failure = json.loads(
                    measurement_paths[0].read_text(encoding="utf-8")
                )
                self.assertEqual(failure["measurement_status"], "incomplete")
                self.assertEqual(failure["failure_type"], "BenchmarkInterrupted")
            finally:
                if benchmark_process.poll() is None:
                    benchmark_process.kill()
                    benchmark_process.wait()

    def test_output_validation_refuses_existing_or_input_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            command = root / "command"
            command.write_text("command\n", encoding="utf-8")
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
            )

            with self.assertRaisesRegex(self.benchmark.BenchmarkError, "already exists"):
                self.benchmark.validate_output_path(
                    command,
                    root=root,
                    routes=[route],
                    common_inputs=(),
                )

    def test_artifact_directory_rejects_symlinked_parent_inside_worktree(self) -> None:
        with (
            tempfile.TemporaryDirectory() as root_name,
            tempfile.TemporaryDirectory() as outside_name,
        ):
            root = Path(root_name).resolve()
            link = Path(outside_name) / "worktree-link"
            link.symlink_to(root, target_is_directory=True)

            with self.assertRaisesRegex(
                self.benchmark.BenchmarkError,
                "outside the measured worktree",
            ):
                self.benchmark.prepare_artifact_root(link / "evidence", root)

    def test_json_result_is_serializable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            command = temp_dir / "fake_test"
            order_log = temp_dir / "order.log"
            write_fake_test_command(command)
            route = self.benchmark.BenchmarkRoute(
                label="current",
                executable=command,
                environment={
                    "BENCH_ROUTE_LABEL": "current",
                    "BENCH_ORDER_LOG": str(order_log),
                },
            )
            config = self.benchmark.BenchmarkConfig(
                baseline=route,
                candidate=None,
                command_arguments=(),
                measured_pairs=1,
                warmup_pairs=0,
                timeout_seconds=2.0,
                cache_state="existing",
                poll_interval_seconds=0.01,
                bootstrap_samples=50,
            )

            result = self.benchmark.run_benchmark(config, root=temp_dir)

            json.dumps(result)
            self.assertEqual(set(result), COMPLETE_RESULT_FIELDS)
            self.assertEqual(result["schema_version"], 2)
            self.assertEqual(result["measurement_status"], "complete")
            self.assertNotIn("evidence_level", result)
            self.assertNotIn("publication_ready", result)
            self.assertNotIn("publication_blockers", result)
            self.assertNotIn("statistical_policy", result)
            self.assertNotIn("comparison", result)


if __name__ == "__main__":
    unittest.main()
