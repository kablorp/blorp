#!/usr/bin/env python3
"""Contract tests for scripts/blorp-cli-embedded-manifest."""

from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "blorp-cli-embedded-manifest"


def load_manifest_module():
	loader = importlib.machinery.SourceFileLoader(
		"blorp_cli_embedded_manifest",
		str(SCRIPT),
	)
	spec = importlib.util.spec_from_loader(loader.name, loader)
	if spec is None:
		raise RuntimeError("could not create embedded-manifest module spec")
	module = importlib.util.module_from_spec(spec)
	sys.modules[loader.name] = module
	loader.exec_module(module)
	return module


class BlorpCliEmbeddedManifestTests(unittest.TestCase):
	@classmethod
	def setUpClass(cls) -> None:
		cls.manifest = load_manifest_module()

	def test_input_manifest_hashes_content_in_deterministic_path_order(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			(root / "z.txt").write_bytes(b"last")
			(root / "a.txt").write_bytes(b"first")
			output = root / "inputs.sha256"

			self.manifest.write_input_manifest(
				root,
				output,
				["z.txt", "a.txt", "z.txt"],
			)

			self.assertEqual(
				output.read_text(encoding="utf-8"),
				(
					f"{hashlib.sha256(b'first').hexdigest()}  a.txt\n"
					f"{hashlib.sha256(b'last').hexdigest()}  z.txt\n"
				),
			)

	def test_backdated_content_change_changes_input_manifest(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			source = root / "runtime.c"
			output = root / "inputs.sha256"
			source.write_bytes(b"old runtime")
			self.manifest.write_input_manifest(root, output, ["runtime.c"])
			old_manifest = output.read_bytes()

			source.write_bytes(b"new runtime")
			os.utime(source, (1, 1))
			self.manifest.write_input_manifest(root, output, ["runtime.c"])

			self.assertNotEqual(output.read_bytes(), old_manifest)
			self.assertIn(
				hashlib.sha256(b"new runtime").hexdigest().encode(),
				output.read_bytes(),
			)

	def test_input_manifest_rejects_malformed_bytes(self) -> None:
		digest = hashlib.sha256(b"content").hexdigest()
		invalid_manifests = {
			"empty": b"",
			"missing final newline": f"{digest}  source.brp".encode(),
			"truncated digest": f"{digest[:-1]}  source.brp\n".encode(),
			"nonhex digest": f"{'g' * 64}  source.brp\n".encode(),
			"missing separator": f"{digest} source.brp\n".encode(),
			"empty path": f"{digest}  \n".encode(),
			"duplicate path": (
				f"{digest}  source.brp\n{digest}  source.brp\n"
			).encode(),
			"unsorted paths": (
				f"{digest}  z.brp\n{digest}  a.brp\n"
			).encode(),
			"unexpected header": f"blorp-sha256 {digest}\n".encode(),
			"invalid utf8": b"\xff\n",
		}

		for name, data in invalid_manifests.items():
			with self.subTest(case=name):
				self.assertFalse(self.manifest.valid_input_manifest(data))

	def test_installed_manifest_binds_compiler_and_exact_input_manifest(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			compiler = root / "blorp"
			inputs = root / "inputs.sha256"
			installed = root / "embedded-inputs.sha256"
			compiler.write_bytes(b"signed compiler")
			inputs.write_text(
				f"{hashlib.sha256(b'runtime').hexdigest()}  runtime.c\n",
				encoding="utf-8",
			)

			self.manifest.write_installed_manifest(compiler, inputs, installed)

			self.assertTrue(
				self.manifest.installed_manifest_is_current(
					compiler,
					inputs,
					installed,
				),
			)
			compiler.write_bytes(b"corrupt compiler")
			self.assertFalse(
				self.manifest.installed_manifest_is_current(
					compiler,
					inputs,
					installed,
				),
			)

	def test_rewrite_repairs_corrupt_or_incomplete_installed_manifest(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			compiler = root / "blorp"
			inputs = root / "inputs.sha256"
			installed = root / "embedded-inputs.sha256"
			compiler.write_bytes(b"compiler")
			inputs.write_text(
				f"{hashlib.sha256(b'runtime').hexdigest()}  runtime.c\n",
				encoding="utf-8",
			)
			installed.write_text(
				"blorp-sha256 " + hashlib.sha256(b"compiler").hexdigest() + "\n",
				encoding="utf-8",
			)

			self.assertFalse(
				self.manifest.installed_manifest_is_current(
					compiler,
					inputs,
					installed,
				),
			)
			self.manifest.write_installed_manifest(compiler, inputs, installed)
			self.assertTrue(
				self.manifest.installed_manifest_is_current(
					compiler,
					inputs,
					installed,
				),
			)

	def test_installed_manifest_rejects_malformed_compiler_header(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			compiler = root / "blorp"
			inputs = root / "inputs.sha256"
			installed = root / "embedded-inputs.sha256"
			compiler.write_bytes(b"compiler")
			digest = hashlib.sha256(b"runtime").hexdigest()
			inputs.write_text(f"{digest}  runtime.c\n", encoding="utf-8")
			compiler_digest = hashlib.sha256(b"compiler").hexdigest()
			malformed_headers = (
				f"blorp-sha256 {compiler_digest[:-1]}\n",
				f"blorp-sha256 {'g' * 64}\n",
				f"blorp-sha512 {compiler_digest}\n",
				f"{compiler_digest}\n",
			)

			for header in malformed_headers:
				with self.subTest(header=header):
					installed.write_text(
						header + inputs.read_text(encoding="utf-8"),
						encoding="utf-8",
					)
					self.assertFalse(
						self.manifest.installed_manifest_is_current(
							compiler,
							inputs,
							installed,
						),
					)

	def test_cli_rejects_missing_input_before_replacing_output(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			output = root / "inputs.sha256"
			output.write_text("preserved\n", encoding="utf-8")

			result = subprocess.run(
				[
					sys.executable,
					str(SCRIPT),
					"write-inputs",
					"--root",
					str(root),
					"--output",
					str(output),
				],
				input="missing.c\n",
				text=True,
				stdout=subprocess.PIPE,
				stderr=subprocess.PIPE,
				check=False,
			)

			self.assertNotEqual(result.returncode, 0)
			self.assertEqual(output.read_text(encoding="utf-8"), "preserved\n")


if __name__ == "__main__":
	unittest.main()
