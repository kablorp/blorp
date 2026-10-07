#!/usr/bin/env python3
"""Contract tests for scripts/discovery-fuzz: the mutation generator, the
verdict classification around the runner process, and the minimiser.

The runner process is replaced by a small script that speaks the same protocol,
so no test compiles Blorp.
"""

from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import random
import stat
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "discovery-fuzz"


def load_fuzzer():
    loader = importlib.machinery.SourceFileLoader("discovery_fuzz", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create discovery-fuzz module spec")
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


fuzz = load_fuzzer()

SAMPLE_DECLARATION = textwrap.dedent(
    """\
    ---
    Doubles each element.
    ---
    pure func doubled(items: List[Int]) -> List[Int]:
    \titems.map(pure func(item):
    \t\titem * 2
    \t)
    """
).splitlines()

SAMPLE_SOURCE = (
    ["-- A module comment.", "import:", "\tlist: map, filter", ""]
    + SAMPLE_DECLARATION
    + ["", "-- A constant.", "LIMIT: Int = 4", ""]
    + ["record Point { x: Int, y: Int }"]
)


def non_blank(lines: list[str]) -> list[str]:
    return [line for line in lines if line.strip()]


class TokenizerTest(unittest.TestCase):
    def test_tokens_partition_every_source_they_are_given(self) -> None:
        texts = ["", "\n\n", 'x = "a ${b} \\" c" -- note\n', "aé = 1.5e3 ..# \x00 $\n"]
        texts += [(ROOT / "standard_library/src/list.brp").read_text(encoding="utf-8")]
        for text in texts:
            self.assertEqual(fuzz.join_tokens(fuzz.tokenize(text)), text)

    def test_strings_comments_and_brackets_are_single_tokens(self) -> None:
        tokens = fuzz.tokenize('f("a, b") -- c, d\n')
        self.assertEqual(
            [token.text for token in tokens if token.is_code], ["f", "(", '"a, b"', ")"]
        )


class DeclarationUnitTest(unittest.TestCase):
    def test_every_code_line_belongs_to_exactly_one_declaration(self) -> None:
        units = fuzz.declaration_units(SAMPLE_SOURCE)
        is_code = fuzz.line_is_code(SAMPLE_SOURCE)
        for index, code in enumerate(is_code):
            owners = [unit for unit in units if unit[0] <= index < unit[1]]
            if code:
                self.assertEqual(len(owners), 1, SAMPLE_SOURCE[index])

    def test_documentation_above_a_declaration_belongs_to_it(self) -> None:
        units = [SAMPLE_SOURCE[start:end] for start, end in fuzz.declaration_units(SAMPLE_SOURCE)]
        self.assertIn(SAMPLE_DECLARATION, units)

    def test_a_declaration_ends_at_its_last_line_not_the_blank_ones_after(self) -> None:
        for start, end in fuzz.declaration_units(SAMPLE_SOURCE):
            self.assertTrue(SAMPLE_SOURCE[end - 1].strip())
            self.assertFalse(SAMPLE_SOURCE[start].startswith(" "))

    def test_a_closing_bracket_in_column_zero_continues_its_declaration(self) -> None:
        lines = ["LIST: List[Int] = [", "\t1,", "]", "OTHER: Int = 2"]
        self.assertEqual(fuzz.declaration_units(lines), [(0, 3), (3, 4)])

    def test_stop_lines_select_the_declaration_that_holds_them(self) -> None:
        units = [fuzz.Unit("a.brp", 0, 3), fuzz.Unit("a.brp", 5, 9), fuzz.Unit("b.brp", 0, 4)]
        chosen = fuzz.units_at_stops(units, [("a.brp", 6), ("a.brp", 4), ("b.brp", 1), ("c.brp", 1)])
        self.assertEqual(chosen, [units[1], units[2]])


class OperatorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.lines = list(SAMPLE_DECLARATION)
        self.rng = random.Random(7)
        self.target = 4  # `items.map(pure func(item):`

    def test_delete_line_removes_exactly_that_line(self) -> None:
        mutated = fuzz.delete_line(self.lines, self.target, self.rng)
        self.assertEqual(mutated, self.lines[: self.target] + self.lines[self.target + 1 :])

    def test_duplicate_line_repeats_it_in_place(self) -> None:
        mutated = fuzz.duplicate_line(self.lines, self.target, self.rng)
        self.assertEqual(mutated[self.target], mutated[self.target + 1])
        self.assertEqual(len(mutated), len(self.lines) + 1)

    def test_swap_lines_keeps_the_same_lines(self) -> None:
        mutated = fuzz.swap_lines(self.lines, self.target, self.rng)
        self.assertNotEqual(mutated, self.lines)
        self.assertEqual(sorted(mutated), sorted(self.lines))

    def test_indent_changes_touch_only_one_lines_leading_whitespace(self) -> None:
        for operator in (fuzz.change_indent_level, fuzz.change_indent_spaces, fuzz.swap_tabs_and_spaces):
            for seed in range(20):
                mutated = operator(self.lines, 5, random.Random(seed))
                if mutated is None:
                    continue
                self.assertEqual(len(mutated), len(self.lines))
                changed = [i for i, (a, b) in enumerate(zip(self.lines, mutated)) if a != b]
                self.assertLessEqual(len(changed), 1)
                for i in changed:
                    self.assertEqual(self.lines[i].lstrip(" \t"), mutated[i].lstrip(" \t"))

    def test_indentation_can_move_a_level_in_the_lines_own_style(self) -> None:
        tabbed = {fuzz.change_indent_level(["\tx"], 0, random.Random(seed))[0] for seed in range(30)}
        self.assertEqual(tabbed, {"x", "\t\tx"})
        spaced = {fuzz.change_indent_level(["    x"], 0, random.Random(seed))[0] for seed in range(30)}
        self.assertEqual(spaced, {"x", "        x"})

    def test_tabs_become_spaces_and_back(self) -> None:
        spaced = fuzz.swap_tabs_and_spaces(["\t\tx"], 0, random.Random(3))
        self.assertIn(" ", spaced[0])
        tabbed = fuzz.swap_tabs_and_spaces(["        x"], 0, random.Random(3))
        self.assertEqual(tabbed, ["\t    x"])
        self.assertIsNone(fuzz.swap_tabs_and_spaces(["x"], 0, random.Random(3)))

    def test_join_lines_makes_one_line_of_two(self) -> None:
        mutated = fuzz.join_lines(["a(", "\tb)"], 0, random.Random(1))
        self.assertEqual(len(mutated), 1)
        self.assertEqual(mutated[0].replace(" ", ""), "a(b)")
        self.assertIsNone(fuzz.join_lines(["only"], 0, random.Random(1)))

    def test_split_line_cuts_between_tokens_and_keeps_every_token(self) -> None:
        for seed in range(20):
            mutated = fuzz.split_line(["\tf(a, b)"], 0, random.Random(seed))
            self.assertEqual(len(mutated), 2)
            before = [t.text for t in fuzz.tokenize("\tf(a, b)") if t.is_code]
            after = [t.text for line in mutated for t in fuzz.tokenize(line) if t.is_code]
            self.assertEqual(before, after)
        self.assertIsNone(fuzz.split_line(["\tx"], 0, random.Random(1)))

    def test_deleting_and_duplicating_a_token_change_the_line_by_that_token(self) -> None:
        line = "\tf(abc, b)"
        lengths = {len(token.text) for token in fuzz.tokenize(line) if token.is_code}
        for seed in range(30):
            deleted = fuzz.delete_token([line], 0, random.Random(seed))[0]
            self.assertIn(len(line) - len(deleted), lengths)
            duplicated = fuzz.duplicate_token([line], 0, random.Random(seed))[0]
            self.assertIn(len(duplicated) - len(line), lengths)

    def test_inserting_a_token_adds_only_a_symbol_a_word_or_a_line_break(self) -> None:
        line = "\tf(a, b)"
        for seed in range(60):
            mutated = fuzz.insert_token([line], 0, random.Random(seed))
            joined = "\n".join(mutated)
            added = len(joined) - len(line)
            self.assertTrue(1 <= added <= 2 + max(len(word) for word in fuzz.INSERTED_WORDS) + 4, joined)

    def test_a_closing_bracket_moves_to_another_line_without_being_lost(self) -> None:
        line = ["\tf(a, b)", "\tg()"]
        for seed in range(20):
            mutated = fuzz.move_closing_bracket(line, 0, random.Random(seed))
            self.assertEqual("".join(mutated).count(")"), 2)
            self.assertNotIn(")", mutated[0])
        self.assertIsNone(fuzz.move_closing_bracket(["\tx"], 0, random.Random(1)))

    def test_mutation_never_edits_comments_or_documentation(self) -> None:
        documentation = SAMPLE_DECLARATION[:3]
        for seed in range(200):
            result = fuzz.mutate_lines(list(SAMPLE_DECLARATION), random.Random(seed))
            self.assertIsNotNone(result)
            _, mutated = result
            self.assertEqual(mutated[:3], documentation)

    def test_a_unit_with_no_code_has_no_mutation(self) -> None:
        self.assertIsNone(fuzz.mutate_lines(["-- only a comment", ""], random.Random(1)))


class GeneratorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.sources = {"a.brp": SAMPLE_SOURCE, "b.brp": list(reversed(SAMPLE_SOURCE))}
        self.units = fuzz.corpus_units(self.sources, fuzz.DEFAULT_MAX_UNIT_LINES)

    def generate(self, seed: int, count: int, whole_file: bool = False) -> list:
        return list(fuzz.generate_mutants(seed, count, self.units, self.sources, whole_file))

    def test_a_seed_gives_the_same_mutants_every_time(self) -> None:
        self.assertEqual(self.generate(3, 40), self.generate(3, 40))

    def test_a_larger_count_extends_the_same_sequence(self) -> None:
        self.assertEqual(self.generate(3, 40)[:25], self.generate(3, 25))

    def test_different_seeds_give_different_mutants(self) -> None:
        self.assertNotEqual([m.text for m in self.generate(1, 30)], [m.text for m in self.generate(2, 30)])

    def test_every_mutant_differs_from_its_original_and_from_the_others(self) -> None:
        mutants = self.generate(5, 60)
        self.assertEqual(len({m.text for m in mutants}), len(mutants))
        for mutant in mutants:
            self.assertNotEqual(mutant.text, mutant.original)

    def test_a_declaration_mutant_is_one_declaration(self) -> None:
        for mutant in self.generate(5, 30):
            lines = self.sources[mutant.unit.path][mutant.unit.start : mutant.unit.end]
            self.assertEqual(mutant.original, "\n".join(lines) + "\n")

    def test_a_whole_file_mutant_changes_only_inside_the_declaration(self) -> None:
        for mutant in self.generate(5, 30, whole_file=True):
            lines = self.sources[mutant.unit.path]
            mutated = mutant.text.removesuffix("\n").split("\n")
            self.assertEqual(mutated[: mutant.unit.start], lines[: mutant.unit.start])
            tail = len(lines) - mutant.unit.end
            self.assertEqual(mutated[len(mutated) - tail :] if tail else [], lines[mutant.unit.end :])

    def test_a_corpus_with_few_mutants_ends_instead_of_looping(self) -> None:
        sources = {"a.brp": ["x"]}
        units = fuzz.corpus_units(sources, 10)
        mutants = list(fuzz.generate_mutants(1, 500, units, sources, False))
        self.assertLess(len(mutants), 500)

    def test_overlong_declarations_are_not_mutated(self) -> None:
        sources = {"a.brp": ["func f() -> Int:"] + ["\t1"] * 50}
        self.assertEqual(fuzz.corpus_units(sources, 10), [])


class CorpusTest(unittest.TestCase):
    def test_fixtures_that_pin_a_known_divergence_are_not_mutated(self) -> None:
        corpus = fuzz.mutable_corpus()
        self.assertTrue(corpus)
        self.assertEqual(set(corpus) & set(fuzz.parity.KNOWN_DIVERGENCES), set())


class VerdictTest(unittest.TestCase):
    def test_parity_violations_and_a_broken_tree_path_fail_the_gate(self) -> None:
        failing = {v for v in fuzz.Verdict if v.is_failure}
        self.assertEqual(
            failing,
            {
                fuzz.Verdict.WRONG_ACCEPT,
                fuzz.Verdict.AST_MISMATCH,
                fuzz.Verdict.WRONG_REJECT,
                fuzz.Verdict.TREE_ERROR,
                fuzz.Verdict.TREE_CRASH,
                fuzz.Verdict.TREE_HANG,
            },
        )

    def test_a_stop_and_an_old_parser_failure_are_not_failures(self) -> None:
        for verdict in (
            fuzz.Verdict.AGREE,
            fuzz.Verdict.SAFE_STOP,
            fuzz.Verdict.BOTH_REJECTED,
            fuzz.Verdict.REJECT_DECLINED,
            fuzz.Verdict.OLD_CRASH,
            fuzz.Verdict.OLD_HANG,
        ):
            self.assertFalse(verdict.is_failure, verdict)

    def test_every_verdict_has_a_headline(self) -> None:
        for verdict in fuzz.Verdict:
            self.assertTrue(verdict.headline)

    def test_result_lines_carry_the_verdict_and_detail(self) -> None:
        name, outcome = fuzz.parse_result_line("fuzz-result m1.brp | ast-mismatch | a | b")
        self.assertEqual((name, outcome), ("m1.brp", fuzz.Outcome(fuzz.Verdict.AST_MISMATCH, "a | b")))

    def test_an_unreadable_result_is_a_protocol_error_not_a_verdict(self) -> None:
        for line in (
            "fuzz-result m1.brp | agree",
            "fuzz-result m1.brp | surprising | ",
            "fuzz-result m1.brp | tool-error | unreadable source",
        ):
            with self.assertRaises(fuzz.RunnerProtocolError, msg=line):
                fuzz.parse_result_line(line)


FAKE_RUNNER = '''\
#!{python}
"""Speaks the discovery_fuzz_runner protocol; what a source says decides what
happens to it."""
import os
import sys
import time

for name in open(sys.argv[1]).read().split("\\n"):
    if not name:
        continue
    text = open(name).read()
    sys.stderr.write("fuzz-begin " + name + "\\n")
    sys.stderr.flush()
    if "OLD-CRASH" in text:
        sys.stderr.write("stack overflow in the old parser\\n")
        sys.stderr.flush()
        os._exit(139)
    if "OLD-HANG" in text:
        time.sleep(60)
    if "SLOW" in text:
        time.sleep(0.6)
    sys.stderr.write("fuzz-old " + name + " | accepted\\n")
    sys.stderr.flush()
    if "TREE-CRASH" in text:
        os._exit(134)
    if "TREE-HANG" in text:
        time.sleep(60)
    label = "wrong-accept" if "WRONG" in text else "agree"
    sys.stderr.write("fuzz-result " + name + " | " + label + " | \\n")
    sys.stderr.flush()
'''


class FakeRunnerCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binary = self.root / "runner"
        self.binary.write_text(FAKE_RUNNER.format(python=sys.executable), encoding="utf-8")
        self.binary.chmod(self.binary.stat().st_mode | stat.S_IXUSR)
        self.work = self.root / "work"
        self.work.mkdir()


class BatchRunnerTest(FakeRunnerCase):
    def classify(self, texts: list[str], timeout: float = 1.5):
        runner = fuzz.BatchRunner(self.binary, self.work, timeout)
        sources = [(f"s{index}.brp", text) for index, text in enumerate(texts)]
        outcomes = runner.classify(sources)
        return [outcomes[name].verdict for name, _ in sources], runner

    def test_each_source_gets_the_verdict_the_runner_printed(self) -> None:
        verdicts, runner = self.classify(["fine", "WRONG", "fine"])
        self.assertEqual(
            verdicts, [fuzz.Verdict.AGREE, fuzz.Verdict.WRONG_ACCEPT, fuzz.Verdict.AGREE]
        )
        self.assertEqual(runner.stats.processes_started, 1)

    def test_a_crash_before_the_old_parser_finished_blames_the_old_parser(self) -> None:
        verdicts, _ = self.classify(["OLD-CRASH"])
        self.assertEqual(verdicts, [fuzz.Verdict.OLD_CRASH])

    def test_a_crash_after_the_old_parser_finished_blames_the_tree_path(self) -> None:
        verdicts, _ = self.classify(["TREE-CRASH"])
        self.assertEqual(verdicts, [fuzz.Verdict.TREE_CRASH])

    def test_a_crash_records_what_the_process_said(self) -> None:
        runner = fuzz.BatchRunner(self.binary, self.work, 1.5)
        outcome = runner.classify([("s0.brp", "OLD-CRASH")])["s0.brp"]
        self.assertIn("stack overflow", outcome.detail)

    def test_a_hang_is_killed_and_blamed_on_the_parser_that_was_running(self) -> None:
        verdicts, _ = self.classify(["OLD-HANG", "TREE-HANG"], timeout=0.3)
        self.assertEqual(verdicts, [fuzz.Verdict.OLD_HANG, fuzz.Verdict.TREE_HANG])

    def test_a_source_that_is_only_slow_is_not_called_hung(self) -> None:
        verdicts, runner = self.classify(["fine", "SLOW", "fine"], timeout=0.3)
        self.assertEqual(verdicts, [fuzz.Verdict.AGREE] * 3)
        self.assertEqual((runner.stats.rechecked, runner.stats.cleared), (1, 1))

    def test_a_real_hang_stays_a_hang_after_the_longer_second_look(self) -> None:
        _, runner = self.classify(["OLD-HANG"], timeout=0.3)
        self.assertEqual((runner.stats.rechecked, runner.stats.cleared), (1, 0))
        self.assertGreater(runner.stats.hang_seconds, 0.3)

    def test_a_crash_is_run_again_before_it_is_believed(self) -> None:
        _, runner = self.classify(["TREE-CRASH"])
        self.assertEqual((runner.stats.rechecked, runner.stats.cleared), (1, 0))

    def test_the_sources_after_a_crash_or_hang_are_still_classified(self) -> None:
        verdicts, runner = self.classify(["fine", "OLD-CRASH", "WRONG", "TREE-HANG", "fine"], timeout=0.3)
        self.assertEqual(
            verdicts,
            [
                fuzz.Verdict.AGREE,
                fuzz.Verdict.OLD_CRASH,
                fuzz.Verdict.WRONG_ACCEPT,
                fuzz.Verdict.TREE_HANG,
                fuzz.Verdict.AGREE,
            ],
        )
        self.assertGreaterEqual(runner.stats.processes_started, 3)

    def test_a_runner_that_dies_before_starting_a_source_is_an_error(self) -> None:
        self.binary.write_text("#!/bin/sh\nexit 3\n", encoding="utf-8")
        runner = fuzz.BatchRunner(self.binary, self.work, 1.5)
        with self.assertRaises(fuzz.RunnerProtocolError):
            runner.classify([("s0.brp", "fine")])

    def test_a_batch_leaves_no_source_files_behind(self) -> None:
        self.classify(["fine", "OLD-CRASH"], timeout=0.3)
        self.assertEqual(sorted(path.name for path in self.work.glob("s*.brp")), [])


class ShrinkTest(unittest.TestCase):
    @staticmethod
    def needing(*required: str):
        return lambda texts: [all(word in text for word in required) for text in texts]

    def test_shrink_keeps_only_what_the_verdict_needs(self) -> None:
        items = list("abcdefghij")
        self.assertEqual("".join(fuzz.shrink(items, self.needing("c", "h"))), "ch")

    def test_shrink_handles_an_empty_input_and_one_that_needs_everything(self) -> None:
        self.assertEqual(fuzz.shrink([], self.needing("a")), [])
        self.assertEqual(fuzz.shrink(list("abc"), self.needing("a", "b", "c")), list("abc"))

    def test_minimise_reduces_lines_then_tokens(self) -> None:
        text = "import:\n\ta: B, C D\n\nfunc f() -> Int:\n\t1\n"
        smallest = fuzz.minimise(text, self.needing("C D"))
        self.assertEqual(smallest, "C D")

    def test_minimise_removes_indentation_one_character_at_a_time(self) -> None:
        keeps = lambda texts: [text.startswith("\t") and "x" in text for text in texts]
        self.assertEqual(fuzz.minimise("\t\t\t  x\n", keeps), "\tx")

    def test_minimise_never_returns_a_text_the_verdict_rejected(self) -> None:
        text = "a(b)\nc(d)\n"
        keeps = lambda texts: [text.count("(") == text.count(")") and "b" in text for text in texts]
        smallest = fuzz.minimise(text, keeps)
        self.assertTrue(keeps([smallest])[0])
        self.assertLessEqual(len(smallest), len(text))


class MinimiserTest(FakeRunnerCase):
    def test_a_failing_source_shrinks_to_what_still_fails(self) -> None:
        runner = fuzz.BatchRunner(self.binary, self.work, 1.5)
        minimiser = fuzz.Minimiser(runner, fuzz.Verdict.WRONG_ACCEPT)
        text = "alpha\nbeta WRONG gamma\ndelta\n"
        smallest, outcome = minimiser.minimise(text)
        self.assertEqual(smallest, "WRONG")
        self.assertEqual(outcome.verdict, fuzz.Verdict.WRONG_ACCEPT)

    def test_a_failure_that_does_not_reproduce_is_reported_not_shrunk(self) -> None:
        runner = fuzz.BatchRunner(self.binary, self.work, 1.5)
        minimiser = fuzz.Minimiser(runner, fuzz.Verdict.WRONG_ACCEPT)
        result = minimiser.minimise("fine")
        self.assertIsInstance(result, fuzz.Outcome)
        self.assertEqual(result.verdict, fuzz.Verdict.AGREE)

    def test_a_text_is_classified_once_however_often_the_search_asks(self) -> None:
        runner = fuzz.BatchRunner(self.binary, self.work, 1.5)
        minimiser = fuzz.Minimiser(runner, fuzz.Verdict.WRONG_ACCEPT)
        minimiser.keeps_verdict(["WRONG a", "b"])
        started = runner.stats.processes_started
        minimiser.keeps_verdict(["WRONG a", "b"])
        self.assertEqual(runner.stats.processes_started, started)


class RunTest(FakeRunnerCase):
    """The driver end to end over a fake runner and a real corpus file."""

    def run_driver(self, *arguments: str) -> tuple[int, str]:
        out = self.root / "failures"
        options = fuzz.parse_arguments(
            [
                "--files", "standard_library/src/list.brp",
                "--count", "30",
                "--binary", str(self.binary),
                "--out", str(out),
                *arguments,
            ]
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = fuzz.run(options)
        return status, output.getvalue()

    def test_a_run_with_only_agreement_exits_zero_and_writes_no_failures(self) -> None:
        status, output = self.run_driver()
        self.assertEqual(status, 0)
        self.assertIn("mutants=30", output)
        self.assertEqual(list((self.root / "failures").iterdir()), [])

    def test_a_wrong_accept_exits_nonzero_and_is_written_out(self) -> None:
        # Every mutant of `list.brp` that keeps a `->` contains the marker.
        marked = self.root / "marked_runner"
        marked.write_text(
            FAKE_RUNNER.format(python=sys.executable).replace('"WRONG" in text', '"->" in text'),
            encoding="utf-8",
        )
        marked.chmod(marked.stat().st_mode | stat.S_IXUSR)
        status, output = self.run_driver("--binary", str(marked), "--minimise")
        self.assertEqual(status, 1)
        self.assertIn("WRONG ACCEPT", output)
        failure = next((self.root / "failures").iterdir())
        self.assertTrue(failure.name.startswith("wrong-accept-"))
        self.assertEqual(
            sorted(path.name for path in failure.iterdir()),
            ["minimised.brp", "mutant.brp", "original.brp", "verdict.txt"],
        )
        self.assertEqual((failure / "minimised.brp").read_text(encoding="utf-8"), "->")
        self.assertIn("verdict: wrong-accept", (failure / "verdict.txt").read_text(encoding="utf-8"))

    def test_an_old_parser_crash_alone_does_not_fail_the_run(self) -> None:
        crashing = self.root / "crashing_runner"
        crashing.write_text(
            FAKE_RUNNER.format(python=sys.executable).replace('"OLD-CRASH" in text', '"func" in text'),
            encoding="utf-8",
        )
        crashing.chmod(crashing.stat().st_mode | stat.S_IXUSR)
        status, output = self.run_driver("--binary", str(crashing))
        self.assertEqual(status, 0)
        self.assertIn("old parser crashed", output)

    def test_the_gate_fixes_its_seed_count_and_selection(self) -> None:
        for argument in (["--seed", "2"], ["--count", "5"], ["--files", "a.brp"], ["--whole-file"]):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                fuzz.parse_arguments(["--gate", *argument])
        options = fuzz.parse_arguments(["--gate"])
        self.assertEqual((options.seed, options.count), (fuzz.GATE_SEED, fuzz.GATE_COUNT))

    def test_an_output_directory_that_has_files_is_refused(self) -> None:
        (self.root / "failures").mkdir()
        (self.root / "failures" / "old").write_text("", encoding="utf-8")
        with self.assertRaises(SystemExit):
            self.run_driver()


class FailureReportTest(unittest.TestCase):
    def test_a_failure_directory_holds_the_original_the_mutant_and_the_verdict(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            mutant = fuzz.Mutant(
                12, fuzz.Unit("a.brp", 2, 4), "delete-token", "f(a, b)\n", "f(a b)\n"
            )
            failure = fuzz.Failure(mutant, fuzz.Outcome(fuzz.Verdict.WRONG_ACCEPT, "detail text"))
            target = fuzz.write_failure(Path(name), 5, failure)
            self.assertEqual(target.name, "wrong-accept-000012")
            self.assertEqual((target / "original.brp").read_text(encoding="utf-8"), "f(a, b)\n")
            self.assertEqual((target / "mutant.brp").read_text(encoding="utf-8"), "f(a b)\n")
            report = (target / "verdict.txt").read_text(encoding="utf-8")
            for expected in ("seed: 5", "mutant: 12", "operator: delete-token", "a.brp lines 3-4"):
                self.assertIn(expected, report)
            self.assertIn("-f(a, b)", report)
            self.assertIn("+f(a b)", report)
            self.assertFalse((target / "minimised.brp").exists())


if __name__ == "__main__":
    unittest.main()
