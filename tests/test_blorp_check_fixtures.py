import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import time
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RUNNER = REPO_ROOT / "tests/test_compiler/run_blorp_check_fixtures.py"


class BlorpCheckFixtureRunnerTests(unittest.TestCase):
    def test_runs_marked_pass_and_fail_fixtures(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            pass_dir = root / "should_pass"
            fail_dir = root / "should_fail"
            pass_dir.mkdir()
            fail_dir.mkdir()

            (pass_dir / "passes.brp").write_text(
                "-- RUN-BLORP-CHECK\nfunc main(args: List[String]) -> Int: 0\n",
                encoding="utf-8",
            )
            (fail_dir / "fails.brp").write_text(
                textwrap.dedent(
                    """\
                    -- EXPECT: error: compatibility diagnostic must not be selected
                    -- EXPECT-BLORP-CONTAINS: production diagnostic
                    -- RUN-BLORP-CHECK
                    func main(args: List[String]) -> Int: 0
                    """
                ),
                encoding="utf-8",
            )
            compiler = root / "blorp"
            compiler.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    from pathlib import Path
                    import sys

                    if Path(sys.argv[-1]).name == "fails.brp":
                        print("error: production diagnostic")
                        raise SystemExit(1)
                    print("Type checking succeeded.")
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
                    "--root",
                    str(root),
                    "--gate-name",
                    "fixture_test",
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
                "BLORP_GATE_RESULT gate=fixture_test status=PASS passed=2 failed=0 tests=2",
                result.stdout,
            )

    def test_reports_missing_expected_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fail_dir = root / "should_fail"
            fail_dir.mkdir()
            (fail_dir / "fails.brp").write_text(
                "-- EXPECT: error: wanted\n-- RUN-BLORP-CHECK\n",
                encoding="utf-8",
            )
            compiler = root / "blorp"
            compiler.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'error: actual'\nexit 1\n",
                encoding="utf-8",
            )
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--root",
                    str(root),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("missing exact diagnostic: error: wanted", result.stdout)
            self.assertIn("status=FAIL passed=0 failed=1 tests=1", result.stdout)

    def test_rejects_infrastructure_exit_for_should_fail_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fail_dir = root / "should_fail"
            fail_dir.mkdir()
            (fail_dir / "fails.brp").write_text(
                "-- EXPECT: error: wanted\n-- RUN-BLORP-CHECK\n",
                encoding="utf-8",
            )
            compiler = root / "blorp"
            compiler.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'error: wanted'\nexit 2\n",
                encoding="utf-8",
            )
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--root",
                    str(root),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("infrastructure exit 2", result.stdout)

    def test_timeout_terminates_descendant_processes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            pass_dir = root / "should_pass"
            pass_dir.mkdir()
            (pass_dir / "hangs.brp").write_text(
                "-- RUN-BLORP-CHECK\n",
                encoding="utf-8",
            )
            compiler = root / "blorp"
            compiler.write_text(
                "#!/bin/sh\nsleep 30 &\nwait\n",
                encoding="utf-8",
            )
            compiler.chmod(0o755)

            started = time.monotonic()
            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--root",
                    str(root),
                    "--timeout",
                    "1",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertLess(time.monotonic() - started, 4)
            self.assertIn("timed out after 1s", result.stdout)

    def test_enforces_expected_fixture_count(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            pass_dir = root / "should_pass"
            pass_dir.mkdir()
            (pass_dir / "only.brp").write_text(
                "-- RUN-BLORP-CHECK\n",
                encoding="utf-8",
            )
            compiler = root / "blorp"
            compiler.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            compiler.chmod(0o755)

            result = subprocess.run(
                [
                    "python3",
                    str(RUNNER),
                    "--blorp-bin",
                    str(compiler),
                    "--root",
                    str(root),
                    "--expected-count",
                    "2",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("expected 2 RUN-BLORP-CHECK fixtures, found 1", result.stdout)


if __name__ == "__main__":
    unittest.main()
