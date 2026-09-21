#!/usr/bin/env python3
"""Guard: the emitter (emit.brp) never spells a raw allocating runtime call.

Half B of the "emitter is a dumb printer" effort: every `blorp_alloc(`,
`blorp_string_create(` and `blorp_list_new(`/`blorp_list_new_inline(` C call
that emit.brp needs must come from a call into one of the five
stage_10_backend renderers (prepared_backend_renderer.brp,
prepared_list_renderer.brp, prepared_tensor_renderer.brp,
prepared_tuple_renderer.brp, intrinsic_renderer.brp), each of which has a
cataloged BackendHelperKind row (backend_helper_catalog.brp) describing its
allocation and ownership behavior. A direct call to one of these three C
function names written as a literal in emit.brp bypasses the catalog: this
test greps for that literal (inside a Blorp string, i.e. preceded by a
quote or another call already inside one) and fails if any remain outside
the renderer files themselves.

ALLOWED_RESIDUE lists any site that must stay a direct call along with the
CleanupPlan/catalog row that already accounts for it; it is empty today --
every site found when this test was added was moved into a renderer entry
(see the commit that added this file).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
EMIT_BRP = ROOT / "blorp" / "src" / "compiler" / "stage_10_backend" / "emit.brp"

# One regex per raw allocating call. These match the C function name inside
# a Blorp string literal (i.e. immediately preceded by a `"`), which is how
# emit.brp would spell a direct call; a bare occurrence inside a comment or
# as a substring of a longer identifier does not count.
DIRECT_ALLOCATION_PATTERNS = {
    "blorp_alloc(": re.compile(r'blorp_alloc\('),
    "blorp_string_create(": re.compile(r'blorp_string_create\('),
    "blorp_list_new(": re.compile(r'blorp_list_new\('),
    "blorp_list_new_inline(": re.compile(r'blorp_list_new_inline\('),
}

# (line substring, plan/commit reference) for any residue that must remain
# a direct call in emit.brp. Empty: every site found was routed through a
# renderer entry when this test was added.
ALLOWED_RESIDUE: dict[str, str] = {}


class NoDirectEmitterAllocationTests(unittest.TestCase):
    def test_emit_brp_has_no_direct_allocation_calls(self) -> None:
        self.assertTrue(EMIT_BRP.exists(), f"{EMIT_BRP} not found")
        lines = EMIT_BRP.read_text().splitlines()

        offenders: list[str] = []
        for lineno, line in enumerate(lines, start=1):
            for needle, pattern in DIRECT_ALLOCATION_PATTERNS.items():
                if not pattern.search(line):
                    continue
                if needle in ALLOWED_RESIDUE:
                    continue
                offenders.append(f"{EMIT_BRP}:{lineno}: {needle} -> {line.strip()[:160]}")

        self.assertEqual(
            offenders,
            [],
            "emit.brp calls an allocating runtime function directly instead of "
            "through a cataloged renderer entry:\n" + "\n".join(offenders),
        )


if __name__ == "__main__":
    unittest.main()
