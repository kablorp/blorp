#!/usr/bin/env python3
"""Contract tests for benchmarks/compiler_typecheck_memory."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / "benchmarks" / "compiler_typecheck_memory"
COMPILER_ENV_SOURCE = ROOT / "blorp" / "src" / "compiler" / "stage_05_types" / "env.brp"
TYPECHECK_DECL_SOURCE = (
    ROOT
    / "blorp"
    / "src"
    / "compiler"
    / "stage_06_typecheck"
    / "decl.brp"
)
TYPE_DECL_ANALYSIS_SOURCE = (
    ROOT
    / "blorp"
    / "src"
    / "compiler"
    / "stage_06_typecheck"
    / "headers"
    / "type_decl_analysis.brp"
)


def load_benchmark_module():
    loader = importlib.machinery.SourceFileLoader(
        "compiler_typecheck_memory_benchmark",
        str(SCRIPT),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create benchmark module spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def fake_bridge_source(
    mutate_request: bool = False,
    artifact_marker: int | None = None,
) -> str:
    mutation = ""
    if mutate_request:
        mutation = """
with open(sys.argv[1], "a", encoding="utf-8") as request_file:
    request_file.write(" ")
"""
    typed_program = (
        "{}"
        if artifact_marker is None
        else json.dumps({"marker": artifact_marker}, separators=(",", ":"))
    )
    return f"""#!/usr/bin/env python3
import json
import sys

with open(sys.argv[1], encoding="utf-8") as request_file:
    request = json.load(request_file)
{mutation}
payload = request["payload"]
for module in [*payload["modules"], payload["target"]]:
    print(json.dumps({{
        "ok": True,
        "artifact": {{
            "module": module["module"],
            "typed_program": {typed_program},
            "type_errors": [],
        }},
    }}))
"""


def top_level_function_source(path: Path, function_name: str) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    marker = f"func {function_name}("
    start = next(
        index
        for index, line in enumerate(lines)
        if marker in line and not line.startswith(("\t", " "))
    )
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line and not line.startswith(("\t", " ", "--")):
            end = index
            break
    return "\n".join(lines[start:end])


class CompilerTypecheckMemoryBenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.benchmark = load_benchmark_module()

    def test_fixture_varies_modules_types_and_probes_independently(self) -> None:
        request, fixture = self.benchmark.fixture_request(
            module_count=2,
            type_depth=3,
            probes_per_module=4,
            primitive_probes_per_module=2,
            primitive_storage_probes_per_module=3,
            resource_scan_depth=2,
            resource_scan_probes_per_module=3,
            self_resolution_depth=2,
            self_resolution_probes_per_module=2,
            type_instantiation_depth=2,
            type_instantiation_probes_per_module=2,
        )

        self.assertEqual(request["action"], "typecheck_graph")
        self.assertEqual(len(request["payload"]["modules"]), 2)
        self.assertEqual(
            request["payload"]["module_targets"],
            ["bench/typecheck_0000", "bench/typecheck_0001"],
        )
        self.assertEqual(
            fixture["artifact_order"],
            ["bench/typecheck_0000", "bench/typecheck_0001", "bench/target"],
        )
        self.assertEqual(fixture["source_declarations"], 41)

        first_source = request["payload"]["modules"][0]["text"]
        self.assertIn("record BenchM0000Shape0002", first_source)
        self.assertIn(
            "copy: BenchM0000Shape0000 = value",
            first_source,
        )
        self.assertIn("pure func bench_m0000_probe_0003", first_source)
        self.assertIn(
            "copy: BenchM0000Shape0002 = value",
            first_source,
        )
        self.assertIn("pure func bench_m0000_primitive_0001", first_source)
        self.assertIn("copy: Int = value", first_source)
        self.assertIn("pure func bench_m0000_primitive_storage_0002", first_source)
        self.assertIn("(value: ..#3) -> (..#3, Int):", first_source)
        self.assertIn("\t(value, 0)", first_source)
        self.assertIn("pure func bench_m0000_resource_scan_0002", first_source)
        self.assertIn("(value: ((Int, Int), Int)) -> Int:", first_source)
        self.assertIn("trait BenchM0000SelfTrait:", first_source)
        self.assertIn(
            "pure func bench_m0000_self_0001(value: ((Self, Int), Int)) -> Int",
            first_source,
        )
        self.assertIn("record BenchM0000SelfConcrete[T] {value: T}", first_source)
        self.assertIn(
            "implements BenchM0000SelfTrait for "
            "BenchM0000SelfConcrete[((Int, Int), Int)]:",
            first_source,
        )
        self.assertIn(
            "pure func bench_m0000_self_0001"
            "(value: ((BenchM0000SelfConcrete[((Int, Int), Int)], Int), Int)) -> Int:",
            first_source,
        )
        self.assertIn(
            "pure func bench_m0000_instantiate_0001[T]"
            "(unchanged: ((Int, Int), Int), value: (((Int, Int), Int), T), "
            "all_changed: List[List[T]])"
            " -> (((Int, Int), Int), T):",
            first_source,
        )
        self.assertIn("\tvalue", first_source)

    def test_fixture_can_add_one_wide_union_per_module(self) -> None:
        request, fixture = self.benchmark.fixture_request(
            module_count=2,
            type_depth=1,
            probes_per_module=1,
            primitive_probes_per_module=0,
            primitive_storage_probes_per_module=0,
            resource_scan_depth=0,
            resource_scan_probes_per_module=0,
            self_resolution_depth=0,
            self_resolution_probes_per_module=0,
            type_instantiation_depth=0,
            type_instantiation_probes_per_module=0,
            union_variants_per_module=3,
        )

        self.assertEqual(fixture["source_declarations"], 7)
        source = request["payload"]["modules"][0]["text"]
        self.assertIn("union BenchM0000Choice:\n", source)
        self.assertIn("\tBenchM0000ChoiceVariant0000(Int)", source)
        self.assertIn("\tBenchM0000ChoiceVariant0001\n", source)
        self.assertIn("\tBenchM0000ChoiceVariant0002(Int)", source)

    def test_benchmark_result_emits_input_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            bridge_path = Path(temp_name) / "fake_typecheck_bridge"
            bridge_source = fake_bridge_source()
            bridge_path.write_text(bridge_source, encoding="utf-8")
            bridge_path.chmod(0o755)
            args = argparse.Namespace(
                modules=1,
                type_depth=1,
                probes_per_module=1,
                primitive_probes_per_module=0,
                primitive_storage_probes_per_module=0,
                resource_scan_depth=0,
                resource_scan_probes_per_module=0,
                self_resolution_depth=0,
                self_resolution_probes_per_module=0,
                type_instantiation_depth=0,
                type_instantiation_probes_per_module=0,
                bridge=str(bridge_path),
                baseline_bridge=None,
                vmmap=False,
                json=True,
                runs=2,
                warmup_runs=1,
            )
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                exit_code = self.benchmark.run_benchmark(args)

            request, _ = self.benchmark.fixture_request(
                1,
                1,
                1,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            )
            request_bytes = json.dumps(
                request,
                separators=(",", ":"),
            ).encode("utf-8")
            result = json.loads(output.getvalue())

        self.assertEqual(exit_code, 0)
        self.assertEqual(result["runs"], 2)
        self.assertEqual(result["warmup_runs"], 1)
        self.assertLessEqual(result["elapsed_min_seconds"], result["elapsed_seconds"])
        self.assertLessEqual(result["elapsed_seconds"], result["elapsed_max_seconds"])
        self.assertLessEqual(
            result["peak_rss_median_bytes"],
            result["peak_rss_bytes"],
        )
        self.assertEqual(
            result["bridge_sha256"],
            hashlib.sha256(bridge_source.encode("utf-8")).hexdigest(),
        )
        self.assertEqual(
            result["request_sha256"],
            hashlib.sha256(request_bytes).hexdigest(),
        )

    def test_benchmark_rejects_input_changed_during_measurement(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            bridge_path = Path(temp_name) / "mutating_typecheck_bridge"
            bridge_path.write_text(
                fake_bridge_source(mutate_request=True),
                encoding="utf-8",
            )
            bridge_path.chmod(0o755)
            args = argparse.Namespace(
                modules=1,
                type_depth=1,
                probes_per_module=1,
                primitive_probes_per_module=0,
                primitive_storage_probes_per_module=0,
                resource_scan_depth=0,
                resource_scan_probes_per_module=0,
                self_resolution_depth=0,
                self_resolution_probes_per_module=0,
                type_instantiation_depth=0,
                type_instantiation_probes_per_module=0,
                bridge=str(bridge_path),
                baseline_bridge=None,
                vmmap=False,
                json=True,
                runs=1,
                warmup_runs=0,
            )

            with self.assertRaisesRegex(RuntimeError, "request changed"):
                self.benchmark.run_benchmark(args)

    def test_benchmark_compares_bridges_with_paired_runs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            bridge_path = Path(temp_name) / "fake_typecheck_bridge"
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            args = argparse.Namespace(
                modules=1,
                type_depth=1,
                probes_per_module=1,
                primitive_probes_per_module=0,
                primitive_storage_probes_per_module=0,
                resource_scan_depth=0,
                resource_scan_probes_per_module=0,
                self_resolution_depth=0,
                self_resolution_probes_per_module=0,
                type_instantiation_depth=0,
                type_instantiation_probes_per_module=0,
                bridge=str(bridge_path),
                baseline_bridge=str(bridge_path),
                vmmap=False,
                json=True,
                runs=2,
                warmup_runs=2,
            )
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                exit_code = self.benchmark.run_benchmark(args)

            result = json.loads(output.getvalue())

        self.assertEqual(exit_code, 0)
        self.assertEqual(result["comparison_order"], "alternating")
        self.assertEqual(result["baseline_bridge_sha256"], result["bridge_sha256"])
        self.assertIn("baseline_elapsed_seconds", result)
        self.assertIn("elapsed_paired_change_percent", result)
        self.assertIn("baseline_peak_rss_median_bytes", result)
        self.assertIn("peak_rss_paired_change_percent", result)
        self.assertEqual(
            result["sample_execution_order"],
            ["candidate,baseline", "baseline,candidate"],
        )
        self.assertEqual(len(result["elapsed_samples_seconds"]), 2)
        self.assertEqual(len(result["baseline_elapsed_samples_seconds"]), 2)
        self.assertEqual(len(result["peak_rss_samples_bytes"]), 2)
        self.assertEqual(len(result["baseline_peak_rss_samples_bytes"]), 2)
        self.assertIn("platform", result)

    def test_benchmark_rejects_different_bridge_responses(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            candidate_path = Path(temp_name) / "candidate_typecheck_bridge"
            candidate_path.write_text(
                fake_bridge_source(artifact_marker=1),
                encoding="utf-8",
            )
            candidate_path.chmod(0o755)
            baseline_path = Path(temp_name) / "baseline_typecheck_bridge"
            baseline_path.write_text(
                fake_bridge_source(artifact_marker=2),
                encoding="utf-8",
            )
            baseline_path.chmod(0o755)
            args = argparse.Namespace(
                modules=1,
                type_depth=1,
                probes_per_module=1,
                primitive_probes_per_module=0,
                primitive_storage_probes_per_module=0,
                resource_scan_depth=0,
                resource_scan_probes_per_module=0,
                self_resolution_depth=0,
                self_resolution_probes_per_module=0,
                type_instantiation_depth=0,
                type_instantiation_probes_per_module=0,
                bridge=str(candidate_path),
                baseline_bridge=str(baseline_path),
                vmmap=False,
                json=True,
                runs=2,
                warmup_runs=0,
            )

            with self.assertRaisesRegex(RuntimeError, "response content varied"):
                self.benchmark.run_benchmark(args)

    def test_comparison_requires_balanced_sample_order(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            bridge_path = Path(temp_name) / "fake_typecheck_bridge"
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            args = argparse.Namespace(
                modules=1,
                type_depth=1,
                probes_per_module=1,
                primitive_probes_per_module=0,
                primitive_storage_probes_per_module=0,
                resource_scan_depth=0,
                resource_scan_probes_per_module=0,
                self_resolution_depth=0,
                self_resolution_probes_per_module=0,
                type_instantiation_depth=0,
                type_instantiation_probes_per_module=0,
                bridge=str(bridge_path),
                baseline_bridge=str(bridge_path),
                vmmap=False,
                json=True,
                runs=3,
                warmup_runs=0,
            )

            with self.assertRaisesRegex(RuntimeError, "even number of measured runs"):
                self.benchmark.run_benchmark(args)

            args.runs = 2
            args.warmup_runs = 1
            with self.assertRaisesRegex(RuntimeError, "even number of warmup runs"):
                self.benchmark.run_benchmark(args)

    def test_recursive_type_ownership_boundaries_do_not_deep_copy(self) -> None:
        resolve_self = top_level_function_source(
            COMPILER_ENV_SOURCE,
            "resolve_self",
        )
        resource_scan = top_level_function_source(
            TYPE_DECL_ANALYSIS_SOURCE,
            "resource_type_scan_contains",
        )
        resolve_impl = top_level_function_source(
            TYPECHECK_DECL_SOURCE,
            "resolve_impl_method_sig",
        )

        self.assertNotIn("compiler_type_copy(", resolve_self)
        self.assertNotIn("compiler_resource_type_scan_context_copy", resource_scan)
        self.assertNotIn("compiler_type_copy(", resolve_impl)
        self.assertNotIn(
            "compiler_resource_type_scan_context_copy",
            TYPE_DECL_ANALYSIS_SOURCE.read_text(encoding="utf-8"),
        )

    def test_streamed_response_validation_checks_every_artifact(self) -> None:
        expected = ["bench/typecheck_0000", "bench/typecheck_0001", "bench/target"]

        def response(module_name: str) -> str:
            return json.dumps(
                {
                    "ok": True,
                    "artifact": {
                        "path": f"/bench/{module_name}.brp",
                        "module": module_name,
                        "typed_program": {"decls": []},
                        "type_errors": [],
                    },
                }
            )

        with tempfile.TemporaryDirectory() as temp_name:
            response_path = Path(temp_name) / "response.jsonl"
            response_path.write_text(
                "\n".join(response(name) for name in expected) + "\n",
                encoding="utf-8",
            )

            artifact_count = self.benchmark.validate_response(response_path, expected)

        self.assertEqual(artifact_count, 3)

    def test_streamed_response_validation_rejects_type_errors(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            response_path = Path(temp_name) / "response.jsonl"
            response_path.write_text(
                json.dumps(
                    {
                        "ok": True,
                        "artifact": {
                            "path": "/bench/target.brp",
                            "module": "bench/target",
                            "typed_program": {"decls": []},
                            "type_errors": ["fixture failed"],
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(RuntimeError, "type errors"):
                self.benchmark.validate_response(response_path, ["bench/target"])


if __name__ == "__main__":
    unittest.main()
