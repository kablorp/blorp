import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER = REPO_ROOT / "blorp/test/tool/test_compiler_tool_fixtures.py"
sys.path.insert(0, str(REPO_ROOT / "blorp/test/lib"))

import process_supervisor

sys.path.insert(0, str(RUNNER.parent))
import test_compiler_tool_fixtures as fixture_runner


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
                "purify/should_purify/pure.brp": (
                    "-- EXPECT-PURIFY: pure_candidate\n"
                    "func pure_candidate() -> Int: 1\n"
                ),
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
                        if path.name == "broken.brp":
                            print("error: broken syntax")
                            raise SystemExit(1)
                        source = path.read_text(encoding="utf-8")
                        unformatted = "func main( args:List[String] )->Int:0"
                        needs_formatting = (
                            path.name == "unformatted.brp" and unformatted in source
                        )
                        if "--check" in sys.argv or "--diff" in sys.argv:
                            if needs_formatting:
                                print("needs formatting")
                                raise SystemExit(1)
                            raise SystemExit(0)
                        if needs_formatting:
                            path.write_text(
                                source.replace(
                                    unformatted,
                                    "func main(args: List[String]) -> Int: 0",
                                ),
                                encoding="utf-8",
                            )
                        raise SystemExit(0)
                    if command == "purify":
                        if "--dry-run" in sys.argv:
                            if path.parent.name == "should_purify":
                                print(
                                    f"[DRY-RUN] Functions that could be purified in "
                                    f"{path}: pure_candidate"
                                )
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

    def test_purify_change_rejects_wrong_function_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_path = Path(temp_dir) / "returns_impure_closure.brp"
            fixture_path.write_text(
                "-- EXPECT-PURIFY: get_action\nfunc get_action() -> Int: 1\n",
                encoding="utf-8",
            )
            output = (
                "[DRY-RUN] Functions that could be purified in "
                f"{fixture_path}: helper\n"
            )
            with mock.patch.object(
                fixture_runner,
                "run_command",
                return_value=process_supervisor.CommandResult(0, output),
            ):
                failures = fixture_runner.run_fixture(
                    Path("bin/blorp"),
                    fixture_runner.Fixture(
                        fixture_runner.FixtureKind.PURIFY_CHANGE, fixture_path
                    ),
                    30,
                )

            self.assertIn("expected purify functions: get_action", failures)
            self.assertIn("actual purify functions: helper", failures)

    def test_purify_change_rejects_unstructured_or_unrelated_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_path = Path(temp_dir) / "pure.brp"
            fixture_path.write_text(
                "-- EXPECT-PURIFY: candidate\nfunc candidate() -> Int: 1\n",
                encoding="utf-8",
            )
            unrelated_path = fixture_path.parent / "unrelated" / fixture_path.name
            for output in (
                "candidate\n",
                "[DRY-RUN] Functions that could be purified in other.brp: candidate\n",
                f"[DRY-RUN] Functions that could be purified in {unrelated_path}: candidate\n",
                f"[DRY-RUN] Functions that could be purified in {fixture_path}: candidate\nnoise\n",
                f"[DRY-RUN] Functions that could be purified in {fixture_path}: candidate, extra\n",
            ):
                with self.subTest(output=output):
                    self.assertTrue(
                        fixture_runner.purify_change_failures(fixture_path, output)
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

    def test_format_fail_fixture_rejects_dropped_comment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture_root = root / "test_compiler"
            fixture = fixture_root / "format/should_fail/comments.brp"
            fixture.parent.mkdir(parents=True)
            fixture.write_text(
                'func main() -> Int:\n'
                '    -- kept\n'
                '    x = "not -- a comment"\n'
                '    -- dropped\n'
                '    0\n',
                encoding="utf-8",
            )
            compiler = root / "bin" / "blorp"
            compiler.parent.mkdir(parents=True, exist_ok=True)
            compiler.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    from pathlib import Path
                    import sys

                    path = Path(sys.argv[-1])
                    source = path.read_text(encoding="utf-8")
                    if "-- dropped" not in source:
                        raise SystemExit(0)
                    if "--check" in sys.argv or "--diff" in sys.argv:
                        print("needs formatting")
                        raise SystemExit(1)
                    path.write_text(source.replace("    -- dropped\\n", ""), encoding="utf-8")
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
                timeout=60,
                check=False,
            )

            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("formatter dropped comment: -- dropped", result.stdout)
            self.assertNotIn("-- kept", result.stdout)
            self.assertNotIn("not -- a comment", result.stdout)

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

    def test_warmup_timeout_is_independent_of_fixture_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture_root = root / "test_compiler"
            fixture = fixture_root / "format/should_pass/fast.brp"
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
                        time.sleep(1.5)
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
                    "--warmup-timeout",
                    "0",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )

            self.assertNotIn("warmup timed out", result.stdout)
            self.assertIn("status=PASS", result.stdout, result.stdout + result.stderr)

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
                    "3",
                    "--warmup-timeout",
                    "0",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=60,
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
                    "--warmup-timeout",
                    "0",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("capture limit", result.stdout)

    def test_process_list_timeout_during_sampling_does_not_fail_command(self) -> None:
        with mock.patch.object(
            process_supervisor,
            "owned_processes",
            side_effect=subprocess.TimeoutExpired(["ps"], 1),
        ) as sampler:
            result = process_supervisor.run_command(
                [sys.executable, "-c", "import time; time.sleep(0.3); print('ok')"], 30
            )

        sampler.assert_called()
        self.assertEqual(result.returncode, 0, result.output)
        self.assertEqual(result.output.strip(), "ok")


if __name__ == "__main__":
    unittest.main()
