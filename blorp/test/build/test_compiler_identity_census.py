"""Focused contract tests for the source identity census."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[3] / "scripts/compiler-identity-census"
CHECKED_IN_BASELINE = SCRIPT.with_name("compiler-identity-census-baseline.json")


class IdentityCensusTest(unittest.TestCase):
    def test_checked_in_coverage_tracks_tuple_flatten_replacement(self):
        baseline = json.loads(CHECKED_IN_BASELINE.read_text(encoding="utf-8"))
        covered = set(baseline["coverage"]["paths"])
        old_path = "blorp/src/compiler/stage_09_core/tuple_sroa.brp"
        replacement = "blorp/src/compiler/stage_09_core/tuple_flatten.brp"
        self.assertFalse(old_path in covered, old_path)
        self.assertTrue(replacement in covered, replacement)
        self.assertTrue((SCRIPT.parents[1] / replacement).is_file())

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "blorp/src/compiler/stage_09_core/ir.brp"
        self.source.parent.mkdir(parents=True)
        self.anchors = []
        for phase in ("stage_06_typecheck", "stage_08_core_lower", "stage_09_core"):
            anchor = self.root / f"blorp/src/compiler/{phase}/anchor.brp"
            anchor.parent.mkdir(parents=True, exist_ok=True)
            anchor.write_text("-- phase anchor\n", encoding="utf-8")
            self.anchors.append(anchor)
        self.source.write_text(
            "record CoreVar {\n"
            "\tname: String,\n"
            "\tid: Int\n"
            "}\n"
            "pure func display(variable: CoreVar) -> String:\n"
            "\tvariable.name\n"
            "pure func equal(variable: CoreVar) -> Bool:\n"
            "\tvariable.name == \"x\"\n",
            encoding="utf-8",
        )
        self.boundary = self.root / "blorp/src/compiler/stage_10_backend/c_naming.brp"
        self.boundary.parent.mkdir(parents=True)
        self.boundary.write_text(
            "pure func c_local_name(name: String) -> String:\n"
            "\tc_identifier(name)\n", encoding="utf-8",
        )
        self.baseline = self.root / "baseline.json"

    def run_census(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root),
             "--baseline", str(self.baseline), *args],
            text=True, capture_output=True, check=False,
        )

    def write_reviewed_baseline(self):
        generated = self.run_census("--write-baseline", str(self.baseline))
        self.assertEqual(generated.returncode, 0, generated.stderr)
        baseline = json.loads(self.baseline.read_text())
        for boundary in baseline["allowed_boundaries"]:
            boundary.update(rationale="Test C identifier formatting boundary.",
                            owner="C5b", oracle="fixture output")
        self.baseline.write_text(json.dumps(baseline), encoding="utf-8")

    def test_sorted_json_and_text_share_rows(self):
        result = self.run_census("--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["schema_version"], 1)
        keys = [row["key"] for row in report["rows"]]
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(result.stdout, self.run_census("--json").stdout)
        text = self.run_census().stdout
        for row in report["rows"]:
            self.assertIn(row["key"], text)

    def test_display_boundary_and_ratchet(self):
        report = json.loads(self.run_census("--json").stdout)
        display = [row for row in report["rows"]
                   if row["category"] == "symbol_projection"
                   and row["classification"] == "allowed_boundary"]
        self.assertEqual(len(display), 1)
        self.assertEqual(display[0]["classification"], "allowed_boundary")
        self.write_reviewed_baseline()
        self.assertEqual(self.run_census("--check").returncode, 0)

        self.source.write_text(self.source.read_text() + "\tvariable.name == \"y\"\n")
        increased = self.run_census("--check")
        self.assertNotEqual(increased.returncode, 0)
        self.assertIn("ir.brp:9", increased.stderr)

        self.source.write_text(
            self.source.read_text()
                .replace("\tvariable.name == \"x\"\n", "")
                .replace("\tvariable.name == \"y\"\n", ""),
            encoding="utf-8",
        )
        reduced = self.run_census("--check")
        self.assertEqual(reduced.returncode, 0, reduced.stderr)

    def test_new_unclassified_semantic_site_fails(self):
        self.write_reviewed_baseline()
        self.boundary.write_text(self.boundary.read_text() + "\tc_local_name(other.name)\n")
        failed = self.run_census("--check")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("c_naming.brp:3", failed.stderr)
        self.assertIn("unclassified", failed.stderr)

    def test_exact_site_swap_at_same_count_fails(self):
        self.write_reviewed_baseline()
        self.source.write_text(
            self.source.read_text().replace("variable.name == \"x\"",
                                            "variable.name == \"y\""),
            encoding="utf-8",
        )
        failed = self.run_census("--check")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("ir.brp:8", failed.stderr)
        self.assertIn("new exact identity site", failed.stderr)

    def test_failed_check_summarizes_revision_and_exact_site_drift(self):
        self.write_reviewed_baseline()
        self.source.write_text(
            self.source.read_text().replace("variable.name == \"x\"",
                                            "variable.name == \"y\"")
                + "\tvar names: Dict[String, Int] = {}\n",
            encoding="utf-8",
        )
        failed = self.run_census("--check")
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertIn("baseline revision: unversioned-fixture", failed.stderr)
        self.assertIn("exact-site drift: 2 added, 1 removed", failed.stderr)
        self.assertIn("source_spelling_predicate: +1 -1", failed.stderr)
        self.assertIn("string_collection: +1 -0", failed.stderr)
        self.assertIn("new exact identity site", failed.stderr)

    def test_failed_check_reports_sites_when_git_is_unavailable(self):
        self.write_reviewed_baseline()
        self.source.write_text(
            self.source.read_text().replace("variable.name == \"x\"",
                                            "variable.name == \"y\""),
            encoding="utf-8",
        )
        failed = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root),
             "--baseline", str(self.baseline), "--check"],
            env={**os.environ, "PATH": "/nonexistent"},
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertIn("baseline revision: unversioned-fixture", failed.stderr)
        self.assertIn("new exact identity site", failed.stderr)
        self.assertNotIn("Traceback", failed.stderr)

    def test_same_function_constructor_swap_at_same_count_fails(self):
        self.source.write_text(
            "pure func make(first: Bool) -> CoreVar:\n"
            "\tif first:\n"
            "\t\tCoreVar {\n"
            "\t\t\tname = \"first\",\n"
            "\t\t\tid = 0\n"
            "\t\t}\n"
            "\telse:\n"
            "\t\tCoreVar {\n"
            "\t\t\tname = \"second\",\n"
            "\t\t\tid = 1\n"
            "\t\t}\n", encoding="utf-8")
        self.write_reviewed_baseline()
        self.source.write_text(self.source.read_text().replace("id = 0", "id = 2")
                               .replace("id = 1", "id = 0"), encoding="utf-8")
        failed = self.run_census("--check")
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertIn("new exact identity site", failed.stderr)

    def test_constructor_swap_distinguished_only_by_string_literal_fails(self):
        self.source.write_text(
            "pure func make() -> CoreVar:\n"
            "\tvar item = {\n"
            "\t\tname = \"first\",\n"
            "\t\tid = 0\n"
            "\t}\n"
            "\titem = {\n"
            "\t\tname = \"second\",\n"
            "\t\tid = 1\n"
            "\t}\n"
            "\titem\n", encoding="utf-8")
        self.write_reviewed_baseline()
        self.source.write_text(self.source.read_text().replace("id = 0", "id = 2")
                               .replace("id = 1", "id = 0"), encoding="utf-8")
        failed = self.run_census("--check")
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertIn("new exact identity site", failed.stderr)

    def test_branch_local_constructor_swap_with_identical_names_fails(self):
        self.source.write_text(
            "pure func make(first_branch: Bool) -> CoreVar:\n"
            "\tif first_branch:\n"
            "\t\tfirst = {\n"
            "\t\t\tname = \"same\",\n"
            "\t\t\tid = 0\n"
            "\t\t}\n"
            "\t\tfirst\n"
            "\telse:\n"
            "\t\tsecond = {\n"
            "\t\t\tname = \"same\",\n"
            "\t\t\tid = 1\n"
            "\t\t}\n"
            "\t\tsecond\n", encoding="utf-8")
        self.write_reviewed_baseline()
        self.source.write_text(self.source.read_text().replace("id = 0", "id = 2")
                               .replace("id = 1", "id = 0"), encoding="utf-8")
        failed = self.run_census("--check")
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertIn("new exact identity site", failed.stderr)

    def test_nonbrace_statement_before_pending_record_keeps_exact_key(self):
        self.source.write_text(
            "pure func make() -> CoreVar:\n"
            "\titem = {\n"
            "\t\tname = \"same\",\n"
            "\t\tid = 0\n"
            "\t}\n"
            "\titem\n", encoding="utf-8")
        self.write_reviewed_baseline()
        self.source.write_text(self.source.read_text().replace(
            "\titem = {", "\tvar unrelated: Int = 42\n\titem = {"), encoding="utf-8")
        checked = self.run_census("--check")
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_pending_site_without_balanced_record_requires_review(self):
        self.source.write_text("pure func example() -> Int:\n\tid = 0\n\tid\n",
                               encoding="utf-8")
        self.write_reviewed_baseline()
        report = json.loads(self.run_census("--json").stdout)
        pending = [row for row in report["rows"]
                   if row["category"] == "pending_constructor"]
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["classification"], "needs_review")
        checked = self.run_census("--check")
        self.assertEqual(checked.returncode, 1, checked.stderr)
        self.assertIn("unclassified semantic site", checked.stderr)

    def test_same_name_implementation_methods_have_distinct_keys(self):
        self.source.write_text(
            "implements Equatable for First:\n"
            "\tpure func equals(self: First, other: First) -> Bool:\n"
            "\t\tself.name == other.name\n"
            "implements Equatable for Second:\n"
            "\tpure func equals(self: Second, other: Second) -> Bool:\n"
            "\t\tself.name == other.name\n", encoding="utf-8")
        report = json.loads(self.run_census("--json").stdout)
        sites = [row for row in report["rows"]
                 if row["category"] == "source_spelling_predicate"]
        self.assertEqual(len(sites), 2)
        self.assertEqual(len({row["scope"] for row in sites}), 2)
        self.assertEqual(len({row["key"] for row in sites}), 2)
        self.assertTrue(any("First" in row["scope"] for row in sites))
        self.assertTrue(any("Second" in row["scope"] for row in sites))

    def test_line_shift_keeps_exact_site_fingerprints(self):
        self.write_reviewed_baseline()
        self.source.write_text("\n-- inserted comment\n" + self.source.read_text(), encoding="utf-8")
        self.boundary.write_text("\n-- inserted comment\n" + self.boundary.read_text(), encoding="utf-8")
        checked = self.run_census("--check")
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_unrelated_statement_before_predicate_keeps_exact_key(self):
        self.write_reviewed_baseline()
        self.source.write_text(
            self.source.read_text().replace("\tvariable.name == \"x\"",
                                            "\tvar unrelated: Int = 42\n\tvariable.name == \"x\""),
            encoding="utf-8")
        checked = self.run_census("--check")
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_comment_marker_inside_string_does_not_hide_site(self):
        self.source.write_text(
            self.source.read_text() + 'var encoded = "x--y" + c_identifier(name)\n',
            encoding="utf-8",
        )
        report = json.loads(self.run_census("--json").stdout)
        self.assertTrue(any(row["category"] == "symbol_projection"
                            and row["path"].endswith("ir.brp")
                            for row in report["rows"]))

    def test_code_shaped_literals_and_comments_produce_no_sites(self):
        self.source.write_text(
            'pure func example() -> String:\n'
            '    "Dict[String, Int] .name == \\"x\\" c_local_name(foo) -- text"\n'
            '    -- Dict[String, Int] .name == "x" c_local_name(foo)\n',
            encoding="utf-8",
        )
        self.boundary.write_text('', encoding="utf-8")
        report = json.loads(self.run_census("--json").stdout)
        self.assertTrue(all(row["category"] == "unsupported_static"
                            for row in report["rows"]))

    def test_same_predicate_moved_between_functions_fails(self):
        self.write_reviewed_baseline()
        lines = self.source.read_text().splitlines()
        lines[5] = '\tvariable.name == "x"'
        lines[7] = '\tvariable.name'
        self.source.write_text("\n".join(lines) + "\n", encoding="utf-8")
        failed = self.run_census("--check")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("new exact identity site", failed.stderr)
        self.assertIn("func:display", failed.stderr)

    def test_missing_root_and_phase_fail_closed(self):
        missing = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root / "missing"), "--json"],
            text=True, capture_output=True, check=False,
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("compiler source root missing", missing.stderr)
        self.anchors[0].unlink()
        empty_phase = self.run_census("--json")
        self.assertNotEqual(empty_phase.returncode, 0)
        self.assertIn("required compiler phase has no .brp files", empty_phase.stderr)

    def test_removed_covered_file_fails_check(self):
        self.write_reviewed_baseline()
        self.source.unlink()
        checked = self.run_census("--check")
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("previously covered compiler file missing", checked.stderr)
        self.assertIn("ir.brp", checked.stderr)

    def test_generic_function_scopes_distinguish_identical_sites(self):
        self.source.write_text(
            "pure func first[T](value: T) -> Bool:\n"
            "\tvalue.name == \"x\"\n"
            "pure func second[T](value: T) -> Bool:\n"
            "\tvalue.name == \"x\"\n", encoding="utf-8",
        )
        report = json.loads(self.run_census("--json").stdout)
        sites = [row for row in report["rows"]
                 if row["category"] == "source_spelling_predicate"]
        self.assertEqual(len(sites), 2)
        self.assertEqual({row["scope"] for row in sites},
                         {"func:first", "func:second"})
        self.assertEqual(len({row["key"] for row in sites}), 2)

    def test_doc_block_excludes_code_shaped_text_then_resumes(self):
        self.source.write_text(
            "---\n"
            "Dict[String, Int] variable.name == \"x\" c_local_name(foo)\n"
            "---\n"
            "pure func after_doc(variable: CoreVar) -> Bool:\n"
            "\tvariable.name == \"y\"\n", encoding="utf-8",
        )
        report = json.loads(self.run_census("--json").stdout)
        sites = [row for row in report["rows"] if row["path"].endswith("ir.brp")]
        self.assertEqual([row["category"] for row in sites
                          if row["classification"] == "legacy_semantic"],
                         ["source_spelling_predicate"])
        self.assertFalse(any(row["category"] == "string_collection" for row in sites))
        self.assertFalse(any(row["category"] == "symbol_projection" for row in sites))

    def test_malformed_baseline_exits_without_traceback(self):
        self.write_reviewed_baseline()
        baseline = json.loads(self.baseline.read_text())
        del baseline["coverage"]
        self.baseline.write_text(json.dumps(baseline), encoding="utf-8")
        missing = self.run_census("--check")
        self.assertEqual(missing.returncode, 2)
        self.assertIn("invalid baseline: coverage", missing.stderr)
        self.assertNotIn("Traceback", missing.stderr)
        baseline["coverage"] = {"paths": [], "counts_by_phase": "wrong"}
        self.baseline.write_text(json.dumps(baseline), encoding="utf-8")
        wrong_type = self.run_census("--check")
        self.assertEqual(wrong_type.returncode, 2)
        self.assertIn("invalid baseline: coverage.counts_by_phase", wrong_type.stderr)
        self.assertNotIn("Traceback", wrong_type.stderr)

    def test_candidate_baseline_requires_boundary_review_and_preserves_review(self):
        candidate = self.run_census("--write-baseline", str(self.baseline))
        self.assertEqual(candidate.returncode, 0, candidate.stderr)
        unreviewed = self.run_census("--check")
        self.assertEqual(unreviewed.returncode, 2)
        self.assertIn("unreviewed allowed boundary", unreviewed.stderr)
        baseline = json.loads(self.baseline.read_text())
        baseline["allowed_boundaries"][0].update(
            rationale="Specific encoding fixture", owner="C5b", oracle="fixture C output")
        self.baseline.write_text(json.dumps(baseline), encoding="utf-8")
        updated = self.run_census("--write-baseline", str(self.baseline))
        self.assertEqual(updated.returncode, 0, updated.stderr)
        preserved = json.loads(self.baseline.read_text())["allowed_boundaries"][0]
        self.assertEqual(preserved["rationale"], "Specific encoding fixture")
        self.assertEqual(preserved["owner"], "C5b")
        self.assertEqual(preserved["oracle"], "fixture C output")
        self.assertEqual(self.run_census("--check").returncode, 0)

    def test_changed_boundary_key_requires_new_review(self):
        self.write_reviewed_baseline()
        old_key = json.loads(self.baseline.read_text())["allowed_boundaries"][0]["key"]
        self.boundary.write_text(
            self.boundary.read_text().replace("c_identifier(name)", "c_identifier(other)"),
            encoding="utf-8")
        stale = self.run_census("--check")
        self.assertEqual(stale.returncode, 1, stale.stderr)
        self.assertIn("unclassified boundary", stale.stderr)
        candidate = self.run_census("--write-baseline", str(self.baseline))
        self.assertEqual(candidate.returncode, 0, candidate.stderr)
        changed = json.loads(self.baseline.read_text())["allowed_boundaries"][0]
        self.assertNotEqual(changed["key"], old_key)
        self.assertEqual(changed["rationale"], "REVIEW_REQUIRED")
        self.assertEqual(changed["owner"], "REVIEW_REQUIRED")
        self.assertEqual(changed["oracle"], "REVIEW_REQUIRED")
        unreviewed = self.run_census("--check")
        self.assertEqual(unreviewed.returncode, 2, unreviewed.stderr)
        self.assertIn("unreviewed allowed boundary", unreviewed.stderr)

    def test_boundary_literal_change_requires_new_review(self):
        self.boundary.write_text(
            'pure func c_local_name(name: String) -> String:\n\tc_identifier("first")\n',
            encoding="utf-8")
        self.write_reviewed_baseline()
        old_key = json.loads(self.baseline.read_text())["allowed_boundaries"][0]["key"]
        self.boundary.write_text(self.boundary.read_text().replace('"first"', '"second"'),
                                 encoding="utf-8")
        stale = self.run_census("--check")
        self.assertEqual(stale.returncode, 1, stale.stderr)
        self.assertIn("unclassified boundary", stale.stderr)
        candidate = self.run_census("--write-baseline", str(self.baseline))
        self.assertEqual(candidate.returncode, 0, candidate.stderr)
        changed = json.loads(self.baseline.read_text())["allowed_boundaries"][0]
        self.assertNotEqual(changed["key"], old_key)
        self.assertEqual([changed[field] for field in ("rationale", "owner", "oracle")],
                         ["REVIEW_REQUIRED"] * 3)
        unreviewed = self.run_census("--check")
        self.assertEqual(unreviewed.returncode, 2, unreviewed.stderr)

    def test_malformed_existing_candidate_is_not_overwritten(self):
        for malformed in ([], {"allowed_boundaries": {}},
                          {"allowed_boundaries": [None]},
                          {"allowed_boundaries": [{"key": "existing", "owner": 2,
                                                    "oracle": "fixture", "rationale": "reviewed"}]}):
            with self.subTest(malformed=malformed):
                original = json.dumps(malformed)
                self.baseline.write_text(original, encoding="utf-8")
                failed = self.run_census("--write-baseline", str(self.baseline))
                self.assertEqual(failed.returncode, 2)
                self.assertIn("invalid existing baseline", failed.stderr)
                self.assertNotIn("Traceback", failed.stderr)
                self.assertEqual(self.baseline.read_text(encoding="utf-8"), original)

    def test_check_and_baseline_generation_are_mutually_exclusive(self):
        combined = self.run_census("--check", "--write-baseline", str(self.baseline))
        self.assertEqual(combined.returncode, 2)
        self.assertIn("mutually exclusive", combined.stderr)
        self.assertFalse(self.baseline.exists())


if __name__ == "__main__":
    unittest.main()
