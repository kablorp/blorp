# Lower String Literal Matches To Length-Aware Dispatch

**Status:** Implemented

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

## Implementation Report

### Lowering

Stage 10 now builds a private `StringLiteralDispatchPlan` for a literal match
when all explicit cases are strings, there are at least four cases, and the
cases occupy more than one byte length. The plan retains first-seen length
order and source order inside each length bucket. Ordinary literal matches,
tail-recursive literal matches, and prepared constructor-payload literal
matches share the same selection and branch-dispatch emitters. Small matches,
single-length matches, and mixed literal kinds retain the direct chain.

The threshold is `MIN_STRING_LENGTH_DISPATCH_CASES = 4`. The four-case probe
is the smallest measured dispatched workload. Balanced lengths improved both
hit and miss cases materially. A skewed three-plus-one distribution was neutral
for its populated bucket and added at most 0.99 ns per classification for its
exceptionally cheap direct-path inputs. Keeping one through three cases direct
avoids the length switch and two temporaries for short chains. Requiring
multiple lengths also avoids a length switch that cannot reject any candidate.

Generated selection loads the nullable scrutinee length once, using `-1` for a
null string, and then compares only the selected bucket with length-bounded
`memcmp`. A zero-length bucket selects its first source case without calling
`memcmp`, so no null data pointer is passed to the C library. The ordinal branch
chain emits each existing branch body and fallback exactly once; ownership,
fallback-binding, cleanup, and tail-return emitters remain unchanged. The
ordinal branch layer is an `if`/`else if` chain rather than a second C switch,
so a source-level `break` still targets its enclosing loop.

### Focused Probe

The ignored `scratch/string_literal_dispatch_probe.brp` contains four-case,
eight-case, and exact 47-keyword classifiers. Seven alternating baseline and
candidate pairs ran 5,000,000 classifications per row. All paired checksums
matched. The measured loop reported zero allocations, releases, retained
objects, and allocator bytes for both workers.

| Input pair | Checksum | Modeled baseline comparisons | Modeled candidate comparisons | Baseline us | Candidate us | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 cases: absent length / same-length miss | 0 | 20,000,000 | 2,500,000 | 57,595 | 11,941 | -79.27% |
| 4 cases: first / fourth hit | 12,500,000 | 12,500,000 | 5,000,000 | 36,531 | 11,783 | -67.75% |
| 8 cases: absent length / same-length miss | 0 | 40,000,000 | 5,000,000 | 110,735 | 11,876 | -89.28% |
| 8 cases: third / seventh hit | 25,000,000 | 25,000,000 | 5,000,000 | 70,160 | 11,281 | -83.92% |
| 47 keywords: absent length / 4-byte miss | 0 | 235,000,000 | 25,000,000 | 622,109 | 11,492 | -98.15% |
| 47 keywords: first / last hit | 120,000,000 | 120,000,000 | 27,500,000 | 308,197 | 59,321 | -80.75% |
| 47 keywords: 10-byte miss / 5-byte hit | 105,000,000 | 222,500,000 | 25,000,000 | 598,914 | 57,154 | -90.46% |

Raw elapsed-microsecond samples, in run order, were:

| Input pair | Baseline samples | Candidate samples |
| --- | --- | --- |
| 4 cases: absent / same-length miss | 64041, 57709, 57938, 55559, 55845, 56004, 57595 | 11151, 10736, 11995, 11998, 11577, 11941, 11953 |
| 4 cases: first / fourth hit | 35132, 36531, 36794, 36257, 36363, 36583, 39073 | 11783, 10676, 10763, 12436, 12850, 12000, 11761 |
| 8 cases: absent / same-length miss | 107109, 111934, 113831, 110735, 109639, 112848, 109575 | 11783, 12074, 11620, 11929, 11876, 10958, 12527 |
| 8 cases: third / seventh hit | 69158, 72367, 71313, 70160, 68687, 69932, 70623 | 11281, 11961, 10929, 11215, 10757, 12016, 11991 |
| 47 keywords: absent / 4-byte miss | 622109, 638823, 621367, 616238, 618066, 630316, 626356 | 11191, 11492, 11974, 10812, 11957, 11966, 10690 |
| 47 keywords: first / last hit | 299046, 304741, 309495, 310754, 308298, 308026, 308197 | 57627, 59236, 60218, 59321, 83462, 59419, 59045 |
| 47 keywords: 10-byte miss / 5-byte hit | 604030, 598590, 597490, 598914, 618827, 607512, 592743 | 57573, 55733, 57332, 57170, 57154, 55767, 55924 |

The comparison columns are deterministic workload models derived from source
case positions and bucket positions; they are not runtime instrumentation.
Every raw timing sample is in
`logs/issue28-string-dispatch/probe-samples.tsv`, with the medians in
`probe-summary.tsv`.

A follow-up threshold probe exercised the most skewed eligible four-case shape:
three literals in one length bucket and one literal in another. It used the
same baseline and candidate workers, one warmup, and seven alternating pairs of
5,000,000 classifications. Checksums, lengths, and all zero allocator counters
matched exactly. The direct path remained slightly faster for the singleton
hit and absent-length cases, where its first mismatching byte made each old
comparison exceptionally cheap; the largest absolute regression was 0.99 ns
per classification. The populated three-literal bucket was neutral.

| Skewed 3+1 input | Checksum | Baseline samples (us) | Candidate samples (us) | Median change |
| --- | ---: | --- | --- | ---: |
| first / third same-bucket hit | 10,000,000 | 31408, 31990, 33619, 32105, 31123, 30611, 31012 | 31298, 32077, 31704, 32955, 32755, 31471, 32866 | +2.13% |
| same-length miss | 0 | 40100, 40412, 40687, 41398, 42293, 41759, 42388 | 38895, 41326, 40656, 40341, 41885, 44354, 41833 | -0.17% |
| singleton-bucket hit | 20,000,000 | 7089, 6126, 7206, 7248, 7245, 6142, 7204 | 11152, 12248, 11152, 12408, 12187, 12148, 11080 | +68.63% (+0.99 ns/classification) |
| absent-length miss | 0 | 3762, 3776, 3713, 3665, 4787, 4820, 3705 | 5883, 5887, 4769, 4963, 5953, 5989, 6027 | +56.49% (+0.43 ns/classification) |

The skewed probe source SHA-256 is
`d6209e0573f3ed76d656077ac1a33502ff495f8e78d350355cbd67fe5d00b699`.
Its baseline/candidate generated-C SHA-256 values are
`b4e15f5cd35c6dc6a48b680440f8759180394a5a1ad0c7f33b3f2817c5e15f35`
and `beedf829c0b967ed857f4776e631d69615e0b74129c942f7068620daa77a984e`;
binary values are
`6d9d563382bc6b8638165408ee1b79b64a1c8be486283c63b5de3b7c06224c85`
and `76613eebea5c70b1f02044127e8fc56077c5ec1d9ab22fc9ef6ed48c161a263d`.
Raw run order and parsed fields are under
`logs/issue28-string-dispatch/skewed-threshold/`.

The probe source SHA-256 is
`3a47761221e746a35724a74934eda95bd65daccf02ea896f0142c13a2626fac0`.
The baseline compiler was the pinned worker
`2d67214a05002f8c296be28199dcec2b613229aea071ab5d7f8301e15e9e4a62`;
the candidate compiler was
`5fd969fef98fa91fc4aa580f2d76d2d2486aa4c5c34e1f14c15a767e4a6e32a6`.
Both used Apple Clang 21.0.0 with `-O2 -fwrapv -pipe` and runtime source SHA-256
`5ded7888cf27bfbf8d7f988dea6a98f13ce3d6c7058caec174f4a55c8892cd45`.
Baseline/candidate generated-C SHA-256 values are `97bcf7842d54c32e9ca4984a5d80ad5ade48000b80b90b3c4d941a9f43809b8a`
and `40d7981edab24f2bdc39dc3097a01cb3c3785216f1661ef7fce6723a9de5cf1a`;
native binary SHA-256 values are `0d0315c4525b69e6b7ca31964515c282f055f19c7e08495f703f3c9a955c5fcb`
and `2dba4c2065c6fea0fb6fdbc0043b553f3b6573e18e55a0eca9f393b337520293`.

| Artifact | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Generated C bytes | 1,553,925 | 1,557,453 | +3,528 (+0.227%) |
| Native binary bytes | 657,192 | 657,112 | -80 (-0.012%) |

### Generated Compiler C

Both compiler workers were emitted from the same source corpus at base
`56d797c600ff4678a1437061616fbfec5e02fc83`. The pinned emitter's `keyword_for`
contains 47 sequential `blorp_string_compare_bytes` calls. The candidate
contains one length switch, 47 direct `memcmp` sites distributed across its
length buckets, a 47-arm ordinal `if` chain, and no
`blorp_string_compare_bytes` call:

```c
long __match_length_3 = __match_scrut_0 ? __match_scrut_0->len : -1L;
switch (__match_length_3) {
case 4L:
  if (memcmp(__match_scrut_0->data, "func", 4L) == 0) __match_case_2 = 0L;
  else if (memcmp(__match_scrut_0->data, "pure", 4L) == 0) __match_case_2 = 1L;
  /* same-length cases only */
}
```

The complete extracted functions and worker hashes are under the ignored
`logs/issue28-string-dispatch/frontend-workers/` directory.

### Stage 01-04 Production Workload

The unprofiled baseline and candidate workers compiled the same
`blorp/src/main.brp` source graph with `compile --ast --no-format`, stopping
before Stage 05. Separate `--profile` workers measured the compiler-owned
`stage_02_lex/lexer::lex` function. All 28 AST summaries were byte-identical,
SHA-256 `c4bce017fb6e9b2e7dff1d0a9538567fc7933ea0615bf14b0da8211d64225c39`.

| Worker | Stage 01-04 wall samples (s) | Median | Profiled lex samples (ms) | Median | Median peak RSS |
| --- | --- | ---: | --- | ---: | ---: |
| Baseline | 2.94, 3.41, 3.56, 3.37, 3.36, 3.45, 3.39 | 3.39 | 8762.996, 9103.732, 9586.876, 9184.736, 9305.904, 9161.049, 9104.368 | 9161.049 | 272,695,296 bytes |
| Candidate | 3.25, 3.05, 3.51, 3.24, 3.28, 3.27, 3.21 | 3.25 | 8846.240, 9699.393, 9013.890, 9019.504, 9114.110, 9122.353, 8923.532 | 9019.504 | 272,171,008 bytes |

Median Stage 01-04 wall time improved 4.13%, profiled lex time improved 1.55%,
and median peak RSS decreased 0.19%. Function-profile instrumentation makes
the absolute lex totals larger than unprofiled wall time; only matched profiled
workers are compared. The raw run order and samples are in
`logs/issue28-string-dispatch/frontend-workers/frontend-run-order.tsv` and
`logs/issue28-string-dispatch/frontend-workers/frontend-samples.tsv`.

Unprofiled worker SHA-256 values are
`0af0103b46cb032b8385e3dcc1fcde81e4705cfab6298ebe86cad919d534bab6`
(baseline) and
`e0141476a5f85e34815c768f587b20f3666b70bf64ec380696b573a011a20ee9`
(candidate). Profiled worker SHA-256 values are
`59d448416b0e73db34862ae8db59b1944f9166b9e4626f672abfbacd12e73ec2`
and `0cae9bace5a1a4169437dc8fc82aed5b3bd33d35c5bbc642a6dc06a7baf9fe17`.

### Verification

Focused structural coverage includes dispatched ordinary, void, tail-recursive,
and prepared constructor-payload matches; empty and embedded-NUL literals;
same-length ordering; fallback binding; deterministic ordinals; enclosing-loop
`break` with resource cleanup; and direct-path retention for small,
single-length, and mixed-kind matches. Runtime coverage executes every case,
same- and absent-length fallbacks, void branches, enclosing-loop `break`, and
tail recursion under normal, undefined-behavior sanitizer, and leak-check modes.

Final validation merged `c1653472` (`Release managed locals on loop exits`).
That Stage 09 change attaches managed-local cleanup to `break` and `continue`;
it does not alter the C construct targeted by an emitted `break`. The ordinal
`if` chain remains necessary so the cleaned-up exit reaches the enclosing loop
instead of being captured by a backend-introduced switch. With both changes
present, the Core emitter suite passed 306/306, the Core resource suite passed
14/14, and the five runtime cases passed in normal, sanitizer, and leak-check
modes (3 allocations, 3 releases, zero leaked objects and bytes).
`scripts/compiler-check --changed` passed one changed production source, two
suites, and one generated-C check. The final backend-stage gate passed 13
sources, 11 suites, and two checks with the repository-supported
`BLORP_COMPILER_SANITIZE_TEST_TIMEOUT=360`; its first default-allowance run
timed out after 199 passing sanitizer tests and reported no test or sanitizer
failure.

## Implementation Report Requirements

Include the dispatch representation and threshold rationale, exact comparison
counts for each probe distribution, all timing samples, source/compiler/runtime
hashes, generated C and binary sizes, representative before/after C, runtime
and focused test totals, Stage 01-04 results, and any cleanup or tail-position
rough edge found.
