#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
RENAMER = REPOSITORY / "scripts" / "rename-identifiers"


class RenameIdentifiersTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="blorp-rename-")
        self.repo = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "test@blorp.invalid"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "Blorp Test"], cwd=self.repo, check=True)

        source = self.repo / "lsp_model.brp"
        source.write_text(
            "record LspModel { lsp_value: Int }\n"
            "record LspPosition { line: Int }\n"
            "-- lsp_value is intentionally updated in documentation.\n"
            'name: String = "lsp_value"\n'
            "not_lsp_value: Int = 1\n"
        )
        excluded = self.repo / "lsp_keep.brp"
        excluded.write_text("pure func lsp_keep() -> Int: 1\n")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=self.repo, check=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_renamer(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(RENAMER),
                ".",
                "--repo",
                str(self.repo),
                "--strip-prefix",
                "lsp_",
                "--strip-prefix",
                "Lsp",
                "--rename-file-prefix",
                "lsp_",
                "--rename",
                "LspPosition=ProtocolPosition",
                "--exclude",
                "lsp_keep",
                *arguments,
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_dry_run_reports_without_modifying_repository(self) -> None:
        result = self.run_renamer("--dry-run")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("path\tlsp_model.brp\tmodel.brp", result.stdout)
        self.assertTrue((self.repo / "lsp_model.brp").exists())
        self.assertFalse((self.repo / "model.brp").exists())

    def test_apply_discovers_symbols_and_renames_complete_tokens(self) -> None:
        result = self.run_renamer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.repo / "lsp_model.brp").exists())
        renamed = self.repo / "model.brp"
        self.assertTrue(renamed.exists())
        self.assertEqual(
            renamed.read_text(),
            "record Model { value: Int }\n"
            "record ProtocolPosition { line: Int }\n"
            "-- value is intentionally updated in documentation.\n"
            'name: String = "value"\n'
            "not_lsp_value: Int = 1\n",
        )

    def test_exclusion_preserves_identifier_and_filename(self) -> None:
        result = self.run_renamer()

        self.assertEqual(result.returncode, 0, result.stderr)
        excluded = self.repo / "lsp_keep.brp"
        self.assertTrue(excluded.exists())
        self.assertIn("lsp_keep", excluded.read_text())

    def test_untracked_files_do_not_define_repository_renames(self) -> None:
        untracked = self.repo / "lsp_untracked.brp"
        untracked.write_text("pure func lsp_untracked() -> Int: 1\n")

        result = self.run_renamer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(untracked.exists())
        self.assertIn("lsp_untracked", untracked.read_text())

    def test_historical_benchmark_results_are_never_rewritten(self) -> None:
        history = self.repo / "benchmarks" / "results" / "history.md"
        history.parent.mkdir(parents=True)
        history.write_text("Historical symbols: lsp_value and lsp_model.brp\n")
        subprocess.run(["git", "add", str(history)], cwd=self.repo, check=True)

        result = self.run_renamer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            history.read_text(),
            "Historical symbols: lsp_value and lsp_model.brp\n",
        )

    def test_second_run_is_idempotent(self) -> None:
        first = self.run_renamer()
        second = self.run_renamer()

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("renamed 0 paths; edited 0 tracked text files", second.stdout)

    def test_duplicate_override_source_is_rejected(self) -> None:
        result = self.run_renamer("--rename", "LspPosition=OtherPosition")

        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate --rename source: LspPosition", result.stderr)

    def test_derived_destination_must_be_an_identifier(self) -> None:
        source = self.repo / "invalid.brp"
        source.write_text("value: Int = lsp_1value\n")
        subprocess.run(["git", "add", str(source)], cwd=self.repo, check=True)

        result = self.run_renamer()

        self.assertEqual(result.returncode, 2)
        self.assertIn("produces invalid identifier '1value'", result.stderr)

    def test_longest_matching_prefix_wins(self) -> None:
        result = self.run_renamer("--strip-prefix", "L")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("record Model", (self.repo / "model.brp").read_text())
        self.assertNotIn("record spModel", (self.repo / "model.brp").read_text())

    def test_file_only_mode_updates_module_references_without_renaming_symbols(self) -> None:
        consumer = self.repo / "consumer.brp"
        consumer.write_text(
            "import:\n\tlsp_model: LspModel\n\n"
            "record Holder { lsp_model: Int }\n"
            "match value:\n\tlsp_model: 1\n\n"
            "pure func lsp_model() -> Int: 1\n"
            'module_label = "lsp_model"\n'
            'backup_path = "assets/lsp_model.brp.backup"\n'
            "value = lsp_value\n"
        )
        history = self.repo / "benchmarks" / "results" / "history.md"
        history.parent.mkdir(parents=True)
        history.write_text("Historical module: lsp_model.brp and lsp_value\n")
        subprocess.run(["git", "add", str(consumer), str(history)], cwd=self.repo, check=True)

        result = subprocess.run(
            [
                str(RENAMER),
                ".",
                "--repo",
                str(self.repo),
                "--rename-file-prefix",
                "lsp_",
                "--exclude",
                "lsp_keep",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repo / "model.brp").exists())
        self.assertEqual(
            consumer.read_text(),
            "import:\n\tmodel: LspModel\n\n"
            "record Holder { lsp_model: Int }\n"
            "match value:\n\tlsp_model: 1\n\n"
            "pure func lsp_model() -> Int: 1\n"
            'module_label = "lsp_model"\n'
            'backup_path = "assets/lsp_model.brp.backup"\n'
            "value = lsp_value\n",
        )
        self.assertEqual(
            history.read_text(),
            "Historical module: lsp_model.brp and lsp_value\n",
        )

    def test_missing_prefix_is_rejected(self) -> None:
        result = subprocess.run(
            [str(RENAMER), ".", "--repo", str(self.repo)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("at least one --strip-prefix or --rename-file-prefix is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
