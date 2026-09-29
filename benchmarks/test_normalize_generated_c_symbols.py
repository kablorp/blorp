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

    def mapped_generated(self, text, rows):
        def row(kind, identity, spelling):
            spans = [[match.start(), match.end()]
                     for match in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(spelling)
                                              + r"(?![A-Za-z0-9_])", text)]
            return {"kind": kind, "identity": identity, "spelling": spelling, "spans": spans}

        return {"version": 1, "c_sha256": hashlib.sha256(text.encode()).hexdigest(),
                "locals": [], "generated": [row(*fields) for fields in rows]}

    def test_new_generated_kinds_normalize_by_first_occurrence(self):
        cases = {
            "type": ("brp_ty3", "brp_tyAbc"),
            "temp": ("__t7", "__tQ9"),
            "local_argument": ("brp_v12_a3", "brp_v99_a1"),
            "local_source_binder": ("brp_v12_s3", "brp_v99_s1"),
            "global": ("brp_g4", "brp_g900"),
            "field": ("f0", "field3"),
        }
        for kind, (old_spelling, new_spelling) in cases.items():
            old = f"void f(void) {{ {old_spelling} x; use({old_spelling}); }}"
            new = old.replace(old_spelling, new_spelling)
            self.different(old, new)
            old_mapped = self.mapped_generated(old, [(kind, "one", old_spelling)])
            new_mapped = self.mapped_generated(new, [(kind, "one", new_spelling)])
            self.assertEqual(normalizer.normalize(old, old_mapped),
                             normalizer.normalize(new, new_mapped), kind)

    def test_new_generated_kinds_reject_mismatched_spelling(self):
        cases = {
            "type": "brp_notype3",
            "temp": "not_temp",
            "local_argument": "brp_v12_3",
            "local_source_binder": "brp_v12_a3",
            "global": "brp_v12_a3",
            "field": "header",
        }
        for kind, spelling in cases.items():
            code = f"void f(void) {{ int {spelling}; }}"
            mapped = self.mapped_generated(code, [(kind, "one", spelling)])
            with self.assertRaisesRegex(ValueError, "does not match kind", msg=kind):
                normalizer.normalize(code, mapped)

    def test_field_family_shares_ordinal_family_and_kept_spellings_are_untouched(self):
        old = "struct S { int field0; int field1; }; void f(struct S s) { use(s.field0, s.field1); }"
        new = "struct S { int f0; int f1; }; void f(struct S s) { use(s.f0, s.f1); }"
        self.different(old, new)

        def mapped(text, spellings):
            return self.mapped_generated(text, [("field", f"member_{index}", spelling)
                                                 for index, spelling in enumerate(spellings)])

        self.assertEqual(normalizer.normalize(old, mapped(old, ["field0", "field1"])),
                         normalizer.normalize(new, mapped(new, ["f0", "f1"])))
        kept = "struct S { int header; int tag; }; void f(struct S s) { use(s.header, s.tag); }"
        self.assertEqual(normalizer.normalize(kept), kept)

    def test_typedef_declared_type_authorizes_local_declaration(self):
        code = self.body("blorp_List x; use(x);")
        sidecar = self.sidecar(code, "x")
        with self.assertRaisesRegex(ValueError, "recognized C declarator"):
            normalizer.normalize(code, sidecar)
        sidecar["locals"][0]["declared_type"] = "blorp_List"
        self.assertIn("@@local:0:0@@", normalizer.normalize(code, sidecar))
        # The local identifier may still drift; the type token is unaffected
        # since declared_type only authorizes recognizing the declarator.
        new = self.body("blorp_List brp_v99_8; use(brp_v99_8);")
        new_sidecar = self.sidecar(new, "brp_v99_8")
        new_sidecar["locals"][0]["declared_type"] = "blorp_List"
        self.assertEqual(normalizer.normalize(code, sidecar), normalizer.normalize(new, new_sidecar))

    def test_declared_type_must_be_a_recognized_typedef_name(self):
        code = self.body("Widget x; use(x);")
        sidecar = self.sidecar(code, "x")
        sidecar["locals"][0]["declared_type"] = "Widget"
        with self.assertRaisesRegex(ValueError, "recognized typedef name"):
            normalizer.normalize(code, sidecar)

    def test_declared_type_still_rejects_function_pointers_and_complex_declarators(self):
        code = self.body("blorp_List (*x)(int); use(x);")
        sidecar = self.sidecar(code, "x")
        sidecar["locals"][0]["declared_type"] = "blorp_List"
        with self.assertRaisesRegex(ValueError, "recognized C declarator"):
            normalizer.normalize(code, sidecar)

    def test_v1_local_rows_remain_valid_without_declared_type(self):
        code = self.body("int local; use(local);")
        sidecar = self.sidecar(code, "local")
        self.assertNotIn("declared_type", sidecar["locals"][0])
        self.assertIn("@@local:0:0@@", normalizer.normalize(code, sidecar))

    def test_typedef_typed_parameter_is_expressible(self):
        code = "void f(blorp_List items) { use(items); }"
        occurrences = [[match.start(), match.end()]
                       for match in re.finditer(r"\bitems\b", code)]
        sidecar = {"version": 1, "c_sha256": hashlib.sha256(code.encode()).hexdigest(),
                   "locals": [{"owner_definition_id": 1, "local_ordinal": 0,
                               "scope_span": [code.index("{"), code.rindex("}") + 1],
                               "emitted_identifier": "items",
                               "declared_type": "blorp_List",
                               "declaration_span": occurrences[0],
                               "reference_spans": occurrences[1:]}]}
        normalized = normalizer.normalize(code, sidecar)
        self.assertIn("@@local:0:0@@", normalized)
        # The parameter identifier may drift; declared_type stays the anchor
        # that authorizes recognizing the (still typedef-typed) parameter.
        new = "void f(blorp_List renamed) { use(renamed); }"
        new_occurrences = [[match.start(), match.end()]
                           for match in re.finditer(r"\brenamed\b", new)]
        new_sidecar = {"version": 1, "c_sha256": hashlib.sha256(new.encode()).hexdigest(),
                       "locals": [{"owner_definition_id": 1, "local_ordinal": 0,
                                   "scope_span": [new.index("{"), new.rindex("}") + 1],
                                   "emitted_identifier": "renamed",
                                   "declared_type": "blorp_List",
                                   "declaration_span": new_occurrences[0],
                                   "reference_spans": new_occurrences[1:]}]}
        self.assertEqual(normalized, normalizer.normalize(new, new_sidecar))

    def test_primitive_parameter_is_expressible_without_declared_type(self):
        code = "void f(int count) { use(count); }"
        occurrences = [[match.start(), match.end()]
                       for match in re.finditer(r"\bcount\b", code)]
        sidecar = {"version": 1, "c_sha256": hashlib.sha256(code.encode()).hexdigest(),
                   "locals": [{"owner_definition_id": 1, "local_ordinal": 0,
                               "scope_span": [code.index("{"), code.rindex("}") + 1],
                               "emitted_identifier": "count",
                               "declaration_span": occurrences[0],
                               "reference_spans": occurrences[1:]}]}
        self.assertIn("@@local:0:0@@", normalizer.normalize(code, sidecar))

    def test_parameter_row_still_rejects_function_pointer_parameters(self):
        code = "void f(void (*cb)(int)) { use(cb); }"
        occurrences = [[match.start(), match.end()]
                       for match in re.finditer(r"\bcb\b", code)]
        sidecar = {"version": 1, "c_sha256": hashlib.sha256(code.encode()).hexdigest(),
                   "locals": [{"owner_definition_id": 1, "local_ordinal": 0,
                               "scope_span": [code.index("{"), code.rindex("}") + 1],
                               "emitted_identifier": "cb",
                               "declaration_span": occurrences[0],
                               "reference_spans": occurrences[1:]}]}
        with self.assertRaisesRegex(ValueError, "recognized C declarator"):
            normalizer.normalize(code, sidecar)

    def test_project_locals_normalizes_new_families_by_first_occurrence(self):
        code = ("brp_ty3 brp_g4;\n"
                "void f(void) { brp_v1_a2 x; __t9 tmp; use(x, tmp, brp_g4); }\n"
                "void g(void) { brp_v9_s3 y; __t1 tmp2; use(y, tmp2); }\n")
        normalized_once = normalizer.project_locals(code)
        normalized_twice = normalizer.project_locals(code)
        self.assertEqual(normalized_once, normalized_twice)
        self.assertNotIn("brp_v1_a2", normalized_once)
        self.assertNotIn("__t9", normalized_once)
        self.assertNotIn("brp_ty3", normalized_once)
        self.assertNotIn("brp_g4", normalized_once)
        # brp_ty3/brp_g4 are outside any function body (the top-level scope).
        self.assertIn("@@project:type:-1:0@@", normalized_once)
        self.assertIn("@@project:global:-1:0@@", normalized_once)
        # f is the first top-level body (id 0), g is the second (id 1); each
        # function's local and temp are that function's own first occurrence
        # of its family, so both get ordinal 0 but under distinct body ids.
        self.assertIn("@@project:local:0:0@@", normalized_once)
        self.assertIn("@@project:local:1:0@@", normalized_once)
        self.assertIn("@@project:temp:0:0@@", normalized_once)
        self.assertIn("@@project:temp:1:0@@", normalized_once)

    def test_project_locals_accepts_owner_less_binder_id_locals(self):
        code = ("void f(void) { long brp_v_2X = 1; long brp_vn_3 = brp_v_2X; "
                "use(brp_v_2X, brp_vn_3); }\n"
                "void g(void) { long brp_v_9 = 2; use(brp_v_9, brp_v1_a2); }\n")
        normalized = normalizer.project_locals(code)
        for spelling in ("brp_v_2X", "brp_vn_3", "brp_v_9", "brp_v1_a2"):
            self.assertNotIn(spelling, normalized)
        # first occurrence per function: brp_v_2X is 0, brp_vn_3 is 1; the
        # second function restarts at 0 under its own body id.
        self.assertIn("@@project:local:0:0@@", normalized)
        self.assertIn("@@project:local:0:1@@", normalized)
        self.assertIn("@@project:local:1:0@@", normalized)
        self.assertIn("@@project:local:1:1@@", normalized)
        # A callable whose base-62 id starts with `v` is not a local.
        self.assertIn("brp_v3K", normalizer.project_locals("void brp_v3K(void);"))

    def test_project_locals_accepts_perceus_temporary_and_derived_locals(self):
        code = ("void f(void) { long brp_vt_5uFzovh2zo4_b0 = 1; "
                "long brp_vd_vt_5uFzovh2zo4_b0_v0 = brp_vt_5uFzovh2zo4_b0; "
                "long brp_vd_v_2X_d0 = 2; use(brp_vt_5uFzovh2zo4_b0, "
                "brp_vd_vt_5uFzovh2zo4_b0_v0, brp_vd_v_2X_d0); }\n")
        normalized = normalizer.project_locals(code)
        for spelling in ("brp_vt_5uFzovh2zo4_b0", "brp_vd_vt_5uFzovh2zo4_b0_v0",
                         "brp_vd_v_2X_d0"):
            self.assertNotIn(spelling, normalized)
        for ordinal in (0, 1, 2):
            self.assertIn("@@project:local:0:%d@@" % ordinal, normalized)

    def test_project_locals_maps_old_and_new_variant_spellings_to_one_family(self):
        parent = (
            "#define TAG_Shape_Circle 0\n#define TAG_Shape_Sq 1\n"
            "Shape* __def_45_Circle(void* field0) { __vc->tag = TAG_Shape_Circle; }\n"
            "static Shape __instance___def_46_Sq;\n"
            "static inline Shape* __blorp_reuse_Shape___def_45_Circle(Shape* __old) {\n"
            "  if (x.tag == BLORP_TAG_SOME) return __def_45_Circle(0); }\n"
        )
        candidate = (
            "#define brp_t_cU 0\n#define brp_t_cV 1\n"
            "Shape* brp_c_cU(void* field0) { __vc->tag = brp_t_cU; }\n"
            "static Shape __instance_brp_c_cV;\n"
            "static inline Shape* __blorp_reuse_Shape_brp_c_cU(Shape* __old) {\n"
            "  if (x.tag == BLORP_TAG_SOME) return brp_c_cU(0); }\n"
        )
        self.assertEqual(normalizer.project_locals(parent), normalizer.project_locals(candidate))
        normalized = normalizer.project_locals(candidate)
        # A runtime tag macro is not a variant tag.
        self.assertIn("BLORP_TAG_SOME", normalized)
        self.assertIn("@@project:variant_constructor:-1:0@@", normalized)
        self.assertIn("@@project:variant_constructor:-1:1@@", normalized)
        self.assertIn("@@project:variant_tag:-1:1@@", normalized)

    def test_project_locals_distinguishes_variants_that_swap_order(self):
        first = "void f(void) { brp_c_a(); brp_c_b(); brp_c_a(); }\n"
        second = "void f(void) { brp_c_a(); brp_c_b(); brp_c_b(); }\n"
        self.assertNotEqual(normalizer.project_locals(first), normalizer.project_locals(second))

    def test_local_families_accept_binder_id_spellings_and_keep_owner_forms(self):
        for kind in ("local_argument", "local_source_binder"):
            grammar = normalizer.GENERATED_GRAMMARS[kind]
            for spelling in ("brp_v_2X", "brp_vn_3"):
                self.assertIsNotNone(grammar.fullmatch(spelling), (kind, spelling))
            # A callable whose base-62 id starts with `v` is never a local.
            self.assertIsNone(grammar.fullmatch("brp_v3K"))
        arguments = normalizer.GENERATED_GRAMMARS["local_argument"]
        binders = normalizer.GENERATED_GRAMMARS["local_source_binder"]
        self.assertIsNotNone(arguments.fullmatch("brp_v1_a2"))
        self.assertIsNotNone(binders.fullmatch("brp_v1_s2"))

    def test_project_locals_field_family_is_file_wide_not_per_body(self):
        code = "void f(void) { use(f0); }\nvoid g(void) { use(f0); }\n"
        normalized = normalizer.project_locals(code)
        markers = re.findall(r"@@project:field:[^@]+@@", normalized)
        self.assertEqual(len(markers), 2)
        self.assertEqual(markers[0], markers[1])

    def test_project_locals_is_weaker_than_sidecar_on_unrelated_local(self):
        # A source-authored local that happens to alternate with the same
        # spelling as a projected temp is folded together: documented
        # limitation of the sidecar-free heuristic mode.
        code = "void f(void) { int __t1; use(__t1); }"
        normalized = normalizer.project_locals(code)
        self.assertIn("@@project:temp:0:0@@", normalized)

    def test_project_locals_cannot_combine_with_sidecar_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "a.c"
            path.write_text("void f(void) { int x; use(x); }\n")
            sidecar_path = Path(directory) / "a.json"
            sidecar_path.write_text(json.dumps(self.sidecar(path.read_text(), "x")))
            command = [sys.executable, str(TOOL), "--project-locals",
                      "--sidecar", str(sidecar_path), str(path)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("--project-locals cannot be combined with --sidecar", result.stderr)

    def test_project_locals_cli_emit_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "a.c"
            path.write_text("void f(void) { brp_v1_a2 x; use(x); }\n")
            command = [sys.executable, str(TOOL), "--project-locals", "--emit", str(path)]
            emitted = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(emitted.returncode, 0)
            self.assertEqual(emitted.stdout, normalizer.project_locals(path.read_text()))
            hash_command = [sys.executable, str(TOOL), "--project-locals", str(path)]
            first = subprocess.run(hash_command, capture_output=True, text=True)
            second = subprocess.run(hash_command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0)
            self.assertEqual(first.stdout, second.stdout)
            self.assertIn("normalized C with --project-locals", first.stdout)

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
