#!/usr/bin/env python3
"""Contract tests for scripts/blorp-build-inputs.

The script owns the Blorp source list that the Makefile and
scripts/compiler-build-status both hash, so these tests pin what is on it and
what the fallback does when the import graph cannot be resolved.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPTS_DIRECTORY = ROOT / "scripts"
SCRIPT_FILES = ("blorp-build-inputs", "blorp_import_graph.py")


class BlorpBuildInputsTests(unittest.TestCase):
	def setUp(self) -> None:
		self.tempdir = tempfile.TemporaryDirectory()
		self.root = Path(self.tempdir.name)
		(self.root / "scripts").mkdir()
		for name in SCRIPT_FILES:
			shutil.copy(SCRIPTS_DIRECTORY / name, self.root / "scripts" / name)
		self.write(
			"blorp/src/main.brp",
			"import:\n\tcompiler/driver\n\tcompiler/reporting\n\tlist: map\n\nfunc main() -> Int:\n\t0\n",
		)
		self.write("blorp/src/compiler/driver.brp", "import:\n\tleaf\n")
		self.write("blorp/src/compiler/leaf.brp", "")
		self.write("blorp/src/compiler/reporting.brp", "import:\n\tleaf\n")
		# Imported by nothing the CLI reaches.
		self.write("blorp/src/compiler_new/tree_parser.brp", "import:\n\t../compiler/leaf\n")
		self.write("blorp/src/format/engine/formatter.brp", "import:\n\t../../compiler/leaf\n")
		self.write("blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp", "")
		self.write("blorp/src/lib/runtime/native/runtime.c", "")
		self.write("blorp/src/lib/runtime_ffi.h", "")
		self.write("standard_library/src/list.brp", "")
		self.write("standard_library/src/unused.brp", "")

	def tearDown(self) -> None:
		self.tempdir.cleanup()

	def write(self, relative: str, content: str) -> None:
		path = self.root / relative
		path.parent.mkdir(parents=True, exist_ok=True)
		path.write_text(content, encoding="utf-8")

	def run_script(self, *arguments: str) -> subprocess.CompletedProcess[str]:
		return subprocess.run(
			[sys.executable, str(self.root / "scripts/blorp-build-inputs"), *arguments],
			cwd=self.root,
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=False,
		)

	def sources(self) -> list[str]:
		result = self.run_script("sources")
		self.assertEqual(result.returncode, 0, result.stderr)
		return result.stdout.splitlines()

	def test_sources_are_the_modules_the_cli_reaches(self) -> None:
		self.assertEqual(
			self.sources(),
			[
				"blorp/src/compiler/driver.brp",
				"blorp/src/compiler/leaf.brp",
				"blorp/src/compiler/reporting.brp",
				"blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp",
				"blorp/src/main.brp",
				"standard_library/src/list.brp",
				"standard_library/src/unused.brp",
			],
		)

	def test_entry_is_the_module_the_makefile_compiles(self) -> None:
		result = self.run_script("entry")
		self.assertEqual(result.stdout, "blorp/src/main.brp\n")

	def test_a_clean_graph_prints_no_fallback_note(self) -> None:
		self.assertEqual(self.run_script("sources").stderr, "")

	def test_modules_only_another_program_reaches_are_not_inputs(self) -> None:
		sources = self.sources()
		self.assertNotIn("blorp/src/compiler_new/tree_parser.brp", sources)
		self.assertNotIn("blorp/src/format/engine/formatter.brp", sources)

	def test_generated_modules_are_inputs_even_when_nothing_imports_them(self) -> None:
		self.write("blorp/src/compiler/stage_01_generated_inputs/compiler_build_info.brp", "")
		self.assertIn(
			"blorp/src/compiler/stage_01_generated_inputs/compiler_build_info.brp",
			self.sources(),
		)

	def test_every_standard_library_module_is_an_input(self) -> None:
		self.assertIn("standard_library/src/unused.brp", self.sources())

	def test_a_later_import_block_is_followed(self) -> None:
		self.write("blorp/src/compiler/late.brp", "")
		self.write(
			"blorp/src/compiler/driver.brp",
			"import:\n\tleaf\n\nfunc helper() -> Int:\n\t0\n\nimport:\n\tlate\n",
		)
		self.assertIn("blorp/src/compiler/late.brp", self.sources())

	def test_a_reached_module_outside_both_source_roots_is_an_input(self) -> None:
		self.write("blorp/tool/helper.brp", "")
		self.write("blorp/src/compiler/leaf.brp", "import:\n\t../../tool/helper\n")

		result = self.run_script("sources")

		self.assertEqual(result.stderr, "")
		self.assertIn("blorp/tool/helper.brp", result.stdout.splitlines())

	def test_headers_are_every_header_under_the_source_tree(self) -> None:
		self.write("blorp/src/compiler_new/tree_ffi.h", "")
		result = self.run_script("headers")
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(
			result.stdout.splitlines(),
			["blorp/src/compiler_new/tree_ffi.h", "blorp/src/lib/runtime_ffi.h"],
		)

	def test_unresolved_import_falls_back_to_every_source_module_and_says_so(self) -> None:
		self.write("blorp/src/compiler/driver.brp", "import:\n\tnot_generated_yet\n")

		result = self.run_script("sources")

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("blorp/src/compiler/driver.brp imports not_generated_yet", result.stderr)
		self.assertIn("every blorp/src module", result.stderr)
		sources = result.stdout.splitlines()
		for path in (
			"blorp/src/compiler_new/tree_parser.brp",
			"blorp/src/format/engine/formatter.brp",
			"blorp/src/main.brp",
			"standard_library/src/unused.brp",
		):
			self.assertIn(path, sources)

	def test_missing_entry_module_falls_back_to_every_source_module(self) -> None:
		(self.root / "blorp/src/main.brp").unlink()

		result = self.run_script("sources")

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertIn("blorp/src/main.brp", result.stderr)
		self.assertIn("blorp/src/compiler_new/tree_parser.brp", result.stdout.splitlines())

	def test_an_import_of_a_package_module_cannot_be_resolved_so_falls_back(self) -> None:
		self.write("blorp/src/compiler/leaf.brp", "import:\n\tpkg/raylib\n")

		result = self.run_script("sources")

		self.assertIn("pkg/raylib", result.stderr)
		self.assertIn("blorp/src/compiler_new/tree_parser.brp", result.stdout.splitlines())


class RealCheckoutTests(unittest.TestCase):
	@unittest.skipUnless(
		(ROOT / "blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp").is_file(),
		"the generated modules are written by make",
	)
	def test_the_checkout_resolves_without_falling_back(self) -> None:
		"""Guards the superset property: if an import stops resolving here, the
		list silently becomes every module and tree-only edits go STALE again."""
		result = subprocess.run(
			[sys.executable, str(SCRIPTS_DIRECTORY / "blorp-build-inputs"), "--root", str(ROOT), "sources"],
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=False,
		)
		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(result.stderr, "")
		self.assertIn("blorp/src/main.brp", result.stdout.splitlines())


if __name__ == "__main__":
	unittest.main()
