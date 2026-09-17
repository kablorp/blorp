#!/usr/bin/env python3
"""Run -fsyntax-only over a list of C files in parallel; print PASS/FAIL summary."""
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = sys.argv[1]
FILES = sys.argv[2:]

FLAGS = [
    "cc", "-O0", "-fwrapv", "-pipe", "-w",
    "-DBLORP_COMPILER_RUNTIME_SOURCES=1",
    "-include", "blorp/src/lib/runtime/native/runtime_decl.c",
    "-Iblorp/src/compiler/stage_01_generated_inputs",
    "-Iblorp/src/compiler/stage_04_modules",
    "-Iblorp/src/compiler/stage_06_typecheck/graph",
    "-Iblorp/src/compiler/stage_06_typecheck/type_system",
    "-Iblorp/src", "-Iblorp/src/lib", "-Iblorp/src/lsp/server", "-Iblorp/src/test",
    "-fsyntax-only",
]


def check(f):
    r = subprocess.run(FLAGS + [f], cwd=ROOT, capture_output=True, text=True)
    return f, r.returncode, r.stdout + r.stderr


ok = True
with ThreadPoolExecutor(max_workers=10) as ex:
    for f, rc, out in ex.map(check, FILES):
        if rc != 0:
            ok = False
            print(f"FAIL {f}")
            print("\n".join("    " + l for l in out.splitlines()[:15]))
        else:
            print(f"OK {f}")

sys.exit(0 if ok else 1)
