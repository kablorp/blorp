# One keyword authority: bounded maintenance plan

Plan only; no production implementation or compiled evidence yet. Initially
reviewed against `c2fa6230c`; implementation follows the accepted propagation
parser and naming changes. Source anchors below describe that initial tree;
resolve the named declarations when line numbers move. The coordinator owns
shared documentation, compiled slots and
integration. Two independent plan reviews precede implementation.

Paths beginning `src/` are relative to `blorp_2/`. Short production references
such as `lex/lex.brp` and `syntax:73` are relative to `blorp_2/src/` and name
the owning module; `test_lex/`, `test_parse/` and `test_utils/` references are
relative to `blorp_2/test/unit/`. Runnable commands use repository-root paths.

## Problem and scope

`lex/lex.brp:517-594` maps spellings to symbols; `utils/syntax.brp:153-191`
maps them back; `test_lex/test_keywords.brp:45-68` repeats the vocabulary as a
round-trip inventory. There is a fourth inverse in
`test_lex/test_lex.brp:59-162`, used to render token traces. Adding a reserved
word can leave recognition, category recognition and diagnostics inconsistent.
The current behavior itself is correct; this is a semantics-preserving refactor,
not a claim that an existing semantic regression fails today.

Keep exactly the current recognized words, contextual identifiers, punctuation,
layout, token spans and spacing. Keep every existing diagnostic byte-for-byte,
including backticks and the suggested `<word>_name`. No language feature,
keyword generator, reflection, traits, cache, FFI or alternate parser is added.

## Proposed model and simplicity verdict

Move keyword variants out of `Symbol` into a fixed `Keyword` enum. `Symbol`
then contains punctuation and layout, including the wildcard. Add
`KeywordToken(Keyword)` to `TokenKind`. Keep one forward spelling match in the
lexer. Delete `keyword_spelling`; classify reserved words by token kind and
quote their already-validated source span for diagnostics.

Add `source_text: String` to transient `LexedProgram`, populated directly from
the immutable `source` passed to `lex`. The parser carries this one reference
inside its existing input; `ParsedModuleContents` does not acquire it. This
adds no per-keyword retained spelling. The current temporary substring used
for lexical lookup remains; removing that is a separate optimization.

This is the smallest direct model found that preserves precise diagnostics
without two spelling maps. A list of spelling/symbol rows would need a second
symbol-equality inventory, trait support, or extra callable/table machinery to
implement reverse lookup. Scanning strings again in the parser would recompute
lexical classification. Keeping `KeywordToken(Symbol)` would still admit
punctuation as a keyword. All are weaker than the precise enum split.

The 11 reserved-only forms (`alias`, `debug`, `detach`, `foreign`, `from`,
`implements`, `resource`, `select`, `trait`, `try`, `where`) have no current
production tag consumers outside lexer construction. The parser treats all
through the same generic reserved-word path. They may therefore share one
`UnparsedKeyword` variant, with their spellings still listed once in the
forward match. This deletes unused semantic distinctions; it is optional and
is not needed to meet the line target. No future feature may classify them
by spelling; a future parser rule must introduce its own explicit variant.

### Decide the classifier result before adopting it

The straightforward shape is `keyword(String) -> Option[Keyword]`, with one
explicit `"_"` arm at the existing word-scanning site. The shorter candidate
is `word_kind(String) -> Option[TokenKind]`, whose same forward match returns
`KeywordToken(...)` or `SymbolToken(Wildcard)` directly.

Do not assume `Option[TokenKind]` is free: its payload is managed, while the
old `Option[Symbol]` and proposed `Option[Keyword]` carry enums. In the first
serialized slot, compile a direct producer-plus-consumer probe of both shapes
with the frozen host. Read the emitted C and measure actual allocations on
the same keyword, wildcard and identifier input. Reject the managed-result
shape if it introduces any per-word allocation or retention. Use the direct
`Option[Keyword]` shape if the shorter candidate does not clearly preserve
cost and readability. Do not introduce another classifier datatype speculatively.

## Literate producer-to-consumer changes

Current data (`src/utils/syntax.brp:73-196`):

```blorp
fixed union Symbol:
    AtSign
    PureKeyword
    FunctionKeyword
    -- other words, punctuation and layout

fixed union TokenKind:
    IdentifierToken(NameId)
    SymbolToken(Symbol)
    -- literals
```

Proposed shape (existing keyword variant names remain):

```blorp
fixed union Keyword:
    PureKeyword
    FunctionKeyword
    -- other currently parsed keyword roles
    UnparsedKeyword

fixed union Symbol:
    AtSign
    -- punctuation and layout, including Wildcard

fixed union TokenKind:
    IdentifierToken(NameId)
    KeywordToken(Keyword)
    SymbolToken(Symbol)
    -- unchanged literal variants
```

Current scan (`src/lex/lex.brp:643-649`):

```blorp
spelling = text.bytes.substring(cursor, IntOps.subtract(end, cursor))
match keyword(spelling):
    Some(value): Ok(ReadyToken(symbol(text, value, cursor, end)))
    None: Ok(WordToken(spelling, cursor, end))
```

The shorter candidate uses the existing token constructor directly:

```blorp
match word_kind(spelling):
    Some(kind): Ok(ReadyToken(token(text, kind, cursor, end)))
    None: Ok(WordToken(spelling, cursor, end))
```

Its one forward match includes `"func": Some(KeywordToken(FunctionKeyword))`
and `"_": Some(SymbolToken(Wildcard))`. The fallback shape returns
`Some(FunctionKeyword)` and handles `"_"` once before calling `keyword`.
Both leave word-boundary scanning and identifier interning unchanged.

Current name rejection (`src/parse/parse.brp:744-749`):

```blorp
SymbolToken(symbol):
    match keyword_spelling(symbol):
        Some(spelling): Err(reserved_name(token.span, spelling))
        None: Err(expected(state, message, IDENTIFIER_HELP))
```

Replace it with a reserved-word arm; punctuation falls through to the existing
identifier error and the preceding AtSign arm keeps its precedence:

```blorp
KeywordToken(_):
    spelling = state.input.source_text.substring(
        token.span.start, IntOps.subtract(token.span.end, token.span.start))
    Err(reserved_name(token.span, spelling))
```

Use `current_keyword(state) -> Option[Keyword]` for keyword predicates and
function-tail keyword dispatch. Keep `current_symbol` for punctuation/layout.
`at_keyword` becomes `current_keyword(state).is_some()`, with no spelling query.
In direct token matches, replace keyword `SymbolToken` arms with `KeywordToken`.
No parser continuation or statement-context rule changes.

## Facts, lifetime and complete consumer map

| Fact | Producer/owner | Lifetime and consumers |
| --- | --- | --- |
| Reserved spelling to grammatical role | Lexer's one forward match | Published as KeywordToken; parser consumes the role |
| Source bytes and matching token spans | `lex` from its source argument | LexedProgram/ParserState only; quoted solely for diagnostics and test traces |
| Punctuation/layout identity | Existing lexer symbol path | SymbolToken; layout and punctuation consumers unchanged |
| Identifier identity | Existing batch `intern_names` | Unchanged NameId path |

Production changes are confined to `src/utils/syntax.brp`, `src/lex/lex.brp`,
and `src/parse/parse.brp`. Relevant sites:

- `syntax:73-191,194-201,228-233`: enum split, inverse deletion, token variant,
  and source reference.
- `lex:11-21,517-594,640-649,1266-1271`: imports, sole mapping, word scan,
  publication. The colon/bracket layout matches at 1075-1091 keep wildcard
  catchalls for non-punctuation tokens.
- `parse:59-76,250-259,343-489,527-555`: imports and keyword predicates;
  `consume_name:736-753`; `consume_base:1200-1242`;
  `consume_operand:1439-1446`; `at_keyword:2076-2081`;
  `consume_function_line:2574-2587`.
- `test_lex/test_lex.brp:59-162`: replace the keyword inverse with
  `KeywordToken(_)` plus source substring, keeping punctuation/layout rendering.
- `test_lex/test_keywords.brp:43-68`: delete round-trip inventory and helper;
  retain category, boundary and contextual-identifier behavior cases.
- `test_utils/test_syntax.brp:71-80`: the only hand-built LexedProgram gains
  `source_text = "main"` for its existing immutable-publication test.

Other callers pass LexedProgram through without constructing or deconstructing
its token variants. The parser's existing source-ID validation remains; this
does not authorize a general token-repair or malformed-input framework.

## Expected physical size and pre-set ceilings

Deletion of the inverse saves 43 production lines. An enum split/source field
adds roughly 5-7; a same-shaped current_keyword helper adds about 13; name and
category checks simplify by roughly 8-12. Import/comment changes and the
wildcard arm leave a projected production delta of approximately **-20 to -35**
without grouping unsupported tags, another roughly 10 removed if grouped.
This is an estimate, not a measured implementation delta. Report ordinary
physical production and test lines separately; production must be **net <=0**.
Do not compress formatting or delete behavioral cases to reach it.

Before implementation freeze source, host/bootstrap/Clang/flags, baseline
pilot/C, fixture outcomes and raw costs. Reuse the frozen retained fixtures and
direct/flat module workloads. For a lexer-heavy phase measurement, use a frozen
copy of the existing `src/parse/parse.brp` text, read outside the measured call;
do not add a source generator. Use the existing Blorp memory counters and direct
phase TestSuite, not another runner or native-symbol access.

Reviewed measurement clarification: direct allocation windows run with the
existing strict/leak tracking enabled. With both measurement variables unset,
the runtime counters are inactive; merely removing `reset_mem_stats` does not
enable them. Do not reset global counters inside the measured helper. Capture
scalar endpoints around the lex or lex-plus-parse call, keeping setup and
report construction outside that allocation window. One and two calls on the
same frozen file check fixed-work call scaling, not a varying word-mix slope;
the classifier probe and emitted C independently cover per-word allocation.

The memory API has no isolated retired-instruction counter. For direct-phase
instruction evidence, run a separate counter-free ordinary TestSuite workload
with both measurement variables unset outside `/usr/bin/time`. Label this a
**phase-workload process proxy**: it includes host/native compilation, startup,
input I/O, assertions and reporting. It cannot establish isolated phase
instructions or attribute a small difference to the lexer. Whole-pilot corpus
and stress instruction limits remain independent acceptance requirements.
Root and an independent compiler expert agree on this narrower claim; no
counter implementation, alternate entrypoint or validation framework is added.

| Metric | Ceiling |
| --- | --- |
| Each frozen whole-compiler fixture/stress allocation count | No growth |
| Direct lex and lex-plus-parse allocation count | No growth; classifier probe/C must show no additional per-word allocation |
| Matched min-of-3 instructions, corpus, each stress input and phase-workload process proxy | +0.5%; proxy is not isolated phase instructions |
| Host compilation of compiler source, allocations and instructions | +5% |
| Token and TokenKind physical carrier size | No growth |
| LexedProgram physical carrier on arm64 | At most one pointer, +8 bytes |
| Additional source backing storage in normal loading | 0 copied bytes |
| Live objects/bytes with the returned parsed product or diagnostic held, after every full-source owner has gone | No growth against the matched baseline, for success and rejection |

Read generated C and its ordinary Clang record-layout dump to verify physical
carriers, mapping types through their actual installed names rather than
assuming numeric C identities are stable. Host `memory.size_of` observations
are supplementary and do not replace physical layout evidence. Compile the
unmodified compiler C already needed for the corpus; no split-output capture
or rewritten C is needed. Use existing `read_memory_counter` with active
counters around direct helper scopes for allocation/release/live-byte evidence;
construct reports after endpoint reads. Check both `MemoryStatsActive` and
`ManagedBytesAvailable`; an inactive/unavailable value is not zero evidence.

The timed phase workload above deliberately reads its input outside the call.
It therefore cannot prove release of the source. Normal loading cannot prove
that either: SourceInputs already retains the source (`load.brp:259-270`). Use
a separate direct Blorp TestSuite lifetime oracle:

1. Test setup retains only a fixture path and the same initial name authority
   used in the matched baseline. A dedicated helper calls `read_file` inside
   its own scope, creating a unique dynamically allocated source string. It
   lexes and parses that string and returns the actual `ParsedModule` or actual
   `Diagnostic`. An I/O/setup failure fails the test. No source string, lexed
   input, wrapper containing either, or SourceInputs escapes this helper.
2. The helper must finish before endpoint counters are read. The caller keeps
   the actual parsed result or rejection alive and observes it after the reads,
   so the compiler cannot destroy it before the observation. Compare live
   managed objects and available live managed bytes with the same helper,
   fixture and retained product in the frozen baseline. Capture only scalar
   endpoints and construct reports afterward. Do not use a static literal or
   retain a full-source outer alias as the measured source.
3. Exercise both a valid normal source fixture and a reserved-name rejection.
   After dropping the returned product/error too, require the counters to
   return to their matched post-setup level. This checks both the boundary
   product and final cleanup, independently of timing and normal loading.
4. Prove this oracle with a temporary accidental-retention mutant that adds
   the source_text reference to ParsedModuleContents and returns it there.
   With the parsed product held after its helper returns, that mutant must
   fail the live-object/live-byte comparison. Checking only source_text's
   value, dropping the product before observation, or obtaining balanced
   process-exit counts does not kill this mutant and is insufficient.

Standalone callers retaining only LexedProgram will now retain that entire
input string until they release the product; document this intentional lifetime
expansion rather than claiming zero retention universally. No source_text
reference may enter ParsedModule or later products. Existing e2e ceilings
remain unchanged.

These are owned-input and host-build proxies, not self-compilation. Stop on a
repeatable ceiling breach, unexpected boxing/copying, lost diagnostic precision,
host miscompilation, or a needed API/model expansion. Do not add a workaround
mechanism or silently revise a ceiling.

## Tests, mutations and gates

Keep current semantic category cases and exact trace bytes. Rename the reserved
word callbacks/descriptions from "words are symbols" to "words are keywords";
punctuation and layout remain symbols. Add granular direct tests for
KeywordToken versus punctuation/layout/IdentifierToken, lone `_`
versus `_if`/`if_`/`in2`, and contextual `fixed`, `methods_only`, `tail_recursive`,
`raw`, `True` remaining identifiers. Exercise representative implemented roles
through the existing parser suites, and reserved-only words through exact
name rejection and a rejection when substituted for `func` at declaration
position. Do not assert a keyword count, source census, or inventory round trip.

Pin exact written-word diagnostics at function, type, parameter, local binding
and propagating binding sites. Include `where = 1`, `var in = 1`, `in ?= ...`,
multi-module origins, indentation, EOF, and a legal UTF-8 string before a later
reserved name, proving byte offsets quote the right module text. Preserve the
existing AtSign diagnostic, `_` identifier error, `else:` unmatched-if error,
and valid underscore binder behavior.

Mutation oracles: keyword -> identifier; keyword -> wrong implemented role;
reserved-only -> FunctionKeyword; wildcard -> keyword; shifted/truncated quote
span; diagnostic quoted from the wrong module; source reference accidentally
retained by a later product. Every protected case must fail for its relevant
mutation. Since this refactor preserves behavior, baseline semantic tests pass;
new type-level tests naturally need the new variants. Do not present that
compile failure as a behavioral failing-first regression.

After the coordinator grants the serial slot and confirms a fresh host:

```bash
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_lex blorp_2/test/unit/test_parse \
  blorp_2/test/unit/test_utils/test_syntax.brp blorp_2/test/test_grammar
make -C blorp_2 test
scripts/blorp2-fixpoint --frontier
```

Require no frontier regression against the actual input tree, reporting its
measured numerator and denominator rather than pinning a historical file count.
Require exact status/stdout/stderr and emitted-C identity
for the frozen fixture corpus, strict zero leaks, and the cost/physical limits
above. Parser source overlaps the propagation worker; integrate on top of that
worker's accepted rewrite and preserve its statement-context changes. Root
later supplies the separate correctness/design reviews and test-runner gate.

## Handback

Return the chosen classifier shape with C/alloc evidence, source/binary/input
hashes, physical carrier and source-lifetime evidence, production/test deltas,
mutation failures, exact corpus identity and gates. Until two plan reviews and
the classifier preflight agree, this document authorizes no implementation.
