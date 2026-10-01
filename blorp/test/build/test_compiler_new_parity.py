#!/usr/bin/env python3
"""Contract tests for the comparison in scripts/compiler-new-parity."""

from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "compiler-new-parity"


def load_parity_module():
	loader = importlib.machinery.SourceFileLoader("compiler_new_parity", str(SCRIPT))
	spec = importlib.util.spec_from_loader(loader.name, loader)
	if spec is None:
		raise RuntimeError("could not create compiler-new-parity module spec")
	module = importlib.util.module_from_spec(spec)
	sys.modules[loader.name] = module
	loader.exec_module(module)
	return module


parity = load_parity_module()


def dump(
	path: str,
	tokens: list[str],
	lexer: int = 0,
	parse: int = 0,
	first: tuple[str, str] | None = None,
	help_line: str | None = None,
) -> str:
	lines = [f"== {path}", *tokens, f"lexer_diagnostics {lexer}", f"parse_diagnostics {parse}"]
	if first is not None:
		lines.append(f"first_diagnostic {first[0]} {first[1]}")
	if help_line is not None:
		lines.append(f"first_help {help_line}")
	return "\n".join(lines) + "\n"


EOF_TOKEN = ["0 0 EndOfFileToken"]


def compare_first(old: str, new: str, **allowances):
	return parity.compare_dumps(
		parity.parse_dump(old),
		parity.parse_dump(new),
		{},
		allowances.get("positions", {}),
		allowances.get("wording", ()),
		allowances.get("help_wording", ()),
	)


class CompilerNewParityTests(unittest.TestCase):
	def test_module_order_agrees_after_normalizing_discovery_paths(self) -> None:
		problems = parity.module_order_problems(
			"compile",
			"blorp/src/main.brp",
			["main", "prelude", "tuple", "blorp/src/a", "option"],
			[
				"blorp/src/main.brp",
				"standard_library/src/prelude.brp",
				"standard_library/src/tuple.brp",
				"blorp/src/a.brp",
				"standard_library/src/option.brp",
			],
		)
		self.assertEqual(problems, [])

	def test_module_order_names_the_first_difference(self) -> None:
		problems = parity.module_order_problems(
			"test",
			"blorp/src/main.brp",
			["main", "prelude", "tuple", "test"],
			["blorp/src/main.brp", "standard_library/src/prelude.brp", "standard_library/src/tuple.brp"],
		)
		self.assertTrue(problems[0].startswith("module order differs for test root"))
		self.assertIn("position 3: existing test, discovery (none)", problems[1])

	def test_hash_and_adjacent_name_merge_into_a_dimension_name(self) -> None:
		merged = parity.merge_dimension_names(
			["0 1 HashSymbol", "1 3 IdentifierToken Ds", "4 5 HashSymbol", "6 7 IdentifierToken x"]
		)
		self.assertEqual(
			merged,
			["0 3 DimensionNameToken Ds", "4 5 HashSymbol", "6 7 IdentifierToken x"],
		)

	def test_identical_dumps_agree(self) -> None:
		text = dump("a.brp", ["0 1 IdentifierToken x", "1 1 EndOfFileToken"])
		comparison = parity.compare_dumps(parity.parse_dump(text), parity.parse_dump(text), {})
		self.assertEqual(comparison.mismatched_files, 0)
		self.assertEqual(comparison.tokens, 2)

	def test_reports_the_file_and_first_differing_token(self) -> None:
		old = dump("a.brp", ["0 1 IdentifierToken x", "2 3 IdentifierToken y", "3 3 EndOfFileToken"])
		new = dump("a.brp", ["0 1 IdentifierToken x", "2 3 IdentifierToken z", "3 3 EndOfFileToken"])
		comparison = parity.compare_dumps(parity.parse_dump(old), parity.parse_dump(new), {})
		self.assertEqual(comparison.mismatched_files, 1)
		[problem] = comparison.problems
		self.assertIn("a.brp: first differing token #1", problem)
		self.assertIn("existing:  2 3 IdentifierToken y", problem)
		self.assertIn("discovery: 2 3 IdentifierToken z", problem)

	def test_reports_a_token_count_difference(self) -> None:
		old = dump("a.brp", ["0 1 IdentifierToken x", "1 1 EndOfFileToken"])
		new = dump("a.brp", ["0 1 IdentifierToken x"])
		comparison = parity.compare_dumps(parity.parse_dump(old), parity.parse_dump(new), {})
		self.assertIn("token count differs: existing 2, discovery 1", comparison.problems[0])

	def test_reports_lexer_diagnostic_and_verdict_differences(self) -> None:
		old = dump("a.brp", ["0 0 EndOfFileToken"], lexer=0, parse=0)
		new = dump("a.brp", ["0 0 EndOfFileToken"], lexer=1, parse=2)
		comparison = parity.compare_dumps(parity.parse_dump(old), parity.parse_dump(new), {})
		self.assertEqual(comparison.mismatched_files, 1)
		joined = "\n".join(comparison.problems)
		self.assertIn("a.brp: lexer diagnostics differ: existing 0, discovery 1", joined)
		self.assertIn("a.brp: verdict differs: existing accept", joined)

	def test_diagnostic_counts_of_one_side_do_not_matter_when_both_reject(self) -> None:
		old = dump("a.brp", ["0 0 EndOfFileToken"], parse=1)
		new = dump("a.brp", ["0 0 EndOfFileToken"], parse=5)
		comparison = parity.compare_dumps(parity.parse_dump(old), parity.parse_dump(new), {})
		self.assertEqual(comparison.mismatched_files, 0)
		self.assertEqual(comparison.rejected_by_both, 1)

	def test_a_file_missing_from_one_dump_is_a_mismatch(self) -> None:
		old = dump("a.brp", ["0 0 EndOfFileToken"]) + dump("b.brp", ["0 0 EndOfFileToken"])
		new = dump("a.brp", ["0 0 EndOfFileToken"])
		comparison = parity.compare_dumps(parity.parse_dump(old), parity.parse_dump(new), {})
		self.assertEqual(comparison.mismatched_files, 1)
		self.assertIn("b.brp: the discovery stage produced no dump", comparison.problems[0])

	def test_an_unreadable_file_is_a_mismatch(self) -> None:
		old = "unreadable a.brp: no such file\n"
		new = dump("a.brp", ["0 0 EndOfFileToken"])
		comparison = parity.compare_dumps(parity.parse_dump(old), parity.parse_dump(new), {})
		self.assertEqual(comparison.mismatched_files, 1)

	def test_a_known_divergence_is_noted_not_failed(self) -> None:
		old = dump("a.brp", ["0 0 EndOfFileToken"], parse=1)
		new = dump("a.brp", ["0 0 EndOfFileToken"], parse=0)
		comparison = parity.compare_dumps(
			parity.parse_dump(old), parity.parse_dump(new), {"a.brp": "a known reason"}
		)
		self.assertEqual(comparison.mismatched_files, 0)
		self.assertEqual(comparison.known_divergences, 1)
		self.assertIn("known divergence a.brp: a known reason", comparison.notes[0])

	def test_a_known_divergence_that_now_agrees_fails(self) -> None:
		text = dump("a.brp", ["0 0 EndOfFileToken"])
		comparison = parity.compare_dumps(
			parity.parse_dump(text), parity.parse_dump(text), {"a.brp": "a known reason"}
		)
		self.assertEqual(comparison.mismatched_files, 1)
		self.assertIn("but the front ends now agree", comparison.problems[0])

	def test_a_known_divergence_for_a_file_outside_the_corpus_fails(self) -> None:
		text = dump("a.brp", ["0 0 EndOfFileToken"])
		comparison = parity.compare_dumps(
			parity.parse_dump(text), parity.parse_dump(text), {"gone.brp": "a known reason"}
		)
		self.assertEqual(comparison.mismatched_files, 1)
		self.assertIn("gone.brp", comparison.problems[0])
		self.assertIn("not in the corpus", comparison.problems[0])

	def test_an_unlisted_construct_pair_is_named(self) -> None:
		text = dump("a.brp", EOF_TOKEN, parse=1, first=("1:1", "m")) + "unlisted_construct_pair ExpectedColonDiagnostic 8\n"
		comparison = compare_first(text, text)
		self.assertEqual(comparison.mismatched_files, 1)
		self.assertIn("ExpectedColonDiagnostic in ", comparison.problems[0])
		self.assertIn("does not list", comparison.problems[0])

	def test_the_same_first_diagnostic_agrees(self) -> None:
		text = dump("a.brp", EOF_TOKEN, parse=1, first=("3:5", "expected `)`"), help_line="close it")
		comparison = compare_first(text, text)
		self.assertEqual(comparison.mismatched_files, 0)
		self.assertEqual(comparison.first_diagnostics.compared, 1)
		self.assertEqual(comparison.first_diagnostics.message_differences, 0)

	def test_a_first_diagnostic_position_difference_names_both_lines(self) -> None:
		old = dump("a.brp", EOF_TOKEN, parse=1, first=("3:5", "expected `)`"))
		new = dump("a.brp", EOF_TOKEN, parse=1, first=("4:1", "expected `)`"))
		comparison = compare_first(old, new)
		self.assertEqual(comparison.mismatched_files, 1)
		[problem] = comparison.problems
		self.assertIn("a.brp: first diagnostic position differs", problem)
		self.assertIn("existing:  3:5 expected `)`", problem)
		self.assertIn("discovery: 4:1 expected `)`", problem)
		self.assertEqual(comparison.first_diagnostics.position_differences, 1)

	def test_a_known_position_divergence_is_counted_not_failed(self) -> None:
		old = dump("a.brp", EOF_TOKEN, parse=1, first=("3:5", "x"))
		new = dump("a.brp", EOF_TOKEN, parse=1, first=("4:1", "x"))
		comparison = compare_first(old, new, positions={"a.brp": "a reason"})
		self.assertEqual(comparison.mismatched_files, 0)
		self.assertEqual(comparison.first_diagnostics.known_positions_used, {"a.brp"})

	def test_a_message_difference_fails_unless_an_entry_allows_it(self) -> None:
		old = dump("a.brp", EOF_TOKEN, parse=1, first=("1:1", "expected `:` after if condition"))
		new = dump("a.brp", EOF_TOKEN, parse=1, first=("1:1", "expected `:`"))
		self.assertEqual(compare_first(old, new).mismatched_files, 1)
		entry = parity.WordingDifference(
			r"expected `:` after if condition", "expected `:`", "a reason"
		)
		allowed = compare_first(old, new, wording=(entry,))
		self.assertEqual(allowed.mismatched_files, 0)
		self.assertEqual(allowed.first_diagnostics.message_differences, 1)
		self.assertEqual(allowed.first_diagnostics.wording_used, {entry})

	def test_a_wording_entry_fills_named_groups_into_the_discovery_text(self) -> None:
		entry = parity.WordingDifference(
			r"`(?P<name>\w+)` is reserved; use `(?P=name)_x`", "`{name}` is reserved", "a reason"
		)
		self.assertTrue(entry.allows("`from` is reserved; use `from_x`", "`from` is reserved"))
		self.assertFalse(entry.allows("`from` is reserved; use `from_x`", "`to` is reserved"))
		self.assertFalse(entry.allows("`from` is reserved; use `to_x`", "`from` is reserved"))

	def test_a_help_the_existing_parser_lacks_may_be_added_but_not_dropped(self) -> None:
		bare = dump("a.brp", EOF_TOKEN, parse=1, first=("1:1", "m"))
		taught = dump("a.brp", EOF_TOKEN, parse=1, first=("1:1", "m"), help_line="do this")
		added = compare_first(bare, taught)
		self.assertEqual(added.mismatched_files, 0)
		self.assertEqual(added.first_diagnostics.helps_added, 1)
		dropped = compare_first(taught, bare)
		self.assertEqual(dropped.mismatched_files, 1)
		self.assertIn("first diagnostic help differs", dropped.problems[0])

	def test_a_changed_help_fails_unless_an_entry_allows_it(self) -> None:
		old = dump("a.brp", EOF_TOKEN, parse=1, first=("1:1", "m"), help_line="old advice")
		new = dump("a.brp", EOF_TOKEN, parse=1, first=("1:1", "m"), help_line="new advice")
		self.assertEqual(compare_first(old, new).mismatched_files, 1)
		entry = parity.WordingDifference(r"old advice", "new advice", "a reason")
		self.assertEqual(compare_first(old, new, help_wording=(entry,)).mismatched_files, 0)

	def test_a_file_one_front_end_reports_no_position_for_is_a_mismatch(self) -> None:
		old = dump("a.brp", EOF_TOKEN, parse=1, first=("1:1", "m"))
		new = dump("a.brp", EOF_TOKEN, parse=1, first=("none", ""))
		self.assertEqual(compare_first(old, new).mismatched_files, 1)

	def test_unused_allowances_are_reported_as_stale(self) -> None:
		entry = parity.WordingDifference(r"a", "b", "a reason")
		tally = parity.FirstDiagnosticTally()
		problems = parity.stale_allowance_problems(
			tally, {"gone.brp": "why"}, (entry,), (entry,), {"a.brp"}
		)
		joined = "\n".join(problems)
		self.assertIn("gone.brp: listed in KNOWN_POSITION_DIVERGENCES (why) but is not in the corpus", joined)
		self.assertIn("WORDING_DIFFERENCES entry no file needs any more", joined)
		self.assertIn("HELP_DIFFERENCES entry no file needs any more", joined)

	def test_a_known_position_that_now_agrees_is_stale(self) -> None:
		problems = parity.stale_allowance_problems(
			parity.FirstDiagnosticTally(), {"a.brp": "why"}, (), (), {"a.brp"}
		)
		self.assertIn("positions now agree", problems[0])

	def test_every_known_position_divergence_is_a_tracked_corpus_file(self) -> None:
		corpus = set(parity.corpus_files())
		for path in parity.KNOWN_POSITION_DIVERGENCES:
			self.assertIn(path, corpus)

	def test_every_known_divergence_is_a_tracked_corpus_file(self) -> None:
		corpus = set(parity.corpus_files())
		for path in parity.KNOWN_DIVERGENCES:
			self.assertIn(path, corpus)


if __name__ == "__main__":
	unittest.main()
