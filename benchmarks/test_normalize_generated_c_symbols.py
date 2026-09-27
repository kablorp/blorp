"""Contract tests for the generated-C identifier comparison oracle."""

import importlib.machinery
import importlib.util
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).with_name("normalize_generated_c_symbols")
loader = importlib.machinery.SourceFileLoader("generated_c_normalizer", str(TOOL))
spec = importlib.util.spec_from_loader(loader.name, loader)
normalizer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = normalizer
loader.exec_module(normalizer)


class GeneratedCSymbolTests(unittest.TestCase):
    @staticmethod
    def body(statements):
        return "void f(void) { " + statements + " }"

    def sidecar(self, c_text, symbol, owner=12, local=3):
        occurrences = [[match.start(), match.end()]
                       for match in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(symbol)
                                                + r"(?![A-Za-z0-9_])", c_text)]
        return {"version": 1, "c_sha256": hashlib.sha256(c_text.encode()).hexdigest(),
                "locals": [{"owner_definition_id": owner, "local_ordinal": local,
                            "scope_span": [c_text.index("{"), c_text.rindex("}") + 1],
                            "emitted_identifier": symbol,
                            "declaration_span": occurrences[0],
                            "reference_spans": occurrences[1:]}]}

    def same(self, old, new):
        self.assertEqual(normalizer.normalize(old), normalizer.normalize(new))

    def different(self, old, new):
        self.assertNotEqual(normalizer.normalize(old), normalizer.normalize(new))

    def test_local_requires_exact_sidecars(self):
        old = self.body("int __blorp_internal_tmp; use(__blorp_internal_tmp);")
        new = self.body("int brp_v12_3; use(brp_v12_3);")
        self.different(old, new)
        self.assertEqual(normalizer.normalize(old, self.sidecar(old, "__blorp_internal_tmp")),
                         normalizer.normalize(new, self.sidecar(new, "brp_v12_3")))

    def test_unlisted_local_spellings_are_preserved(self):
        for old, new in [("source_x", "brp_v12_3"),
                         ("__blorp_source_1_x", "brp_v12_3"),
                         ("__blorp_internal_tmp", "brp_v12_3")]:
            self.different(f"int {old};", f"int {new};")

    def test_existing_families_and_related_closure(self):
        old = "void brp_3(void); void *__sc_brp_3 = brp_3; /* def_id=31 */\nint __def_31_None;"
        new = "void brp_Z(void); void *__sc_brp_Z = brp_Z; /* def_id=8 */\nint __def_8_None;"
        self.different(old, new)

        def mapped(text, callable_name, definition_id, label):
            def row(kind, identity, spelling):
                spans = [[match.start(), match.end()]
                         for match in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(spelling), text)]
                return {"kind": kind, "identity": identity,
                        "spelling": spelling, "spans": spans}
            return {"version": 1, "c_sha256": hashlib.sha256(text.encode()).hexdigest(),
                    "locals": [], "generated": [
                        row("callable", f"callable_{label}", f"brp_{callable_name}"),
                        row("static_closure", f"callable_{label}", f"__sc_brp_{callable_name}"),
                        row("definition_comment", f"definition_{label}", f"def_id={definition_id}"),
                        row("definition", f"definition_{label}", f"__def_{definition_id}_")]}

        self.assertEqual(normalizer.normalize(old, mapped(old, "3", 31, "old")),
                         normalizer.normalize(new, mapped(new, "Z", 8, "new")))

    def test_local_id_drift_and_scope_structure(self):
        old = self.body("int old_x; use(old_x);")
        new = self.body("int brp_v99_8; use(brp_v99_8);")
        self.assertEqual(normalizer.normalize(old, self.sidecar(old, "old_x", 12, 3)),
                         normalizer.normalize(new, self.sidecar(new, "brp_v99_8", 99, 8)))
        changed_scope = new.replace("void f", "void g")
        self.assertNotEqual(normalizer.normalize(old, self.sidecar(old, "old_x")),
                            normalizer.normalize(changed_scope,
                                                 self.sidecar(changed_scope, "brp_v99_8")))

    def test_declaration_reference_swap_and_empty_references(self):
        code = self.body("int local; use(local);")
        sidecar = self.sidecar(code, "local")
        row = sidecar["locals"][0]
        row["declaration_span"], row["reference_spans"][0] = (
            row["reference_spans"][0], row["declaration_span"])
        with self.assertRaisesRegex(ValueError, "recognized C declarator"):
            normalizer.normalize(code, sidecar)
        unused = self.body("int unused;")
        self.assertIn("@@local:0:0@@", normalizer.normalize(unused,
                      self.sidecar(unused, "unused")))

    def test_cross_scope_swap_and_invalid_scope(self):
        code = "void f(){ int same; use(same); } void g(){ int same; use(same); }"
        first = self.sidecar(code[:code.index(" void g")], "same")["locals"][0]
        second = self.sidecar(code[code.index("void g"):], "same", 13, 4)["locals"][0]
        offset = code.index("void g")
        for field in ("scope_span", "declaration_span"):
            second[field] = [value + offset for value in second[field]]
        second["reference_spans"] = [[value + offset for value in span]
                                     for span in second["reference_spans"]]
        mapped = {"version": 1, "c_sha256": hashlib.sha256(code.encode()).hexdigest(),
                  "locals": [first, second]}
        self.assertIn("@@local:1:0@@", normalizer.normalize(code, mapped))
        wrong = json.loads(json.dumps(mapped))
        wrong["locals"][0]["scope_span"] = second["scope_span"]
        with self.assertRaisesRegex(ValueError, "innermost brace scope"):
            normalizer.normalize(code, wrong)
        wrong = json.loads(json.dumps(mapped))
        wrong["locals"][0]["scope_span"] = [0, len(code)]
        with self.assertRaisesRegex(ValueError, "balanced C brace pair"):
            normalizer.normalize(code, wrong)

    def test_nested_same_spelling_uses_innermost_preceding_declaration(self):
        code = "void f(){ int x; { use(x); int x; use(x); } use(x); }"
        occurrences = [[match.start(), match.end()]
                       for match in re.finditer(r"\bx\b", code)]
        outer = [code.index("{"), code.rindex("}") + 1]
        inner_open = code.index("{", outer[0] + 1)
        inner = [inner_open, code.index("}", inner_open) + 1]

        def row(owner, ordinal, scope, declaration, references):
            return {"owner_definition_id": owner, "local_ordinal": ordinal,
                    "scope_span": scope, "emitted_identifier": "x",
                    "declaration_span": occurrences[declaration],
                    "reference_spans": [occurrences[index] for index in references]}

        sidecar = {"version": 1, "c_sha256": hashlib.sha256(code.encode()).hexdigest(),
                   "locals": [row(1, 0, outer, 0, [1, 4]),
                              row(2, 0, inner, 2, [3])]}
        normalized = normalizer.normalize(code, sidecar)
        self.assertIn("@@local:0:0@@", normalized)
        self.assertIn("@@local:1:0@@", normalized)
        merged = json.loads(json.dumps(sidecar))
        merged["locals"] = [row(1, 0, outer, 0, [1, 2, 3, 4])]
        with self.assertRaisesRegex(ValueError, "reference cannot be a declaration"):
            normalizer.normalize(code, merged)
        misowned = json.loads(json.dumps(sidecar))
        misowned["locals"][0]["reference_spans"] = [occurrences[1], occurrences[3], occurrences[4]]
        misowned["locals"][1]["reference_spans"] = []
        with self.assertRaisesRegex(ValueError, "another scoped declaration"):
            normalizer.normalize(code, misowned)

    def test_unknown_type_looking_expression_is_not_a_declaration(self):
        for spelling in ("Type", "blorp_value"):
            code = self.body(f"{spelling} * x;")
            with self.assertRaisesRegex(ValueError, "recognized C declarator"):
                normalizer.normalize(code, self.sidecar(code, "x"))

    def test_typedef_names_never_authorize_v1_locals(self):
        for code in ("typedef int Type;\n" + self.body("Type * x;"),
                     "#if 0\ntypedef int Type;\n#endif\n" + self.body("Type * x;"),
                     self.body("int Type; Type * x;")):
            with self.assertRaisesRegex(ValueError, "recognized C declarator"):
                normalizer.normalize(code, self.sidecar(code, "x"))

    def test_type_definition_braces_are_not_local_scopes(self):
        field = "struct S { int x; };"
        with self.assertRaisesRegex(ValueError, "not a compound statement"):
            normalizer.normalize(field, self.sidecar(field, "x"))
        function = self.body("int x; { long y; use(y); } use(x);")
        self.assertIn("@@local:0:0@@", normalizer.normalize(function,
                      self.sidecar(function, "x")))

    def test_explicit_compound_scope_forms_and_unknown_prefix(self):
        bodies = ("if (1) { int x; use(x); }",
                  "if (0) {} else { int x; use(x); }",
                  "do { int x; use(x); } while (0);",
                  "label: { int x; use(x); }",
                  "int result = ({ int x; use(x); 0; });")
        for body in bodies:
            code = self.body(body)
            sidecar = self.sidecar(code, "x")
            declaration = sidecar["locals"][0]["declaration_span"][0]
            openings = [match.start() for match in re.finditer(r"\{", code)
                        if match.start() < declaration]
            inner_open = openings[-1]
            sidecar["locals"][0]["scope_span"] = [inner_open, code.index("}", inner_open) + 1]
            self.assertIn(f"@@local:{len(openings) - 1}:0@@",
                          normalizer.normalize(code, sidecar), body)
        unknown = self.body("unknown { int x; use(x); }")
        sidecar = self.sidecar(unknown, "x")
        inner_open = unknown.index("{", unknown.index("{") + 1)
        sidecar["locals"][0]["scope_span"] = [inner_open, unknown.index("}", inner_open) + 1]
        with self.assertRaisesRegex(ValueError, "not a compound statement"):
            normalizer.normalize(unknown, sidecar)

    def test_local_declaration_scope_must_be_innermost(self):
        code = "void f(){ { int x; use(x); } }"
        sidecar = self.sidecar(code, "x")
        with self.assertRaisesRegex(ValueError, "innermost brace scope"):
            normalizer.normalize(code, sidecar)
        inner_open = code.index("{", code.index("{") + 1)
        sidecar["locals"][0]["scope_span"] = [inner_open, code.index("}", inner_open) + 1]
        self.assertIn("@@local:1:0@@", normalizer.normalize(code, sidecar))

    def test_local_sidecar_cannot_absorb_non_value_identifier_roles(self):
        cases = {
            "member": self.body("int x; use(s.x);"),
            "commented member": self.body("int x; use(s./* field */x);"),
            "pointer member": self.body("int x; use(p->x);"),
            "commented pointer member": self.body("int x; use(p->/* field */x);"),
            "spliced pointer member": self.body("int x; use(p-\\\n>x);"),
            "goto and label": self.body("int x; goto x; x: use(x);"),
            "tag": self.body("int x; struct x *p; use(x);"),
            "macro parameter and body": "void f(){ int x;\n#define M(x) (x)\nuse(x); }",
            "continued macro body": "void f(){ int x;\n#define M(x) (\\\n x)\nuse(x); }",
            "comment before directive": "void f(){ int x;\n/**/#define M(x) (x)\nuse(x); }",
            "spaced comment before directive": "void f(){ int x;\n  /* lead */  #define M(x) (x)\nuse(x); }",
            "multiple comments before directive": "void f(){ int x;\n/* a *//* b */#define M(x) (x)\nuse(x); }",
            "comment with hash before directive": "void f(){ int x;\n/* # is text */ #define M(x) (x)\nuse(x); }",
            "spliced comment before directive": "void f(){ int x;\n/* lead */ \\\n #define M(x) (x)\nuse(x); }",
            "comment and continued body": "void f(){ int x;\n/**/#define M(x) (\\\n x)\nuse(x); }",
        }
        for label, old in cases.items():
            new = re.sub(r"\bx\b", "y", old)
            self.assertNotEqual(normalizer.normalize(old), normalizer.normalize(new), label)
            for code, symbol in ((old, "x"), (new, "y")):
                with self.assertRaisesRegex(ValueError, "non-value|preprocessor", msg=label):
                    normalizer.normalize(code, self.sidecar(code, symbol))

    def test_hash_after_ordinary_token_is_not_a_directive(self):
        for code in ('"#define M(x)" ordinary #define M(x)',
                     'ordinary /* # inside comment */ #define M(x)',
                     'ordinary /* multi\nline */ #define M(x)'):
            lexemes, logical = normalizer.c_lexemes(code)
            self.assertEqual(normalizer.directive_spans(lexemes, logical), [])

    def test_alternate_preprocessor_markers_reject_sidecars_but_raw_stays_exact(self):
        for marker in ("%:", "??=", "%\\\n:", "?\\\n?=", "??\\\n=", "?\\\n?\\\n="):
            old = f"void f(){{ int x;\n{marker}define M(x) (x)\nuse(x); }}"
            new = re.sub(r"\bx\b", "y", old)
            self.assertNotEqual(normalizer.normalize(old), normalizer.normalize(new))
            for code, symbol in ((old, "x"), (new, "y")):
                with self.assertRaisesRegex(ValueError, "alternate preprocessor markers"):
                    normalizer.normalize(code, self.sidecar(code, symbol))
        for literal_or_comment in ('void f(){ int x; puts("%:"); use(x); }',
                                   'void f(){ int x; /* ??= */ use(x); }'):
            with self.assertRaisesRegex(ValueError, "alternate preprocessor markers"):
                normalizer.normalize(literal_or_comment,
                                     self.sidecar(literal_or_comment, "x"))
        with tempfile.TemporaryDirectory() as directory:
            old_path = Path(directory) / "old.c"
            new_path = Path(directory) / "new.c"
            old_path.write_text("%:define M(x) (x)\n")
            new_path.write_text("%:define M(y) (y)\n")
            command = [sys.executable, str(TOOL), str(old_path), str(new_path)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)
            command[-1] = str(old_path)
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_definition_span_cannot_target_a_literal(self):
        code = 'void f(){ puts("__def_31_"); }'
        start = code.index("__def_31_")
        sidecar = {"version": 1, "c_sha256": hashlib.sha256(code.encode()).hexdigest(),
                   "locals": [], "generated": [{"kind": "definition",
                   "identity": "one", "spelling": "__def_31_",
                   "spans": [[start, start + len("__def_31_")]]}]}
        with self.assertRaisesRegex(ValueError, "inside an identifier"):
            normalizer.normalize(code, sidecar)

    def test_linked_generated_payloads_must_agree(self):
        code = "void brp_1(void); void* __sc_brp_2; /* def_id=32 */ int __def_31_None;"

        def row(kind, spelling):
            start = code.index(spelling)
            return {"kind": kind, "identity": "one", "spelling": spelling,
                    "spans": [[start, start + len(spelling)]]}

        base = {"version": 1, "c_sha256": hashlib.sha256(code.encode()).hexdigest(),
                "locals": []}
        for generated in ([row("callable", "brp_1"),
                           row("static_closure", "__sc_brp_2")],
                          [row("definition", "__def_31_"),
                           row("definition_comment", "def_id=32")]):
            with self.assertRaisesRegex(ValueError, "linked generated spellings"):
                normalizer.normalize(code, {**base, "generated": generated})

    def test_line_spliced_comment_is_not_identifier_context(self):
        for code in ("void f(){ // continued \\\n int ghost;\n int live; }",
                     "void f(){ /\\\n/ int ghost;\n int live; }"):
            sidecar = self.sidecar(code, "ghost")
            with self.assertRaisesRegex(ValueError, "recognized C declarator"):
                normalizer.normalize(code, sidecar)

    def test_generated_order_and_family_do_not_collapse(self):
        old = "int brp_1 = 3; int brp_2 = 4; use(brp_1, brp_2);"
        reordered = "int brp_9 = 4; int brp_8 = 3; use(brp_8, brp_9);"

        def mapped(code, spellings):
            return {"version": 1, "c_sha256": hashlib.sha256(code.encode()).hexdigest(),
                    "locals": [], "generated": [
                        {"kind": "callable", "identity": str(index + 100),
                         "spelling": spelling,
                         "spans": [[match.start(), match.end()]
                                   for match in re.finditer(re.escape(spelling), code)]}
                        for index, spelling in enumerate(spellings)]}

        self.assertNotEqual(normalizer.normalize(old, mapped(old, ["brp_1", "brp_2"])),
                            normalizer.normalize(reordered,
                                                 mapped(reordered, ["brp_9", "brp_8"])))

    def test_malformed_sidecars_fail_closed(self):
        code = self.body("int local; use(local);")
        with self.assertRaisesRegex(ValueError, "must be an object"):
            normalizer.normalize(code, [])
        sidecar = self.sidecar(code, "local")
        sidecar["generated"] = [{"kind": [], "identity": [], "spelling": "brp_1",
                                  "spans": [[0, 5]]}]
        with self.assertRaisesRegex(ValueError, "malformed"):
            normalizer.normalize(code, sidecar)

    def test_source_identifier_with_generated_looking_suffix_is_exact(self):
        self.different("int source__v7; use(source__v7);",
                       "int source__v8; use(source__v8);")

    def test_explicit_suffix_family_and_lookalikes(self):
        old = 'int st_diag__v0; use(st_diag__v0); /* __v0 */ puts("st_diag__v0");'
        new = 'int st_diag__v7; use(st_diag__v7); /* __v0 */ puts("st_diag__v0");'
        self.different(old, new)

        def mapped(text, spelling):
            spans = [[match.start(), match.end()]
                     for match in re.finditer(re.escape(spelling), text)
                     if match.start() < text.index('/*')]
            return {"version": 1, "c_sha256": hashlib.sha256(text.encode()).hexdigest(),
                    "locals": [], "generated": [{"kind": "variable_suffix",
                    "identity": "local_one", "spelling": spelling, "spans": spans}]}

        self.assertEqual(normalizer.normalize(old, mapped(old, "st_diag__v0")),
                         normalizer.normalize(new, mapped(new, "st_diag__v7")))
        changed = new.replace("/* __v0 */", "/* __v1 */")
        self.assertNotEqual(normalizer.normalize(old, mapped(old, "st_diag__v0")),
                            normalizer.normalize(changed, mapped(changed, "st_diag__v7")))

    def test_collision_and_split(self):
        old = self.body("int a; use(a);")
        sidecar = self.sidecar(old, "a")
        duplicate = dict(sidecar)
        duplicate["locals"] = sidecar["locals"] * 2
        with self.assertRaisesRegex(ValueError, "split or merged"):
            normalizer.normalize(old, duplicate)
        mismatch = json.loads(json.dumps(sidecar))
        mismatch["locals"][0]["reference_spans"] = [[4, 5]]
        with self.assertRaisesRegex(ValueError, "outside scope"):
            normalizer.normalize(old, mismatch)

    def test_sidecar_rejects_missing_use_and_wrong_hash(self):
        old = self.body("int local; use(local); use(local);")
        sidecar = self.sidecar(old, "local")
        sidecar["locals"][0]["reference_spans"].pop()
        with self.assertRaisesRegex(ValueError, "unlisted local"):
            normalizer.normalize(old, sidecar)
        sidecar["c_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "hash"):
            normalizer.normalize(old, sidecar)

    def test_sidecar_rejects_duplicate_scope_name_and_bad_token_boundary(self):
        old = self.body("int local; use(local);")
        sidecar = self.sidecar(old, "local")
        second = json.loads(json.dumps(sidecar["locals"][0]))
        second["owner_definition_id"] = 13
        sidecar["locals"].append(second)
        with self.assertRaisesRegex(ValueError, "split or merged"):
            normalizer.normalize(old, sidecar)
        sidecar["locals"].pop()
        sidecar["locals"][0]["declaration_span"][0] += 1
        with self.assertRaisesRegex(ValueError, "recognized C declarator"):
            normalizer.normalize(old, sidecar)

    def test_missing_occurrence_and_structure(self):
        old = "int __blorp_internal_a; use(__blorp_internal_a);"
        self.different(old, "int brp_v1_1; use(0);")
        self.different(old, "use(brp_v1_1); int brp_v1_1;")
        self.different(old, "int brp_v1_1; other(brp_v1_1);")

    def test_literals_comments_and_source_identifiers_remain(self):
        old = 'int __blorp_internal_a; /* keep=3 */ puts("__blorp_internal_a"); source_x;'
        self.different(old, 'int brp_v1_1; /* keep=4 */ puts("__blorp_internal_a"); source_x;')
        self.different(old, 'int brp_v1_1; /* keep=3 */ puts("brp_v1_1"); source_x;')
        self.different(old, 'int brp_v1_1; /* keep=3 */ puts("__blorp_internal_a"); source_y;')

    def test_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "old.c"
            second = Path(directory) / "new.c"
            first.write_text(self.body("int __blorp_internal_a; use(__blorp_internal_a);") + "\n")
            second.write_text(self.body("int brp_v2_4; use(brp_v2_4);") + "\n")
            first_sidecar = Path(directory) / "old.json"
            second_sidecar = Path(directory) / "new.json"
            first_sidecar.write_text(json.dumps(self.sidecar(first.read_text(), "__blorp_internal_a", 2, 4)))
            second_sidecar.write_text(json.dumps(self.sidecar(second.read_text(), "brp_v2_4", 2, 4)))

            def run(*args):
                return subprocess.run([sys.executable, str(TOOL), *map(str, args)],
                                      capture_output=True, text=True)

            emitted = run("--emit", first)
            self.assertEqual(emitted.returncode, 0)
            self.assertEqual(emitted.stdout, normalizer.normalize(first.read_text()))
            digest = run(first)
            self.assertEqual(digest.returncode, 0)
            self.assertRegex(digest.stdout, r"^raw C SHA-256: [0-9a-f]{64}  ")
            self.assertEqual(run(first, second).returncode, 1)
            self.assertEqual(run("--sidecar", first_sidecar, "--sidecar", second_sidecar,
                                 first, second).returncode, 0)
            second.write_text(self.body("int brp_v2_4; other(brp_v2_4);") + "\n")
            self.assertEqual(run(first, second).returncode, 1)
            self.assertEqual(run("--sidecar", first_sidecar, "--sidecar", second_sidecar,
                                 first, second).returncode, 2)
            self.assertEqual(run("--emit", first, second).returncode, 2)
            self.assertEqual(run(first, second, first).returncode, 2)
            self.assertEqual(run(Path(directory) / "missing.c").returncode, 2)
            second_sidecar.write_text("[]")
            malformed = run("--sidecar", first_sidecar, "--sidecar", second_sidecar,
                            first, second)
            self.assertEqual(malformed.returncode, 2)
            self.assertNotIn("Traceback", malformed.stderr)


if __name__ == "__main__":
    unittest.main()
