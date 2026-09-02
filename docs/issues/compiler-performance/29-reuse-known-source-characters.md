# Reuse Known Source Characters During Cursor Advancement

**Status:** Proposed

## Objective

Remove redundant source lookups in lexer lookahead and cursor advancement.
When a scanner has already read the current character, advance the cursor from
that known character instead of indexing the source string again. When only the
next character is needed, index the next offset directly instead of constructing
an otherwise unused advanced cursor.

This is a small, general source/cursor API improvement followed by a measured
lexer migration. It must preserve all Unicode, offset, line, column, tab, span,
EOF, and diagnostic behavior.

## Why This Issue Exists

The current lexer commonly performs this sequence:

```blorp
match peek(state):
	Some(c):
		if accepts(c):
			state = advance(state)
```

`peek` calls `source_peek`; `advance` calls `source_advance`; and
`source_advance` calls `source_peek` again to decide how line and column change.
The same character is therefore bounds-checked and loaded twice.

`peek_next` has another redundant path:

```blorp
next_cursor: Cursor = source_advance(state.source, state.cursor)
source_peek(state.source, next_cursor)
```

Only the next offset matters, but this computes line and column from the current
character and performs two source reads.

Symbol emission also calls `advance_n` with a grammar-known width. That loops
through general source advancement even though every recognized symbol is a
fixed ASCII spelling.

These operations sit under `scan_identifier`, `scan_symbol_or_error`, number
scanning, and other hot paths. Current lexing is 583.623 ms of the 1.209-second
Stage 01-04 self-parse. `advance`, `scan_identifier`, and symbol scanning are
visible in native samples. The expected gain is smaller than removing a heap
allocation, but the change makes the source API clearer: reading and advancing
are separate unless the caller explicitly supplies the character already read.

## Required API

Add a helper in `blorp/src/lib/source.brp` with semantics equivalent to:

```blorp
pure func source_advance_over(cursor: Cursor, current: Char) -> Cursor:
	match current:
		'\n':
			{offset = cursor.offset + 1, line = cursor.line + 1, column = 1}
		'\t':
			{offset = cursor.offset + 1, line = cursor.line, column = ...}
		_:
			{offset = cursor.offset + 1, line = cursor.line, column = cursor.column + 1}
```

The exact name may differ, but it must state that the supplied character is the
character being crossed. `source_advance` should remain the safe convenience
operation and delegate after `source_peek`:

```blorp
pure func source_advance(src: SourceFile, cursor: Cursor) -> Cursor:
	match source_peek(src, cursor):
		Some(current): source_advance_over(cursor, current)
		None: cursor
```

This establishes one authoritative newline/tab rule. Do not duplicate tab
math across scanners.

## Lexer Migration

### Known-Character Loops

In loops that already matched `Some(c)`, replace a subsequent general advance
with `source_advance_over(cursor, c)`. Issue 26 should normally land first so
these loops operate on a local stack cursor.

Migrate one scanner family at a time:

1. identifiers;
2. numbers;
3. spaces and line comments;
4. simple delimiter scans; and
5. complex string/pipe scanners only after exact span and recovery tests exist.

Never use a stale character after another operation has changed the cursor.

### Lookahead

Change `peek_next` to direct offset lookup, preferably through the existing
`peek_at(state, 1)` helper. Prove that source offsets advance by one logical
`Char` under current `String.get` semantics. If offsets are byte offsets and a
non-ASCII current character changes the next offset by more than one, do not
make this substitution; instead add a cursor-aware lookahead primitive that
returns both the next cursor and character correctly.

The current lexer grammar recognizes ASCII identifiers and symbols, but string
and comment contents may contain Unicode. The implementation must derive the
rule from the actual string/cursor contract, not assume all source is ASCII.

### Fixed ASCII Symbols

`emit_symbol` knows both the recognized `Symbol` and source width. It may use a
private fixed-ASCII advancement helper only if:

- every call site comes from an exact grammar spelling;
- tests prove the spelling and width agree;
- the helper name and comment state the ASCII invariant; and
- invalid widths cannot silently move past unrelated source.

Prefer advancing over the one or two already-inspected characters. Do not add a
public unchecked cursor jump merely to save a tiny loop.

## Semantic Requirements

- `source_advance` remains infallible and unchanged at EOF.
- `source_advance_over` produces exactly the same cursor as
  `source_advance` when supplied the actual current character.
- Newline and tab behavior remains identical at every starting column.
- Source offsets retain their documented byte/codepoint interpretation.
- Lookahead never reads past EOF and returns the same `Option[Char]`.
- Token and diagnostic spans remain byte-for-byte identical.
- No unchecked source access, sentinel character, or magic tab width is added.
- Cooperative checkpoints remain present; Issue 31 owns their frequency.

## Test-First Plan

Add source primitive tests in the existing owner for `blorp/src/lib/source.brp`
or create a focused compiler Stage 02 source test if no owner exists. Cover:

- ordinary ASCII;
- newline;
- tabs from columns 1, 2, 4, and 5;
- EOF;
- a non-ASCII character;
- equivalence of known-character and general advancement; and
- repeated advancement across mixed text.

Extend `test_lexer.brp` with exact span tests around:

- one- and two-character symbols;
- identifiers adjacent to Unicode string/comment content;
- tabs and newlines;
- EOF lookahead;
- `r`, `raw`, and raw-string near misses; and
- malformed characters followed by valid tokens.

Create a structural test or generated-C check proving the identifier loop no
longer calls both source peek and general source advance for one accepted
character.

## Fast Feedback Loop

Use the ignored cursor probe from Issue 26 or create
`scratch/source_advance_probe.brp`. It should have two modes over the same fixed
input:

- baseline-style peek plus general advance; and
- known-character advance.

Both modes must return the same final `Cursor` checksum. Include ordinary text,
newlines, tabs, and non-ASCII characters. Run enough iterations for stable
timing, with input construction outside the measured region.

During implementation, do not rebuild:

```bash
bin/blorp check --no-format blorp/src/lib/source.brp
bin/blorp check --no-format blorp/src/compiler/stage_02_lex/lexer.brp
bin/blorp test blorp/test/compiler/stage_02_lex/test_lexer.brp
bin/blorp run --no-format scratch/source_advance_probe.brp
```

Compile the probe to a temporary C file and inspect only the two loops:

```bash
probe_c=$(mktemp "${TMPDIR:-/tmp}/blorp-source-advance.XXXXXX.c")
bin/blorp compile --no-format --no-embed-runtime \
  -o "$probe_c" scratch/source_advance_probe.brp
rg -n 'source_advance|source_peek|StackOption_Char|cursor' "$probe_c"
rm -f "$probe_c"
```

Measure one warmup and at least seven alternating runs. Record checksums,
elapsed time, and allocation counts. The focused operation should allocate
nothing; an allocation difference indicates an unintended aggregate or state
boundary.

After focused tests stabilize, run one `make`, rerun Stage 02 tests, and profile
lexing and Stages 01-04 against `blorp/src/main.brp`.

## Expected Results

For migrated loops, each accepted character should require one source lookup
rather than two. `peek_next` should avoid constructing and advancing an unused
cursor. Fixed-width symbols should not loop through general source advancement.

Allocation counts should be neutral. Expected improvement is fewer bounds
checks, source helper calls, and field loads, with a measurable focused-probe
speedup and a modest full-lexer improvement. Do not promise a large Stage 01-04
percentage from this issue alone.

If generated C proves one lookup but timing is neutral, the cleanup may still
land if code size is neutral and the API is clearer. If generated code grows or
Unicode/span behavior becomes conditional, stop rather than trading correctness
for a micro-optimization.

## Implementation Order

1. Document and test cursor offset semantics.
2. Add equivalence tests for the new primitive.
3. Implement `source_advance_over`; delegate from `source_advance`.
4. Migrate identifier scanning and measure.
5. Simplify `peek_next` after proving offset semantics.
6. Migrate each additional scanner independently.
7. Consider fixed ASCII symbol advancement last.
8. Rebuild once and run the full early-frontend profile.

## Acceptance Criteria

1. One authoritative helper implements newline/tab cursor changes.
2. Known-character loops do not re-read the same character to advance.
3. Lookahead performs no unnecessary cursor advancement.
4. Unicode, tab, newline, EOF, token span, and diagnostic behavior is tested.
5. Focused generated C proves redundant calls are removed.
6. The focused probe has identical cursor checksums and no new allocations.
7. Before/after focused and full-lexer timings are reported.
8. Stage 02 tests, source tests, `scripts/compiler-check --changed`, and one
   final relevant full pass succeed.
9. No generated or scratch artifacts are committed.

## Out Of Scope

- changing `String` indexing semantics;
- unchecked raw byte access;
- Unicode identifier support;
- local stack cursor architecture itself, owned by Issue 26;
- keyword dispatch, token representation, or `LexerStep` removal;
- checkpoint amortization; and
- parser cursor changes.

## Implementation Report Requirements

Include the verified source-offset contract, migrated call sites, equivalence
tests, representative generated C, all focused samples, allocation results,
Stage 01-04 results, test totals, and any Unicode or C-inlining rough edge.
