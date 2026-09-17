#!/usr/bin/env python3
"""Completeness guard for the DirectRuntimeCall cancellation-point registry.

`stage_10_backend/cancellation_plan.brp` classifies a `DirectRuntimeCall` as
"cannot cancel the current task" unless its C symbol appears in
`RUNTIME_CALL_CANCELLATION_POINT_SYMBOLS`. That symbol is exactly what
`emit_direct_runtime_call` writes as a bare C function call, so the only way
this is sound is if the registry is a superset of every runtime.c symbol that
can transitively reach a cancellation sink: a park, a yield, the cooperative
checkpoint slow path, or a cancellation cleanup-frame slow path.

This test recomputes that reachable set directly from
`blorp/src/lib/runtime/native/runtime.c` (a conservative, comment/string-aware
textual parse of its function definitions and call sites, including indirect
calls through the runtime's function-pointer struct fields such as
`blorp_Stream.pull`, and functions defined only by expanding an X-macro such
as `BLORP_DEFINE_CHANNEL_STACK_OPTION` -- e.g. `blorp_channel_recv_int` exists
nowhere as literal text in runtime.c, only as one `##`-pasted instantiation of
that macro, and it reaches `blorp_channel_recv_raw`, a real cancellation
point) and asserts it is a subset of the registry list embedded in
`cancellation_plan.brp`. It also asserts every registry entry actually names
a function `runtime.c` defines (directly or via macro expansion), so the
registry cannot silently rot into a list of typos.

Run with `--dump` to print the freshly computed reachable set as a sorted
Blorp string-list literal, for pasting back into
`RUNTIME_CALL_CANCELLATION_POINT_SYMBOLS` after a runtime change adds or
removes a cancellation point.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RUNTIME_C = ROOT / "blorp" / "src" / "lib" / "runtime" / "native" / "runtime.c"
CANCELLATION_PLAN = (
    ROOT / "blorp" / "src" / "compiler" / "stage_10_backend" / "cancellation_plan.brp"
)

# Sink functions: anything that can leave the current C frame through longjmp
# on cancellation, or that runs the cleanup-frame slow path. `mco_yield` is an
# external minicoro symbol, never defined in runtime.c, so it is matched as a
# call site rather than a function definition.
SINK_NAMES = {
    "__blorp_cancel_current_task_if_requested",
    "blorp_yield_now",
    "mco_yield",
    "blorp_cooperative_checkpoint_slow",
    "__blorp_task_cleanup_push_slow",
    "__blorp_task_cleanup_push_task_slow",
    "__blorp_task_cleanup_duplicate_slot_slow",
    "__blorp_task_cleanup_pop_slot_slow",
    "__blorp_task_cleanup_scope_exit_slow",
}

MACRO_LIKE = re.compile(r"^[A-Z][A-Z0-9_]*$")
IDENT_CALL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
FIELD_CALL_RE = re.compile(r"(?:->|\.)\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(")
FIELD_ASSIGN_RE = re.compile(
    r"\.?\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*[,;)]"
)
DESIGNATED_INIT_RE = re.compile(
    r"\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*[,}]"
)


def strip_comments_and_strings(source: str) -> str:
    """Blank out comments, string literals, and char literals, preserving
    every other byte's offset (so brace/paren matching stays valid)."""
    out = []
    i = 0
    n = len(source)
    while i < n:
        c = source[i]
        if c == "/" and i + 1 < n and source[i + 1] == "/":
            j = source.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif c == "/" and i + 1 < n and source[i + 1] == "*":
            j = source.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append(" " * (j - i))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
        elif c == "'":
            j = i + 1
            while j < n and source[j] != "'":
                j += 2 if source[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


FUNCTION_MACRO_DEFINE_RE = re.compile(
    r"^[ \t]*#define[ \t]+([A-Za-z_][A-Za-z0-9_]*)\(([^)]*)\)[ \t]*(.*)$"
)
TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _join_backslash_continuations(text: str) -> str:
    return text.replace("\\\n", " ")


def _find_macro_definitions(text_with_continuations_joined: str) -> dict[str, tuple[list[str], str]]:
    """Return {macro_name: (param_names, body_text)} for every function-like
    `#define` in the file (line continuations already joined)."""
    macros: dict[str, tuple[list[str], str]] = {}
    for line in text_with_continuations_joined.split("\n"):
        m = FUNCTION_MACRO_DEFINE_RE.match(line)
        if not m:
            continue
        name, params_src, body = m.group(1), m.group(2), m.group(3)
        params = [p.strip() for p in params_src.split(",") if p.strip()]
        macros[name] = (params, body)
    return macros


def _expand_macro_invocations(clean: str, macros: dict[str, tuple[list[str], str]]) -> str:
    """Find every top-level call-shaped invocation of a function-like macro
    and substitute its arguments into the macro body (handling `##` token
    pasting the way the C preprocessor would), returning the concatenation of
    every expansion. This is what lets the reachability scan see functions
    like `blorp_channel_recv_int`, which exist only as one instantiation of
    `BLORP_DEFINE_CHANNEL_STACK_OPTION` and never as literal text."""
    expansions: list[str] = []
    for name, (params, body) in macros.items():
        for m in re.finditer(r"\b" + re.escape(name) + r"\s*\(", clean):
            # Skip the `#define NAME(...)` line itself -- it matches the same
            # call-shaped pattern, with the parameter names as "arguments",
            # which would substitute each parameter for itself as a no-op.
            line_start = clean.rfind("\n", 0, m.start()) + 1
            if clean[line_start:m.start()].lstrip().startswith("#define"):
                continue
            # Balanced-paren argument extraction starting after the macro name.
            start = m.end()
            depth = 1
            i = start
            n = len(clean)
            while i < n and depth > 0:
                if clean[i] == "(":
                    depth += 1
                elif clean[i] == ")":
                    depth -= 1
                i += 1
            if depth != 0:
                continue
            args_src = clean[start : i - 1]
            args = _split_top_level_commas(args_src)
            if len(args) != len(params):
                continue
            expanded = body
            for param, arg in zip(params, args):
                expanded = re.sub(
                    r"(?<![A-Za-z0-9_])" + re.escape(param) + r"(?![A-Za-z0-9_])",
                    arg.strip(),
                    expanded,
                )
            expanded = re.sub(r"\s*##\s*", "", expanded)
            expansions.append(expanded)
    return "\n".join(expansions)


def _split_top_level_commas(args_src: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    current = []
    for ch in args_src:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
    if current or parts:
        parts.append("".join(current))
    return parts


def expand_x_macros(clean: str) -> str:
    """Return extra source text: every instantiation of every function-like
    `#define` in `clean`, textually expanded, concatenated together. Appending
    this to `clean` before scanning for function definitions and call graph
    edges lets macro-generated runtime functions (channel/stream per-type
    variants, etc.) participate in reachability like any other function."""
    joined = _join_backslash_continuations(clean)
    macros = _find_macro_definitions(joined)
    return _expand_macro_invocations(joined, macros)


def find_function_definitions(clean: str) -> dict[str, tuple[int, int]]:
    """Return {function_name: (body_start, body_end)} for every top-level
    brace-delimited definition whose header looks like `name(...) {`. Struct,
    enum, and macro-defined bodies are excluded (macro names are ALL_CAPS by
    this codebase's convention, and typedef'd blocks contain 'typedef')."""
    funcs: dict[str, tuple[int, int]] = {}
    n = len(clean)
    idx = 0
    depth = 0
    while idx < n:
        ch = clean[idx]
        if ch == "{":
            if depth == 0:
                semi = clean.rfind(";", 0, idx)
                brace = clean.rfind("}", 0, idx)
                start = max(semi, brace) + 1
                header = clean[start:idx]
                m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{}]*\)\s*$", header, re.S)
                if m and "typedef" not in header and not MACRO_LIKE.match(m.group(1)):
                    name = m.group(1)
                    depth_inner = 1
                    j = idx + 1
                    while j < n and depth_inner > 0:
                        if clean[j] == "{":
                            depth_inner += 1
                        elif clean[j] == "}":
                            depth_inner -= 1
                        j += 1
                    funcs[name] = (idx + 1, j - 1)
                    idx = j
                    depth = 0
                    continue
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        idx += 1
    return funcs


def compute_reachable_set(clean: str, funcs: dict[str, tuple[int, int]]) -> set[str]:
    all_names = set(funcs.keys())

    direct_calls = {
        name: set(m.group(1) for m in IDENT_CALL_RE.finditer(clean[s:e]))
        for name, (s, e) in funcs.items()
    }

    # Indirect calls: `x->field(...)` or `x.field(...)`. Any function that is
    # ever assigned to `field` anywhere in the file is a possible target of
    # every call through that field, conservatively (the field's static type
    # is not tracked, so this over-approximates rather than under-approximates).
    call_fields = set(m.group(1) for m in FIELD_CALL_RE.finditer(clean))
    field_targets: dict[str, set[str]] = {f: set() for f in call_fields}
    for pattern in (FIELD_ASSIGN_RE, DESIGNATED_INIT_RE):
        for m in pattern.finditer(clean):
            field, value = m.group(1), m.group(2)
            if field in field_targets and value in all_names:
                field_targets[field].add(value)

    indirect_calls = {}
    for name, (s, e) in funcs.items():
        body = clean[s:e]
        targets: set[str] = set()
        for m in FIELD_CALL_RE.finditer(body):
            targets |= field_targets.get(m.group(1), set())
        indirect_calls[name] = targets

    combined = {
        name: direct_calls.get(name, set()) | indirect_calls.get(name, set())
        for name in all_names
    }

    # Seed: functions that directly name-call a sink, whether or not the sink
    # itself is a local definition (mco_yield is external).
    reach: set[str] = set()
    for name, (s, e) in funcs.items():
        called = set(m.group(1) for m in IDENT_CALL_RE.finditer(clean[s:e]))
        if called & SINK_NAMES:
            reach.add(name)

    changed = True
    while changed:
        changed = False
        for name, callees in combined.items():
            if name in reach:
                continue
            if callees & reach:
                reach.add(name)
                changed = True

    return reach


def load_registry(cancellation_plan_src: str) -> list[str]:
    m = re.search(
        r"RUNTIME_CALL_CANCELLATION_POINT_SYMBOLS:\s*List\[String\]\s*=\s*\[(.*?)\]",
        cancellation_plan_src,
        re.S,
    )
    if not m:
        raise AssertionError(
            "could not find RUNTIME_CALL_CANCELLATION_POINT_SYMBOLS in cancellation_plan.brp"
        )
    return re.findall(r'"([^"]+)"', m.group(1))


def build_augmented_source(runtime_src: str) -> str:
    """The comment/string-stripped runtime.c text, with every X-macro
    instantiation's expansion appended, so macro-generated functions are
    visible to `find_function_definitions` and the call-graph scan."""
    clean = strip_comments_and_strings(runtime_src)
    return clean + "\n" + expand_x_macros(clean)


class RuntimeCancellationRegistryCompletenessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime_src = RUNTIME_C.read_text()
        self.clean = build_augmented_source(self.runtime_src)
        self.funcs = find_function_definitions(self.clean)
        self.reach = compute_reachable_set(self.clean, self.funcs)
        self.registry = load_registry(CANCELLATION_PLAN.read_text())

    def test_runtime_has_expected_sink_definitions(self) -> None:
        # Every sink except the external `mco_yield` must be a real runtime.c
        # definition, or the reachability computation below is vacuous.
        defined_sinks = SINK_NAMES & set(self.funcs.keys())
        self.assertEqual(
            defined_sinks,
            SINK_NAMES - {"mco_yield"},
            "a cancellation sink function was renamed or removed in runtime.c; "
            "update SINK_NAMES in this test and re-derive the registry",
        )

    def test_reachable_set_is_nonempty_and_bounded(self) -> None:
        # A sanity bound, not a contract: catches the parser silently matching
        # nothing (reach == {sinks only}) or something pathological (matching
        # nearly the whole file because a regex went wrong).
        self.assertGreater(len(self.reach), 20)
        self.assertLess(len(self.reach), len(self.funcs) // 2)

    def test_registry_entries_are_defined_runtime_symbols(self) -> None:
        undefined = sorted(set(self.registry) - set(self.funcs.keys()))
        self.assertEqual(
            undefined,
            [],
            "RUNTIME_CALL_CANCELLATION_POINT_SYMBOLS names symbols runtime.c "
            "does not define (typo, or the function was renamed/removed): "
            f"{undefined}",
        )

    def test_registry_covers_every_reachable_cancellation_point(self) -> None:
        missing = sorted(self.reach - set(self.registry))
        self.assertEqual(
            missing,
            [],
            "runtime.c functions that can now reach a cancellation sink but are "
            "not in RUNTIME_CALL_CANCELLATION_POINT_SYMBOLS (cancellation_plan.brp): "
            f"{missing}. A DirectRuntimeCall to one of these would be wrongly "
            "elided as non-cancelling. Add them to the registry.",
        )

    def test_registry_has_no_duplicate_entries(self) -> None:
        self.assertEqual(len(self.registry), len(set(self.registry)))


def main() -> int:
    if "--dump" in sys.argv:
        runtime_src = RUNTIME_C.read_text()
        clean = build_augmented_source(runtime_src)
        funcs = find_function_definitions(clean)
        reach = compute_reachable_set(clean, funcs)
        for name in sorted(reach):
            print(f'\t"{name}",')
        return 0
    unittest.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
