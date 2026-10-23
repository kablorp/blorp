#!/usr/bin/env python3
"""Build-free contract tests for the cross-language benchmark sample runner."""

from __future__ import annotations

import re
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
RUNNER = ROOT / "benchmarks" / "bench_run.py"
FIB_OUTPUT = "Fib(40) = 102334155\n"
EXPECTED_OUTPUTS = {
    "numeric_loop": "Total Collatz steps: 131434272\n",
    "array_sum": "Completed 10000 iterations, total: 4995000000\n",
    "array_ops": "Completed 10000 iterations, final sum: 44955000000\n",
    "dict_ops": (
        "build: done\n"
        "lookup_hit checksum: 34996500000\n"
        "lookup_miss count: 1000000\n"
        "remove count: 1000000\n"
        "iterate sum: 349965000000\n"
    ),
    "list_ops": (
        "append checksum: 5000000\n"
        "sort checksum: 4999000\n"
        "filter checksum: 2500000\n"
        "fold checksum: 99990000000\n"
        "reverse checksum: 10000000\n"
        "concat checksum: 10000000\n"
    ),
    "set_ops": (
        "build: done\n"
        "contains_hit: 2000000\n"
        "contains_miss: 2000000\n"
        "union: 5000000\n"
        "intersect: 2500000\n"
        "difference: 2500000\n"
    ),
    "compiler_ast": "compiler_ast checksum: 2390849568879\n",
    "compiler_emit": (
        "compiler_emit checksum: -4239430305840994758\n"
        "compiler_emit bytes: 263793\n"
    ),
    "binary_trees": (
        "stretch tree of depth 16 check: 6442483711\n"
        "32768 trees of depth 4 check: 12812288\n"
        "8192 trees of depth 6 check: 50585600\n"
        "2048 trees of depth 8 check: 201586688\n"
        "512 trees of depth 10 check: 805568000\n"
        "128 trees of depth 12 check: 3221487488\n"
        "32 trees of depth 14 check: 12885164000\n"
        "long lived tree of depth 15 check: 1610629119\n"
    ),
}


class BenchmarkRunnerTests(unittest.TestCase):
    def test_c_benchmark_commands_use_o2(self) -> None:
        script = (ROOT / "benchmarks" / "bench.sh").read_text(encoding="utf-8")
        logical_commands = script.replace("\\\n", " ")
        compile_commands = re.findall(r"^\s*\$CC\s+[^\n]+", logical_commands, re.MULTILINE)
        self.assertEqual(len(compile_commands), 6)
        for command in compile_commands:
            self.assertIn("-O2", command)
            self.assertNotIn("-O3", command)

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

    def test_selected_benchmarks_reject_wrong_result_despite_valid_timing_marker(self) -> None:
        for name in EXPECTED_OUTPUTS:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp_name:
                script, counter = self.fake_benchmark(Path(temp_name), ["wrong result\n"])
                result = self.run_samples(name, script, counter)

                self.assertEqual(result.returncode, 125)
                self.assertIn(f"{name} output mismatch", result.stderr)
                self.assertEqual(counter.read_text(), "1")

    def test_selected_benchmarks_accept_exact_result(self) -> None:
        for name, output in EXPECTED_OUTPUTS.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp_name:
                script, counter = self.fake_benchmark(Path(temp_name), [output])
                result = self.run_samples(name, script, counter)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "0.1250\n")

    def test_selected_benchmarks_check_warmup_output(self) -> None:
        for name, output in EXPECTED_OUTPUTS.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp_name:
                wrong_checksum = re.sub(r"(?<=: )-?\d+", "0", output, count=1)
                script, counter = self.fake_benchmark(
                    Path(temp_name), [wrong_checksum, output]
                )
                result = self.run_samples(name, script, counter, warmups=1)

                self.assertEqual(result.returncode, 125)
                self.assertIn(f"{name} output mismatch", result.stderr)
                self.assertEqual(counter.read_text(), "1")

    def test_selected_benchmarks_check_every_timed_output(self) -> None:
        for name, output in EXPECTED_OUTPUTS.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp_name:
                wrong_checksum = re.sub(r"(?<=: )-?\d+", "0", output, count=1)
                script, counter = self.fake_benchmark(
                    Path(temp_name), [output, wrong_checksum]
                )
                result = self.run_samples(name, script, counter, runs=2)

                self.assertEqual(result.returncode, 125)
                self.assertIn(f"{name} output mismatch", result.stderr)
                self.assertEqual(counter.read_text(), "2")

    def test_unchecked_benchmarks_keep_timing_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            script, counter = self.fake_benchmark(Path(temp_name), ["other result\n"])
            result = self.run_samples("string", script, counter)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "0.1250\n")

    def test_binary_trees_accepts_existing_tab_separators(self) -> None:
        output = EXPECTED_OUTPUTS["binary_trees"].replace(" check:", "\t check:").replace(" trees", "\t trees")
        with tempfile.TemporaryDirectory() as temp_name:
            script, counter = self.fake_benchmark(Path(temp_name), [output])
            result = self.run_samples("binary_trees", script, counter)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_new_contracts_reject_changed_checksum(self) -> None:
        for name in ("binary_trees", "compiler_ast", "compiler_emit"):
            output = EXPECTED_OUTPUTS[name]
            changed = re.sub(r"(?<=: )-?\d+", "0", output, count=1)
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp_name:
                script, counter = self.fake_benchmark(Path(temp_name), [changed])
                result = self.run_samples(name, script, counter)
                self.assertEqual(result.returncode, 125)
                self.assertIn(f"{name} output mismatch", result.stderr)

    def test_binary_trees_preserves_line_boundaries(self) -> None:
        output = EXPECTED_OUTPUTS["binary_trees"].replace("\n", " ")
        with tempfile.TemporaryDirectory() as temp_name:
            script, counter = self.fake_benchmark(Path(temp_name), [output])
            result = self.run_samples("binary_trees", script, counter)
            self.assertEqual(result.returncode, 125)

    def test_compiler_checksums_keep_exact_whitespace(self) -> None:
        for name in ("compiler_ast", "compiler_emit"):
            output = EXPECTED_OUTPUTS[name].replace(" checksum:", "\tchecksum:")
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp_name:
                script, counter = self.fake_benchmark(Path(temp_name), [output])
                result = self.run_samples(name, script, counter)
                self.assertEqual(result.returncode, 125)


class BenchmarkIntegrationTests(unittest.TestCase):
    """Exercise the real shell flow with build-free compiler/native substitutes."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("benchmarks/blorp", "benchmarks/blorp_2", "bin", "blorp_2/build", "blorp_2/standard_library"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for name in ("bench.sh", "bench_run.py"):
            shutil.copyfile(ROOT / "benchmarks" / name, self.root / "benchmarks" / name)
        for language, names in (("blorp", ("fib", "string")), ("blorp_2", ("fib",))):
            for name in names:
                (self.root / "benchmarks" / language / f"{name}.brp").write_text(f"{language} {name} fixture\n")
        self.log = self.root / "calls.jsonl"
        self.compiler = self.root / "selected-blorp2"
        self.write_executable(self.root / "bin/blorp", self.compiler_source("blorp"))
        self.write_executable(self.compiler, self.compiler_source("blorp2"))
        self.write_executable(self.root / "blorp_2/build/compiler", self.compiler_source("blorp2"))
        self.cc = self.root / "fake_cc"
        self.write_executable(self.cc, '''import json, os, pathlib, sys
args = sys.argv[1:]
if args == ['--version']:
    print('fake C compiler')
    raise SystemExit(0)
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps({'kind': 'cc', 'args': args}) + '\\n')
output = pathlib.Path(args[args.index('-o') + 1])
if '-c' in args:
    diagnostics = int('-DBLORP_MEMORY_DIAGNOSTICS=1' in args)
    if diagnostics and 'blorp2' in output.name and os.environ.get('FAKE_FAIL_DIAGNOSTIC_BUILD'):
        print('deliberate Blorp2 diagnostic C compilation failure', file=sys.stderr)
        raise SystemExit(71)
    output.write_text(str(diagnostics))
else:
    diagnostics = max((int(pathlib.Path(arg).read_text()) for arg in args if arg.endswith('.o')), default=0)
    language = 'blorp2' if 'blorp2' in output.name else 'blorp'
    seconds = os.environ.get('FAKE_B2_SECONDS', '0.125000') if language == 'blorp2' else '0.125000'
    program = "import json, os, sys\\n"
    program += "with open(os.environ['FAKE_LOG'], 'a') as log: log.write(json.dumps({'kind': 'native', 'path': sys.argv[0], 'diagnostics': %r, 'mode': os.environ.get('BLORP_LEAK_CHECK')}) + '\\\\n')\\n" % diagnostics
    program += "print(os.environ.get('FAKE_OUTPUT', 'Fib(40) = 102334155'))\\n"
    program += "print('BENCH name=fib lang=%s seconds=%s', file=sys.stderr)\\n" % (language, seconds)
    if diagnostics:
        program += "print('blorp: leak check: 2 allocs, 2 releases, 0 leaked, 0 bytes', file=sys.stderr)\\n"
        program += "raise SystemExit(99 if os.environ.get('FAKE_FAIL_STATS') == %r else 0)\\n" % language
    output.write_text('#!' + sys.executable + '\\n' + program)
    output.chmod(0o755)
''')
        self.env = dict(os.environ, PYTHON=sys.executable, GO="missing-benchmark-go", OCAMLOPT="missing-benchmark-ocaml",
                        CC=str(self.cc), BLORP2_COMPILER=str(self.compiler), FAKE_LOG=str(self.log),
                        BENCH_RUNS="1", BENCH_WARMUPS="0", BENCH_ALLOC_STATS="0", BENCH_VERBOSE="1")
        self.env.pop("BLORP_LEAK_CHECK", None)

    def write_executable(self, path: Path, source: str) -> None:
        path.write_text(f"#!{sys.executable}\n{source}")
        path.chmod(0o755)

    def compiler_source(self, language: str) -> str:
        return f'''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps({{'kind': {language!r}, 'path': sys.argv[0], 'args': args,
                          'source': pathlib.Path(args[2] if {language!r} == 'blorp2' else args[1]).read_text()}}) + '\\n')
if {language!r} == 'blorp2':
    if os.environ.get('FAKE_FAIL_B2'):
        print('deliberate Blorp2 compiler failure', file=sys.stderr)
        raise SystemExit(32)
    assert len(args) == 4 and args[0] == '--library-root', args
    output = pathlib.Path(args[3])
else:
    assert args[0] == 'compile', args
    output = pathlib.Path(args[1]).with_suffix('.c')
output.write_text('/* fake generated C */\\n')
'''

    def run_benchmark(self, name: str = "fib", **environment: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(self.root / "benchmarks/bench.sh"), name],
                              env=dict(self.env, **environment), text=True, capture_output=True, check=False)

    def calls(self, kind: str) -> list[dict]:
        entries = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [entry for entry in entries if entry["kind"] == kind]

    def test_blorp2_has_independent_column_and_explicit_compiler_inputs(self) -> None:
        result = self.run_benchmark()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        header = next(line for line in result.stdout.splitlines() if line.strip().startswith("Benchmark"))
        self.assertEqual(header.split(), ["Benchmark", "blorp", "blorp2", "C", "Go", "OCaml", "Python"])
        row = next(line for line in result.stdout.splitlines() if line.strip().startswith("fib "))
        self.assertEqual(row.split()[:7], ["fib", "0.1250s", "0.1250s", "-", "-", "-", "-"])
        calls = self.calls("blorp2")
        self.assertEqual(len(calls), 1)
        arguments = calls[0]["args"]
        self.assertEqual(arguments[:2], ["--library-root", str(self.root / "blorp_2/standard_library")])
        self.assertEqual(calls[0]["path"], str(self.compiler))
        self.assertEqual(calls[0]["source"], "blorp_2 fib fixture\n")
        self.assertTrue(arguments[2].endswith(".brp"))
        self.assertTrue(arguments[3].endswith(".c"))
        self.assertEqual(len(self.calls("blorp")), 1)

    def test_unsupported_blorp2_row_stays_dash_without_compiler(self) -> None:
        result = self.run_benchmark("string", BLORP2_COMPILER=str(self.root / "absent"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        row = next(line for line in result.stdout.splitlines() if line.strip().startswith("string "))
        self.assertEqual(row.split()[:3], ["string", "0.1250s", "-"])
        self.assertEqual(self.calls("blorp2"), [])

    def test_blorp2_slowdown_is_an_explicit_elapsed_time_ratio(self) -> None:
        result = self.run_benchmark(FAKE_B2_SECONDS="12.5")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("blorp2/blorp time: 100.0x", result.stdout)

    def test_selected_blorp2_compile_failure_does_not_fallback(self) -> None:
        result = self.run_benchmark(FAKE_FAIL_B2="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL", result.stdout)
        self.assertEqual(len(self.calls("blorp")), 1)
        self.assertEqual(len(self.calls("blorp2")), 1)

    def test_missing_selected_compiler_explains_build_and_override(self) -> None:
        result = self.run_benchmark(BLORP2_COMPILER=str(self.root / "absent"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BLORP2_COMPILER", result.stderr)
        self.assertIn("make -C blorp_2", result.stderr)

    def test_allocation_stats_use_separate_binaries_and_modes(self) -> None:
        result = self.run_benchmark(BENCH_ALLOC_STATS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls("native")
        self.assertEqual(len(calls), 4)
        normal = [entry for entry in calls if entry["diagnostics"] == 0]
        diagnostic = [entry for entry in calls if entry["diagnostics"] == 1]
        self.assertEqual(len(normal), 2)
        self.assertEqual(len(diagnostic), 2)
        self.assertTrue(all(entry["mode"] is None for entry in normal))
        for entry in diagnostic:
            self.assertEqual(entry["mode"], "strict" if "blorp2" in entry["path"] else "1")
        self.assertTrue(all(entry["path"].endswith(".alloc") for entry in diagnostic))
        self.assertEqual(len(self.calls("blorp2")), 1)
        self.assertIn("allocs=2", result.stdout)

    def test_diagnostic_failure_fails_benchmark(self) -> None:
        result = self.run_benchmark(BENCH_ALLOC_STATS="1", FAKE_FAIL_STATS="blorp2")
        self.assertNotEqual(result.returncode, 0)

    def test_diagnostic_build_failure_is_reported_despite_existing_normal_binary(self) -> None:
        result = self.run_benchmark(BENCH_ALLOC_STATS="1", FAKE_FAIL_DIAGNOSTIC_BUILD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 failed", result.stdout)
        self.assertIn("Build failed: blorp2/fib", result.stderr)
        self.assertIn("deliberate Blorp2 diagnostic C compilation failure", result.stderr)
        # The diagnostic compile fails only after the normal executable linked.
        commands = [entry["args"] for entry in self.calls("cc")]
        normal_link = next(index for index, arguments in enumerate(commands)
                           if "-c" not in arguments and "bench_blorp2_fib" == Path(arguments[arguments.index("-o") + 1]).name)
        diagnostic_compile = next(index for index, arguments in enumerate(commands)
                                  if "-DBLORP_MEMORY_DIAGNOSTICS=1" in arguments
                                  and any("blorp2" in argument for argument in arguments))
        self.assertLess(normal_link, diagnostic_compile)

    def test_normal_timing_uses_no_diagnostic_compilation(self) -> None:
        result = self.run_benchmark()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.calls("native")), 2)
        self.assertTrue(all(entry["diagnostics"] == 0 for entry in self.calls("native")))
        self.assertTrue(all("-DBLORP_MEMORY_DIAGNOSTICS=1" not in entry["args"] for entry in self.calls("cc")))

    def test_provisional_blorp2_rows_label_the_comparison(self) -> None:
        for name in ("list_ops", "compiler_ast", "compiler_emit"):
            with self.subTest(name=name):
                for language in ("blorp", "blorp_2"):
                    (self.root / "benchmarks" / language / f"{name}.brp").write_text(f"{language} {name} fixture\n")
                result = self.run_benchmark(name, FAKE_OUTPUT=EXPECTED_OUTPUTS[name].rstrip("\n"))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                row = next(line for line in result.stdout.splitlines() if line.strip().startswith(name + " "))
                self.assertRegex(row.lower(), r"blorp2.*(?:provisional|current.library)")

    def test_default_blorp2_compiler_is_maintained_artifact(self) -> None:
        del self.env["BLORP2_COMPILER"]
        result = self.run_benchmark()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls("blorp2")[0]["path"], str(self.root / "blorp_2/build/compiler"))


if __name__ == "__main__":
    unittest.main()
