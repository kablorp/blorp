#!/usr/bin/env python3
"""Run formatter and purify fixtures through the production Blorp CLI."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
import shutil
import sys
import tempfile

from process_supervisor import (
    CAPTURE_LIMIT_EXIT,
    PROCESS_TIMEOUT_EXIT,
    CommandResult,
    run_command,
)
from run_blorp_check_fixtures import expectation_failures, parse_expectations


DEFAULT_FIXTURE_ROOT = Path("tests/test_compiler")
DEFAULT_STDLIB_CASE = Path("std/crypto_random.brp")
EXPECTED_TOOL_FIXTURE_COUNT = 106


class FixtureKind(Enum):
    FORMAT_PASS = "format/should_pass"
    FORMAT_FAIL = "format/should_fail"
    FORMAT_ERROR = "format/should_error"
    PURIFY_CHANGE = "purify/should_purify"
    PURIFY_NO_CHANGE = "purify/should_not_purify"
    PURIFY_REWRITE = "purify/should_rewrite"


@dataclass(frozen=True)
class Fixture:
    kind: FixtureKind
    path: Path


def discover_fixtures(fixture_root: Path) -> list[Fixture]:
    locations = (
        (FixtureKind.FORMAT_PASS, fixture_root / "format/should_pass"),
        (FixtureKind.FORMAT_FAIL, fixture_root / "format/should_fail"),
        (FixtureKind.FORMAT_ERROR, fixture_root / "format/should_error"),
        (FixtureKind.PURIFY_CHANGE, fixture_root / "purify/should_purify"),
        (FixtureKind.PURIFY_NO_CHANGE, fixture_root / "purify/should_not_purify"),
        (FixtureKind.PURIFY_REWRITE, fixture_root / "purify/should_rewrite"),
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
            return []
        failures = expectation_failures(
            parse_expectations(fixture.path.read_text(encoding="utf-8")),
            result.output,
        )
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
        if fixture.kind is FixtureKind.PURIFY_CHANGE and not changed:
            return ["expected purify to report functions to change"]
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
    parser.add_argument("--blorp-bin", default="./blorp")
    parser.add_argument("--fixture-root")
    parser.add_argument("--no-stdlib-case", action="store_true")
    parser.add_argument("--expected-count", type=int)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--gate-name", default="compiler_tools")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.timeout < 0 or (args.expected_count is not None and args.expected_count < 1):
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
    if expected_count is None and args.fixture_root is None and not args.no_stdlib_case:
        expected_count = EXPECTED_TOOL_FIXTURE_COUNT

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

    warmup_failures = warm_formatter(compiler, args.timeout)
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
