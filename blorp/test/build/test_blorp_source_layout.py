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
	def write_layout(
		self,
		root: Path,
		*,
		shared_consumers: dict[str, list[str]] | None = None,
		legacy_owner_paths: list[str] | None = None,
		legacy_owner_importers: dict[str, list[str]] | None = None,
		temporary_cross_owner_imports: dict[str, list[str]] | None = None,
		forbidden_top_level_paths: list[str] | None = None,
		isolated_test_owners: list[str] | None = None,
		owner_roots: list[str] | None = None,
		fixture_directories: list[str] | None = None,
	) -> None:
		for owner in owner_roots or []:
			(root / "blorp/src" / owner).mkdir(parents=True, exist_ok=True)
		(root / "blorp/src/compiler").mkdir(parents=True, exist_ok=True)
		(root / "blorp/src/run").mkdir(parents=True, exist_ok=True)
		(root / "blorp/src/format").mkdir(parents=True, exist_ok=True)
		(root / "blorp/src/test").mkdir(parents=True, exist_ok=True)
		(root / "blorp/src/lib").mkdir(parents=True, exist_ok=True)
		(root / "blorp/test/compiler").mkdir(parents=True, exist_ok=True)
		(root / "blorp/test/test").mkdir(parents=True, exist_ok=True)
		(root / "blorp/source_ownership.json").write_text(
			json.dumps(
				{
					"version": 1,
					"source_root": "blorp/src",
					"test_root": "blorp/test",
					"owner_roots": ["compiler", "run", "format", "test", *(owner_roots or [])],
					"composition_roots": ["main.brp"],
					"legacy_source_roots": [],
					"forbidden_top_level_paths": forbidden_top_level_paths or [],
					"legacy_owner_paths": legacy_owner_paths or [],
					"legacy_owner_importers": legacy_owner_importers or {},
					"temporary_cross_owner_imports": temporary_cross_owner_imports or {},
					"fixture_directories": fixture_directories or ["fixture", "should_pass", "should_fail"],
					"shared_module_consumers": shared_consumers or {},
					"isolated_test_owners": isolated_test_owners or [],
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

	def test_rejects_cross_owner_import_written_as_a_module_alias(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			(root / "blorp/src/compiler/command.brp").write_text(
				"import:\n\t../run/command as command\n",
				encoding="utf-8",
			)
			(root / "blorp/src/run/command.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("cross-owner import", result.stderr)

	def test_rejects_cross_owner_import_without_symbols(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			(root / "blorp/src/compiler/command.brp").write_text(
				"import:\n\t../run/command\n",
				encoding="utf-8",
			)
			(root / "blorp/src/run/command.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("cross-owner import", result.stderr)

	def test_symbols_below_an_import_are_not_taken_for_modules(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			# `main` is a symbol of `./sibling`; read as a module it would resolve to
			# the source root's `main.brp`, which no compiler module may import.
			(root / "blorp/src/compiler/command.brp").write_text(
				"import:\n\t./sibling:\n\t\tmain\n",
				encoding="utf-8",
			)
			(root / "blorp/src/compiler/sibling.brp").write_text("", encoding="utf-8")
			(root / "blorp/src/main.brp").write_text("", encoding="utf-8")

			result = self.run_checker(root)

			self.assertEqual(result.returncode, 0, result.stderr)

	def write_compiler_new_importers(self, root: Path, importer: str) -> None:
		self.write_layout(
			root,
			owner_roots=["compiler_new"],
			temporary_cross_owner_imports={
				"compiler/discovery_adapter.brp": ["compiler_new/tables.brp"],
			},
		)
		(root / "blorp/src/compiler_new/tables.brp").write_text("", encoding="utf-8")
		(root / "blorp/src/compiler/discovery_adapter.brp").write_text(
			"import:\n\t../compiler_new/tables as Tables\n",
			encoding="utf-8",
		)
		(root / f"blorp/src/compiler/{importer}.brp").write_text(
			"import:\n\t../compiler_new/tables as Tables\n",
			encoding="utf-8",
		)

	def test_only_the_registered_adapter_may_import_compiler_new(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_compiler_new_importers(root, "pipeline")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn(
				"cross-owner import compiler -> compiler_new: compiler/pipeline.brp",
				result.stderr,
			)
			self.assertNotIn("compiler/discovery_adapter.brp imports", result.stderr)

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

	def test_repository_manifest_treats_formatter_expected_output_as_fixture(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			manifest = json.loads((ROOT / "blorp/source_ownership.json").read_text(encoding="utf-8"))
			self.write_layout(root, fixture_directories=manifest["fixture_directories"])
			golden = root / "blorp/test/format/expected_output/formatted.brp"
			golden.parent.mkdir(parents=True)
			golden.write_text("func main() -> Int: 0\n", encoding="utf-8")

			result = self.run_checker(root)
			self.assertEqual(result.returncode, 0, result.stderr)

			(root / "blorp/test/format/helper.brp").write_text("", encoding="utf-8")
			result = self.run_checker(root)
			self.assertNotEqual(result.returncode, 0)
			self.assertIn("test module must start with test_: format/helper.brp", result.stderr)
			self.assertNotIn("format/expected_output/formatted.brp", result.stderr)

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

	def write_isolated_run_owner(self, root: Path, test_imports: str) -> None:
		self.write_layout(root, isolated_test_owners=["run"])
		(root / "blorp/src/run/command.brp").write_text("", encoding="utf-8")
		(root / "blorp/src/lib/shared.brp").write_text("", encoding="utf-8")
		(root / "blorp/src/compiler/pipeline.brp").write_text("", encoding="utf-8")
		(root / "blorp/test/run").mkdir(parents=True)
		(root / "blorp/test/run/test_command.brp").write_text(
			f"import:\n{test_imports}",
			encoding="utf-8",
		)

	def test_isolated_test_owner_accepts_its_owner_lib_and_standard_library(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_isolated_run_owner(
				root,
				"\t../../src/run/command: run_command\n"
				"\t../../src/lib/shared: shared\n"
				"\ttest: TestSuite\n",
			)

			result = self.run_checker(root)

			self.assertNotIn("isolated test owner", result.stderr)

	def test_isolated_test_owner_rejects_another_owners_source(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_isolated_run_owner(root, "\t../../src/compiler/pipeline: compile\n")

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("isolated test owner run may import only run, lib", result.stderr)

	def test_isolated_owner_rejects_another_owner_reached_through_lib(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_isolated_run_owner(root, "\t../../src/run/command: run_command\n")
			(root / "blorp/src/run/command.brp").write_text(
				"import:\n\t../lib/shared: shared\n",
				encoding="utf-8",
			)
			(root / "blorp/src/lib/shared.brp").write_text(
				"import:\n\t../compiler/pipeline: compile\n",
				encoding="utf-8",
			)

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("isolated owner run reaches another owner through lib", result.stderr)

	def test_isolated_owner_ignores_fixture_with_invalid_utf8(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root, isolated_test_owners=["compiler"])
			fixtures = root / "blorp/test/compiler/stage/fixtures/should_fail"
			fixtures.mkdir(parents=True)
			(fixtures / "invalid_utf8.brp").write_bytes(b'x: String = "\xff"\n')

			result = self.run_checker(root)

			self.assertEqual(result.returncode, 0, result.stderr)

	def test_isolated_owner_names_test_module_with_invalid_utf8(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root, isolated_test_owners=["compiler"])
			(root / "blorp/test/compiler/test_bad.brp").write_bytes(b'x = "\xff"\n')

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertNotIn("Traceback", result.stderr)
			self.assertIn("test_bad.brp is not valid UTF-8 at byte 5", result.stderr)

	def test_source_with_invalid_utf8_is_a_clear_error(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root)
			(root / "blorp/src/compiler/bad.brp").write_bytes(b'x = "\xff"\n')

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertNotIn("Traceback", result.stderr)
			self.assertIn("bad.brp is not valid UTF-8 at byte 5", result.stderr)

	def test_isolated_test_owner_must_be_registered(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_layout(root, isolated_test_owners=["missing"])

			result = self.run_checker(root)

			self.assertNotEqual(result.returncode, 0)
			self.assertIn("isolated test owner is not a registered owner: missing", result.stderr)


if __name__ == "__main__":
	unittest.main()
