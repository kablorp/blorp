#!/usr/bin/env python3
"""Step summary of `scripts/premerge-gate`, run in a scratch repository.

The scratch repository holds a copy of the gate script and fake `make`,
`scripts/test`, `bin/blorp` and codegen-audit commands that succeed instantly,
so the gate's own bookkeeping is what runs. FAKE_MAKE_FAIL names a make target
that fails.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]

FAKE_MAKE = textwrap.dedent(
	"""\
	#!/bin/bash
	[ -n "${FAKE_MAKE_FAIL:-}" ] && [ "$*" = "$FAKE_MAKE_FAIL" ] && exit 2
	exit 0
	"""
)
FAKE_BLORP = "#!/bin/bash\nexit 0\n"
FAKE_SCRIPTS_TEST = textwrap.dedent(
	"""\
	#!/bin/bash
	echo "BLORP_GATE_RESULT gate=test status=PASS passed=1 failed=0 tests=1"
	"""
)
STEP_ROW = re.compile(r"^(?P<name>.+?)\s+(?P<status>PASS|FAIL|SKIP)\s+(?P<seconds>\d+)$")
STEP_RECORD = re.compile(r"^BLORP_GATE_STEP name=(?P<name>[a-z-]+) status=(?P<status>PASS|FAIL|SKIP) seconds=(?P<seconds>\d+)$")


class PremergeGateStepsTest(unittest.TestCase):
	def setUp(self) -> None:
		self.directory = tempfile.TemporaryDirectory()
		self.addCleanup(self.directory.cleanup)
		self.repo = Path(self.directory.name)
		(self.repo / "scripts").mkdir()
		(self.repo / "bin").mkdir()
		audit = self.repo / "blorp/test/test_compiler/test_pipeline/codegen_audit"
		audit.mkdir(parents=True)
		self.write_executable(self.repo / "bin/make", FAKE_MAKE)
		self.write_executable(self.repo / "bin/blorp", FAKE_BLORP)
		self.write_executable(self.repo / "scripts/test", FAKE_SCRIPTS_TEST)
		self.write_executable(audit / "run_codegen_audit.sh", FAKE_BLORP)
		for name in ("premerge-gate", "gate-scope"):
			shutil.copy(ROOT / "scripts" / name, self.repo / "scripts" / name)
		policy = self.repo / "benchmarks/blorp_test_session_policy.json"
		policy.parent.mkdir()
		shutil.copy(ROOT / "benchmarks/blorp_test_session_policy.json", policy)
		(self.repo / "examples").mkdir()
		(self.repo / "README.md").write_text("scratch\n", encoding="utf-8")
		for command in (
			["init", "-q", "-b", "main"],
			["config", "user.email", "test@example.com"],
			["config", "user.name", "Test"],
			["add", "-A"],
			["commit", "-q", "-m", "scratch"],
		):
			subprocess.run(["git", "-C", str(self.repo), *command], check=True)

	@staticmethod
	def write_executable(path: Path, text: str) -> None:
		path.write_text(text, encoding="utf-8")
		path.chmod(0o755)

	def run_gate(self, *args: str, fail_make_target: str = "") -> subprocess.CompletedProcess:
		environment = dict(os.environ)
		environment["BLORP_TEST_LOCK_HELD"] = "1"
		environment["PATH"] = f"{self.repo / 'bin'}:{environment['PATH']}"
		environment["FAKE_MAKE_FAIL"] = fail_make_target
		return subprocess.run(
			["bash", "scripts/premerge-gate", "--no-docker", "--no-sanitize", *args],
			cwd=self.repo,
			env=environment,
			stdout=subprocess.PIPE,
			stderr=subprocess.STDOUT,
			text=True,
		)

	def table_rows(self, output: str) -> list[tuple[str, str, str]]:
		rows = []
		for line in output.splitlines():
			match = STEP_ROW.match(line)
			if match:
				rows.append((match["name"], match["status"], match["seconds"]))
		return rows

	def step_records(self, output: str) -> list[tuple[str, str, str]]:
		return [
			(match["name"], match["status"], match["seconds"])
			for match in map(STEP_RECORD.match, output.splitlines())
			if match
		]

	def test_passing_gate_lists_every_step_then_the_verdict_last(self) -> None:
		result = self.run_gate("--no-examples-run")
		self.assertEqual(result.returncode, 0, result.stdout)
		rows = self.table_rows(result.stdout)
		self.assertEqual(
			[(name, status) for name, status, _ in rows],
			[
				("Preflight", "PASS"),
				("Build", "PASS"),
				("Quality", "PASS"),
				("Benchmark tooling", "PASS"),
				("Tests", "PASS"),
				("Codegen audit", "PASS"),
				("Preview smoke", "PASS"),
				("Example checks", "PASS"),
				("Example smoke runs", "SKIP"),
				("Sanitizers", "SKIP"),
				("Docker", "SKIP"),
				("Security scan", "PASS"),
				("Drift and hygiene", "PASS"),
				("Total", "PASS"),
			],
		)
		lines = result.stdout.splitlines()
		self.assertRegex(
			lines[-1],
			r"^BLORP_GATE_RESULT gate=premerge-gate status=PASS passed=1 failed=0 tests=1$",
		)
		records = self.step_records(result.stdout)
		self.assertEqual(len(records), len(rows) - 1)
		self.assertIn(("example-smoke-runs", "SKIP", records[8][2]), records)
		last_record_line = max(index for index, line in enumerate(lines) if line.startswith("BLORP_GATE_STEP "))
		self.assertEqual(last_record_line, len(lines) - 2)

	def git(self, *args: str) -> None:
		subprocess.run(["git", "-C", str(self.repo), *args], check=True)

	def commit_change(self, name: str) -> None:
		path = self.repo / name
		path.parent.mkdir(parents=True, exist_ok=True)
		path.write_text("changed\n", encoding="utf-8")
		self.git("add", name)
		self.git("commit", "-q", "-m", f"change {name}")

	def statuses(self, output: str) -> dict[str, str]:
		return {name: status for name, status, _ in self.table_rows(output)}

	def test_documentation_change_runs_only_the_cheap_steps(self) -> None:
		self.git("update-ref", "refs/remotes/origin/main", "HEAD")
		self.commit_change("docs/GUIDE.md")
		result = self.run_gate()
		self.assertEqual(result.returncode, 0, result.stdout)
		self.assertIn("Change scope: docs-only (1 paths)", result.stdout)
		self.assertEqual(
			result.stdout.splitlines()[-1],
			"BLORP_GATE_RESULT gate=premerge-gate status=PASS passed=0 failed=0 tests=0",
		)
		statuses = self.statuses(result.stdout)
		for step in ("Preflight", "Security scan", "Drift and hygiene"):
			self.assertEqual(statuses[step], "PASS", step)
		for step in (
			"Build", "Quality", "Benchmark tooling", "Tests", "Codegen audit",
			"Preview smoke", "Example checks", "Example smoke runs", "Sanitizers", "Docker",
		):
			self.assertEqual(statuses[step], "SKIP", step)

	def test_code_change_skips_only_untouched_benchmark_tooling(self) -> None:
		self.git("update-ref", "refs/remotes/origin/main", "HEAD")
		self.commit_change("blorp/src/compiler/stage_06_typecheck/infer.brp")
		result = self.run_gate()
		self.assertEqual(result.returncode, 0, result.stdout)
		self.assertIn("Change scope: full (1 paths; benchmark tooling untouched)", result.stdout)
		statuses = self.statuses(result.stdout)
		self.assertEqual(statuses["Benchmark tooling"], "SKIP")
		self.assertEqual(statuses["Build"], "PASS")
		self.assertEqual(statuses["Tests"], "PASS")

	def test_benchmark_tooling_change_runs_the_benchmark_tooling_step(self) -> None:
		self.git("update-ref", "refs/remotes/origin/main", "HEAD")
		self.commit_change("benchmarks/bench_runner.py")
		result = self.run_gate()
		self.assertEqual(self.statuses(result.stdout)["Benchmark tooling"], "PASS")

	def test_full_flag_runs_everything_for_a_documentation_change(self) -> None:
		self.git("update-ref", "refs/remotes/origin/main", "HEAD")
		self.commit_change("docs/GUIDE.md")
		result = self.run_gate("--full")
		self.assertIn("Change scope: full (--full)", result.stdout)
		self.assertEqual(self.statuses(result.stdout)["Tests"], "PASS")
		self.assertEqual(self.statuses(result.stdout)["Benchmark tooling"], "PASS")

	def test_missing_merge_base_runs_everything(self) -> None:
		result = self.run_gate()
		self.assertIn("Change scope: full (no merge base", result.stdout)

	def test_aborted_step_is_fail_and_later_steps_are_not_listed(self) -> None:
		result = self.run_gate(fail_make_target="quality")
		self.assertNotEqual(result.returncode, 0)
		rows = self.table_rows(result.stdout)
		self.assertEqual(
			[(name, status) for name, status, _ in rows],
			[("Preflight", "PASS"), ("Build", "PASS"), ("Quality", "FAIL"), ("Total", "FAIL")],
		)
		self.assertEqual(
			[(name, status) for name, status, _ in self.step_records(result.stdout)],
			[("preflight", "PASS"), ("build", "PASS"), ("quality", "FAIL")],
		)
		self.assertRegex(result.stdout.splitlines()[-1], r"^BLORP_GATE_RESULT gate=premerge-gate status=FAIL ")

	def test_dry_run_prints_no_verdict_and_no_step_records(self) -> None:
		result = self.run_gate("--dry-run")
		self.assertEqual(result.returncode, 0, result.stdout)
		self.assertNotIn("BLORP_GATE_RESULT", result.stdout)
		self.assertEqual(self.step_records(result.stdout), [])


if __name__ == "__main__":
	unittest.main()
