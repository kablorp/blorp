#!/usr/bin/env python3
"""Instrument Blorp 2 generated C to attribute List and String update copies to call sites.

Scratch measurement only: it rewrites a copy of the generated C and never touches the
repository. macOS only (it reads `_mh_execute_header` for the load address).

Usage: instrument_copies.py IN.c OUT.c

The runtime has two helpers per update (append, set, concat for Lists; concat and
append_int for Strings). The borrowed helper always copies the whole value. The
`*_take_left` helper updates in place when the caller holds the only reference and
otherwise falls back to the borrowed helper and drops its argument. The output
records, per call site (a return address), how often each path ran and how many
List slots or String bytes it moved:
  list_unique / string_unique      in place (nothing copied; units are the live length
                                   the copy would have cost)
  list_fallback / string_fallback  shared root, copied by the take_left helper
  list_borrowed / string_borrowed  called directly on a borrowed value, copied
Helpers are marked noinline and every statement is put on its own line so that
`-g` line numbers name the call. The program writes $BLORP_PROF_OUT at exit.
"""
import re
import sys

PRELUDE = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach-o/loader.h>
extern const struct mach_header_64 _mh_execute_header;
enum { PROF_LIST_FALLBACK, PROF_LIST_UNIQUE, PROF_STRING_FALLBACK, PROF_STRING_UNIQUE,
       PROF_LIST_BORROWED, PROF_STRING_BORROWED, PROF_KINDS };
static const char *prof_kind_names[] = {"list_fallback","list_unique","string_fallback","string_unique",
                                        "list_borrowed","string_borrowed"};
#define PROF_SLOTS (1u<<16)
struct prof_row { void *address; unsigned kind; unsigned long long hits, units; };
static struct prof_row prof_rows[PROF_SLOTS];
static void prof_hit(unsigned kind, void *address, long long units) {
  uintptr_t key = ((uintptr_t)address * 0x9E3779B97F4A7C15ull) ^ kind;
  unsigned slot = (unsigned)(key >> 20) & (PROF_SLOTS - 1);
  for (;;) {
    struct prof_row *row = &prof_rows[slot];
    if (row->hits == 0) { row->address = address; row->kind = kind; }
    if (row->address == address && row->kind == kind) { row->hits++; row->units += (unsigned long long)units; return; }
    slot = (slot + 1) & (PROF_SLOTS - 1);
  }
}
static void prof_report(void) {
  FILE *out = fopen(getenv("BLORP_PROF_OUT") ? getenv("BLORP_PROF_OUT") : "prof.tsv", "w");
  fprintf(out, "#load\t%p\n", (void *)&_mh_execute_header);
  for (unsigned i = 0; i < PROF_SLOTS; i++)
    if (prof_rows[i].hits)
      fprintf(out, "%s\t%p\t%llu\t%llu\n", prof_kind_names[prof_rows[i].kind], prof_rows[i].address,
              prof_rows[i].hits, prof_rows[i].units);
  fclose(out);
}
__attribute__((constructor)) static void prof_start(void) { atexit(prof_report); }
#define PROF_RA __builtin_return_address(0)
'''

NOINLINE = '__attribute__((noinline)) '
LIST_TYPE = r'struct blorp_l_[a-z0-9_]+'
helpers = {}


def instrument(text):
    def rewrite(label, pattern, replace):
        nonlocal text
        text, count = re.subn(pattern, replace, text)
        helpers[label] = count

    # In-place helpers: shared root (fallback) or unique.
    rewrite("list take_left",
            LIST_TYPE + r'\* blorp_list_(?:append|set|concat)_take_left_[a-z0-9_]+\([^{)]*\)\{',
            lambda m: NOINLINE + m.group(0)
            + 'prof_hit(atomic_load_explicit(&values->references,memory_order_acquire)!=1'
              '?PROF_LIST_FALLBACK:PROF_LIST_UNIQUE,PROF_RA,values->length);')
    # Borrowed helpers: every call copies all live slots.
    rewrite("list borrowed",
            LIST_TYPE + r'\* blorp_list_(?:append|set|concat)_[0-9]+_[a-z0-9_]+\(const ' + LIST_TYPE + r' \*(values|left),[^{)]*\)\{',
            lambda m: NOINLINE + m.group(0) + 'prof_hit(PROF_LIST_BORROWED,PROF_RA,%s->length);' % m.group(1))
    rewrite("string take_left",
            r'struct blorp_string \*blorp_string_(?:concat|append_int)_take_left\(struct blorp_string \*left,[^{)]*\) \{',
            lambda m: NOINLINE + m.group(0)
            + 'prof_hit(atomic_load_explicit(&left->references,memory_order_acquire)!=1'
              '?PROF_STRING_FALLBACK:PROF_STRING_UNIQUE,PROF_RA,left->length);')
    rewrite("string borrowed",
            r'struct blorp_string \*blorp_string_(?:concat|append_int)\(const struct blorp_string \*left,[^{)]*\) \{',
            lambda m: NOINLINE + m.group(0) + 'prof_hit(PROF_STRING_BORROWED,PROF_RA,left->length);')
    return PRELUDE + text


def split_statements(source):
    """Put each C statement on its own line (outside literals and preprocessor lines)."""
    out, i, n, quote, directive = [], 0, len(source), None, False
    at_line_start = True
    while i < n:
        c = source[i]
        if quote:
            out.append(c)
            if c == '\\':
                out.append(source[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        elif source.startswith('/*', i):
            j = source.index('*/', i) + 2
            out.append(source[i:j])
            i = j
            continue
        elif c in '"\'':
            quote = c
            out.append(c)
        else:
            if at_line_start and c == '#':
                directive = True
            out.append(c)
            if c == '\n':
                directive = False
            elif not directive and c in ';{}':
                out.append('\n')
        at_line_start = (c == '\n') or (at_line_start and c in ' \t')
        i += 1
    return ''.join(out)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1]) as handle:
        text = handle.read()
    instrumented = split_statements(instrument(text))
    with open(sys.argv[2], "w") as handle:
        handle.write(instrumented)
    for label, count in sorted(helpers.items()):
        print("%-18s %d" % (label, count), file=sys.stderr)
        if count == 0:
            sys.exit("error: instrument_copies: no %s helper matched; the runtime's helper shape changed" % label)


if __name__ == "__main__":
    main()
