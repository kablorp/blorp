# String code-point semantics

Plan revision 1, 2026-11-10, written against origin/main `999c28fb6`.

Keith set the direction on 2026-11-10:

> For UTF8 strings, which we have, we should support utf-8 semantics. We
> should store the length in chars or codepoints, or whatever python does.
> We can consider having a ByteView of a string or an ASCII refinement type.

So `String` stays UTF-8 in memory. `length` counts code points, as Python's
`len` does, from a count stored in every String. Byte-level access moves to
functions whose names say "byte". The decisions below settle the rest.

**Status:** approved. Keith approved S3 to S9 and the ceilings as
recommended on 2026-11-10. The S0 cost spike is done: the stored count costs
+0.16% instructions and +0.11% peak heap on a self-compile (see "S0
results"). L1 landed on 2026-11-12 within its ceilings, with S9's recount
limited to strict runs (see "L1 results"). That recount costs a strict -O0
test compiler about 18%, which L2's e2e instruction ceilings cannot absorb as
planned. Counting eight bytes per step (see "Recount") and resetting three
path ceilings (see "Keith's ruling") let L2 proceed. L2 landed on 2026-11-12:
the seed now carries the count, so the test compiler recounts under strict,
and no e2e ceiling was raised. L3, the breaking switch, is next.

## Problem

`length` counts UTF-8 bytes, and `slice` takes byte offsets:

```blorp
func main() -> Int:
    word = "héllo"
    print("${word.length()}")          -- prints 6; Python's len gives 5
    match word.slice(0, 2):            -- None: offset 2 is inside "é"
        Some(part): print(part)
        None: print("no slice")
    0
```

A programmer coming from Python expects 5 and `"hé"`. A byte count is the
right answer only for byte work: buffers, framing, lexers. Those callers
should say so.

## Background

**The API today** (`standard_library/string.brp`). `length`, `byte_at` and
`slice` work in bytes, and `slice` returns `None` at an offset inside a
character. The rules are documented in:
- `README.md:273-278` and `:314-333`;
- `grammar.ebnf:77-79`;
- `standard_library/README.md:278-285`.

**The runtime** (`src/common/codegen/runtime/string.brp:44`):

```c
struct blorp_string {
atomic_size_t references;
int64_t length;          /* bytes */
size_t capacity; /* Byte capacity, excluding the trailing NUL. */
char bytes[];
};
```

`blorp_string_allocate` is the one constructor. Its writers are in:
- `runtime/string.brp` and `runtime/string_concat.brp`;
- `fs.brp` and `system.brp`;
- `list.brp` (argv);
- `process.brp` and `float.brp`.

Every external input is already validated as UTF-8 (`blorp_utf8_is_valid`).
Interpolation lowers to `+`.

**Who depends on bytes.** The compiler's own text handling does:
- `common/syntax/lex.brp` (19 `length`, 10 `byte_at`, 8 `slice`), `common/syntax/parse.brp`
  and `common/syntax/source.brp`;
- the formatter (`printer`, `trivia`, `layout`, `flat`, `format`);
- `common/cli/usage.brp`, `common/cli/report.brp`, `common/utils/text.brp` and `common/analysis/load/load.brp`;
- `common/codegen/emit/emit.brp:327` (`append_byte_array`) and
  `common/codegen/emit/float_literal.brp:72`;
- `scripts/embed_library.brp:61-184`, which the seed builds and whose output
  is the embedded library, so a missed rename there changes the compiler
  silently.

Spans are byte ranges and stay so.
- **Library:** `json.brp` scans bytes and reports a byte `ParseError.offset`.
  `path.brp`, `io/fs.brp` and `io/process.brp` also work in bytes.
- **Formatter widths:** `display_width` (`format/printer.brp:112`) already
  counts code points by hand.
- **Diagnostic columns:** they count bytes (`common/cli/report.brp:39-56`).

**The bootstrap constraint.** The parser accepts only the builtin labels it
knows (`common/syntax/parse.brp:4398-4439`). The pinned seed builds the compiler
with `--library-root blorp/standard_library`, so it parses this tree's
`string.brp`. A new `string.*` label therefore cannot appear in `string.brp`
until a seed knows it. Every landing below is shaped by that.

**Related plans.**
- `UINT8_BYTES_PLAN.md`: `Bytes` is a copied `List[UInt8]`, and its L4 changes
  `byte_at` to `Option[UInt8]`.
- The `Path` plan has landed: naming case is enforced, and its seed rotation
  is done.
- The language-server plan needs a UTF-8 byte length for `Content-Length`. It
  computes UTF-16 positions itself.

## Decisions for Keith

S1 and S2 are Keith's direction. Keith approved S3 to S9 as recommended on
2026-11-10; each keeps its alternatives for the record.

- **S1, the unit (decided).** Code points, as Python counts. Grapheme
  clusters are rejected for `length`: they need Unicode's segmentation tables,
  which change between Unicode versions, and Python does not use them.
  Graphemes can be a library function later.
- **S2, a stored count (decided).** Each String stores its code-point count
  beside its byte count, so `length` is O(1). A String is ASCII exactly when
  the two counts are equal, which gives an O(1) ASCII test for free.
- **S3, the String API.** *Recommended:*

  | Function | Unit | Cost |
  | --- | --- | --- |
  | `length(text) -> Int` | code points | O(1) |
  | `byte_length(text) -> Int` | bytes | O(1) |
  | `slice(text, start, end) -> String` | code points, clamped | O(1) if ASCII, else O(n) |
  | `codepoint_at(text, index) -> Option[Int]` | code point index, scalar value | O(1) if ASCII, else O(n) |
  | `codepoints(text) -> List[Int]` | every scalar value, in order | O(n) |
  | `is_ascii(text) -> Bool` | | O(1) |
  | `byte_at(text, index) -> Option[Int]` | bytes (unchanged) | O(1) |
  | `byte_slice(text, start, end) -> Option[String]` | byte offsets (today's `slice`) | O(1) plus the copy |

  - **`slice` clamps and cannot fail.** Every code-point index is a character
    boundary, so `slice` clamps `start` and `end` into `0..length` and
    returns a String, as Python slices do and as `List.take`/`drop` and the
    planned `Bytes.slice` already do (principle 10). `byte_slice` keeps
    today's `Option`, because a byte offset can still land inside a
    character.
  - **`codepoint_at` returns the scalar as an Int.** That matches
    `from_codepoint`, until a `Char` type exists. It then becomes
    `Option[Char]`, the way `byte_at` becomes `Option[UInt8]` in the Bytes
    plan.
  - **The spelling** is "codepoint", one word, matching `from_codepoint`.
  - **`slice` with `start > end`** returns `""`, as Python does.
  - **Unit-free functions stay as they are.** `starts_with` (which walks
    `byte_at` until the prefix ends) and `equals` give the same answers in
    either unit. `hash` is not unit-free in its code: it folds `byte_at` over
    `0..value.length()` (`string.brp:85`). It moves to `byte_length`, or after
    L3 it would hash only a prefix of non-ASCII text.
- **S4, byte access: functions, not a view type.** *Recommended:* (a) the
  three `byte_*` functions on String. The alternative, (b), is an opaque
  `ByteView` (or Swift-like `utf8`) value reached by `text.utf8()`, with
  `length`, `at` and `slice`.
  - A view groups the byte operations. But its offsets are still plain
    `Int`s, so it cannot stop a byte offset from reaching `slice`, which is
    the mistake worth preventing.
  - It adds a type and an import (the Bytes plan's B2 shows a type import is
    needed for UFCS).
  - Whole-buffer byte work already has `Bytes`.
  - The protection that does work is the unit in the name: every byte
    function says "byte".

  A typed `ByteOffset` would be the real safety step; it is not proposed.
- **S5, ASCII: a runtime fast path now, a type when a consumer needs it.**
  *Recommended:* (a) `is_ascii` plus the O(1) fast paths in `slice` and
  `codepoint_at`.
  - The alternative, (b), is `opaque type Ascii = String` in an `ascii`
    module, with `to_ascii(text) -> Option[Ascii]` and guaranteed O(1)
    indexing. Blorp has no refinement types; an opaque type is how the
    library states one.
  - (a) gives every ASCII String the speed already. (b) adds a conversion at
    every boundary for a static guarantee that nothing needs yet.
  - Revisit (b) when a consumer, such as a protocol parser, wants the
    guarantee in its signatures.
- **S6, indexing non-ASCII text.** `codepoint_at` and `slice` scan from the
  start on non-ASCII text, so `while i < text.length(): text.codepoint_at(i)`
  is quadratic there. *Recommended:*
  - (a) document the cost, and give iteration `codepoints(text)`, one O(n)
    pass.
  - The alternative, (b), is a PyPy-style index: the byte offset of every
    Kth code point, built lazily inside the String. Building it lazily means
    mutating a shared immutable value, which needs atomics, and nothing
    measured needs it.
  - Defer (b) until a profile shows the quadratic loop.
- **S7, diagnostic columns.** `render_file_location` (`common/cli/report.brp:39-56`)
  counts every byte as a column. *Recommended:* count code points, so a
  column agrees with the new `length` and with rustc's convention. Spans stay
  byte ranges inside the compiler.
- **S8, JSON error offsets.** `json.ParseError.offset` is a documented byte
  offset (`standard_library/README.md:368-381`). *Recommended:* code points,
  so `source.slice(offset, ...)` finds the error. The scanner stays
  byte-based. It converts once, when it fails, by counting the code points
  before the failing byte. "End of input" then means `source.length()`.
- **S9, the stored count's oracle.** A count that a writer forgets to update
  is silently wrong. *Recommended:* in `BLORP_MEMORY_DIAGNOSTICS` builds,
  releasing a String recounts its bytes and aborts with a named fault on a
  mismatch. Every e2e program and unit suite then checks every String it
  frees, at no cost to release builds.

## Code

**The runtime header** (`runtime/string.brp:44`). One field is added.
`blorp_string_allocate` sets it with `length`, and every writer that fills
the bytes afterwards sets it too.

```c
struct blorp_string {
atomic_size_t references;
int64_t length;          /* bytes */
int64_t code_points;     /* Unicode scalars; equal to length exactly when ASCII */
size_t capacity;
char bytes[];
};
```

**Concatenation adds counts and never rescans.** In `string_concat.brp:18`
today, `blorp_string_append_bytes` copies the suffix's bytes. It gains the
suffix's count, which a String operand already has:

```c
/* before */
struct blorp_string *blorp_string_concat(const struct blorp_string *left,const struct blorp_string *right) {
return blorp_string_append_bytes(left,right->bytes,right->length);
}
/* after */
struct blorp_string *blorp_string_concat(const struct blorp_string *left,const struct blorp_string *right) {
return blorp_string_append_bytes(left,right->bytes,right->length,right->code_points);
}
```

The in-place append (`append_bytes_take_left`, `:45`) adds the same count.
`append_int` passes its digit count, because digits are ASCII. Only
`from_bytes` and external input count by scanning. External input already
scans to validate, so it counts in the same pass.

**The library** (`standard_library/string.brp`):

```blorp
-- before
pure func length(value: String) -> Int:
    builtin("string.length")

pure func slice(value: String, start: Int, end: Int) -> Option[String]:
    builtin("string.slice")

-- after
-- The number of Unicode code points; "é" has length 1 whatever its bytes.
pure func length(value: String) -> Int:
    builtin("string.codepoint_length")

-- The number of UTF-8 bytes, for buffers, framing and byte offsets.
pure func byte_length(value: String) -> Int:
    builtin("string.byte_length")

-- Code points from `start` up to `end`, both clamped into 0..length.
pure func slice(value: String, start: Int, end: Int) -> String:
    builtin("string.codepoint_slice")

-- Half-open byte offsets; None unless both ends are character boundaries.
pure func byte_slice(value: String, start: Int, end: Int) -> Option[String]:
    builtin("string.byte_slice")

-- A String is ASCII exactly when every code point is one byte.
pure func is_ascii(value: String) -> Bool:
    value.length() == value.byte_length()
```

`codepoint_at` is a builtin. `codepoints` is a plain Blorp loop that decodes
`byte_at`, in O(n).

**Labels are never reused.** The old `string.length` and `string.slice`
labels are deleted rather than given new meanings. If a seed compiled
`string.length` as bytes while the tree compiled it as code points, stages
A and B of the fixpoint would disagree on non-ASCII input.

**A compiler call site** (`format/printer.brp:112`). The hand-written
code-point loop becomes the library call:

```blorp
-- before
pure func display_width(written_text: String) -> Int:
    var width = 0
    var position = 0
    while position < written_text.length():
        match written_text.byte_at(position):
            Some(byte):
                if or(byte < CONTINUATION_FIRST, byte > CONTINUATION_LAST):
                    width = width + 1
            None:
                void
        position = position + 1
    width

-- after
pure func display_width(written_text: String) -> Int:
    written_text.length()
```

**Diagnostic columns** (`common/cli/report.brp:39-56`, S7). The loop advances one byte
at a time and adds a column for every byte. After the change, it adds one
only at the first byte of a character:

```blorp
-- before
        if line_feed:
            line = line + 1
            column = 1
        else:
            column = column + 1

-- after: continuation bytes (0x80-0xBF) do not start a character
        if line_feed:
            line = line + 1
            column = 1
        else if starts_character(file.contents, cursor):
            column = column + 1
```

`starts_character` is a small byte test in the compiler's text utilities
(`common/utils/text.brp`), with named bounds rather than literals.

The lexer's byte work only renames: `text.bytes.length()` becomes
`text.bytes.byte_length()` at `common/syntax/lex.brp:507, 596, 639, ...`, and its
`slice` calls become `byte_slice`.

## S0 results

**Setup.** Measured 2026-11-10 on origin/main `999c28fb6`:
- **Compiler:** a stage-2 build. The seed-built test compiler emitted the
  compiler with each tree's runtime, and clang linked it at
  `-O2 -DBLORP_MEMORY_DIAGNOSTICS=1`.
- **Rounds:** five, alternating between the base and spike trees, on a
  loaded host (load average 5 to 9).
- **Peak heap:** both trees carried the same probe for peak live requested
  bytes. The runtime has no such counter today.

**What the spike changed.** It kept `code_points` current on every writer:
- `from_bytes` by counting, which covers literals, `slice`, number formatting,
  `read_text`, argv and process capture;
- concatenation and the in-place append by adding counts;
- directory entries and system messages.

Nothing read the field.

**Results**, as medians with the range across rounds:

| Workload | Metric | Base | Spike | Change |
| --- | --- | --- | --- | --- |
| self-compile | instructions | 13.315 G (13.286–13.363) | 13.336 G (13.325–13.386) | +0.16% |
| self-compile | allocations | 13,611,465 | 13,611,478 | +13 |
| self-compile | peak heap | 159,693,235 B | 159,873,297 B | +0.11% |
| self-compile | max RSS | 223.5 MB | 224.5 MB | +0.43%, within noise |
| `list/literal_entries` | instructions | 105.38 M | 106.15 M | +0.72%, noisy |
| `list/literal_entries` | peak heap | 1,087,280 B | 1,092,251 B | +0.46% |

- **Determinism.** Allocations and peak heap were identical in every round.
- **The 13 extra allocations** are the added runtime text's own literals.
- **Peak heap rises by 180,062 bytes:** 8 bytes for each of about 22,500
  Strings live at the peak.
- **The emitted C** differs only in its embedded runtime text.
- **This table is the record.** The raw files were not kept.

## L1 results

Written and measured against origin/main `7ddaebf32` (UInt8 L1 and its
seed), at candidate `d3af35192`, before the branch was rebased onto
`af2f0909a`.

**The writer census.** Every C that makes or fills a String, found from each
call of `blorp_string_allocate` and `blorp_string_from_bytes` and each write
to `->length`:

| Writer | Where | How it sets `code_points` |
| --- | --- | --- |
| `blorp_string_allocate` | `runtime/string.brp` | a parameter: the one constructor states both counts |
| `blorp_string_from_counted_bytes` | `runtime/string.brp` | the caller's count |
| `blorp_string_from_bytes` | `runtime/string.brp` | counts its copy, once allocation has refused a bad length |
| literals | `runtime/string.brp` | `from_bytes`, once per site |
| `int_to_string` | `runtime/string.brp` | the digit count: digits are ASCII |
| `from_codepoint` | `runtime/string.brp` | 1 |
| `bytes_to_text` | `runtime/string.brp` | `from_bytes`, after validation |
| `byte_slice` (today's `slice`) | `STRING_SLICE_RUNTIME` | `from_bytes` on the slice |
| `codepoint_slice` | `STRING_SLICE_RUNTIME` | `last - first`, without a rescan |
| concatenation, interpolation | `runtime/string_concat.brp` | the sum of both counts |
| in-place append | `runtime/string_concat.brp` | adds the suffix's count |
| `append_int`, borrowed and in place | `runtime/string_concat.brp` | adds the digit count |
| `float_to_string` | `runtime/float.brp` | `from_bytes` (ASCII) |
| `read_text`, `next_lines` | `runtime/fs.brp` | `from_bytes`, after validation |
| directory entries | `runtime/fs.brp` | 1 for the ASCII entry code, plus the name's count |
| `create_temporary_directory` | `runtime/fs.brp` | `from_bytes` |
| `current_directory` | `runtime/system.brp` | `from_bytes`, after validation |
| argv | `runtime/list.brp` | `from_bytes`, after validation |
| capture (exit text, stdout, stderr), `find_program` | `runtime/process.brp` | `from_bytes` |

`string_to_bytes` only reads a String, and `blorp_string_reserve_unique`
grows capacity without touching either count.

**What L1 decided beyond the text above.**
- **One C function per meaning.** `blorp_string_length` and
  `blorp_string_slice` became `blorp_string_byte_length` and
  `blorp_string_byte_slice`, which both the old and the new byte labels
  call. L3 deletes only the `string.length` and `string.slice` labels and
  their operations.
- **External input is counted in a second pass.** It is validated, then
  `from_bytes` counts its copy, not the one pass "Code" suggests. Fusing the
  two would change every native for a saving the measurement cannot see.
- **Where the functions live.** `codepoint_length` and `codepoint_at` are in
  `string_runtime()`, beside `byte_at`; both slices share
  `STRING_SLICE_RUNTIME`.
- **S9 runs only under `BLORP_LEAK_CHECK=strict`**, because the full recount
  cost 5.14% of a -O2 diagnostics self-compile, above its 3% ceiling. Every
  e2e program, component suite and runtime probe runs strict, so they all
  still recount.
- **The stale probes are driven, not deleted.** `test/test_common/test_codegen/test_runtime/string_suite.brp`
  runs `string_test.c`, `string_concat_test.c` and the new
  `string_codepoints_test.c`. The revived concatenation probe caught
  `from_bytes` counting a negative length's bytes before allocation could
  refuse it, which L1 fixes.

**Non-ASCII text reaches every writer** under strict runs. Literals,
concatenation, the in-place append, interpolation, `slice`, `next_lines`,
argv, directory names, `read_text` and `bytes_to_text` already had it. L1
adds it to capture (the probe child's streams), `find_program` (the
directory it finds), the current directory and a temporary directory's
prefix.

**A broken writer fails.** With the in-place append's
`left->code_points+=suffix_code_points` removed:
- the String runtime suite fails 9 of its 76 cases, at their count
  assertions;
- `string_operations/concat_reuse`, compiled by that test compiler, prints
  its first line and aborts with `error: target String code point count
  disagrees with its bytes` (exit 134);
- a test driver compiled by that compiler aborts the same way.

With the recount disabled instead, only the suite's `wrong count faults at
release` case fails.

**Costs.** Measured 2026-11-12 on an Apple M4 (macOS 26.7.1, Apple clang
21.0.0), base `7ddaebf32`, candidate `d3af35192`:
- **Stage 2,** as in S0. Each tree's seed-built compiler emits its own
  compiler with its own runtime. clang links that at -O2 with
  `-DBLORP_MEMORY_DIAGNOSTICS=0` and `=1`, and at -O0 with `=1` (the test
  compiler's flags). Every binary compiles the base tree's `main.brp` and
  library.
- **Rounds:** five, alternating sides, for each -O2 variant; one for each
  -O0 variant.
- **Peak heap:** both trees carried the same uncommitted probe for peak live
  requested bytes.

| Variant | Metric | Base | Candidate | Change | Ceiling |
| --- | --- | --- | --- | --- | --- |
| -O2, no diagnostics | instructions | 12.249 G | 12.290 G | +0.34% | +0.5% |
| -O2, diagnostics | instructions | 13.716 G | 13.813 G | +0.70% | +3% |
| -O2, diagnostics, strict | instructions | 13.718 G | 14.423 G | +5.14% | none: strict only |
| -O0, diagnostics | instructions | 43.376 G | 43.584 G | +0.48% | none |
| -O0, diagnostics, strict | instructions | 43.356 G | 51.065 G | +17.78% | L2's 15% e2e margin |
| diagnostics, strict | allocations | 14,070,305 | 14,070,306 | +1 | +50 |
| diagnostics, strict | peak heap | 162,756,577 B | 162,936,818 B | +0.11% | +0.3% |

- **Stage 1** (`scripts/self-compile-cost 7ddaebf32 d3af35192`, 11 rounds):
  the compiler-side change costs nothing measurable. Fixed input: +1
  allocation, -0.04% instructions. Own source: +0.18% allocations and +0.15%
  instructions, from the larger source.
- **Output identity.** The emitted C for the fixed input differs only in the
  runtime text and in the renamed `blorp_string_byte_length` and
  `blorp_string_byte_slice` calls.
- **Production lines:** +178 net (`blorp/src` +226, -48):
  - the header and writers, +22;
  - S9, +15;
  - the labels and operations, +141 (+35 of it runtime C).

  The estimate before coding was +157. Test lines: +812 net.
- **Raw samples** are under `blorp/build/string-codepoints-l1-cost/` in the
  L1 worktree.

**The risk this leaves for L2.** The e2e harness runs every timed compile
under `BLORP_LEAK_CHECK=strict` (it reads the allocation report), so once
L2's seed carries S9, a timed compile pays about the -O0 strict row's 18%.
Limiting S9 to strict runs does not keep L2 within the 15% margin. Ways out,
for the coordinator and Keith:
- (a) a cheaper count, such as eight bytes per step;
- (b) time e2e compiles without strict, with the allocations from a second
  run;
- (c) a separate opt-in for the recount;
- (d) new e2e ceilings at L2.

The coordinator's recommendation (2026-11-12): try (a) before L2. Counting
eight bytes per step changes no decision and no interface; re-measure the
-O0 strict row. Bring (b), (c) or (d) to Keith only if (a) still leaves L2
over the 15% margin; (d) would break the rule above that L2 raises no
ceiling.

**Recount (2026-11-12, `blorp/string-recount`).** `blorp_utf8_code_points`
now counts continuations eight bytes per step: a byte is a continuation when
its bit 7 is set and its bit 6 is clear, so `word & ~(word << 1) & 0x80...80`
marks them, and a multiply by `0x01...01` sums the marks into the top byte.
The tail is a per-byte loop with no call. This is plain C11 (no
`__builtin_popcountll`; the runtime has no precedent for builtins). One
function serves the strict recount and `from_bytes`. The suite's
`word_count` case checks lengths 0, 1, 7, 8, 9, 15, 16 and 17, and scalars of
every width starting at every offset in a word, against the per-byte count.
So do words made only of continuation bytes, and invalid bytes (`0xff`,
`0xc0`) mixed with continuations at every prefix length. Production +18 net
lines.

The L2 reproduction (fixpoint stage B at -O0 with diagnostics,
`make -C blorp test-e2e INSTRUCTION_CHECK=on BLORP_TEST_COMPILER=<stage_b>`):

| Case | Ceiling | Before | After |
| --- | --- | --- | --- |
| `source_loops/nesting` | 565,332,965 | 664,939,712 | passes |
| the 6.2 G harness compile | 6,215,987,687 | 6,811,050,507 | passes |
| `fs_lines` | 1,196,778,594 | 1,286,899,142 | passes |
| `fs_directories` | 1,347,097,145 | 1,435,575,057 | passes |
| `path_join/arguments` (`strings.brp:1022`) | 574,758,593 | 589,617,289 | 575,586,952 to 578,115,851 |
| `path_join/aliases` | 570,000,000 | 583,219,072 | 570,826,670 to 570,977,539 |

Failing ceilings fell from 17 in 4 tests to 2. With the recount off the
`path_join/aliases` compile measures 569.5 M against its 570 M ceiling and
run-to-run noise is about 0.1%, so what remains is the count's own upkeep
(+0.48%) plus a recount of about 0.3%. A zero-padded word for the tail
(no byte loop) measured no better. A third run also took `path_parent/edges`
0.15% over. Once `203541220` reset those three ceilings (see "Keith's
ruling"), the reproduction passed on the rebased commit: 236 of 236 tests,
with no ceiling exceeded.

Costs, measured 2026-11-12 on an Apple M4 against origin/main `95f37e437`
(the candidate is the commit before its review fixes, whose runtime text
differs only in a constant's name and two comments). Stage 2 as in S0: each
tree's seed-built compiler emits its own compiler, clang links it, and every
binary compiles the base tree's `main.brp` and library; five rounds,
alternating sides, medians:

| Variant | Metric | Base | Candidate | Change |
| --- | --- | --- | --- | --- |
| -O2, no diagnostics | instructions | 12.387 G | 12.374 G | -0.10% |
| -O2, diagnostics | instructions | 13.851 G | 13.827 G | -0.17% |
| -O2, diagnostics, strict | instructions | 14.470 G | 14.083 G | -2.67% |
| -O0, diagnostics | instructions | 43.875 G | 43.752 G | -0.28% |
| -O0, diagnostics, strict | instructions | 51.381 G | 44.631 G | -13.14% |
| diagnostics, strict | allocations | 14,130,124 | 14,130,124 | identical |

A strict -O0 compile now costs +2.0% over the same compile without strict
(it was +17.1%). `self-compile-cost origin/main HEAD --rounds 5` (stage 1):
fixed input +0 allocations and +0.019% instructions; own source +17
allocations and +0.014% instructions. Raw samples:
`blorp/build/string-recount-cost/` in the recount worktree.

**A coordinator ceiling correction at landing.** The fs write program's
compile allocation ceiling rose from 222,217 to 222,218, because the branch
measures one allocation more than main at the same path. These counts also
grow with the checkout's depth, by about four per directory level (the
compiler's `Path.normalize` allocates one String per component), so in a
deep worktree both main and this branch exceed two exact ceilings that CI
meets.

**Keith's ruling, 2026-11-12: two e2e instruction ceilings reset to measured
+15% before L2.** In the L2 reproduction (fixpoint stage B as the test
compiler), only `path_join/aliases` and `path_join/arguments` stay over once
the recount counts eight bytes per step, by 0.14% to 0.6%. Neither ceiling
had the harness's 15% margin: UInt8 L3 had scaled both by its own growth, so
whatever margin they had before carried over unchanged. Main's own test
compiler, without the recount, measured them at:

| Program | Old ceiling | Main's median (5 strict runs at `95f37e437`) | New ceiling |
| --- | --- | --- | --- |
| `path_join/aliases` | 570,000,000 | 569,342,696 | 654,744,100 |
| `path_join/arguments` | 574,758,593 | 573,717,398 | 659,775,008 |

One `arguments` run on main already measured 574,858,510, over its old
ceiling. The new ceilings are main's medians plus 15%, set in their own
commit before L2, so L2 still raises no ceiling. The samples are under
`build/measurements/string-recount-l2-probe-2026-11-12/` in the main
checkout.

**Coordinator correction, same day: `path_parent/edges` 576,844,537 →
659,963,073.** A third stage-B run took it 0.15% over (577,734,836). L3 had
scaled it the same way, and main measures it at a median of 573,880,933, only
0.52% under its ceiling. It is the only other ceiling that both failed the
reproduction and sits under 1% from main's cost, so the coordinator gave it
the same reset under the standing budget delegation. The other ceilings L3
scaled that were measured stay as they are, because all pass the
reproduction: `path_normalize/edges` sits 1.47% under its ceiling, `fs/write`
3.6%, `string_slice/bounds` 9.7% and `uint8/values` 18.3%.

**Checkout depth, resolved 2026-11-12.** Keith chose a fast path in
`normalize` over a named allowance on allocation ceilings and over fixed-depth
harness paths. An already normal spelling (nonempty, `/` alone or components
that are nonempty and neither `.` nor `..`) comes back unchanged after a byte
scan, so it costs no allocation. A test in `driver/harness.brp` compiles one
program from two directories eight levels apart and expects equal strict
allocations. Main gave 112,097 and 112,121; the change gives 112,044 at both.
Keith accepted the cost, asked as "about +4.6k compile allocations for
programs importing path": every program that imports `path` compiles the
larger `path.brp`, so it pays about 4,650 more compile allocations. Programs
that don't import it, such as hello world, do not. The brief capped
production growth at +40 lines; the change is +58, about +51 before
formatting. The coordinator accepted the overrun, since it is the scan Keith
approved. Self-compile against `525b653c2`: fixed input -59 allocations and
-0.007% instructions with identical C; own source +9,040 allocations
(+0.064%) and +0.021% instructions. At runtime, the `path_normalize/edges`
run pins for normal spellings fall to 3 allocations:
- `/foo/bar` from 13;
- `.../..x/x..` from 12;
- `ab/leaf` and `é/leaf` from 11;
- `ab` and `é` from 10;
- `/` from 7.

The surviving-aliases case falls from 34 to 30.

The change moved these ceilings:
- **Allocation ceilings, each raised by the measured increase** (same-depth
  main against the change), so each keeps its headroom:
  - fs/read 222,197 → 226,851 (+4,654);
  - fs/write 234,300 → 238,950 (+4,650);
  - fs/directories 420,003 → 424,653 (+4,650).
- **Instruction ceilings, reset to the change's median of 3 plus 15%:**
  - fs/lines 1,196,778,594 → 1,388,425,179 (main's median was 1,193,005,705,
    0.3% under its old ceiling);
  - fs/directories 1,347,097,145 → 1,557,742,393;
  - `path_normalize/edges` 605,108,277 → 723,191,280.

## Landings

1. **S0, a spike** that never lands (done). It measured the stored count's
   cost on a stage-2 self-compile; see "S0 results".
2. **L1, the compiler learns the operations.** No library or behaviour
   changes.
   - The runtime header gains `code_points`, and every writer maintains it.
   - S9's recount on release.
   - The labels `string.byte_length`, `string.byte_slice`,
     `string.codepoint_length`, `string.codepoint_slice` and
     `string.codepoint_at`, in the parser's list, the namespace builtins and
     emit.
   - Each label gets its own runtime operation beside `StringLength` and
     `StringSlice` (`namespace/builtins.brp`, mapped in `emit.brp:264-279`).
   - Nothing calls the labels yet, and every program's output is unchanged.
   - **Tests:**
     - S9 checks the count across every existing e2e program.
     - New fixtures push non-ASCII text through every writer: literals,
       concatenation, in-place append, interpolation, `slice`, `read_text`,
       `next_lines`, directory names, argv, process capture and the current
       directory.
     - The new C functions have no Blorp caller until L3, so a runtime suite
       tests them directly in C. It follows `test/test_common/test_codegen/test_runtime/string_literal_suite.brp`,
       which writes `string_runtime()` beside a C fixture and compiles them
       together.
   - **Compile ceilings.** The e2e records' `{ allocations, instructions }`
     are compile ceilings for the seed-built test compiler, so L1 does not
     move them. They move at L2, when the compiler itself carries the count
     and S9's recount (the test compiler is a diagnostics build). L2 must pass
     `make -C blorp test-e2e INSTRUCTION_CHECK=on` within their 15% margin
     without raising any ceiling. If it cannot, S9 runs only under
     `BLORP_LEAK_CHECK=strict` (see "Ceilings").
3. **L2, a seed rotation.** It can share PATH landing 5's rotation, and the
   language server's console natives, if they are on main first. Otherwise
   it is a plain rotation.
   - **Done, 2026-11-12.** A plain rotation. The pin names
     `blorp-seed-15d8d1263e10`, which main's CI built from the recount's
     commit `15d8d1263`. `make -C blorp test-e2e INSTRUCTION_CHECK=on` passes
     with the seed-built test compiler and no ceiling raised.
4. **L3, the switch, one breaking landing** (principle 14, no shims).
   - **First, a census.** Grep every String `length()`, `byte_at` and
     `.slice(` under `blorp/src`, `blorp/scripts`, `blorp/standard_library`,
     `blorp/test` and `examples`. Classify each call as bytes or characters,
     and attach the list to the brief before any edit.
   - **Library:**
     - `string.brp` takes S3's API, and `hash` folds over `byte_length`;
     - `json.brp` changes its offsets (S8);
     - `path.brp`, `io/fs.brp` and `io/process.brp` move their byte work to
       the `byte_*` functions.
   - **Compiler and scripts:**
     - every byte use moves to `byte_*`, including
       `scripts/embed_library.brp`;
     - `display_width` and `render_file_location` (S7) change as shown under
       "Code".
   - **Labels:** `string.length` and `string.slice` are deleted, with their
     `StringLength` and `StringSlice` operations and their C functions.
   - **Tests:** the byte-length expectations change. `string_literal/unicode`,
     `unicode_escapes` and `union` go from 6 to 2; `tail_arms` from 7 to 6;
     `normalization` from 5 to 3. `fs/lines.brp` and its harness
     expectation (`harness.brp:95-98`) are rewritten around
     `length` and `byte_length`, and `test_json.brp:401-402` moves to
     `byte_length`. Each test that indexes by byte moves to `byte_*`. The
     census names these, among them:
     - `test/support/text_search.brp`;
     - `test_embed_library.brp`;
     - the lexer and format suites;
     - `test/test_common/test_codegen/test_runtime/process_suite.brp`.
   - **Docs:** `README.md` "Strings" and "String operations", `grammar.ebnf`
     (lines 77-79, 225, 290, 298, 598) and `standard_library/README.md`.
5. **L4, later and only on demand:** an `Ascii` type (S5) and a code-point
   index (S6).

## Ceilings

Approved by Keith on 2026-11-10. Each is measured on a stage-2 compiler
against its parent commit, interleaved, as in S0.

| Landing | Instructions, self-compile | Allocations | Peak heap | Production lines |
| --- | --- | --- | --- | --- |
| L1 | at most +0.5%, in a `-DBLORP_MEMORY_DIAGNOSTICS=0` build | at most +50 | at most +0.3% | at most +200 net |
| L1, S9's recount | at most +3%, in a diagnostics build | +0 | +0 | included above |
| L3 | at most +0.5% | at most +0.1% | at most +0.3% | at most +100 net; test lines reported separately |

- **The L1 instruction ceiling** leaves room for the label plumbing above
  S0's +0.16%.
- **S9's recount** runs only in diagnostics builds. That includes the test
  compiler once L2's seed carries it, so its cost there is capped too. If it
  exceeds +3%, it runs only under `BLORP_LEAK_CHECK=strict`.
- **The e2e compile ceilings** have a 15% margin and absorb these costs.
- **The line ceilings are estimates:** S0's runtime change was 27 changed
  lines. Recalibrate them at the start of L1, before writing code, and report
  the recalibrated figures before continuing.

## Scope and non-goals

- Not in scope: grapheme clusters; normalization (text is never
  normalized); a `Char` type; UTF-16 helpers (the language server writes its
  own); display width for wide or zero-width characters (the formatter keeps
  counting code points).
- Found, not fixed: `test/test_common/test_codegen/test_runtime/fixtures/string_test.c` and
  `string_concat_test.c` were referenced by no suite or Makefile rule, so they
  never ran. L1 drives them from `test/test_common/test_codegen/test_runtime/string_suite.brp`. L1 found
  that `argv_test.c`, with its `aggregate_runtime_test.h`, runs nowhere
  either; it is left for a later change.
- Concurrent work:
  - The Bytes plan's L4 edits the same `byte_at` call sites. Whichever lands
    second rebases; the conflict is mechanical.
  - PATH landing 1's naming rules apply to every new name here, and they
    already fit.

## Risks and unknowns

- **A missed writer.** Any C that fills a String's bytes after
  `blorp_string_allocate` must set the count. S9 is the guard, and L1's
  fixtures route non-ASCII text through every writer the census found.
- **Meaning drift at the switch.** A compiler `length()` call on non-ASCII
  text that means bytes but is not renamed changes silently. L3 renames by
  phase owner, not by search-and-replace. The compiler's observable text
  handling must not move, apart from S7's columns:
  - formatting the repository gives identical output;
  - lexer spans are identical;
  - every e2e diagnostic is identical, except a column on a line with
    non-ASCII text before the error.

  Any other difference is a missed rename.
- **The fixpoint.** Stage B (built by the L2 seed) and stage C must agree
  after L3. Never reusing a label is what keeps them agreeing.

## Testing

- **L1:**
  - S9's recount runs under every e2e program and unit suite.
  - Non-ASCII fixtures cover each writer.
  - A runtime C suite calls the new functions directly. It covers each one
    on ASCII, non-ASCII and empty text, `codepoint_slice`'s clamping, and
    `byte_slice`'s `None` inside a character.
  - Compiler unit tests accept the new labels and reject a misspelled one.
  - A deliberately broken writer (one that skips its count) must fail S9 in
    its fixture.
- **L3:**
  - e2e fixtures cover `length`, `byte_length`, `slice`'s clamping (negative
    start, end past `length`, `start > end`), `codepoint_at` on ASCII and
    non-ASCII text, `codepoints`, `is_ascii`, and `byte_slice`'s `None`
    inside a character.
  - S7's column has a diagnostic test on a line with non-ASCII text before
    the error.
  - S8's offset has a JSON test with `é` before the failure.
  - `hash` has a test with two non-ASCII Strings that differ only in their
    last byte, which must hash differently.
- **Commands:** iterate with the owning unit suite or fixture. Before review,
  run `make -C blorp test`, `make -C blorp test-compiler` and then
  `make -C blorp test-e2e INSTRUCTION_CHECK=on`,
  `bash blorp/test/test_bootstrap/test_bootstrap.sh` and `scripts/blorp-fixpoint --prove`.

## Acceptance criteria

- [ ] **L1:**
  - Every existing program's output and exit code are unchanged.
  - S9 passes on every e2e program.
  - The stage-2 costs are within the ceilings.
  - A broken writer fails its fixture.
- [ ] **L2:** the rotated seed builds the compiler, and the fixpoint proves.
- [ ] **L3:**
  - The Problem's program prints `5` and `hé`.
  - `make -C blorp format-check` passes unchanged, and every e2e diagnostic
    expectation is unchanged, except S7's non-ASCII column tests.
  - All gates pass, and the fixpoint proves.
  - `grep -rn '"string.length"\|"string.slice"' blorp/src blorp/standard_library`
    finds nothing.

## Handback

Each landing returns:
- its commit;
- the gate logs' paths;
- stage-2 self-compile instructions, allocations and peak heap, before and
  after;
- production and test line counts, reported separately.

Stop and ask Keith when:
- a ceiling fails;
- a writer cannot keep the count without rescanning;
- a compiler call site's unit is unclear;
- L3 changes formatter output, a lexer span, or a diagnostic other than S7's
  columns.
