#!/usr/bin/env python3
"""Contract tests for scripts/audit-issue-handoffs."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
AUDIT = ROOT / "scripts" / "audit-issue-handoffs"


class AuditIssueHandoffsTests(unittest.TestCase):
	def write_issue_tree(self, root: Path) -> None:
		issue_root = root / "docs/issues"
		workflow = issue_root / "agent-workflow"
		workflow.mkdir(parents=True)
		(issue_root / "README.md").write_text(
			"\n".join(
				[
					"# Active Engineering Issues",
					"",
					"### Agent Development Workflow",
					"",
					"- [Ready handoff](agent-workflow/01-ready.md)",
					"- [Missing fields](agent-workflow/03-missing-fields.md)",
					"- [Long handoff](agent-workflow/04-long.md)",
					"- [Missing file](agent-workflow/99-missing.md)",
					"",
					"### Empty Workstream",
					"",
					"- [Only missing](empty-workstream/01-missing.md)",
					"",
				]
			),
			encoding="utf-8",
		)
		(issue_root / "empty-workstream").mkdir()
		(workflow / "01-ready.md").write_text(
			"\n".join(
				[
					"# Ready Handoff",
					"",
					"**Status:** Proposed",
					"",
					"**Current state:** The fixture is current.",
					"**Next action:** Run the audit.",
					"**Read first:** [Fixture](support.md).",
					"**Fast loop:** `scripts/audit-issue-handoffs --scope docs/issues/agent-workflow`",
					"**Decision:** Keep mechanical findings separate from semantic review.",
					"",
					"## Objective",
					"",
					"Audit the issue handoff shape.",
					"",
				]
			),
			encoding="utf-8",
		)
		(workflow / "02-unindexed.md").write_text(
			"\n".join(
				[
					"# Unindexed Handoff",
					"",
					"**Status:** Proposed",
					"",
					"**Current state:** Present but unindexed.",
					"**Next action:** Add an index link.",
					"**Read first:** `docs/issues/README.md`.",
					"**Fast loop:** `scripts/audit-issue-handoffs --scope docs/issues/agent-workflow`",
					"**Decision:** Report this as mechanical drift.",
					"",
					"## Objective",
					"",
					"Demonstrate an unindexed active issue.",
					"",
					"See [Broken](missing-support.md).",
					"",
				]
			),
			encoding="utf-8",
		)
		(workflow / "03-missing-fields.md").write_text(
			"# Missing Fields\n\n**Status:** Proposed\n",
			encoding="utf-8",
		)
		(workflow / "04-long.md").write_text(
			"\n".join(
				[
					"# Long Handoff",
					"",
					"**Status:** Proposed",
					"",
					"## Objective",
					"",
					"Keep this as a warning.",
					*(f"line {line_number}" for line_number in range(305)),
				]
			),
			encoding="utf-8",
		)
		(workflow / "support.md").write_text("# Support\n", encoding="utf-8")

	def run_audit(
		self,
		root: Path,
		*arguments: str,
	) -> subprocess.CompletedProcess[str]:
		return subprocess.run(
			["python3", str(AUDIT), "--root", str(root), *arguments],
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=False,
		)

	def test_reports_index_link_shape_and_long_document_findings(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_issue_tree(root)

			result = self.run_audit(
				root,
				"--scope",
				"docs/issues/agent-workflow",
				"--json",
			)

			self.assertEqual(result.returncode, 1, result.stderr)
			payload = json.loads(result.stdout)
			findings = {
				(finding["kind"], finding["path"])
				for finding in payload["findings"]
			}
			self.assertIn(
				("broken_index_link", "docs/issues/README.md"),
				findings,
			)
			self.assertIn(
				("unindexed_issue", "docs/issues/agent-workflow/02-unindexed.md"),
				findings,
			)
			self.assertIn(
				("broken_local_link", "docs/issues/agent-workflow/02-unindexed.md"),
				findings,
			)
			self.assertIn(
				("missing_objective", "docs/issues/agent-workflow/03-missing-fields.md"),
				findings,
			)
			self.assertIn(
				("long_document", "docs/issues/agent-workflow/04-long.md"),
				findings,
			)
			self.assertEqual(payload["summary"]["errors"], 4)
			self.assertEqual(payload["summary"]["warnings"], 1)

	def test_reports_broken_index_links_when_scope_has_no_issue_files(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			self.write_issue_tree(root)

			result = self.run_audit(
				root,
				"--scope",
				"docs/issues/empty-workstream",
				"--json",
			)

			self.assertEqual(result.returncode, 1, result.stderr)
			payload = json.loads(result.stdout)
			self.assertEqual(payload["summary"]["errors"], 1)
			self.assertEqual(payload["findings"][0]["kind"], "broken_index_link")

	def test_audits_indexed_nonnumeric_files_without_status(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			issue_root = root / "docs/issues"
			workflow = issue_root / "agent-workflow"
			workflow.mkdir(parents=True)
			(issue_root / "README.md").write_text(
				"\n".join(
					[
						"# Active Engineering Issues",
						"",
						"### Agent Development Workflow",
						"",
						"- [Named handoff](agent-workflow/named-handoff.md)",
						"",
					]
				),
				encoding="utf-8",
			)
			(workflow / "named-handoff.md").write_text(
				"# Named Handoff\n\n## Objective\n\nThis indexed handoff is missing status.\n",
				encoding="utf-8",
			)
			(workflow / "support.md").write_text(
				"# Support\n\nThis unindexed note should not be audited as a handoff.\n",
				encoding="utf-8",
			)

			result = self.run_audit(
				root,
				"--scope",
				"docs/issues/agent-workflow",
				"--json",
			)

			self.assertEqual(result.returncode, 1, result.stderr)
			payload = json.loads(result.stdout)
			self.assertEqual(payload["summary"]["errors"], 1)
			self.assertEqual(payload["findings"][0]["kind"], "missing_status")
			self.assertEqual(
				payload["findings"][0]["path"],
				"docs/issues/agent-workflow/named-handoff.md",
			)

	def test_reports_missing_markdown_anchor_targets(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			issue_root = root / "docs/issues"
			workflow = issue_root / "agent-workflow"
			workflow.mkdir(parents=True)
			(issue_root / "README.md").write_text(
				"\n".join(
					[
						"# Active Engineering Issues",
						"",
						"### Agent Development Workflow",
						"",
						"- [Anchor handoff](agent-workflow/01-anchor.md)",
						"",
					]
				),
				encoding="utf-8",
			)
			(workflow / "01-anchor.md").write_text(
				"\n".join(
					[
						"# Anchor Handoff",
						"",
						"**Status:** Proposed",
						"",
						"## Objective",
						"",
						"Check [missing anchor](support.md#missing-section).",
						"",
					]
				),
				encoding="utf-8",
			)
			(workflow / "support.md").write_text("# Present Section\n", encoding="utf-8")

			result = self.run_audit(
				root,
				"--scope",
				"docs/issues/agent-workflow",
				"--json",
			)

			self.assertEqual(result.returncode, 1, result.stderr)
			payload = json.loads(result.stdout)
			self.assertEqual(payload["summary"]["errors"], 1)
			self.assertEqual(payload["findings"][0]["kind"], "broken_local_link")
			self.assertIn("#missing-section", payload["findings"][0]["message"])

	def test_reports_missing_same_file_anchor_targets(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			issue_root = root / "docs/issues"
			workflow = issue_root / "agent-workflow"
			workflow.mkdir(parents=True)
			(issue_root / "README.md").write_text(
				"\n".join(
					[
						"# Active Engineering Issues",
						"",
						"### Agent Development Workflow",
						"",
						"- [Anchor handoff](agent-workflow/01-anchor.md)",
						"",
					]
				),
				encoding="utf-8",
			)
			(workflow / "01-anchor.md").write_text(
				"\n".join(
					[
						"# Anchor Handoff",
						"",
						"**Status:** Proposed",
						"",
						"## Objective",
						"",
						"Check [missing anchor](#missing-section).",
						"",
					]
				),
				encoding="utf-8",
			)

			result = self.run_audit(
				root,
				"--scope",
				"docs/issues/agent-workflow",
				"--json",
			)

			self.assertEqual(result.returncode, 1, result.stderr)
			payload = json.loads(result.stdout)
			self.assertEqual(payload["summary"]["errors"], 1)
			self.assertEqual(payload["findings"][0]["kind"], "broken_local_link")
			self.assertIn("#missing-section", payload["findings"][0]["message"])

	def test_accepts_duplicate_markdown_heading_anchor_suffixes(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			issue_root = root / "docs/issues"
			workflow = issue_root / "agent-workflow"
			workflow.mkdir(parents=True)
			(issue_root / "README.md").write_text(
				"\n".join(
					[
						"# Active Engineering Issues",
						"",
						"### Agent Development Workflow",
						"",
						"- [Anchor handoff](agent-workflow/01-anchor.md)",
						"",
					]
				),
				encoding="utf-8",
			)
			(workflow / "01-anchor.md").write_text(
				"\n".join(
					[
						"# Anchor Handoff",
						"",
						"**Status:** Proposed",
						"",
						"## Objective",
						"",
						"Check [duplicate anchor](support.md#section-1).",
						"",
					]
				),
				encoding="utf-8",
			)
			(workflow / "support.md").write_text(
				"# Section\n\n## Section\n",
				encoding="utf-8",
			)

			result = self.run_audit(
				root,
				"--scope",
				"docs/issues/agent-workflow",
			)

			self.assertEqual(result.returncode, 0, result.stderr)
			self.assertIn("errors=0 warnings=0", result.stdout)

	def test_text_output_is_read_only_and_keeps_warnings_nonfatal(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			issue_root = root / "docs/issues"
			workflow = issue_root / "agent-workflow"
			workflow.mkdir(parents=True)
			(issue_root / "README.md").write_text(
				"\n".join(
					[
						"# Active Engineering Issues",
						"",
						"### Agent Development Workflow",
						"",
						"- [Long handoff](agent-workflow/01-long.md)",
						"",
					]
				),
				encoding="utf-8",
			)
			(workflow / "01-long.md").write_text(
				"\n".join(
					[
						"# Long Handoff",
						"",
						"**Status:** Proposed",
						"",
						"## Objective",
						"",
						"Long but mechanically valid.",
						*(f"line {line_number}" for line_number in range(305)),
					]
				),
				encoding="utf-8",
			)
			before = {
				path.relative_to(root): path.read_bytes()
				for path in sorted(root.rglob("*"))
				if path.is_file()
			}

			result = self.run_audit(root, "--scope", "docs/issues/agent-workflow")

			after = {
				path.relative_to(root): path.read_bytes()
				for path in sorted(root.rglob("*"))
				if path.is_file()
			}
			self.assertEqual(result.returncode, 0, result.stderr)
			self.assertEqual(before, after)
			self.assertIn("WARN long_document", result.stdout)
			self.assertIn("errors=0 warnings=1", result.stdout)


if __name__ == "__main__":
	unittest.main()
