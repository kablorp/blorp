"""Contract tests for scripts/audit-compiler-antipatterns."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[4]
AUDIT = ROOT / "scripts" / "audit-compiler-antipatterns"


class CompilerAntipatternAuditTests(unittest.TestCase):
    def run_audit(self, source_root: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(AUDIT), "--source-root", str(source_root), "--json", *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def write_fixture(self, source_root: Path) -> None:
        source_root.mkdir(parents=True)
        (source_root / "sample.brp").write_text(
            """\
record CompilerState {
\tfacts: Facts,
\tnames: Dict[String, Int],
\tfirst: Option[String],
\tsecond: Option[String],
\taccepted: Bool,
\tcount: Int,
\tindex: Int,
\terrors: List[String]
}

struct TinyValue {
\tvalue: Int
}

record BoxedUses {
\toptional: Option[TinyValue],
\titems: List[TinyValue]
}

union TinyResult:
\tFoundTiny(TinyValue)
\tMissingTiny

pure func advance_one(state: CompilerState) -> CompilerState:
\tstate

pure func advance_two(state: CompilerState) -> CompilerState:
\t{ state | count = state.count + 1 }

pure func advance_three(state: CompilerState) -> CompilerState:
\t{ state | index = state.index + 1 }

pure func maybe_append(items: List[Int], should_append: Bool) -> List[Int]:
\texample: String = "Option[TinyValue]"
\t-- List[TinyValue] in prose is not a placement.
\tif should_append:
\t\titems.append(1)
\telse:
\t\titems

pure func scan_pair(items: List[Int]) -> (List[Int], Int):
\t(items, items.length())

private pure func build_name_index[T](
\titems: List[Option[T]],
) -> Dict[String, Int]:
\t{}
""",
            encoding="utf-8",
        )

    def test_reports_structural_signals_with_stable_counts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            source_root = Path(raw_temp_dir) / "compiler"
            self.write_fixture(source_root)

            result = self.run_audit(source_root, "--large-file-lines", "20")

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["schema_version"], 1)
            self.assertEqual(report["source_root"], "<external>")
            self.assertEqual(report["census"]["source_files"], 1)
            self.assertEqual(
                report["census"]["by_rule"],
                {
                    "conditional-parameter-passthrough": 1,
                    "flag-state-record": 1,
                    "index-builder": 1,
                    "large-file": 1,
                    "small-tuple-return": 1,
                    "string-keyed-dict": 2,
                    "struct-storage-review": 3,
                    "threaded-state-record": 1,
                },
            )
            findings = report["findings"]
            finding_order = [
                (item["rule"], item["path"], item["line"], item["symbol"])
                for item in findings
            ]
            self.assertEqual(finding_order, sorted(finding_order))
            threaded = next(item for item in findings if item["rule"] == "threaded-state-record")
            self.assertEqual(threaded["symbol"], "CompilerState")
            self.assertIn("3 functions", threaded["evidence"])
            passthrough = next(
                item for item in findings if item["rule"] == "conditional-parameter-passthrough"
            )
            self.assertEqual(passthrough["symbol"], "maybe_append")
            self.assertIn("items", passthrough["evidence"])

    def test_rule_filter_preserves_unfiltered_census(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            source_root = Path(raw_temp_dir) / "compiler"
            self.write_fixture(source_root)

            result = self.run_audit(source_root, "--rule", "index-builder")

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(len(report["findings"]), 1)
            self.assertEqual(report["findings"][0]["rule"], "index-builder")
            self.assertEqual(report["census"]["by_rule"]["threaded-state-record"], 1)

    def test_rejects_unknown_rule(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            source_root = Path(raw_temp_dir) / "compiler"
            self.write_fixture(source_root)

            result = self.run_audit(source_root, "--rule", "not-a-rule")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid choice", result.stderr)


if __name__ == "__main__":
    unittest.main()
