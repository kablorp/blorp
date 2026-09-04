#!/usr/bin/env python3
"""Contract tests for the benchmark-only compiler worker builder and adapters."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[5]
BUILDER_MODULE_PATH = ROOT / "benchmarks" / "compiler_benchmark_worker.py"
MODULE_PATH = ROOT / "benchmarks" / "compiler_typecheck_worker.py"
BACKEND_MODULE_PATH = ROOT / "benchmarks" / "compiler_backend_worker.py"
TYPECHECK_GRAPH_INCLUDE_DIR = Path(
    "blorp/src/compiler/stage_06_typecheck/graph"
)


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(
        name,
        path,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load benchmark worker module: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class CompilerTypecheckWorkerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.builder = load_module("compiler_benchmark_worker", BUILDER_MODULE_PATH)
        cls.worker = load_module("compiler_typecheck_worker_builder", MODULE_PATH)
        cls.backend = load_module("compiler_backend_worker_builder", BACKEND_MODULE_PATH)

    def test_explicit_worker_must_be_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            path = Path(temp_name) / "worker"
            path.write_text("worker", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "not executable"):
                self.worker.prepare_typecheck_worker(
                    ROOT,
                    Path(temp_name) / "output",
                    str(path),
                )

    def test_builder_compiles_benchmark_source_with_large_stack_wrapper(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            compiler = root / "bin" / "blorp"
            source = root / self.worker.WORKER_SOURCE
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text("compiler", encoding="utf-8")
            compiler.chmod(0o755)
            source.parent.mkdir(parents=True)
            source.write_text("func main(args: List[String]) -> Int: 0\n", encoding="utf-8")
            output_dir = root / "output"

            def fake_run(command, _root, description):
                if description.startswith("linking"):
                    worker_path = Path(command[command.index("-o") + 1])
                    worker_path.write_text("worker", encoding="utf-8")
                    worker_path.chmod(0o755)

            with mock.patch.object(self.builder, "_run", side_effect=fake_run) as run:
                worker_path = self.worker.prepare_typecheck_worker(
                    root,
                    output_dir,
                    None,
                )

            compile_command = run.call_args_list[0].args[0]
            object_command = run.call_args_list[1].args[0]
            wrapper = (output_dir / "compiler_typecheck_worker_main.c").read_text(
                encoding="utf-8"
            )
            self.assertEqual(compile_command[:3], [str(compiler), "compile", "--no-format"])
            self.assertEqual(compile_command[-1], str(source))
            self.assertIn(
                f"-Dmain={self.worker.WORKER_MAIN_SYMBOL}",
                object_command,
            )
            self.assertIn(
                f"-I{(root / TYPECHECK_GRAPH_INCLUDE_DIR).resolve()}",
                object_command,
            )
            self.assertIn(
                f"pthread_attr_setstacksize(&attr, (size_t){self.builder.WORKER_STACK_SIZE_BYTES})",
                wrapper,
            )
            self.assertEqual(worker_path, output_dir / "compiler_typecheck_worker")

    def test_backend_adapter_selects_backend_worker_contract(self) -> None:
        expected = Path("/tmp/backend-worker")
        with mock.patch.object(
            self.backend,
            "prepare_benchmark_worker",
            return_value=expected,
        ) as prepare:
            actual = self.backend.prepare_backend_worker(
                ROOT,
                Path("/tmp/output"),
                None,
            )

        self.assertEqual(actual, expected)
        prepare.assert_called_once_with(
            ROOT,
            Path("/tmp/output"),
            None,
            env_name=self.backend.BACKEND_WORKER_ENV,
            source_path=self.backend.WORKER_SOURCE,
            worker_name=self.backend.WORKER_NAME,
            main_symbol=self.backend.WORKER_MAIN_SYMBOL,
        )

    def test_backend_adapter_requests_debug_profile_worker_explicitly(self) -> None:
        expected = Path("/tmp/backend-counter-worker")
        with mock.patch.object(
            self.backend,
            "prepare_benchmark_worker",
            return_value=expected,
        ) as prepare:
            actual = self.backend.prepare_backend_worker(
                ROOT,
                Path("/tmp/output"),
                None,
                debug_profile=True,
            )

        self.assertEqual(actual, expected)
        self.assertTrue(prepare.call_args.kwargs["debug_profile"])
        self.assertEqual(
            prepare.call_args.kwargs["env_name"],
            self.backend.BACKEND_COUNTER_WORKER_ENV,
        )

    def test_builder_links_and_runs_worker_with_system_c_compiler(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            compiler = root / "bin" / "blorp"
            source = root / self.worker.WORKER_SOURCE
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text(
                textwrap.dedent(
                    """\
                    #!/bin/sh
                    set -eu
                    output=""
                    while [ "$#" -gt 0 ]; do
                        if [ "$1" = "-o" ]; then
                            output=$2
                            shift 2
                        else
                            shift
                        fi
                    done
                    printf '%s\\n' '#include "indexed_graph_ffi.h"' > "$output"
                    printf '%s\\n' 'int main(int argc, char **argv) { return argc == 2 ? 0 : 9; }' >> "$output"
                    """
                ),
                encoding="utf-8",
            )
            compiler.chmod(0o755)
            source.parent.mkdir(parents=True)
            source.write_text(
                "func main(args: List[String]) -> Int: 0\n",
                encoding="utf-8",
            )
            ffi_header = (
                root / TYPECHECK_GRAPH_INCLUDE_DIR / "indexed_graph_ffi.h"
            )
            ffi_header.parent.mkdir(parents=True)
            ffi_header.write_text(
                "/* benchmark worker FFI fixture */\n",
                encoding="utf-8",
            )
            request = root / "request.json"
            request.write_text("{}", encoding="utf-8")

            worker_path = self.worker.prepare_typecheck_worker(
                root,
                root / "output",
                None,
            )
            completed = subprocess.run(
                [str(worker_path), str(request)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_environment_override_uses_benchmark_specific_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            path = Path(temp_name) / "worker"
            path.write_text("worker", encoding="utf-8")
            path.chmod(0o755)
            with mock.patch.dict(
                os.environ,
                {self.worker.TYPECHECK_WORKER_ENV: str(path)},
                clear=False,
            ):
                selected = self.worker.prepare_typecheck_worker(
                    ROOT,
                    Path(temp_name) / "output",
                    None,
                )
            self.assertEqual(selected, path.resolve())


if __name__ == "__main__":
    unittest.main()
