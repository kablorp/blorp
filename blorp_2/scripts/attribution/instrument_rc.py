#!/usr/bin/env python3
"""Count every atomic reference-count operation in Blorp 2 generated C, by kind and by source.

Scratch measurement only: it rewrites a copy of the generated C and never touches
the repository. The instrumented program counts operations in plain integers, so
it is valid only because the compiler is single-threaded.

Usage:
  instrument_rc.py --kinds IN.c OUT.c
      Count by kind (record, list, union, string) and direction. Needs no markers;
      this is the uninstrumented total the tagged counts must sum to.
  instrument_rc.py --tagged MARKED.c OUT.c CATEGORIES.tsv
      Also count by source and by the Blorp function responsible. MARKED.c is the
      output of the marker compiler (patch_emit_markers.py); CATEGORIES.tsv
      receives the category names in tag order.
The instrumented program writes `kind direction function category count` rows to
the file named by $BLORP_RC_OUT when it exits (--kinds: `kind direction count`).

How a source is known. Every call of a dup or drop helper becomes
`(blorp_rc_tag = T, helper)(...)`, so the atomic operation at the top of the helper
counts under T. The tag packs the Blorp function number N of `blorp_f_N` above six
category bits. T depends on where the call sits:
  - inside a marker region of a user function: the region's reason and borrow source
    (acquire:reason:source), or, for a drop, the origin of the dropped owner
    (drop:origin; an owner no marker created is an error). `+pair` marks an acquisition
    the markers saw partnered with a drop, and `+pair:REASON` a drop whose partner
    acquisition had that reason;
  - in a drop helper that has its own atomic operation, after that operation: the
    helper frees its children (cascade:record|list|union);
  - in a list helper (get, append, ...): runtime_list:<operation>;
  - in a helper with no atomic operation of its own (an unboxed union, an inline
    record): the tag its caller set, saved on entry and restored before each call,
    so one Blorp-level acquisition stays one acquisition.
Calls of other runtime functions set only the function bits. A call of a helper in a
user function outside every marker region counts as `unmarked`; the report states it.

The shared empty List's owner count exists only in diagnostic builds, where
`blorp_list_empty_acquire` is a function; in the normal build it is a macro with no
atomic operation, so the counted program is the normal build and ignores it.
"""
import re
import sys

KINDS = ["record", "list", "union", "string", "other"]
CATEGORY_BITS = 7
CATEGORY_MASK = (1 << CATEGORY_BITS) - 1
# Characters before a parameter list searched for the function name; no name is longer.
NAME_WINDOW = 200

HELPER_CALL = re.compile(
    r"\b(blorp_(?:record|list|union|callable)_(?:dup|drop)_\w+|blorp_string_(?:retain|release))\s*\(")
LIST_RUNTIME_CALL = re.compile(r"\b(blorp_list_(?:get|append|concat|set|suffix|repeat)\w*)\s*\(")
STRING_RUNTIME_CALL = re.compile(r"\b(blorp_string_(?!retain\b|release\b)\w+)\s*\(")
LIST_RUNTIME_NAME = re.compile(r"blorp_list_(get|append|concat|set|suffix|repeat)_")
HELPER_NAME = re.compile(r"blorp_(?:record|list|union|callable)_(dup|drop)_\w+$|blorp_string_(retain|release)$")
USER_NAME = re.compile(r"blorp_f_(\d+)$")
ATOMIC = re.compile(r"atomic_fetch_(add|sub)_explicit\(\s*&")
MARKER = re.compile(r"/\*RC:([^*]*)\*/")
# Top-level tokens the brace scan must step over without counting their braces.
SCAN = re.compile(
    r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|/\*.*?\*/|//[^\n]*|^[ \t]*#(?:\\\n|[^\n])*|[{}]',
    re.S | re.M)


def fail(message):
    sys.exit("error: instrument_rc: " + message)


def functions(source):
    """Return (name, body_start, body_end) for every top-level function body."""
    found, depth, open_at = [], 0, None
    for token in SCAN.finditer(source):
        text = token.group()
        if text == "{":
            if depth == 0:
                open_at = token.start()
            depth += 1
        elif text == "}":
            depth -= 1
            if depth == 0:
                name = function_name_before(source, open_at)
                if name:
                    found.append((name, open_at + 1, token.start()))
        # strings, comments and directives do not change depth
    return found


def function_name_before(source, brace):
    """The function a top-level `{` opens, or None for a struct, union or initializer."""
    index = brace - 1
    while index >= 0 and source[index].isspace():
        index -= 1
    if index < 0 or source[index] != ")":
        return None
    depth = 0
    while index >= 0:
        if source[index] == ")":
            depth += 1
        elif source[index] == "(":
            depth -= 1
            if depth == 0:
                break
        index -= 1
    named = re.search(r"(\w+)\s*$", source[max(0, index - NAME_WINDOW):index])
    return named.group(1) if named else None


def kind_of(function):
    for kind in KINDS[:4]:
        if function.startswith("blorp_" + kind):
            return KINDS.index(kind)
    return KINDS.index("other")


def match_end(source, open_paren):
    depth = 0
    for index in range(open_paren, len(source)):
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    fail("unbalanced parenthesis")


def count_atomics(body, function, counter):
    """Wrap each atomic add/sub so it also bumps `counter(kind, direction)`; return (text, sites)."""
    pieces, cursor, sites = [], 0, 0
    for match in ATOMIC.finditer(body):
        end = match_end(body, match.start() + len("atomic_fetch_" + match.group(1) + "_explicit"))
        direction = 0 if match.group(1) == "add" else 1
        pieces.append(body[cursor:match.start()])
        pieces.append("(%s,%s)" % (counter(kind_of(function), direction), body[match.start():end]))
        cursor = end
        sites += 1
    pieces.append(body[cursor:])
    return "".join(pieces), sites


class Categories:
    def __init__(self):
        self.names = ["untagged"]

    def number(self, name):
        if name not in self.names:
            self.names.append(name)
            if len(self.names) > CATEGORY_MASK + 1:
                fail("more than %d categories" % (CATEGORY_MASK + 1))
        return self.names.index(name)


def region_tags(body, name):
    """Per-call categories inside a user function body: split at its marker regions."""
    acquired, created = {}, {}
    for marker in MARKER.finditer(body):
        fields = marker.group(1).split()
        if fields[:2] == ["B", "A"]:
            acquired[fields[5]] = fields[2]
        elif fields[0] == "K":
            created[fields[1]] = fields[2]
    pieces, cursor, category = [], 0, "unmarked"
    for marker in MARKER.finditer(body):
        pieces.append((body[cursor:marker.start()], category))
        cursor = marker.end()
        fields = marker.group(1).split()
        if fields[0] == "B":
            if fields[1] == "A":
                reason, source, pair = fields[2:5]
                category = "acquire:" + reason + ("" if reason == "projection" else ":" + source)
                category += "+pair" if pair == "pair" else ""
            else:
                owner, partner = fields[2:4]
                origin = acquired.get(owner) or created.get(owner)
                if origin is None:
                    fail("%s drops owner %s, which no marker created" % (name, owner))
                category = "drop:" + origin + ("" if partner == "none" else "+pair:" + partner)
        elif fields[0] == "E":
            category = "unmarked"
    pieces.append((body[cursor:], category))
    return pieces


def tag_calls(text, tag_expression):
    return HELPER_CALL.sub(lambda m: "(blorp_rc_tag=%s,%s)(" % (tag_expression, m.group(1)), text)


def rewrite_tagged(name, body, categories):
    user = USER_NAME.match(name)
    if user:
        number = int(user.group(1))
        function_bits = number << CATEGORY_BITS
        out = []
        for text, category in region_tags(body, name):
            text = tag_calls(text, "%du" % (function_bits | categories.number(category)))
            for pattern in (LIST_RUNTIME_CALL, STRING_RUNTIME_CALL):
                text = pattern.sub(lambda m: "(blorp_rc_tag=%du,%s)(" % (function_bits, m.group(1)), text)
            out.append(text)
        return "".join(out)
    list_runtime = LIST_RUNTIME_NAME.match(name)
    if list_runtime:
        category = categories.number("runtime_list:" + list_runtime.group(1))
        return tag_calls(body, "(blorp_rc_tag&~%du)|%du" % (CATEGORY_MASK, category))
    helper = HELPER_NAME.match(name)
    if helper:
        first_atomic = ATOMIC.search(body)
        if first_atomic is None:
            # No operation of its own: every child call runs under the caller's tag.
            if not HELPER_CALL.search(body):
                return body
            return "const unsigned blorp_rc_saved=blorp_rc_tag;" + tag_calls(body, "blorp_rc_saved")
        if name.split("_")[2] == "dup" or name.startswith("blorp_string_"):
            return body
        # After its own decrement a drop helper frees children: a cascade.
        parent = name.split("_")[1]
        category = categories.number("cascade:" + parent)
        head, tail = body[:first_atomic.start()], body[first_atomic.start():]
        return head + tag_calls(tail, "(blorp_rc_tag&~%du)|%du" % (CATEGORY_MASK, category))
    if HELPER_CALL.search(body):
        category = categories.number("runtime_other")
        return tag_calls(body, "(blorp_rc_tag&~%du)|%du" % (CATEGORY_MASK, category))
    return body


def check_only_calls(source):
    """Every mention of a helper must be a call or a declaration, or a tag could be missed."""
    for match in re.finditer(r"\b(blorp_(?:record|list|union|callable)_(?:dup|drop)_\w+|blorp_string_(?:retain|release))\b(?!\s*\()", source):
        fail("helper %s is used other than by a call (offset %d)" % (match.group(1), match.start()))


PRELUDE_COMMON = """#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
"""


def rewrite(source, mode):
    categories = Categories()
    pieces, cursor, wrapped = [], 0, 0
    for name, start, end in functions(source):
        body = source[start:end]
        if mode == "tagged":
            body = rewrite_tagged(name, body, categories)
            counter = lambda kind, direction: "blorp_rc_counts[blorp_rc_tag][%d]++" % (kind * 2 + direction)
        else:
            counter = lambda kind, direction: "blorp_rc_kind_counts[%d]++" % (kind * 2 + direction)
        body, sites = count_atomics(body, name, counter)
        wrapped += sites
        pieces.append(source[cursor:start])
        pieces.append(body)
        cursor = end
    pieces.append(source[cursor:])
    found = len(ATOMIC.findall(source))
    if wrapped != found:
        fail("wrapped %d atomic operations but the source has %d; one sits outside a function body" % (wrapped, found))
    return "".join(pieces), categories


def prelude(mode, function_limit):
    kinds = ",".join('"%s"' % kind for kind in KINDS)
    if mode == "kinds":
        return PRELUDE_COMMON + """static unsigned long blorp_rc_kind_counts[10];
static void blorp_rc_report(void){static const char *kinds[]={%s};const char *path=getenv("BLORP_RC_OUT");
FILE *out=path?fopen(path,"w"):stderr;if(!out)return;
for(int k=0;k<5;k++)for(int d=0;d<2;d++)fprintf(out,"%%s\\t%%s\\t%%lu\\n",kinds[k],d?"dec":"inc",blorp_rc_kind_counts[2*k+d]);
if(path)fclose(out);}
__attribute__((constructor)) static void blorp_rc_install(void){atexit(blorp_rc_report);}
""" % kinds
    tags = (function_limit + 1) << CATEGORY_BITS
    return PRELUDE_COMMON + """static unsigned long blorp_rc_counts[%d][10];
static unsigned blorp_rc_tag;
static void blorp_rc_report(void){static const char *kinds[]={%s};const char *path=getenv("BLORP_RC_OUT");
FILE *out=path?fopen(path,"w"):stderr;if(!out)return;
for(unsigned t=0;t<%du;t++)for(int k=0;k<5;k++)for(int d=0;d<2;d++){unsigned long n=blorp_rc_counts[t][2*k+d];
if(n)fprintf(out,"%%s\\t%%s\\t%%u\\t%%u\\t%%lu\\n",kinds[k],d?"dec":"inc",t>>%d,t&%du,n);}
if(path)fclose(out);}
__attribute__((constructor)) static void blorp_rc_install(void){atexit(blorp_rc_report);}
""" % (tags, kinds, tags, CATEGORY_BITS, CATEGORY_MASK)


def main():
    arguments = sys.argv[1:]
    if len(arguments) == 3 and arguments[0] == "--kinds":
        mode, source_path, output_path, categories_path = "kinds", arguments[1], arguments[2], None
    elif len(arguments) == 4 and arguments[0] == "--tagged":
        mode, source_path, output_path, categories_path = "tagged", arguments[1], arguments[2], arguments[3]
    else:
        sys.exit(__doc__)
    with open(source_path) as handle:
        source = handle.read()
    check_only_calls(source)
    rewritten, categories = rewrite(source, mode)
    limit = max([int(m.group(1)) for m in re.finditer(r"\bblorp_f_(\d+)\(", source)] or [0])
    with open(output_path, "w") as handle:
        handle.write(prelude(mode, limit) + rewritten)
    if categories_path:
        with open(categories_path, "w") as handle:
            handle.write("".join("%d\t%s\n" % (index, name) for index, name in enumerate(categories.names)))
    print("instrumented %s: %d atomic operations, %d categories"
          % (mode, len(ATOMIC.findall(source)), len(categories.names)), file=sys.stderr)


if __name__ == "__main__":
    main()
