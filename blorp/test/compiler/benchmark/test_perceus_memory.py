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
            "blorp_CancelCleanupFrame cleanup; "
            "BLORP_TASK_CLEANUP_SCOPE(cleanup); "
            "blorp_retain(x); blorp_release(x); blorp_release_arc_only(y); "
            "blorp_task_cleanup_push(a); blorp_task_cleanup_pop_slot(b); "
            "blorp_task_cleanup_duplicate_slot(c); "
            "blorp_stack_result_retain(d); blorp_stack_result_retain_value(e); "
            "blorp_stack_result_release(f); "
            'const char *s = "blorp_retain(fake)"; '
            "// blorp_release(fake)\n/* blorp_task_cleanup_push(fake) */"
        )

        self.assertEqual(census, {
            "cleanup_frame_declarations": 1,
            "cleanup_scope_guards": 1,
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

    def test_profile_counter_parser_accepts_legacy_baseline_schema(self) -> None:
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
            require_candidate_schema=False,
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
            mixed_function_catalog = body_shape == "mixed_function_owner_catalog"
            _, program = self.benchmark.fixture_request(
                8 if mixed_function_catalog else 4,
                3,
                1536 if mixed_function_catalog else 256,
                8 if mixed_function_catalog else 2,
                params_per_function=32 if mixed_function_catalog else 2,
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

    def test_aggregate_escape_is_a_supported_body_shape(self) -> None:
        self.assertIn("aggregate_escape", self.benchmark.BODY_SHAPES)

    def test_borrowed_return_is_a_supported_body_shape(self) -> None:
        self.assertIn("borrowed_return", self.benchmark.BODY_SHAPES)

    def test_referenced_global_boundary_is_a_supported_body_shape(self) -> None:
        self.assertIn("referenced_global_boundary", self.benchmark.BODY_SHAPES)

    def test_mixed_function_owner_catalog_is_a_supported_body_shape(self) -> None:
        self.assertIn("mixed_function_owner_catalog", self.benchmark.BODY_SHAPES)

    def test_mixed_function_owner_fixture_has_fixed_geometry(self) -> None:
        _, program = self.benchmark.fixture_request(
            8,
            2,
            1536,
            8,
            params_per_function=32,
            body_shape="mixed_function_owner_catalog",
            invoke_workers=False,
        )
        workers = [
            declaration
            for declaration in program["decls"]
            if declaration.get("kind") == "function"
            and declaration.get("name", "").startswith("bench_worker_")
        ]

        self.assertEqual(len(workers), 2)
        for worker in workers:
            self.assertEqual(len(worker["params"]), 32)
            self.assertEqual(
                self.benchmark.expression_node_count(worker["body"]),
                1536,
            )
            self.assertEqual(
                self.benchmark.mixed_function_owner_census(worker["body"]),
                {
                    "consuming_calls": 32,
                    "aggregate_transfers": 32,
                    "result_terminals": 32,
                    "parameter_reference_sites": 72,
                    "global_reference_sites": 24,
                    "distinct_parameters": 24,
                    "distinct_globals": 8,
                    "nested_lambdas": 0,
                },
            )

    def test_referenced_global_fixture_has_fixed_nodes_and_boundary_sites(self) -> None:
        _, program = self.benchmark.fixture_request(
            384,
            2,
            256,
            8,
            params_per_function=0,
            body_shape="referenced_global_boundary",
            invoke_workers=False,
        )
        worker = next(
            declaration
            for declaration in program["decls"]
            if declaration.get("name") == "bench_worker_0000"
        )

        self.assertEqual(self.benchmark.expression_node_count(worker["body"]), 256)
        self.assertEqual(worker["return_type"], self.benchmark.named_type("String"))
        self.assertEqual(worker["params"], [])
        self.assertEqual(
            self.benchmark.referenced_global_boundary_census(worker["body"]),
            {
                "consuming_calls": 12,
                "aggregate_transfers": 12,
                "result_terminals": 8,
                "reference_sites": 32,
                "distinct_global_indices": 8,
            },
        )

    def test_borrowed_return_fixture_has_fixed_nodes_and_result_terminals(self) -> None:
        _, program = self.benchmark.fixture_request(
            1,
            2,
            256,
            0,
            params_per_function=8,
            body_shape="borrowed_return",
            invoke_workers=False,
        )
        worker = next(
            declaration
            for declaration in program["decls"]
            if declaration.get("name") == "bench_worker_0000"
        )

        self.assertEqual(self.benchmark.expression_node_count(worker["body"]), 256)
        self.assertEqual(worker["return_type"], self.benchmark.named_type("String"))
        self.assertEqual(
            self.benchmark.count_parameter_reads(
                worker["body"],
                "BENCH_BORROWED_PARAM_0000_0000",
            ),
            self.benchmark.RESULT_ALIAS_TERMINALS_PER_FUNCTION,
        )
        self.assertEqual(
            self.benchmark.count_parameter_reads(
                worker["body"],
                "BENCH_BORROWED_PARAM_0000_0007",
            ),
            0,
        )

    def test_aggregate_escape_fixture_has_fixed_nodes_and_real_escape_sites(self) -> None:
        _, program = self.benchmark.fixture_request(
            1,
            2,
            128,
            0,
            params_per_function=8,
            body_shape="aggregate_escape",
            invoke_workers=False,
        )
        worker = next(
            declaration
            for declaration in program["decls"]
            if declaration.get("name") == "bench_worker_0000"
        )

        self.assertEqual(self.benchmark.expression_node_count(worker["body"]), 128)
        self.assertEqual(
            self.benchmark.count_parameter_reads(
                worker["body"],
                "BENCH_BORROWED_PARAM_0000_0000",
            ),
            self.benchmark.AGGREGATE_ESCAPE_SITES_PER_FUNCTION,
        )
        self.assertEqual(
            self.benchmark.count_parameter_reads(
                worker["body"],
                "BENCH_BORROWED_PARAM_0000_0007",
            ),
            0,
        )

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

    def test_aggregate_matrix_rejects_owner_scaled_rewrite_work(self) -> None:
        def point(
            owner_count,
            node_visits,
            member_visits,
            *,
            fallback_requests=0,
            rewrite_actions=None,
            baseline_node_visits=None,
        ):
            return {
                "functions": 2,
                "params_per_function": owner_count,
                "comparison_kind": "compiler-worker",
                "work_counters": {
                    "borrowed_aggregate_node_visits": node_visits,
                    "borrowed_aggregate_owner_candidate_visits": member_visits,
                    "borrowed_aggregate_alias_fallback_requests": fallback_requests,
                    "borrowed_aggregate_rewrite_actions": (
                        rewrite_actions
                        if rewrite_actions is not None
                        else 2 * self.benchmark.AGGREGATE_ESCAPE_SITES_PER_FUNCTION
                    ),
                    "borrowed_origin_member_visits": member_visits,
                    "borrowed_origin_storage_slots": 0,
                },
                "baseline_work_counters": {
                    "borrowed_aggregate_node_visits": (
                        baseline_node_visits
                        if baseline_node_visits is not None
                        else node_visits * owner_count
                    ),
                },
            }

        valid = [point(1, 256, 32), point(8, 256, 32), point(32, 256, 32)]
        self.benchmark.validate_borrowed_aggregate_matrix(valid)

        invalid = [point(1, 256, 32), point(8, 2048, 256), point(32, 8192, 1024)]
        with self.assertRaisesRegex(RuntimeError, "scales with owner count"):
            self.benchmark.validate_borrowed_aggregate_matrix(invalid)

        fallbacks = [
            point(1, 256, 32, fallback_requests=1),
            point(8, 256, 32, fallback_requests=1),
            point(32, 256, 32, fallback_requests=1),
        ]
        with self.assertRaisesRegex(RuntimeError, "scalar alias fallback"):
            self.benchmark.validate_borrowed_aggregate_matrix(fallbacks)

        wrong_rewrites = [
            point(1, 256, 32, rewrite_actions=1),
            point(8, 256, 32, rewrite_actions=1),
            point(32, 256, 32, rewrite_actions=1),
        ]
        with self.assertRaisesRegex(RuntimeError, "escaping values"):
            self.benchmark.validate_borrowed_aggregate_matrix(wrong_rewrites)

        insufficient_reduction = [
            point(1, 256, 32, baseline_node_visits=256),
            point(8, 256, 32, baseline_node_visits=512),
            point(32, 256, 32, baseline_node_visits=1000),
        ]
        with self.assertRaisesRegex(RuntimeError, "at least 75%"):
            self.benchmark.validate_borrowed_aggregate_matrix(insufficient_reduction)

    def test_aggregate_matrix_reuses_workers_and_varies_only_owner_count(self) -> None:
        args = argparse.Namespace(
            bridge=None,
            counter_bridge=None,
            globals=1,
            functions=2,
            body_leaves=128,
            global_reads_per_function=0,
            params_per_function=1,
            parameter_type="String",
            body_shape="linear",
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
            self.benchmark.run_aggregate_matrix(args)

        prepare.assert_called_once()
        points = [
            (
                call.args[0].params_per_function,
                call.args[0].functions,
                call.args[0].body_leaves,
                call.args[0].body_shape,
                call.args[0].invoke_workers,
            )
            for call in run.call_args_list
        ]
        self.assertEqual(points, [
            (1, 2, 128, "aggregate_escape", False),
            (8, 2, 128, "aggregate_escape", False),
            (32, 2, 128, "aggregate_escape", False),
        ])

    def test_result_matrix_rejects_owner_scaled_rewrite_work(self) -> None:
        def point(
            owner_count,
            node_visits,
            candidate_visits,
            *,
            fallback_requests=0,
            rewrite_actions=None,
            baseline_node_visits=None,
        ):
            return {
                "functions": 2,
                "params_per_function": owner_count,
                "comparison_kind": "compiler-worker",
                "paired_window_elapsed_microseconds_ratio_median": 0.80,
                "paired_window_allocations_ratio_median": 0.70,
                "paired_window_releases_ratio_median": 1.0,
                "work_counters": {
                    "borrowed_result_node_visits": node_visits,
                    "borrowed_result_owner_candidate_visits": candidate_visits,
                    "borrowed_result_alias_fallback_requests": fallback_requests,
                    "borrowed_result_rewrite_actions": (
                        rewrite_actions
                        if rewrite_actions is not None
                        else 2 * self.benchmark.RESULT_ALIAS_TERMINALS_PER_FUNCTION
                    ),
                    "borrowed_origin_member_visits": candidate_visits,
                    "borrowed_origin_storage_slots": 0,
                },
                "baseline_work_counters": {
                    "borrowed_result_node_visits": (
                        baseline_node_visits
                        if baseline_node_visits is not None
                        else node_visits * owner_count
                    ),
                },
            }

        valid = [point(1, 130, 64), point(8, 130, 64), point(32, 130, 64)]
        self.benchmark.validate_borrowed_result_matrix(valid)

        scaled = [point(1, 256, 64), point(8, 2048, 512), point(32, 8192, 2048)]
        with self.assertRaisesRegex(RuntimeError, "scales with owner count"):
            self.benchmark.validate_borrowed_result_matrix(scaled)

        fallbacks = [
            point(1, 130, 64, fallback_requests=1),
            point(8, 130, 64, fallback_requests=1),
            point(32, 130, 64, fallback_requests=1),
        ]
        with self.assertRaisesRegex(RuntimeError, "scalar alias fallback"):
            self.benchmark.validate_borrowed_result_matrix(fallbacks)

        wrong_rewrites = [
            point(1, 130, 64, rewrite_actions=1),
            point(8, 130, 64, rewrite_actions=1),
            point(32, 130, 64, rewrite_actions=1),
        ]
        with self.assertRaisesRegex(RuntimeError, "result terminals"):
            self.benchmark.validate_borrowed_result_matrix(wrong_rewrites)

        insufficient_reduction = [
            point(1, 130, 64, baseline_node_visits=130),
            point(8, 130, 64, baseline_node_visits=260),
            point(32, 130, 64, baseline_node_visits=500),
        ]
        with self.assertRaisesRegex(RuntimeError, "at least 75%"):
            self.benchmark.validate_borrowed_result_matrix(insufficient_reduction)

    def test_result_matrix_reuses_workers_and_varies_only_owner_count(self) -> None:
        args = argparse.Namespace(
            bridge=None,
            counter_bridge=None,
            globals=1,
            functions=2,
            body_leaves=256,
            global_reads_per_function=0,
            params_per_function=1,
            parameter_type="String",
            body_shape="linear",
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
            self.benchmark.run_result_matrix(args)

        prepare.assert_called_once()
        points = [
            (
                call.args[0].params_per_function,
                call.args[0].functions,
                call.args[0].body_leaves,
                call.args[0].body_shape,
                call.args[0].invoke_workers,
                call.args[0].measurement_window,
            )
            for call in run.call_args_list
        ]
        self.assertEqual(points, [
            (1, 2, 256, "borrowed_return", False, "perceus-direct"),
            (8, 2, 256, "borrowed_return", False, "perceus-direct"),
            (32, 2, 256, "borrowed_return", False, "perceus-direct"),
        ])

    def test_referenced_global_matrix_rejects_owner_scaled_rewrite_work(self) -> None:
        def point(
            referenced_globals,
            normalization_visits,
            *,
            fallback_requests=0,
            rewrite_actions=64,
            baseline_visits=None,
        ):
            return {
                "globals": 384,
                "functions": 2,
                "global_reads_per_function": referenced_globals,
                "comparison_kind": "compiler-worker",
                "paired_window_elapsed_microseconds_ratio_median": 0.80,
                "paired_window_allocations_ratio_median": 0.70,
                "paired_window_releases_ratio_median": 1.0,
                "work_counters": {
                    "referenced_global_discovery_node_visits": 512,
                    "referenced_global_read_candidates": 2 * referenced_globals,
                    "referenced_global_exact_matches": 2 * referenced_globals,
                    "borrowed_global_catalog_slots": 2 * referenced_globals,
                    "borrowed_global_normalization_visits": normalization_visits,
                    "borrowed_global_alias_fallback_requests": fallback_requests,
                    "borrowed_global_rewrite_actions": rewrite_actions,
                },
                "baseline_work_counters": {
                    "borrowed_global_normalization_visits": (
                        baseline_visits
                        if baseline_visits is not None
                        else normalization_visits * referenced_globals
                    ),
                },
            }

        valid = [point(1, 600), point(8, 600), point(32, 600)]
        self.benchmark.validate_referenced_global_matrix(valid)

        scaled = [point(1, 600), point(8, 4800), point(32, 19200)]
        with self.assertRaisesRegex(RuntimeError, "scales with referenced globals"):
            self.benchmark.validate_referenced_global_matrix(scaled)

        fallbacks = [
            point(1, 600, fallback_requests=1),
            point(8, 600, fallback_requests=1),
            point(32, 600, fallback_requests=1),
        ]
        with self.assertRaisesRegex(RuntimeError, "scalar alias fallback"):
            self.benchmark.validate_referenced_global_matrix(fallbacks)

        wrong_rewrites = [
            point(1, 600, rewrite_actions=1),
            point(8, 600, rewrite_actions=1),
            point(32, 600, rewrite_actions=1),
        ]
        with self.assertRaisesRegex(RuntimeError, "boundary sites"):
            self.benchmark.validate_referenced_global_matrix(wrong_rewrites)

        insufficient_reduction = [
            point(1, 600, baseline_visits=600),
            point(8, 600, baseline_visits=1200),
            point(32, 600, baseline_visits=2000),
        ]
        with self.assertRaisesRegex(RuntimeError, "at least 75%"):
            self.benchmark.validate_referenced_global_matrix(insufficient_reduction)

    def test_lambda_boundary_fixture_has_fixed_outer_region_geometry(self) -> None:
        for owner_count in (1, 8, 32):
            _, program = self.benchmark.fixture_request(
                1,
                2,
                256,
                0,
                params_per_function=owner_count,
                body_shape="lambda_borrowed_boundary",
                invoke_workers=False,
            )
            workers = [
                declaration
                for declaration in program["decls"]
                if declaration.get("kind") == "function"
                and declaration.get("name", "").startswith("bench_worker_")
            ]
            self.assertEqual(len(workers), 2)
            for worker in workers:
                outer_lambda = worker["body"]["body"]
                self.assertEqual(len(outer_lambda["params"]), owner_count)
                self.assertEqual(
                    self.benchmark.expression_node_count(outer_lambda["body"]),
                    256,
                )
                self.assertEqual(
                    self.benchmark.lambda_boundary_census(outer_lambda["body"]),
                    {
                        "consuming_calls": 12,
                        "aggregate_transfers": 12,
                        "result_terminals": 12,
                        "owner_reads": 36,
                        "distinct_owners": owner_count,
                        "nested_lambdas": 1,
                    },
                )

    def test_lambda_baseline_matrix_requires_exact_regions_and_owner_slots(self) -> None:
        def point(owner_count, visits, *, regions=4):
            slots = 2 * owner_count + 2
            return {
                "params_per_function": owner_count,
                "work_counters": {
                    "lambda_regions_normalized": regions,
                    "lambda_parameter_owner_slots": slots,
                    "lambda_capture_owner_slots": 0,
                    "lambda_referenced_global_owner_slots": 0,
                    "lambda_scalar_owner_normalizations": slots,
                    "lambda_borrowed_normalization_visits": visits,
                },
            }

        self.benchmark.validate_lambda_owner_baseline_matrix([
            point(1, 100),
            point(8, 800),
            point(32, 3200),
        ])

        with self.assertRaisesRegex(RuntimeError, "lambda_regions_normalized"):
            self.benchmark.validate_lambda_owner_baseline_matrix([
                point(1, 100, regions=3),
                point(8, 800),
                point(32, 3200),
            ])

        with self.assertRaisesRegex(RuntimeError, "must scale with owner count"):
            self.benchmark.validate_lambda_owner_baseline_matrix([
                point(1, 100),
                point(8, 100),
                point(32, 100),
            ])

    def test_lambda_catalog_matrix_rejects_owner_scaled_or_scalar_work(self) -> None:
        def point(
            owner_count,
            visits,
            *,
            scalar_normalizations=0,
            fallback_requests=0,
            baseline_visits=None,
        ):
            slots = 2 * owner_count + 2
            return {
                "params_per_function": owner_count,
                "comparison_kind": "compiler-worker",
                "paired_window_elapsed_microseconds_ratio_median": 0.80,
                "paired_window_allocations_ratio_median": 0.70,
                "paired_window_releases_ratio_median": 1.0,
                "work_counters": {
                    "lambda_regions_normalized": 4,
                    "lambda_parameter_owner_slots": slots,
                    "lambda_capture_owner_slots": 0,
                    "lambda_referenced_global_owner_slots": 0,
                    "lambda_scalar_owner_normalizations": scalar_normalizations,
                    "lambda_borrowed_normalization_visits": visits,
                    "lambda_alias_fallback_requests": fallback_requests,
                    "lambda_rewrite_actions": 74,
                    "borrowed_call_rewrite_actions": 24,
                    "borrowed_aggregate_rewrite_actions": 24,
                    "borrowed_result_rewrite_actions": 26,
                },
                "baseline_work_counters": {
                    "lambda_borrowed_normalization_visits": (
                        baseline_visits
                        if baseline_visits is not None
                        else visits * owner_count
                    ),
                },
            }

        valid = [point(1, 1072), point(8, 1072), point(32, 1072)]
        self.benchmark.validate_lambda_owner_catalog_matrix(valid)

        scaled = [point(1, 1072), point(8, 8576), point(32, 34304)]
        with self.assertRaisesRegex(RuntimeError, "visits changed or scale"):
            self.benchmark.validate_lambda_owner_catalog_matrix(scaled)

        scalar = [
            point(1, 1072, scalar_normalizations=4),
            point(8, 1072, scalar_normalizations=18),
            point(32, 1072, scalar_normalizations=66),
        ]
        with self.assertRaisesRegex(RuntimeError, "scalar owner normalization"):
            self.benchmark.validate_lambda_owner_catalog_matrix(scalar)

        fallback = [
            point(1, 1072, fallback_requests=1),
            point(8, 1072, fallback_requests=1),
            point(32, 1072, fallback_requests=1),
        ]
        with self.assertRaisesRegex(RuntimeError, "scalar alias fallback"):
            self.benchmark.validate_lambda_owner_catalog_matrix(fallback)

        insufficient_reduction = [
            point(1, 1072, baseline_visits=1072),
            point(8, 1072, baseline_visits=2144),
            point(32, 1072, baseline_visits=4000),
        ]
        with self.assertRaisesRegex(RuntimeError, "at least 75%"):
            self.benchmark.validate_lambda_owner_catalog_matrix(insufficient_reduction)

        missing_aggregate_actions = [point(1, 1072), point(8, 1072), point(32, 1072)]
        for matrix_point in missing_aggregate_actions:
            matrix_point["work_counters"]["borrowed_aggregate_rewrite_actions"] = 0
            matrix_point["work_counters"]["lambda_rewrite_actions"] = 50
        with self.assertRaisesRegex(RuntimeError, "borrowed_aggregate_rewrite_actions"):
            self.benchmark.validate_lambda_owner_catalog_matrix(
                missing_aggregate_actions
            )

        slow_one_owner = [point(1, 1072), point(8, 1072), point(32, 1072)]
        slow_one_owner[0]["paired_window_elapsed_microseconds_ratio_median"] = 1.06
        with self.assertRaisesRegex(RuntimeError, "one-owner direct timing"):
            self.benchmark.validate_lambda_owner_catalog_matrix(slow_one_owner)

    def test_lambda_owner_matrix_reuses_workers_and_isolates_lambda_parameters(self) -> None:
        args = argparse.Namespace(
            bridge=None,
            counter_bridge=None,
            baseline_bridge=None,
            globals=1,
            functions=2,
            body_leaves=256,
            global_reads_per_function=0,
            params_per_function=1,
            parameter_type="String",
            body_shape="linear",
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
            self.benchmark.run_lambda_owner_matrix(args)

        prepare.assert_called_once()
        points = [
            (
                call.args[0].params_per_function,
                call.args[0].functions,
                call.args[0].body_leaves,
                call.args[0].body_shape,
                call.args[0].invoke_workers,
                call.args[0].measurement_window,
            )
            for call in run.call_args_list
        ]
        self.assertEqual(points, [
            (1, 2, 256, "lambda_borrowed_boundary", False, "perceus-direct"),
            (8, 2, 256, "lambda_borrowed_boundary", False, "perceus-direct"),
            (32, 2, 256, "lambda_borrowed_boundary", False, "perceus-direct"),
        ])

    def test_mixed_function_owner_matrix_reuses_workers(self) -> None:
        args = argparse.Namespace(
            bridge=None,
            counter_bridge=None,
            baseline_bridge="/tmp/perceus-baseline-worker",
            baseline_counter_bridge="/tmp/perceus-baseline-counter-worker",
            globals=1,
            functions=2,
            body_leaves=64,
            global_reads_per_function=0,
            params_per_function=0,
            parameter_type="String",
            body_shape="linear",
            end_to_end=False,
            work_counters=False,
        )

        with mock.patch.object(
            self.benchmark,
            "prepare_backend_worker",
            side_effect=lambda _root, _directory, explicit, **_kwargs: Path(
                explicit or "/tmp/perceus-worker"
            ),
        ) as prepare, mock.patch.object(
            self.benchmark,
            "run_benchmark",
            return_value=0,
        ) as run:
            self.benchmark.run_mixed_function_owner_catalog_matrix(args)

        self.assertEqual(prepare.call_count, 1)
        points = [
            (
                call.args[0].params_per_function,
                call.args[0].global_reads_per_function,
                call.args[0].globals,
                call.args[0].functions,
                call.args[0].body_leaves,
                call.args[0].body_shape,
                call.args[0].invoke_workers,
                call.args[0].measurement_window,
            )
            for call in run.call_args_list
        ]
        self.assertEqual(points, [
            (1, 1, 1, 2, 1536, "mixed_function_owner_catalog", False, "perceus-direct"),
            (32, 8, 8, 2, 1536, "mixed_function_owner_catalog", False, "perceus-direct"),
        ])

    def test_mixed_function_owner_matrix_requires_combined_catalog_gain(self) -> None:
        def point(
            params,
            globals_count,
            visits,
            baseline_visits,
            *,
            time_ratio,
            allocation_ratio,
            release_ratio,
            fallback_requests=0,
        ):
            return {
                "params_per_function": params,
                "global_reads_per_function": globals_count,
                "globals": globals_count,
                "functions": 2,
                "comparison_kind": "compiler-worker",
                "paired_window_elapsed_microseconds_ratio_median": time_ratio,
                "paired_window_allocations_ratio_median": allocation_ratio,
                "paired_window_releases_ratio_median": release_ratio,
                "work_counters": {
                    "borrowed_call_owner_catalog_slots": 2 * params,
                    "borrowed_global_catalog_slots": 2 * globals_count,
                    "borrowed_call_alias_fallback_requests": fallback_requests,
                    "borrowed_aggregate_alias_fallback_requests": 0,
                    "borrowed_result_alias_fallback_requests": 0,
                    "borrowed_call_rewrite_actions": 64,
                    "borrowed_aggregate_rewrite_actions": 64,
                    "borrowed_result_rewrite_actions": 64,
                    "mixed_function_normalization_visits": visits,
                },
                "baseline_work_counters": {
                    "mixed_function_normalization_visits": baseline_visits,
                },
            }

        valid = [
            point(1, 1, 1200, 2400, time_ratio=1.03, allocation_ratio=1.01, release_ratio=1.01),
            point(32, 8, 1200, 2400, time_ratio=0.90, allocation_ratio=0.85, release_ratio=0.85),
        ]
        self.benchmark.validate_mixed_function_owner_catalog_matrix(valid)

        insufficient_visits = [
            {
                **point_value,
                "work_counters": {
                    **point_value["work_counters"],
                    "mixed_function_normalization_visits": 1500,
                },
            }
            for point_value in valid
        ]
        with self.assertRaisesRegex(RuntimeError, "at least 40%"):
            self.benchmark.validate_mixed_function_owner_catalog_matrix(insufficient_visits)

        insufficient_allocations = [valid[0], {
            **valid[1],
            "paired_window_allocations_ratio_median": 0.96,
        }]
        with self.assertRaisesRegex(RuntimeError, "at least 5%"):
            self.benchmark.validate_mixed_function_owner_catalog_matrix(
                insufficient_allocations
            )

        fallback = [valid[0], {
            **valid[1],
            "work_counters": {
                **valid[1]["work_counters"],
                "borrowed_call_alias_fallback_requests": 1,
            },
        }]
        with self.assertRaisesRegex(RuntimeError, "scalar alias fallback"):
            self.benchmark.validate_mixed_function_owner_catalog_matrix(fallback)

    def test_referenced_global_visit_counter_composes_operation_work(self) -> None:
        operation_counters = {
            "borrowed_call_node_visits": 10,
            "borrowed_aggregate_node_visits": 20,
            "borrowed_result_node_visits": 30,
        }
        baseline = self.benchmark.add_referenced_global_derived_counters({
            **operation_counters,
            "borrowed_global_normalization_visits": 0,
        })
        candidate = self.benchmark.add_referenced_global_derived_counters({
            **operation_counters,
            "borrowed_global_normalization_visits": 40,
        })

        self.assertEqual(baseline["borrowed_global_normalization_visits"], 60)
        self.assertEqual(candidate["borrowed_global_normalization_visits"], 60)

    def test_referenced_global_matrix_reuses_workers_and_varies_only_global_count(self) -> None:
        args = argparse.Namespace(
            bridge=None,
            counter_bridge=None,
            baseline_bridge="/tmp/perceus-baseline-worker",
            baseline_counter_bridge="/tmp/perceus-baseline-counter-worker",
            globals=384,
            functions=2,
            body_leaves=256,
            global_reads_per_function=1,
            params_per_function=0,
            parameter_type="String",
            body_shape="linear",
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
            self.benchmark.run_referenced_global_matrix(args)

        prepare.assert_called_once()
        points = [
            (
                call.args[0].globals,
                call.args[0].global_reads_per_function,
                call.args[0].functions,
                call.args[0].body_leaves,
                call.args[0].params_per_function,
                call.args[0].body_shape,
                call.args[0].invoke_workers,
                call.args[0].measurement_window,
            )
            for call in run.call_args_list
        ]
        self.assertEqual(points, [
            (384, 1, 2, 256, 0, "referenced_global_boundary", False, "perceus-direct"),
            (384, 8, 2, 256, 0, "referenced_global_boundary", False, "perceus-direct"),
            (384, 32, 2, 256, 0, "referenced_global_boundary", False, "perceus-direct"),
        ])

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

    def test_aggregate_matrix_dispatches_without_single_fixture_limits(self) -> None:
        with mock.patch.object(
            self.benchmark,
            "run_aggregate_matrix",
            return_value=0,
        ) as run:
            exit_code = self.benchmark.main([
                "--aggregate-matrix",
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
