#!/usr/bin/env python3
"""Contract tests for the benchmark-only typecheck worker builder."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "benchmarks" / "compiler_typecheck_worker.py"


def load_worker_module():
    spec = importlib.util.spec_from_file_location(
        "compiler_typecheck_worker_builder",
        MODULE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load typecheck worker builder")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CompilerTypecheckWorkerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.worker = load_worker_module()

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
            compiler = root / "blorp"
            source = root / self.worker.WORKER_SOURCE
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

            with mock.patch.object(self.worker, "_run", side_effect=fake_run) as run:
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
                f"pthread_attr_setstacksize(&attr, (size_t){self.worker.WORKER_STACK_SIZE_BYTES})",
                wrapper,
            )
            self.assertEqual(worker_path, output_dir / "compiler_typecheck_worker")

    def test_builder_links_and_runs_worker_with_system_c_compiler(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            root = Path(temp_name)
            compiler = root / "blorp"
            source = root / self.worker.WORKER_SOURCE
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
                    printf '%s\\n' 'int main(int argc, char **argv) { return argc == 2 ? 0 : 9; }' > "$output"
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
