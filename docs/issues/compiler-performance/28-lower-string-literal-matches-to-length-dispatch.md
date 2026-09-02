# Lower String Literal Matches To Length-Aware Dispatch

**Status:** Proposed

## Objective

Make a `match` with multiple string-literal cases select candidates by string
length before performing byte comparisons. Apply the optimization generally in
compiler-owned Core/C lowering so lexer keyword recognition and every other
Blorp string-literal match benefit without a hand-written lexer lookup table.

The scrutinee must still be evaluated once. Source case behavior, fallback
bindings, ownership, branch bodies, diagnostics, and non-string literal matches
must remain unchanged.

## Why This Issue Exists

The lexer recognizes keywords with one source-level match containing roughly
48 string literals. Current generated C is a linear chain:

```c
if (blorp_string_compare_bytes(text, "func", 4L) == 0) {
    ...
} else if (blorp_string_compare_bytes(text, "pure", 4L) == 0) {
    ...
} else if (...) {
    ...
}
```

A normal identifier can execute every comparison before reaching the fallback.
`blorp_string_compare_bytes` compares `min(value_length, literal_length)` bytes
before it checks which string is longer. Therefore even literals of impossible
length can call `memcmp`.

Native Stage 01-04 sampling places `_platform_memcmp` and
`blorp_string_compare_bytes` among the largest leaves. Lexing currently costs a
median 583.623 ms and 48.28% of the early frontend. The compiler source contains
many non-keyword identifiers, so the worst-case fallback is common.

This is a compiler lowering deficiency, not a property unique to keywords.
Encoding a trie, hash table, or length buckets manually in `lexer.brp` would
duplicate information already present in a literal match and would leave every
other program with the same poor lowering.

## Required Lowering

### Eligibility

Use length-aware dispatch only when:

- the Core node is `LiteralMatchExpr` or the corresponding prepared literal
  match form already handled by the backend;
- every explicit case literal is `StringLiteral`;
- there are enough distinct cases to justify dispatch; begin with a named
  constant such as `MIN_STRING_LENGTH_DISPATCH_CASES`, measured rather than
  magic; and
- the existing emitter can produce every branch and fallback normally.

One- and two-case matches may retain the current direct chain if generated size
and benchmarks show it is cheaper. Mixed literal kinds and unsupported shapes
must use the existing path.

### Dispatch Shape

The preferred output computes the string length once and selects only literals
of that length. One acceptable structure is:

```c
long match_case = -1;
switch (text->len) {
case 2:
    if (memcmp(text->data, "in", 2) == 0) match_case = 8;
    else if (memcmp(text->data, "if", 2) == 0) match_case = 9;
    break;
case 4:
    if (memcmp(text->data, "func", 4) == 0) match_case = 0;
    else if (memcmp(text->data, "pure", 4) == 0) match_case = 1;
    break;
default:
    break;
}

switch (match_case) {
case 0: ...; break;
case 1: ...; break;
default: ...fallback...; break;
}
```

Equivalent structured C is acceptable. The essential properties are:

1. length is loaded once;
2. literals of other lengths perform no byte comparison;
3. literals sharing a length retain their source order;
4. each branch body is emitted once;
5. the fallback is emitted once;
6. temporary names remain deterministic; and
7. generated code grows only linearly with cases.

If direct `memcmp` is emitted after exact length equality, zero-length and null
handling must match current string semantics. Prefer a small runtime helper such
as `blorp_string_equal_bytes` when it provides one authoritative null/length
contract. That helper must check exact length before reading bytes. Do not use
`blorp_string_compare_bytes` after the length has already selected the case.

### Where To Implement

Start in `blorp/src/compiler/stage_10_backend/emit.brp`, around
`emit_literal_match_statement`, `emit_tailrec_literal_match_statement`, and
`c_literal_match_test`. Reuse a common private dispatch builder for ordinary and
tail-recursive literal matches; do not allow the two emitters to drift.

If backend-only construction becomes awkward because eligibility or grouping
must be recomputed in several paths, introduce one explicit prepared dispatch
record local to Stage 10. Do not add a broadly visible Core node unless an
earlier pass genuinely needs the distinction.

## Semantic Requirements

- Evaluate the scrutinee exactly once and before any case selection.
- Preserve first matching case behavior. Duplicate literal cases should already
  be rejected or normalized; nevertheless, grouping must preserve source order
  within equal-length cases.
- Preserve fallback bindings and their borrow/own modes.
- Preserve branch-local cleanup, returns, tail recursion, cancellation cleanup,
  and result initialization.
- Handle embedded NUL bytes using explicit lengths.
- Never call `memcmp` with a null data pointer, including zero-length strings.
- Preserve non-exhaustive match failure text and location behavior.
- Do not change ordering comparisons such as `<` or `>`; this issue is equality
  dispatch for literal patterns only.
- Generated names and grouping order must be deterministic. Use first-seen
  length order or sorted numeric length order and test the chosen rule.

## Test-First Plan

Extend `blorp/test/compiler/stage_10_backend/test_core_emit.brp` before changing
the emitter. Add Core fixtures covering:

- at least eight strings across several lengths;
- multiple strings sharing one length;
- no matching case;
- a fallback binding;
- a value-returning match and a void match;
- a tail-recursive match position;
- empty and embedded-NUL literals; and
- a small match that stays on the direct path when a threshold is used.

The structural test must prove:

- one length load;
- a length switch or equivalent bounded dispatch;
- no byte comparison for a different-length bucket;
- one copy of every branch body and fallback;
- stable case ordinals; and
- absence of the old 48-comparison-shaped chain in the keyword probe after the
  integrated build.

Add or identify a runtime compiler test that executes all cases and the
fallback. Generated-C assertions alone do not prove control flow.

If a runtime helper is added, add a native/runtime-focused test for null,
empty, embedded-NUL, equal, unequal-same-length, and unequal-length inputs.

## Fast Feedback Loop

This issue changes the compiler emitter, so repeatedly rebuilding the compiler
would be wasteful. Exercise the edited emitter directly through its existing
Blorp test:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_10_backend/emit.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

That test imports the working-tree emitter and calls
`emit_unprojected_core_program_c_artifact_for_tests`; its in-memory C artifact
reflects candidate logic even though `bin/blorp` was built earlier.

Create an ignored `scratch/string_literal_dispatch_probe.brp` containing:

- a keyword-sized match with the exact current keyword count and length
  distribution;
- a mostly-miss input corpus;
- a mixed hit corpus; and
- a deterministic sum of returned case identifiers.

Before the integrated build, use the focused emitter test to generate and
inspect its equivalent Core shape. After one final `make`, compile the source
probe and inspect its generated C:

```bash
probe_c=$(mktemp "${TMPDIR:-/tmp}/blorp-string-dispatch.XXXXXX.c")
bin/blorp compile --no-format --no-embed-runtime \
  -o "$probe_c" scratch/string_literal_dispatch_probe.brp
rg -n 'match_case|switch|memcmp|string_compare_bytes' "$probe_c"
rm -f "$probe_c"
```

Benchmark one warmup and at least seven alternating baseline/candidate runs of
the native probe. Record hit distribution, checksum, elapsed time, generated C
bytes, and binary bytes.

Only after the focused emitter and runtime tests pass should `make` be run.
Then measure lexer time and Stage 01-04 time against `blorp/src/main.brp`; do not
use total compiler time.

## Expected Results

For an identifier whose length has no keyword bucket, expected byte comparisons
fall from as many as 48 to zero. For a populated length, comparisons fall to the
number of keywords in that bucket. Keyword hits remain bounded by the bucket,
not by their position in the full declaration.

Expected observable results are:

- a large reduction in `blorp_string_compare_bytes`/`memcmp` calls in the
  mostly-miss probe;
- a measurable improvement in keyword classification and compiler lexing;
- unchanged allocation counts, except for removal of any helper-created
  temporary accidentally discovered during implementation; and
- linear, controlled generated-C growth.

The current profile does not isolate all string comparisons to the lexer, so no
exact percentage is promised. If the focused comparison count falls but lexer
time does not, retain the general lowering only if the focused benchmark and
generated code-size result justify it.

## Implementation Order

1. Add failing generated-C and runtime tests.
2. Add a private eligibility and grouping representation.
3. Emit deterministic length/case selection for ordinary matches.
4. Share the selection builder with tail-recursive matches.
5. Add the exact-length runtime helper only if needed.
6. Verify fallbacks, bindings, returns, NULs, and cleanup paths.
7. Benchmark the source probe and measure generated size.
8. Rebuild once and inspect the real `keyword_for` output.
9. Reprofile lexing and Stages 01-04.

## Acceptance Criteria

1. Eligible multi-case string literal matches dispatch by exact length first.
2. Impossible-length literals perform no byte comparison.
3. Scrutinee, branches, and fallback preserve evaluation and ownership
   semantics.
4. Ordinary and tail-recursive match paths share one dispatch policy.
5. Empty, NUL-containing, same-length, different-length, and null-safe runtime
   behavior is tested.
6. Keyword generated C no longer contains one full linear comparison chain.
7. Focused before/after comparison counts and timings are reported.
8. Generated C and native binary size are reported and remain linear.
9. `test_core_emit`, relevant runtime tests, `scripts/compiler-check --changed`,
   and one final relevant full gate pass.
10. Fresh Stage 01-04 lexer and total medians are reported.

## Out Of Scope

- hand-writing a lexer-only trie or hash table;
- allocating a dictionary during keyword lookup;
- changing language keywords or string-match semantics;
- optimizing relational string comparisons;
- parser token access;
- token representation changes; and
- whole-program perfect-hash infrastructure.

## Implementation Report Requirements

Include the dispatch representation and threshold rationale, exact comparison
counts for each probe distribution, all timing samples, source/compiler/runtime
hashes, generated C and binary sizes, representative before/after C, runtime
and focused test totals, Stage 01-04 results, and any cleanup or tail-position
rough edge found.
