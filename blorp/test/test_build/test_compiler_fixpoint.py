#!/usr/bin/env python3
"""Process-free checks for scripts/compiler-fixpoint and the stage builder's
--generator and --c-only options."""

import runpy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
fixpoint = runpy.run_path(str(ROOT / "scripts" / "compiler-fixpoint"))
builder = runpy.run_path(str(ROOT / "benchmarks" / "build_stage2_compiler"))

RECIPE = (
    'echo "Generating Blorp CLI C"; \\\n'
    '"$bootstrap_compiler" compile --std-dir "standard_library/src" \\\n'
    '\t--no-format --no-embed-runtime -o "$tmp_c" "blorp/src/main.brp"; \\\n'
)


class FixpointTests(unittest.TestCase):
    def run_stages(self, outputs):
        """Run fixpoint() with each stage writing the given C text."""
        calls = []

        def fake_builder(arguments, what):
            calls.append(arguments)
            generated = Path(arguments[arguments.index("--generated-c") + 1])
            generated.write_text(outputs[len(calls) - 1])

        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(fixpoint["fixpoint"].__globals__, {"run_stage_builder": fake_builder}):
                status = fixpoint["fixpoint"](Path(directory))
        return status, calls

    def test_identical_stage_two_and_three_output_is_a_fixpoint(self):
        status, calls = self.run_stages(["a\n", "b\n", "b\n"])
        self.assertEqual(status, fixpoint["FIXPOINT"])
        self.assertEqual(len(calls), 3)
        self.assertIn("--c-only", calls[2])
        self.assertEqual(Path(calls[1][calls[1].index("--generator") + 1]).name, "blorp-stage2")

    def test_differing_stage_two_and_three_output_is_not_a_fixpoint(self):
        status, _ = self.run_stages(["a\n", "b\nc\n", "b\nd\n"])
        self.assertEqual(status, fixpoint["NOT_A_FIXPOINT"])

    def test_first_difference_names_the_line(self):
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left.c"
            right = Path(directory) / "right.c"
            left.write_text("same\nleft\n")
            right.write_text("same\nright\n")
            self.assertIn("line 2", fixpoint["first_difference"](left, right))


class GeneratorOptionTests(unittest.TestCase):
    def test_generate_command_uses_the_given_generator(self):
        command = builder["extract_generate_command"](RECIPE, Path("/stage2"), Path("/out.c"))
        self.assertEqual(command[0], "/stage2")
        self.assertEqual(command[-3:], ["-o", "/out.c", "blorp/src/main.brp"])

    def test_c_only_requires_a_generated_c_path(self):
        with self.assertRaises(SystemExit):
            builder["main"](["--c-only"])

    def test_c_only_generates_without_building(self):
        generated = []
        with patch.dict(builder["main"].__globals__, {"generate": lambda gen, out: generated.append((gen, out))}):
            with patch.dict(builder["main"].__globals__, {"sha256_file": lambda path: "digest"}):
                status = builder["main"](["--generator", "/stage3", "--generated-c", "/tmp/x.c", "--c-only"])
        self.assertEqual(status, 0)
        self.assertEqual(
            [(str(g), str(o)) for g, o in generated],
            [(str(Path("/stage3").resolve()), str(Path("/tmp/x.c").resolve()))],
        )


if __name__ == "__main__":
    unittest.main()
