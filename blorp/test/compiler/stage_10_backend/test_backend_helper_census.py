#!/usr/bin/env python3
"""Emitted-C census for the small self-compile fixture.

This is the check that step 4 of the "emitter is a dumb printer" effort
(backend_helper_catalog.brp) was supposed to make possible: pin the exact
count of every retain/release/allocation-relevant runtime call in the C
emitted for a small, fast fixture program, so a change to the emitter or the
renderers that shifts these counts is caught immediately instead of only
showing up as a self-compile allocation-count drift.

What this test does NOT yet do: predict these counts from the prepared
program plus backend_helper_catalog.brp (BackendHelperKind / row counts).
That requires tagging every renderer call site in emit.brp with the
BackendHelperKind it renders (`RenderedHelper { kind, c }` in the design doc),
which was scoped as step 2 of the catalog task and is not done -- the catalog
exists and is total (see test_core_backend_helper_catalog.brp), but nothing
in emit.brp reads it yet. Until that wiring lands, this test pins actual
counts from the compiled C directly (a regression guard), not
catalog-predicted counts (the eventual "prediction equals reality" proof).

Residue: none tracked yet, for the same reason -- there is no prediction to
diff against. When the wiring lands, replace EXPECTED_CALL_COUNTS' role with
a real prediction built from the prepared program's rendered-helper counts
plus backend_helper_catalog.brp, and move any site that still can't be
predicted (documented emitter-introduced temporaries, per cf9a7350's audit)
into an explicit allowed-residue list here.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
BLORP_BIN = ROOT / "bin" / "blorp"
SMALL_PROGRAM = ROOT / "benchmarks" / "self_compile" / "small.brp"
STD_DIR = ROOT / "standard_library" / "src"

# Pinned counts of allocation/ownership-relevant substrings in the C emitted
# for benchmarks/self_compile/small.brp by the current compiler. Any change
# here should be explained by a corresponding source change to small.brp or
# to the renderers/emitter -- an unexplained change is exactly what this test
# exists to catch.
EXPECTED_CALL_COUNTS = {
    "blorp_retain(": 16,
    "blorp_release(": 39,
    "blorp_alloc(": 5,
    "blorp_list_new(": 3,
    "blorp_list_new_inline(": 2,
    "blorp_dict_new(": 0,
    "blorp_string_alloc(": 0,
    "blorp_tuple_new(": 0,
    "blorp_list_append(": 0,
    "blorp_list_cow(": 0,
    "blorp_dict_insert(": 0,
    "blorp_list_ensure_capacity(": 0,
    "blorp_box_struct(": 0,
    "blorp_unbox_struct(": 0,
}


def count_occurrences(text: str, needle: str) -> int:
    return len(re.findall(re.escape(needle), text))


class BackendHelperCensusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not BLORP_BIN.exists():
            raise unittest.SkipTest(f"{BLORP_BIN} not built; run `make` first")
        with tempfile.TemporaryDirectory() as temp_name:
            output = Path(temp_name) / "small.c"
            result = subprocess.run(
                [
                    str(BLORP_BIN),
                    "compile",
                    "--no-format",
                    "--no-embed-runtime",
                    "--std-dir",
                    str(STD_DIR),
                    "-o",
                    str(output),
                    str(SMALL_PROGRAM),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(
                    "bin/blorp compile failed for the small fixture:\n"
                    f"stdout: {result.stdout}\nstderr: {result.stderr}"
                )
            cls.generated_c = output.read_text()

    def test_pinned_call_counts_are_unchanged(self) -> None:
        actual = {
            needle: count_occurrences(self.generated_c, needle)
            for needle in EXPECTED_CALL_COUNTS
        }
        self.assertEqual(
            actual,
            EXPECTED_CALL_COUNTS,
            "emitted-C census for benchmarks/self_compile/small.brp changed; "
            "update EXPECTED_CALL_COUNTS only after confirming the change is "
            "intended (a renderer/emitter behaviour change), not a regression",
        )


if __name__ == "__main__":
    unittest.main()
