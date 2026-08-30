import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


REPO_ROOT = Path(__file__).resolve().parents[4]
RUNNER = REPO_ROOT / "tests/test_compiler/run_compiler_tool_fixtures.py"


class CompilerToolFixtureRunnerTests(unittest.TestCase):
    @staticmethod
    def pid_is_running(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def test_runs_all_public_tool_fixture_categories(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture_root = root / "test_compiler"
            fixtures = {
                "format/should_pass/formatted.brp": "func main(args: List[String]) -> Int: 0\n",
                "format/should_fail/unformatted.brp": "func main( args:List[String] )->Int:0\n",
                "format/should_error/broken.brp": "-- EXPECT: error: broken syntax\nfunc broken(\n",
                "purify/should_purify/pure.brp": "func pure_candidate() -> Int: 1\n",
                "purify/should_not_purify/impure.brp": "func impure_candidate(): print(1)\n",
                "purify/should_rewrite/rewrite.brp": (
                    "-- EXPECT-CONTAINS: pure func rewrite_me\n"
                    "func rewrite_me() -> Int: 1\n"
                ),
                "lint/should_find/finding.brp": "record Wrapper {value: Int}\n",
                "lint/should_be_clean/clean.brp": "record Pair {left: Int, right: Int}\n",
            }
            for relative_path, source in fixtures.items():
                path = fixture_root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")

            compiler = root / "bin" / "blorp"
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    from pathlib import Path
                    import sys

                    command = sys.argv[1]
                    path = Path(sys.argv[-1])
                    if command == "format":
                        if path.name == "unformatted.brp":
                            print("needs formatting")
                            raise SystemExit(1)
                        if path.name == "broken.brp":
                            print("error: broken syntax")
                            raise SystemExit(1)
                        raise SystemExit(0)
                    if command == "purify":
                        if "--dry-run" in sys.argv:
                            if path.parent.name == "should_purify":
                                print("pure_candidate")
                            raise SystemExit(0)
                        source = path.read_text(encoding="utf-8")
                        path.write_text(
                            source.replace("func rewrite_me", "pure func rewrite_me"),
                            encoding="utf-8",
                        )
                        raise SystemExit(0)
                    if command == "lint":
                        if path.parent.name == "should_find":
                            print(
                                '{"schema_version":1,"findings":'
                                '[{"rule_id":"structure.single-field-record"}]}'
                            )
                        else:
                            print('{"schema_version":1,"findings":[]}')
                        raise SystemExit(0)
                    if command == "check":
                        raise SystemExit(0)
                    raise SystemExit(2)
                    """
                ),
                encoding="utf-8",
            )
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--fixture-root",
                    str(fixture_root),
                    "--no-stdlib-case",
                    "--expected-count",
                    str(len(fixtures)),
                    "--gate-name",
                    "compiler_tools_test",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=10,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(
                "BLORP_GATE_RESULT gate=compiler_tools_test "
                "status=PASS passed=8 failed=0 tests=8",
                result.stdout,
            )

    def test_reports_expectation_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture_root = root / "test_compiler"
            fixture = fixture_root / "format/should_error/broken.brp"
            fixture.parent.mkdir(parents=True)
            fixture.write_text(
                "-- EXPECT: error: wanted diagnostic\nfunc broken(\n",
                encoding="utf-8",
            )
            compiler = root / "bin" / "blorp"
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text(
                "#!/bin/sh\n"
                "case \"$*\" in\n"
                "  *warmup.brp) exit 0 ;;\n"
                "esac\n"
                "printf '%s\\n' 'error: actual diagnostic'\n"
                "exit 1\n",
                encoding="utf-8",
            )
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--fixture-root",
                    str(fixture_root),
                    "--no-stdlib-case",
                    "--expected-count",
                    "1",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("missing exact diagnostic: error: wanted diagnostic", result.stdout)
            self.assertIn("status=FAIL passed=0 failed=1 tests=1", result.stdout)

    def test_rejects_empty_custom_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            compiler = root / "bin" / "blorp"
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--fixture-root",
                    str(root / "missing"),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("no compiler tool fixtures found", result.stdout)
            self.assertIn("status=FAIL passed=0 failed=1 tests=1", result.stdout)

    def test_timeout_terminates_descendant_that_escapes_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture_root = root / "test_compiler"
            fixture = fixture_root / "format/should_pass/hangs.brp"
            fixture.parent.mkdir(parents=True)
            fixture.write_text("func main(args: List[String]) -> Int: 0\n", encoding="utf-8")
            marker = root / "descendant.pid"
            compiler = root / "bin" / "blorp"
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    from pathlib import Path
                    import os
                    import subprocess
                    import sys
                    import time

                    if Path(sys.argv[-1]).name == "warmup.brp":
                        raise SystemExit(0)
                    child = subprocess.Popen([
                        sys.executable,
                        "-c",
                        "import os, time; os.setsid(); time.sleep(30)",
                    ])
                    Path(os.environ["DESCENDANT_MARKER"]).write_text(str(child.pid))
                    time.sleep(30)
                    """
                ),
                encoding="utf-8",
            )
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--fixture-root",
                    str(fixture_root),
                    "--no-stdlib-case",
                    "--expected-count",
                    "1",
                    "--timeout",
                    "1",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=6,
                env={**os.environ, "DESCENDANT_MARKER": str(marker)},
                check=False,
            )

            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("formatter timed out", result.stdout)
            self.assertTrue(marker.is_file())
            descendant_pid = int(marker.read_text(encoding="utf-8"))
            for _ in range(40):
                if not self.pid_is_running(descendant_pid):
                    break
                time.sleep(0.05)
            try:
                self.assertFalse(self.pid_is_running(descendant_pid))
            finally:
                if self.pid_is_running(descendant_pid):
                    os.kill(descendant_pid, signal.SIGKILL)

    @unittest.skipUnless(
        sys.platform.startswith("linux"),
        "Linux subreaper semantics close the leader-exit attribution race",
    )
    def test_leader_exit_terminates_adopted_detached_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture_root = root / "test_compiler"
            fixture = fixture_root / "format/should_pass/leaks.brp"
            fixture.parent.mkdir(parents=True)
            fixture.write_text(
                "func main(args: List[String]) -> Int: 0\n", encoding="utf-8"
            )
            marker = root / "descendant.pid"
            compiler = root / "bin" / "blorp"
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    from pathlib import Path
                    import os
                    import subprocess
                    import sys
                    import time

                    if Path(sys.argv[-1]).name == "warmup.brp":
                        raise SystemExit(0)
                    child = subprocess.Popen([
                        sys.executable,
                        "-c",
                        (
                            "from pathlib import Path; import os, time; "
                            "os.setsid(); "
                            "Path(os.environ['DESCENDANT_MARKER']).write_text(str(os.getpid())); "
                            "time.sleep(30)"
                        ),
                    ])
                    marker = Path(os.environ["DESCENDANT_MARKER"])
                    deadline = time.monotonic() + 2
                    while True:
                        try:
                            published_pid = marker.read_text()
                        except FileNotFoundError:
                            published_pid = ""
                        if published_pid == str(child.pid):
                            break
                        if time.monotonic() >= deadline:
                            raise RuntimeError("descendant did not publish its PID")
                        time.sleep(0.001)
                    """
                ),
                encoding="utf-8",
            )
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--fixture-root",
                    str(fixture_root),
                    "--no-stdlib-case",
                    "--expected-count",
                    "1",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=6,
                env={**os.environ, "DESCENDANT_MARKER": str(marker)},
                check=False,
            )

            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("command left descendant processes running", result.stdout)
            self.assertTrue(marker.is_file())
            descendant_pid = int(marker.read_text(encoding="utf-8"))
            try:
                self.assertFalse(self.pid_is_running(descendant_pid))
            finally:
                if self.pid_is_running(descendant_pid):
                    os.kill(descendant_pid, signal.SIGKILL)

    def test_capture_limit_terminates_noisy_command(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture_root = root / "test_compiler"
            fixture = fixture_root / "format/should_pass/noisy.brp"
            fixture.parent.mkdir(parents=True)
            fixture.write_text("func main(args: List[String]) -> Int: 0\n", encoding="utf-8")
            compiler = root / "bin" / "blorp"
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    from pathlib import Path
                    import sys
                    import time

                    if Path(sys.argv[-1]).name == "warmup.brp":
                        raise SystemExit(0)
                    sys.stdout.write("x" * 2000000)
                    sys.stdout.flush()
                    time.sleep(30)
                    """
                ),
                encoding="utf-8",
            )
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--fixture-root",
                    str(fixture_root),
                    "--no-stdlib-case",
                    "--expected-count",
                    "1",
                    "--timeout",
                    "5",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("capture limit", result.stdout)


if __name__ == "__main__":
    unittest.main()
