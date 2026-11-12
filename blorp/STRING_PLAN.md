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
results"). L1 has not started.

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
       tests them directly in C. It follows `test/runtime/string_literal_suite.brp`,
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
     expectation (`self_hosted_harness.brp:95-98`) are rewritten around
     `length` and `byte_length`, and `test_json.brp:401-402` moves to
     `byte_length`. Each test that indexes by byte moves to `byte_*`. The
     census names these, among them:
     - `test/unit/text_search.brp`;
     - `test_embed_library.brp`;
     - the lexer and format suites;
     - `test/runtime/process_suite.brp`.
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
- Found, not fixed: `test/runtime/fixtures/string_test.c` and
  `string_concat_test.c` are referenced by no suite or Makefile rule, so they
  never run. L1 should either drive them from its new runtime suite or
  delete them.
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
  `bash blorp/test/tooling/test_bootstrap.sh` and `scripts/blorp-fixpoint --prove`.

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
