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


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "benchmarks" / "compiler_typecheck_memory"


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


def fake_bridge_source(mutate_request: bool = False) -> str:
    mutation = ""
    if mutate_request:
        mutation = """
with open(sys.argv[1], "a", encoding="utf-8") as request_file:
    request_file.write(" ")
"""
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
            "typed_program": {{}},
            "type_errors": [],
        }},
    }}))
"""


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
        self.assertEqual(fixture["source_declarations"], 31)

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
                bridge=str(bridge_path),
                vmmap=False,
                json=True,
            )
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                exit_code = self.benchmark.run_benchmark(args)

            request, _ = self.benchmark.fixture_request(1, 1, 1, 0, 0, 0, 0)
            request_bytes = json.dumps(
                request,
                separators=(",", ":"),
            ).encode("utf-8")
            result = json.loads(output.getvalue())

        self.assertEqual(exit_code, 0)
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
                bridge=str(bridge_path),
                vmmap=False,
                json=True,
            )

            with self.assertRaisesRegex(RuntimeError, "request changed"):
                self.benchmark.run_benchmark(args)

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
