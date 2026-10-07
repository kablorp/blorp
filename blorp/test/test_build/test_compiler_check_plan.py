#!/usr/bin/env python3
"""Contract tests for scripts/compiler-check planning mode."""

from __future__ import annotations

import importlib.machinery
import importlib.util
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


def load_script(name: str, script: str):
	loader = importlib.machinery.SourceFileLoader(name, str(ROOT / "scripts" / script))
	spec = importlib.util.spec_from_loader(loader.name, loader)
	module = importlib.util.module_from_spec(spec)
	sys.modules[loader.name] = module
	loader.exec_module(module)
	return module


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
		(self.root / "blorp/test/test_compiler/test_stage_09_core").mkdir(parents=True)
		(self.root / "blorp/test/test_compiler/test_stage_06_typecheck").mkdir(parents=True)
		shutil.copy(COMPILER_CHECK, self.script)
		shutil.copy(COMPILER_CHECK.with_name("blorp_import_graph.py"), self.root / "scripts/blorp_import_graph.py")
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
		self.write_suite("blorp/test/test_compiler/test_stage_09_core/test_core_match.brp")
		self.write_suite("blorp/test/test_compiler/test_stage_06_typecheck/test_env.brp")
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

	def write_suite_path(self, path: str) -> None:
		full_path = self.root / path
		full_path.parent.mkdir(parents=True, exist_ok=True)
		self.write_suite(path)

	def write_suite(self, path: str) -> None:
		(self.root / path).write_text("tests : TestSuite = test_suite(\"mini\")\n", encoding="utf-8")

	def write_manifest(
		self,
		modules: list[dict[str, object]] | None = None,
		extra_suites: list[dict[str, object]] | None = None,
	) -> None:
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
					"path": "blorp/test/test_compiler/test_stage_09_core/test_core_match.brp",
				},
				{
					"id": "test_env",
					"path": "blorp/test/test_compiler/test_stage_06_typecheck/test_env.brp",
				},
				*(extra_suites or []),
			],
			"checks": [
				{"id": "compiler-core-sanitize", "path": "scripts/test", "gate": "compiler-core-sanitize"}
			],
			"broad_gates": [
				{"id": "compiler-blorp", "path": "scripts/test", "gate": "compiler-blorp"},
				{"id": "compiler-new-parity", "path": "scripts/test", "gate": "compiler-new-parity"},
			],
			"modules": modules,
		}
		manifest_path = self.root / "blorp/test/test_compiler/compiler_test_ownership.json"
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
		# The plan's expected `--timeout` is compiler-check's default; a gate
		# runner such as docker-gate must not change what this test sees.
		environment.pop("BLORP_COMPILER_TEST_TIMEOUT", None)
		return subprocess.run(
			[sys.executable, str(self.script), *arguments],
			cwd=self.root,
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			env=environment,
			check=False,
		)


DISCOVERY_SOURCES = "blorp/src/compiler_new/stage_01_discovery"
PARSE_SOURCES = f"{DISCOVERY_SOURCES}/parse"
COMPILER_NEW_TESTS = "blorp/test/test_compiler_new/test_stage_01_discovery"
TREE_PROJECTION = "blorp/src/compiler/discovery_tree_projection.brp"
ADAPTER_SUITE = "blorp/test/test_compiler/test_stage_04_modules/test_discovery_adapter.brp"
TREE_SUITE = "blorp/test/test_compiler/test_stage_04_modules/test_tree_body_projection.brp"
COMPARISON_TOOL = "blorp/test/test_compiler/tools/discovery_adapter_comparison.brp"
FORMATTER = "blorp/src/format/engine/formatter.brp"
SHARED_WITH_FORMATTER = f"{PARSE_SOURCES}/tree_shared_with_formatter.brp"
ENV_SUITE = "blorp/test/test_compiler/test_stage_06_typecheck/test_env.brp"
ENV_USER_SUITE = "blorp/test/test_compiler/test_stage_06_typecheck/test_env_user.brp"
PRODUCTION_PARSER = "blorp/src/compiler/stage_03_parse/language_parser.brp"
PARITY_TESTS = "blorp/test/test_build/test_compiler_new_parity.py"
CHECKED_MARKER = "-- RUN-BLORP-CHECK"

IMPORT_TREE_PROJECTION = "import:\n\t../../../src/compiler/discovery_tree_projection: project\n\n"


class TreePathRepository(MiniCompilerCheckRepository):
	"""The mini repository plus a production graph and a tree path beside it.

	`main.brp` reaches the old parser, the front end, the adapter, the body
	parser and the lexer. The tree parser, the tree projection and what they
	import are reached by nothing in production; the adapter suite imports the
	tree projection.
	"""

	def __enter__(self) -> "TreePathRepository":
		super().__enter__()
		graph = {
			"blorp/src/main.brp": [
				"compiler/discovery_front_end",
				"compiler/stage_03_parse/language_parser",
				"compiler_new/stage_01_discovery/parse/body_parser",
				"compiler_new/stage_01_discovery/lex/lexer",
			],
			"blorp/src/compiler/discovery_front_end.brp": ["discovery_adapter"],
			"blorp/src/compiler/discovery_adapter.brp": [],
			PRODUCTION_PARSER: [],
			f"{PARSE_SOURCES}/body_parser.brp": [],
			f"{DISCOVERY_SOURCES}/lex/lexer.brp": [],
			TREE_PROJECTION: ["../compiler_new/stage_01_discovery/parse/tree_body_parser"],
			f"{PARSE_SOURCES}/tree_body_parser.brp": ["stop_reason", "recipes"],
			f"{PARSE_SOURCES}/tree_type_parser.brp": [],
			f"{PARSE_SOURCES}/stop_reason.brp": [],
			f"{PARSE_SOURCES}/recipes.brp": [],
			# A second program's entry, which `main.brp` does not import, and a
			# parse module only it reaches.
			FORMATTER: ["../../compiler_new/stage_01_discovery/parse/tree_shared_with_formatter"],
			SHARED_WITH_FORMATTER: [],
		}
		for path, imports in graph.items():
			self.write_source(path, self.module_text(imports))
		self.write_source("standard_library/src/prelude.brp")
		self.write_source("scripts/compiler-new-parity")
		self.write_source(f"{COMPILER_NEW_TESTS}/test_parse/test_tree_body_parser.brp")
		self.write_source(
			f"{COMPILER_NEW_TESTS}/test_parse/fixtures/should_fail/marked.brp",
			f"{CHECKED_MARKER}\nvalue = 1\n",
		)
		self.write_source(
			f"{COMPILER_NEW_TESTS}/test_parse/fixtures/should_fail/unmarked.brp", "value = 1\n"
		)
		self.write_source(
			ADAPTER_SUITE,
			IMPORT_TREE_PROJECTION + "tests : TestSuite = test_suite(\"adapter\")\n",
		)
		self.write_source(COMPARISON_TOOL, IMPORT_TREE_PROJECTION)
		self.write_source(
			TREE_SUITE,
			"import:\n\t../tools/discovery_adapter_comparison\n\ntests : TestSuite = test_suite(\"tree\")\n",
		)
		self.write_source(ENV_USER_SUITE, "import:\n\ttest_env\n\ntests : TestSuite = test_suite(\"user\")\n")
		self.write_manifest(
			[
				*self.default_modules(),
				self.module_entry(FORMATTER, ["test_env"]),
				self.module_entry("blorp/src/compiler/discovery_adapter.brp", ["test_env"]),
				self.module_entry("blorp/src/compiler/discovery_front_end.brp", ["test_env"]),
				self.module_entry(PRODUCTION_PARSER, ["test_env"]),
				self.module_entry("blorp/src/main.brp", ["test_env"]),
				self.module_entry(TREE_PROJECTION, ["test_discovery_adapter", "test_tree_body_projection"], "compiler-new-parity"),
			],
			extra_suites=[
				{"id": "test_discovery_adapter", "path": ADAPTER_SUITE},
				{"id": "test_tree_body_projection", "path": TREE_SUITE},
				{"id": "test_env_user", "path": ENV_USER_SUITE},
			],
		)
		self.git("add", ".")
		self.git("commit", "-m", "tree path fixture")
		return self

	@staticmethod
	def module_text(imports: list[str]) -> str:
		if not imports:
			return "value = 1\n"
		lines = "".join(f"\t{spelling}\n" for spelling in imports)
		return f"import:\n{lines}\nvalue = 1\n"

	@staticmethod
	def module_entry(path: str, suites: list[str], broad_gate: str = "compiler-blorp") -> dict[str, object]:
		return {"path": path, "stage": "typecheck", "suites": suites, "checks": [], "broad_gate": broad_gate}

	@staticmethod
	def default_modules() -> list[dict[str, object]]:
		return [
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
				"suites": ["test_env", "test_env_user"],
				"checks": [],
				"broad_gate": "compiler-blorp",
			},
		]


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
			self.assertIn("focused suite: blorp/test/test_compiler/test_stage_09_core/test_core_match.brp", plan.stdout)
			self.assertIn("selected special check: compiler-core-sanitize", plan.stdout)
			self.assertIn(
				"Focused action: make; bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_match.brp; scripts/test --no-build --serial compiler-core-sanitize",
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
					"suites": ["blorp/test/test_compiler/test_stage_09_core/test_core_match.brp"],
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
			(repo.root / "blorp/test/test_compiler/test_stage_09_core/test_core_match.brp").write_text(
				"tests : TestSuite = test_suite(\"changed\")\n",
				encoding="utf-8",
			)

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Changed test: blorp/test/test_compiler/test_stage_09_core/test_core_match.brp", result.stdout)
			self.assertIn("Focused action: make; bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_match.brp", result.stdout)
			self.assertNotIn("Recommended additional gate:", result.stdout)
			self.assertFalse(repo.marker.exists())

	def test_changed_plan_covers_staged_unstaged_untracked_and_base_changes(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			base_branch = repo.git("branch", "--show-current").stdout.strip()
			repo.git("checkout", "-b", "feature")
			repo.write_source("blorp/src/compiler/stage_06_typecheck/env.brp", "value = 3\n")
			repo.git("commit", "-am", "committed change")
			repo.write_source("blorp/src/compiler/stage_09_core/match lowering.brp", "value = 4\n")
			repo.write_source("blorp/test/test_compiler/test_stage_09_core/test_core_match.brp", "tests : TestSuite = test_suite(\"changed\")\n")
			repo.git("add", "blorp/test/test_compiler/test_stage_09_core/test_core_match.brp")
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
			self.assertIn("Changed test: blorp/test/test_compiler/test_stage_09_core/test_core_match.brp", result.stdout)
			self.assertIn("focused suite: blorp/test/test_compiler/test_stage_06_typecheck/test_env.brp", result.stdout)

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
			self.assertIn("blorp/test/test_compiler/compiler_test_ownership.json", result.stderr)
			self.assertIn("scripts/compiler-check --validate-manifest", result.stderr)

		with MiniCompilerCheckRepository() as repo:
			result = repo.run("--stage", "missing", "--plan")
			self.assertNotEqual(result.returncode, 0)
			self.assertIn("unknown stage 'missing'", result.stderr)

		with MiniCompilerCheckRepository() as repo:
			result = repo.run("blorp/test/test_compiler/missing.brp", "--plan")
			self.assertNotEqual(result.returncode, 0)
			self.assertIn("unknown suite", result.stderr)

	def test_manifest_validation_rejects_suite_hidden_in_fixture_directory(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			hidden_suite = (
				"blorp/test/test_compiler/test_stage_06_typecheck/fixtures/typecheck/"
				"should_pass/test_hidden.brp"
			)
			repo.write_suite_path(hidden_suite)

			validation = repo.run("--validate-manifest")
			self.assertEqual(validation.returncode, 2)
			self.assertIn("executable Blorp suite in fixture directory", validation.stderr)
			self.assertIn(hidden_suite, validation.stderr)

	def test_manifest_validation_ignores_commented_suite_text_in_fixture(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			repo.write_source(
				"blorp/test/test_compiler/test_stage_06_typecheck/fixtures/typecheck/"
				"should_pass/comment_only.brp",
				"-- tests: TestSuite = this is a comment, not an executable suite\n",
			)

			validation = repo.run("--validate-manifest")
			self.assert_success(validation)

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
				["blorp/test/test_compiler/test_stage_09_core/test_core_match.brp"],
			)
			self.assertEqual(payload["selection"]["checks"], ["compiler-core-sanitize"])
			self.assertEqual(payload["recommendations"], ["scripts/test compiler-blorp"])
			self.assertIn(payload["selection"]["sources"][0], human.stdout)
			self.assertIn(payload["selection"]["suites"][0], human.stdout)
			self.assertIn(payload["selection"]["checks"][0], human.stdout)

	def test_tree_path_only_change_hands_back_the_suites_importing_it_and_the_tree_gates(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_body_parser.brp", "value = 2\n")
			repo.write_source(f"{PARSE_SOURCES}/recipes.brp", "value = 2\n")
			repo.write_source(f"{COMPILER_NEW_TESTS}/test_parse/test_tree_body_parser.brp", "value = 2\n")
			repo.write_source("scripts/compiler-new-parity", "value = 2\n")
			repo.write_source("docs/DISCOVERY_REDESIGN.md", "notes\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: tree path only", result.stdout)
			self.assertIn(
				f"scripts/compiler-build-status --quiet; bin/blorp test --timeout 180 {ADAPTER_SUITE} {TREE_SUITE}; "
				f"python3 -m unittest {PARITY_TESTS}; "
				"scripts/test --no-build compiler-new compiler-new-parity",
				result.stdout,
			)
			self.assertNotIn("Hand-back gates: broad", result.stdout)
			self.assertNotIn("Recommended additional gate", result.stdout)
			self.assertFalse(repo.marker.exists())

	def test_a_changed_tree_projection_module_hands_back_its_owned_suites_and_its_manifest_gate(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(TREE_PROJECTION, "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: tree path only", result.stdout)
			self.assertIn(f"bin/blorp test --timeout 180 {ADAPTER_SUITE}", result.stdout)
			# The manifest owns the module and names compiler-new-parity, whose adapter
			# differential runs the projection, as its broad gate; the test_compiler_new
			# suites never import it.
			self.assertIn("Recommended additional gate: scripts/test compiler-new-parity\n", result.stdout)
			self.assertNotIn("scripts/test compiler-blorp", result.stdout)

	def test_a_change_confined_to_compiler_new_tests_needs_no_suite_run(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{COMPILER_NEW_TESTS}/test_parse/fixtures/should_fail/unmarked.brp", "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back action: scripts/compiler-build-status --quiet; scripts/test --no-build compiler-new compiler-new-parity", result.stdout)

	def test_old_parser_change_selects_compiler_blorp_and_no_tree_hand_back(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(PRODUCTION_PARSER, "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn(f"Changed production source: {PRODUCTION_PARSER}", result.stdout)
			self.assertIn("Recommended additional gate: scripts/test compiler-blorp", result.stdout)
			self.assertNotIn("Hand-back gates", result.stdout)

	def test_adapter_change_alone_is_not_tree_path(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source("blorp/src/compiler/discovery_adapter.brp", "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Recommended additional gate: scripts/test compiler-blorp", result.stdout)
			self.assertNotIn("Hand-back gates", result.stdout)

	def test_discovery_code_production_runs_selects_the_broad_gates(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{DISCOVERY_SOURCES}/lex/lexer.brp", "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn(f"outside the tree path: {DISCOVERY_SOURCES}/lex/lexer.brp", result.stdout)
			self.assertIn("scripts/test compiler-new compiler-new-parity compiler-blorp", result.stdout)

	def test_mixed_change_set_selects_the_broad_gates_and_names_the_production_paths(self) -> None:
		for production_path in (
			PRODUCTION_PARSER,
			"blorp/src/compiler/discovery_adapter.brp",
			f"{DISCOVERY_SOURCES}/lex/lexer.brp",
			f"{PARSE_SOURCES}/body_parser.brp",
			"standard_library/src/prelude.brp",
			"Makefile",
		):
			with self.subTest(production_path=production_path), TreePathRepository() as repo:
				repo.write_source(f"{PARSE_SOURCES}/tree_body_parser.brp", "value = 2\n")
				repo.write_source(production_path, "value = 2\n")

				result = repo.run("--changed", "--plan")
				self.assert_success(result)

				self.assertIn("Hand-back gates: broad", result.stdout)
				self.assertIn(f"outside the tree path: {production_path}", result.stdout)
				self.assertIn("scripts/test compiler-new compiler-new-parity compiler-blorp", result.stdout)
				self.assertNotIn("tree path only", result.stdout)

	def test_a_program_entry_other_than_main_is_production(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(FORMATTER, "value = 2\n")

			alone = repo.run("--changed", "--plan")
			self.assert_success(alone)
			self.assertNotIn("tree path only", alone.stdout)
			self.assertIn("Recommended additional gate: scripts/test compiler-blorp", alone.stdout)

			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "value = 2\n")
			mixed = repo.run("--changed", "--plan")
			self.assert_success(mixed)
			self.assertIn("Hand-back gates: broad", mixed.stdout)
			self.assertIn(f"outside the tree path: {FORMATTER}", mixed.stdout)
			self.assertIn("Recommended additional gate: scripts/test compiler-blorp", mixed.stdout)

	def test_a_discovery_module_only_another_program_imports_is_production(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(SHARED_WITH_FORMATTER, "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn(f"outside the tree path: {SHARED_WITH_FORMATTER}", result.stdout)

	def test_suites_importing_a_changed_tree_path_tool_are_handed_back(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(COMPARISON_TOOL, IMPORT_TREE_PROJECTION + "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: tree path only", result.stdout)
			self.assertIn(TREE_SUITE, result.stdout)

	def test_suites_importing_a_changed_test_file_run_with_it(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(ENV_SUITE, "tests : TestSuite = test_suite(\"changed\")\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			focused = next(line for line in result.stdout.splitlines() if line.startswith("Focused action:"))
			self.assertIn(ENV_SUITE, focused)
			self.assertIn(ENV_USER_SUITE, focused)

	def test_a_module_production_reaches_is_production_whatever_its_name(self) -> None:
		with TreePathRepository() as repo:
			# A whole-module import, naming nothing, still puts the module in production.
			repo.write_source(f"{PARSE_SOURCES}/body_parser.brp", "import:\n\tstop_reason\n\nvalue = 1\n")
			repo.git("add", ".")
			repo.git("commit", "-m", "production reaches the tree support module")
			repo.write_source(f"{PARSE_SOURCES}/stop_reason.brp", "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn(f"outside the tree path: {PARSE_SOURCES}/stop_reason.brp", result.stdout)

	def test_a_module_the_graph_cannot_resolve_is_production(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "import:\n\tno_such_module\n\nvalue = 1\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)

	def test_when_production_imports_do_not_all_resolve_nothing_is_tree_path(self) -> None:
		with TreePathRepository() as repo:
			# A generated module that has not been built: what production reaches is unknown.
			repo.write_source("blorp/src/main.brp", "import:\n\tgenerated_not_built\n\nvalue = 1\n")
			repo.git("add", ".")
			repo.git("commit", "-m", "main imports an unbuilt module")
			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "value = 2\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn(
				"tree path not provable: blorp/src/main.brp imports generated_not_built, "
				"which does not resolve; run make",
				result.stdout,
			)
			unprovable = json.loads(repo.run("--changed", "--plan", "--json").stdout)["hand_back"]["unprovable"]
			self.assertIn("generated_not_built", unprovable)

	def test_an_unresolved_import_in_a_changed_file_is_named(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "import:\n\tno_such_module\n\nvalue = 1\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn(
				f"tree path not provable: {PARSE_SOURCES}/tree_type_parser.brp imports no_such_module",
				result.stdout,
			)

	def test_changes_to_the_parity_script_run_its_python_tests(self) -> None:
		for path in ("scripts/compiler-new-parity", PARITY_TESTS):
			with self.subTest(path=path), TreePathRepository() as repo:
				repo.write_source(path, "changed\n")

				result = repo.run("--changed", "--plan")
				self.assert_success(result)

				self.assertIn("Hand-back gates: tree path only", result.stdout)
				self.assertIn(
					f"python3 -m unittest {PARITY_TESTS}; scripts/test --no-build compiler-new compiler-new-parity",
					result.stdout,
				)

		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "value = 2\n")
			self.assertNotIn("unittest", repo.run("--changed", "--plan").stdout)

	def test_the_inert_rule_covers_what_gate_scope_calls_documentation(self) -> None:
		check = load_script("compiler_check_for_inert_rule", "compiler-check")
		gate_scope = load_script("gate_scope_for_inert_rule", "gate-scope")
		for path in ("docs/GUIDE.md", "README.md", "scripts/README.md", "docs/issues/x.txt"):
			self.assertTrue(gate_scope.is_documentation(path), path)
			self.assertIs(check.PathClassifier.__new__(check.PathClassifier).scope(path), check.PathScope.INERT, path)
		for path in ("blorp/src/main.brp", "scripts/test", "Makefile"):
			self.assertFalse(gate_scope.is_documentation(path), path)
		# Intended difference: a measurement record of any type is inert here (no
		# gate reads it) but only its Markdown counts as documentation there.
		self.assertIs(
			check.PathClassifier.__new__(check.PathClassifier).scope("benchmarks/results/run.json"),
			check.PathScope.INERT,
		)
		self.assertFalse(gate_scope.is_documentation("benchmarks/results/run.json"))

	def test_a_checked_fixture_in_compiler_new_tests_is_production(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "value = 2\n")
			repo.write_source(
				f"{COMPILER_NEW_TESTS}/test_parse/fixtures/should_fail/marked.brp",
				f"{CHECKED_MARKER}\nvalue = 2\n",
			)

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn("fixtures/should_fail/marked.brp", result.stdout)

	def test_an_unmarked_fixture_beside_a_tree_edit_stays_tree_path(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "value = 2\n")
			repo.write_source(
				f"{COMPILER_NEW_TESTS}/test_parse/fixtures/should_fail/unmarked.brp", "value = 2\n"
			)

			self.assertIn("Hand-back gates: tree path only", repo.run("--changed", "--plan").stdout)

	def test_a_compiler_blorp_test_is_tree_path_only_when_it_imports_the_tree_path(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(
				ADAPTER_SUITE, IMPORT_TREE_PROJECTION + "tests : TestSuite = test_suite(\"changed\")\n"
			)
			self.assertIn("Hand-back gates: tree path only", repo.run("--changed", "--plan").stdout)

		with TreePathRepository() as repo:
			repo.write_source(
				"blorp/test/test_compiler/test_stage_06_typecheck/test_env.brp",
				"tests : TestSuite = test_suite(\"changed\")\n",
			)
			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "value = 2\n")
			result = repo.run("--changed", "--plan")
			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn("test_env.brp", result.stdout)

	def test_a_deleted_production_file_beside_a_tree_path_edit_is_broad(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_body_parser.brp", "value = 2\n")
			(repo.root / "standard_library/src/prelude.brp").unlink()

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn("outside the tree path: standard_library/src/prelude.brp", result.stdout)

	def test_a_renamed_production_file_keeps_both_paths(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_body_parser.brp", "value = 2\n")
			repo.git("mv", "standard_library/src/prelude.brp", "standard_library/src/prelude_renamed.brp")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: broad", result.stdout)
			self.assertIn("standard_library/src/prelude.brp", result.stdout)
			self.assertIn("standard_library/src/prelude_renamed.brp", result.stdout)

	def test_documentation_beside_tree_path_does_not_widen_the_scope(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_type_parser.brp", "value = 2\n")
			repo.write_source("docs/GUIDE.md", "notes\n")
			repo.write_source("benchmarks/results/discovery_note.md", "notes\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertIn("Hand-back gates: tree path only", result.stdout)

	def test_documentation_alone_has_no_hand_back(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source("docs/GUIDE.md", "notes\n")

			result = repo.run("--changed", "--plan")
			self.assert_success(result)

			self.assertNotIn("Hand-back gates", result.stdout)

	def test_plan_json_carries_the_hand_back(self) -> None:
		with TreePathRepository() as repo:
			repo.write_source(f"{PARSE_SOURCES}/tree_body_parser.brp", "value = 2\n")
			tree_only = json.loads(repo.run("--changed", "--plan", "--json").stdout)
			self.assertEqual(tree_only["hand_back"]["scope"], "tree-path-only")
			self.assertEqual(
				tree_only["hand_back"]["commands"],
				[
					"scripts/compiler-build-status --quiet",
					f"bin/blorp test --timeout 180 {ADAPTER_SUITE} {TREE_SUITE}",
					"scripts/test --no-build compiler-new compiler-new-parity",
				],
			)
			self.assertEqual(tree_only["hand_back"]["tree_paths"], [f"{PARSE_SOURCES}/tree_body_parser.brp"])
			self.assertEqual(tree_only["hand_back"]["production_paths"], [])

			repo.write_source("Makefile", "all:\n")
			mixed = json.loads(repo.run("--changed", "--plan", "--json").stdout)
			self.assertEqual(mixed["hand_back"]["scope"], "broad")
			self.assertEqual(mixed["hand_back"]["production_paths"], ["Makefile"])
			self.assertEqual(mixed["hand_back"]["tree_paths"], [f"{PARSE_SOURCES}/tree_body_parser.brp"])
			self.assertEqual(
				mixed["hand_back"]["commands"],
				["scripts/test compiler-new compiler-new-parity compiler-blorp"],
			)

		with TreePathRepository() as repo:
			repo.write_source("docs/GUIDE.md", "notes\n")
			self.assertEqual(json.loads(repo.run("--changed", "--plan", "--json").stdout)["hand_back"]["scope"], "none")

	def test_plan_help_exposes_manifest_validation(self) -> None:
		with MiniCompilerCheckRepository() as repo:
			result = repo.run("--help")
			self.assert_success(result)

			self.assertIn("--validate-manifest", result.stdout)
			self.assertIn("validate ownership manifest", result.stdout)


if __name__ == "__main__":
	unittest.main()
