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


def rules(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from rules(child)
    elif isinstance(value, list):
        for child in value:
            yield from rules(child)


class RecordSpellingGrammarTest(unittest.TestCase):
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
