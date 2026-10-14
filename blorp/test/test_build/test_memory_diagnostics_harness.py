#!/usr/bin/env python3
"""Fast, process-free checks for paired compiler measurement safeguards."""

import runpy
import subprocess
import tempfile
import unittest
import json
import contextlib
import io
from pathlib import Path
from unittest.mock import patch


BENCHMARKS_DIR = Path(__file__).resolve().parents[3] / "benchmarks"
builder = runpy.run_path(str(BENCHMARKS_DIR / "build_stage2_compiler"))
measure = runpy.run_path(str(BENCHMARKS_DIR / "self_compile_measure"))
emission = runpy.run_path(str(BENCHMARKS_DIR / "c_emission_bytes"))


class PairedCompilerTests(unittest.TestCase):
    def test_make_recipe_selects_diagnostic_mode(self):
        with patch.object(builder["subprocess"], "run", return_value=subprocess.CompletedProcess([], 0, "recipe", "")) as run:
            self.assertEqual(builder["make_recipe"]("compile-prepared-blorp-cli", 1), "recipe")
        self.assertIn("BLORP_MEMORY_DIAGNOSTICS=1", run.call_args.args[0])

    def test_binary_mode_rejects_swapped_and_missing_provenance(self):
        for output in ("memory_diagnostics: 0\n", "blorp 0.0.1\n"):
            with self.subTest(output=output):
                with patch.object(builder["subprocess"], "run", return_value=subprocess.CompletedProcess([], 0, output, "")):
                    with self.assertRaises(builder["BuildError"]):
                        builder["verify_binary_mode"](Path("diagnostic"), 1)
        with patch.object(builder["subprocess"], "run", return_value=subprocess.CompletedProcess([], 0, "memory_diagnostics: 1\n", "")):
            builder["verify_binary_mode"](Path("diagnostic"), 1)

    def test_checkpoint_requires_actual_counters(self):
        with self.assertRaisesRegex(measure["MeasureError"], "no allocation checkpoints"):
            measure["checkpoint_deltas"]([])
        with self.assertRaisesRegex(measure["MeasureError"], "missing allocator_bytes"):
            measure["checkpoint_deltas"]([{
                "phase": "parse", "total_allocations": "2", "current_objects": "1",
                "rss_bytes": "100",
            }])
        rows = measure["checkpoint_deltas"]([{
            "phase": "parse", "total_allocations": "2", "current_objects": "1",
            "allocator_bytes": "64", "rss_bytes": "100",
        }])
        self.assertEqual(rows[0]["delta_allocations"], 2)

    def test_pair_rejects_swapped_modes_and_incomplete_provenance(self):
        normal = {
            "memory_diagnostics": "0", "commit": "abc", "compiled_by": "self-abc",
            "optimization": "cli=-O2 runtime=-O2", "target": "arm64-darwin",
            "split": "8", "cc": "clang",
        }
        diagnostic = {**normal, "memory_diagnostics": "1"}
        measure["validate_compiler_pair"](normal, diagnostic)
        with self.assertRaisesRegex(measure["MeasureError"], "expected 0"):
            measure["validate_compiler_pair"](diagnostic, normal)
        with self.assertRaisesRegex(measure["MeasureError"], "cc provenance is missing"):
            measure["validate_compiler_pair"](normal, {**diagnostic, "cc": "unknown"})
        with self.assertRaisesRegex(measure["MeasureError"], "optimization differs"):
            measure["validate_compiler_pair"](
                normal, {**diagnostic, "optimization": "cli=-O2 runtime=-O0"}
            )

    def test_c_emission_reader_accepts_legacy_and_paired_records(self):
        legacy = {
            "schema": 1, "output_sha256": "a" * 64,
            "compiler_sha256": "b" * 64, "input_rev": "c" * 40,
            "compiler_rev": "d" * 40, "compiler_path": "/tmp/compiler",
            "c_optimization": "-O2", "compiler_build_status": "FRESH",
            "program": "self", "compiler_stage": 2, "output_bytes": 100,
            "toolchain": {"cc_version": "clang"},
        }
        paired = {
            **legacy, "schema": 2, "diagnostic_compiler_sha256": "e" * 64,
            "diagnostic_compiler_path": "/tmp/diagnostic",
            "toolchain": {"cc_version": "clang", "memory_diagnostics": "0"},
            "diagnostic_toolchain": {"memory_diagnostics": "1"},
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "measurement.json"
            for record in (legacy, paired):
                path.write_text(json.dumps(record))
                self.assertEqual(emission["load_measurement"](path), record)
            paired["diagnostic_toolchain"] = {"memory_diagnostics": "0"}
            path.write_text(json.dumps(paired))
            with self.assertRaisesRegex(ValueError, "normal and diagnostic compiler modes"):
                emission["load_measurement"](path)

    def test_measurement_comparison_labels_legacy_accounting_mode(self):
        legacy = {"schema": 1, "output_sha256": "same", "toolchain": None}
        paired = {"schema": 2, "output_sha256": "same", "toolchain": None}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = measure["compare"](legacy, paired)
        self.assertFalse(result["schema_mismatch"])
        self.assertIn("accounting-mode experiment", output.getvalue())
        with contextlib.redirect_stdout(io.StringIO()):
            unsupported = measure["compare"]({**legacy, "schema": 7}, paired)
        self.assertTrue(unsupported["schema_mismatch"])

    def test_comparison_requires_numeric_evidence(self):
        valid = {
            "schema": 1, "total_allocations": 2,
            "instructions_retired": {"min": 100}, "peak_rss_bytes": 4096,
            "output_bytes": 50,
        }
        measure["validate_record_evidence"](valid, "baseline")
        with self.assertRaisesRegex(measure["MeasureError"], "instructions_retired.min"):
            measure["validate_record_evidence"](
                {**valid, "instructions_retired": {"min": 0}}, "baseline"
            )


if __name__ == "__main__":
    unittest.main()
