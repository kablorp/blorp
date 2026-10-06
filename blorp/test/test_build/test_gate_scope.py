#!/usr/bin/env python3
"""Contract tests for scripts/gate-scope, which picks the premerge gate's steps."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
GATE_SCOPE_SCRIPT = ROOT / "scripts" / "gate-scope"


def load_gate_scope():
	loader = importlib.machinery.SourceFileLoader("gate_scope", str(GATE_SCOPE_SCRIPT))
	spec = importlib.util.spec_from_loader("gate_scope", loader)
	module = importlib.util.module_from_spec(spec)
	# dataclasses looks its module up in sys.modules.
	sys.modules["gate_scope"] = module
	loader.exec_module(module)
	return module


gate_scope = load_gate_scope()
Scope = gate_scope.Scope
BenchmarkTooling = gate_scope.BenchmarkTooling
POLICY_INPUTS = gate_scope.benchmark_policy_inputs(ROOT)


def classify(paths, full_requested=False):
	return gate_scope.classify(paths, POLICY_INPUTS, full_requested)


class ClassifyTest(unittest.TestCase):
	def test_documentation_only_change_skips_the_build_and_tests(self) -> None:
		result = classify(["docs/GUIDE.md", "README.md", "docs/issues/anything.json", "blorp/src/NOTES.md"])
		self.assertEqual(result.scope, Scope.DOCS_ONLY)
		self.assertEqual(result.benchmark_tooling, BenchmarkTooling.SKIP)
		self.assertEqual(result.summary, "docs-only (4 paths)")

	def test_documentation_plus_one_source_file_is_full(self) -> None:
		result = classify(["docs/GUIDE.md", "blorp/src/compiler/stage_06_typecheck/infer.brp"])
		self.assertEqual(result.scope, Scope.FULL)
		self.assertEqual(result.benchmark_tooling, BenchmarkTooling.SKIP)

	def test_unknown_path_is_full(self) -> None:
		result = classify(["some/new/directory/file.xyz"])
		self.assertEqual(result.scope, Scope.FULL)

	def test_benchmark_tooling_paths_run_the_benchmark_tooling_suites(self) -> None:
		touched = [
			"benchmarks/bench_runner.py",
			"blorp/benchmark/compiler/compiler_typecheck_worker.brp",
			"scripts/bench-blorp-test-session",
			"scripts/with-build-lock",
			"blorp/src/test/session.brp",
			"blorp/src/compiler/stage_09_core/perceus.brp",
			"blorp/test/test_compiler/test_benchmark/test_backend_memory.py",
			"blorp/test/test_test/test_session_benchmark.py",
			"standard_library/src/bytes.brp",
			"blorp/test/test_runtime/test_types/test_bool.brp",
		]
		for path in touched:
			with self.subTest(path=path):
				result = classify(["blorp/src/compiler/stage_06_typecheck/infer.brp", path])
				self.assertEqual(result.scope, Scope.FULL)
				self.assertEqual(result.benchmark_tooling, BenchmarkTooling.RUN)

	def test_recorded_benchmark_results_are_data_not_tooling(self) -> None:
		result = classify(["benchmarks/results/typecheck_2026-10-06.json"])
		self.assertEqual(result.scope, Scope.FULL)
		self.assertEqual(result.benchmark_tooling, BenchmarkTooling.SKIP)

	def test_compiler_test_tree_is_not_a_benchmark_tooling_input(self) -> None:
		result = classify(["blorp/test/test_compiler/test_stage_09_core/test_core_match.brp"])
		self.assertEqual(result.benchmark_tooling, BenchmarkTooling.SKIP)

	def test_documentation_beside_benchmark_tooling_runs_the_suites(self) -> None:
		result = classify(["docs/GUIDE.md", "benchmarks/bench_runner.py"])
		self.assertEqual(result.scope, Scope.FULL)
		self.assertEqual(result.benchmark_tooling, BenchmarkTooling.RUN)

	def test_missing_merge_base_runs_everything(self) -> None:
		result = classify(None)
		self.assertEqual(result.scope, Scope.FULL)
		self.assertEqual(result.benchmark_tooling, BenchmarkTooling.RUN)
		self.assertIn("no merge base", result.summary)

	def test_forced_full_ignores_documentation_only_paths(self) -> None:
		result = classify(["docs/GUIDE.md"], full_requested=True)
		self.assertEqual(result.scope, Scope.FULL)
		self.assertEqual(result.benchmark_tooling, BenchmarkTooling.RUN)

	def test_no_changed_paths_runs_everything(self) -> None:
		result = classify([])
		self.assertEqual(result.scope, Scope.FULL)
		self.assertEqual(result.benchmark_tooling, BenchmarkTooling.RUN)

	def test_docs_only_scope_cannot_run_benchmark_tooling(self) -> None:
		with self.assertRaises(ValueError):
			gate_scope.Classification(Scope.DOCS_ONLY, BenchmarkTooling.RUN, "docs-only")


class RuleReferencesExistTest(unittest.TestCase):
	def test_every_named_tooling_path_exists(self) -> None:
		for path in sorted(gate_scope.BENCHMARK_TOOLING_PATHS):
			with self.subTest(path=path):
				self.assertTrue((ROOT / path).exists(), f"{path} is named by the rules but does not exist")

	def test_every_benchmark_policy_input_exists(self) -> None:
		for path in POLICY_INPUTS:
			with self.subTest(path=path):
				self.assertTrue((ROOT / path).exists(), f"{path} is a policy input but does not exist")


class ChangedPathsTest(unittest.TestCase):
	"""Runs against a scratch repository whose `origin/main` is a local ref."""

	def setUp(self) -> None:
		self.directory = tempfile.TemporaryDirectory()
		self.addCleanup(self.directory.cleanup)
		self.repo = Path(self.directory.name)
		self.git("init", "-q", "-b", "main")
		self.git("config", "user.email", "test@example.com")
		self.git("config", "user.name", "Test")
		self.commit("base.txt", "base\n")

	def git(self, *args: str) -> str:
		return subprocess.run(
			["git", "-C", str(self.repo), *args],
			check=True,
			stdout=subprocess.PIPE,
			text=True,
		).stdout

	def commit(self, name: str, text: str) -> None:
		path = self.repo / name
		path.parent.mkdir(parents=True, exist_ok=True)
		path.write_text(text, encoding="utf-8")
		self.git("add", name)
		self.git("commit", "-q", "-m", f"add {name}")

	def mark_origin_main(self) -> None:
		self.git("update-ref", "refs/remotes/origin/main", "HEAD")

	def test_without_origin_main_there_is_no_merge_base(self) -> None:
		self.assertIsNone(gate_scope.changed_paths(self.repo, gate_scope.DEFAULT_BASE_REFS))

	def test_committed_staged_unstaged_and_untracked_changes_all_count(self) -> None:
		self.mark_origin_main()
		self.commit("docs/committed.md", "committed\n")
		(self.repo / "base.txt").write_text("edited\n", encoding="utf-8")
		(self.repo / "docs/staged.md").write_text("staged\n", encoding="utf-8")
		self.git("add", "docs/staged.md")
		(self.repo / "untracked.brp").write_text("x\n", encoding="utf-8")
		paths = gate_scope.changed_paths(self.repo, gate_scope.DEFAULT_BASE_REFS)
		self.assertEqual(paths, ["base.txt", "docs/committed.md", "docs/staged.md", "untracked.brp"])

	def test_a_move_lists_both_sides(self) -> None:
		self.mark_origin_main()
		(self.repo / "docs").mkdir()
		self.git("mv", "base.txt", "docs/base.md")
		paths = gate_scope.changed_paths(self.repo, gate_scope.DEFAULT_BASE_REFS)
		self.assertEqual(paths, ["base.txt", "docs/base.md"])

	def test_the_remote_gate_base_ref_is_used_when_origin_main_is_missing(self) -> None:
		self.git("update-ref", "refs/blorp-docker-gate-base/main", "HEAD")
		self.commit("docs/new.md", "new\n")
		paths = gate_scope.changed_paths(self.repo, gate_scope.DEFAULT_BASE_REFS)
		self.assertEqual(paths, ["docs/new.md"])

	def test_script_prints_the_scope_for_a_documentation_change(self) -> None:
		policy = self.repo / gate_scope.BENCHMARK_POLICY
		policy.parent.mkdir(parents=True, exist_ok=True)
		policy.write_text('{"workloads": {}}\n', encoding="utf-8")
		self.git("add", gate_scope.BENCHMARK_POLICY)
		self.git("commit", "-q", "-m", "policy")
		self.mark_origin_main()
		self.commit("docs/new.md", "new\n")
		self.commit("README.md", "readme\n")
		output = subprocess.run(
			[str(GATE_SCOPE_SCRIPT), "--root", str(self.repo)],
			check=True,
			stdout=subprocess.PIPE,
			text=True,
		).stdout
		self.assertEqual(
			output.splitlines(),
			["scope=docs-only", "benchmark_tooling=skip", "summary=docs-only (2 paths)"],
		)


if __name__ == "__main__":
	unittest.main()
