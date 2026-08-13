#!/usr/bin/env python3
"""Contract tests for benchmarks/compiler_perceus_memory."""

from __future__ import annotations

import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "benchmarks" / "compiler_perceus_memory"


def load_benchmark_module():
    loader = importlib.machinery.SourceFileLoader(
        "compiler_perceus_memory_benchmark",
        str(SCRIPT),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create benchmark module spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class CompilerPerceusMemoryBenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.benchmark = load_benchmark_module()

    def perceus_response(
        self,
        global_count: int = 4,
        function_count: int = 2,
        params_per_function: int = 0,
        parameter_type: str = "String",
    ):
        _, program = self.benchmark.fixture_request(
            global_count,
            function_count,
            4,
            1,
            params_per_function=params_per_function,
            parameter_type=parameter_type,
        )
        worker = program["decls"][global_count]
        worker["body"] = {
            "kind": "drop",
            "var": self.benchmark.core_var("BENCH_MANAGED_LOCAL_0000", None),
            "value_type": self.benchmark.named_type("String"),
            "release_policy": "arc",
            "body": worker["body"],
            "type": self.benchmark.named_type("Int"),
            "loc": self.benchmark.synthetic_loc(),
        }
        return {"ok": True, "artifact": {"core": program}}

    def test_fixture_stops_after_perceus_by_default(self) -> None:
        request, _ = self.benchmark.fixture_request(4, 2, 4, 1)

        self.assertEqual(request["action"], self.benchmark.PERCEUS_ACTION)

    def test_validator_accepts_perceus_core_artifact(self) -> None:
        response = self.perceus_response()

        with tempfile.TemporaryDirectory() as temp_name:
            response_path = Path(temp_name) / "response.json"
            response_path.write_text(json.dumps(response), encoding="utf-8")
            artifact_bytes, artifact_hash = self.benchmark.validate_response(
                response_path,
                4,
                2,
                self.benchmark.PERCEUS_ACTION,
                0,
                "String",
            )

        self.assertGreater(artifact_bytes, 0)
        self.assertEqual(len(artifact_hash), 64)

    def test_validator_rejects_echoed_pre_perceus_core(self) -> None:
        _, program = self.benchmark.fixture_request(4, 2, 4, 1)
        response = {"ok": True, "artifact": {"core": program}}

        with tempfile.TemporaryDirectory() as temp_name:
            response_path = Path(temp_name) / "response.json"
            response_path.write_text(json.dumps(response), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "ownership event"):
                self.benchmark.validate_response(
                    response_path,
                    4,
                    2,
                    self.benchmark.PERCEUS_ACTION,
                    0,
                    "String",
                )

    def test_validator_rejects_wrong_artifact_for_action(self) -> None:
        response = {"ok": True, "artifact": {"c_code": "int main(void) { return 0; }"}}

        with tempfile.TemporaryDirectory() as temp_name:
            response_path = Path(temp_name) / "response.json"
            response_path.write_text(json.dumps(response), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "Perceus Core"):
                self.benchmark.validate_response(
                    response_path,
                    4,
                    2,
                    self.benchmark.PERCEUS_ACTION,
                    0,
                    "String",
                )

    def test_validator_rejects_changed_parameter_shape(self) -> None:
        response = self.perceus_response()
        response["artifact"]["core"]["decls"][4]["params"] = []

        with tempfile.TemporaryDirectory() as temp_name:
            response_path = Path(temp_name) / "response.json"
            response_path.write_text(json.dumps(response), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "parameter shape"):
                self.benchmark.validate_response(
                    response_path,
                    4,
                    2,
                    self.benchmark.PERCEUS_ACTION,
                    1,
                    "String",
                )

    def test_validator_rejects_missing_parameter_read(self) -> None:
        response = self.perceus_response(params_per_function=1)
        worker = response["artifact"]["core"]["decls"][4]
        worker["body"] = self.benchmark.literal_expr("int", 0, "Int")

        with tempfile.TemporaryDirectory() as temp_name:
            response_path = Path(temp_name) / "response.json"
            response_path.write_text(json.dumps(response), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "parameter reads"):
                self.benchmark.validate_response(
                    response_path,
                    4,
                    2,
                    self.benchmark.PERCEUS_ACTION,
                    1,
                    "String",
                )

    def test_global_matrix_reuses_one_explicit_worker(self) -> None:
        args = argparse.Namespace(
            bridge=None,
            baseline_bridge=None,
            globals=1,
            functions=2,
            body_leaves=64,
            global_reads_per_function=0,
            end_to_end=False,
            vmmap=False,
            json=True,
            samples=7,
            warmup=True,
            global_matrix=True,
            timeout=60.0,
            params_per_function=0,
            parameter_type="String",
            parameter_matrix=False,
            invoke_workers=True,
            build_mode="benchmark-worker-O0",
        )

        with mock.patch.object(
            self.benchmark,
            "prepare_backend_worker",
            return_value=Path("/tmp/perceus-worker"),
        ) as prepare, mock.patch.object(
            self.benchmark,
            "run_benchmark",
            return_value=0,
        ) as run:
            self.benchmark.run_global_matrix(args)

        prepare.assert_called_once()
        self.assertEqual(
            [
                (call.args[0].globals, call.args[0].global_reads_per_function)
                for call in run.call_args_list
            ],
            [(32, 0), (32, 32), (384, 0), (384, 32)],
        )
        self.assertTrue(all(call.args[0].bridge == "/tmp/perceus-worker" for call in run.call_args_list))

    def test_parameter_fixture_varies_params_without_growing_expression_tree(self) -> None:
        _, one_param_program = self.benchmark.fixture_request(
            1,
            2,
            64,
            0,
            params_per_function=1,
            parameter_type="String",
            invoke_workers=False,
        )
        _, many_param_program = self.benchmark.fixture_request(
            1,
            2,
            64,
            0,
            params_per_function=32,
            parameter_type="String",
            invoke_workers=False,
        )

        one_param_worker = one_param_program["decls"][1]
        many_param_worker = many_param_program["decls"][1]
        one_param_main = one_param_program["decls"][-1]
        many_param_main = many_param_program["decls"][-1]

        self.assertEqual(len(one_param_worker["params"]), 1)
        self.assertEqual(len(many_param_worker["params"]), 32)
        def borrowed_param_reads(value):
            if isinstance(value, dict):
                own_read = int(
                    value.get("kind") == "var"
                    and value.get("var", {}).get("name", "").startswith(
                        "BENCH_BORROWED_PARAM_"
                    )
                )
                return own_read + sum(borrowed_param_reads(item) for item in value.values())
            if isinstance(value, list):
                return sum(borrowed_param_reads(item) for item in value)
            return 0

        self.assertEqual(borrowed_param_reads(one_param_worker["body"]), 1)
        self.assertEqual(borrowed_param_reads(many_param_worker["body"]), 32)
        self.assertEqual(one_param_main["body"], many_param_main["body"])
        self.assertEqual(
            self.benchmark.input_expression_count(1, 2, 64, 0, False),
            self.benchmark.input_expression_count(1, 2, 64, 32, False),
        )

    def test_parameter_matrix_reuses_one_worker_and_runs_required_points(self) -> None:
        args = argparse.Namespace(
            bridge=None,
            baseline_bridge=None,
            globals=384,
            functions=2,
            body_leaves=64,
            global_reads_per_function=32,
            params_per_function=0,
            parameter_type="String",
            end_to_end=False,
            vmmap=False,
            json=True,
            samples=7,
            warmup=True,
            global_matrix=False,
            parameter_matrix=True,
            invoke_workers=True,
            build_mode="benchmark-worker-O0",
            timeout=60.0,
        )

        with mock.patch.object(
            self.benchmark,
            "prepare_backend_worker",
            return_value=Path("/tmp/perceus-worker"),
        ) as prepare, mock.patch.object(
            self.benchmark,
            "run_benchmark",
            return_value=0,
        ) as run:
            self.benchmark.run_parameter_matrix(args)

        prepare.assert_called_once()
        self.assertEqual(
            [call.args[0].params_per_function for call in run.call_args_list],
            [1, 8, 32],
        )
        self.assertEqual(
            [call.args[0].parameter_type for call in run.call_args_list],
            ["String", "String", "String"],
        )
        self.assertEqual(
            [call.args[0].control_parameter_type for call in run.call_args_list],
            [
                "Int",
                "Int",
                "Int",
            ],
        )
        self.assertTrue(all(call.args[0].globals == 1 for call in run.call_args_list))
        self.assertTrue(
            all(
                call.args[0].functions == self.benchmark.PARAMETER_MATRIX_FUNCTIONS
                for call in run.call_args_list
            )
        )
        self.assertTrue(
            all(
                call.args[0].body_leaves == self.benchmark.PARAMETER_MATRIX_BODY_LEAVES
                for call in run.call_args_list
            )
        )
        self.assertTrue(
            all(call.args[0].global_reads_per_function == 0 for call in run.call_args_list)
        )
        self.assertTrue(all(not call.args[0].invoke_workers for call in run.call_args_list))
        self.assertTrue(
            all(call.args[0].build_mode == "benchmark-worker-O0" for call in run.call_args_list)
        )

    def test_parameter_matrix_ignores_single_fixture_shape_arguments(self) -> None:
        with mock.patch.object(
            self.benchmark,
            "run_parameter_matrix",
            return_value=0,
        ) as run:
            exit_code = self.benchmark.main([
                "--parameter-matrix",
                "--globals",
                "1",
                "--global-reads-per-function",
                "100",
                "--params-per-function",
                "100",
                "--body-leaves",
                "1",
            ])

        self.assertEqual(exit_code, 0)
        run.assert_called_once()

    def test_parameter_matrix_rejects_end_to_end_mode(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                self.benchmark.main(["--parameter-matrix", "--end-to-end"])

        self.assertEqual(raised.exception.code, 2)

    def test_paired_sample_order_alternates_baseline_and_candidate(self) -> None:
        self.assertEqual(
            self.benchmark.paired_sample_order(0),
            ("baseline", "candidate"),
        )
        self.assertEqual(
            self.benchmark.paired_sample_order(1),
            ("candidate", "baseline"),
        )

    def test_paired_summary_reports_candidate_over_baseline_ratio(self) -> None:
        summary = self.benchmark.summarize_paired_elapsed(
            [2.0, 4.0, 8.0],
            [1.0, 3.0, 4.0],
        )

        self.assertEqual(summary["baseline_elapsed_seconds"], 4.0)
        self.assertEqual(summary["candidate_elapsed_seconds"], 3.0)
        self.assertEqual(summary["candidate_baseline_ratio"], 0.75)
        self.assertEqual(summary["paired_ratios"], [0.5, 0.75, 0.5])

    def test_measurement_worker_times_out_renderer(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            bridge_path = temp_dir / "slow-bridge"
            request_path = temp_dir / "request.json"
            response_path = temp_dir / "response.json"
            stderr_path = temp_dir / "stderr.txt"
            metrics_path = temp_dir / "metrics.json"
            bridge_path.write_text("#!/bin/sh\nsleep 10\n", encoding="utf-8")
            bridge_path.chmod(0o755)
            request_path.write_text("{}", encoding="utf-8")

            exit_code = self.benchmark.measurement_worker([
                os.fspath(bridge_path),
                os.fspath(request_path),
                os.fspath(response_path),
                os.fspath(stderr_path),
                os.fspath(metrics_path),
                "0.05",
                "0",
            ])
            metrics = json.loads(metrics_path.read_text(encoding="utf-8"))

        self.assertEqual(exit_code, 0)
        self.assertTrue(metrics["timed_out"])


if __name__ == "__main__":
    unittest.main()
