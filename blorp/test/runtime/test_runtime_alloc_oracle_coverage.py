#!/usr/bin/env python3
"""Coverage gate for the runtime allocation oracle (allocation-contract
roadmap milestone 6).

A newly introduced raw allocation call in runtime.c must either be routed
through one of the oracle's counted wrappers (BLORP_ORACLE_MALLOC/CALLOC/
REALLOC, blorp_malloc_checked/blorp_realloc_checked/blorp_calloc_checked,
blorp_pool_refill, blorp_simd_alloc, or the blorp_alloc/mmap call sites the
oracle counts directly) or be given an explicit "Not an allocation the
oracle observes, because ..." comment immediately above it. This test greps
every malloc/calloc/realloc/posix_memalign/aligned_alloc/mmap call site and
fails if a site is neither counted nor allowlisted, so a new raw allocation
site cannot land silently uncovered.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNTIME_C = ROOT / "blorp" / "src" / "lib" / "runtime" / "native" / "runtime.c"

# Calls that are themselves the counted wrapper/macro (their bodies contain
# the raw libc call the macro or wrapper exists to count).
COUNTING_SITE_MARKERS = (
    "BLORP_ORACLE_MALLOC(",
    "BLORP_ORACLE_CALLOC(",
    "BLORP_ORACLE_REALLOC(",
)

# Function-call prefixes that are themselves already-instrumented
# allocation entry points; a raw libc call is expected inside their own
# definitions further down this file (found via COUNTING_SITE_MARKERS or a
# direct __blorp_oracle_count call immediately above), so a *use* of one of
# these does not need its own allowlist entry.
ALREADY_COUNTED_CALL_PREFIXES = (
    "blorp_alloc(",
    "blorp_malloc_checked(",
    "blorp_realloc_checked(",
    "blorp_calloc_checked(",
    "blorp_union_destroy_stack_grow(",
)

RAW_CALL_PATTERN = re.compile(
    r"\b(malloc|calloc|realloc|posix_memalign|aligned_alloc|mmap)\s*\("
)

ALLOWLIST_MARKER = "Not an allocation the oracle observes"
ORACLE_COUNT_MARKER = "__blorp_oracle_count("


def _is_already_counted_use(line: str) -> bool:
    return any(prefix in line for prefix in ALREADY_COUNTED_CALL_PREFIXES)


def _is_counting_definition_site(line: str) -> bool:
    return any(marker in line for marker in COUNTING_SITE_MARKERS)


class RuntimeAllocOracleCoverageTests(unittest.TestCase):
    def test_every_raw_allocation_call_is_counted_or_allowlisted(self) -> None:
        lines = RUNTIME_C.read_text().splitlines()
        uncovered = []

        def is_noise(text: str) -> bool:
            stripped = text.strip()
            return (
                stripped == ""
                or stripped.startswith("//")
                or stripped.startswith("#")
                or stripped.startswith("*")
                or stripped.startswith("/*")
            )

        def code_part(text: str) -> str:
            # Drop a trailing `// ...` line comment so a raw-call keyword
            # mentioned only in prose does not look like a real call.
            idx = text.find("//")
            return text if idx == -1 else text[:idx]

        for lineno, line in enumerate(lines, start=1):
            if is_noise(line):
                continue
            code = code_part(line)
            if not RAW_CALL_PATTERN.search(code):
                continue
            # Skip the macro/comment definitions themselves and any use of
            # an already-instrumented wrapper/entry point.
            if _is_counting_definition_site(code):
                continue
            if _is_already_counted_use(code):
                continue
            if "#define BLORP_ORACLE_" in line or "BLORP_ORACLE_" in line:
                continue

            # Search a generous backward window of physical lines (plus the
            # call's own line, for a macro body like BLORP_ORACLE_MALLOC's
            # definition where the count call and the libc call are on the
            # same statement) for either marker. The window only needs to
            # bridge ordinary local context — a short run of comments, one
            # function signature, a couple of statements, or a few
            # preprocessor branches — not cross into an unrelated function.
            window_start = max(0, lineno - 13)
            window = lines[window_start:lineno]

            if any(ORACLE_COUNT_MARKER in text for text in window):
                continue
            if any(ALLOWLIST_MARKER in text for text in window):
                continue

            uncovered.append((lineno, line.strip()))

        if uncovered:
            details = "\n".join(f"  runtime.c:{n}: {text}" for n, text in uncovered)
            self.fail(
                "Found raw allocation call(s) neither routed through a "
                "counted oracle wrapper nor explicitly allowlisted with a "
                "'Not an allocation the oracle observes, because ...' "
                "comment. Assign each an owner:\n" + details
            )


if __name__ == "__main__":
    unittest.main()
