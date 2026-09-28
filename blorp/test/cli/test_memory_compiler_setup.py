"""CLI memory checks must work with CI's prebuilt compiler pair."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SETUP = ROOT / "blorp/test/cli/prepare_memory_compiler.py"
VERSION = """blorp 0.0.1
commit: abc123
target: test-target
channel: local
dirty: false
compiled_by: dev-123
optimization: cli=-O2 runtime=-O2
split: 8
cc: test clang
memory_diagnostics: 0
"""


class MemoryCompilerSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.normal = self.root / "bin/blorp"
        self.diagnostic = self.root / "prebuilt diagnostic"
        self.write_program(self.normal, VERSION)
        self.write_program(self.diagnostic, VERSION.replace("memory_diagnostics: 0", "memory_diagnostics: 1"))
        self.make_marker = self.root / "make-called"
        make = self.root / "fake-bin/make"
        make.parent.mkdir()
        make.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(self.make_marker))}\nexit 93\n")
        make.chmod(0o755)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("BLORP_")}
        self.environment["PATH"] = f"{make.parent}:{os.environ['PATH']}"

    def write_program(self, path, output, status=0):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\nprintf '%s\\n' {shlex.quote(output)}\nexit {status}\n")
        path.chmod(0o755)

    def run_setup(self, supplied=True):
        environment = dict(self.environment)
        if supplied:
            environment["BLORP_DIAGNOSTIC_BIN"] = str(self.diagnostic)
        return subprocess.run(
            [sys.executable, str(SETUP), str(self.normal)], cwd=self.root,
            env=environment, text=True, capture_output=True,
        )

    def test_prebuilt_pair_needs_no_bootstrap_build_tree_or_make(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.diagnostic.resolve()))
        self.assertFalse(self.make_marker.exists())

    def test_missing_or_nonexecutable_diagnostic_fails_without_building(self):
        self.diagnostic.unlink()
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("executable", result.stderr)
        self.write_program(self.diagnostic, VERSION)
        self.diagnostic.chmod(0o644)
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertFalse(self.make_marker.exists())

    def test_rejects_incompatible_or_incomplete_versions(self):
        diagnostic_version = VERSION.replace("memory_diagnostics: 0", "memory_diagnostics: 1")
        for version in (
            VERSION,
            diagnostic_version.replace("abc123", "different"),
            diagnostic_version.replace("cli=-O2", "cli=-O0"),
            diagnostic_version.replace("cc: test clang\n", ""),
            diagnostic_version + "memory_diagnostics: 1\n",
        ):
            with self.subTest(version=version):
                self.write_program(self.diagnostic, version)
                self.assertNotEqual(self.run_setup().returncode, 0)
        self.write_program(self.normal, VERSION.replace("cc: test clang\n", ""))
        self.write_program(self.diagnostic, diagnostic_version.replace("cc: test clang\n", ""))
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertFalse(self.make_marker.exists())

    def test_version_command_failure_is_not_accepted(self):
        self.write_program(self.diagnostic, VERSION.replace("memory_diagnostics: 0", "memory_diagnostics: 1"), status=7)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--version", result.stderr)

    def test_local_fallback_preserves_freshness_failure_detail(self):
        self.write_program(self.root / "scripts/compiler-build-status", "STALE: intentional fixture mismatch", status=1)
        result = self.run_setup(supplied=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("intentional fixture mismatch", result.stderr)
        self.assertFalse(self.make_marker.exists())

    def test_local_fallback_forwards_native_configuration(self):
        self.write_program(self.root / "scripts/compiler-build-status", "FRESH")
        target = self.root / "blorp/build/_build/blorp-cli/blorp-diagnostic"
        target.parent.mkdir(parents=True)
        make = self.root / "fake-bin/make"
        make.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$BLORP_CLI_C_OPTIMIZATION\" \"$BLORP_CLI_RUNTIME_C_OPTIMIZATION\" \"$BLORP_CLI_C_SPLIT\" > {shlex.quote(str(self.make_marker))}\n"
            f"cp {shlex.quote(str(self.diagnostic))} {shlex.quote(str(target))}\n"
        )
        result = self.run_setup(supplied=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.make_marker.read_text().splitlines(), ["-O2", "-O2", "8"])
        self.assertEqual(result.stdout.strip(), str(target.resolve()))

    def test_local_build_failure_is_reported(self):
        self.write_program(self.root / "scripts/compiler-build-status", "FRESH")
        self.write_program(self.root / "fake-bin/make", "intentional build failure", status=93)
        result = self.run_setup(supplied=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("intentional build failure", result.stderr)

    def test_cli_setup_failure_emits_exactly_one_structured_result(self):
        # Exercise the real shell reporting boundary without compiling every
        # unrelated smoke fixture that precedes memory-toolchain selection.
        script = (ROOT / "blorp/test/cli/test_cli.sh").read_text()
        functions = "\n".join(
            re.search(rf"(?ms)^{name}\(\) \{{.*?^\}}", script).group(0)
            for name in ("record_pass", "record_fail", "finish")
        )
        start = script.index("TOTAL=$((TOTAL + 1))\nif BLORP_DIAGNOSTIC_BIN=")
        end = script.index('\nexpect_memory_checkpoint_labels "compiler memory checkpoints use phase labels"', start)
        setup_copy = self.root / "blorp/test/cli/prepare_memory_compiler.py"
        setup_copy.parent.mkdir(parents=True)
        shutil.copy2(SETUP, setup_copy)
        self.diagnostic.unlink()
        result = subprocess.run(
            ["bash", "-c", "set -u\nPASS=0\nFAIL=0\nTOTAL=0\nCLI_GATE_NAME=cli\n"
             + functions + "\n" + script[start:end]],
            cwd=self.root, capture_output=True, text=True,
            env={**self.environment, "BLORP_BIN_ABS": str(self.normal),
                 "BLORP_DIAGNOSTIC_BIN": str(self.diagnostic), "TMPDIR_CLI": str(self.root)},
        )
        self.assertEqual(result.returncode, 1)
        rows = [line for line in result.stdout.splitlines() if line.startswith("BLORP_GATE_RESULT ")]
        self.assertEqual(rows, ["BLORP_GATE_RESULT gate=cli status=FAIL passed=0 failed=1 tests=1"])
        self.assertIn("Compiler is not executable", result.stdout)

    def test_ci_bundles_and_selects_diagnostic_compiler(self):
        workflow = (ROOT / ".github/workflows/ci-platform.yml").read_text()
        compile_step = workflow.split("      - name: Compile\n", 1)[1].split("      - name: Install\n", 1)[0]
        self.assertIn("BLORP_CLI_C_OPTIMIZATION: -O2", compile_step)
        self.assertIn("make build-blorp-cli-diagnostic", compile_step)
        bundle_step = workflow.split("      - name: Bundle build\n", 1)[1].split("      - name: Upload build\n", 1)[0]
        self.assertIn("blorp/build/_build/blorp-cli/blorp-diagnostic", bundle_step)
        test_step = workflow.split("      - name: Run test suites\n", 1)[1].split("      - name: Verify rebuilt", 1)[0]
        self.assertIn("BLORP_DIAGNOSTIC_BIN: blorp/build/_build/blorp-cli/blorp-diagnostic", test_step)


if __name__ == "__main__":
    unittest.main()
