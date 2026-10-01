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


def dump(path: str, tokens: list[str], lexer: int = 0, parse: int = 0) -> str:
	lines = [f"== {path}", *tokens, f"lexer_diagnostics {lexer}", f"parse_diagnostics {parse}"]
	return "\n".join(lines) + "\n"


class CompilerNewParityTests(unittest.TestCase):
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

	def test_every_known_divergence_is_a_tracked_corpus_file(self) -> None:
		corpus = set(parity.corpus_files())
		for path in parity.KNOWN_DIVERGENCES:
			self.assertIn(path, corpus)


if __name__ == "__main__":
	unittest.main()
