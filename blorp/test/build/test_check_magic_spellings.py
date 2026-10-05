"""Contract tests for the stable finding identity of scripts/check-magic-spellings."""

import contextlib
import importlib.machinery
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[3] / "scripts/check-magic-spellings"


def load_script():
    loader = importlib.machinery.SourceFileLoader("check_magic_spellings", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class MagicSpellingIdentityTest(unittest.TestCase):
    def setUp(self):
        self.script = load_script()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "src"
        self.source.mkdir()
        self.allowlist = self.root / "allowlist"
        self.script.SOURCE_ROOT = str(self.source)
        self.script.ALLOWLIST = str(self.allowlist)

    def write_module(self, relative, text):
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def keys(self):
        return sorted(self.script.key_of(finding) for finding in self.script.scan(self.script.SOURCE_ROOT))

    def run_check(self, *arguments):
        output = io.StringIO()
        errors = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = self.script.main(list(arguments))
        return status, output.getvalue(), errors.getvalue()

    def test_rewrapping_a_call_keeps_its_key(self):
        self.write_module("a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/")\n')
        one_line = self.keys()
        self.write_module(
            "a.brp",
            'pure func f(p: String) -> Bool:\n\tp.starts_with(\n\t\t"pkg/", -- the import prefix\n\t)\n',
        )
        self.assertEqual(one_line, self.keys())
        self.assertEqual(1, len(one_line))

    def test_changing_the_literal_changes_the_key(self):
        self.write_module("a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/")\n')
        before = self.keys()
        self.write_module("a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("package/")\n')
        self.assertNotEqual(before, self.keys())

    def test_moving_a_line_within_its_declaration_keeps_the_key_and_between_declarations_changes_it(self):
        self.write_module(
            "a.brp",
            'pure func f(p: String) -> Bool:\n\tx = 1\n\tp.starts_with("pkg/")\n\npure func g() -> Int:\n\t1\n',
        )
        before = self.keys()
        self.write_module(
            "a.brp",
            'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/")\n\tx = 1\n\npure func g() -> Int:\n\t1\n',
        )
        self.assertEqual(before, self.keys())
        self.write_module(
            "a.brp",
            'pure func f(p: String) -> Bool:\n\tx = 1\n\npure func g(p: String) -> Bool:\n\tp.starts_with("pkg/")\n',
        )
        self.assertNotEqual(before, self.keys())

    def test_two_tests_on_one_line_are_two_findings_and_a_third_copy_is_new(self):
        self.write_module("a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/") or p.starts_with("pkg/")\n')
        self.assertEqual(0, self.run_check("--update")[0])
        self.assertEqual(0, self.run_check("--strict")[0])
        self.write_module(
            "a.brp",
            'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/") or p.starts_with("pkg/") or p.starts_with("pkg/")\n',
        )
        status, output, _ = self.run_check()
        self.assertEqual(1, status)
        self.assertIn('new reader (starts_with) in f: ', output)

    def test_update_keeps_comments_of_surviving_entries_and_drops_the_rest(self):
        self.write_module(
            "a.brp",
            'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/")\n\npure func g(p: String) -> Bool:\n\tp.ends_with("_suffix")\n',
        )
        self.run_check("--update")
        lines = self.allowlist.read_text(encoding="utf-8").split("\n")
        starts = next(index for index, line in enumerate(lines) if "starts_with" in line)
        ends = next(index for index, line in enumerate(lines) if "ends_with" in line)
        # Insert the later position first so the earlier index stays valid.
        for position, comment in sorted(
            [(ends, "# Not a compiler name."), (starts, "# Import request syntax.")], reverse=True
        ):
            lines.insert(position, comment)
        self.allowlist.write_text("\n".join(lines), encoding="utf-8")
        self.write_module("a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/")\n')
        self.run_check("--update")
        text = self.allowlist.read_text(encoding="utf-8")
        self.assertIn("# Import request syntax.\na.brp\treader\tstarts_with", text)
        self.assertNotIn("Not a compiler name", text)

    def test_stale_entries_fail_only_under_strict(self):
        self.write_module("a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/")\n')
        self.run_check("--update")
        self.write_module("a.brp", "pure func f(p: String) -> Bool:\n\tTrue\n")
        self.assertEqual(0, self.run_check()[0])
        self.assertEqual(1, self.run_check("--strict")[0])

    def test_new_findings_sharing_a_literal_across_files_get_one_hint(self):
        for name in ("a.brp", "b.brp", "c.brp"):
            self.write_module(name, 'private FIXED_PREFIX: String = "fixed"\n')
        status, output, _ = self.run_check()
        self.assertEqual(1, status)
        self.assertIn('the literal "fixed" appears in 3 files: a.brp, b.brp, c.brp; prefer one shared named definition', output)
        self.assertEqual(1, output.count("hint:"))

    def test_report_lists_literals_spelled_in_several_files(self):
        for name in ("a.brp", "b.brp"):
            self.write_module(name, 'private FIXED_PREFIX: String = "fixed"\n')
        _, output, _ = self.run_check("--report")
        self.assertIn('"fixed": 2 files: a.brp, b.brp', output)

    def declarations(self):
        return sorted({finding.declaration for finding in self.script.scan(self.script.SOURCE_ROOT)})

    def test_an_implements_header_with_generic_bounds_is_the_declaration(self):
        self.write_module(
            "a.brp",
            "implements Provider for Holder[Texts:Table, Inner:Provider]:\n"
            "\tpure func f(p: String) -> Bool:\n"
            '\t\tp.starts_with("pkg/")\n',
        )
        self.assertEqual(["Provider for Holder[Texts:Table, Inner:Provider]"], self.declarations())

    def test_lowercase_constants_and_foreign_blocks_are_declarations(self):
        self.write_module(
            "a.brp",
            'private help_text: Bool = "pkg/".starts_with("pkg/")\n'
            'foreign(include: "x.h"):\n'
            "\tpure func f(p: String) -> Bool:\n"
            '\t\tp.starts_with("pkg/")\n',
        )
        self.assertEqual(['foreign(include: "x.h")', "help_text"], self.declarations())

    def test_literal_free_readers_are_counted_per_declaration(self):
        two = "pure func f(a: String, b: String) -> Int:\n\ta.parse_int() + b.parse_int()\n"
        self.write_module("a.brp", two)
        self.run_check("--update")
        self.assertEqual(0, self.run_check("--strict")[0])
        self.write_module("a.brp", two + "\tc.parse_int()\n")
        status, output, _ = self.run_check()
        self.assertEqual(1, status)
        self.assertEqual(1, output.count("new reader (parse_int) in f"))

    def test_a_new_literal_in_a_listed_declaration_is_new(self):
        self.write_module("a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("a/")\n')
        self.run_check("--update")
        self.write_module(
            "a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("a/") or p.starts_with("b/")\n'
        )
        status, output, _ = self.run_check()
        self.assertEqual(1, status)
        self.assertEqual(1, output.count("new reader (starts_with) in f"))

    def test_a_marker_constant_is_keyed_by_its_name_not_its_value(self):
        self.write_module("a.brp", 'private FIXED_PREFIX: String = "fixed"\n')
        [key] = self.keys()
        self.assertEqual(("a.brp", "producer", "marker_constant", "FIXED_PREFIX", "FIXED_PREFIX"), key)
        self.write_module("a.brp", 'private FIXED_PREFIX: String = "other"\n')
        self.assertEqual([key], self.keys())
        self.write_module("a.brp", 'private OTHER_PREFIX: String = "fixed"\n')
        self.assertNotEqual([key], self.keys())

    def test_an_unbalanced_bracket_does_not_swallow_the_next_statements(self):
        self.write_module(
            "a.brp",
            "pure func f(p: String) -> Bool:\n"
            "\tx = broken(\n"
            '\tp.starts_with("pkg/")\n'
            "pure func g(p: String) -> Bool:\n"
            '\tp.starts_with("other/")\n',
        )
        self.assertEqual(
            [
                ("a.brp", "reader", "starts_with", "f", '"pkg/"'),
                ("a.brp", "reader", "starts_with", "g", '"other/"'),
            ],
            self.keys(),
        )

    def test_a_legacy_format_allowlist_is_rejected_with_the_update_hint(self):
        self.write_module("a.brp", 'pure func f(p: String) -> Bool:\n\tp.starts_with("pkg/")\n')
        self.allowlist.write_text('a.brp\treader\tstarts_with\tp.starts_with("pkg/")\n', encoding="utf-8")
        status, _, errors = self.run_check()
        self.assertEqual(2, status)
        self.assertIn("run --update", errors)


if __name__ == "__main__":
    unittest.main()
