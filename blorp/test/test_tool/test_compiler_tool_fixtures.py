#!/usr/bin/env python3
"""Run formatter, purify, and lint fixtures through the production Blorp CLI."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import difflib
from enum import Enum
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "blorp/test/test_lib"))

from process_supervisor import (
    CAPTURE_LIMIT_EXIT,
    PROCESS_TIMEOUT_EXIT,
    CommandResult,
    run_command,
)
from run_blorp_check_fixtures import expectation_failures, parse_expectations


DEFAULT_FIXTURE_ROOT = Path("blorp/test")
DEFAULT_STDLIB_CASE = Path("standard_library/src/crypto_random.brp")
PURIFY_EXPECTATION_PREFIX = "-- EXPECT-PURIFY: "
FORMAT_PASS_GOLDENS = frozenset(
    {
        "block_header_expression_multiline.brp",
        "collection_call_arg_indentation.brp",
        "comment_declaration_lines.brp",
        "control_flow_block_spacing.brp",
        "if_condition_chain_multiline.brp",
        "list_record_literal.brp",
        "logical_condition_multiline.brp",
        "logical_value_multiline.brp",
        "nested_collection_tuple_indentation.brp",
        "nested_inline_lambda_call_argument.brp",
        "record_multiline_layout.brp",
    }
)
PURIFY_DRY_RUN_LINE = re.compile(
    r"\[DRY-RUN\] Functions that could be purified in (.+): "
    r"([A-Za-z_][A-Za-z_0-9]*(?:, [A-Za-z_][A-Za-z_0-9]*)*)"
)


class FixtureKind(Enum):
    FORMAT_PASS = "format/should_pass"
    FORMAT_FAIL = "format/should_fail"
    FORMAT_ERROR = "format/should_error"
    PURIFY_CHANGE = "purify/should_purify"
    PURIFY_NO_CHANGE = "purify/should_not_purify"
    PURIFY_REWRITE = "purify/should_rewrite"
    LINT_FINDING = "lint/should_find"
    LINT_CLEAN = "lint/should_be_clean"


@dataclass(frozen=True)
class Fixture:
    kind: FixtureKind
    path: Path


def discover_fixtures(fixture_root: Path) -> list[Fixture]:
    locations = (
        (FixtureKind.FORMAT_PASS, fixture_root / "test_format/should_pass"),
        (FixtureKind.FORMAT_FAIL, fixture_root / "test_format/should_fail"),
        (FixtureKind.FORMAT_ERROR, fixture_root / "test_format/should_error"),
        (FixtureKind.PURIFY_CHANGE, fixture_root / "test_purify/should_purify"),
        (FixtureKind.PURIFY_NO_CHANGE, fixture_root / "test_purify/should_not_purify"),
        (FixtureKind.PURIFY_REWRITE, fixture_root / "test_purify/should_rewrite"),
        (FixtureKind.LINT_FINDING, fixture_root / "test_lint/should_find"),
        (FixtureKind.LINT_CLEAN, fixture_root / "test_lint/should_be_clean"),
    )
    return [
        Fixture(kind, path)
        for kind, directory in locations
        if directory.is_dir()
        for path in sorted(directory.glob("*.brp"))
    ]


def output_details(result: CommandResult, action: str) -> list[str]:
    if result.returncode == PROCESS_TIMEOUT_EXIT:
        return [f"{action} timed out"]
    if result.returncode == CAPTURE_LIMIT_EXIT:
        return [f"{action} exceeded the capture limit"]
    details = [f"{action} exited with status {result.returncode}"]
    details.extend(line for line in result.output.splitlines() if line)
    return details


def format_command(compiler: Path, fixture: Path) -> list[str]:
    return [str(compiler), "format", "--check", str(fixture)]


def purify_command(compiler: Path, fixture: Path, dry_run: bool) -> list[str]:
    command = [str(compiler), "purify"]
    if dry_run:
        command.append("--dry-run")
    command.append(str(fixture))
    return command


def lint_command(compiler: Path, fixture: Path) -> list[str]:
    return [str(compiler), "lint", "--format", "json", str(fixture)]


def rewrite_expectation_failures(original: Path, rewritten: str) -> list[str]:
    expectations = parse_expectations(original.read_text(encoding="utf-8"))
    body = "\n".join(
        line for line in rewritten.splitlines() if not line.startswith("-- EXPECT-")
    )
    failures = [
        f"missing rewritten text: {expected}"
        for expected in expectations.contains
        if expected and expected not in body
    ]
    failures.extend(
        f"forbidden rewritten text present: {forbidden}"
        for forbidden in expectations.not_contains
        if forbidden and forbidden in body
    )
    return failures


def purify_change_failures(fixture: Path, output: str) -> list[str]:
    expectations = [
        line.removeprefix(PURIFY_EXPECTATION_PREFIX)
        for line in fixture.read_text(encoding="utf-8").splitlines()
        if line.startswith(PURIFY_EXPECTATION_PREFIX)
    ]
    if len(expectations) != 1:
        return ["expected exactly one -- EXPECT-PURIFY: function list"]
    expected_names = expectations[0].split(", ")
    if not all(re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", name) for name in expected_names):
        return ["invalid -- EXPECT-PURIFY: function list"]

    lines = output.splitlines()
    if len(lines) != 1:
        return [
            "expected exactly one purify dry-run line",
            "actual output: " + (output.strip() or "(empty)"),
        ]
    match = PURIFY_DRY_RUN_LINE.fullmatch(lines[0])
    if match is None:
        return ["malformed purify dry-run line", "actual output: " + lines[0]]
    reported_path, names = match.groups()
    if Path(reported_path).resolve() != fixture.resolve():
        return [f"purify reported a different file: {reported_path}"]
    actual_names = names.split(", ")
    if sorted(actual_names) != sorted(expected_names):
        return [
            "expected purify functions: " + ", ".join(expected_names),
            "actual purify functions: " + ", ".join(actual_names),
        ]
    return []


def line_comment_text(line: str) -> str | None:
    """Return the `--` comment ending a source line, or None.

    Skips `--` inside double-quoted and character literals on the same line.
    Fixture comments are simple enough for this scan; it is not a lexer, so
    fixtures must not put `--` inside multiline pipe strings.
    """
    quote: str | None = None
    index = 0
    while index < len(line):
        char = line[index]
        if quote is not None:
            if char == "\\":
                index += 1
            elif char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif line.startswith("--", index):
            return line[index:].rstrip()
        index += 1
    return None


def source_comment_texts(source: str) -> Counter[str]:
    comments = (line_comment_text(line) for line in source.splitlines())
    return Counter(comment for comment in comments if comment is not None)


def comment_preservation_failures(original: str, formatted: str) -> list[str]:
    """Require formatting to keep every comment exactly once."""
    before = source_comment_texts(original)
    after = source_comment_texts(formatted)
    failures = [
        f"formatter dropped comment: {comment}"
        for comment in sorted((before - after).elements())
    ]
    failures.extend(
        f"formatter duplicated or invented comment: {comment}"
        for comment in sorted((after - before).elements())
    )
    return failures


def expected_formatted_path(fixture: Path) -> Path | None:
    """Find the exact golden for a formatter should_fail fixture."""
    format_root = fixture.parent.parent
    if fixture.name in FORMAT_PASS_GOLDENS:
        expected = format_root / "should_pass" / fixture.name
    else:
        expected = format_root / "expected_output" / fixture.name
    return expected if expected.is_file() else None


def formatted_fixpoint_failures(compiler: Path, fixture: Path, timeout: int) -> list[str]:
    """Require exact canonical output, a fixpoint, and preserved comments.

    The formatter must accept its own output unchanged; otherwise `format --check`
    cannot serve as a gate over freshly formatted trees.
    """
    expected_path = expected_formatted_path(fixture)
    if expected_path is None:
        return [f"missing expected formatted output for {fixture.name}"]
    with tempfile.TemporaryDirectory(prefix="blorp-format-fixpoint-") as temp_dir:
        formatted_path = Path(temp_dir) / fixture.name
        shutil.copyfile(fixture, formatted_path)
        write = run_command([str(compiler), "format", str(formatted_path)], timeout)
        if write.returncode != 0:
            return ["formatter failed to rewrite the source"] + output_details(
                write, "formatter"
            )
        formatted_bytes = formatted_path.read_bytes()
        expected_bytes = expected_path.read_bytes()
        failures = comment_preservation_failures(
            fixture.read_text(encoding="utf-8"), formatted_bytes.decode("utf-8")
        )
        if formatted_bytes != expected_bytes:
            failures.append("formatted output differs from expected output")
            failures.extend(
                difflib.unified_diff(
                    expected_bytes.decode("utf-8").splitlines(),
                    formatted_bytes.decode("utf-8").splitlines(),
                    fromfile=str(expected_path),
                    tofile="actual formatted output",
                    lineterm="",
                )
            )
        recheck = run_command(
            [str(compiler), "format", "--diff", str(formatted_path)], timeout
        )
    if recheck.returncode != 0:
        failures.append("formatted output is not a fixpoint")
        failures.extend(output_details(recheck, "formatter recheck"))
    return failures


def run_fixture(compiler: Path, fixture: Fixture, timeout: int) -> list[str]:
    if fixture.kind in {
        FixtureKind.FORMAT_PASS,
        FixtureKind.FORMAT_FAIL,
        FixtureKind.FORMAT_ERROR,
    }:
        result = run_command(format_command(compiler, fixture.path), timeout)
        if fixture.kind is FixtureKind.FORMAT_PASS:
            if result.returncode == 0:
                return []
            return ["expected an already formatted source"] + output_details(
                result, "formatter"
            )
        if result.returncode == 0:
            return ["expected the formatter to reject the source"]
        if result.returncode != 1:
            return output_details(result, "formatter")
        if fixture.kind is FixtureKind.FORMAT_FAIL:
            return formatted_fixpoint_failures(compiler, fixture.path, timeout)
        failures = expectation_failures(
            parse_expectations(fixture.path.read_text(encoding="utf-8")),
            result.output,
        )
        if failures:
            failures.append("actual output: " + (result.output.strip() or "(empty)"))
        return failures

    if fixture.kind in {FixtureKind.LINT_FINDING, FixtureKind.LINT_CLEAN}:
        result = run_command(lint_command(compiler, fixture.path), timeout)
        if result.returncode != 0:
            return output_details(result, "lint")
        try:
            payload = json.loads(result.output)
        except json.JSONDecodeError as error:
            return [f"lint returned malformed JSON: {error}", result.output.strip()]
        if payload.get("schema_version") != 1 or not isinstance(payload.get("findings"), list):
            return ["lint returned an unsupported JSON envelope", result.output.strip()]
        failures = expectation_failures(
            parse_expectations(fixture.path.read_text(encoding="utf-8")),
            result.output,
        )
        if fixture.kind is FixtureKind.LINT_FINDING and not payload["findings"]:
            failures.append("expected lint to report at least one finding")
        if fixture.kind is FixtureKind.LINT_CLEAN and payload["findings"]:
            failures.append("expected lint to report no findings")
        if failures:
            failures.append("actual output: " + (result.output.strip() or "(empty)"))
        return failures

    if fixture.kind in {
        FixtureKind.PURIFY_CHANGE,
        FixtureKind.PURIFY_NO_CHANGE,
    }:
        result = run_command(purify_command(compiler, fixture.path, True), timeout)
        if result.returncode != 0:
            return output_details(result, "purify")
        changed = bool(result.output.strip())
        if fixture.kind is FixtureKind.PURIFY_CHANGE:
            return purify_change_failures(fixture.path, result.output)
        if fixture.kind is FixtureKind.PURIFY_NO_CHANGE and changed:
            return ["expected purify to report no changes", result.output.strip()]
        return []

    with tempfile.TemporaryDirectory(prefix="blorp-purify-test-") as temp_dir:
        rewritten_path = Path(temp_dir) / fixture.path.name
        shutil.copyfile(fixture.path, rewritten_path)
        result = run_command(purify_command(compiler, rewritten_path, False), timeout)
        if result.returncode != 0:
            return output_details(result, "purify")
        check = run_command(
            [str(compiler), "check", "--no-format", str(rewritten_path)], timeout
        )
        if check.returncode != 0:
            return ["rewritten source did not typecheck"] + output_details(
                check, "check"
            )
        return rewrite_expectation_failures(
            fixture.path, rewritten_path.read_text(encoding="utf-8")
        )


def warm_formatter(compiler: Path, timeout: int) -> list[str]:
    with tempfile.TemporaryDirectory(prefix="blorp-formatter-warmup-") as temp_dir:
        source = Path(temp_dir) / "warmup.brp"
        source.write_text(
            "func main(args: List[String]) -> Int:\n\t0\n", encoding="utf-8"
        )
        result = run_command(format_command(compiler, source), timeout)
    if result.returncode == 0:
        return []
    return output_details(result, "formatter warmup")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--blorp-bin", default="bin/blorp")
    parser.add_argument("--fixture-root")
    parser.add_argument("--no-stdlib-case", action="store_true")
    parser.add_argument("--expected-count", type=int)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument(
        "--warmup-timeout",
        type=int,
        help="seconds for the formatter warmup run (0 = unbounded; default: --timeout)",
    )
    parser.add_argument("--gate-name", default="compiler_tools")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.warmup_timeout is None:
        args.warmup_timeout = args.timeout
    if (
        args.timeout < 0
        or args.warmup_timeout < 0
        or (args.expected_count is not None and args.expected_count < 1)
    ):
        parser.error("timeouts must be non-negative and expected counts must be positive")
    return args


def emit_failure(suite: str, name: str, details: list[str]) -> None:
    print(f"FAIL: [{suite}] {name}")
    for detail in details:
        if detail:
            print(f"DETAIL {detail}")


def main() -> int:
    args = parse_args()
    compiler = Path(args.blorp_bin).resolve()
    fixture_root = Path(args.fixture_root) if args.fixture_root else DEFAULT_FIXTURE_ROOT
    fixtures = discover_fixtures(fixture_root)
    if not fixtures:
        emit_failure("compiler_tools", "inventory", ["no compiler tool fixtures found"])
        print(
            f"BLORP_GATE_RESULT gate={args.gate_name} status=FAIL "
            "passed=0 failed=1 tests=1"
        )
        return 1
    if not args.no_stdlib_case:
        fixtures.append(Fixture(FixtureKind.PURIFY_NO_CHANGE, DEFAULT_STDLIB_CASE))
    expected_count = args.expected_count
    if expected_count is not None and len(fixtures) != expected_count:
        emit_failure(
            "compiler_tools",
            "inventory",
            [f"expected {expected_count} fixtures, found {len(fixtures)}"],
        )
        print(
            f"BLORP_GATE_RESULT gate={args.gate_name} status=FAIL "
            "passed=0 failed=1 tests=1"
        )
        return 1

    warmup_failures = warm_formatter(compiler, args.warmup_timeout)
    if warmup_failures:
        emit_failure("format/warmup", "renderer", warmup_failures)
        print(
            f"BLORP_GATE_RESULT gate={args.gate_name} status=FAIL "
            "passed=0 failed=1 tests=1"
        )
        return 1

    passed = 0
    failed = 0
    for fixture in fixtures:
        failures = run_fixture(compiler, fixture, args.timeout)
        if failures:
            failed += 1
            emit_failure(fixture.kind.value, fixture.path.name, failures)
        else:
            passed += 1
            if args.verbose:
                print(f"PASS: [{fixture.kind.value}] {fixture.path.name}")

    status = "PASS" if failed == 0 else "FAIL"
    print(
        f"BLORP_GATE_RESULT gate={args.gate_name} status={status} "
        f"passed={passed} failed={failed} tests={passed + failed}"
    )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
