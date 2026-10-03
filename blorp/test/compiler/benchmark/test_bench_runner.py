#!/usr/bin/env python3
"""Build-free contract tests for the cross-language benchmark sample runner."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
RUNNER = ROOT / "benchmarks" / "bench_run.py"
FIB_OUTPUT = "Fib(40) = 102334155\n"


class BenchmarkRunnerTests(unittest.TestCase):
    def fake_benchmark(self, directory: Path, outputs: list[str]) -> tuple[Path, Path]:
        script = directory / "fake_benchmark.py"
        counter = directory / "invocations.txt"
        script.write_text(
            "import pathlib\n"
            "import sys\n"
            f"outputs = {outputs!r}\n"
            "counter = pathlib.Path(sys.argv[1])\n"
            "index = int(counter.read_text()) if counter.exists() else 0\n"
            "counter.write_text(str(index + 1))\n"
            "print(outputs[index], end='')\n"
            "print('BENCH name=fib lang=fake seconds=0.125000', file=sys.stderr)\n",
            encoding="utf-8",
        )
        return script, counter

    def run_samples(
        self,
        name: str,
        script: Path,
        counter: Path,
        *,
        warmups: int = 0,
        runs: int = 1,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(RUNNER),
                str(warmups),
                str(runs),
                name,
                sys.executable,
                str(script),
                str(counter),
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_fib_rejects_wrong_result_despite_valid_timing_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            script, counter = self.fake_benchmark(Path(temp_name), ["Fib(40) = 0\n"])
            result = self.run_samples("fib", script, counter)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fib output mismatch", result.stderr)
            self.assertEqual(counter.read_text(), "1")

    def test_fib_accepts_exact_result(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            script, counter = self.fake_benchmark(Path(temp_name), [FIB_OUTPUT])
            result = self.run_samples("fib", script, counter)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "0.1250\n")

    def test_fib_checks_warmup_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            script, counter = self.fake_benchmark(
                Path(temp_name), ["Fib(40) = 0\n", FIB_OUTPUT]
            )
            result = self.run_samples("fib", script, counter, warmups=1)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fib output mismatch", result.stderr)
            self.assertEqual(counter.read_text(), "1")

    def test_fib_checks_every_timed_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            script, counter = self.fake_benchmark(
                Path(temp_name), [FIB_OUTPUT, "Fib(40) = 0\n"]
            )
            result = self.run_samples("fib", script, counter, runs=2)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("fib output mismatch", result.stderr)
            self.assertEqual(counter.read_text(), "2")

    def test_other_benchmarks_keep_timing_contract_without_output_check(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            script, counter = self.fake_benchmark(Path(temp_name), ["other result\n"])
            result = self.run_samples("numeric_loop", script, counter)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "0.1250\n")


if __name__ == "__main__":
    unittest.main()
