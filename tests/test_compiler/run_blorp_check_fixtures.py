#!/usr/bin/env python3
"""Run production compiler fixtures marked for direct Blorp checking."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from pathlib import Path
import sys

from process_supervisor import CAPTURE_LIMIT_EXIT, PROCESS_TIMEOUT_EXIT, run_command


MARKER = "-- RUN-BLORP-CHECK"
PRODUCTION_FIXTURE_COUNT = 36


@dataclass
class Expectations:
    exact: list[str] = field(default_factory=list)
    contains: list[str] = field(default_factory=list)
    not_contains: list[str] = field(default_factory=list)

    def has_checks(self) -> bool:
        return bool(self.exact or self.contains or self.not_contains)


def parse_expectations(source: str) -> Expectations:
    generic = Expectations()
    blorp = Expectations()
    prefixes = (
        ("-- EXPECT: ", generic.exact, False),
        ("-- EXPECT-CONTAINS:", generic.contains, True),
        ("-- EXPECT-NOT-CONTAINS:", generic.not_contains, True),
        ("-- EXPECT-BLORP: ", blorp.exact, False),
        ("-- EXPECT-BLORP-CONTAINS:", blorp.contains, True),
        ("-- EXPECT-BLORP-NOT-CONTAINS:", blorp.not_contains, True),
    )
    for line in source.splitlines():
        for prefix, destination, trim in prefixes:
            if line.startswith(prefix):
                expected = line[len(prefix) :]
                destination.append(expected.strip() if trim else expected)
                break
    return blorp if blorp.has_checks() else generic


def normalized_diagnostics(output: str) -> list[str]:
    diagnostics: list[str] = []
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith(("error: ", "warning: ")):
            diagnostics.append(stripped)
            continue
        for marker, prefix in ((": error: ", "error: "), (": warning: ", "warning: ")):
            if marker in stripped:
                diagnostics.append(prefix + stripped.split(marker, 1)[1])
                break
        else:
            if stripped.startswith(("expected: ", "found: ", "help: ", "note: ")):
                diagnostics.append(stripped)
            elif stripped.startswith("= help: "):
                diagnostics.append("help: " + stripped[len("= help: ") :])
            elif stripped.startswith("= note: "):
                diagnostics.append("note: " + stripped[len("= note: ") :])
    return diagnostics


def expectation_failures(expectations: Expectations, output: str) -> list[str]:
    diagnostics = normalized_diagnostics(output)
    failures = [
        f"missing exact diagnostic: {expected}"
        for expected in expectations.exact
        if expected and expected not in diagnostics
    ]
    failures.extend(
        f"missing output substring: {expected}"
        for expected in expectations.contains
        if expected and expected not in output
    )
    failures.extend(
        f"unexpected output substring: {expected}"
        for expected in expectations.not_contains
        if expected and expected in output
    )
    return failures


def discover_fixtures(roots: list[Path]) -> list[Path]:
    fixtures: list[Path] = []
    for root in roots:
        for path in root.rglob("*.brp"):
            source = path.read_text(encoding="utf-8")
            if any(line.strip() == MARKER for line in source.splitlines()):
                fixtures.append(path)
    return sorted(set(fixtures))


def run_fixture(compiler: Path, fixture: Path, timeout: int) -> tuple[bool, list[str]]:
    result = run_command(
        [str(compiler), "check", "--no-format", str(fixture)], timeout
    )
    output = result.output
    if result.returncode == PROCESS_TIMEOUT_EXIT:
        return False, [f"timed out after {timeout}s"]
    if result.returncode == CAPTURE_LIMIT_EXIT:
        return False, ["compiler exceeded the capture limit"]

    if "should_pass" in fixture.parts:
        if result.returncode == 0:
            return True, []
        return False, [f"expected success, got exit {result.returncode}", output.strip()]
    if "should_fail" not in fixture.parts:
        return False, ["fixture must be under should_pass or should_fail"]
    if result.returncode == 0:
        return False, ["expected failure, but check succeeded"]
    if result.returncode != 1:
        return False, [f"compiler infrastructure exit {result.returncode}", output.strip()]

    failures = expectation_failures(
        parse_expectations(fixture.read_text(encoding="utf-8")), output
    )
    if failures:
        failures.append("actual output: " + (output.strip() or "(empty)"))
    return not failures, failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--blorp-bin", default="./blorp")
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--expected-count", type=int)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--gate-name", default="compiler_blorp_fixtures")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.timeout < 0 or (args.expected_count is not None and args.expected_count < 1):
        parser.error("timeouts must be non-negative and expected counts must be positive")
    return args


def main() -> int:
    args = parse_args()
    compiler = Path(args.blorp_bin).resolve()
    roots = [Path(root) for root in args.root] or [Path("tests/test_compiler")]
    fixtures = discover_fixtures(roots)
    expected_count = args.expected_count
    if expected_count is None and not args.root:
        expected_count = PRODUCTION_FIXTURE_COUNT
    if not fixtures:
        print("FAIL: no RUN-BLORP-CHECK fixtures found")
        print(
            f"BLORP_GATE_RESULT gate={args.gate_name} status=FAIL "
            "passed=0 failed=1 tests=1"
        )
        return 1
    if expected_count is not None and len(fixtures) != expected_count:
        print(
            f"FAIL: expected {expected_count} RUN-BLORP-CHECK fixtures, "
            f"found {len(fixtures)}"
        )
        print(
            f"BLORP_GATE_RESULT gate={args.gate_name} status=FAIL "
            "passed=0 failed=1 tests=1"
        )
        return 1

    passed = 0
    failed = 0
    for fixture in fixtures:
        succeeded, details = run_fixture(compiler, fixture, args.timeout)
        if succeeded:
            passed += 1
            if args.verbose:
                print(f"PASS: {fixture}")
            continue
        failed += 1
        print(f"FAIL: {fixture}")
        for detail in details:
            if detail:
                print(f"  {detail}")

    status = "PASS" if failed == 0 else "FAIL"
    print(
        f"BLORP_GATE_RESULT gate={args.gate_name} status={status} "
        f"passed={passed} failed={failed} tests={passed + failed}"
    )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
