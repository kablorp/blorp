#!/usr/bin/env python3
"""Turn the raw files `run` leaves in its output directory into markdown tables.

Usage: report.py STAGE OUTPUT_DIRECTORY [--top N]
  STAGE is one of: copies, rc, allocations, profile, timing.
Each stage reads only files written by the matching stage of `run` (named below),
prints markdown to stdout, and fails if a file is missing or malformed. macOS or Linux
with `atos` or `addr2line` (copies only). Python 3 standard library only.

  copies       copies/prof.tsv, copies/binary, copies/statements.c, self.c
  rc           rc/kinds.tsv, rc/tagged.tsv, rc/categories.tsv, self.c
  allocations  allocations/sites.txt (allocation-sites output, every row)
  profile      profile/sample.txt, self.c
  timing       timing/runs.tsv

Symbolizing and the `module.function` comments reuse blorp_2/scripts/allocation-sites.
Functions are named by their comment, so the monomorphs of one function and
lambdas of one name are merged in every per-function table.
"""
import argparse
import importlib.machinery
import importlib.util
import os
import re
import subprocess
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
# Functions the roadmap names as O1's targets, and `text.concat`, which `emit` calls.
COPY_TARGETS = ("emit.append_owner_alias", "emit.append_selection", "emit.append_selection_body",
                "emit.append_loop", "emit.append_loop_exit", "names.with_bucket_entry", "emit.emit",
                "text.concat")
NAMED_ROWS_PER_FUNCTION = 6


def fail(message):
    sys.exit("error: report: " + message)


def read(path):
    try:
        with open(path) as handle:
            return handle.read()
    except OSError as problem:
        fail("cannot read %s: %s" % (path, problem))


def load_allocation_sites():
    """The allocation-sites script as a module; it has no .py suffix, so load it by path."""
    sys.dont_write_bytecode = True
    path = os.path.join(HERE, "..", "allocation-sites")
    loader = importlib.machinery.SourceFileLoader("allocation_sites", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def function_labels(directory):
    """Map `blorp_f_N` to the `module.function` comment the emitter writes before it."""
    return load_allocation_sites().read_function_comments(os.path.join(directory, "self.c"))


def label_of(labels, function):
    """Function number 0 stands for runtime code with no Blorp caller."""
    return labels.get("blorp_f_%d" % function, "blorp_f_%d" % function) if function else "(runtime, no Blorp caller)"


def table(headers, rows, align=None):
    align = align or ["l"] * len(headers)
    lines = ["| " + " | ".join(headers) + " |",
             "| " + " | ".join("---:" if a == "r" else "---" for a in align) + " |"]
    lines += ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows]
    return "\n".join(lines) + "\n"


def number(value):
    return "{:,}".format(value)


def percent(part, whole):
    return "%.1f%%" % (100.0 * part / whole) if whole else "0.0%"


# ---------------------------------------------------------------- copies

def symbolize(binary, offsets):
    """(function, line) per return-address offset, through allocation-sites' symbolizer command."""
    tool = load_allocation_sites()
    where = {}
    ordered = sorted(offsets)
    for start in range(0, len(ordered), tool.SYMBOLIZER_BATCH):
        batch = ordered[start:start + tool.SYMBOLIZER_BATCH]
        command, per_address = tool.symbolizer_command(binary, batch)
        run = subprocess.run(command, capture_output=True, text=True)
        lines = run.stdout.splitlines()
        if run.returncode != 0 or len(lines) != len(batch) * per_address:
            fail("%s failed (%d): %s" % (command[0], run.returncode, run.stderr.strip()))
        for index, offset in enumerate(batch):
            answer = lines[index * per_address:(index + 1) * per_address]
            located = re.search(r":(\d+)\)?\s*$", answer[-1])
            if not located:
                fail("no line number in symbolizer output: " + answer[-1])
            where[offset] = (tool.function_name(answer), int(located.group(1)))
    return where


def read_copy_rows(directory):
    """(label, kind, line) -> [calls, units], with the fallback copy inside a take_left helper counted once."""
    labels = function_labels(directory)
    rows, load = [], None
    for line in read(os.path.join(directory, "copies", "prof.tsv")).splitlines():
        if line.startswith("#load"):
            load = int(line.split()[1], 16)
        elif line and not line.startswith("#"):
            kind, address, hits, units = line.split()
            rows.append((kind, int(address, 16), int(hits), int(units)))
    if load is None:
        fail("prof.tsv has no #load line")
    where = symbolize(os.path.join(directory, "copies", "binary"), {a - load for _, a, _, _ in rows})
    sites = defaultdict(lambda: [0, 0])
    for kind, address, hits, units in rows:
        function, line = where[address - load]
        # A borrowed helper called from a take_left helper is that helper's shared
        # fallback copy; it is counted there so the two paths stay disjoint.
        if kind.endswith("borrowed") and "take_left" in function:
            continue
        key = (labels.get(function, function), kind, line)
        sites[key][0] += hits
        sites[key][1] += units
    return sites


def copies(directory, top):
    sites = read_copy_rows(directory)
    statements = read(os.path.join(directory, "copies", "statements.c")).split("\n")
    by_path, by_function = defaultdict(lambda: [0, 0]), defaultdict(lambda: [0, 0])
    for (label, kind, _), (hits, units) in sites.items():
        for cells, key in ((by_path, kind), (by_function, (kind, label))):
            cells[key][0] += hits
            cells[key][1] += units
    out = ["### Copies by path\n"]
    names = [("list_borrowed", "List borrowed update", "slots"), ("list_fallback", "List shared fallback", "slots"),
             ("string_borrowed", "String borrowed update", "bytes"), ("string_fallback", "String shared fallback", "bytes")]
    out.append(table(["Path", "Calls", "Copied"],
                     [(label, number(by_path[k][0]), "%s %s" % (number(by_path[k][1]), unit)) for k, label, unit in names],
                     ["l", "r", "r"]))
    out.append(table(["Path", "Calls", "Length the copy would have cost"],
                     [(label, number(by_path[k][0]), number(by_path[k][1]))
                      for k, label in (("list_unique", "List in place"), ("string_unique", "String in place"))],
                     ["l", "r", "r"]))
    out.append("### Copies by function (borrowed update and shared fallback; top %d by units)\n" % top)
    copying = [(k, v) for k, v in by_function.items() if not k[0].endswith("unique")]
    out.append(table(["Path", "Function", "Calls", "Copied"],
                     [(k[0], k[1], number(v[0]), number(v[1])) for k, v in sorted(copying, key=lambda i: -i[1][1])[:top]],
                     ["l", "l", "r", "r"]))
    out.append(named_sites(sites, by_function, statements))
    out.append("### Copy sites (borrowed update and shared fallback; top %d statements by units)\n" % top)
    copying_sites = [(k, v) for k, v in sites.items() if not k[1].endswith("unique")]
    out.append(table(["Path", "Function", "statements.c line", "Calls", "Copied", "Statement"],
                     statement_rows(sorted(copying_sites, key=lambda i: -i[1][1])[:top], statements),
                     ["l", "l", "r", "r", "r", "l"]))
    return "\n".join(out)


def statement_rows(sites, statements):
    rows = []
    for (label, kind, line), (hits, units) in sites:
        statement = statements[line - 1].strip() if 0 < line <= len(statements) else ""
        statement = statement if len(statement) <= 100 else statement[:97] + "..."
        rows.append((kind, label, line, number(hits), number(units), "`%s`" % statement.replace("|", "\\|")))
    return rows


def named_sites(sites, by_function, statements):
    """In-place, fallback and borrowed rows for the functions the roadmap names."""
    out = ["### Named functions: copying paths\n"]
    out.append(table(["Function", "Path", "Calls", "Copied"],
                     [(name, k[0], number(v[0]), number(v[1])) for name in COPY_TARGETS
                      for k, v in sorted(by_function.items()) if k[1] == name and not k[0].endswith("unique")],
                     ["l", "l", "r", "r"]))
    chosen = []
    for name in COPY_TARGETS:
        mine = [(k, v) for k, v in sites.items() if k[0] == name]
        chosen += sorted(mine, key=lambda i: -i[1][1])[:NAMED_ROWS_PER_FUNCTION]
    out.append("### Named functions: every path at their busiest statements (up to %d per function)\n" % NAMED_ROWS_PER_FUNCTION)
    out.append(table(["Path", "Function", "statements.c line", "Calls", "Units", "Statement"],
                     statement_rows(chosen, statements), ["l", "l", "r", "r", "r", "l"]))
    return "\n".join(out)


# -------------------------------------------------------------------- rc

RC_KINDS = ["record", "list", "union", "string"]
# The roadmap's sources, in its order, by category prefix; the first match wins.
RC_GROUPS = [
    ("Projection acquisition", ("acquire:projection",)),
    ("Stored-field acquisition", ("acquire:stored",)),
    ("Borrowed-return acquisition (end of a block)", ("acquire:block_end",)),
    ("Loop-entry acquisition", ("acquire:loop_entry",)),
    ("Call transfer (acquisition for an owned parameter)", ("acquire:call",)),
    ("Explicit drop at last use", ("drop:",)),
    ("Cascade from a parent's free", ("cascade:",)),
    ("List `get` (hands out a second reference)", ("runtime_list:get",)),
    ("Other list helpers (append, concat, set, ...)", ("runtime_list:",)),
    ("Other runtime helper (String literals, concat)", ("runtime_other",)),
    ("Unattributed", ("unmarked", "untagged")),
]
PAIR_REASONS = ("stored", "block_end", "call", "loop_entry")


def read_rc(directory):
    categories = {}
    for line in read(os.path.join(directory, "rc", "categories.tsv")).splitlines():
        index, name = line.split("\t")
        categories[int(index)] = name
    tagged = defaultdict(int)  # (kind, direction, function number, category name) -> count
    for line in read(os.path.join(directory, "rc", "tagged.tsv")).splitlines():
        kind, direction, function, category, count = line.split("\t")
        tagged[(kind, direction, int(function), categories[int(category)])] += int(count)
    kinds = {}
    for line in read(os.path.join(directory, "rc", "kinds.tsv")).splitlines():
        kind, direction, count = line.split("\t")
        kinds[(kind, direction)] = int(count)
    return tagged, kinds


def group_of(category):
    for label, prefixes in RC_GROUPS:
        if category.startswith(prefixes):
            return label
    fail("category %s belongs to no group" % category)


def cell(cells, kind):
    return "%s / %s" % (number(cells[(kind, "inc")]), number(cells[(kind, "dec")]))


def by_kind_rows(groups, grand):
    """Rows `label | operations | share | per-kind inc / dec` for {label: {(kind, direction): count}}."""
    rows = []
    for label, cells in groups:
        total = sum(cells.values())
        rows.append([label, number(total), percent(total, grand)] + [cell(cells, k) for k in RC_KINDS])
    return rows


def rc_kinds(kinds, tagged):
    rows, grand = [], 0
    for kind in RC_KINDS + ["other"]:
        inc, dec = kinds[(kind, "inc")], kinds[(kind, "dec")]
        grand += inc + dec
        rows.append((kind, number(inc), number(dec), number(inc + dec)))
    rows.append(("total", number(sum(kinds[(k, "inc")] for k in RC_KINDS + ["other"])),
                 number(sum(kinds[(k, "dec")] for k in RC_KINDS + ["other"])), number(grand)))
    mismatches = []
    for kind in RC_KINDS + ["other"]:
        for direction in ("inc", "dec"):
            summed = sum(c for (k, d, _, _), c in tagged.items() if k == kind and d == direction)
            if summed != kinds[(kind, direction)]:
                mismatches.append("%s %s: tagged %d, kinds-only %d" % (kind, direction, summed, kinds[(kind, direction)]))
    verdict = "yes, every kind and direction" if not mismatches else "NO: " + "; ".join(mismatches)
    text = "### Atomic operations by kind\n\n" + table(["Kind", "Increments", "Decrements", "Total"], rows, ["l", "r", "r", "r"])
    return text + "\nTagged counts sum to the kind-only counts: **%s**.\n" % verdict, grand


def rc_sources(tagged, grand):
    grouped = defaultdict(lambda: defaultdict(int))
    for (kind, direction, _, category), count in tagged.items():
        grouped[group_of(category)][(kind, direction)] += count
    rows = by_kind_rows([(label, grouped[label]) for label, _ in RC_GROUPS], grand)
    return ("### Atomic operations by source (increments / decrements per data kind)\n\n"
            + table(["Source", "Operations", "Share"] + RC_KINDS, rows, ["l", "r", "r", "r", "r", "r", "r"]))


def rc_pairs(tagged, grand):
    """Projection pairs, and move candidates by the reason of the acquisition that starts each pair."""
    groups = []
    projection = defaultdict(int)
    for (kind, direction, _, category), count in tagged.items():
        if (direction == "inc" and category == "acquire:projection") or \
                (direction == "dec" and category.startswith("drop:projection")):
            projection[(kind, direction)] += count
    groups.append(("Projection acquired, owner later dropped", projection))
    totals = defaultdict(int)
    for reason in PAIR_REASONS:
        cells = defaultdict(int)
        for (kind, direction, _, category), count in tagged.items():
            if direction == "inc" and category.startswith("acquire:%s:" % reason) and category.endswith("+pair"):
                cells[(kind, "inc")] += count
            if direction == "dec" and category.endswith("+pair:" + reason):
                cells[(kind, "dec")] += count
        if cells:
            groups.append(("Move candidate, acquisition reason `%s`" % reason, cells))
            for key, count in cells.items():
                totals[key] += count
    groups.append(("Move candidates, all reasons", totals))
    mismatch = {k: sum(c for (kk, d, _, cat), c in tagged.items() if kk == k and d == "inc" and cat.endswith("+pair"))
                - totals[(k, "dec")] for k in RC_KINDS}
    text = ("### Acquire-then-drop pairs\n\nA move candidate is an acquisition from an owner whose drop follows in the "
            "same operation list with at most one definition between, so a move would replace both. Each drop is "
            "filed under the reason of its own partner acquisition, so both columns of a row are measured. The projection "
            "row overlaps the others when a projected owner is acquired again from.\n\n"
            + table(["Pairs", "Operations", "Share"] + RC_KINDS, by_kind_rows(groups, grand), ["l", "r", "r", "r", "r", "r", "r"]))
    return text + "\nAcquisitions minus drops in the move-candidate pairs, by kind: %s.\n" % ", ".join(
        "%s %s" % (k, number(v)) for k, v in mismatch.items())


def rc_origins(tagged):
    origins = defaultdict(lambda: defaultdict(int))
    for (kind, direction, _, category), count in tagged.items():
        if category.startswith("drop:"):
            origins[category[len("drop:"):].split("+")[0]][kind] += count
    rows = [[o, number(sum(c.values()))] + [number(c[k]) for k in RC_KINDS]
            for o, c in sorted(origins.items(), key=lambda item: -sum(item[1].values()))]
    return "### Explicit drops by the origin of the dropped owner\n\n" + table(["Origin", "Drops"] + RC_KINDS, rows, ["l", "r", "r", "r", "r", "r"])


def rc_reuse_pool(tagged, kinds):
    """Record work a reused cell would skip: children freed by a cascade and fields stored into a new cell."""
    cascade = sum(c for (k, d, _, cat), c in tagged.items() if k == "record" and cat.startswith("cascade:"))
    stored = sum(c for (k, d, _, cat), c in tagged.items() if k == "record" and cat.startswith("acquire:stored"))
    total = sum(kinds[("record", d)] for d in ("inc", "dec"))
    return ("### Record RC work a reused record cell could skip\n\n"
            "Record decrements in cascades (%s, any parent kind) plus record increments for stored fields (%s): %s of %s "
            "record operations (%s). This is neither an upper nor a lower bound: cascades also free records held by "
            "other parents, and the old cell's own drop is not included.\n"
            % (number(cascade), number(stored), number(cascade + stored), number(total), percent(cascade + stored, total)))


def rc_concentration(tagged, labels, grand):
    projection, modules = defaultdict(int), defaultdict(int)
    for (kind, direction, function, category), count in tagged.items():
        name = label_of(labels, function)
        modules[name.split(".")[0]] += count
        if category == "acquire:projection":
            projection[name] += count
    ranked = sorted(projection.items(), key=lambda item: -item[1])[:5]
    held = sum(c for _, c in ranked)
    module, module_count = max(modules.items(), key=lambda item: item[1])
    return ("### Concentration\n\nThe five functions with the most projection acquisitions hold %s of %s (%s): %s. "
            "Module `%s` holds %s of all %s operations (%s).\n"
            % (number(held), number(sum(projection.values())), percent(held, sum(projection.values())),
               "; ".join("%s %s" % (n, number(c)) for n, c in ranked), module, number(module_count), number(grand),
               percent(module_count, grand)))


def rc_top_record_functions(tagged, labels, kinds, top):
    short = [("Projection acquisition", "proj acq"), ("Explicit drop at last use", "drops"),
             ("Cascade from a parent's free", "cascade"), ("Stored-field acquisition", "stored"),
             ("Borrowed-return acquisition (end of a block)", "block end"),
             ("List `get` (hands out a second reference)", "list get")]
    per_function = defaultdict(lambda: defaultdict(int))
    for (kind, direction, function, category), count in tagged.items():
        if kind == "record":
            per_function[label_of(labels, function)][group_of(category)] += count
    record_total = sum(kinds[("record", d)] for d in ("inc", "dec"))
    rows = []
    for name, cells in sorted(per_function.items(), key=lambda item: -sum(item[1].values()))[:top]:
        total = sum(cells.values())
        rows.append([name, number(total), percent(total, record_total)] + [number(cells[g]) for g, _ in short])
    return ("### Top %d Blorp functions by record operations\n\n" % top
            + table(["Function", "Record ops", "Share"] + [s for _, s in short], rows, ["l", "r", "r"] + ["r"] * len(short)))


def rc(directory, top):
    labels = function_labels(directory)
    tagged, kinds = read_rc(directory)
    kinds_text, grand = rc_kinds(kinds, tagged)
    return "\n".join([kinds_text, rc_sources(tagged, grand), rc_pairs(tagged, grand), rc_origins(tagged),
                      rc_reuse_pool(tagged, kinds), rc_concentration(tagged, labels, grand),
                      rc_top_record_functions(tagged, labels, kinds, top)])


# ------------------------------------------------------------- allocations

# Immediate helper -> data kind. Every allocating runtime helper carries its family in its name.
ALLOCATION_KINDS = [
    ("record", re.compile(r"blorp_record_make_")),
    ("boxed union", re.compile(r"blorp_union_make_")),
    ("List", re.compile(r"blorp_list_")),
    ("String", re.compile(r"blorp_string_|blorp_int_to_string|blorp_float_|blorp_read_file")),
]
SITE_LINE = re.compile(r"\s*(\d+)\s+([\d.]+)%\s+(\d+)\s+(\d+)\s+(.*)$")


def allocation_kind(helper):
    if helper == "(direct)":
        # Only list literals allocate in emitted code itself (`blorp_vl_N_capacity` in blorp_f_N).
        return "List (literal built inline)"
    for kind, pattern in ALLOCATION_KINDS:
        if pattern.match(helper):
            return kind
    return "other runtime (%s)" % re.sub(r"\d+", "N", helper)


def allocations(directory, top):
    text = read(os.path.join(directory, "allocations", "sites.txt"))
    header = re.search(r"total: (\d+) allocations, (\d+) bytes requested, (\d+) resizes", text)
    if not header:
        fail("sites.txt has no total line")
    total, total_bytes = int(header.group(1)), int(header.group(2))
    section = text.split("By site and immediate helper", 1)
    if len(section) != 2:
        fail("sites.txt has no 'By site and immediate helper' table")
    by_kind = defaultdict(lambda: [0, 0])
    pairs = defaultdict(lambda: [0, 0])
    for line in section[1].splitlines():
        found = SITE_LINE.match(line)
        if not found:
            continue
        count, size, label = int(found.group(1)), int(found.group(3)), found.group(5)
        function, _, helper = label.partition(" <- ")
        function = re.sub(r" \(blorp_f_\d+\)$", "", function)
        kind = allocation_kind(helper)
        for cells, key in ((by_kind, kind), (pairs, (function, helper, kind))):
            cells[key][0] += count
            cells[key][1] += size
    out = ["### Allocations by data kind\n",
           "Total %s allocations, %s bytes requested.\n" % (number(total), number(total_bytes))]
    out.append(table(["Kind", "Allocations", "Share", "Bytes requested"],
                     [(k, number(v[0]), percent(v[0], total), number(v[1]))
                      for k, v in sorted(by_kind.items(), key=lambda item: -item[1][0])], ["l", "r", "r", "r"]))
    out.append("### Top %d allocation sites (function, immediate helper)\n" % top)
    ranked = sorted(pairs.items(), key=lambda item: -item[1][0])[:top]
    out.append(table(["Function", "Helper", "Kind", "Allocations", "Share", "Bytes requested"],
                     [(f, h, k, number(v[0]), percent(v[0], total), number(v[1])) for (f, h, k), v in ranked],
                     ["l", "l", "l", "r", "r", "r"]))
    return "\n".join(out)


# ---------------------------------------------------------------- profile

# Top-of-stack classes. A frame is charged to the first class whose pattern matches
# its symbol or, for system frames, the library it lives in.
PROFILE_CLASSES = [
    ("allocator", re.compile(r"^(blorp_memory_|_?malloc|_?free$|_?calloc|_?realloc|_?nano|_?szone|_xzm|_?small_|_?tiny_|_?large_|_?mvm_)|\(in libsystem_malloc")),
    ("reference-count helpers", re.compile(r"^blorp_(record|list|union|callable)_(dup|drop)_|^blorp_string_(retain|release)")),
    ("memmove, memset, bzero", re.compile(r"_platform_mem|_platform_bzero|^_?mem(move|cpy|set)|^_?bzero")),
    ("specialization lookup (O0's function list)", re.compile(r"find_instance|slot_has_union_key|find_union_instance|slot_has_record_key|same_type|find_union_slot|find_record_instance|instance_lookup")),
]


def classify_frame(frame):
    for label, pattern in PROFILE_CLASSES:
        if pattern.search(frame):
            return label
    return "other"


def inclusive_samples(text):
    """Per function, samples counted once per call-graph path (recursive frames below the first are ignored)."""
    inclusive, stack, in_graph = defaultdict(int), [], False
    for line in text.splitlines():
        if line.startswith("Call graph:"):
            in_graph = True
        elif line.startswith("Total number in stack"):
            break
        elif in_graph:
            node = re.match(r"^(\s*[+!:| ]*)(\d+) (\S+)", line)
            if node:
                indent, count, symbol = len(node.group(1)), int(node.group(2)), node.group(3)
                while stack and stack[-1][0] >= indent:
                    stack.pop()
                if symbol not in [s for _, s in stack]:
                    inclusive[symbol] += count
                stack.append((indent, symbol))
    return inclusive


def profile(directory, top):
    labels = function_labels(directory)
    text = read(os.path.join(directory, "profile", "sample.txt"))
    tail = text.split("Sort by top of stack, same collapsed", 1)
    if len(tail) != 2:
        fail("sample.txt has no 'Sort by top of stack' section")
    thread = re.search(r"^\s+(\d+) Thread_", text, re.M)
    if not thread:
        fail("sample.txt has no main-thread line")
    samples = int(thread.group(1))
    classes, listed = defaultdict(int), 0
    for line in tail[1].split("Binary Images:")[0].splitlines():
        found = re.match(r"\s+(.+?)\s{2,}\(in ([^)]*)\)\s+(\d+)\s*$", line)
        if found:
            symbol, library, count = found.group(1), found.group(2), int(found.group(3))
            # A user function inlines its callees at -O2, so its comment label is all there is to match.
            classes[classify_frame("%s (in %s)" % (labels.get(symbol, symbol), library))] += count
            listed += count
    out = ["### Top-of-stack shares (%s samples)\n" % number(samples),
           "`sample` lists only frames with at least 5 samples (%s of %s samples here), so every class is a "
           "lower bound; \"other\" holds the unlisted remainder.\n" % (number(listed), number(samples))]
    out.append(table(["Class", "Samples", "Share of all samples"],
                     [(k, number(v), percent(v, samples)) for k, v in sorted(classes.items(), key=lambda item: -item[1])],
                     ["l", "r", "r"]))
    blorp = defaultdict(int)
    for symbol, count in inclusive_samples(text).items():
        if symbol.startswith("blorp_f_"):
            blorp[labels.get(symbol, symbol)] += count
    out.append("### Top %d Blorp functions, inclusive\n" % top)
    out.append(table(["Function", "Samples", "Share"],
                     [(n, number(c), percent(c, samples)) for n, c in sorted(blorp.items(), key=lambda item: -item[1])[:top]],
                     ["l", "r", "r"]))
    return "\n".join(out)


# ----------------------------------------------------------------- timing

def timing(directory, top):
    rows = []
    for line in read(os.path.join(directory, "timing", "runs.tsv")).splitlines():
        build, sample, load, seconds, cycles, instructions = line.split("\t")
        rows.append((build, int(sample), load, float(seconds), int(cycles), int(instructions)))
    best = {}
    for build in sorted({r[0] for r in rows}):
        mine = [r for r in rows if r[0] == build]
        best[build] = (min(r[3] for r in mine), min(r[4] for r in mine), min(r[5] for r in mine))
    out = ["### Runs (in execution order)\n"]
    out.append(table(["Build", "Sample", "Load average (1, 5, 15 min) before", "User+system seconds", "Cycles", "Instructions retired"],
                     [(r[0], r[1], r[2], "%.3f" % r[3], number(r[4]), number(r[5])) for r in rows], ["l", "r", "l", "r", "r", "r"]))
    out.append("### Best of %d\n" % max(r[1] for r in rows))
    out.append(table(["Build", "Seconds", "Cycles", "Instructions retired"],
                     [(b, "%.3f" % v[0], number(v[1]), number(v[2])) for b, v in best.items()], ["l", "r", "r", "r"]))
    a, p = best["atomic"], best["plain"]
    instructions = 100.0 * (p[2] / a[2] - 1)
    out.append("Plain over atomic, best of each: %.1f%% less time, %.1f%% fewer cycles, %.1f%% %s instructions.\n"
               % (100.0 * (1 - p[0] / a[0]), 100.0 * (1 - p[1] / a[1]), abs(instructions), "more" if instructions > 0 else "fewer"))
    by_sample = defaultdict(dict)
    for r in rows:
        by_sample[r[1]][r[0]] = r
    fewer = sorted(100.0 * (1 - v["plain"][4] / v["atomic"][4]) for v in by_sample.values() if len(v) == 2)
    out.append("Per pair (same sample number), the plain build used %.1f%% to %.1f%% fewer cycles, median %.1f%%.\n"
               % (fewer[0], fewer[-1], fewer[len(fewer) // 2]))
    return "\n".join(out)


STAGES = {"copies": copies, "rc": rc, "allocations": allocations, "profile": profile, "timing": timing}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stage", choices=sorted(STAGES))
    parser.add_argument("directory")
    parser.add_argument("--top", type=int, default=20)
    arguments = parser.parse_args()
    print(STAGES[arguments.stage](arguments.directory, arguments.top))


if __name__ == "__main__":
    main()
