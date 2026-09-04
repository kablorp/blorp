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


ROOT = Path(__file__).resolve().parents[4]
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

    def test_measurement_windows_have_explicit_actions_and_labels(self) -> None:
        self.assertEqual(
            self.benchmark.measurement_action("ownership-preparation-plus-perceus"),
            self.benchmark.MEASURE_OWNERSHIP_PREPARATION_PERCEUS_ACTION,
        )
        self.assertEqual(
            self.benchmark.measurement_action("perceus-direct"),
            self.benchmark.MEASURE_PERCEUS_DIRECT_ACTION,
        )
        self.assertEqual(
            self.benchmark.measurement_window_label(
                self.benchmark.MEASURE_OWNERSHIP_PREPARATION_PERCEUS_ACTION,
            ),
            "ownership-preparation plus Perceus",
        )
        self.assertEqual(
            self.benchmark.measurement_window_label(
                self.benchmark.MEASURE_PERCEUS_DIRECT_ACTION,
            ),
            "direct Perceus",
        )
        self.assertEqual(
            self.benchmark.measurement_window_label(self.benchmark.END_TO_END_ACTION),
            "backend emission",
        )

    def test_generated_c_ownership_census_separates_operation_kinds(self) -> None:
        census = self.benchmark.generated_c_ownership_census(
            "blorp_retain(x); blorp_release(x); blorp_release_arc_only(y); "
            "blorp_task_cleanup_push(a); blorp_task_cleanup_pop_slot(b); "
            "blorp_task_cleanup_duplicate_slot(c); "
            "blorp_stack_result_retain(d); blorp_stack_result_retain_value(e); "
            "blorp_stack_result_release(f); "
            'const char *s = "blorp_retain(fake)"; '
            "// blorp_release(fake)\n/* blorp_task_cleanup_push(fake) */"
        )

        self.assertEqual(census, {
            "retain_calls": 1,
            "release_calls": 1,
            "release_arc_only_calls": 1,
            "cleanup_push_calls": 1,
            "cleanup_pop_calls": 1,
            "cleanup_duplicate_calls": 1,
            "stack_result_retain_calls": 1,
            "stack_result_retain_value_calls": 1,
            "stack_result_release_calls": 1,
        })

    def test_profile_counter_parser_requires_complete_exact_schema(self) -> None:
        rows = []
        expected = {}
        for index, name in enumerate(self.benchmark.PERCEUS_WORK_COUNTER_NAMES, start=1):
            expected[name] = index - 1
            rows.append(
                f"compiler_perceus_work_{name} 0.001 0.1% {index} 0.100"
            )

        actual = self.benchmark.parse_perceus_work_counters("\n".join(rows))

        self.assertEqual(actual, expected)
        with self.assertRaisesRegex(RuntimeError, "missing Perceus work counters"):
            self.benchmark.parse_perceus_work_counters("\n".join(rows[:-1]))

    def test_profile_counter_parser_accepts_pre_tranche_two_baseline_schema(self) -> None:
        rows = []
        for index, name in enumerate(
            self.benchmark.LEGACY_PERCEUS_WORK_COUNTER_NAMES,
            start=1,
        ):
            rows.append(
                f"compiler_perceus_work_{name} 0.001 0.1% {index} 0.100"
            )

        actual = self.benchmark.parse_perceus_work_counters(
            "\n".join(rows),
            require_tranche_2=False,
        )

        self.assertEqual(set(actual), set(self.benchmark.LEGACY_PERCEUS_WORK_COUNTER_NAMES))

    def test_contract_inference_uses_collected_equations_without_body_rescans(self) -> None:
        perceus_source = (
            ROOT / "blorp" / "src" / "compiler" / "stage_09_core" / "perceus.brp"
        ).read_text(encoding="utf-8")

        for required in (
            "record ParameterFlow",
            "record FunctionContractEquation",
            "record OwnershipContractGraph",
            "collect_function_contract_equation",
            "solve_user_call_contracts",
        ):
            self.assertIn(required, perceus_source)

        for obsolete in (
            "private pure func infer_user_contract(",
            "private pure func analyze_user_contract_wave(",
        ):
            self.assertNotIn(obsolete, perceus_source)

    def test_core_ownership_census_counts_policies(self) -> None:
        response = self.perceus_response()
        body = response["artifact"]["core"]["decls"][4]["body"]
        response["artifact"]["core"]["decls"][4]["body"] = {
            "kind": "dup",
            "var": self.benchmark.core_var("BENCH_MANAGED_LOCAL_0000", None),
            "value_type": self.benchmark.named_type("String"),
            "retain_policy": "arc",
            "body": body,
            "type": self.benchmark.named_type("Int"),
            "loc": self.benchmark.synthetic_loc(),
        }

        census = self.benchmark.core_ownership_census(response["artifact"]["core"])

        self.assertEqual(census["dup_by_policy"], {"arc": 1})
        self.assertEqual(census["drop_by_policy"], {"arc": 1})

    def test_core_expression_census_vocabulary_matches_serialized_ir(self) -> None:
        ir_source = (
            ROOT / "blorp" / "src" / "compiler" / "stage_09_core" / "ir.brp"
        ).read_text(encoding="utf-8")
        serialized_tags = set(
            self.benchmark.re.findall(
                r'^private [A-Z0-9_]+_EXPR_TAG: String = "([^"]+)"',
                ir_source,
                self.benchmark.re.MULTILINE,
            )
        )

        self.assertEqual(self.benchmark.CORE_EXPR_KINDS, serialized_tags)

    def test_supported_body_shapes_are_structurally_distinct(self) -> None:
        fingerprints = set()
        for body_shape in self.benchmark.BODY_SHAPES:
            _, program = self.benchmark.fixture_request(
                4,
                3,
                64,
                2,
                params_per_function=2,
                body_shape=body_shape,
                branch_arms=2,
                user_call_edges=2,
            )
            worker = next(
                declaration
                for declaration in program["decls"]
                if declaration.get("name") == "bench_worker_0000"
            )
            fingerprints.add(json.dumps(worker["body"], sort_keys=True))

        self.assertEqual(len(fingerprints), len(self.benchmark.BODY_SHAPES))

    def test_borrowed_call_fixture_invokes_workers_with_heap_records(self) -> None:
        _, program = self.benchmark.fixture_request(
            1,
            1,
            16,
            0,
            params_per_function=2,
            body_shape="borrowed_call_protection",
        )
        main = next(
            declaration
            for declaration in program["decls"]
            if declaration.get("name") == "main"
        )
        call = main["body"]["first"]

        self.assertEqual(
            [argument["kind"] for argument in call["args"]],
            ["record_construct", "record_construct"],
        )

    def test_call_graph_shapes_pass_borrowed_parameters_across_edges(self) -> None:
        _, program = self.benchmark.fixture_request(
            1,
            3,
            14,
            0,
            params_per_function=2,
            body_shape="nested_user_call",
            user_call_edges=1,
        )
        worker_body = program["decls"][1]["body"]
        rendered = json.dumps(worker_body, sort_keys=True)

        self.assertIn("BENCH_BORROWED_PARAM_0000_0000", rendered)
        self.assertIn("BENCH_BORROWED_PARAM_0000_0001", rendered)
        self.assertIn("bench_worker_0001", rendered)

    def test_mutual_call_edge_count_uses_distinct_callees(self) -> None:
        _, program = self.benchmark.fixture_request(
            1,
            4,
            64,
            0,
            params_per_function=1,
            body_shape="mutually_recursive_calls",
            user_call_edges=3,
        )
        rendered = json.dumps(program["decls"][1]["body"], sort_keys=True)

        self.assertIn("bench_worker_0001", rendered)
        self.assertIn("bench_worker_0002", rendered)
        self.assertIn("bench_worker_0003", rendered)
        self.assertEqual(rendered.count('"kind": "user"'), 3)

    def test_contract_fixture_holds_body_nodes_constant_when_varying_owners(self) -> None:
        body_counts = []
        for owner_count in (1, 8, 32, 128):
            _, program = self.benchmark.fixture_request(
                1,
                self.benchmark.CONTRACT_MATRIX_FUNCTIONS,
                self.benchmark.CONTRACT_MATRIX_OWNER_BODY_LEAVES,
                0,
                params_per_function=owner_count,
                body_shape="nested_user_call",
                user_call_edges=1,
                invoke_workers=False,
            )
            body_counts.append([
                self.benchmark.expression_node_count(decl["body"])
                for decl in program["decls"]
                if decl["kind"] == "function" and decl["name"] != "main"
            ])

        self.assertTrue(all(counts == body_counts[0] for counts in body_counts))
        self.assertEqual(
            body_counts[0],
            [self.benchmark.CONTRACT_MATRIX_OWNER_BODY_LEAVES]
            * self.benchmark.CONTRACT_MATRIX_FUNCTIONS,
        )

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
            all(
                call.args[0].body_shape == "borrowed_call_protection"
                for call in run.call_args_list
            )
        )
        self.assertTrue(
            all(call.args[0].build_mode == "benchmark-worker-O0" for call in run.call_args_list)
        )

    def test_borrowed_call_matrix_rejects_owner_scaled_rewrite_work(self) -> None:
        def point(
            owner_count,
            node_visits,
            member_visits,
            *,
            fallback_requests=0,
            baseline_node_visits=None,
        ):
            return {
                "functions": 2,
                "params_per_function": owner_count,
                "comparison_kind": "compiler-worker",
                "work_counters": {
                    "borrowed_call_node_visits": node_visits,
                    "borrowed_call_alias_fallback_requests": fallback_requests,
                    "borrowed_call_rewrite_actions": 2,
                    "borrowed_origin_member_visits": member_visits,
                    "borrowed_origin_storage_slots": 0,
                    "borrowed_call_owner_catalog_slots": 2 * owner_count,
                },
                "baseline_work_counters": {
                    "borrowed_call_node_visits": (
                        baseline_node_visits
                        if baseline_node_visits is not None
                        else node_visits * owner_count
                    ),
                },
            }

        valid = [point(1, 256, 2), point(8, 256, 2), point(32, 256, 2)]
        self.benchmark.validate_borrowed_call_matrix(valid)

        invalid = [point(1, 256, 2), point(8, 2048, 16), point(32, 8192, 64)]
        with self.assertRaisesRegex(RuntimeError, "scales with owner count"):
            self.benchmark.validate_borrowed_call_matrix(invalid)

        fallbacks = [
            point(1, 256, 2, fallback_requests=1),
            point(8, 256, 2, fallback_requests=1),
            point(32, 256, 2, fallback_requests=1),
        ]
        with self.assertRaisesRegex(RuntimeError, "scalar alias fallback"):
            self.benchmark.validate_borrowed_call_matrix(fallbacks)

        insufficient_reduction = [
            point(1, 256, 2, baseline_node_visits=256),
            point(8, 256, 2, baseline_node_visits=512),
            point(32, 256, 2, baseline_node_visits=1000),
        ]
        with self.assertRaisesRegex(RuntimeError, "at least 75%"):
            self.benchmark.validate_borrowed_call_matrix(insufficient_reduction)

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

    def test_paired_end_to_end_mode_does_not_require_counter_worker(self) -> None:
        with mock.patch.object(
            self.benchmark,
            "run_benchmark",
            return_value=0,
        ) as run:
            exit_code = self.benchmark.main([
                "--end-to-end",
                "--baseline-bridge",
                "/tmp/baseline-worker",
                "--samples",
                "7",
                "--globals",
                "1",
                "--global-reads-per-function",
                "0",
            ])

        self.assertEqual(exit_code, 0)
        run.assert_called_once()

    def test_contract_matrix_varies_one_primary_axis_at_a_time(self) -> None:
        args = argparse.Namespace(
            bridge=None,
            counter_bridge=None,
            baseline_bridge=None,
            globals=1,
            functions=2,
            body_leaves=64,
            global_reads_per_function=0,
            params_per_function=1,
            parameter_type="String",
            body_shape="linear",
            user_call_edges=1,
            end_to_end=False,
            work_counters=False,
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
            self.benchmark.run_contract_matrix(args)

        prepare.assert_called_once()
        points = [
            (
                call.args[0].primary_axis,
                call.args[0].params_per_function,
                call.args[0].body_leaves,
                call.args[0].user_call_edges,
                call.args[0].functions,
                call.args[0].body_shape,
            )
            for call in run.call_args_list
        ]
        self.assertEqual(
            points,
            [
                ("borrowed_owners", 1, 644, 1, 8, "nested_user_call"),
                ("borrowed_owners", 8, 644, 1, 8, "nested_user_call"),
                ("borrowed_owners", 32, 644, 1, 8, "nested_user_call"),
                ("borrowed_owners", 128, 644, 1, 8, "nested_user_call"),
                ("body_nodes", 1, 32, 1, 8, "nested_user_call"),
                ("body_nodes", 1, 128, 1, 8, "nested_user_call"),
                ("body_nodes", 1, 512, 1, 8, "nested_user_call"),
                ("user_call_edges", 8, 512, 1, 33, "mutually_recursive_calls"),
                ("user_call_edges", 8, 512, 8, 33, "mutually_recursive_calls"),
                ("user_call_edges", 8, 512, 32, 33, "mutually_recursive_calls"),
            ],
        )

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

    def test_paired_window_summary_retains_per_pair_ratios(self) -> None:
        summary = self.benchmark.summarize_paired_window_metric(
            "window_allocations",
            [
                {"window_allocations": 100},
                {"window_allocations": 200},
                {"window_allocations": 400},
            ],
            [
                {"window_allocations": 50},
                {"window_allocations": 150},
                {"window_allocations": 200},
            ],
        )

        self.assertEqual(summary["baseline_window_allocations"], 200)
        self.assertEqual(
            summary["paired_window_allocations_ratios"],
            [0.5, 0.75, 0.5],
        )
        self.assertEqual(summary["paired_window_allocations_ratio_median"], 0.5)

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
