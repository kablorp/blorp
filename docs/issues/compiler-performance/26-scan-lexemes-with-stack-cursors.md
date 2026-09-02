# Scan Lexer Lexemes With Stack Cursors

**Status:** Implemented

## Objective

Stop threading the heap-allocated `LexerState` through every character of a
lexeme. Scan contiguous text with a local stack `Cursor`, construct the span
once, and update `LexerState.cursor` once when the scan completes.

The first required slice is identifier scanning. Extend the same shape to
numbers, spaces, and comments only after the identifier slice independently
passes its structural and performance gates. String and pipe-string scanners
may follow only when their extra state can be kept explicit without obscuring
their error handling.

This is a source refactor in Stage 02. It must not change accepted syntax,
token text, token order, trivia attachment, spans, diagnostics, or parser
behavior.

## Why This Issue Exists

The current identifier scanner in
`blorp/src/compiler/stage_02_lex/lexer.brp` has this shape:

```blorp
private pure func scan_identifier_text(state: LexerState) -> (String, SourceSpan, LexerState):
	start_cursor: Cursor = state.cursor
	var st: LexerState = state

	while ...:
		...
		st = advance(st)

	span: SourceSpan = span_from(st, start_cursor, st.cursor)
	(source_span_text(st.source, span), span, st)
```

`Cursor` is a stack struct, but `LexerState` is a managed record containing the
source and several lists. The generated C currently:

1. retains the incoming state to initialize mutable `st`;
2. runs a consumed record update for every accepted character;
3. can lose uniqueness on the first update and allocate a replacement state;
4. allocates a three-element heap tuple for the return value;
5. retains the string, span, and state while destructuring that tuple; and
6. destroys the tuple immediately in `scan_identifier`.

The current Stage 01-04 profile of compiler self-parsing measured a median
583.623 ms in lexing, 48.28% of the 1.209-second early frontend. Native and
instrumented profiles both identify `scan_identifier`,
`scan_identifier_text`, and cursor advancement as important lexer paths.

Fieldwise COW record updates from Issue 25 made a unique cursor-only state
update much cheaper. They cannot eliminate the unnecessary state ownership
boundary or the tuple produced once per identifier. A stack cursor does both.

## Required Design

### Identifier Slice

Replace the state-returning text helper with a cursor-returning scan. A suitable
shape is:

```blorp
private pure func identifier_end_cursor(source: SourceFile, start: Cursor) -> Cursor:
	var cursor: Cursor = start
	var scanning: Bool = True

	while scanning:
		match source_peek(source, cursor):
			Some(c):
				if is_ident_continue(c):
					cursor = source_advance(source, cursor)
				else:
					scanning = False
			None:
				scanning = False

	cursor
```

`scan_identifier` should then:

1. remember `state.cursor` as the start;
2. compute the end cursor;
3. construct one span;
4. classify or retain the lexeme text exactly as before;
5. update `state.cursor` once; and
6. emit the same token through the existing emission protocol.

Names may differ, but the ownership boundary must remain visible: the inner
loop owns a `Cursor`, not a `LexerState`.

Do not introduce a nullable token, sentinel character, mutable global, native
lexer escape hatch, or boolean combination that makes scan outcomes implicit.

### Follow-On Scanner Slices

After identifiers improve, inventory loops that repeatedly call `advance(st)`.
Classify them before editing:

- **Cursor-only loops:** spaces and simple comments can normally move directly.
- **Cursor plus scalar state:** number scanning also tracks `saw_dot`; keep that
  scalar local and update `LexerState` once.
- **Diagnostic-producing loops:** retain an explicit local diagnostic result or
  defer these until a clean value model is established.
- **Complex literal loops:** strings and pipe blocks track interpolation,
  escapes, and recovery. Do not force them into the simple helper if doing so
  duplicates logic or hides error state.

Each migrated scanner is a separate measured checkpoint. Do not rewrite every
scanner before measuring the first one.

### Relationship To Source-Access Cleanup

This issue deliberately continues to use `source_advance(source, cursor)`, even
though that helper re-reads the current character. Issue 29 introduces the
known-character advancement primitive and removes that duplicate read. Keeping
the changes separate lets measurement attribute the state/tuple improvement
independently from source-access improvement.

## Semantic Requirements

- The end cursor must be identical for empty, one-character, long, and EOF-
  terminated lexemes.
- Line, column, and offset behavior must remain byte-for-byte identical.
- Identifier recognition remains ASCII under the current grammar. Do not
  broaden Unicode identifier syntax in this issue.
- Keyword recognition remains unchanged; Issue 28 owns dispatch optimization.
- `source_span_text` must receive the same half-open range.
- Diagnostics must retain their current source path, module, line, and column.
- Cancellation and cooperative checkpoint behavior must not be removed here.
- The returned token and lexer state must obey ordinary Blorp value semantics.

## Test-First Plan

Before production edits, extend
`blorp/test/compiler/stage_02_lex/test_lexer.brp` with a focused test covering:

- an identifier at the beginning of a line;
- identifiers ending before whitespace, punctuation, newline, and EOF;
- an underscore-prefixed identifier;
- a long identifier, long enough to exercise the loop materially;
- a keyword-shaped prefix such as `record_value` that remains an identifier;
- exact token text; and
- exact start/end offset, line, and column.

The functional test may already pass before the refactor. Add a structural
probe that fails on the old generated shape: generated C for the candidate
lexer must not contain the heap tuple construction formerly belonging to
`scan_identifier_text`, and the identifier loop must not call the consuming
`LexerState` advancement specialization once per character.

Do not assert compressed C symbol names. Locate the function using stable type
names, distinctive source strings, or a small purpose-built public probe.

## Fast Feedback Loop

Do not rebuild the compiler during the source-refactor loop.

### 1. Create An Ignored Focused Probe

Create `scratch/lexer_stack_cursor_probe.brp`. It should import `lex`, construct
one source string containing many long non-keyword identifiers, and report a
deterministic checksum formed from token count, identifier text lengths, span
offsets, and diagnostic count.

Build the source string before the measured region. If memory statistics are
available, call `reset_mem_stats` immediately before `lex` and
`get_mem_stats` immediately afterward. Do not print from inside the measured
region.

The checked-in compiler can compile the probe while importing the edited lexer
from the working tree. Therefore the target executable exercises the candidate
lexer even before `make` rebuilds `bin/blorp`.

### 2. Iterate With Narrow Commands

Use:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_02_lex/lexer.brp
bin/blorp test blorp/test/compiler/stage_02_lex/test_lexer.brp
bin/blorp run --no-format scratch/lexer_stack_cursor_probe.brp
```

Compile the probe to a temporary C file when inspecting ownership shape:

```bash
probe_c=$(mktemp "${TMPDIR:-/tmp}/blorp-lexer-cursor.XXXXXX.c")
bin/blorp compile --no-format --no-embed-runtime \
  -o "$probe_c" scratch/lexer_stack_cursor_probe.brp
rg -n 'scan_identifier|LexerState|blorp_tuple_new|blorp_retain|blorp_release' "$probe_c"
rm -f "$probe_c"
```

Do not commit the scratch source or generated C.

### 3. Measure Before Broadening

Run one warmup and at least seven alternating baseline/candidate probe runs on
the same host and compiler binary. Record every sample, median elapsed time,
allocation count, token count, and checksum.

Only after the identifier slice is proven should another scanner be migrated.
Repeat the focused measurement after every scanner slice.

### 4. Rebuild Once

Run `make` only after the changed lexer and focused tests are stable. Then rerun
the probe using the rebuilt compiler and run the Stage 01-04 harness against
`blorp/src/main.brp`, stopping before typechecking.

## Expected Results

The identifier slice should produce:

- zero heap tuple allocations from `scan_identifier_text`;
- no heap `LexerState` update per identifier character;
- one state cursor update per identifier;
- fewer retains, releases, and cancellation-cleanup operations around the
  identifier result; and
- a measurable reduction in identifier-heavy probe time and allocations.

No exact percentage is an acceptance requirement. A reasonable exploratory
expectation is a 10-25% improvement in identifier-heavy lexing and a smaller
but visible improvement in full compiler lexing. Since lexing is 48.28% of the
early frontend, every 10% lexing improvement is approximately a 4.8% Stage
01-04 improvement before secondary effects.

If generated work is removed but the probe does not improve, profile the probe
before migrating another scanner. If allocation count rises, stop and explain
the new owner rather than accepting a timing-only result.

## Acceptance Criteria

1. The identifier inner loop advances a stack `Cursor`, not `LexerState`.
2. The identifier scan returns no heap tuple or replacement lexer state.
3. `LexerState.cursor` is updated once after the scan.
4. Existing token text, spans, trivia, diagnostics, and keyword behavior remain
   byte-for-byte unchanged.
5. Focused tests cover all identifier termination boundaries and exact spans.
6. Generated C proves the tuple and per-character state update are absent.
7. The focused probe preserves its checksum and reports before/after time and
   allocations.
8. Any additional scanner migration is separately measured and remains easy to
   review.
9. A rebuilt compiler passes `scripts/compiler-check --changed` and the Stage
   02 lexer suite.
10. A fresh Stage 01-04 profile reports lexing and total early-frontend medians
    without using total compiler time.
11. No generated artifacts remain in the repository.

## Out Of Scope

- removing `LexerStep`;
- changing keyword dispatch;
- known-character or fixed-width cursor primitives;
- changing `Token`, `TokenKind`, `SourceSpan`, or trivia representation;
- changing cooperative checkpoint frequency;
- parallel module discovery or lexing; and
- parser token-access optimization.

## Implementation Report Requirements

Record the source revision, compiler hash, probe hash, input size, token count,
checksum, all timing samples, allocation counts, and representative before/
after generated C. List every migrated scanner explicitly. Include focused and
final test commands with pass/fail totals and note any ownership or profiling
rough edge discovered.

## Implementation Report

Implemented from source revision `99ad1d88451b2ee3f7c6d13995a862f9e29fd7cc`.
The rebuilt compiler SHA-256 was
`952af9b1c56ca7b43d622ee552d714439c3013a38f854788fb028ea8d099234c`.
The ignored probe SHA-256 was
`534da0484b52ace958c6ef7dd57608fe2b1b4df53af16d874d4861c86fd262eb`.

Only `scan_identifier` was migrated. The old helper returned a heap tuple
containing text, span, and `LexerState`; the replacement helper returns a
stack `Cursor`. `scan_identifier` now constructs the half-open span once and
applies the final cursor to the state at the emission boundary. Spaces,
comments, numbers, strings, and pipe strings remain unchanged so that each can
be evaluated independently in a later issue.

The focused optimized-native probe lexed 4,150,000 source bytes containing
50,000 long identifiers. Both implementations produced 50,001 tokens, zero
diagnostics, and checksum `207508250000`.

| Probe | Elapsed samples (microseconds) | Median | Allocations | Releases |
| --- | --- | ---: | ---: | ---: |
| Baseline | 45,288; 45,095; 45,671; 44,468; 45,980; 45,297; 44,782 | 45,288 | 500,014 | 300,010 |
| Stack cursor | 32,883; 33,832; 57,221; 44,861; 33,715; 34,437; 34,055 | 34,055 | 450,014 | 250,010 |

The median improved by 24.8%, and the candidate removed exactly 50,000
allocations and releases: one immediately destroyed result tuple per
identifier. Current objects (`200,004`) and allocator bytes (`25,900,368`)
were identical. The timing set contains two noisy candidate samples; the
allocation result and generated shape are deterministic.

Profile-instrumented generated C names `identifier_end_cursor` and shows a
local `Cursor` advanced by `source_advance`. Its body contains no
`LexerState` update and returns the cursor directly. The enclosing
`scan_identifier` calls it once and contains no `blorp_tuple_new`; unrelated
three-element tuples elsewhere in the lexer remain.

After the single rebuild, seven uninstrumented `compile --ast --no-format
blorp/src/main.brp` runs measured Stage 01-04 wall times of 3.09, 3.11, 3.16,
3.19, 3.19, 3.16, and 3.11 seconds: median 3.16 seconds. This command exits
before typechecking. A fresh function-instrumented worker reported cumulative
`lex` samples of 11,024.853; 10,997.060; 10,971.830; 11,091.522; 11,336.119;
11,535.341; and 11,732.080 milliseconds: median 11,091.522 milliseconds. Its
corresponding frontend-graph median was 15,752.048 milliseconds. These
instrumented absolute values include substantial profiling overhead and are
phase-attribution data, not substitutes for the uninstrumented wall time.

Validation completed with `make`, direct lexer typechecking, all 31 Stage 02
lexer tests, and `scripts/compiler-check --changed` (one production source,
one focused suite, zero special checks). The final `scripts/test
compiler-blorp` gate passed all 4,156 tests. Generated-C compilation surfaced
the repository's existing broad generated-code warnings; none originated in
the new cursor helper.
