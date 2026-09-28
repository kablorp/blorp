"""Select a verified diagnostic compiler for CLI memory tests.

CI supplies a prebuilt pair: its test job must not need bootstrap downloads,
local build manifests, or another compiler build. Local runs without an
explicit pair retain the fresh-checkout check and build a diagnostic sibling.
Only the selected executable path is written to stdout.
"""

import filecmp
import os
from pathlib import Path
import re
import subprocess
import sys


class SetupError(Exception):
    pass


def checked_run(command, *, environment=None, timeout=30):
    try:
        result = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        raise SetupError(f"Cannot run {command[0]}: {error}") from error
    if result.returncode != 0:
        raise SetupError(f"{' '.join(map(str, command))} failed (exit {result.returncode}):\n{result.stdout}{result.stderr}")
    return result.stdout


def compiler_version(binary, mode):
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise SetupError(f"Compiler is not executable: {binary}")
    lines = checked_run([str(binary), "--version"]).strip().splitlines()
    if not lines or not lines[0].startswith("blorp "):
        raise SetupError(f"Missing compiler version from {binary}")
    fields = {"version": lines[0]}
    for line in lines[1:]:
        if not line.strip():
            continue
        name, separator, value = line.partition(": ")
        if not separator or name in fields:
            raise SetupError(f"Malformed or duplicate compiler version field from {binary}: {line}")
        fields[name] = value
    for name in ("commit", "target", "channel", "dirty", "compiled_by", "optimization", "split", "cc", "memory_diagnostics"):
        if not fields.get(name) or fields[name] == "unknown":
            raise SetupError(f"Missing {name} provenance from {binary}")
    if fields["memory_diagnostics"] != str(mode):
        raise SetupError(f"Expected memory_diagnostics: {mode} from {binary}")
    return fields


def prepare(normal, supplied):
    normal_version = compiler_version(normal, 0)
    if supplied is not None:
        # Do not fall back to a build if an explicitly supplied artifact is bad.
        if not supplied:
            raise SetupError("BLORP_DIAGNOSTIC_BIN must name an executable")
        diagnostic = Path(supplied).resolve()
    else:
        installed = Path("bin/blorp")
        if not installed.is_file() or not filecmp.cmp(normal, installed, shallow=False):
            raise SetupError("Local memory tests require checkout bin/blorp; supply BLORP_DIAGNOSTIC_BIN for a prebuilt pair")
        checked_run(["scripts/compiler-build-status"])
        optimization = re.fullmatch(r"cli=(\S+) runtime=(\S+)", normal_version["optimization"])
        if not optimization or not normal_version["split"].isdigit() or int(normal_version["split"]) < 1:
            raise SetupError("Cannot read compiler optimization/split configuration")
        environment = {
            **os.environ,
            "BLORP_CLI_C_OPTIMIZATION": optimization.group(1),
            "BLORP_CLI_RUNTIME_C_OPTIMIZATION": optimization.group(2),
            "BLORP_CLI_C_SPLIT": normal_version["split"],
        }
        checked_run(["make", "--no-print-directory", "build-blorp-cli-diagnostic"], environment=environment, timeout=600)
        diagnostic = Path("blorp/build/_build/blorp-cli/blorp-diagnostic").resolve()
    diagnostic_version = compiler_version(diagnostic, 1)
    for name, value in normal_version.items():
        if name != "memory_diagnostics" and diagnostic_version.get(name) != value:
            raise SetupError(f"Diagnostic compiler {name} differs from normal compiler")
    if diagnostic_version.keys() != normal_version.keys():
        raise SetupError("Diagnostic compiler version fields differ from normal compiler")
    return diagnostic


def main():
    if len(sys.argv) != 2:
        print("usage: prepare_memory_compiler.py NORMAL_COMPILER", file=sys.stderr)
        return 2
    try:
        print(prepare(Path(sys.argv[1]).resolve(), os.environ.get("BLORP_DIAGNOSTIC_BIN")))
    except SetupError as error:
        print(f"Compiler memory test setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
