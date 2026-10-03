#!/usr/bin/env python3
"""Instrument the frozen R0 stage-2 C for a diagnostic construction census.

Without --binary, this only writes a copy of generated C. With --binary, it
also builds a diagnostic compiler; it never runs a self-compile.
The input hash and every replacement anchor are fixed to the R0 baseline;
regenerate and review this script if any of them change.
"""

from __future__ import annotations

import argparse
from bisect import bisect_right
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess


STAGE2_BODY_C_SHA256 = "8a9c88f126cdca4de62bed45627479434c582b3cd8731e2275c73f516f9813a2"
REPO_ROOT = Path(__file__).resolve().parent.parent

INCLUDE_ANCHOR = '#include "definition_index_ffi.h"\n\n'
CORE_PARAM_SIGNATURE = "brp_tyg7* brp_tyg7_make(brp_tydS* name, brp_tydU* typ, long loc) {\n"
CORE_PARAM_TAG = "blorp_src_compiler_stage_09_core_ir__CoreParam"
PERCEUS_GLOBAL_SIGNATURE = "brp_tyzZ* brp_tyzZ_make(brp_tyg7* f0, int f1) {\n"
PERCEUS_GLOBAL_TAG = "blorp_src_compiler_stage_09_core_perceus_env__PerceusGlobal"
NESTED_SITE = (
    "brp_tyg7* __t11_77 = brp_tyg7_make(__t10_74, __t10_75, __t10_76);\n"
    "  __t10_78 = __t11_77;\n"
    "}\n"
    "int __t10_79 = brp_v_58B->f4;\n"
    "brp_tyzZ* __t11_80 = brp_tyzZ_make(__t10_78, __t10_79);\n"
)

PROBE_DECLARATIONS = r'''/* Diagnostic-only R0 counters: generated-C box calls and selected constructors. */
static unsigned long long r0_generated_box_calls;
static unsigned long long r0_box_site_calls[R0_BOX_SITE_COUNT];
static unsigned long long r0_coreparam_make;
static unsigned long long r0_perceusglobal_make;
static unsigned long long r0_nested_coreparam_site;

static inline void* r0_probe_box_struct(unsigned int site, void* data, size_t size) {
  __atomic_fetch_add(&r0_generated_box_calls, 1ULL, __ATOMIC_RELAXED);
  __atomic_fetch_add(&r0_box_site_calls[site], 1ULL, __ATOMIC_RELAXED);
  return blorp_box_struct(data, size);
}

__attribute__((destructor)) static void r0_print_census(void) {
  fprintf(stderr,
      "BLORP_R0_CENSUS generated_box_calls=%llu coreparam_make=%llu "
      "perceusglobal_make=%llu nested_coreparam_site=%llu\n",
      __atomic_load_n(&r0_generated_box_calls, __ATOMIC_RELAXED),
      __atomic_load_n(&r0_coreparam_make, __ATOMIC_RELAXED),
      __atomic_load_n(&r0_perceusglobal_make, __ATOMIC_RELAXED),
      __atomic_load_n(&r0_nested_coreparam_site, __ATOMIC_RELAXED));
  for (unsigned int site = 0; site < R0_BOX_SITE_COUNT; ++site) {
    unsigned long long calls = __atomic_load_n(&r0_box_site_calls[site], __ATOMIC_RELAXED);
    if (calls) fprintf(stderr, "BLORP_R0_BOX_SITE id=%u calls=%llu\n", site, calls);
  }
}

'''

BOX_CALL = "blorp_box_struct("
BOX_TYPE = re.compile(r"^blorp_box_struct\(&[A-Za-z_][A-Za-z_0-9]*, sizeof\(([A-Za-z_][A-Za-z_0-9]*)\)\)")
STRUCT_DECL = re.compile(r"^\s*(?:private\s+)?struct\s+([A-Za-z_][A-Za-z_0-9]*)\s*\{", re.MULTILINE)


def code_call_offsets(source: str) -> list[int]:
    """Find actual calls, ignoring C comments, strings, and character literals."""
    offsets: list[int] = []
    index = 0
    state = "code"
    while index < len(source):
        char = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if char == "/" and following == "/":
                state = "line_comment"
                index += 2
                continue
            if char == "/" and following == "*":
                state = "block_comment"
                index += 2
                continue
            if char == '"':
                state = "string"
            elif char == "'":
                state = "character"
            elif source.startswith(BOX_CALL, index) and (
                index == 0 or not (source[index - 1].isalnum() or source[index - 1] == "_")
            ):
                offsets.append(index)
                index += len(BOX_CALL)
                continue
        elif state == "line_comment":
            if char == "\n":
                state = "code"
        elif state == "block_comment":
            if char == "*" and following == "/":
                state = "code"
                index += 2
                continue
        elif state in ("string", "character"):
            if char == "\\":
                index += 2
                continue
            if (state == "string" and char == '"') or (state == "character" and char == "'"):
                state = "code"
        index += 1
    if state not in ("code", "line_comment"):
        raise ValueError(f"unterminated C lexical state: {state}")
    return offsets


def box_site_manifest(source: str) -> list[dict[str, object]]:
    sites: list[dict[str, object]] = []
    line_breaks = [index for index, char in enumerate(source) if char == "\n"]
    for site_id, offset in enumerate(code_call_offsets(source)):
        line_start = source.rfind("\n", 0, offset) + 1
        line_end = source.find("\n", offset)
        line = source[line_start:line_end if line_end >= 0 else len(source)]
        match = BOX_TYPE.match(source[offset:offset + 200])
        c_type = match.group(1) if match else None
        # Destination is proved only by the emitted operation at this site.
        destination = "unknown"
        if "__tup_tuple" in line and (
            "blorp_tuple_new(" in line or "blorp_tuple_set_rc(" in line
        ):
            destination = "tuple_element"
        elif "__list_store" in line and "blorp_list_set_raw(" in line:
            destination = "list_fallback"
        elif "__dict_insert_value" in line:
            destination = "dictionary_value"
        elif "__dict_insert_key" in line:
            destination = "dictionary_key"
        elif "blorp_StackResult" in line and (
            ".data.Ok.field0" in line or ".data.Err.field0" in line
        ):
            destination = "stack_result_payload"
        elif "__cl_ret" in line and "return" in line:
            destination = "closure_result"
        elif "__cl_arg" in line:
            destination = "closure_argument"
        elif "__cl_capture" in line:
            destination = "closure_capture"
        sites.append({
            "id": site_id,
            "offset": offset,
            "line": bisect_right(line_breaks, offset) + 1,
            "c_type": c_type,
            "source_declaration": None,
            "destination": destination,
        })
    return sites


def declared_structs() -> list[str]:
    rows: list[str] = []
    for root in ("blorp/src", "standard_library/src", "pkg"):
        for path in sorted((REPO_ROOT / root).rglob("*.brp")):
            for match in STRUCT_DECL.finditer(path.read_text(encoding="utf-8")):
                rows.append(f"{path.relative_to(REPO_ROOT)}:{match.group(1)}")
    return rows


def replace_once(source: str, anchor: str, replacement: str) -> str:
    count = source.count(anchor)
    if count != 1:
        raise ValueError(f"expected one anchor, found {count}: {anchor[:100]!r}")
    return source.replace(anchor, replacement, 1)


def verify_constructor(source: str, signature: str, tag: str) -> None:
    if source.count(signature) != 1:
        raise ValueError(f"constructor signature is not unique: {signature.strip()}")
    body_start = source.index(signature) + len(signature)
    body_prefix = source[body_start:body_start + 600]
    if body_prefix.count(tag) != 1:
        raise ValueError(f"constructor type tag is missing or ambiguous: {tag}")


def instrument(source: str, sites: list[dict[str, object]]) -> str:
    verify_constructor(source, CORE_PARAM_SIGNATURE, CORE_PARAM_TAG)
    verify_constructor(source, PERCEUS_GLOBAL_SIGNATURE, PERCEUS_GLOBAL_TAG)
    if source.count(NESTED_SITE) != 1:
        raise ValueError("fresh CoreParam-to-PerceusGlobal callsite is not unique")

    if len(sites) != 375:
        raise ValueError(f"expected 375 generated box callsites, found {len(sites)}")
    # Preserve argument evaluation while adding one constant site ID per call.
    parts: list[str] = []
    cursor = 0
    for site in sites:
        offset = int(site["offset"])
        parts.extend((source[cursor:offset], f"r0_probe_box_struct({site['id']}, "))
        cursor = offset + len(BOX_CALL)
    parts.append(source[cursor:])
    source = "".join(parts)
    source = replace_once(
        source,
        INCLUDE_ANCHOR,
        INCLUDE_ANCHOR + f"#define R0_BOX_SITE_COUNT {len(sites)}\n" + PROBE_DECLARATIONS,
    )
    source = replace_once(
        source,
        CORE_PARAM_SIGNATURE,
        CORE_PARAM_SIGNATURE
        + "  __atomic_fetch_add(&r0_coreparam_make, 1ULL, __ATOMIC_RELAXED);\n",
    )
    source = replace_once(
        source,
        PERCEUS_GLOBAL_SIGNATURE,
        PERCEUS_GLOBAL_SIGNATURE
        + "  __atomic_fetch_add(&r0_perceusglobal_make, 1ULL, __ATOMIC_RELAXED);\n",
    )
    source = replace_once(
        source,
        NESTED_SITE,
        "__atomic_fetch_add(&r0_nested_coreparam_site, 1ULL, __ATOMIC_RELAXED);\n"
        + NESTED_SITE,
    )
    return source


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="retained linkable stage-2 body C")
    parser.add_argument("--output", type=Path, required=True, help="new diagnostic C path")
    parser.add_argument("--binary", type=Path, help="build a diagnostic binary after preparing C")
    parser.add_argument("--manifest", type=Path, help="write the static site/declaration map as JSON")
    args = parser.parse_args()

    input_path = args.input.resolve()
    output_path = args.output.resolve()
    if input_path == output_path or output_path.exists():
        parser.error("output must be a new path distinct from input")
    binary_path = args.binary.resolve() if args.binary else None
    manifest_path = args.manifest.resolve() if args.manifest else None
    if manifest_path and manifest_path in (input_path, output_path, binary_path):
        parser.error("manifest must be distinct from input, output, and binary")
    if manifest_path and manifest_path.exists():
        parser.error("manifest must be a new path")
    if binary_path and (binary_path.exists() or binary_path == REPO_ROOT / "bin/blorp"):
        parser.error("binary must be a new path and must not replace bin/blorp")
    if binary_path and os.environ.get("BLORP_CLI_C_OPTIMIZATION") != "-O2":
        parser.error("set BLORP_CLI_C_OPTIMIZATION=-O2 before building")

    raw = input_path.read_bytes()
    actual_sha = hashlib.sha256(raw).hexdigest()
    if actual_sha != STAGE2_BODY_C_SHA256:
        parser.error(f"stage-2 body C SHA-256 mismatch: {actual_sha}")
    source = raw.decode("utf-8")
    sites = box_site_manifest(source)
    output = instrument(source, sites)
    output_path.write_text(output, encoding="utf-8")
    print(f"wrote {output_path} ({hashlib.sha256(output.encode()).hexdigest()})")
    if manifest_path:
        manifest = {
            "stage2_body_sha256": STAGE2_BODY_C_SHA256,
            "site_count": len(sites),
            "sites": [{key: value for key, value in site.items() if key != "offset"} for site in sites],
            "declared_structs": [
                {"declaration": declaration, "c_type": None, "dynamic_constructions": None,
                 "dynamic_box_calls": None, "mapping": "unattributed"}
                for declaration in declared_structs()
            ],
        }
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {manifest_path} ({len(sites)} box sites, {len(manifest['declared_structs'])} declarations)")

    if binary_path:
        # Reuse the stage-2 builder's Makefile-derived compile/link commands.
        # The frozen generated C is already prepared, so do not call its
        # build() entrypoint: that would regenerate and overwrite this probe.
        helper = runpy.run_path(str(REPO_ROOT / "benchmarks/build_stage2_compiler"))
        helper["check_bin_blorp_fresh"]()
        recipe = helper["make_recipe"]("compile-prepared-blorp-cli", 0)
        object_path = output_path.with_suffix(".o")
        if object_path.exists():
            parser.error(f"diagnostic object path already exists: {object_path}")
        compile_command = helper["extract_compile_command"](recipe, output_path, object_path)
        link_command = helper["extract_link_command"](recipe, object_path, binary_path)
        subprocess.run(compile_command, cwd=REPO_ROOT, check=True)
        subprocess.run(link_command, cwd=REPO_ROOT, check=True)
        helper["verify_binary_mode"](binary_path, 0)
        print(f"built {binary_path} ({hashlib.sha256(binary_path.read_bytes()).hexdigest()})")


if __name__ == "__main__":
    main()
