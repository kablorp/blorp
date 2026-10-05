"""Check the declaration spelling rules shared by both editor integrations."""

import json
from pathlib import Path
import re
import unittest


EDITOR = Path(__file__).resolve().parent
GRAMMARS = (
    EDITOR / "vscode/syntaxes/blorp.tmLanguage.json",
    EDITOR / "intellij/src/main/resources/textmate/blorp/syntaxes/blorp.tmLanguage.json",
)
CONFIGURATIONS = (
    EDITOR / "vscode/language-configuration.json",
    EDITOR / "intellij/src/main/resources/textmate/blorp/language-configuration.json",
)


def rules(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from rules(child)
    elif isinstance(value, list):
        for child in value:
            yield from rules(child)


class RecordSpellingGrammarTest(unittest.TestCase):
    def test_fixed_union_headers_increase_indentation(self):
        for path in CONFIGURATIONS:
            pattern = json.loads(path.read_text())["indentationRules"]["increaseIndentPattern"]
            for prefix in ("", "private "):
                for header in ("fixed union Response:", "fixed union Response[T, #N]: -- payloads"):
                    with self.subTest(path=path, source=prefix + header):
                        self.assertIsNotNone(re.search(pattern, prefix + header))

    def test_fixed_identifiers_do_not_increase_indentation(self):
        for path in CONFIGURATIONS:
            pattern = json.loads(path.read_text())["indentationRules"]["increaseIndentPattern"]
            for source in ("fixed: Int = 1", "private fixed: Int = 1", "fixed union_name:", "fixed_record:"):
                with self.subTest(path=path, source=source):
                    self.assertIsNone(re.search(pattern, source))

    def test_contextual_fixed_union_declarations(self):
        for path in GRAMMARS:
            with self.subTest(path=path):
                grammar = json.loads(path.read_text())
                declaration_rules = list(rules(grammar))
                for prefix in ("", "private "):
                    rule = next(rule for rule in declaration_rules
                                if rule.get("comment") == prefix + "fixed union declaration")
                    matched = re.search(rule["match"], prefix + "fixed union Response[T, #N]:")
                    self.assertIsNotNone(matched)
                    captured_scopes = {
                        matched.group(int(group)): capture["name"]
                        for group, capture in rule["captures"].items()
                    }
                    self.assertEqual(captured_scopes["fixed"], "storage.modifier.fixed.blorp")
                    self.assertEqual(captured_scopes["union"], "keyword.declaration.union.blorp")
                    self.assertEqual(captured_scopes["Response"], "entity.name.type.union.blorp")
                    ordinary = next(rule for rule in declaration_rules
                                    if rule.get("comment") == prefix + "union declaration")
                    self.assertLess(declaration_rules.index(rule), declaration_rules.index(ordinary))
                    for source in ("fixed: Int = 1", "func bump(fixed: Int) -> Int:"):
                        self.assertIsNone(re.search(rule["match"], source))

    def test_contextual_fixed_record_declarations(self):
        for path in GRAMMARS:
            with self.subTest(path=path):
                grammar = json.loads(path.read_text())
                declaration_rules = {
                    rule.get("comment"): rule for rule in rules(grammar)
                }
                for prefix in ("", "private "):
                    rule = declaration_rules[prefix + "fixed record declaration"]
                    matched = re.search(rule["match"], prefix + "fixed record Box[T] {value: T}")
                    self.assertIsNotNone(matched)
                    captured_scopes = {
                        matched.group(int(group)): capture["name"]
                        for group, capture in rule["captures"].items()
                    }
                    self.assertEqual(captured_scopes["fixed"], "storage.modifier.fixed.blorp")
                    self.assertEqual(captured_scopes["record"], "keyword.declaration.record.blorp")
                    self.assertEqual(captured_scopes["Box"], "entity.name.type.record.blorp")
                    for identifier_source in ("fixed: Int = 1", "func bump(fixed: Int) -> Int:"):
                        self.assertIsNone(re.search(rule["match"], identifier_source))

    def test_struct_is_not_a_reserved_word_rule(self):
        for path in GRAMMARS:
            with self.subTest(path=path):
                for rule in rules(json.loads(path.read_text())):
                    self.assertNotIn("struct", rule.get("match", ""))
                    for capture in rule.get("captures", {}).values():
                        self.assertNotIn(".struct.", capture.get("name", ""))


if __name__ == "__main__":
    unittest.main()
