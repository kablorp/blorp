"""Focused tests for scripts/audit-compiler-blorp-dead-code."""

from __future__ import annotations

from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "audit-compiler-blorp-dead-code"


class CompilerBlorpDeadCodeAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.audit = runpy.run_path(str(SCRIPT))

    def test_type_declarations_participate_in_reachability(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            source_root = Path(raw_temp_dir) / "src"
            source_root.mkdir()
            source_root = source_root.resolve()
            source = source_root / "sample.brp"
            source.write_text(
                """\
type alias LiveAlias = String
opaque type LiveOpaque = LiveAlias

record Holder {
\tvalue: LiveOpaque
}
""",
                encoding="utf-8",
            )

            self.audit["parse_declarations"].__globals__["SOURCE_ROOT"] = source_root
            declarations, variants = self.audit["parse_declarations"]([source])
            edges = self.audit["declaration_edges"](
                declarations,
                variants,
                {"sample": []},
            )
            holder = self.audit["Node"]("sample", "Holder")
            live_opaque = self.audit["Node"]("sample", "LiveOpaque")
            live_alias = self.audit["Node"]("sample", "LiveAlias")

            self.assertEqual(declarations[live_alias].kind, "type alias")
            self.assertEqual(declarations[live_opaque].kind, "opaque type")
            self.assertEqual(
                self.audit["reachable"]({holder}, edges),
                {holder, live_opaque, live_alias},
            )

    def test_tracked_files_ignore_deleted_worktree_paths(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            root = Path(raw_temp_dir).resolve()
            existing = root / "existing.brp"
            existing.write_text("pure func live() -> Int: 1\n", encoding="utf-8")
            tracked_files = self.audit["tracked_files"]
            tracked_files.__globals__["ROOT"] = root

            with patch(
                "subprocess.check_output",
                return_value="existing.brp\ndeleted.brp\n",
            ):
                self.assertEqual(tracked_files("*.brp"), [existing])

    def test_source_inventory_excludes_untracked_generated_sources(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            root = Path(raw_temp_dir).resolve()
            source_root = root / "compiler/src"
            source_root.mkdir(parents=True)
            tracked = source_root / "tracked.brp"
            generated = source_root / "generated.brp"
            tracked.write_text("pure func live() -> Int: 1\n", encoding="utf-8")
            generated.write_text("pure func generated() -> Int: 2\n", encoding="utf-8")

            source_files_for_audit = self.audit["source_files_for_audit"]
            source_files_for_audit.__globals__["ROOT"] = root
            source_files_for_audit.__globals__["SOURCE_ROOT"] = source_root

            with patch(
                "subprocess.check_output",
                return_value="compiler/src/tracked.brp\n",
            ):
                self.assertEqual(source_files_for_audit(), [tracked])

    def test_unused_import_detection_is_entry_scoped(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            source_root = Path(raw_temp_dir) / "src"
            source_root.mkdir()
            source_root = source_root.resolve()
            dependency = source_root / "dependency.brp"
            dependency.write_text(
                """\
record UsedType {
\tvalue: Int
}

record UnusedType {
\tvalue: Int
}
""",
                encoding="utf-8",
            )
            source = source_root / "source.brp"
            source.write_text(
                """\
import:
\tdependency: UsedType
\tdependency as UnusedDependency

pure func keep(value: UsedType) -> UsedType:
\tvalue
""",
                encoding="utf-8",
            )

            self.audit["parse_imports"].__globals__["SOURCE_ROOT"] = source_root
            known_paths = {source.resolve(), dependency.resolve()}
            findings = self.audit["unused_import_bindings"](
                source,
                source.read_text(encoding="utf-8"),
                known_paths,
            )

            self.assertEqual(len(findings), 1)
            self.assertEqual(findings[0].module, "dependency")
            self.assertEqual(findings[0].alias, "UnusedDependency")
            self.assertEqual(findings[0].line, 3)

    def test_source_only_environment_controls_exclude_documented_controls(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            temp_dir = Path(raw_temp_dir)
            source = temp_dir / "source.brp"
            source.write_text(
                """\
func configure() -> Bool:
\tgetenv("BLORP_HIDDEN_SWITCH").is_some()

func documented() -> Bool:
\tgetenv("BLORP_PUBLIC_SWITCH").is_some()
""",
                encoding="utf-8",
            )
            documentation = temp_dir / "README.md"
            documentation.write_text(
                "Set `BLORP_PUBLIC_SWITCH=1` to enable the public behavior.\n",
                encoding="utf-8",
            )

            findings = self.audit["source_only_environment_controls"](
                [source],
                [documentation],
            )

            self.assertEqual(findings, ["BLORP_HIDDEN_SWITCH"])

    def test_environment_reference_files_exclude_source_and_binary_files(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            temp_dir = Path(raw_temp_dir)
            source = temp_dir / "source.brp"
            documentation = temp_dir / "README.md"
            binary = temp_dir / "compiler.bin"
            reference_files = self.audit["environment_reference_files"]

            findings = reference_files(
                [source],
                [source, documentation, binary],
            )

            self.assertEqual(findings, [documentation])


if __name__ == "__main__":
    unittest.main()
