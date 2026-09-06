"""Focused tests for scripts/audit-compiler-blorp-dead-code."""

from __future__ import annotations

from contextlib import redirect_stdout
import io
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[4]
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
            source_root = root / "blorp/src/compiler"
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
                return_value="blorp/src/compiler/tracked.brp\n",
            ):
                self.assertEqual(source_files_for_audit(), [tracked])

    def test_source_inventory_includes_relocated_cli_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            root = Path(raw_temp_dir).resolve()
            source_root = root / "blorp/src/compiler"
            source_root.mkdir(parents=True)
            compiler_source = source_root / "pipeline.brp"
            compiler_source.write_text("pure func compile() -> Int: 1\n", encoding="utf-8")
            cli_root = root / "blorp/src/main.brp"
            cli_root.parent.mkdir(parents=True, exist_ok=True)
            cli_root.write_text("func main(args: List[String]) -> Int: 0\n", encoding="utf-8")

            source_files_for_audit = self.audit["source_files_for_audit"]
            source_files_for_audit.__globals__["ROOT"] = root
            source_files_for_audit.__globals__["SOURCE_ROOT"] = source_root
            source_files_for_audit.__globals__["CLI_ROOT"] = cli_root

            with patch(
                "subprocess.check_output",
                return_value="blorp/src/compiler/pipeline.brp\nblorp/src/main.brp\n",
            ):
                self.assertEqual(
                    source_files_for_audit(),
                    sorted([cli_root, compiler_source]),
                )

            module_name = self.audit["module_name"]
            module_name.__globals__["SOURCE_ROOT"] = source_root
            module_name.__globals__["CLI_ROOT"] = cli_root
            self.assertEqual(module_name(cli_root), "__blorp_main__")

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

    def test_module_identity_call_graph_classifies_direct_facts_and_callers(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            source_root = Path(raw_temp_dir) / "src"
            source_root.mkdir()
            source_root = source_root.resolve()
            source = source_root / "sample.brp"
            source.write_text(
                """\
record ModuleHolder {
\tmodule_path: String
}

pure func identity_name(identity: ModuleIdentity) -> String:
\tmodule_identity_display_name(identity)

pure func path_name(module_path: String) -> String:
\tmodule_path

pure func prepared_module_canonical_path(module: ModuleHolder) -> String:
\tmodule.module_path

pure func holder_path(holder: ModuleHolder) -> String:
\tholder.module_path

pure func identity_body(value: Int) -> Int:
\towner: Option[ModuleIdentity] = None
\tvalue

pure func string_body(value: Int) -> String:
\tmodule_name: String = "sample"
\tmodule_name

pure func caller(identity: ModuleIdentity) -> String:
\tidentity_name(identity)

pure func transitive_caller(value: Int) -> String:
\tcaller(value)

pure func unrelated(value: Int) -> Int:
\tvalue

pure func module_surface_symbol_kind_name(value: String) -> String:
\tvalue

pure func import_module_named_field(value: String) -> String:
\tvalue

pure func module_view_find_local_name(value: String) -> String:
\tvalue
""",
                encoding="utf-8",
            )

            self.audit["parse_declarations"].__globals__["SOURCE_ROOT"] = source_root
            declarations, variants = self.audit["parse_declarations"]([source])
            graph = self.audit["module_identity_call_graph"](
                declarations,
                variants,
                {"sample": []},
            )
            nodes = {node["id"]: node for node in graph["nodes"]}

            self.assertEqual(
                nodes["sample::identity_name"]["direct_facts"],
                ["module_identity_signature"],
            )
            self.assertEqual(
                nodes["sample::path_name"]["direct_facts"],
                ["module_string_signature"],
            )
            self.assertEqual(
                nodes["sample::holder_path"]["direct_facts"],
                ["module_string_field_read"],
            )
            self.assertEqual(
                nodes["sample::prepared_module_canonical_path"]["direct_facts"],
                ["module_string_field_read", "module_string_named_function"],
            )
            self.assertEqual(
                nodes["sample::identity_body"]["direct_facts"],
                ["module_identity_body"],
            )
            self.assertEqual(
                nodes["sample::string_body"]["direct_facts"],
                ["module_string_body"],
            )
            self.assertEqual(nodes["sample::caller"]["distance_to_direct_fact"], 0)
            self.assertEqual(
                nodes["sample::transitive_caller"]["distance_to_direct_fact"],
                1,
            )
            self.assertNotIn("sample::unrelated", nodes)
            self.assertNotIn("sample::module_surface_symbol_kind_name", nodes)
            self.assertNotIn("sample::import_module_named_field", nodes)
            self.assertNotIn("sample::module_view_find_local_name", nodes)
            self.assertIn(
                {"caller": "sample::transitive_caller", "callee": "sample::caller"},
                graph["edges"],
            )

    def test_module_identity_call_graph_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            source_root = Path(raw_temp_dir) / "src"
            source_root.mkdir()
            source_root = source_root.resolve()
            source = source_root / "sample.brp"
            source.write_text(
                """\
pure func second(module_name: String) -> String: module_name
pure func first(value: Int) -> String: second(value)
""",
                encoding="utf-8",
            )

            self.audit["parse_declarations"].__globals__["SOURCE_ROOT"] = source_root
            declarations, variants = self.audit["parse_declarations"]([source])
            first = self.audit["module_identity_call_graph"](
                declarations,
                variants,
                {"sample": []},
            )
            second = self.audit["module_identity_call_graph"](
                dict(reversed(list(declarations.items()))),
                variants,
                {"sample": []},
            )

            self.assertEqual(first, second)
            self.assertEqual(
                [node["id"] for node in first["nodes"]],
                ["sample::first", "sample::second"],
            )

            output = io.StringIO()
            with redirect_stdout(output):
                self.audit["print_module_identity_call_graph_dot"](first)

            dot = output.getvalue()
            self.assertTrue(dot.startswith("digraph compiler_module_identity_calls {\n"))
            self.assertIn("sample::second\\n", dot)
            self.assertNotIn("sample::second\\\\n", dot)
            self.assertIn('"sample::second" [label=', dot)
            self.assertIn('shape="box"', dot)
            self.assertIn('shape="ellipse"', dot)
            self.assertIn('"sample::first" -> "sample::second";', dot)
            self.assertLess(dot.index('"sample::first" [label='), dot.index('"sample::second" [label='))
            self.assertEqual(self.audit["dot_escape"]('a"b\\c'), 'a\\"b\\\\c')
            self.assertTrue(dot.endswith("}\n"))


if __name__ == "__main__":
    unittest.main()
