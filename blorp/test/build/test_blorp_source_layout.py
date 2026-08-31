#!/usr/bin/env python3
"""Contract tests for the Blorp source ownership gate."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
CHECKER = ROOT / "scripts" / "check-blorp-layout"


class BlorpSourceLayoutTests(unittest.TestCase):
	def test_repository_separates_standard_library_sources_and_tests(self) -> None:
		source_root = ROOT / "standard_library/src"
		test_root = ROOT / "standard_library/test"

		self.assertTrue(source_root.is_dir())
		self.assertTrue(test_root.is_dir())
		self.assertFalse((ROOT / "std").exists())
		self.assertTrue((source_root / "test.brp").is_file())
		self.assertTrue((test_root / "test_check_std_builtins.py").is_file())
		self.assertFalse(any((source_root / "test").glob("**/*.brp")))

	def write_layout(
		self,
		root: Path,
		*,
		shared_consumers: dict[str, list[str]] | None = None,
		legacy_owner_paths: list[str] | None = None,
		legacy_owner_importers: dict[str, list[str]] | None = None,
		temporary_cross_owner_imports: dict[str, list[str]] | None = None,
		forbidden_top_level_paths: list[str] | None = None,
	) -> None:
		(root / "blorp/src/compiler").mkdir(parents=True)
		(root / "blorp/src/run").mkdir(parents=True)
		(root / "blorp/src/format").mkdir(parents=True)
		(root / "blorp/src/test").mkdir(parents=True)
		(root / "blorp/src/lib").mkdir(parents=True)
		(root / "blorp/test/compiler").mkdir(parents=True)
		(root / "blorp/test/test").mkdir(parents=True)
		(root / "blorp/source_ownership.json").write_text(
			json.dumps(
				{
					"version": 1,
					"source_root": "blorp/src",
					"test_root": "blorp/test",
					"owner_roots": ["compiler", "run", "format", "test"],
					"composition_roots": ["main.brp"],
					"legacy_source_roots": [],
					"forbidden_top_level_paths": forbidden_top_level_paths or [],
					"legacy_owner_paths": legacy_owner_paths or [],
					"legacy_owner_importers": legacy_owner_importers or {},
					"temporary_cross_owner_imports": temporary_cross_owner_imports or {},
					"fixture_directories": ["fixture", "should_pass", "should_fail"],
					"shared_module_consumers": shared_consumers or {},
				}
			),
			encoding="utf-8",
		)

	def run_checker(self, root: Path) -> subprocess.CompletedProcess[str]:
		return subprocess.run(
			["python3", str(CHECKER), "--root", str(root)],
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=False,
		)

	def test_rejects_cross_owner_import(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			(root / "blorp/src/compiler/command.brp").write_text(
				"import:\n\t../run/command: run_command\n",
				encoding="utf-8",
			)
			(root / "blorp/src/run/command.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("cross-owner import", result.stderr)

	def test_accepts_one_registered_temporary_cross_owner_import(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(
				root,
				temporary_cross_owner_imports={
					"compiler/legacy_cli.brp": ["run/command.brp"],
				},
			)
			(root / "blorp/src/compiler/legacy_cli.brp").write_text(
				"import:\n\t../run/command: run_command\n",
				encoding="utf-8",
			)
			(root / "blorp/src/run/command.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertEqual(result.returncode, 0, result.stderr)

	def test_rejects_stale_temporary_cross_owner_import_permission(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(
				root,
				temporary_cross_owner_imports={
					"compiler/legacy_cli.brp": ["run/command.brp"],
				},
			)
			(root / "blorp/src/compiler/legacy_cli.brp").write_text("", encoding="utf-8")
			(root / "blorp/src/run/command.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("stale temporary cross-owner import permission", result.stderr)

	def test_rejects_unregistered_import_into_legacy_owner(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(
				root,
				legacy_owner_paths=["compiler/legacy_cli"],
				legacy_owner_importers={"compiler/legacy_cli": ["main.brp"]},
			)
			(root / "blorp/src/compiler/pipeline.brp").write_text(
				"import:\n\tlegacy_cli/command: run_command\n",
				encoding="utf-8",
			)
			legacy_command = root / "blorp/src/compiler/legacy_cli/command.brp"
			legacy_command.parent.mkdir(parents=True)
			legacy_command.write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("unregistered legacy-owner import", result.stderr)

	def test_rejects_stale_legacy_owner_importer_permission(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(
				root,
				legacy_owner_paths=["compiler/legacy_cli"],
				legacy_owner_importers={"compiler/legacy_cli": ["compiler/pipeline.brp"]},
			)
			(root / "blorp/src/compiler/legacy_cli").mkdir(parents=True)
			(root / "blorp/src/compiler/legacy_cli/command.brp").write_text(
				"",
				encoding="utf-8",
			)
			(root / "blorp/src/compiler/pipeline.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("stale legacy-owner importer permission", result.stderr)

	def test_shared_module_requires_two_reachable_consumers(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(
				root,
				shared_consumers={"shared.brp": ["compiler", "run"]},
			)
			(root / "blorp/src/lib/shared.brp").write_text("", encoding="utf-8")
			(root / "blorp/src/compiler/command.brp").write_text(
				"import:\n\t../lib/shared: shared_value\n",
				encoding="utf-8",
			)
			(root / "blorp/src/run/command.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("declared consumer run cannot reach", result.stderr)

	def test_accepts_shared_module_with_two_reachable_consumers(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(
				root,
				shared_consumers={"shared.brp": ["compiler", "run"]},
			)
			(root / "blorp/src/lib/shared.brp").write_text("", encoding="utf-8")
			for owner in ("compiler", "run"):
				(root / f"blorp/src/{owner}/command.brp").write_text(
					"import:\n\t../lib/shared: shared_value\n",
					encoding="utf-8",
				)

			result = self.run_checker(root)

			self.assertEqual(result.returncode, 0, result.stderr)

	def test_compiler_runtime_sources_are_owned_by_the_blorp_executable(self) -> None:
		source_ownership = json.loads(
			(ROOT / "blorp/source_ownership.json").read_text(encoding="utf-8")
		)
		compiler_ownership = json.loads(
			(ROOT / "blorp/test/compiler/compiler_test_ownership.json").read_text(
				encoding="utf-8"
			)
		)
		owned_compiler_modules = {
			module["path"] for module in compiler_ownership["modules"]
		}

		self.assertFalse(
			(ROOT / "standard_library/src/compiler_runtime.brp").exists()
		)
		self.assertTrue((ROOT / "blorp/src/lib/runtime_sources.brp").is_file())
		self.assertTrue(
			(ROOT / "blorp/src/compiler/runtime_source_provider.brp").is_file()
		)
		self.assertEqual(
			source_ownership["shared_module_consumers"].get("runtime_sources.brp"),
			["compiler", "run", "test"],
		)
		self.assertIn(
			"blorp/src/lib/runtime_sources.brp",
			owned_compiler_modules,
		)
		self.assertIn(
			"blorp/src/compiler/runtime_source_provider.brp",
			owned_compiler_modules,
		)

	def test_test_module_prefix_excludes_registered_fixtures(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			(root / "blorp/test/compiler/command.brp").write_text("", encoding="utf-8")
			fixture = root / "blorp/test/compiler/should_pass/program.brp"
			fixture.parent.mkdir(parents=True)
			fixture.write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("test module must start with test_", result.stderr)
			self.assertNotIn(str(fixture.relative_to(root)), result.stderr)

	def test_accepts_test_as_a_production_command_owner_with_mirrored_tests(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			(root / "blorp/src/test/command.brp").write_text("", encoding="utf-8")
			(root / "blorp/test/test/test_command.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertEqual(result.returncode, 0, result.stderr)

	def test_rejects_test_shaped_module_below_test_command_owner(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			(root / "blorp/src/test/test_command.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("test-shaped module", result.stderr)
			self.assertIn("test/test_command.brp", result.stderr)

	def test_rejects_unknown_source_owner(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			rogue = root / "blorp/src/rogue/module.brp"
			rogue.parent.mkdir(parents=True)
			rogue.write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("unregistered source owner: rogue", result.stderr)

	def test_rejects_forbidden_top_level_path(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root, forbidden_top_level_paths=["compiler", "tests"])
			(root / "compiler").mkdir()

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("forbidden top-level path exists: compiler", result.stderr)

	def test_rejects_test_shaped_source_below_production_owner(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			(root / "blorp/src/compiler/test_command.brp").write_text(
				"",
				encoding="utf-8",
			)
			nested_test = root / "blorp/src/format/test/cases.brp"
			nested_test.parent.mkdir(parents=True)
			nested_test.write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("test-shaped module", result.stderr)
			self.assertIn("nested test directory", result.stderr)

	def test_rejects_fixture_directory_below_source(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			fixture = root / "blorp/src/compiler/should_pass/program.brp"
			fixture.parent.mkdir(parents=True)
			fixture.write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("fixture directory is not allowed", result.stderr)


if __name__ == "__main__":
	unittest.main()
