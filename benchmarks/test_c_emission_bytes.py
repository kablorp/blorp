#!/usr/bin/env python3
"""Focused lexical and provenance checks for c_emission_bytes."""

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).with_name("c_emission_bytes")
NO_MEASUREMENT = object()


class CEmissionBytesTest(unittest.TestCase):
    def run_probe(self, source: bytes, measurement: object = NO_MEASUREMENT) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            c_path = root / "example.c"
            c_path.write_bytes(source)
            command = [str(TOOL), str(c_path), "--json", "--top", "2"]
            if measurement is not NO_MEASUREMENT:
                record_path = root / "measurement.json"
                record_path.write_text(json.dumps(measurement))
                command.extend(["--measurement", str(record_path)])
            return subprocess.run(command, capture_output=True, text=True, check=False)

    def test_counts_lexical_tokens_without_strings_comments_or_numbers_as_identifiers(self) -> None:
        source = (
            b"#include <stdint.h>\n"
            b"/* brp_9 */\n"
            b"typedef struct brp_ty0 brp_ty0;\n"
            b"int brp_9(void) { // __t0_1\n"
            b"  int __t0_1 = 0xBEEF + 1e+2;\n"
            b"  return __t0_1 + user_name + '\\'' + \"brp_9\"[0];\n"
            b"}\n"
        )
        result = self.run_probe(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        totals = report["bytes"]
        self.assertEqual(totals["total"], len(source))
        self.assertEqual(
            sum(totals[key] for key in ("comments", "literals", "identifiers", "structure")),
            len(source),
        )
        families = report["identifier_families"]
        self.assertEqual(families["projected_callable_spelling"]["occurrences"], 1)
        self.assertEqual(families["projected_type_spelling"]["occurrences"], 2)
        self.assertEqual(families["compact_temp_spelling"]["occurrences"], 2)
        self.assertEqual(report["top_unknown"][0]["identifier"], "user_name")
        self.assertEqual(report["top_unknown"][0]["occurrences"], 1)

    def test_checks_measurement_hash_and_carries_provenance(self) -> None:
        source = b"int main(void) { return 0; }\n"
        digest = hashlib.sha256(source).hexdigest()
        measurement = {
            "schema": 1,
            "output_sha256": digest,
            "output_bytes": len(source),
            "program": "small",
            "input_rev": "a" * 40,
            "compiler_path": "/tmp/compiler",
            "compiler_sha256": "b" * 64,
            "compiler_rev": "c" * 40,
            "compiler_build_status": "FRESH",
            "compiler_stage": 1,
            "c_optimization": "-O2",
            "toolchain": {"cc_version": "clang-test"},
        }
        good = self.run_probe(source, measurement)
        self.assertEqual(good.returncode, 0, good.stderr)
        provenance = json.loads(good.stdout)["provenance"]
        self.assertEqual(provenance["c_sha256"], digest)
        self.assertEqual(provenance["input_rev"], "a" * 40)
        self.assertEqual(provenance["compiler_sha256"], "b" * 64)
        bad = self.run_probe(source, {**measurement, "output_sha256": "wrong"})
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("output_sha256", bad.stderr)
        unknown_revision = self.run_probe(source, {**measurement, "input_rev": "unknown"})
        self.assertEqual(unknown_revision.returncode, 2)
        self.assertIn("input_rev", unknown_revision.stderr)

    def test_rejects_missing_or_non_object_measurement(self) -> None:
        source = b"int main(void) { return 0; }\n"
        for invalid in (None, [], {"schema": 1, "output_sha256": hashlib.sha256(source).hexdigest()}):
            with self.subTest(invalid=invalid):
                result = self.run_probe(source, invalid)
                self.assertEqual(result.returncode, 2)
                self.assertIn("measurement", result.stderr)

    def test_line_comment_continues_across_backslash_newline(self) -> None:
        source = b"// hidden \\\n brp_9\nint brp_1(void);\n"
        result = self.run_probe(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["identifier_families"]["projected_callable_spelling"]["occurrences"], 1)
        self.assertEqual(report["bytes"]["comments"], len(b"// hidden \\\n brp_9"))


if __name__ == "__main__":
    unittest.main()
