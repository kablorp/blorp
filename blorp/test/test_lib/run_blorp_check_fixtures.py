#!/usr/bin/env python3
"""Run production compiler fixtures marked for direct Blorp checking."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from pathlib import Path
import re
import sys

from process_supervisor import CAPTURE_LIMIT_EXIT, PROCESS_TIMEOUT_EXIT, run_command


MARKER = "-- RUN-BLORP-CHECK"

# The compiler's fixtures and the discovery stage's fixtures. Every should_fail
# fixture marked `RUN-BLORP-CHECK` runs through `bin/blorp check`, so the stage
# must reject it with the text and position it pins.
DEFAULT_ROOTS = (Path("blorp/test/test_compiler"), Path("blorp/test/test_compiler_new"))


@dataclass
class Expectations:
    exact: list[str] = field(default_factory=list)
    contains: list[str] = field(default_factory=list)
    not_contains: list[str] = field(default_factory=list)
    # A fixture whose own pins cannot be used (see `stage_expectations`) fails
    # with these rather than silently losing a check.
    pin_errors: list[str] = field(default_factory=list)
    # Whether the checks are the stage's own pins rather than the fixture's
    # `EXPECT`/`EXPECT-BLORP` lines.
    stage_pinned: bool = False

    def has_checks(self) -> bool:
        return bool(self.exact or self.contains or self.not_contains)


DISCOVERY_POSITION = re.compile(r"\s(\d+):(\d+)\s*$")


def stage_expectations(source: str, fallback: Expectations) -> Expectations:
    """Expectations for a fixture checked against the discovery stage.

    A should_fail fixture pins the stage's own rendered diagnostic in
    `-- EXPECT-DISCOVERY-TEXT:` lines and its position in the `line:column` that
    ends `-- EXPECT-DISCOVERY:`; the `compiler-new` gates already hold those
    true. They replace the fixture's `EXPECT-BLORP` wording and position. The
    `NOT-CONTAINS` checks are about what must not appear and stay as they are.
    A fixture with no `EXPECT-DISCOVERY-TEXT` has nothing stage-specific to say
    and FALLS BACK to its `EXPECT`/`EXPECT-BLORP` checks: those fixtures do not
    pin the stage's text (`main` reports how many there are). A fixture that has the text
    pins but no `line:column` on its `EXPECT-DISCOVERY` line is a malformed
    fixture and fails, instead of silently losing its position check.
    """
    texts: list[str] = []
    positions: list[str] = []
    for line in source.splitlines():
        if line.startswith("-- EXPECT-DISCOVERY-TEXT:"):
            texts.append(line[len("-- EXPECT-DISCOVERY-TEXT:") :].strip())
        elif line.startswith("-- EXPECT-DISCOVERY:"):
            match = DISCOVERY_POSITION.search(line)
            if match:
                positions.append(f":{match.group(1)}:{match.group(2)}: error:")
    if not texts:
        return fallback
    pin_errors = (
        []
        if positions
        else [
            "has EXPECT-DISCOVERY-TEXT but no `line:column` on its "
            "EXPECT-DISCOVERY line, so the stage's position cannot be checked"
        ]
    )
    return Expectations(
        exact=texts,
        contains=positions,
        not_contains=fallback.not_contains,
        pin_errors=pin_errors,
        stage_pinned=True,
    )


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
    return stage_expectations(source, blorp if blorp.has_checks() else generic)


SEVERITY_MARKERS = ((": error: ", "error: "), (": warning: ", "warning: "))


def normalized_diagnostics(output: str) -> list[str]:
    diagnostics: list[str] = []
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith(("error: ", "warning: ")):
            diagnostics.append(stripped)
            continue
        for marker, prefix in SEVERITY_MARKERS:
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
    failures = list(expectations.pin_errors)
    failures += [
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


def print_stage_coverage(fixtures: list[Path]) -> None:
    """Say how many should_fail fixtures check the stage's own pins.

    The rest fall back to their `EXPECT`/`EXPECT-BLORP` lines, so they do not
    pin the stage's own text.
    """
    failing = [path for path in fixtures if "should_fail" in path.parts]
    pinned = sum(
        1
        for path in failing
        if parse_expectations(path.read_text(encoding="utf-8")).stage_pinned
    )
    print(
        f"discovery stage: {pinned} of {len(failing)} should_fail fixtures check the "
        f"stage's pinned text and position; {len(failing) - pinned} fall back to their "
        "EXPECT/EXPECT-BLORP checks"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--blorp-bin", default="bin/blorp")
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
    roots = [Path(root) for root in args.root] or list(DEFAULT_ROOTS)
    fixtures = discover_fixtures(roots)
    # scripts/test owns the expected production count and passes it explicitly;
    # a standalone run checks only that some fixture was found.
    expected_count = args.expected_count
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

    print_stage_coverage(fixtures)
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
