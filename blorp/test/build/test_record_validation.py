#!/usr/bin/env python3
"""Contract tests for scripts/record-validation."""

from __future__ import annotations

import hashlib
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RECORDER = ROOT / "scripts" / "record-validation"


def sha256_file(path: Path) -> str:
	digest = hashlib.sha256()
	with path.open("rb") as source:
		for chunk in iter(lambda: source.read(1024 * 1024), b""):
			digest.update(chunk)
	return digest.hexdigest()


class RecordValidationTests(unittest.TestCase):
	def run_recorder(
		self,
		output: Path,
		command: list[str],
		*,
		cwd: Path | None = None,
		extra_env: dict[str, str] | None = None,
		replace: bool = False,
		timeout_seconds: float | None = None,
	) -> subprocess.CompletedProcess[str]:
		recorder_command = [sys.executable, str(RECORDER), "--output", str(output)]
		if replace:
			recorder_command.append("--replace")
		if timeout_seconds is not None:
			recorder_command.extend(["--timeout", str(timeout_seconds)])
		recorder_command.extend(["--", *command])
		env = os.environ.copy()
		env.update(
			{
				"BLORP_COMPILER_TEST_TIMEOUT": "17",
				"BLORP_API_TOKEN": "do-not-record-this-secret",
				"BLORP_CC": "fake cc with spaces",
			}
		)
		if extra_env is not None:
			env.update(extra_env)
		return subprocess.run(
			recorder_command,
			cwd=cwd or ROOT,
			env=env,
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=False,
		)

	def write_fake_command(self, directory: Path, body: str) -> Path:
		command = directory / "fake command.sh"
		command.write_text("#!/usr/bin/env bash\nset -u\n" + body, encoding="utf-8")
		command.chmod(command.stat().st_mode | stat.S_IXUSR)
		return command

	def read_metadata(self, output: Path) -> dict[str, object]:
		return json.loads((output / "metadata.json").read_text(encoding="utf-8"))

	def test_missing_recorder_documents_unimplemented_interface(self) -> None:
		if RECORDER.exists():
			self.skipTest("scripts/record-validation exists")
		with tempfile.TemporaryDirectory() as directory:
			result = self.run_recorder(Path(directory) / "packet", ["true"])
		self.assertNotEqual(result.returncode, 0)

	def test_success_packet_preserves_command_output_and_safe_provenance(self) -> None:
		if not RECORDER.exists():
			self.skipTest("scripts/record-validation is not implemented yet")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			argv_log = root / "argv.json"
			command = self.write_fake_command(
				root,
				(
					f"python3 - <<'PY' \"$@\"\n"
					f"import json, pathlib, sys\n"
					f"pathlib.Path({str(argv_log)!r}).write_text(json.dumps(sys.argv[1:]), encoding='utf-8')\n"
					f"PY\n"
					f"printf 'out:%s\\n' \"$1\"\n"
					f"printf 'err:%s\\n' \"$2\" >&2\n"
					f"exit 0\n"
				),
			)
			output = root / "packet"
			untracked_probe = ROOT / "record-validation-untracked-probe.tmp"

			try:
				untracked_probe.write_text("untracked source identity\n", encoding="utf-8")
				result = self.run_recorder(
					output,
					[str(command), "space value", "semi;and$literal"],
				)
			finally:
				untracked_probe.unlink(missing_ok=True)

			self.assertEqual(result.returncode, 0, result.stderr)
			self.assertEqual(
				json.loads(argv_log.read_text(encoding="utf-8")),
				["space value", "semi;and$literal"],
			)
			metadata = self.read_metadata(output)
			self.assertEqual(metadata["schema_version"], 1)
			self.assertEqual(
				metadata["command"],
				[str(command), "space value", "semi;and$literal"],
			)
			self.assertEqual(metadata["cwd"], str(ROOT))
			self.assertEqual(metadata["exit_code"], 0)
			self.assertIsInstance(metadata["elapsed_ms"], int)
			self.assertRegex(str(metadata["started_at_utc"]), r"^\d{4}-\d{2}-\d{2}T")
			self.assertRegex(str(metadata["git_head"]), r"^[0-9a-f]{40}$")
			self.assertIsInstance(metadata["git_dirty"], bool)
			self.assertRegex(str(metadata["tracked_diff_sha256"]), r"^[0-9a-f]{64}$")
			self.assertGreaterEqual(metadata["untracked_file_count"], 1)
			self.assertRegex(str(metadata["untracked_file_sha256"]), r"^[0-9a-f]{64}$")
			self.assertRegex(str(metadata["worktree_fingerprint_sha256"]), r"^[0-9a-f]{64}$")
			self.assertIn("start_source", metadata)
			self.assertIn("end_source", metadata)
			self.assertFalse(metadata["source_changed_during_run"])
			self.assertRegex(str(metadata["bin_blorp_sha256"]), r"^(absent|[0-9a-f]{64})$")
			self.assertEqual(metadata["artifacts"], ["stdout.log", "stderr.log"])
			environment = metadata["environment"]
			self.assertEqual(
				environment,
				{"BLORP_COMPILER_TEST_TIMEOUT": "17", "BLORP_CC": "fake cc with spaces"},
			)
			self.assertNotIn("do-not-record-this-secret", (output / "metadata.json").read_text())
			self.assertIn("out:space value\n", (output / "stdout.log").read_text(encoding="utf-8"))
			self.assertIn("err:semi;and$literal\n", (output / "stderr.log").read_text(encoding="utf-8"))
			self.assertIn(str(output), result.stdout)
			self.assertIn("scripts/record-validation --output", result.stdout)

	def test_nonzero_and_signal_status_are_preserved(self) -> None:
		if not RECORDER.exists():
			self.skipTest("scripts/record-validation is not implemented yet")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			exit_command = self.write_fake_command(root, "echo before-exit\nexit 42\n")
			exit_output = root / "exit-packet"

			exit_result = self.run_recorder(exit_output, [str(exit_command)])

			self.assertEqual(exit_result.returncode, 42)
			self.assertEqual(self.read_metadata(exit_output)["exit_code"], 42)
			self.assertIn("before-exit", (exit_output / "stdout.log").read_text())

			signal_command = self.write_fake_command(root, "kill -TERM $$\n")
			signal_output = root / "signal-packet"

			signal_result = self.run_recorder(signal_output, [str(signal_command)])

			self.assertEqual(signal_result.returncode, 128 + signal.SIGTERM)
			self.assertEqual(self.read_metadata(signal_output)["exit_code"], -signal.SIGTERM)

	def test_timeout_records_and_returns_failure_without_hiding_output(self) -> None:
		if not RECORDER.exists():
			self.skipTest("scripts/record-validation is not implemented yet")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			command = self.write_fake_command(
				root,
				"echo ready\nsleep 5\necho too-late\n",
			)
			output = root / "timeout-packet"

			result = self.run_recorder(output, [str(command)], timeout_seconds=1.0)

			self.assertEqual(result.returncode, 124)
			metadata = self.read_metadata(output)
			self.assertEqual(metadata["exit_code"], 124)
			self.assertTrue(metadata["timed_out"])
			self.assertIn("ready", (output / "stdout.log").read_text())
			self.assertNotIn("too-late", (output / "stdout.log").read_text())

	def test_existing_output_directory_is_refused_unless_replace_is_explicit(self) -> None:
		if not RECORDER.exists():
			self.skipTest("scripts/record-validation is not implemented yet")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			command = self.write_fake_command(root, "echo should-not-run > ran.txt\n")
			output = root / "packet"
			output.mkdir()
			(output / "keep.txt").write_text("preserve me", encoding="utf-8")

			refused = self.run_recorder(output, [str(command)], cwd=root)

			self.assertNotEqual(refused.returncode, 0)
			self.assertEqual((output / "keep.txt").read_text(encoding="utf-8"), "preserve me")
			self.assertFalse((root / "ran.txt").exists())

			replace_refused = self.run_recorder(output, [str(command)], cwd=root, replace=True)

			self.assertNotEqual(replace_refused.returncode, 0)
			self.assertEqual((output / "keep.txt").read_text(encoding="utf-8"), "preserve me")
			self.assertFalse((root / "ran.txt").exists())

			victim = root / "victim.txt"
			victim.write_text("outside packet", encoding="utf-8")
			output.joinpath("metadata.json").write_text(
				json.dumps(
					{
						"schema_version": 1,
						"artifacts": ["../victim.txt", "/tmp/absolute-victim.txt"],
						"artifact_sha256": {},
					}
				),
				encoding="utf-8",
			)
			malformed_replace = self.run_recorder(output, [str(command)], cwd=root, replace=True)

			self.assertNotEqual(malformed_replace.returncode, 0)
			self.assertEqual(victim.read_text(encoding="utf-8"), "outside packet")
			self.assertEqual((output / "keep.txt").read_text(encoding="utf-8"), "preserve me")
			self.assertFalse((root / "ran.txt").exists())

			inside_victim = output / "user.txt"
			inside_victim.write_text("not a recorder artifact", encoding="utf-8")
			output.joinpath("metadata.json").write_text(
				json.dumps(
					{
						"schema_version": 1,
						"artifacts": ["stdout.log", "stderr.log", "user.txt"],
						"artifact_sha256": {},
					}
				),
				encoding="utf-8",
			)
			same_directory_refused = self.run_recorder(
				output,
				[str(command)],
				cwd=root,
				replace=True,
			)

			self.assertNotEqual(same_directory_refused.returncode, 0)
			self.assertEqual(inside_victim.read_text(encoding="utf-8"), "not a recorder artifact")
			self.assertFalse((root / "ran.txt").exists())
			inside_victim.unlink()

			outside_symlink_target = root / "outside-created.txt"
			output.joinpath("stdout.log").symlink_to(Path("..") / outside_symlink_target.name)
			output.joinpath("metadata.json").write_text(
				json.dumps(
					{
						"schema_version": 1,
						"artifacts": ["stdout.log", "stderr.log"],
						"artifact_sha256": {},
					}
				),
				encoding="utf-8",
			)
			symlink_refused = self.run_recorder(output, [str(command)], cwd=root, replace=True)

			self.assertNotEqual(symlink_refused.returncode, 0)
			self.assertFalse(outside_symlink_target.exists())
			self.assertFalse((root / "ran.txt").exists())
			output.joinpath("stdout.log").unlink()
			(output / "metadata.json").write_text(
				json.dumps(
					{
						"schema_version": 1,
						"artifacts": ["stdout.log", "stderr.log"],
						"artifact_sha256": {},
					}
				),
				encoding="utf-8",
			)
			(output / "stdout.log").write_text("old stdout", encoding="utf-8")
			(output / "stderr.log").write_text("old stderr", encoding="utf-8")
			(output / "keep.txt").unlink()
			replaced = self.run_recorder(output, [str(command)], cwd=root, replace=True)

			self.assertEqual(replaced.returncode, 0, replaced.stderr)
			self.assertTrue((root / "ran.txt").is_file())
			self.assertEqual(self.read_metadata(output)["cwd"], str(root.resolve()))

	def test_artifact_hashes_match_captured_logs(self) -> None:
		if not RECORDER.exists():
			self.skipTest("scripts/record-validation is not implemented yet")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			command = self.write_fake_command(root, "echo hash-me\n")
			output = root / "packet"

			result = self.run_recorder(output, [str(command)])

			self.assertEqual(result.returncode, 0, result.stderr)
			metadata = self.read_metadata(output)
			self.assertEqual(
				metadata["artifact_sha256"],
				{
					"stdout.log": sha256_file(output / "stdout.log"),
					"stderr.log": sha256_file(output / "stderr.log"),
				},
			)

	def test_no_git_checkout_and_missing_binary_are_unavailable_not_fatal(self) -> None:
		if not RECORDER.exists():
			self.skipTest("scripts/record-validation is not implemented yet")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			command = self.write_fake_command(root, "echo outside-git\n")
			output = root / "packet"

			result = self.run_recorder(output, [str(command)], cwd=root)

			self.assertEqual(result.returncode, 0, result.stderr)
			metadata = self.read_metadata(output)
			self.assertEqual(metadata["cwd"], str(root.resolve()))
			self.assertEqual(metadata["git_head"], "unavailable")
			self.assertEqual(metadata["tracked_diff_sha256"], "unavailable")
			self.assertEqual(metadata["untracked_file_count"], 0)
			self.assertEqual(metadata["untracked_file_sha256"], "unavailable")
			self.assertEqual(metadata["worktree_fingerprint_sha256"], "unavailable")
			self.assertEqual(metadata["source_changed_during_run"], "unknown")
			self.assertEqual(metadata["bin_blorp_sha256"], "absent")

	def test_records_start_and_end_source_when_command_mutates_tracked_input(self) -> None:
		if not RECORDER.exists():
			self.skipTest("scripts/record-validation is not implemented yet")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			repo = root / "repo"
			repo.mkdir()
			subprocess.run(["git", "init"], cwd=repo, stdout=subprocess.DEVNULL, check=True)
			subprocess.run(
				["git", "config", "user.email", "validation@example.invalid"],
				cwd=repo,
				check=True,
			)
			subprocess.run(
				["git", "config", "user.name", "Validation Test"],
				cwd=repo,
				check=True,
			)
			tracked = repo / "tracked.brp"
			tracked.write_text("func value() -> Int:\n\t1\n", encoding="utf-8")
			subprocess.run(["git", "add", "tracked.brp"], cwd=repo, check=True)
			subprocess.run(
				["git", "commit", "-m", "initial"],
				cwd=repo,
				stdout=subprocess.DEVNULL,
				check=True,
			)
			command = self.write_fake_command(
				root,
				f"printf 'func value() -> Int:\\n\\t2\\n' > {str(tracked)!r}\n",
			)
			output = repo / "validation-packet"

			result = self.run_recorder(output, [str(command)], cwd=repo)

			self.assertEqual(result.returncode, 0, result.stderr)
			metadata = self.read_metadata(output)
			start_source = metadata["start_source"]
			end_source = metadata["end_source"]
			self.assertFalse(start_source["git_dirty"])
			self.assertTrue(end_source["git_dirty"])
			self.assertNotEqual(
				start_source["tracked_diff_sha256"],
				end_source["tracked_diff_sha256"],
			)
			self.assertNotEqual(
				start_source["worktree_fingerprint_sha256"],
				end_source["worktree_fingerprint_sha256"],
			)
			self.assertTrue(metadata["source_changed_during_run"])
			self.assertEqual(metadata["worktree_fingerprint_excludes"], str(output.resolve()))
			self.assertEqual(start_source["untracked_file_count"], 0)
			self.assertEqual(end_source["untracked_file_count"], 0)

	def test_output_exclusion_does_not_hide_source_symlink_pointing_into_packet(self) -> None:
		if not RECORDER.exists():
			self.skipTest("scripts/record-validation is not implemented yet")
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			repo = root / "repo"
			repo.mkdir()
			subprocess.run(["git", "init"], cwd=repo, stdout=subprocess.DEVNULL, check=True)
			subprocess.run(
				["git", "config", "user.email", "validation@example.invalid"],
				cwd=repo,
				check=True,
			)
			subprocess.run(
				["git", "config", "user.name", "Validation Test"],
				cwd=repo,
				check=True,
			)
			tracked = repo / "tracked.brp"
			tracked.write_text("func value() -> Int:\n\t1\n", encoding="utf-8")
			subprocess.run(["git", "add", "tracked.brp"], cwd=repo, check=True)
			subprocess.run(
				["git", "commit", "-m", "initial"],
				cwd=repo,
				stdout=subprocess.DEVNULL,
				check=True,
			)
			output = repo / "validation-packet"
			source_link = repo / "source-link"
			source_link.symlink_to(Path("validation-packet") / "generated.log")
			command = self.write_fake_command(root, "echo no-source-change\n")

			result = self.run_recorder(output, [str(command)], cwd=repo)

			self.assertEqual(result.returncode, 0, result.stderr)
			metadata = self.read_metadata(output)
			start_source = metadata["start_source"]
			end_source = metadata["end_source"]
			self.assertEqual(start_source["untracked_file_count"], 1)
			self.assertEqual(end_source["untracked_file_count"], 1)
			self.assertEqual(
				start_source["worktree_fingerprint_sha256"],
				end_source["worktree_fingerprint_sha256"],
			)
			self.assertFalse(metadata["source_changed_during_run"])


if __name__ == "__main__":
	unittest.main()
