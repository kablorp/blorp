#!/usr/bin/env python3
"""Contract tests for the comparison in scripts/compiler-new-parity."""

from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
import unittest.mock


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
	def test_a_discovery_graph_with_enough_modules_is_complete(self) -> None:
		check = parity.RootCheck("compile root", "compile", "blorp/src/main.brp", 3)
		lines = [
			"user blorp/src/main.brp",
			"stdlib standard_library/src/prelude.brp",
			"stdlib standard_library/src/tuple.brp",
		]
		self.assertEqual(parity.degraded_graph_problems(check, lines), [])

	def test_a_discovery_graph_below_the_minimum_is_degraded(self) -> None:
		check = parity.RootCheck("test root", "test", "blorp/src/main.brp", 3)
		problems = parity.degraded_graph_problems(
			check,
			["user blorp/src/main.brp", "stdlib standard_library/src/prelude.brp"],
		)
		self.assertEqual(len(problems), 1)
		self.assertTrue(problems[0].startswith("discovery graph for test root"))
		self.assertIn("fewer than the expected minimum 3", problems[0])

	def test_a_package_check_needs_a_module_with_the_package_origin(self) -> None:
		check = parity.RootCheck(
			"source packages",
			"compile",
			"blorp/src/main.brp",
			1,
			required_origin_prefix=parity.SOURCE_PACKAGE_ORIGIN_PREFIX,
		)
		problems = parity.degraded_graph_problems(check, ["user blorp/src/main.brp"])
		self.assertEqual(len(problems), 1)
		self.assertIn("source-package:", problems[0])

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

	def adapter_output(self, *lines: str) -> str:
		return "\n".join(lines) + "\n"

	def adapter_problems(self, output: str, allowances=(), used=None, expected_skipped=None) -> list[str]:
		return parity.adapter_problems(
			"adapter differential, test root",
			parity.parse_adapter_output(output),
			allowances,
			set() if used is None else used,
			set() if expected_skipped is None else expected_skipped,
		)

	def test_a_clean_adapter_run_has_no_problems(self) -> None:
		output = self.adapter_output(
			"skipped a.brp | rejected by the existing parser",
			"summary modules=3 compared=2 skipped=1 declarations=40 differences=0",
		)
		report = parity.parse_adapter_output(output)
		self.assertEqual((report.modules, report.compared, report.skipped, report.declarations), (3, 2, 1, 40))
		self.assertEqual(report.skipped_paths, ["a.brp"])
		self.assertEqual(self.adapter_problems(output, expected_skipped={"a.brp"}), [])

	def test_a_module_skipped_without_being_rejected_fails_the_adapter_run(self) -> None:
		output = self.adapter_output(
			"skipped a.brp | rejected by the existing parser",
			"summary modules=3 compared=2 skipped=1 declarations=40 differences=0",
		)
		joined = "\n".join(self.adapter_problems(output, expected_skipped=set()))
		self.assertIn("skipped without being rejected", joined)

	def test_a_rejected_module_that_is_not_skipped_fails_the_adapter_run(self) -> None:
		output = self.adapter_output("summary modules=3 compared=3 skipped=0 declarations=40 differences=0")
		joined = "\n".join(self.adapter_problems(output, expected_skipped={"b.brp"}))
		self.assertIn("rejected but not skipped", joined)

	def test_an_adapter_error_line_is_a_problem(self) -> None:
		output = self.adapter_output(
			"adapter-error a.brp | the tables hold no row 3 of DefinitionTable",
			"summary modules=1 compared=0 skipped=0 declarations=0 differences=0",
		)
		self.assertIn("could not rebuild a module", "\n".join(self.adapter_problems(output)))

	def test_an_unlisted_adapter_difference_names_module_declaration_and_field(self) -> None:
		output = self.adapter_output(
			"difference app/a.brp | helper | decls[1].function.span.end_column | old=7 | new=9",
			"summary modules=1 compared=1 skipped=0 declarations=2 differences=1",
		)
		joined = "\n".join(self.adapter_problems(output))
		self.assertIn("app/a.brp | helper | decls[1].function.span.end_column", joined)
		self.assertIn("existing parser: 7", joined)
		self.assertIn("adapter:         9", joined)

	def test_an_adapter_difference_value_may_contain_the_separators(self) -> None:
		output = self.adapter_output(
			"difference a.brp | f | decls[0].doc | old=\"a \\| b\" | new=\"a \\| new=c\"",
			"summary modules=1 compared=1 skipped=0 declarations=1 differences=1",
		)
		report = parity.parse_adapter_output(output)
		self.assertEqual(report.problems, [])
		self.assertEqual((report.differences[0].old, report.differences[0].new), ('"a | b"', '"a | new=c"'))

	def test_a_listed_adapter_difference_is_allowed_and_marked_used(self) -> None:
		output = self.adapter_output(
			"difference app/a.brp | helper | decls[1].function.doc | old=null | new=\"x\"",
			"summary modules=1 compared=1 skipped=0 declarations=2 differences=1",
		)
		entry = parity.AdapterDifference(r"decls\[\d+\]\.function\.doc", "a reason", declaration="helper")
		used: set = set()
		self.assertEqual(self.adapter_problems(output, (entry,), used), [])
		self.assertEqual(used, {entry})
		self.assertEqual(parity.stale_adapter_allowances((entry,), used), [])

	def test_an_adapter_allowance_for_another_declaration_does_not_apply(self) -> None:
		output = self.adapter_output(
			"difference app/a.brp | helper | decls[1].function.doc | old=null | new=\"x\"",
			"summary modules=1 compared=1 skipped=0 declarations=2 differences=1",
		)
		entry = parity.AdapterDifference(r".*", "a reason", declaration="other")
		self.assertTrue(self.adapter_problems(output, (entry,)))

	def test_an_unused_adapter_allowance_is_stale(self) -> None:
		entry = parity.AdapterDifference(r"decls\[0\]", "a reason")
		problems = parity.stale_adapter_allowances((entry,), set())
		self.assertIn("ADAPTER_DIFFERENCES entry no module needs any more", problems[0])

	def test_an_adapter_run_that_printed_no_summary_fails(self) -> None:
		self.assertIn("printed no summary", "\n".join(self.adapter_problems("")))

	def test_an_adapter_run_that_compared_nothing_fails(self) -> None:
		output = self.adapter_output("summary modules=2 compared=0 skipped=2 declarations=0 differences=0")
		self.assertIn("no module was compared", "\n".join(self.adapter_problems(output)))

	def test_unknown_adapter_output_fails(self) -> None:
		output = self.adapter_output(
			"table invariants violated: 3",
			"summary modules=1 compared=1 skipped=0 declarations=1 differences=0",
		)
		self.assertIn("unexpected adapter differential output", "\n".join(self.adapter_problems(output)))

	def tree_prefix_output(self, *lines: str, updates=None, omitted=(), extra=()) -> str:
		counts = {
			"modules": 1, "compared": 1, "skipped": 0, "errors": 0,
			"declarations": 10, "completed_functions": 0, "completed_traits": 0, "completed_implementations": 0, "differences": 0, "reported": 0,
		}
		for kind in (
			"import_block", "foreign_block", "record", "fixed_record",
			"alias", "builtin_type", "resource_type", "union", "fixed_union", "enum",
		):
			counts[f"kind_{kind}"] = 1
		for kind in ("function", "trait", "implementation", "constant_global", "mutable_global"):
			counts[f"kind_{kind}"] = 0
		for stop in (
			"end_of_source", "function_header", "trait_preview", "implementation_preview",
			"global_initializer", "rejected_global_initializer", "rejected_declaration", "without_progress",
		):
			counts[f"stop_{stop}"] = int(stop == "end_of_source")
		counts.update({} if updates is None else updates)
		fields = [f"{name}={value}" for name, value in counts.items() if name not in omitted]
		return self.adapter_output(
			*lines,
			"tree-prefix-summary " + " ".join([*fields, *extra]),
			"summary modules=1 compared=1 skipped=0 declarations=10 differences=0",
		)

	def tree_prefix_problems(self, output: str, expected_skipped=None, require_completed_kinds=False) -> list[str]:
		return parity.tree_prefix_problems(
			"tree prefix, test root",
			parity.parse_adapter_output(output).tree_prefix,
			set() if expected_skipped is None else expected_skipped,
			require_completed_kinds=require_completed_kinds,
		)

	def test_clean_combined_output_preserves_both_adapter_reports(self) -> None:
		output = self.tree_prefix_output()
		report = parity.parse_adapter_output(output)
		self.assertEqual((report.modules, report.compared, report.declarations), (1, 1, 10))
		prefix = report.tree_prefix
		self.assertEqual((prefix.modules, prefix.compared, prefix.declarations), (1, 1, 10))
		self.assertEqual((prefix.skipped, prefix.errors, prefix.reported), (0, 0, 0))
		self.assertEqual((prefix.kinds["record"], prefix.kinds["fixed_record"]), (1, 1))
		self.assertEqual(prefix.stops["end_of_source"], 1)
		self.assertEqual(self.adapter_problems(output), [])
		self.assertEqual(self.tree_prefix_problems(output, require_completed_kinds=True), [])

	def test_tree_prefix_requires_one_summary(self) -> None:
		output = self.tree_prefix_output()
		summary = next(line for line in output.splitlines() if line.startswith("tree-prefix-summary "))
		for changed in (output.replace(summary + "\n", ""), output + summary + "\n"):
			with self.subTest(output=changed):
				self.assertTrue(self.tree_prefix_problems(changed))

	def test_tree_prefix_rejects_malformed_missing_unknown_and_negative_fields(self) -> None:
		outputs = (
			self.tree_prefix_output(updates={"modules": "many"}),
			self.tree_prefix_output(updates={"modules": -1}),
			self.tree_prefix_output(omitted=("declarations",)),
			self.tree_prefix_output(extra=("unexpected=0",)),
			self.tree_prefix_output(extra=("modules=1",)),
			self.tree_prefix_output(extra=("broken",)),
		)
		for output in outputs:
			with self.subTest(output=output):
				self.assertTrue(self.tree_prefix_problems(output))

	def test_tree_prefix_rejects_inconsistent_module_stop_and_kind_counts(self) -> None:
		for updates in (
			{"modules": 2}, {"stop_end_of_source": 0}, {"stop_function_header": 1},
			{"kind_record": 3}, {"skipped": 1, "modules": 2}, {"errors": 1, "modules": 2},
		):
			with self.subTest(updates=updates):
				self.assertTrue(self.tree_prefix_problems(self.tree_prefix_output(updates=updates)))

	def test_tree_prefix_skips_exactly_the_rejected_modules(self) -> None:
		output = self.tree_prefix_output(
			"tree-prefix-skipped a.brp | rejected by the existing parser",
			updates={"modules": 2, "skipped": 1},
		)
		self.assertEqual(parity.parse_adapter_output(output).tree_prefix.skipped_paths, ["a.brp"])
		self.assertEqual(self.tree_prefix_problems(output, expected_skipped={"a.brp"}), [])
		self.assertTrue(self.tree_prefix_problems(output))
		self.assertTrue(self.tree_prefix_problems(output, expected_skipped={"b.brp"}))
		self.assertTrue(self.tree_prefix_problems(self.tree_prefix_output(), expected_skipped={"a.brp"}))

	def test_tree_prefix_errors_name_the_module_stage_and_message(self) -> None:
		output = self.tree_prefix_output(
			"tree-prefix-error a.brp | projection | missing dimension literal token",
			updates={"modules": 2, "errors": 1},
		)
		joined = "\n".join(self.tree_prefix_problems(output))
		self.assertIn("a.brp", joined)
		self.assertIn("projection", joined)
		self.assertIn("missing dimension literal token", joined)

	def test_tree_prefix_rejects_malformed_skip_error_and_difference_lines(self) -> None:
		for line in (
			"tree-prefix-skipped", "tree-prefix-skipped a.brp",
			"tree-prefix-error", "tree-prefix-error a.brp | projection",
			"tree-prefix-difference a.brp | f | decls[0].doc | old=x",
		):
			with self.subTest(line=line):
				self.assertTrue(self.tree_prefix_problems(self.tree_prefix_output(line)))

	def test_tree_prefix_rejects_unknown_error_stages(self) -> None:
		output = self.tree_prefix_output(
			"tree-prefix-error a.brp | unknown | missing dimension literal token",
			updates={"modules": 2, "errors": 1},
		)
		problems = parity.parse_adapter_output(output).tree_prefix.problems
		self.assertTrue(any("unreadable tree prefix error line" in problem for problem in problems))

	def test_tree_prefix_completed_kind_counts_cannot_exceed_completed_declarations(self) -> None:
		output = self.tree_prefix_output(updates={"declarations": 8})
		problems = parity.parse_adapter_output(output).tree_prefix.problems
		self.assertIn("tree prefix completed kind counts exceed completed declarations", problems)

	def test_owner_coverage_may_exceed_its_preview_stops_but_not_fall_below(self) -> None:
		# A module can complete owners and then stop at a later one of the same kind.
		for kind, stop in (("trait", "trait_preview"), ("implementation", "implementation_preview")):
			with self.subTest(kind=kind):
				matched = {"stop_end_of_source": 0, f"stop_{stop}": 1, f"kind_{kind}": 1}
				self.assertEqual(self.tree_prefix_problems(self.tree_prefix_output(updates=matched)), [])
				uncovered = {"stop_end_of_source": 0, f"stop_{stop}": 1}
				problems = parity.parse_adapter_output(self.tree_prefix_output(updates=uncovered)).tree_prefix.problems
				self.assertTrue(any("coverage is below" in problem for problem in problems))

	def test_function_coverage_may_exceed_its_header_stops_but_not_fall_below(self) -> None:
		# A module can complete functions and then stop at a later function header.
		completed_then_stopped = {
			"stop_end_of_source": 0, "stop_function_header": 1, "kind_function": 1, "completed_functions": 2,
		}
		self.assertEqual(self.tree_prefix_problems(self.tree_prefix_output(updates=completed_then_stopped)), [])
		completed_only = {"kind_function": 1, "completed_functions": 2}
		self.assertEqual(self.tree_prefix_problems(self.tree_prefix_output(updates=completed_only)), [])
		uncovered_stop = {"stop_end_of_source": 0, "stop_function_header": 1}
		problems = parity.parse_adapter_output(self.tree_prefix_output(updates=uncovered_stop)).tree_prefix.problems
		self.assertTrue(any("function coverage is below" in problem for problem in problems))

	def test_tree_prefix_completed_functions_cannot_exceed_completed_declarations(self) -> None:
		output = self.tree_prefix_output(updates={"completed_functions": 11})
		problems = parity.parse_adapter_output(output).tree_prefix.problems
		self.assertIn("tree prefix completed function count exceeds completed declarations", problems)

	def test_clean_tree_prefix_global_coverage_includes_remaining_typed_stops(self) -> None:
		completed_and_stopped = {
			"stop_end_of_source": 0,
			"stop_global_initializer": 1,
			"kind_constant_global": 1,
			"kind_mutable_global": 1,
		}
		self.assertEqual(self.tree_prefix_problems(self.tree_prefix_output(updates=completed_and_stopped)), [])

		missing_stop_coverage = {
			"stop_end_of_source": 0,
			"stop_global_initializer": 1,
		}
		problems = parity.parse_adapter_output(self.tree_prefix_output(updates=missing_stop_coverage)).tree_prefix.problems
		self.assertTrue(any("coverage does not include" in problem for problem in problems))

	def test_differing_tree_prefix_boundary_may_earn_no_preview_coverage(self) -> None:
		output = self.tree_prefix_output(
			"tree-prefix-difference a.brp | helper | stop.kind | old=function | new=trait",
			updates={"differences": 1, "reported": 1, "stop_end_of_source": 0, "stop_trait_preview": 1},
		)
		self.assertEqual(parity.parse_adapter_output(output).tree_prefix.problems, [])
		self.assertTrue(self.tree_prefix_problems(output))

	def test_tree_prefix_difference_passes_only_when_an_allowance_names_it(self) -> None:
		output = self.tree_prefix_output(
			"tree-prefix-difference a.brp | helper | decls[0].value.kind | old=x | new=y",
			updates={"differences": 1, "reported": 1},
		)
		report = parity.parse_adapter_output(output).tree_prefix
		allowance = parity.AdapterDifference(path=r"decls\[0\]\.value\..*", reason="known fault", declaration="helper", module="a.brp")
		other_module = parity.AdapterDifference(path=r"decls\[0\]\.value\..*", reason="known fault", declaration="helper", module="b.brp")
		used: set = set()
		self.assertEqual(parity.tree_prefix_problems("tree prefix", report, set(), allowances=(allowance,), used=used), [])
		self.assertEqual(used, {allowance})
		self.assertTrue(parity.tree_prefix_problems("tree prefix", report, set(), allowances=(other_module,)))
		self.assertTrue(parity.tree_prefix_problems("tree prefix", report, set()))

	def test_full_adapter_error_does_not_fail_a_clean_tree_prefix_report(self) -> None:
		output = self.tree_prefix_output("adapter-error a.brp | the tables hold no row 3 of DefinitionTable")
		self.assertTrue(self.adapter_problems(output))
		self.assertEqual(self.tree_prefix_problems(output), [])

	def test_tree_prefix_difference_values_preserve_escaped_separators(self) -> None:
		output = self.tree_prefix_output(
			'tree-prefix-difference a.brp | f | decls[0].doc | old="a \\| b" | new="a \\| new=c"',
			updates={"differences": 1, "reported": 1},
		)
		report = parity.parse_adapter_output(output)
		self.assertEqual(report.differences, [])
		difference = report.tree_prefix.differences[0]
		self.assertEqual((difference.old, difference.new), ('"a | b"', '"a | new=c"'))
		self.assertTrue(self.tree_prefix_problems(output))

	def test_tree_prefix_truncated_differences_still_fail(self) -> None:
		output = self.tree_prefix_output(
			"tree-prefix-difference a.brp | Point | decls[0].span.end | old=7 | new=9",
			updates={"differences": 2, "reported": 1},
		)
		self.assertEqual(parity.parse_adapter_output(output).tree_prefix.problems, [])
		self.assertTrue(self.tree_prefix_problems(output))
		self.assertTrue(self.tree_prefix_problems(self.tree_prefix_output(updates={"differences": 1})))

	def test_tree_prefix_rejects_inconsistent_reported_difference_counts(self) -> None:
		line = "tree-prefix-difference a.brp | Point | decls[0].span.end | old=7 | new=9"
		for updates in ({"differences": 1, "reported": 0}, {"differences": 0, "reported": 1}):
			with self.subTest(updates=updates):
				report = parity.parse_adapter_output(self.tree_prefix_output(line, updates=updates))
				self.assertTrue(report.tree_prefix.problems)

	def test_tree_prefix_run_that_compared_nothing_fails(self) -> None:
		updates = {"modules": 0, "compared": 0, "declarations": 0, "stop_end_of_source": 0}
		for kind in (
			"import_block", "foreign_block", "record", "fixed_record",
			"alias", "builtin_type", "resource_type", "union", "fixed_union", "enum",
		):
			updates[f"kind_{kind}"] = 0
		self.assertTrue(self.tree_prefix_problems(self.tree_prefix_output(updates=updates)))

	def test_corpus_tree_prefix_requires_every_completed_declaration_kind(self) -> None:
		for kind in (
			"import_block", "foreign_block", "record", "fixed_record",
			"alias", "builtin_type", "resource_type", "union", "fixed_union", "enum",
		):
			with self.subTest(kind=kind):
				output = self.tree_prefix_output(updates={f"kind_{kind}": 0})
				self.assertEqual(self.tree_prefix_problems(output), [])
				self.assertIn(kind, "\n".join(self.tree_prefix_problems(output, require_completed_kinds=True)))

	def test_tree_prefix_rejects_missing_unknown_and_negative_kind_or_stop_counts(self) -> None:
		for output in (
			self.tree_prefix_output(omitted=("kind_fixed_record",)),
			self.tree_prefix_output(omitted=("kind_fixed_union",)),
			self.tree_prefix_output(omitted=("stop_end_of_source",)),
			self.tree_prefix_output(extra=("kind_value_record=1",)),
			self.tree_prefix_output(extra=("kind_struct=1",)),
			self.tree_prefix_output(extra=("stop_unknown=1",)),
			self.tree_prefix_output(updates={"kind_fixed_record": -1}),
			self.tree_prefix_output(updates={"kind_fixed_union": -1}),
			self.tree_prefix_output(updates={"stop_end_of_source": -1}),
		):
			with self.subTest(output=output):
				self.assertTrue(self.tree_prefix_problems(output))

	def test_tree_prefix_rejected_and_nonprogressing_stops_fail_on_accepted_modules(self) -> None:
		for stop in ("rejected_global_initializer", "rejected_declaration", "without_progress"):
			with self.subTest(stop=stop):
				output = self.tree_prefix_output(updates={"stop_end_of_source": 0, f"stop_{stop}": 1})
				self.assertTrue(self.tree_prefix_problems(output))

	def test_adapter_allowances_cannot_allow_tree_prefix_differences(self) -> None:
		output = self.tree_prefix_output(
			"tree-prefix-difference a.brp | helper | decls[0].function.doc | old=null | new=x",
			updates={"differences": 1, "reported": 1},
		)
		entry = parity.AdapterDifference(r"decls\[\d+\]\.function\.doc", "a reason", declaration="helper")
		used: set = set()
		self.assertEqual(self.adapter_problems(output, (entry,), used), [])
		self.assertEqual(used, set())
		self.assertTrue(self.tree_prefix_problems(output))

	def tree_module_output(self, *lines: str, updates=None, omitted=(), extra=()) -> str:
		counts = {
			"modules": 3, "assembled": 2, "rejected": 0, "unassembled": 1, "skipped": 0, "errors": 0,
			"differences": 0, "reported": 0,
		}
		for stop in (
			"function_body", "trait_bodies", "implementation_bodies", "global_initializer",
			"rejected_global_initializer", "rejected_declaration", "without_progress",
		):
			counts[f"stop_{stop}"] = int(stop == "function_body")
		counts.update({} if updates is None else updates)
		fields = [f"{name}={value}" for name, value in counts.items() if name not in omitted]
		return self.adapter_output(*lines, "tree-module-summary " + " ".join([*fields, *extra]))

	def tree_module_problems(self, output: str, expected_skipped=None, allowances=(), used=None) -> list[str]:
		return parity.tree_module_problems(
			"tree module, test root",
			parity.parse_adapter_output(output).tree_module,
			set() if expected_skipped is None else expected_skipped,
			allowances,
			set() if used is None else used,
		)

	def test_a_clean_tree_module_run_has_no_problems(self) -> None:
		output = self.tree_module_output()
		report = parity.parse_adapter_output(output).tree_module
		self.assertEqual((report.totals["assembled"], report.totals["unassembled"]), (2, 1))
		self.assertEqual(report.stops["function_body"], 1)
		self.assertEqual(self.tree_module_problems(output), [])

	def test_tree_module_requires_one_complete_summary(self) -> None:
		output = self.tree_module_output()
		summary = output.strip()
		for changed in (
			"", output + summary + "\n",
			self.tree_module_output(omitted=("assembled",)),
			self.tree_module_output(extra=("unknown=1",)),
			self.tree_module_output(updates={"assembled": "two"}),
		):
			with self.subTest(output=changed):
				self.assertTrue(self.tree_module_problems(changed))

	def test_tree_module_counts_must_account_for_every_module_and_line(self) -> None:
		for updates in (
			{"modules": 4}, {"stop_function_body": 0}, {"skipped": 1, "modules": 4},
			{"errors": 1, "modules": 4}, {"rejected": 1, "modules": 4}, {"reported": 1, "differences": 1},
		):
			with self.subTest(updates=updates):
				self.assertTrue(self.tree_module_problems(self.tree_module_output(updates=updates)))

	def test_a_module_the_tree_path_rejects_fails(self) -> None:
		output = self.tree_module_output("tree-module-rejected a.brp | 1", updates={"rejected": 1, "modules": 4})
		self.assertEqual(parity.parse_adapter_output(output).tree_module.problems, [])
		self.assertIn("a.brp", "\n".join(self.tree_module_problems(output)))

	def test_a_census_error_names_the_module_and_fails(self) -> None:
		output = self.tree_module_output(
			"tree-module-error a.brp | census | 1 problems, first expression 3 issued and not held",
			updates={"errors": 1, "modules": 4},
		)
		joined = "\n".join(self.tree_module_problems(output))
		self.assertIn("a.brp", joined)
		self.assertIn("census", joined)
		unknown_stage = self.tree_module_output(
			"tree-module-error a.brp | unknown | x", updates={"errors": 1, "modules": 4},
		)
		self.assertTrue(parity.parse_adapter_output(unknown_stage).tree_module.problems)

	def test_tree_module_skips_exactly_the_rejected_modules(self) -> None:
		output = self.tree_module_output(
			"tree-module-skipped a.brp | rejected by the existing parser", updates={"skipped": 1, "modules": 4},
		)
		self.assertEqual(self.tree_module_problems(output, expected_skipped={"a.brp"}), [])
		self.assertTrue(self.tree_module_problems(output))

	def test_tree_module_difference_passes_only_when_an_allowance_names_it(self) -> None:
		output = self.tree_module_output(
			"tree-module-difference a.brp | helper | decls[0].body.kind | old=x | new=y",
			updates={"differences": 1, "reported": 1},
		)
		allowance = parity.AdapterDifference(path=r"decls\[0\]\.body\..*", reason="known fault", module="a.brp")
		used: set = set()
		self.assertEqual(self.tree_module_problems(output, allowances=(allowance,), used=used), [])
		self.assertEqual(used, {allowance})
		self.assertTrue(self.tree_module_problems(output))
		truncated = self.tree_module_output(
			"tree-module-difference a.brp | helper | decls[0].body.kind | old=x | new=y",
			updates={"differences": 2, "reported": 1},
		)
		self.assertTrue(self.tree_module_problems(truncated, allowances=(allowance,)))

	def test_tree_module_rejected_stops_fail_on_accepted_modules(self) -> None:
		for stop in ("rejected_global_initializer", "rejected_declaration", "without_progress"):
			with self.subTest(stop=stop):
				output = self.tree_module_output(updates={"stop_function_body": 0, f"stop_{stop}": 1})
				self.assertTrue(self.tree_module_problems(output))

	def test_the_repository_lists_no_unexplained_adapter_difference(self) -> None:
		for entry in parity.ADAPTER_DIFFERENCES:
			self.assertTrue(entry.reason.strip())


class StopCensusTest(unittest.TestCase):
	OUTPUT = "\n".join([
		"difference ignored.brp | x | y | old=1 | new=2",
		"stop-reason a.brp | function | multiline-call-arguments | 10 | first",
		"stop-reason a.brp | function | lambda-header | 30 | later",
		"stop-reason b.brp | function | multiline-call-arguments | 4 | first",
		"stop-reason b.brp | function | multiline-call-arguments | 9 | later",
		"stop-reason c.brp | global-initializer | with-block | 2 | first",
		"tree-prefix-summary modules=3",
	])

	def test_counts_first_stops_as_modules_and_every_stop_as_declarations(self) -> None:
		census = parity.parse_stop_census(self.OUTPUT)
		calls = census.reasons["multiline-call-arguments"]
		self.assertEqual((calls.modules, calls.declarations, calls.example), (2, 3, "a.brp:10"))
		later_only = census.reasons["lambda-header"]
		self.assertEqual((later_only.modules, later_only.declarations, later_only.example), (0, 1, ""))
		self.assertEqual(census.kinds, {"function": 2, "global-initializer": 1})

	def test_ranks_by_first_stops_then_declarations_then_name(self) -> None:
		table = parity.render_stop_census(parity.parse_stop_census(self.OUTPUT), 5).splitlines()
		rows = [line.split(" | ")[1] for line in table if line.startswith("| ") and line[2].isdigit()]
		self.assertEqual(rows, ["multiline-call-arguments", "with-block", "lambda-header"])
		self.assertIn("| 1 | multiline-call-arguments | 2 | 66.7% | 3 | a.brp:10 |", table)
		self.assertIn("| 3 | lambda-header | 0 | 0.0% | 1 | - |", table)

	def test_rejects_a_malformed_line(self) -> None:
		with self.assertRaises(SystemExit):
			parity.parse_stop_census("stop-reason a.brp | function | x | 1")
		with self.assertRaises(SystemExit):
			parity.parse_stop_census("stop-reason a.brp | function | x | 1 | middle")


class TargetedRunTest(unittest.TestCase):
	CENSUS = StopCensusTest.OUTPUT
	CORPUS = ["a.brp", "b.brp", "c.brp", "d.brp"]

	def exit_message(self, call) -> str:
		with self.assertRaises(SystemExit) as raised:
			call()
		return str(raised.exception.code)

	def test_first_stop_locations_give_each_modules_line(self) -> None:
		text = "stop-reason a.brp | function | with-block | 12 | first\nstop-reason a.brp | function | with-block | 30 | later\n"
		self.assertEqual(parity.first_stop_locations(text, "with-block"), [("a.brp", 12)])

	def test_a_census_line_without_a_line_number_is_an_exit_not_a_crash(self) -> None:
		text = "stop-reason a.brp | function | with-block | x | first\n"
		message = self.exit_message(lambda: parity.first_stop_locations(text, "with-block"))
		self.assertIn("malformed stop-reason line", message)

	def test_a_stop_reason_selects_the_modules_whose_first_stop_had_it(self) -> None:
		self.assertEqual(
			parity.first_stop_modules(self.CENSUS, "multiline-call-arguments"), ["a.brp", "b.brp"]
		)
		# a.brp stops later at lambda-header, but its first stop is another reason.
		self.assertEqual(parity.first_stop_modules(self.CENSUS, "with-block"), ["c.brp"])

	def test_a_reason_that_only_stops_later_declarations_selects_nothing_and_says_so(self) -> None:
		message = self.exit_message(lambda: parity.first_stop_modules(self.CENSUS, "lambda-header"))
		self.assertIn("no module's first stop was lambda-header", message)

	def test_an_unknown_reason_lists_the_reasons_the_census_has(self) -> None:
		message = self.exit_message(lambda: parity.first_stop_modules(self.CENSUS, "multiline-call"))
		self.assertIn("multiline-call", message)
		self.assertIn("multiline-call-arguments", message)
		self.assertIn("with-block", message)

	def test_files_must_be_corpus_files_and_come_back_in_corpus_order(self) -> None:
		self.assertEqual(parity.select_files(["c.brp", "a.brp", "c.brp"], self.CORPUS), ["a.brp", "c.brp"])
		message = self.exit_message(lambda: parity.select_files(["a.brp", "typo.brp"], self.CORPUS))
		self.assertIn("typo.brp", message)
		self.assertNotIn("a.brp is not", message)

	def test_a_census_file_keeps_only_the_stop_lines_and_selects_like_the_census(self) -> None:
		text = parity.census_result_text(self.CENSUS, "header text")
		self.assertTrue(text.startswith("# header text\n"))
		self.assertNotIn("difference ignored", text)
		self.assertEqual(parity.first_stop_modules(text, "with-block"), ["c.brp"])
		self.assertEqual(
			parity.render_stop_census(parity.parse_stop_census(text), 3),
			parity.render_stop_census(parity.parse_stop_census(self.CENSUS), 3),
		)

	def test_a_missing_census_file_names_the_command_that_writes_it(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			message = self.exit_message(lambda: parity.read_census_result(Path(directory) / "absent.txt"))
		self.assertIn("--stop-census", message)

	def test_a_stored_census_is_read_back_with_its_header(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			path = Path(directory) / "stop-census.txt"
			parity.write_census_result(path, self.CENSUS, "recorded at abc")
			text, header = parity.read_census_result(path)
		self.assertEqual(header, "recorded at abc")
		self.assertEqual(parity.first_stop_modules(text, "with-block"), ["c.brp"])

	def test_the_default_census_file_is_per_checkout_under_the_temporary_directory(self) -> None:
		first = parity.default_census_file(Path("/work/one"))
		self.assertEqual(first, parity.default_census_file(Path("/work/one")))
		self.assertNotEqual(first, parity.default_census_file(Path("/work/two")))
		self.assertTrue(str(first).startswith(tempfile.gettempdir()))

	def test_only_a_full_corpus_census_is_stored(self) -> None:
		full = parity.CorpusSelection.full(self.CORPUS)
		targeted = parity.CorpusSelection.of_files(["a.brp"], "one file")
		self.assertTrue(full.stores_census)
		self.assertFalse(targeted.stores_census)
		self.assertEqual(full.paths, tuple(self.CORPUS))
		self.assertFalse(full.targeted)
		self.assertTrue(targeted.targeted)

	def test_a_targeted_comparison_does_not_require_allowance_files_outside_it(self) -> None:
		self.assertTrue(parity.KNOWN_DIVERGENCES)
		agreeing = dump("a.brp", EOF_TOKEN)
		comparison = parity.compare_selected_dumps(
			parity.parse_dump(agreeing), parity.parse_dump(agreeing), ("a.brp",)
		)
		self.assertEqual(comparison.problems, [])
		self.assertEqual(comparison.mismatched_files, 0)

	def test_a_targeted_comparison_still_fails_a_selected_disagreement(self) -> None:
		comparison = parity.compare_selected_dumps(
			parity.parse_dump(dump("a.brp", EOF_TOKEN)),
			parity.parse_dump(dump("a.brp", ["0 1 IdentifierToken x", *EOF_TOKEN])),
			("a.brp",),
		)
		self.assertEqual(comparison.mismatched_files, 1)

	def test_a_targeted_report_is_not_the_gate_result(self) -> None:
		comparison = parity.compare_selected_dumps({}, {}, ())
		captured = io.StringIO()
		with contextlib.redirect_stdout(captured):
			parity.report(comparison, 1.0, parity.CorpusSelection.of_files(["a.brp"], "one file"))
		self.assertIn("targeted", captured.getvalue())
		self.assertNotIn("BLORP_GATE_RESULT", captured.getvalue())
		full = io.StringIO()
		with contextlib.redirect_stdout(full):
			parity.report(comparison, 1.0, parity.CorpusSelection.full(self.CORPUS))
		self.assertIn("BLORP_GATE_RESULT gate=compiler_new_parity", full.getvalue())

	def test_a_targeted_adapter_run_skips_the_root_runs_and_compares_only_the_listed_files(self) -> None:
		full = parity.adapter_runs(Path("list.txt"), parity.CorpusSelection.full(self.CORPUS))
		self.assertEqual(len(full), len(parity.ROOT_CHECKS) + 1)
		self.assertNotIn(parity.ONLY_LISTED_FLAG, full[-1][1])
		targeted = parity.adapter_runs(
			Path("list.txt"), parity.CorpusSelection.of_files(["a.brp"], "one file")
		)
		self.assertEqual(len(targeted), 1)
		self.assertEqual(targeted[0][1], (parity.ADAPTER_FILES_MODE, "list.txt", parity.ONLY_LISTED_FLAG))

	def adapter_report(self, listed, compared, skipped=0, modules=None) -> "parity.AdapterReport":
		lines = [f"listed-module {path}" for path in listed]
		lines.append(
			f"summary modules={len(listed) if modules is None else modules} compared={compared} "
			f"skipped={skipped} declarations=0 differences=0"
		)
		return parity.parse_adapter_output("\n".join(lines) + "\n")

	def test_a_targeted_adapter_run_must_cover_exactly_the_selected_files(self) -> None:
		selected = ("a.brp", "b.brp")
		self.assertEqual(
			parity.selection_problems("run", self.adapter_report(selected, compared=2), selected), []
		)
		# One rejected by the existing parser is skipped, still covered.
		self.assertEqual(
			parity.selection_problems("run", self.adapter_report(selected, compared=1, skipped=1), selected), []
		)
		reached_other = parity.selection_problems(
			"run", self.adapter_report(("a.brp", "c.brp"), compared=2), selected
		)
		self.assertIn("1 not reached (for example ['b.brp'])", reached_other[0])
		self.assertIn("1 others compared (for example ['c.brp'])", reached_other[0])
		self.assertTrue(parity.selection_problems("run", self.adapter_report((), compared=0, modules=0), selected))

	def test_a_targeted_adapter_run_must_account_for_every_selected_file(self) -> None:
		selected = ("a.brp", "b.brp")
		self.assertTrue(
			parity.selection_problems("run", self.adapter_report(selected, compared=1), selected)
		)
		self.assertTrue(
			parity.selection_problems("run", self.adapter_report(selected, compared=2, modules=3), selected)
		)
		duplicated = self.adapter_report(("a.brp", "a.brp"), compared=2)
		self.assertTrue(parity.selection_problems("run", duplicated, selected))

	def run_targeted(self, adapter_only: bool, adapter_result, selection=None):
		selection = selection or parity.CorpusSelection.of_files(["a.brp", "b.brp"], "two files")
		built = []
		output = io.StringIO()
		with unittest.mock.patch.object(
			parity, "build_dumper", side_effect=lambda source, work, chosen: built.append(source)
		), unittest.mock.patch.object(
			parity, "check_adapter", return_value=adapter_result
		), contextlib.redirect_stdout(output):
			status = parity.run_targeted_parity(Path("work"), Path("list"), selection, adapter_only, 0.0)
		return status, built, output.getvalue()

	def test_an_adapter_only_run_builds_no_token_dumper_and_counts_the_selected_files(self) -> None:
		status, built, printed = self.run_targeted(True, ([], [], 0))
		self.assertEqual((status, built), (0, []))
		self.assertIn("targeted run over two files (not the gate): PASS files=2", printed)

	def test_an_adapter_problem_fails_a_targeted_run_without_a_gate_result(self) -> None:
		status, _, printed = self.run_targeted(True, ([], ["adapter differential, two files: boom"], 1))
		self.assertEqual(status, 1)
		self.assertIn("boom", printed)
		self.assertIn("FAIL", printed)
		self.assertNotIn("BLORP_GATE_RESULT", printed)

	def choose(self, arguments, tracked, census=None):
		options = parity.parse_arguments(arguments)
		with unittest.mock.patch.object(parity, "tracked_files", return_value=tracked), \
				contextlib.redirect_stdout(io.StringIO()):
			return parity.choose_selection(options, ["a.brp", "b.brp"])

	def test_no_selection_option_chooses_the_whole_corpus(self) -> None:
		selection = self.choose([], ["a.brp", "b.brp", "c.brp"])
		self.assertEqual((selection.paths, selection.targeted), (("a.brp", "b.brp"), False))

	def test_files_may_be_any_tracked_source_file_not_only_corpus_roots(self) -> None:
		selection = self.choose(["--files", "c.brp"], ["a.brp", "b.brp", "c.brp"])
		self.assertEqual((selection.paths, selection.targeted), (("c.brp",), True))
		with self.assertRaises(SystemExit):
			self.choose(["--files", "elsewhere.brp"], ["a.brp"])

	def test_a_stop_reason_selects_tracked_modules_from_the_stored_census(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			census = Path(directory) / "stop-census.txt"
			parity.write_census_result(census, self.CENSUS, "recorded")
			selection = self.choose(
				["--stop-reason", "multiline-call-arguments", "--census-file", str(census)], ["a.brp", "b.brp"]
			)
		self.assertEqual((selection.paths, selection.targeted), (("a.brp", "b.brp"), True))
		self.assertIn("multiline-call-arguments", selection.description)

	def test_a_stop_reason_leaves_out_modules_no_longer_tracked(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			census = Path(directory) / "stop-census.txt"
			parity.write_census_result(census, self.CENSUS, "recorded")
			selection = self.choose(
				["--stop-reason", "multiline-call-arguments", "--census-file", str(census)], ["b.brp"]
			)
		self.assertEqual(selection.paths, ("b.brp",))

	def test_files_and_stop_reason_are_exclusive_and_adapter_only_needs_a_selection(self) -> None:
		options = parity.parse_arguments(["--files", "a.brp", "b.brp", "--adapter-only"])
		self.assertEqual((options.files, options.adapter_only), (["a.brp", "b.brp"], True))
		self.assertEqual(parity.parse_arguments(["--stop-reason", "with-block"]).stop_reason, "with-block")
		for arguments in (
			["--files", "a.brp", "--stop-reason", "with-block"],
			["--adapter-only"],
			["--files", "a.brp", "--compare", "x", "y"],
			["--census-file", "x"] + ["--compare", "x", "y"],
		):
			with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
				with self.assertRaises(SystemExit):
					parity.parse_arguments(arguments)


if __name__ == "__main__":
	unittest.main()
