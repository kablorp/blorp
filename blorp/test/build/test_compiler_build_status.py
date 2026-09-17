#!/usr/bin/env python3
"""Contract tests for scripts/compiler-build-status."""

from __future__ import annotations

import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
STATUS = ROOT / "scripts" / "compiler-build-status"
BUILD_METADATA_ENV_VARS = (
	"BLORP_BUILD_VERSION",
	"BLORP_BUILD_COMMIT",
	"BLORP_BUILD_TARGET",
	"BLORP_BUILD_CHANNEL",
	"BLORP_BUILD_DIRTY",
)
BUILD_OPTIMIZATION_ENV_VARS = (
	"BLORP_CLI_C_OPTIMIZATION",
	"BLORP_CLI_RUNTIME_C_OPTIMIZATION",
)


def sha256_bytes(data: bytes) -> str:
	return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
	return sha256_bytes(path.read_bytes())


def input_manifest(root: Path, paths: list[str]) -> bytes:
	records = []
	for path in sorted(set(paths)):
		records.append(f"{sha256_file(root / path)}  {path}\n")
	return "".join(records).encode("utf-8")


def hash_lines(*lines: str) -> str:
	return sha256_bytes(("".join(f"{line}\n" for line in lines)).encode("utf-8"))


def make_executable(path: Path, data: bytes) -> None:
	path.write_bytes(data)
	path.chmod(path.stat().st_mode | stat.S_IXUSR)


class CompilerBuildStatusTests(unittest.TestCase):
	def setUp(self) -> None:
		self.tempdir = tempfile.TemporaryDirectory()
		self.root = Path(self.tempdir.name)
		self.build = self.root / "blorp/build/_build/blorp-cli"
		self.build.mkdir(parents=True)
		for directory in (
			"bin",
			"scripts",
			"blorp/build",
			"blorp/src/compiler/stage_01_generated_inputs",
			"blorp/src/lib/runtime/native",
			"blorp/src/lsp/server",
			"blorp/tool",
			"standard_library/src",
			"fake-bin",
		):
			(self.root / directory).mkdir(parents=True, exist_ok=True)

		self.fake_cc = self.root / "fake-bin/cc"
		make_executable(
			self.fake_cc,
			b"#!/bin/sh\nprintf 'fake cc 1.0\\n'\n",
		)
		make_executable(self.root / "scripts/blorp-compiler-bootstrap", b"bootstrap\n")
		make_executable(self.root / "scripts/blorp-cli-embedded-manifest", b"manifest\n")
		make_executable(self.root / "scripts/split-generated-c", b"splitter\n")
		make_executable(self.root / "bootstrap-blorp", b"bootstrap compiler\n")
		self.bootstrap_compiler = str((self.root / "bootstrap-blorp").resolve())
		self.bootstrap_target = self.detect_bootstrap_target()
		self.bootstrap_artifact_sha = "a" * 64
		self.write(
			"blorp/build/bootstrap.env",
			"\n".join(
				[
					"BLORP_BOOTSTRAP_REPO=example/blorp",
					"BLORP_BOOTSTRAP_TAG=dev-aaaaaaaaaaaa",
					"BLORP_BOOTSTRAP_VERSION=0.0.0-dev.aaaaaaaaaaaa",
					"BLORP_BOOTSTRAP_LAYOUT=direct",
					"BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN=" + self.bootstrap_artifact_sha,
					"BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=" + self.bootstrap_artifact_sha,
					"BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=" + self.bootstrap_artifact_sha,
					"",
				]
			),
		)
		self.write("blorp/src/main.brp", "func main(args: List[String]) -> Int:\n\t0\n")
		self.write("blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp", "std\n")
		self.write("blorp/build/VERSION", "0.0.1\n")
		self.write(
			"blorp/src/compiler/stage_01_generated_inputs/compiler_build_info.brp",
			(
				'VERSION: String = "0.0.1"\n'
				'VERSION_DESCRIPTION: String = "blorp 0.0.1\\ncommit: unknown\\ntarget: unknown\\nchannel: local\\ndirty: unknown\\nstd: embedded, hash " + embedded_std_digest\n'
			),
		)
		self.write("blorp/src/lib/runtime/native/minicoro.h", "mini\n")
		self.write("blorp/src/lib/runtime/native/runtime.c", "runtime\n")
		self.write("blorp/src/lib/runtime/native/runtime_decl.c", "decl\n")
		self.write("blorp/src/lib/runtime/native/runtime_extra.h", "extra\n")
		self.write("blorp/src/lsp/server/native_runtime.c", "lsp\n")
		self.write("blorp/tool/generate_build_sources.brp", "tool\n")
		self.write("standard_library/src/list.brp", "list\n")
		self.write(
			"Makefile",
			"\n".join(
				[
					"# Generate the compiler C separately so CI reports self-hosting time independently.",
					"generate recipe line",
					"# Prepare every generated C input and the complete native build manifest.",
					"prepare recipe line",
					"# Compile prepared C inputs with the host C toolchain only.",
					"compile recipe line",
					"# Preserve the safe all-in-one build path for local callers.",
					"",
				]
			),
		)
		self.write("blorp/build/_build/blorp-cli/blorp_cli_main.c", "generated c\n")
		self.write("blorp/build/_build/blorp-cli/runtime_sources.c", "runtime sources\n")
		self.runtime_object = self.build / f"runtime-{self.runtime_config_hash()}.o"
		self.runtime_object.write_bytes(b"runtime object\n")
		make_executable(self.build / "blorp", b"build compiler\n")
		make_executable(self.root / "bin/blorp", b"installed compiler\n")
		self.write_fresh_manifests()

	def tearDown(self) -> None:
		self.tempdir.cleanup()

	def write(self, relative: str, content: str) -> None:
		path = self.root / relative
		path.parent.mkdir(parents=True, exist_ok=True)
		path.write_text(content, encoding="utf-8")

	def detect_bootstrap_target(self) -> str:
		if sys.platform == "darwin":
			return "aarch64-apple-darwin"
		return "x86_64-unknown-linux-gnu"

	def recipe_hash(self, start: str, end: str) -> str:
		lines = self.root.joinpath("Makefile").read_text(encoding="utf-8").splitlines(True)
		capturing = False
		selected = []
		for line in lines:
			if line.startswith(start):
				capturing = True
			if capturing:
				selected.append(line)
			if capturing and line.startswith(end):
				break
		return sha256_bytes("".join(selected).encode("utf-8"))

	def runtime_config_hash(self, runtime_opt: str = "-O2") -> str:
		records = [
			f"{runtime_opt}\n",
			"-fwrapv -pipe -w -DMINICORO_IMPL -DBLORP_COMPILER_RUNTIME_SOURCES=1\n",
			f"{sha256_file(self.root / 'blorp/src/lib/runtime/native/minicoro.h')}  blorp/src/lib/runtime/native/minicoro.h\n",
			f"{sha256_file(self.root / 'blorp/src/lib/runtime/native/runtime.c')}  blorp/src/lib/runtime/native/runtime.c\n",
			f"{sha256_file(self.root / 'blorp/src/lib/runtime/native/runtime_decl.c')}  blorp/src/lib/runtime/native/runtime_decl.c\n",
			f"{self.fake_cc}\n",
			"fake cc 1.0\n",
		]
		return sha256_bytes("".join(records).encode("utf-8"))

	def generated_c_input_paths(self) -> list[str]:
		return [
			"blorp/src/main.brp",
			"blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp",
			"blorp/src/compiler/stage_01_generated_inputs/compiler_build_info.brp",
			"standard_library/src/list.brp",
			self.bootstrap_compiler,
			"scripts/blorp-compiler-bootstrap",
			"scripts/blorp-cli-embedded-manifest",
		]

	def build_input_paths(self) -> list[str]:
		return [
			*self.generated_c_input_paths(),
			"blorp/src/lib/runtime/native/minicoro.h",
			"blorp/src/lib/runtime/native/runtime.c",
			"blorp/src/lib/runtime/native/runtime_decl.c",
			"blorp/src/lib/runtime/native/runtime_extra.h",
			"blorp/build/_build/blorp-cli/runtime_sources.c",
			"blorp/src/lsp/server/native_runtime.c",
			"blorp/tool/generate_build_sources.brp",
		]

	def write_fresh_manifests(
		self,
		cli_opt: str = "-O0",
		runtime_opt: str = "-O2",
		split_n: str = "8",
	) -> None:
		c_manifest = input_manifest(self.root, self.generated_c_input_paths())
		(self.build / "generated-c-build-inputs.sha256").write_bytes(c_manifest)
		c_input_hash = hash_lines(
			sha256_bytes(c_manifest),
			self.recipe_hash(
				"# Generate the compiler C separately",
				"# Prepare every generated C input",
			),
		)
		(self.build / "generated-c-inputs.sha256").write_text(
			f"{c_input_hash}\n",
			encoding="utf-8",
		)
		(self.build / "blorp_cli_main.c.sha256").write_text(
			f"{sha256_file(self.build / 'blorp_cli_main.c')}\n",
			encoding="utf-8",
		)

		build_manifest = input_manifest(self.root, self.build_input_paths())
		(self.build / "build-inputs.sha256").write_bytes(build_manifest)
		binary_input_hash = hash_lines(
			sha256_bytes(build_manifest),
			sha256_file(self.build / "blorp_cli_main.c"),
			self.recipe_hash(
				"# Compile prepared C inputs",
				"# Preserve the safe all-in-one build path",
			),
			cli_opt,
			self.runtime_config_hash(runtime_opt),
			sha256_file(self.root / "scripts/split-generated-c"),
			split_n,
		)
		(self.build / "inputs.sha256").write_text(f"{binary_input_hash}\n", encoding="utf-8")
		(self.build / "blorp.sha256").write_text(
			f"{sha256_file(self.build / 'blorp')}\n",
			encoding="utf-8",
		)
		install_inputs = input_manifest(
			self.root,
			[
				"blorp/build/_build/blorp-cli/inputs.sha256",
				"blorp/build/_build/blorp-cli/blorp.sha256",
			],
		)
		(self.build / "install-inputs.sha256").write_bytes(install_inputs)
		(self.build / "embedded-inputs.sha256").write_text(
			f"blorp-sha256 {sha256_file(self.root / 'bin/blorp')}\n"
			+ install_inputs.decode("utf-8"),
			encoding="utf-8",
		)

	def run_status(
		self,
		*args: str,
		extra_env: dict[str, str] | None = None,
		use_bootstrap_override: bool = True,
	) -> subprocess.CompletedProcess[str]:
		env = os.environ.copy()
		# Synthetic build info and manifests use local defaults, even when CI
		# builds the real compiler with release metadata and native flags.
		for name in (*BUILD_METADATA_ENV_VARS, *BUILD_OPTIMIZATION_ENV_VARS):
			env.pop(name, None)
		env.update(
			{
				"PATH": f"{self.root / 'fake-bin'}:{env['PATH']}",
				"PYTHONDONTWRITEBYTECODE": "1",
			}
		)
		if use_bootstrap_override:
			env["BLORP_BOOTSTRAP_COMPILER_BIN"] = str(self.root / "bootstrap-blorp")
		if extra_env:
			env.update(extra_env)
		return subprocess.run(
			[sys.executable, str(STATUS), *args],
			cwd=self.root,
			env=env,
			text=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.PIPE,
			check=False,
		)

	def snapshot_files(self) -> dict[str, str]:
		return {
			str(path.relative_to(self.root)): sha256_file(path)
			for path in self.root.rglob("*")
			if path.is_file()
		}

	def assert_status(self, result: subprocess.CompletedProcess[str], code: int, word: str) -> None:
		self.assertEqual(result.returncode, code, result.stdout + result.stderr)
		self.assertIn(word, result.stdout + result.stderr)

	def test_reports_fresh_for_matching_current_inputs(self) -> None:
		before = self.snapshot_files()

		result = self.run_status()

		self.assert_status(result, 0, "FRESH")
		self.assertEqual(self.snapshot_files(), before)

	def test_inherited_ci_build_environment_does_not_change_fixture_baseline(self) -> None:
		with patch.dict(
			os.environ,
			{
				"BLORP_BUILD_VERSION": "0.0.1-ci",
				"BLORP_BUILD_COMMIT": "ci123",
				"BLORP_BUILD_TARGET": "x86_64-unknown-linux-gnu",
				"BLORP_BUILD_CHANNEL": "preview",
				"BLORP_BUILD_DIRTY": "false",
				"BLORP_CLI_C_OPTIMIZATION": "-O2",
				"BLORP_CLI_RUNTIME_C_OPTIMIZATION": "-O3",
			},
		):
			result = self.run_status()

		self.assert_status(result, 0, "FRESH")

	def test_quiet_uses_exit_codes_without_output(self) -> None:
		self.assert_status(self.run_status("--quiet"), 0, "")
		self.assertEqual(self.run_status("--quiet").stdout, "")

	def test_compiler_source_edit_reports_stale(self) -> None:
		self.write("blorp/src/main.brp", "func main(args: List[String]) -> Int:\n\t1\n")

		result = self.run_status()

		self.assert_status(result, 1, "STALE")
		self.assertIn("blorp/src/main.brp", result.stdout)
		self.assertIn("Next: make", result.stdout)

	def test_untracked_compiler_source_reports_stale(self) -> None:
		self.write("blorp/src/new_input.brp", "func helper() -> Int:\n\t1\n")

		result = self.run_status()

		self.assert_status(result, 1, "STALE")
		self.assertIn("blorp/src/new_input.brp", result.stdout)

	def test_standard_library_and_runtime_edits_report_stale(self) -> None:
		for path in (
			"standard_library/src/list.brp",
			"blorp/src/lib/runtime/native/runtime.c",
		):
			with self.subTest(path=path):
				self.write_fresh_manifests()
				self.write(path, f"changed {path}\n")
				self.assert_status(self.run_status(), 1, "STALE")

	def test_build_version_edit_reports_stale(self) -> None:
		self.write("blorp/build/VERSION", "9.9.9-parent-probe\n")

		result = self.run_status()

		self.assert_status(result, 1, "STALE")
		self.assertIn("compiler_build_info.brp", result.stdout)

	def test_build_info_environment_override_reports_stale(self) -> None:
		for name in BUILD_METADATA_ENV_VARS:
			with self.subTest(name=name):
				result = self.run_status(extra_env={name: "override"})
				self.assert_status(result, 1, "STALE")
				self.assertIn("compiler_build_info.brp", result.stdout)

	def test_malformed_generated_build_info_reports_unknown(self) -> None:
		self.write(
			"blorp/src/compiler/stage_01_generated_inputs/compiler_build_info.brp",
			"generated without version\n",
		)

		result = self.run_status()

		self.assert_status(result, 2, "UNKNOWN")

	def test_bootstrap_and_native_flags_report_stale(self) -> None:
		self.write("bootstrap-blorp", "new bootstrap\n")
		self.assert_status(self.run_status(), 1, "STALE")
		self.write_fresh_manifests()

		result = self.run_status(extra_env={"BLORP_CLI_C_OPTIMIZATION": "-O2"})

		self.assert_status(result, 1, "STALE")
		self.assertIn("BLORP_CLI_C_OPTIMIZATION=-O2", result.stdout)

	def test_split_count_change_reports_stale(self) -> None:
		result = self.run_status(extra_env={"BLORP_CLI_C_SPLIT": "1"})

		self.assert_status(result, 1, "STALE")
		self.assertIn("BLORP_CLI_C_SPLIT=1", result.stdout)

	def test_splitter_script_edit_reports_stale(self) -> None:
		self.write("scripts/split-generated-c", "changed splitter\n")

		result = self.run_status()

		self.assert_status(result, 1, "STALE")

	def test_fresh_reports_split_plan(self) -> None:
		result = self.run_status()

		self.assert_status(result, 0, "FRESH")
		self.assertIn("8-way split", result.stdout)
		self.assertIn("8 per-TU objects", result.stdout)

	def test_fresh_reports_single_tu_escape_hatch(self) -> None:
		self.write_fresh_manifests(split_n="1")

		result = self.run_status(extra_env={"BLORP_CLI_C_SPLIT": "1"})

		self.assert_status(result, 0, "FRESH")
		self.assertIn("single translation unit", result.stdout)

	def test_missing_or_corrupt_provenance_reports_unknown(self) -> None:
		for path in (
			"bin/blorp",
			"blorp/build/_build/blorp-cli/inputs.sha256",
			"blorp/build/_build/blorp-cli/embedded-inputs.sha256",
		):
			with self.subTest(path=path):
				make_executable(self.root / "bin/blorp", b"installed compiler\n")
				self.write_fresh_manifests()
				target = self.root / path
				if target.exists():
					target.unlink()
				result = self.run_status()
				self.assert_status(result, 2, "UNKNOWN")

		self.write_fresh_manifests()
		self.write("blorp/build/_build/blorp-cli/inputs.sha256", "not a digest\n")
		self.assert_status(self.run_status(), 2, "UNKNOWN")

	def test_altered_binary_bytes_report_unknown_not_fresh(self) -> None:
		make_executable(self.root / "bin/blorp", b"altered compiler\n")

		result = self.run_status()

		self.assert_status(result, 2, "UNKNOWN")
		self.assertIn("bin/blorp", result.stdout)

	def test_copied_matching_binary_and_provenance_can_remain_fresh(self) -> None:
		other = self.root / "other-worktree"
		other.mkdir()
		shutil.copy2(self.root / "bin/blorp", other / "blorp")
		shutil.copy2(self.build / "embedded-inputs.sha256", other / "embedded-inputs.sha256")
		shutil.copy2(other / "blorp", self.root / "bin/blorp")
		shutil.copy2(other / "embedded-inputs.sha256", self.build / "embedded-inputs.sha256")

		self.assert_status(self.run_status(), 0, "FRESH")

	def test_configured_bootstrap_pin_ignores_other_cached_releases(self) -> None:
		cache_root = self.root / "bootstrap-cache"
		pinned_dir = (
			cache_root
			/ "dev-aaaaaaaaaaaa"
			/ "direct"
			/ self.bootstrap_target
			/ self.bootstrap_artifact_sha
		)
		other_dir = cache_root / "dev-bbbbbbbbbbbb/direct" / self.bootstrap_target / ("b" * 64)
		for directory, content in (
			(pinned_dir, b"pinned cached compiler\n"),
			(other_dir, b"other cached compiler\n"),
		):
			directory.mkdir(parents=True)
			make_executable(directory / "blorp", content)
			(directory / "MANIFEST").write_text(
				"\n".join(
					[
						"repo=example/blorp",
						"tag=" + directory.parts[-4],
						"version=0.0.0-dev." + directory.parts[-4].removeprefix("dev-"),
						"layout=direct",
						"target=" + self.bootstrap_target,
						"artifact_sha256=" + directory.name,
						"file_sha256_blorp=" + sha256_file(directory / "blorp"),
						"",
					]
				),
				encoding="utf-8",
			)
		self.bootstrap_compiler = str((pinned_dir / "blorp").resolve())
		self.write_fresh_manifests()

		result = self.run_status(
			extra_env={"BLORP_COMPILER_BOOTSTRAP_CACHE_DIR": str(cache_root)},
			use_bootstrap_override=False,
		)

		self.assert_status(result, 0, "FRESH")

	def test_bootstrap_manifest_drift_reports_unknown_even_off_host(self) -> None:
		self.write(
			"blorp/build/bootstrap.env",
			"\n".join(
				[
					"BLORP_BOOTSTRAP_REPO=example/blorp",
					"BLORP_BOOTSTRAP_TAG=dev-aaaaaaaaaaaa",
					"BLORP_BOOTSTRAP_VERSION=0.0.0-dev.aaaaaaaaaaaa",
					"BLORP_BOOTSTRAP_LAYOUT=direct",
					"BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN=" + self.bootstrap_artifact_sha,
					"BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=not-a-sha",
					"BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=" + self.bootstrap_artifact_sha,
					"",
				]
			),
		)

		result = self.run_status(
			extra_env={"BLORP_BOOTSTRAP_COMPILER_BIN": ""},
			use_bootstrap_override=False,
		)

		self.assert_status(result, 2, "UNKNOWN")
		self.assertIn("invalid SHA-256", result.stdout)

	def test_bootstrap_tag_version_drift_reports_unknown(self) -> None:
		self.write(
			"blorp/build/bootstrap.env",
			"\n".join(
				[
					"BLORP_BOOTSTRAP_REPO=example/blorp",
					"BLORP_BOOTSTRAP_TAG=latest",
					"BLORP_BOOTSTRAP_VERSION=0.0.0-dev.aaaaaaaaaaaa",
					"BLORP_BOOTSTRAP_LAYOUT=direct",
					"BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN=" + self.bootstrap_artifact_sha,
					"BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=" + self.bootstrap_artifact_sha,
					"BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=" + self.bootstrap_artifact_sha,
					"",
				]
			),
		)

		result = self.run_status(
			extra_env={"BLORP_BOOTSTRAP_COMPILER_BIN": ""},
			use_bootstrap_override=False,
		)

		self.assert_status(result, 2, "UNKNOWN")
		self.assertIn("immutable dev revision", result.stdout)

	def test_unsupported_or_unreadable_inputs_report_unknown(self) -> None:
		result = self.run_status(extra_env={"PATH": "/nonexistent"})

		self.assert_status(result, 2, "UNKNOWN")


if __name__ == "__main__":
	unittest.main()
