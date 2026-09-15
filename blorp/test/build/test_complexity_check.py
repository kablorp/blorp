#!/usr/bin/env python3
"""Contract tests for scripts/complexity-check."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
COMPLEXITY_CHECK = ROOT / "scripts" / "complexity-check"


def location(line: int) -> dict[str, object]:
	return {
		"kind": "known",
		"file": "example.brp",
		"line": line,
		"column": 1,
		"end_line": line,
		"end_column": 10,
	}


def variable(name: str, line: int = 1, uniq: int = 0) -> dict[str, object]:
	return {"kind": "var", "var": {"name": name, "uniq": uniq}, "loc": location(line)}


def void(line: int = 1) -> dict[str, object]:
	return {"kind": "void", "loc": location(line)}


def call(
	name: str,
	args: list[dict[str, object]],
	line: int,
	def_id: int = 99,
) -> dict[str, object]:
	return {
		"kind": "call",
		"call_kind": {"kind": "user", "name": name, "def_id": def_id},
		"callee": variable(name, line),
		"args": args,
		"loc": location(line),
	}


def core_function(
	name: str,
	body: dict[str, object],
	params: list[str] | None = None,
	def_id: int = 99,
) -> dict[str, object]:
	return {
		"kind": "function",
		"name": name,
		"module": "example",
		"params": [
			{"name": {"name": param, "uniq": 0}, "type": {"kind": "named", "name": "Any"}}
			for param in params or []
		],
		"body": body,
		"def_id": def_id,
		"loc": location(3),
	}


def append_assignment(name: str, line: int) -> dict[str, object]:
	length = variable("append_length", uniq=1)
	grown = variable("append_result", uniq=1)
	new_length = {
		"kind": "binary",
		"op": "add",
		"left": length,
		"right": integer(1),
	}
	return {
		"kind": "assign",
		"var": {"name": name, "uniq": 0},
		"rhs": {
			"kind": "let",
			"name": {"name": "append_length", "uniq": 1},
			"rhs": call("list_len", [variable(name)], line),
			"body": {
				"kind": "let",
				"name": {"name": "append_result", "uniq": 1},
				"rhs": call("list_ensure_capacity", [variable(name), new_length], line),
				"body": {
					"kind": "seq",
					"first": call("list_set_len", [grown, new_length], line),
					"second": grown,
				},
			},
		},
		"loc": location(line),
	}


def for_list(
	iterable: dict[str, object],
	body: dict[str, object],
	line: int,
	binder: str = "item",
) -> dict[str, object]:
	return {
		"kind": "for_list",
		"for_list": {
			"binder": {"var": {"name": binder, "uniq": 0}},
			"iterable": iterable,
			"body": body,
		},
		"loc": location(line),
	}


def for_range(
	start: dict[str, object],
	end: dict[str, object],
	body: dict[str, object],
	line: int,
) -> dict[str, object]:
	return {
		"kind": "for_range",
		"binder": {
			"var": {"name": "index", "uniq": 0},
			"range_direction": "forward_only",
		},
		"start": start,
		"end": end,
		"body": body,
		"loc": location(line),
	}


def integer(value: int) -> dict[str, object]:
	return {"kind": "literal", "literal": {"kind": "int", "value": str(value)}}


def string(value: str) -> dict[str, object]:
	return {"kind": "literal", "literal": {"kind": "string", "value": value}}


def program(
	body: dict[str, object],
	extra_decls: list[dict[str, object]] | None = None,
) -> dict[str, object]:
	return {
		"kind": "program",
		"decls": [core_function("example__scan_pairs", body, def_id=1), *(extra_decls or [])],
		"foreign_includes": [],
	}


class ComplexityCheckTests(unittest.TestCase):
	def setUp(self) -> None:
		self.tempdir = tempfile.TemporaryDirectory()
		self.root = Path(self.tempdir.name)

	def tearDown(self) -> None:
		self.tempdir.cleanup()

	def write_core(self, value: dict[str, object], annotated: bool = False) -> Path:
		path = self.root / "program.core"
		encoded = json.dumps(value)
		if annotated:
			encoded = "-- blorp example.brp\n===== after specialize =====\n" + encoded + "\n"
		path.write_text(encoded, encoding="utf-8")
		return path

	def run_check(self, core_file: Path, *args: str) -> subprocess.CompletedProcess[str]:
		return subprocess.run(
			[
				sys.executable,
				str(COMPLEXITY_CHECK),
				"--core-file",
				str(core_file),
				"--json",
				*args,
			],
			cwd=ROOT,
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=False,
		)

	def test_reports_nested_traversal_of_same_collection_as_quadratic(self) -> None:
		body = for_list(
			variable("items"),
			for_list(variable("items"), void(), line=12),
			line=10,
		)

		result = self.run_check(self.write_core(program(body), annotated=True))

		self.assertEqual(result.returncode, 0, result.stderr)
		report = json.loads(result.stdout)
		self.assertEqual(report["finding_count"], 1)
		finding = report["findings"][0]
		self.assertEqual(finding["rule"], "nested-traversal")
		self.assertEqual(finding["function"], "example__scan_pairs")
		self.assertEqual(finding["degree"], 2)
		self.assertEqual(finding["complexity"], "O(items^2)")
		self.assertEqual(finding["confidence"], "structural-candidate")
		self.assertEqual(finding["location"], {"file": "example.brp", "line": 12})

	def test_reports_independent_nested_traversals_with_both_dimensions(self) -> None:
		body = for_list(
			variable("modules"),
			for_list(variable("declarations"), void(), line=22),
			line=20,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["complexity"], "O(modules * declarations)")
		self.assertEqual(finding["dimensions"], ["modules", "declarations"])

	def test_uses_core_variable_identity_for_shadowed_names(self) -> None:
		body = for_list(
			variable("items", uniq=1),
			for_list(variable("items", uniq=2), void(), line=27),
			line=26,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["complexity"], "O(items#1 * items#2)")

	def test_folds_outer_binder_children_into_one_aggregate_dimension(self) -> None:
		child_fields = {
			"kind": "field",
			"expr": variable("module"),
			"field": "declarations",
			"loc": location(29),
		}
		body = for_list(
			variable("modules"),
			for_list(child_fields, void(), line=29),
			line=28,
			binder="module",
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_aggregate_child_dimension_still_multiplies_a_full_scan(self) -> None:
		child_fields = {
			"kind": "field",
			"expr": variable("module"),
			"field": "declarations",
			"loc": location(29),
		}
		body = for_list(
			variable("modules"),
			for_list(
				child_fields,
				for_list(variable("all_names"), void(), line=30),
				line=29,
				binder="declaration",
			),
			line=28,
			binder="module",
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["complexity"], "O(total(module.declarations) * all_names)")
		self.assertEqual(finding["relationship"], "independent-dimensions")

	def test_reports_list_contains_inside_a_dynamic_traversal(self) -> None:
		body = for_list(
			variable("items"),
			call("list__contains__mono_String", [variable("seen"), variable("item")], 33),
			line=32,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["rule"], "linear-scan-in-traversal")
		self.assertEqual(finding["complexity"], "O(items * seen)")
		self.assertEqual(finding["location"], {"file": "example.brp", "line": 33})

	def test_reports_list_any_inside_a_dynamic_traversal(self) -> None:
		predicate = {"kind": "lambda", "body": void(36), "loc": location(36)}
		body = for_list(
			variable("diagnostics"),
			call("list__any__pure__mono_Diagnostic", [variable("accepted"), predicate], 36),
			line=35,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["rule"], "linear-scan-in-traversal")
		self.assertEqual(finding["complexity"], "O(diagnostics * accepted)")

	def test_reports_other_known_linear_list_operations_inside_traversals(self) -> None:
		body = for_list(
			variable("modules"),
			call("list__map__pure__mono_Decl", [variable("declarations"), void()], 37),
			line=36,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["rule"], "linear-scan-in-traversal")
		self.assertEqual(finding["complexity"], "O(modules * declarations)")
		self.assertIn("list__map", finding["evidence"])

	def test_reports_known_quadratic_list_unique_without_an_outer_loop(self) -> None:
		body = call("list__unique__mono_String", [variable("items")], 39)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["rule"], "known-quadratic-operation")
		self.assertEqual(finding["complexity"], "O(items^2)")
		self.assertEqual(finding["confidence"], "known-operation-cost")

	def test_reports_list_sort_cost_inside_an_outer_traversal(self) -> None:
		body = for_list(
			variable("rounds"),
			call("list__sort__mono_String", [variable("items")], 40),
			line=39,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["rule"], "n-log-n-operation-in-traversal")
		self.assertEqual(finding["degree"], 2)
		self.assertEqual(finding["complexity"], "O(rounds * items * log(items))")

	def test_does_not_report_a_top_level_n_log_n_sort_at_degree_two(self) -> None:
		body = call("list__sort__mono_String", [variable("items")], 41)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_reports_dynamic_substring_search_as_two_dimensions(self) -> None:
		body = call("string__contains", [variable("haystack"), variable("needle")], 42)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["rule"], "known-quadratic-operation")
		self.assertEqual(finding["complexity"], "O(haystack * needle)")

	def test_treats_a_literal_string_needle_as_constant_cost(self) -> None:
		body = for_list(
			variable("items"),
			call("string__raw_index_of", [variable("name"), string(":"), integer(0)], 43),
			line=42,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		findings = json.loads(result.stdout)["findings"]
		self.assertEqual([finding["complexity"] for finding in findings], ["O(items * name)"])
		self.assertEqual(findings[0]["rule"], "linear-scan-in-traversal")

	def test_treats_a_literal_string_haystack_as_fixed_work(self) -> None:
		body = for_list(
			variable("items"),
			call("string__contains", [string("constant"), variable("needle")], 44),
			line=43,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_reports_dict_value_scan_inside_a_traversal(self) -> None:
		body = for_list(
			variable("values"),
			call("dict__contains_value__mono_String_Int", [variable("table"), variable("value")], 44),
			line=43,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["complexity"], "O(values * table)")

	def test_reports_each_dynamic_concat_input_inside_a_traversal(self) -> None:
		body = for_list(
			variable("chunks"),
			call("list__concat__mono_String", [variable("prefix"), variable("chunk")], 41),
			line=40,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		findings = json.loads(result.stdout)["findings"]
		self.assertEqual(
			{finding["complexity"] for finding in findings},
			{"O(chunks * prefix)", "O(chunks * chunk)"},
		)

	def test_deduplicates_the_same_concat_input_at_one_source_site(self) -> None:
		body = for_list(
			variable("chunks"),
			call("list__concat__mono_String", [variable("items"), variable("items")], 43),
			line=42,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["finding_count"], 1)

	def test_derives_a_one_hop_parameter_scan_summary(self) -> None:
		helper = core_function(
			"example__append_unique",
			call("list__contains__mono_String", [variable("seen"), variable("item")], 44),
			params=["seen", "item"],
		)
		body = for_list(
			variable("items"),
			call("example__append_unique", [variable("seen"), variable("item")], 46),
			line=45,
		)

		result = self.run_check(self.write_core(program(body, [helper])))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["rule"], "summarized-operation-cost")
		self.assertEqual(finding["complexity"], "O(items * seen)")
		self.assertEqual(finding["confidence"], "derived-one-hop-summary")

	def test_one_hop_summary_preserves_a_quadratic_parameter_cost(self) -> None:
		helper = core_function(
			"example__deduplicate",
			call("list__unique__mono_String", [variable("items")], 47),
			params=["items"],
		)
		body = call("example__deduplicate", [variable("items")], 48)

		result = self.run_check(self.write_core(program(body, [helper])))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = next(
			item
			for item in json.loads(result.stdout)["findings"]
			if item["rule"] == "summarized-operation-cost"
		)
		self.assertEqual(finding["rule"], "summarized-operation-cost")
		self.assertEqual(finding["complexity"], "O(items^2)")

	def test_does_not_propagate_summaries_transitively(self) -> None:
		scan_helper = core_function(
			"example__scan_helper",
			call("list__contains__mono_String", [variable("seen"), variable("item")], 48),
			params=["seen", "item"],
			def_id=98,
		)
		wrapper = core_function(
			"example__wrapper",
			call("example__scan_helper", [variable("seen"), variable("item")], 49),
			params=["seen", "item"],
			def_id=99,
		)
		body = for_list(
			variable("items"),
			call("example__wrapper", [variable("seen"), variable("item")], 51),
			line=50,
		)

		result = self.run_check(self.write_core(program(body, [scan_helper, wrapper])))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_does_not_match_a_summary_when_function_ids_disagree(self) -> None:
		helper = core_function(
			"example__helper",
			call("list__contains__mono_String", [variable("seen"), variable("item")], 49),
			params=["seen", "item"],
			def_id=20,
		)
		body = for_list(
			variable("items"),
			call(
				"example__helper",
				[variable("seen"), variable("item")],
				51,
				def_id=999,
			),
			line=50,
		)

		result = self.run_check(self.write_core(program(body, [helper])))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_ignores_non_node_metadata_while_building_summaries(self) -> None:
		body = for_list(
			variable("items"),
			{
				"kind": "seq",
				"first": {"kind": {"kind": "pointer"}},
				"second": void(),
			},
			line=50,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_does_not_summarize_a_scan_nested_below_a_traversal(self) -> None:
		helper = core_function(
			"example__scan_each",
			for_list(
				variable("xs"),
				call("list__contains__mono_String", [variable("ys"), variable("x")], 52),
				line=51,
			),
			params=["xs", "ys"],
		)
		body = for_list(
			variable("rounds"),
			call("example__scan_each", [variable("xs"), variable("ys")], 54),
			line=53,
		)

		result = self.run_check(self.write_core(program(body, [helper])))

		self.assertEqual(result.returncode, 0, result.stderr)
		findings = json.loads(result.stdout)["findings"]
		self.assertFalse(any(item["rule"] == "summarized-operation-cost" for item in findings))
		self.assertIn("O(xs * ys)", {item["complexity"] for item in findings})

	def test_does_not_apply_a_function_summary_to_its_recursive_call(self) -> None:
		recursive_call = for_list(
			variable("rounds"),
			call("example__recursive", [variable("items"), variable("needle")], 54),
			line=53,
		)
		recursive = core_function(
			"example__recursive",
			{
				"kind": "seq",
				"first": call(
					"list__contains__mono_String",
					[variable("items"), variable("needle")],
					52,
				),
				"second": recursive_call,
			},
			params=["items", "needle"],
			def_id=97,
		)

		result = self.run_check(self.write_core(program(void(), [recursive])))

		self.assertEqual(result.returncode, 0, result.stderr)
		findings = json.loads(result.stdout)["findings"]
		self.assertFalse(any(item["rule"] == "summarized-operation-cost" for item in findings))

	def test_refines_a_growing_accumulator_scan_to_quadratic(self) -> None:
		body = for_list(
			variable("items"),
			{
				"kind": "seq",
				"first": call(
					"list__contains__mono_String",
					[variable("result"), variable("item")],
					54,
				),
				"second": append_assignment("result", 55),
			},
			line=53,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		findings = json.loads(result.stdout)["findings"]
		self.assertEqual(
			{finding["complexity"] for finding in findings},
			{"O(items * result)", "O(items^2)"},
		)
		growth = next(item for item in findings if item["rule"] == "growing-accumulator-scan")
		self.assertEqual(growth["relationship"], "repeated-dimension")
		self.assertEqual(growth["confidence"], "monotone-growth-pattern")

	def test_discarded_append_result_does_not_prove_accumulator_growth(self) -> None:
		discarded_append = {
			"kind": "assign",
			"var": {"name": "result", "uniq": 0},
			"rhs": {
				"kind": "seq",
				"first": call(
					"list__append__mono_String",
					[variable("result"), variable("item")],
					56,
				),
				"second": variable("result"),
			},
			"loc": location(56),
		}
		body = for_list(
			variable("items"),
			{
				"kind": "seq",
				"first": call(
					"list__contains__mono_String",
					[variable("result"), variable("item")],
					55,
				),
				"second": discarded_append,
			},
			line=54,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		findings = json.loads(result.stdout)["findings"]
		self.assertEqual([item["complexity"] for item in findings], ["O(items * result)"])

	def test_capacity_reservation_alone_is_not_accumulator_growth(self) -> None:
		reserve = {
			"kind": "assign",
			"var": {"name": "result", "uniq": 0},
			"rhs": call("list_ensure_capacity", [variable("result"), integer(8)], 57),
			"loc": location(57),
		}
		body = for_list(
			variable("items"),
			{
				"kind": "seq",
				"first": call(
					"list__contains__mono_String",
					[variable("result"), variable("item")],
					56,
				),
				"second": reserve,
			},
			line=55,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["rule"], "linear-scan-in-traversal")
		self.assertEqual(finding["complexity"], "O(items * result)")

	def test_does_not_treat_plain_append_as_an_inherently_linear_scan(self) -> None:
		body = for_list(
			variable("items"),
			call("list__append__mono_String", [variable("result"), variable("item")], 57),
			line=56,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_deduplicates_equivalent_costs_at_one_source_site(self) -> None:
		scan = call("list__contains__mono_String", [variable("seen"), variable("item")], 59)
		body = for_list(
			variable("items"),
			{"kind": "seq", "first": scan, "second": scan},
			line=58,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["finding_count"], 1)

	def test_folds_a_linear_scan_of_an_outer_binder_child(self) -> None:
		names = {
			"kind": "field",
			"expr": variable("module"),
			"field": "names",
			"loc": location(37),
		}
		body = for_list(
			variable("modules"),
			call("list__contains__mono_String", [names, variable("name")], 37),
			line=36,
			binder="module",
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_folded_child_scan_still_multiplies_other_active_dimensions(self) -> None:
		names = {
			"kind": "field",
			"expr": variable("module"),
			"field": "names",
			"loc": location(40),
		}
		body = for_list(
			variable("modules"),
			for_list(
				variable("candidates"),
				call("list__contains__mono_String", [names, variable("candidate")], 40),
				line=39,
			),
			line=38,
			binder="module",
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = next(
			item
			for item in json.loads(result.stdout)["findings"]
			if item["rule"] == "linear-scan-in-traversal"
		)
		self.assertEqual(finding["complexity"], "O(candidates * total(module.names))")
		self.assertEqual(finding["relationship"], "independent-dimensions")

	def test_marks_a_call_derived_scan_from_an_outer_binder_as_dependent(self) -> None:
		derived_names = call("names_for", [variable("module")], 43)
		body = for_list(
			variable("modules"),
			call(
				"list__contains__mono_String",
				[derived_names, variable("name")],
				43,
			),
			line=42,
			binder="module",
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["relationship"], "dependent-inner")

	def test_does_not_report_constant_or_non_list_membership_scans(self) -> None:
		literal_list = {
			"kind": "list_construct",
			"construct": {"elements": [integer(1), integer(2)]},
		}
		constant_scan = for_list(
			variable("items"),
			call("list__contains__mono_Int", [literal_list, variable("item")], 38),
			line=37,
		)
		set_scan = for_list(
			variable("items"),
			call("set__contains__mono_Int", [variable("seen"), variable("item")], 40),
			line=39,
		)
		body = {"kind": "seq", "first": constant_scan, "second": set_scan}

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_does_not_report_a_top_level_linear_scan(self) -> None:
		body = call("list__contains__mono_String", [variable("items"), variable("needle")], 41)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_source_input_stops_at_post_dce_core(self) -> None:
		compiler = self.root / "fake-blorp"
		compiler.write_text(
			"#!/bin/sh\n"
			"saw_dump=0\n"
			"saw_stop=0\n"
			"for arg in \"$@\"; do\n"
			"  case \"$arg\" in\n"
			"    --dump-core-after=dce) saw_dump=1 ;;\n"
			"    --stop-after=dce) saw_stop=1 ;;\n"
			"    --dump-core-file=*) output=${arg#*=} ;;\n"
			"  esac\n"
			"done\n"
			"[ \"$saw_dump\" -eq 1 ] && [ \"$saw_stop\" -eq 1 ] || exit 9\n"
			"printf '%s\\n' '{\"kind\":\"program\",\"decls\":[],\"foreign_includes\":[]}' > \"$output\"\n",
			encoding="utf-8",
		)
		compiler.chmod(0o755)
		source = self.root / "example.brp"
		source.write_text("func main(): void\n", encoding="utf-8")
		result = subprocess.run(
			[
				sys.executable,
				str(COMPLEXITY_CHECK),
				str(source),
				"--compiler",
				str(compiler),
				"--json",
			],
			cwd=ROOT,
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=False,
		)

		self.assertEqual(result.returncode, 0, result.stderr)
		report = json.loads(result.stdout)
		self.assertEqual(report["schema_version"], 2)
		self.assertEqual(report["stage"], "dce")

	def test_raw_core_reports_unknown_stage(self) -> None:
		result = self.run_check(self.write_core(program(void())))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["stage"], "unknown")

	def test_annotated_core_reports_the_selected_stage(self) -> None:
		result = self.run_check(self.write_core(program(void()), annotated=True))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["stage"], "specialize")

	def test_multistage_core_prefers_and_reports_the_dce_object(self) -> None:
		dce_program = program(
			for_list(
				variable("items"),
				for_list(variable("items"), void(), line=46),
				line=45,
			)
		)
		final_program = program(void())
		path = self.root / "multistage.core"
		path.write_text(
			"===== after dce =====\n"
			+ json.dumps(dce_program)
			+ "\n===== after final =====\n"
			+ json.dumps(final_program)
			+ "\n",
			encoding="utf-8",
		)

		result = self.run_check(path)

		self.assertEqual(result.returncode, 0, result.stderr)
		report = json.loads(result.stdout)
		self.assertEqual(report["stage"], "dce")
		self.assertEqual(report["finding_count"], 1)

	def test_does_not_multiply_sequential_or_constant_bound_loops(self) -> None:
		sequential = {
			"kind": "seq",
			"first": for_list(variable("left"), void(), line=30),
			"second": for_list(variable("right"), void(), line=31),
		}
		constant_outer = for_range(
			integer(0),
			integer(4),
			for_list(variable("items"), void(), line=35),
			line=34,
		)
		body = {"kind": "seq", "first": sequential, "second": constant_outer}

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_does_not_multiply_a_fixed_collection_literal(self) -> None:
		literal_list = {
			"kind": "list_construct",
			"construct": {"elements": [integer(1), integer(2)]},
		}
		body = for_list(
			literal_list,
			for_list(variable("items"), void(), line=39),
			line=38,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_minimum_degree_filters_findings(self) -> None:
		body = for_list(
			variable("a"),
			for_list(variable("b"), void(), line=42),
			line=41,
		)

		result = self.run_check(self.write_core(program(body)), "--minimum-degree", "3")

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["finding_count"], 0)

	def test_findings_only_fail_when_requested(self) -> None:
		body = for_list(
			variable("left"),
			for_list(variable("right"), void(), line=47),
			line=46,
		)

		result = self.run_check(self.write_core(program(body)), "--fail-on-findings")

		self.assertEqual(result.returncode, 1, result.stderr)
		self.assertEqual(json.loads(result.stdout)["finding_count"], 1)

	def test_module_prefix_filters_functions(self) -> None:
		body = for_list(
			variable("left"),
			for_list(variable("right"), void(), line=49),
			line=48,
		)

		result = self.run_check(
			self.write_core(program(body)),
			"--module-prefix",
			"different/module",
		)

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_reports_each_nested_site_once_at_its_full_degree(self) -> None:
		body = for_list(
			variable("a"),
			for_list(
				variable("b"),
				for_list(variable("c"), void(), line=53),
				line=52,
			),
			line=51,
		)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		findings = json.loads(result.stdout)["findings"]
		self.assertEqual([(item["degree"], item["location"]["line"]) for item in findings], [(3, 53), (2, 52)])

	def test_concurrent_traversal_contributes_to_total_work(self) -> None:
		concurrent = {
			"kind": "pre_closure_concurrently_loop",
			"pre_closure_concurrently_loop": {
				"var": {"name": "task_item", "uniq": 0},
				"iterable": variable("tasks"),
				"body": for_list(variable("items"), void(), line=62),
				"timeout": None,
				"limit": integer(4),
			},
			"loc": location(61),
		}

		result = self.run_check(self.write_core(program(concurrent)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(finding["complexity"], "O(tasks * items)")
		self.assertEqual(finding["metric"], "worst-case work")

	def test_lambda_body_starts_a_new_execution_context(self) -> None:
		deferred = {
			"kind": "lambda",
			"body": for_list(variable("inner"), void(), line=68),
			"loc": location(67),
		}
		body = for_list(variable("outer"), deferred, line=66)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		self.assertEqual(json.loads(result.stdout)["findings"], [])

	def test_dynamic_range_identity_includes_start_end_and_direction(self) -> None:
		outer = for_range(
			variable("start"),
			integer(10),
			for_range(variable("other_start"), integer(10), void(), line=73),
			line=72,
		)
		result = self.run_check(self.write_core(program(outer)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(
			finding["complexity"],
			"O(range(start..10) * range(other_start..10))",
		)

	def test_range_direction_participates_in_dimension_identity(self) -> None:
		inner = for_range(variable("start"), variable("end"), void(), line=76)
		inner["binder"]["range_direction"] = "may_run_backward"
		outer = for_range(variable("start"), variable("end"), inner, line=75)

		result = self.run_check(self.write_core(program(outer)))

		self.assertEqual(result.returncode, 0, result.stderr)
		finding = json.loads(result.stdout)["findings"][0]
		self.assertEqual(
			finding["complexity"],
			"O(range(start..end) * range(start..end))",
		)
		self.assertEqual(finding["relationship"], "independent-dimensions")

	def test_rejects_a_malformed_known_traversal_shape(self) -> None:
		body = {"kind": "for_list", "for_list": {"iterable": variable("items")}}

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 2)
		self.assertIn("for_list is missing a Core expression body", result.stderr)

	def test_rejects_a_malformed_known_operation_shape(self) -> None:
		body = call("list__unique__mono_String", [], 78)

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 2)
		self.assertIn("list__unique is missing a required Core argument", result.stderr)

	def test_rejects_missing_loop_binder_metadata(self) -> None:
		body = {
			"kind": "for_list",
			"for_list": {"iterable": variable("items"), "body": void()},
		}

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 2)
		self.assertIn("for_list is missing a Core loop binder", result.stderr)

	def test_ranking_orders_repeated_independent_then_dependent(self) -> None:
		repeated = for_list(
			variable("same"),
			for_list(variable("same"), void(), line=82),
			line=81,
		)
		independent = for_list(
			variable("left"),
			for_list(variable("right"), void(), line=84),
			line=83,
		)
		derived_children = call("children_for", [variable("parent")], 86)
		dependent = for_list(
			variable("parents"),
			for_list(derived_children, void(), line=86),
			line=85,
			binder="parent",
		)
		body = {
			"kind": "seq",
			"first": repeated,
			"second": {
				"kind": "seq",
				"first": independent,
				"second": dependent,
			},
		}

		result = self.run_check(self.write_core(program(body)))

		self.assertEqual(result.returncode, 0, result.stderr)
		relationships = [item["relationship"] for item in json.loads(result.stdout)["findings"]]
		self.assertEqual(
			relationships,
			["repeated-dimension", "independent-dimensions", "dependent-inner"],
		)

	def test_rejects_a_core_dump_without_a_program(self) -> None:
		path = self.root / "bad.core"
		path.write_text("===== after specialize =====\nnot json\n", encoding="utf-8")

		result = self.run_check(path)

		self.assertEqual(result.returncode, 2)
		self.assertIn("could not parse Core JSON", result.stderr)


if __name__ == "__main__":
	unittest.main()
