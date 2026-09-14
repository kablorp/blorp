#!/usr/bin/env python3
"""Contract tests for scripts/compiler-check planning mode."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
COMPILER_CHECK = ROOT / "scripts" / "compiler-check"


class MiniCompilerCheckRepository:
	def __init__(self) -> None:
		self.temporary_directory = tempfile.TemporaryDirectory()
		self.root = Path(self.temporary_directory.name)
		self.marker = self.root / "tool-runs.log"
		self.script = self.root / "scripts/compiler-check"

	def __enter__(self) -> "MiniCompilerCheckRepository":
		(self.root / "scripts").mkdir(parents=True)
		(self.root / "bin").mkdir()
		(self.root / "blorp/src/compiler/stage_09_core").mkdir(parents=True)
		(self.root / "blorp/src/compiler/stage_06_typecheck").mkdir(parents=True)
		(self.root / "blorp/test/compiler/stage_09_core").mkdir(parents=True)
		(self.root / "blorp/test/compiler/stage_06_typecheck").mkdir(parents=True)
		shutil.copy(COMPILER_CHECK, self.script)
		self.script.chmod(0o755)
		self.write_executable("make", "printf 'make\\n' >> tool-runs.log\n")
		self.write_executable(
			"bin/blorp",
			"printf 'bin/blorp %s\\n' \"$*\" >> tool-runs.log\n",
		)
		self.write_executable(
			"scripts/test",
			"printf 'scripts/test %s\\n' \"$*\" >> tool-runs.log\n",
		)
		self.write_source("blorp/src/compiler/stage_09_core/match lowering.brp")
		self.write_source("blorp/src/compiler/stage_06_typecheck/env.brp")
		self.write_suite("blorp/test/compiler/stage_09_core/test_core_match.brp")
		self.write_suite("blorp/test/compiler/stage_06_typecheck/test_env.brp")
		self.write_manifest()
		self.git("init")
		self.git("config", "user.email", "test@example.com")
		self.git("config", "user.name", "Test User")
		self.git("add", ".")
		self.git("commit", "-m", "initial")
		return self

	def __exit__(self, *args: object) -> None:
		self.temporary_directory.cleanup()

	def write_executable(self, path: str, body: str) -> None:
		full_path = self.root / path
		full_path.parent.mkdir(parents=True, exist_ok=True)
		full_path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body, encoding="utf-8")
		full_path.chmod(0o755)

	def write_source(self, path: str, content: str = "value = 1\n") -> None:
		full_path = self.root / path
		full_path.parent.mkdir(parents=True, exist_ok=True)
		full_path.write_text(content, encoding="utf-8")

	def write_suite(self, path: str) -> None:
		(self.root / path).write_text("tests : TestSuite = test_suite(\"mini\")\n", encoding="utf-8")

	def write_manifest(self, modules: list[dict[str, object]] | None = None) -> None:
		if modules is None:
			modules = [
				{
					"path": "blorp/src/compiler/stage_09_core/match lowering.brp",
					"stage": "core",
					"suites": ["test_core_match"],
					"checks": ["compiler-core-sanitize"],
					"broad_gate": "compiler-blorp",
				},
				{
					"path": "blorp/src/compiler/stage_06_typecheck/env.brp",
					"stage": "typecheck",
					"suites": ["test_env"],
					"checks": [],
					"broad_gate": "compiler-blorp",
				},
			]
		manifest = {
			"schema_version": 1,
			"stages": ["core", "typecheck"],
			"suites": [
				{
					"id": "test_core_match",
					"path": "blorp/test/compiler/stage_09_core/test_core_match.brp",
				},
				{
					"id": "test_env",
					"path": "blorp/test/compiler/stage_06_typecheck/test_env.brp",
				},
			],
			"checks": [
				{"id": "compiler-core-sanitize", "path": "scripts/test", "gate": "compiler-core-sanitize"}
			],
			"broad_gates": [
				{"id": "compiler-blorp", "path": "scripts/test", "gate": "compiler-blorp"}
			],
			"modules": modules,
		}
		manifest_path = self.root / "blorp/test/compiler/compiler_test_ownership.json"
		manifest_path.parent.mkdir(parents=True, exist_ok=True)
		manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

	def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
		return subprocess.run(
			["git", *arguments],
			cwd=self.root,
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=True,
		)

	def run(self, *arguments: str) -> subprocess.CompletedProcess[str]:
		environment = os.environ.copy()
		environment["PATH"] = f"{self.root}{os.pathsep}{environment['PATH']}"
		return subprocess.run(
			[sys.executable, str(self.script), *arguments],
			cwd=self.root,
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			env=environment,
			check=False,
		)


class CompilerCheckPlanTests(unittest.TestCase):
	def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
		self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

	def test_plan_for_changed_module_reports_same_selection_without_running_tools(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			repo.write_source("blorp/src/compiler/stage_09_core/match lowering.brp", "value = 2\n")

			plan = repo.run("--changed", "--plan")
			self.assert_success(plan)

			self.assertIn("Mode: plan only", plan.stdout)
			self.assertIn("Changed production source: 'blorp/src/compiler/stage_09_core/match lowering.brp'", plan.stdout)
			self.assertIn("owner stage: core", plan.stdout)
			self.assertIn("focused suite: blorp/test/compiler/stage_09_core/test_core_match.brp", plan.stdout)
			self.assertIn("selected special check: compiler-core-sanitize", plan.stdout)
			self.assertIn(
				"Focused action: make; bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_match.brp; scripts/test --no-build --serial compiler-core-sanitize",
				plan.stdout,
			)
			self.assertIn("Recommended additional gate: scripts/test compiler-blorp", plan.stdout)
			self.assertIn("Reason: manifest broad_gate", plan.stdout)
			self.assertFalse(repo.marker.exists())
			self.assertFalse((repo.root / "logs").exists())

			run = repo.run("--changed")
			self.assert_success(run)
			self.assertIn("make", repo.marker.read_text(encoding="utf-8"))
			self.assertIn("bin/blorp test --timeout 180", repo.marker.read_text(encoding="utf-8"))
			self.assertIn("scripts/test --no-build --serial", repo.marker.read_text(encoding="utf-8"))

	def test_execution_failure_retains_selection_logs_and_exact_rerun(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			repo.write_executable(
				"bin/blorp",
				(
					"printf 'bin/blorp %s\\n' \"$*\" >> tool-runs.log\n"
					"printf 'suite failed\\n'\n"
					"exit 7\n"
				),
			)
			repo.write_source("blorp/src/compiler/stage_09_core/match lowering.brp", "value = 6\n")

			result = repo.run("--changed")

			self.assertEqual(result.returncode, 7)
			self.assertIn("Compiler check failed with status 7.", result.stderr)
			self.assertIn("Rerun: scripts/compiler-check --changed", result.stderr)
			retained_line = next(
				line for line in result.stderr.splitlines() if line.startswith("Logs retained at: ")
			)
			log_directory = repo.root / retained_line.removeprefix("Logs retained at: ")
			self.assertTrue(log_directory.is_dir())
			self.assertEqual(
				json.loads((log_directory / "selection.json").read_text(encoding="utf-8")),
				{
					"schema_version": 1,
					"sources": ["blorp/src/compiler/stage_09_core/match lowering.brp"],
					"suites": ["blorp/test/compiler/stage_09_core/test_core_match.brp"],
					"checks": ["compiler-core-sanitize"],
				},
			)
			self.assertEqual(
				(log_directory / "rerun.txt").read_text(encoding="utf-8"),
				"scripts/compiler-check --changed\n",
			)
			metadata = json.loads((log_directory / "metadata.json").read_text(encoding="utf-8"))
			self.assertEqual(metadata["command"], "scripts/compiler-check --changed")
			self.assertIn("suite failed", (log_directory / "suites.log").read_text(encoding="utf-8"))

	def test_plan_for_directly_changed_suite_selects_itself(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			(repo.root / "blorp/test/compiler/stage_09_core/test_core_match.brp").write_text(
				"tests : TestSuite = test_suite(\"changed\")\n",
				encoding="utf-8",
			)

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Changed test: blorp/test/compiler/stage_09_core/test_core_match.brp", result.stdout)
			self.assertIn("Focused action: make; bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_match.brp", result.stdout)
			self.assertNotIn("Recommended additional gate:", result.stdout)
			self.assertFalse(repo.marker.exists())

	def test_changed_plan_covers_staged_unstaged_untracked_and_base_changes(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			base_branch = repo.git("branch", "--show-current").stdout.strip()
			repo.git("checkout", "-b", "feature")
			repo.write_source("blorp/src/compiler/stage_06_typecheck/env.brp", "value = 3\n")
			repo.git("commit", "-am", "committed change")
			repo.write_source("blorp/src/compiler/stage_09_core/match lowering.brp", "value = 4\n")
			repo.write_source("blorp/test/compiler/stage_09_core/test_core_match.brp", "tests : TestSuite = test_suite(\"changed\")\n")
			repo.git("add", "blorp/test/compiler/stage_09_core/test_core_match.brp")
			repo.write_source("blorp/src/compiler/stage_06_typecheck/new_untracked.brp")
			modules = [
				{
					"path": "blorp/src/compiler/stage_09_core/match lowering.brp",
					"stage": "core",
					"suites": ["test_core_match"],
					"checks": ["compiler-core-sanitize"],
					"broad_gate": "compiler-blorp",
				},
				{
					"path": "blorp/src/compiler/stage_06_typecheck/env.brp",
					"stage": "typecheck",
					"suites": ["test_env"],
					"checks": [],
					"broad_gate": "compiler-blorp",
				},
				{
					"path": "blorp/src/compiler/stage_06_typecheck/new_untracked.brp",
					"stage": "typecheck",
					"suites": ["test_env"],
					"checks": [],
					"broad_gate": "compiler-blorp",
				},
			]
			repo.write_manifest(modules)

			result = repo.run("--changed", "--base", base_branch, "--plan")
			self.assert_success(result)

			self.assertIn("Changed production source: 'blorp/src/compiler/stage_09_core/match lowering.brp'", result.stdout)
			self.assertIn("Changed production source: blorp/src/compiler/stage_06_typecheck/env.brp", result.stdout)
			self.assertIn("Changed production source: blorp/src/compiler/stage_06_typecheck/new_untracked.brp", result.stdout)
			self.assertIn("Changed test: blorp/test/compiler/stage_09_core/test_core_match.brp", result.stdout)
			self.assertIn("focused suite: blorp/test/compiler/stage_06_typecheck/test_env.brp", result.stdout)

	def test_plan_noop_is_explicit_for_no_changes_docs_and_bootstrap_only(self) -> None:
		for path in (None, "docs/README.md", "blorp/build/bootstrap.env"):
			with self.subTest(path=path), MiniCompilerCheckRepository() as repo:
				if path is not None:
					target = repo.root / path
					target.parent.mkdir(parents=True, exist_ok=True)
					target.write_text("changed\n", encoding="utf-8")

				result = repo.run("--changed", "--plan")
				self.assert_success(result)

				self.assertIn("Selected 0 production sources, 0 suites, 0 special checks.", result.stdout)
				self.assertIn("This is a no-op, not a passing validation", result.stdout)
				self.assertIn("task-specific build/docs/release checks", result.stdout)
				self.assertFalse(repo.marker.exists())

	def test_unowned_production_module_and_unknown_inputs_are_errors(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			repo.write_source("blorp/src/compiler/stage_09_core/unowned.brp")
			result = repo.run("--changed", "--plan")

			self.assertEqual(result.returncode, 2)
			self.assertIn("unowned production Blorp module", result.stderr)
			self.assertIn("blorp/test/compiler/compiler_test_ownership.json", result.stderr)
			self.assertIn("scripts/compiler-check --validate-manifest", result.stderr)

		with MiniCompilerCheckRepository() as repo:
			result = repo.run("--stage", "missing", "--plan")
			self.assertNotEqual(result.returncode, 0)
			self.assertIn("unknown stage 'missing'", result.stderr)

		with MiniCompilerCheckRepository() as repo:
			result = repo.run("blorp/test/compiler/missing.brp", "--plan")
			self.assertNotEqual(result.returncode, 0)
			self.assertIn("unknown suite", result.stderr)

	def test_plan_json_matches_human_selection(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			repo.write_source("blorp/src/compiler/stage_09_core/match lowering.brp", "value = 5\n")

			human = repo.run("--changed", "--plan")
			json_result = repo.run("--changed", "--plan", "--json")
			self.assert_success(human)
			self.assert_success(json_result)

			payload = json.loads(json_result.stdout)
			self.assertEqual(payload["schema_version"], 1)
			self.assertEqual(payload["mode"], "plan")
			self.assertEqual(
				payload["selection"]["sources"],
				["blorp/src/compiler/stage_09_core/match lowering.brp"],
			)
			self.assertEqual(
				payload["selection"]["suites"],
				["blorp/test/compiler/stage_09_core/test_core_match.brp"],
			)
			self.assertEqual(payload["selection"]["checks"], ["compiler-core-sanitize"])
			self.assertEqual(payload["recommendations"], ["scripts/test compiler-blorp"])
			self.assertIn(payload["selection"]["sources"][0], human.stdout)
			self.assertIn(payload["selection"]["suites"][0], human.stdout)
			self.assertIn(payload["selection"]["checks"][0], human.stdout)

	def test_plan_help_exposes_manifest_validation(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			result = repo.run("--help")
			self.assert_success(result)

			self.assertIn("--validate-manifest", result.stdout)
			self.assertIn("validate ownership manifest", result.stdout)


if __name__ == "__main__":
	unittest.main()
