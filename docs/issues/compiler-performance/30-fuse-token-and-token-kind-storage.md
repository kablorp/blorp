# Fuse Token And Token-Kind Storage

**Status:** Proposed; requires the allocation gate below before representation cutover

## Objective

Reduce the persistent heap objects created per lexical token by storing the
token variant and its payload directly in one managed token value. Remove the
current nested `Token { kind: TokenKind, ... }` representation, which allocates
a `TokenKind` union object and then a separate `Token` record for every token.

The preferred representation is a single `Token` union whose variants carry
their payload, span, and trivia. It must make illegal token payload/tag
combinations unrepresentable. Parser, formatter, bridge, and diagnostics must
observe exactly the same token stream.

This issue begins with a required allocation inventory. Do not perform the
representation migration unless the inventory proves that `TokenKind` remains
a material persistent allocation after the already-accepted cursor work and
any other lexer changes that land first.

## Why This Issue Exists

The current Stage 02 model is:

```blorp
union TokenKind:
	IdentifierToken(String)
	KeywordToken(Keyword)
	...

record Token {
	kind: TokenKind,
	span: SourceSpan,
	leading_trivia: List[Trivia],
	trailing_trivia: List[Trivia]
}
```

Generated C constructs a heap `TokenKind`, then a heap `Token` containing a
pointer to that union. A normal token also owns a heap `SourceSpan`; identifiers
and literals may own a lexeme string. Transient scanner results, when present,
are a separate allocation class and must not be counted as token storage.

Current native samples show `Token_destroy`, `TokenKind_destroy`, generic
allocation, release, and free activity in the lexer. Lexing is 583.623 ms,
48.28% of the Stage 01-04 self-parse. The nested persistent token representation
may be a material allocation floor independently of transient scanner-result
representation.

The compiler and formatter retain tokens and their trivia, so these objects
cannot simply be dropped. The opportunity is to represent the same information
with one allocation instead of two.

## Required Precondition And Decision Gate

Build an ignored mixed-token allocation probe against current main. Count:

- source bytes;
- total tokens;
- each token variant;
- tokens with leading/trailing trivia;
- total allocations during one `lex` call; and
- allocations per token after subtracting fixed setup where possible.

Inspect generated constructors and a native allocation profile. Proceed only
if all are true:

1. every ordinary token still calls a heap `TokenKind` constructor;
2. `TokenKind` construction is not already fused or stack-promoted;
3. it accounts for approximately one allocation per token; and
4. eliminating that allocation is expected to reduce lex allocations by at
   least 10% on the compiler corpus or by at least 0.8 allocations per token on
   the focused probe.

If the gate fails, close the issue with measurements. Do not force a broad data
model migration for an allocation the compiler already removed.

## Required Representation

Use one precise union. Names may be adjusted to avoid collisions with existing
`Keyword` and `Symbol` constructors, but the shape should be equivalent to:

```blorp
union Token:
	IdentifierLexToken(String, SourceSpan, List[Trivia], List[Trivia])
	KeywordLexToken(Keyword, SourceSpan, List[Trivia], List[Trivia])
	SymbolLexToken(Symbol, SourceSpan, List[Trivia], List[Trivia])
	IntLiteralLexToken(String, SourceSpan, List[Trivia], List[Trivia])
	FloatLiteralLexToken(String, SourceSpan, List[Trivia], List[Trivia])
	StringLiteralLexToken(StringLiteralKind, String, SourceSpan, List[Trivia], List[Trivia])
	CharLiteralLexToken(Int, SourceSpan, List[Trivia], List[Trivia])
	DocStringLexToken(String, SourceSpan, List[Trivia], List[Trivia])
	NewlineLexToken(SourceSpan, List[Trivia], List[Trivia])
	IndentLexToken(SourceSpan, List[Trivia], List[Trivia])
	DedentLexToken(SourceSpan, List[Trivia], List[Trivia])
	EndOfFileLexToken(SourceSpan, List[Trivia], List[Trivia])
```

Repeating span/trivia fields in source is intentional: each union value remains
self-contained, and no second metadata record should replace the allocation
just removed.

Do not replace `TokenKind` with a scalar tag plus nullable or defaulted payload
fields. That would permit an identifier without text or a newline with a string
payload and violate the repository's illegal-state policy.

## API Migration

Add exhaustive token accessors where a consumer needs common metadata:

```blorp
pure func token_span(token: Token) -> SourceSpan
pure func token_leading_trivia(token: Token) -> List[Trivia]
pure func token_trailing_trivia(token: Token) -> List[Trivia]
pure func token_with_appended_trailing_trivia(token: Token, trivia: Trivia) -> Token
```

Accessors must match directly on `Token`; they must not reconstruct a
`TokenKind` or metadata record.

Migrate hot parser predicates to match the token directly:

```blorp
match current_token(state):
	KeywordLexToken(keyword, _, _, _): ...
	...
```

If repetitive matches obscure parser intent, add narrow predicates such as
`token_is_symbol(token, expected)` that match the fused union without
allocating. Do not add a general `token_kind(token) -> TokenKind`; that would
recreate the eliminated union on every parser lookup and could be worse than
the starting point.

`LexerState.last_token_kind` currently retains a complete `TokenKind` even
though lambda-body logic only asks whether the previous token was a colon.
Replace it with the narrowest precise fact, for example
`previous_token_was_colon: Bool`, or a small enum if another distinct state is
actually required. The field name must state exactly what the boolean means.

Delete `TokenKind` only after all production and test consumers are migrated.
Do not leave compatibility wrappers or two parallel token representations.

## Ownership Requirements

- Each token constructor allocates exactly one token union object.
- Managed payload release masks cover only fields present in that variant.
- Span and trivia ownership transfers exactly once into the token.
- Matching a token for its tag must not retain every payload field.
- Common metadata accessors may borrow or retain the requested field according
  to normal language semantics, but must not allocate a replacement token.
- Appending trailing trivia must preserve COW value semantics if another owner
  of the token is live.
- Empty trivia lists must remain canonical and allocation-free.
- Token identity is not observable and must not become a language-level API.

## Semantic Requirements

- Token variant, payload text/value, span, and trivia are byte-for-byte equal to
  the old representation.
- Token ordering and EOF behavior are unchanged.
- Parser acceptance, error recovery, and exact diagnostics are unchanged.
- Formatter comment placement and output are unchanged.
- Parser bridge and Stage 06 bridge JSON are byte-for-byte unchanged.
- Public language syntax does not change.
- No token payload is inferred from a string prefix, constructor name, or other
  heuristic.

## Test-First Plan

Before migration:

1. Extend `blorp/test/compiler/stage_02_lex/test_token.brp` with exhaustive
   construction/accessor tests for every token variant.
2. Extend `test_lexer.brp` with one mixed stream that checks every variant,
   exact spans, and both trivia directions.
3. Add parser tests that exercise token predicates and error recovery across
   identifier, keyword, symbol, and literal variants.
4. Preserve or add formatter tests for leading/trailing comments.
5. Preserve byte-for-byte parser/bridge JSON fixtures.
6. Add an allocation assertion in the focused probe: after fixed setup, the
   candidate must remove approximately one allocation per token.

The old representation should fail the structural allocation target. Do not
write tests that merely rename constructors.

## Fast Feedback Loop

Create ignored `scratch/fused_token_probe.brp` importing `lex`. Use a fixed
source with all token variants and comments, repeat it enough for stable memory
counts, and produce a checksum over payloads, spans, and trivia. Reset memory
stats immediately before lexing.

Migrate in compiling slices:

1. define the fused union and accessors beside the old representation;
2. convert constructors and Stage 02 tests;
3. convert lexer emission;
4. convert parser predicates and direct `.kind` reads;
5. convert formatter and bridges;
6. delete the old representation immediately.

The temporary dual-definition state is a development checkpoint only, not a
valid merge point.

Run narrow commands after each slice:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_02_lex/token.brp
bin/blorp check --no-format blorp/src/compiler/stage_02_lex/lexer.brp
bin/blorp check --no-format blorp/src/compiler/stage_03_parse/language_parser.brp
bin/blorp test blorp/test/compiler/stage_02_lex/test_token.brp
bin/blorp test blorp/test/compiler/stage_02_lex/test_lexer.brp
bin/blorp run --no-format scratch/fused_token_probe.brp
```

Do not rebuild while exhaustive pattern matches are being migrated. The old
compiler can compile and execute the edited token/lexer/parser modules as part
of focused tests.

Compile the probe to temporary C and count constructors:

```bash
probe_c=$(mktemp "${TMPDIR:-/tmp}/blorp-fused-token.XXXXXX.c")
bin/blorp compile --no-format --no-embed-runtime \
  -o "$probe_c" scratch/fused_token_probe.brp
rg -n 'TokenKind_make|TokenKind_destroy|Token_make|Token_destroy|LexToken' "$probe_c"
rm -f "$probe_c"
```

After focused suites are stable, run `make` once, then parser, formatter,
bridge, CLI format, and Stage 01-04 profiling gates.

## Expected Results

The focused probe should remove approximately one persistent allocation and one
eventual destruction per token. The exact total reduction depends on literal
strings, spans, parser products, and remaining state allocations.

Expected secondary effects are:

- fewer generic allocations/releases/frees in lexer samples;
- better locality when parser code tests a token and reads its payload;
- a measurable lexing improvement; and
- possible parser improvement from avoiding nested `TokenKind` ownership.

Generated C may grow because variant metadata fields and exhaustive accessors
are repeated. Measure both generated C and final binary size. Code-size growth
must remain bounded and justified by the allocation result; do not generate one
specialized accessor per call site.

## Acceptance Criteria

1. The allocation decision gate is recorded and passes.
2. One fused token union represents tag, payload, span, and trivia without
   invalid combinations.
3. `TokenKind` and all compatibility wrappers are deleted.
4. No hot accessor reconstructs a kind or metadata aggregate.
5. Generated C allocates one token object, not separate token and kind objects.
6. Focused allocations fall by approximately one per token, with any deviation
   explained.
7. Token streams, bridge JSON, diagnostics, and formatter output are unchanged.
8. Parser, lexer, formatter, bridge, ownership/leak, and sanitizer tests pass.
9. Before/after lex, parse, and Stage 01-04 timings are reported.
10. Generated C and binary size changes are reported and bounded.
11. One final relevant full test pass and `scripts/compiler-check --changed`
    succeed.
12. No scratch or generated artifact is committed.

## Dependencies And Out Of Scope

The allocation probe must distinguish persistent `TokenKind` objects from
transient scanner-result objects. No scanner-result representation change is a
prerequisite. Re-run the gate after other accepted lexer changes if they alter
the allocation baseline.

This issue does not redesign `SourceSpan`, intern identifier strings, change
trivia retention, add a compilation-without-trivia mode, optimize parser token
indexing, or add general compiler inline-union-field support. If a general
inline-union representation becomes preferable, write a separate issue with
its complete ownership and ABI design rather than expanding this migration.

## Implementation Report Requirements

Include the allocation inventory and decision, final union/API, exhaustive
ownership accounting, constructor counts, focused allocation-per-token samples,
all timing samples, generated C/binary sizes, compatibility fixture results,
test totals, reviewer verdicts, and any parser or formatter migration rough
edge.
