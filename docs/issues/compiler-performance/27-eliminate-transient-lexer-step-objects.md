# Eliminate Transient Lexer Step Objects

**Status:** Proposed

## Objective

Remove the heap-allocated `LexerStep` result created by every call to
`scan_one`. Make token and trivia accumulation part of the private lexer state
so scanning functions return a single `LexerState` and the driver no longer
allocates, matches, and destroys a transient union for each scanning step.

The public result remains:

```blorp
record LexResult {
	tokens: List[Token],
	diagnostics: List[ParseDiagnostic]
}
```

No public syntax, token, span, trivia, diagnostic, or ordering behavior may
change.

## Why This Issue Exists

The current private protocol is:

```blorp
private union LexerStep:
	LexerStateStep(LexerState)
	LexerTokenStep(LexerState, Token)
	LexerTrailingTriviaStep(LexerState, Trivia)
```

`scan_one` returns one of these values and `lex` immediately matches it to
recover the next state and optionally update the token list. Generated C shows
that all three constructors call `blorp_alloc`, install a destructor and
release mask, and are destroyed after the match. They do not escape the driver
iteration and do not represent persistent language data.

This creates one avoidable allocation boundary for tokens, whitespace runs,
newlines, comments, and error recovery steps. It also prevents emission helpers
from directly exploiting the unique lexer state and token-list accumulator.

The refreshed self-parse profile measured lexing at 583.623 ms, or 48.28% of
Stages 01-04. Allocation, release, and destructor functions are the largest
combined native leaf class. Removing a short-lived allocation from the central
driver is therefore both a cleanliness improvement and a direct attack on the
measured cost.

## Required Design

### One Private State Owns Output Construction

Add the preallocated token accumulator to `LexerState`:

```blorp
private record LexerState {
	source: SourceFile,
	cursor: Cursor,
	tokens: List[Token],
	diagnostics: List[ParseDiagnostic],
	...
}
```

Initialize it once using the current capacity estimate:

```blorp
tokens = list(source.text.length() / 4 + 16)
```

Scanners should return `LexerState`. The three old outcomes become explicit
state operations:

- state-only progress returns the updated state;
- token emission appends to `state.tokens` and returns the updated state;
- trailing trivia updates the last token in `state.tokens` and returns the
  updated state.

The driver should converge toward:

```blorp
while not done:
	...
	state = scan_one(state)

{
	tokens = state.tokens,
	diagnostics = state.diagnostics
}
```

Exact source structure may vary, but no replacement result union or tuple may
remain between `scan_one` and `lex`.

### Emission Helpers

Change `emit_token` from `LexerStep` to `LexerState`. It must:

1. construct exactly one `Token`;
2. transfer `pending_trivia` to its leading trivia;
3. append the token to the preallocated token list;
4. replace `pending_trivia` with the canonical empty list;
5. update `line_has_token`; and
6. record only the minimal previous-token fact required by lambda-body logic.

Change trivia attachment similarly. A trailing comment must update the last
token with exactly the same COW semantics as today. A leading comment must stay
pending until the next emitted token.

Structural tokens from indentation and EOF finalization must append to the same
state-owned list. Remove temporary structural-token lists only when their
ordering is preserved directly. Do not replace `LexerStep` with a new temporary
list, callback, nullable token, or `(LexerState, Option[Token])` aggregate.

### Ownership Shape

Issue 25's fieldwise COW updates are a prerequisite. The implementation should
keep the state uniquely owned across the driver whenever possible. Before
settling on source shape, inspect generated C for `emit_token` and the
`scan_one` driver.

Compute values needed from the old state before consuming it into a record
update. Avoid retaining `state` merely because the same expression reads a
field after constructing the update. In particular, confirm that adding
`tokens` does not make cursor-only updates reconstruct or retain the token list.

## Semantic Requirements

- Tokens retain exact source order, including multiple dedents before the next
  source token and EOF last.
- Leading and trailing comments attach to the same tokens as before.
- A lexer error must not discard structural tokens already emitted.
- Pending newline, indentation, group depth, and lambda-body behavior remain
  unchanged.
- Token-list capacity is only an implementation detail; no observable ordering
  may depend on reallocation.
- The public `LexResult` remains independent of subsequent state destruction.
- Pure-function and value-semantics guarantees remain intact.
- No shared mutable state or native mutation escape hatch is introduced.

## Test-First Plan

Extend `blorp/test/compiler/stage_02_lex/test_lexer.brp` before changing the
protocol. Required regression coverage is:

- ordinary token emission;
- a source containing only whitespace;
- leading and trailing comments;
- blank lines and comments around indentation;
- multiple dedents before a following token;
- unexpected-character recovery after indentation;
- string and pipe-string paths that emit through specialized helpers;
- EOF with and without a final newline; and
- exact token signatures, spans, trivia, and diagnostic strings.

Add a structural assertion over generated C for a focused lexer probe. It must
fail while `LexerStep` constructors are called and pass only when the type and
all three constructors are absent from the reachable candidate lexer.

Do not test only allocation totals: an unrelated allocation improvement could
hide retention of the transient protocol.

## Fast Feedback Loop

### 1. Create An Ignored Mixed-Token Probe

Create `scratch/lexer_step_probe.brp`. Its fixed source should contain:

- many identifiers, keywords, numbers, and symbols;
- indentation and multiple dedents;
- leading and trailing comments;
- normal and raw strings; and
- one recoverable unexpected character.

Run `lex` repeatedly over the already-created `SourceFile`. Reset memory stats
immediately before the loop and read them immediately afterward. Return a
checksum that includes token count, diagnostic count, selected token kinds,
selected spans, and trivia counts.

### 2. Iterate Without Rebuilding

The installed compiler can compile a target that imports the edited Stage 02
source. Use only:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_02_lex/lexer.brp
bin/blorp test blorp/test/compiler/stage_02_lex/test_lexer.brp
bin/blorp run --no-format scratch/lexer_step_probe.brp
```

After each coherent scanner family is converted, return immediately to those
commands. Do not run the full compiler test corpus while exhaustive matches and
return types are still being updated.

### 3. Inspect Candidate Generated C

```bash
probe_c=$(mktemp "${TMPDIR:-/tmp}/blorp-lexer-step.XXXXXX.c")
bin/blorp compile --no-format --no-embed-runtime \
  -o "$probe_c" scratch/lexer_step_probe.brp
rg -n 'LexerStep|LexerStateStep|LexerTokenStep|LexerTrailingTriviaStep|blorp_alloc' "$probe_c"
rm -f "$probe_c"
```

Absence of constructor calls is required. Also inspect the emitted `scan_one`,
`emit_token`, and driver functions to confirm the change did not merely rename
the allocation.

### 4. Measure Focused Work

Capture one warmup and at least seven alternating runs of baseline and
candidate probes. Record elapsed time, allocations, releases when available,
peak/current objects, token count, and checksum. Use the same compiler binary,
C compiler, flags, and input bytes.

### 5. Integrated Check Only At The End

After focused checks stabilize, run `make`, rerun the Stage 02 tests using the
new compiler, and run the Stage 01-04 self-parse harness against
`blorp/src/main.brp`. Stop before typechecking. Run broader gates once, at the
end.

## Expected Results

The implementation must remove one `LexerStep` allocation and destruction per
driver step. The mixed-token probe should show a clear allocation reduction
approximately proportional to the number of old `scan_one` results.

Timing should improve because allocation, destructor dispatch, release-mask
handling, and the immediate union match disappear. The exact percentage is not
known. Treat a visible allocation reduction as the primary structural result;
report timing rather than promising a threshold.

Full compiler lexing should remain below the current 583.623 ms median under a
controlled comparison. If it does not, inspect whether carrying `tokens` in
`LexerState` caused lost uniqueness or repeated list retains. Do not land a
cleaner-looking protocol that merely shifts the allocation into state updates.

## Implementation Order

1. Add regression and structural tests.
2. Add `tokens` to initialization and final result projection.
3. Convert ordinary `emit_token` and the main driver.
4. Convert state-only scanner paths.
5. Convert trailing trivia.
6. Convert specialized string/docstring emission paths.
7. Convert indentation and finalization emissions.
8. Delete `LexerStep` and obsolete helpers.
9. Inspect generated C and measure the focused probe.
10. Rebuild once and measure Stages 01-04.

Every numbered step after step 2 must typecheck before proceeding. Do not leave
parallel old and new protocols at the final merge point.

## Acceptance Criteria

1. `LexerStep` and all three constructors are deleted.
2. `scan_one` and its callees return `LexerState` without an equivalent heap
   result aggregate.
3. One preallocated token list is owned through the private lexer state.
4. All token, structural-token, trivia, error, and EOF ordering is unchanged.
5. Generated C contains no reachable transient step constructor.
6. Generated C shows unique cursor updates do not retain or rebuild the token
   accumulator.
7. The focused probe preserves its checksum and reports a material allocation
   reduction.
8. Focused timing and Stage 01-04 lex timing are reported.
9. Stage 02 tests, `scripts/compiler-check --changed`, and one final relevant
   full test pass succeed.
10. Generated artifacts and scratch files are not committed.

## Dependencies And Out Of Scope

Issue 25 must already be present. Issue 26 should normally land first so the
state-owned output list is not threaded through per-character loops.

This issue does not change keyword dispatch, source cursor primitives, token or
span representation, parser token access, cooperative checkpoint frequency, or
module-level concurrency.

## Implementation Report Requirements

Include the final private state shape, ownership reasoning for token/trivia
transfer, before/after generated driver excerpts, removed constructor counts,
all focused samples and memory counters, Stage 01-04 samples, functional test
totals, reviewer findings, and any lost-uniqueness rough edge discovered.
