#!/usr/bin/env python3
"""Split a single generated Blorp CLI C file into N translation units.

This is a measurement-study tool: it does NOT touch the Blorp emitter. It
post-processes the C file that `blorp compile --no-embed-runtime` already
produced (see blorp/src/compiler/stage_10_backend/), turning it into:

  - one shared header (<out>/split_shared.h): every #include/#define/typedef
    line from the original file, verbatim and in original order, plus extern
    declarations for every top-level global and a prototype for every
    function definition.
  - N body translation units (<out>/split_body_0.c .. split_body_{N-1}.c):
    each #includes the shared header, then contains a contiguous, order-
    preserving, size-balanced subset of the original function definitions.
    All top-level *data* globals (string literals, closures, canonical
    record/list/union singleton constants, ...) are defined exactly once,
    all in split_body_0.c, to keep the ownership bookkeeping simple; every
    other TU sees them only via `extern` from the header.

Every function loses `static` (and `inline`, when present) because the
generator already guarantees function symbols are globally unique
(`brp_<base62>`), so promoting them to external linkage is safe. Every
non-function global also loses `static`; it is defined once (in TU 0) and
`extern`-declared everywhere else. String literal globals
(`BLORP_STATIC_STRING(...)`) are especially load-bearing: Blorp treats
immortal literals as pointer-identical objects (`same_object`), so the
splitter must never duplicate their storage across translation units --- it
keeps exactly one definition and only ever emits `extern` references
elsewhere. A handful of globals (currently: canonical empty/static list
singletons) are declared with an anonymous `struct { ... }` type; since
anonymous struct types are not compatible across translation units in C, the
splitter synthesizes a named typedef for each one and uses that typedef on
both sides (the header's `extern` and the owning TU's definition).

The parser is a small brace/string/comment-aware scanner (see
`iter_top_level_units`), not a full C parser; it relies on structural
regularities of Blorp's C backend (documented in AGENTS.md / this file) that
were verified against the real generated output on 2026-09-17: all functions
are `static`, there are no bare (non-typedef'd) struct/union/enum body
definitions, no `#undef`, no duplicate macro names, and all preprocessor
directives start at column 0.

Usage:
    benchmarks/split_generated_c.py <generated.c> <out_dir> -n N [-n N ...]

For each requested N this writes <out_dir>/N<split-name>/ containing
split_shared.h and split_body_0.c .. split_body_{N-1}.c.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Tokenizer / top-level unit scanner
# ---------------------------------------------------------------------------

@dataclass
class Unit:
    kind: str  # 'directive' | 'typedef' | 'function' | 'global' | 'string_literal' | 'prototype'
    start: int
    end: int
    text: str = ""  # populated by caller (slice of source)


def iter_top_level_units(text: str):
    """Yield (kind_hint, start, end) for every top-level construct.

    kind_hint is 'directive' for #include/#define/#undef/... spans, or
    'unit' for everything else (typedefs, prototypes, function defs, global
    var defs) -- finer classification happens in classify_unit().
    """
    n = len(text)
    i = 0
    unit_start = None
    depth = 0
    func_body_flag = False
    entered_brace = False

    while i < n:
        c = text[i]

        # Comments are skipped unconditionally, even before a unit starts,
        # so a leading comment never gets glued onto the next real unit.
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            i = end + 2 if end != -1 else n
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            end = text.find("\n", i + 1)
            i = end + 1 if end != -1 else n
            continue

        if unit_start is None:
            if c in " \t\r\n":
                i += 1
                continue
            if c == "#" and (i == 0 or text[i - 1] == "\n"):
                j = i
                while True:
                    nl = text.find("\n", j)
                    if nl == -1:
                        j = n
                        break
                    if text[nl - 1] == "\\":
                        j = nl + 1
                        continue
                    j = nl + 1
                    break
                yield ("directive", i, j)
                i = j
                continue
            unit_start = i
            depth = 0
            func_body_flag = False
            entered_brace = False

        if c == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "'":
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == "'":
                    i += 1
                    break
                i += 1
            continue
        if c == "{":
            if depth == 0 and not entered_brace:
                k = i - 1
                while k >= unit_start and text[k] in " \t\r\n":
                    k -= 1
                func_body_flag = k >= unit_start and text[k] == ")"
                entered_brace = True
            depth += 1
            i += 1
            continue
        if c == "}":
            depth -= 1
            i += 1
            if depth == 0 and func_body_flag:
                yield ("unit", unit_start, i)
                unit_start = None
            continue
        if c == ";" and depth == 0:
            i += 1
            yield ("unit", unit_start, i)
            unit_start = None
            continue
        i += 1

    if unit_start is not None:
        raise ValueError(f"unterminated top-level unit starting at offset {unit_start}")


def find_toplevel_char(body: str, ch: str) -> int:
    """Index of the first occurrence of `ch` at brace/string depth 0, or -1."""
    depth = 0
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        if c == '"':
            i += 1
            while i < n:
                if body[i] == "\\":
                    i += 2
                    continue
                if body[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "'":
            i += 1
            while i < n:
                if body[i] == "\\":
                    i += 2
                    continue
                if body[i] == "'":
                    i += 1
                    break
                i += 1
            continue
        if c == "{":
            if depth == 0 and ch == "{":
                return i
            depth += 1
            i += 1
            continue
        if c == "}":
            depth -= 1
            i += 1
            continue
        if depth == 0 and c == ch:
            return i
        i += 1
    return -1


def matching_brace(text: str, open_idx: int) -> int:
    """Given the index of a '{', return the index just past its matching '}'."""
    assert text[open_idx] == "{"
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unterminated brace group")


STATIC_RE = re.compile(r"^\s*static\b\s*")
INLINE_RE = re.compile(r"^\s*inline\b\s*")


def strip_leading_keywords(body: str) -> str:
    """Strip a leading 'static' and/or 'inline' keyword (any order)."""
    changed = True
    while changed:
        changed = False
        m = STATIC_RE.match(body)
        if m:
            body = body[m.end():]
            changed = True
            continue
        m = INLINE_RE.match(body)
        if m:
            body = body[m.end():]
            changed = True
    return body


@dataclass
class ClassifiedUnit:
    kind: str
    raw: str            # original unit text, exactly as it appeared
    name: str = ""       # symbol name, for globals/functions
    # For functions:
    proto: str = ""       # "RETTYPE NAME(ARGS)" with static/inline stripped
    def_text: str = ""    # full definition text with static/inline stripped
    # For string_literal globals:
    len_arg: str = ""
    bytes_arg: str = ""
    # For anonymous-struct-typed globals:
    typedef_name: str = ""
    typedef_text: str = ""
    def_after_typedef: str = ""  # "TYPEDEF NAME = {...};"
    # For plain globals:
    extern_decl: str = ""
    owner_def: str = ""


def classify_unit(kind_hint: str, raw: str) -> ClassifiedUnit:
    if kind_hint == "directive":
        if raw.lstrip().startswith("#define BLORP_STATIC_STRING"):
            return ClassifiedUnit(kind="static_string_macro", raw=raw)
        return ClassifiedUnit(kind="directive", raw=raw)

    body = raw.strip()

    if body.startswith("typedef"):
        return ClassifiedUnit(kind="typedef", raw=raw)

    if body.startswith("BLORP_STATIC_STRING("):
        inner = body[len("BLORP_STATIC_STRING("):]
        name_end = inner.find(",")
        name = inner[:name_end].strip()
        rest = inner[name_end + 1:]
        len_end = rest.find(",")
        len_arg = rest[:len_end].strip()
        bytes_arg = rest[len_end + 1:].rstrip()
        # strip trailing ");" (allow whitespace before it)
        assert bytes_arg.rstrip().endswith(");"), bytes_arg[-10:]
        bytes_arg = bytes_arg.rstrip()[:-2].strip()
        return ClassifiedUnit(
            kind="string_literal", raw=raw, name=name,
            len_arg=len_arg, bytes_arg=bytes_arg,
        )

    # Does this unit contain a top-level brace group at all?
    brace_idx = None
    depth = 0
    i = 0
    nb = len(body)
    while i < nb:
        c = body[i]
        if c == '"':
            i += 1
            while i < nb:
                if body[i] == "\\":
                    i += 2
                    continue
                if body[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "'":
            i += 1
            while i < nb:
                if body[i] == "\\":
                    i += 2
                    continue
                if body[i] == "'":
                    i += 1
                    break
                i += 1
            continue
        if c == "{":
            if depth == 0 and brace_idx is None:
                brace_idx = i
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1

    ends_with_brace = body.rstrip().endswith("}")

    if ends_with_brace:
        # Function definition: top-level unit whose brace group is a
        # function body (iter_top_level_units only stops at '}' for those).
        stripped = strip_leading_keywords(body)
        open_idx = find_toplevel_char(stripped, "{")
        assert open_idx != -1, stripped[:200]
        sig = stripped[:open_idx].strip()
        # function name = identifier immediately before the '(' of the
        # top-level parameter list.
        paren = sig.find("(")
        name = sig[:paren].strip().split()[-1].lstrip("*")
        return ClassifiedUnit(
            kind="function", raw=raw, name=name,
            proto=sig + ";", def_text=stripped,
        )

    # Otherwise: ends with ';' outside of any brace-body -> either a bare
    # prototype (no body braces anywhere) or a global variable definition
    # (has an initializer brace group, or is a bare declaration).
    if brace_idx is None:
        # No braces at all: "TYPE NAME(ARGS);" (prototype, drop+regenerate)
        # or "TYPE NAME;" / "TYPE NAME[N];" (uninitialized global).
        core = body.rstrip()
        assert core.endswith(";")
        core_noscolon = core[:-1].rstrip()
        has_toplevel_eq = find_toplevel_char(body, "=") != -1
        if core_noscolon.endswith(")") and not has_toplevel_eq:
            return ClassifiedUnit(kind="prototype", raw=raw)
        # bare global declaration or initializer with no braces at all
        # (e.g. "static blorp_String* NAME = (blorp_String*)&lit;"); fall
        # through to the shared declarator/initializer split below.
        pass

    # Has at least one top-level brace group ending in ';', or none at all
    # (a scalar/pointer initializer or bare declaration): global variable.
    # with an initializer. Special-case the anonymous-struct-type form.
    stripped = strip_leading_keywords(body)
    if re.match(r"^struct\s*\{", stripped):
        open_idx = stripped.find("{")
        close_idx = matching_brace(stripped, open_idx) - 1  # index of the '}'
        struct_body = stripped[open_idx:close_idx + 1]
        after = stripped[close_idx + 1:]
        eq_idx = find_toplevel_char(after, "=")
        assert eq_idx != -1, after[:120]
        var_name = after[:eq_idx].strip()
        typedef_name = "__blorp_split_ty_" + var_name
        typedef_text = "typedef struct " + struct_body + " " + typedef_name + ";"
        def_after_typedef = typedef_name + " " + after.strip()
        return ClassifiedUnit(
            kind="anon_struct_global", raw=raw, name=var_name,
            typedef_name=typedef_name, typedef_text=typedef_text,
            def_after_typedef=def_after_typedef,
        )

    eq_idx = find_toplevel_char(stripped, "=")
    if eq_idx == -1:
        declarator = stripped.rstrip().rstrip(";").rstrip()
    else:
        declarator = stripped[:eq_idx].strip()
    name = _declarator_name(declarator)
    return ClassifiedUnit(
        kind="global", raw=raw, name=name,
        extern_decl="extern " + declarator + ";",
        owner_def=stripped,
    )


def _declarator_name(declarator: str) -> str:
    # "TYPE NAME" or "TYPE NAME[N]" or "TYPE *NAME" -> NAME
    d = declarator.strip()
    bracket = d.find("[")
    if bracket != -1:
        d = d[:bracket]
    name = d.strip().split()[-1]
    return name.lstrip("*")


# ---------------------------------------------------------------------------
# Splitting driver
# ---------------------------------------------------------------------------

@dataclass
class ParsedSource:
    header_directives: list  # raw text, in original order (directives+typedefs)
    static_string_macro: str
    string_literals: list    # ClassifiedUnit
    anon_struct_globals: list
    plain_globals: list
    functions: list          # ClassifiedUnit, in original order


def parse_source(text: str) -> ParsedSource:
    header_directives = []
    static_string_macro = None
    string_literals = []
    anon_struct_globals = []
    plain_globals = []
    functions = []
    dropped_prototypes = 0

    for kind_hint, start, end in iter_top_level_units(text):
        raw = text[start:end]
        cu = classify_unit(kind_hint, raw)
        if cu.kind == "directive" or cu.kind == "typedef":
            header_directives.append(raw)
        elif cu.kind == "static_string_macro":
            static_string_macro = raw
        elif cu.kind == "string_literal":
            string_literals.append(cu)
        elif cu.kind == "anon_struct_global":
            anon_struct_globals.append(cu)
        elif cu.kind == "global":
            plain_globals.append(cu)
        elif cu.kind == "function":
            functions.append(cu)
        elif cu.kind == "prototype":
            dropped_prototypes += 1
        else:
            raise AssertionError(f"unhandled unit kind {cu.kind!r}")

    if static_string_macro is None:
        raise ValueError("BLORP_STATIC_STRING macro definition not found")

    sys.stderr.write(
        "parse_source: %d header lines, %d string literals, "
        "%d anon-struct globals, %d plain globals, %d functions, "
        "%d prototypes dropped (regenerated)\n"
        % (len(header_directives), len(string_literals), len(anon_struct_globals),
           len(plain_globals), len(functions), dropped_prototypes)
    )
    return ParsedSource(
        header_directives=header_directives,
        static_string_macro=static_string_macro,
        string_literals=string_literals,
        anon_struct_globals=anon_struct_globals,
        plain_globals=plain_globals,
        functions=functions,
    )


def derive_extern_string_macro(static_macro_text: str) -> str:
    """Build the BLORP_EXTERN_STRING macro from the *captured*
    BLORP_STATIC_STRING macro definition, rather than a hand-maintained
    copy: rename it and drop exactly the one 'static ' that makes the
    original definition file-local. If the emitter ever changes this macro
    (an extra header field, a different alloc class, ...) this keeps the
    extern twin in sync automatically instead of silently diverging -- a
    stale hand-copied twin would give immortal string literals a wrong
    object header at runtime, not a compile error.
    """
    renamed = static_macro_text.replace(
        "BLORP_STATIC_STRING", "BLORP_EXTERN_STRING", 1
    )
    extern_macro, n = re.subn(r"static ", "", renamed, count=1)
    if n != 1:
        raise ValueError(
            "expected exactly one 'static ' in BLORP_STATIC_STRING's body "
            f"to remove; found {n} in: {renamed!r}"
        )
    if "blorp_String name" not in extern_macro:
        raise ValueError(
            "derived BLORP_EXTERN_STRING macro lost its 'blorp_String name' "
            f"declaration: {extern_macro!r}"
        )
    return extern_macro


def build_header(parsed: ParsedSource) -> str:
    out = []
    out.append("/* Generated by benchmarks/split_generated_c.py -- shared header. */\n")
    out.append("#ifndef BLORP_SPLIT_SHARED_H\n#define BLORP_SPLIT_SHARED_H\n")
    for d in parsed.header_directives:
        out.append(d if d.endswith("\n") else d + "\n")
    out.append("\n" + parsed.static_string_macro + "\n")
    out.append(derive_extern_string_macro(parsed.static_string_macro) + "\n")

    out.append("/* extern decls: string literals */\n")
    for cu in parsed.string_literals:
        out.append(f"extern blorp_String {cu.name};\n")

    out.append("\n/* extern decls: anonymous-struct-typed globals (synthesized typedefs) */\n")
    for cu in parsed.anon_struct_globals:
        out.append(cu.typedef_text + "\n")
        out.append(f"extern {cu.typedef_name} {cu.name};\n")

    out.append("\n/* extern decls: other globals */\n")
    for cu in parsed.plain_globals:
        out.append(cu.extern_decl + "\n")

    out.append("\n/* function prototypes */\n")
    for cu in parsed.functions:
        out.append(cu.proto + "\n")

    out.append("\n#endif /* BLORP_SPLIT_SHARED_H */\n")
    return "".join(out)


def balanced_bins(functions: list, n: int):
    """Partition `functions` (in order) into n contiguous, size-balanced bins."""
    if n <= 1:
        return [functions]
    sizes = [len(cu.def_text) for cu in functions]
    total = sum(sizes)
    target = max(1, total // n)
    bins = []
    cur = []
    cur_size = 0
    for cu, sz in zip(functions, sizes):
        cur.append(cu)
        cur_size += sz
        if len(bins) < n - 1 and cur_size >= target:
            bins.append(cur)
            cur = []
            cur_size = 0
    bins.append(cur)
    while len(bins) < n:
        bins.append([])
    assert len(bins) == n
    assert sum(len(b) for b in bins) == len(functions)
    return bins


def build_body(parsed: ParsedSource, tu_index: int, funcs: list, header_name: str) -> str:
    out = [f'#include "{header_name}"\n\n']
    if tu_index == 0:
        out.append("/* Global definitions (owned by TU 0). */\n")
        for cu in parsed.string_literals:
            out.append(f"BLORP_EXTERN_STRING({cu.name}, {cu.len_arg}, {cu.bytes_arg});\n")
        out.append("\n")
        for cu in parsed.anon_struct_globals:
            out.append(cu.def_after_typedef + "\n")
        out.append("\n")
        for cu in parsed.plain_globals:
            out.append(cu.owner_def + "\n")
        out.append("\n")
    out.append(f"/* {len(funcs)} function definitions. */\n")
    for cu in funcs:
        out.append(cu.def_text + "\n")
    return "".join(out)


def write_split(parsed: ParsedSource, out_dir: str, n: int):
    split_dir = os.path.join(out_dir, f"n{n}")
    os.makedirs(split_dir, exist_ok=True)
    header_name = "split_shared.h"
    header_text = build_header(parsed)
    with open(os.path.join(split_dir, header_name), "w") as f:
        f.write(header_text)

    bins = balanced_bins(parsed.functions, n)
    for idx, funcs in enumerate(bins):
        body_text = build_body(parsed, idx, funcs, header_name)
        with open(os.path.join(split_dir, f"split_body_{idx}.c"), "w") as f:
            f.write(body_text)

    sizes = [sum(len(cu.def_text) for cu in b) for b in bins]
    sys.stderr.write(
        f"n={n}: wrote {split_dir} -- per-TU function-body bytes: {sizes}\n"
    )
    return split_dir


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="path to the generated blorp_cli_main.c")
    ap.add_argument("out_dir", help="directory to write split_n{N}/ subdirectories into")
    ap.add_argument("-n", dest="ns", action="append", type=int, required=True,
                     help="number of TUs to split into (repeatable)")
    args = ap.parse_args()

    with open(args.source, "r", encoding="utf-8") as f:
        text = f.read()

    parsed = parse_source(text)
    os.makedirs(args.out_dir, exist_ok=True)
    for n in args.ns:
        write_split(parsed, args.out_dir, n)


if __name__ == "__main__":
    main()
