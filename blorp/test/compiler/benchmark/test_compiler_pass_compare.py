#!/usr/bin/env python3
"""Contract tests for benchmarks/compiler_pass_compare."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / "benchmarks" / "compiler_pass_compare"


def load_compare_module():
    loader = importlib.machinery.SourceFileLoader(
        "compiler_pass_compare_benchmark",
        str(SCRIPT),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create benchmark module spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class CompilerPassCompareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.compare = load_compare_module()

    def fake_binary(
        self,
        directory: Path,
        name: str,
        *,
        checksum: str = "same",
        malformed: bool = False,
        exit_code: int = 0,
        sleep_seconds: float = 0.0,
    ) -> Path:
        path = directory / name
        output = (
            "BROKEN OUTPUT"
            if malformed
            else (
                "FAKE_PASS_PROFILE iterations=3 shape=small checksum="
                + checksum
                + " elapsed_microseconds=101 setup_microseconds=909 "
                + "workload_valid=True"
            )
        )
        path.write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env python3
                import sys
                import time

                if {sleep_seconds!r}:
                    time.sleep({sleep_seconds!r})
                print({output!r})
                raise SystemExit({exit_code})
                """
            ),
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def run_driver(self, *arguments: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), *arguments],
            cwd=cwd or ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )

    def test_alternates_order_and_retains_raw_pairs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            baseline = self.fake_binary(temp, "baseline")
            candidate = self.fake_binary(temp, "candidate")
            results = temp / "pairs.json"

            completed = self.run_driver(
                "--label",
                "fake-pass",
                "--baseline-bin",
                str(baseline),
                "--candidate-bin",
                str(candidate),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--stable-field",
                "shape",
                "--pairs",
                "3",
                "--warmup-pairs",
                "1",
                "--results",
                str(results),
                "--json",
                "--",
                "shared",
                "args",
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            output = json.loads(completed.stdout)
            saved = json.loads(results.read_text(encoding="utf-8"))
            self.assertEqual(output["execution_order"], [
                "baseline",
                "candidate",
                "candidate",
                "baseline",
                "baseline",
                "candidate",
            ])
            self.assertEqual(saved["argument_vector"], ["shared", "args"])
            self.assertEqual(len(saved["raw_pairs"]), 3)
            self.assertEqual(saved["paired_deltas"], [
                {"pair": 0, "elapsed_microseconds": 0},
                {"pair": 1, "elapsed_microseconds": 0},
                {"pair": 2, "elapsed_microseconds": 0},
            ])
            self.assertEqual(saved["median"]["baseline_elapsed_microseconds"], 101)
            self.assertEqual(saved["median"]["candidate_elapsed_microseconds"], 101)

    def test_malformed_output_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline", malformed=True)),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate")),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("unexpected benchmark output", completed.stderr)

    def test_checksum_disagreement_fails_before_speed_claim(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline", checksum="base")),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate", checksum="candidate")),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("baseline/candidate output mismatch: checksum", completed.stderr)
            self.assertNotIn("elapsed_ratio", completed.stdout)

    def test_requires_semantic_checksum_field(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline", checksum="base")),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate", checksum="candidate")),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--pairs",
                "1",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("--checksum-field is required", completed.stderr)

    def test_nonzero_child_exit_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline", exit_code=17)),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate")),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("benchmark command failed for baseline", completed.stderr)

    def test_timeout_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline", sleep_seconds=0.2)),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate")),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
                "--timeout",
                "0.01",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("timed out for baseline", completed.stderr)

    def test_dirty_roots_fail_without_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            source_root = temp / "repo"
            source_root.mkdir()
            subprocess.run(["git", "init"], cwd=source_root, stdout=subprocess.DEVNULL, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=source_root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=source_root, check=True)
            tracked = source_root / "tracked.txt"
            tracked.write_text("clean\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=source_root, check=True)
            subprocess.run(["git", "commit", "-m", "initial"], cwd=source_root, stdout=subprocess.DEVNULL, check=True)
            tracked.write_text("dirty\n", encoding="utf-8")

            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline-bin")),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate-bin")),
                "--baseline-source-root",
                str(source_root),
                "--candidate-source-root",
                str(source_root),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("baseline source root is dirty", completed.stderr)
            self.assertEqual(tracked.read_text(encoding="utf-8"), "dirty\n")

    def test_fixture_hashes_and_allowed_dirty_roots_are_reported_without_writes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            fixture = temp / "fixture.txt"
            fixture.write_text("same input\n", encoding="utf-8")
            source_root = temp / "repo"
            source_root.mkdir()
            subprocess.run(["git", "init"], cwd=source_root, stdout=subprocess.DEVNULL, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=source_root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=source_root, check=True)
            tracked = source_root / "tracked.txt"
            tracked.write_text("clean\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=source_root, check=True)
            subprocess.run(["git", "commit", "-m", "initial"], cwd=source_root, stdout=subprocess.DEVNULL, check=True)
            tracked.write_text("dirty\n", encoding="utf-8")

            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline-bin")),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate-bin")),
                "--baseline-source-root",
                str(source_root),
                "--candidate-source-root",
                str(source_root),
                "--allow-dirty-source",
                "--fixture",
                str(fixture),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
                "--json",
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(completed.stdout)
            self.assertEqual(result["fixture_hashes"][str(fixture.resolve())]["bytes"], 11)
            self.assertTrue(result["baseline"]["source"]["dirty"])
            self.assertEqual(tracked.read_text(encoding="utf-8"), "dirty\n")

    def test_paired_fixture_sources_must_match_before_sampling(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            baseline_root = temp / "baseline"
            candidate_root = temp / "candidate"
            baseline_fixture = baseline_root / "bench" / "fixture.brp"
            candidate_fixture = candidate_root / "bench" / "fixture.brp"
            baseline_fixture.parent.mkdir(parents=True)
            candidate_fixture.parent.mkdir(parents=True)
            baseline_fixture.write_text("baseline source\n", encoding="utf-8")
            candidate_fixture.write_text("candidate source\n", encoding="utf-8")

            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline-bin")),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate-bin")),
                "--baseline-source-root",
                str(baseline_root),
                "--candidate-source-root",
                str(candidate_root),
                "--fixture-source",
                "bench/fixture.brp",
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("baseline/candidate fixture source mismatch", completed.stderr)

    def test_paired_fixture_source_symlinks_cannot_escape_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            baseline_root = temp / "baseline"
            candidate_root = temp / "candidate"
            external_fixture = temp / "external.brp"
            external_fixture.write_text("same source\n", encoding="utf-8")
            baseline_fixture = baseline_root / "bench" / "fixture.brp"
            candidate_fixture = candidate_root / "bench" / "fixture.brp"
            baseline_fixture.parent.mkdir(parents=True)
            candidate_fixture.parent.mkdir(parents=True)
            baseline_fixture.symlink_to(external_fixture)
            candidate_fixture.write_text("same source\n", encoding="utf-8")

            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline-bin")),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate-bin")),
                "--baseline-source-root",
                str(baseline_root),
                "--candidate-source-root",
                str(candidate_root),
                "--fixture-source",
                "bench/fixture.brp",
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("baseline fixture source escapes source root", completed.stderr)

    def test_matching_paired_fixture_sources_are_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            baseline_root = temp / "baseline"
            candidate_root = temp / "candidate"
            baseline_fixture = baseline_root / "bench" / "fixture.brp"
            candidate_fixture = candidate_root / "bench" / "fixture.brp"
            baseline_fixture.parent.mkdir(parents=True)
            candidate_fixture.parent.mkdir(parents=True)
            baseline_fixture.write_text("same source\n", encoding="utf-8")
            candidate_fixture.write_text("same source\n", encoding="utf-8")

            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline-bin")),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate-bin")),
                "--baseline-source-root",
                str(baseline_root),
                "--candidate-source-root",
                str(candidate_root),
                "--fixture-source",
                "bench/fixture.brp",
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
                "--json",
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(completed.stdout)
            paired_source = result["paired_fixture_sources"]["bench/fixture.brp"]
            self.assertTrue(paired_source["identical"])
            self.assertEqual(paired_source["baseline"]["bytes"], 12)
            self.assertEqual(
                paired_source["baseline"]["sha256"],
                paired_source["candidate"]["sha256"],
            )

    def test_missing_source_roots_are_unknown_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            completed = self.run_driver(
                "--baseline-bin",
                str(self.fake_binary(temp, "baseline")),
                "--candidate-bin",
                str(self.fake_binary(temp, "candidate")),
                "--prefix",
                "FAKE_PASS_PROFILE",
                "--time-field",
                "elapsed_microseconds",
                "--checksum-field",
                "checksum",
                "--pairs",
                "1",
                "--json",
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(completed.stdout)
            self.assertEqual(result["baseline"]["source"]["provenance"], "unknown")
            self.assertEqual(result["candidate"]["source"]["reason"], "source root not supplied")


if __name__ == "__main__":
    unittest.main()
