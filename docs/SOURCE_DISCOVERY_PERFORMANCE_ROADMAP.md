# Source Discovery Performance Roadmap

Status (2026-09-21): Task 4 landed on main as `91c60328d` ("Keep successful
lexer scans scalar"): `source_discovery_complete` allocations 11,964,593 to
8,467,008 (-29.2%) on the frozen self-compile, -29.6% on the small program,
byte-identical C, instructions -0.6%. Tasks 1, 2, 3, 5 and 6 remain open and
are deferred while the optimization effort moves to typechecking; the
evidence below is from `4054fe4d` at `-O0` and must be re-captured before the
next discovery round. At `-O2` the discovery phase of the self-compile takes
about 0.58 s.

Goal: reduce the instructions and small managed allocations required to read,
lex, parse, finalize, and connect the compiler's source modules. This roadmap
is intentionally narrower than the frontend-facts roadmap: every task ends at
the `source_discovery_complete` checkpoint and must preserve the exact product
handed to typechecking.

The work is split into six workstreams, each containing independently
measurable cuts. Land the workstreams in order unless a task says otherwise.
Each cut should remain small enough to revert as one commit when its mechanism
is sound but its production result is neutral or negative.

Read first:

- [`DEVELOPMENT.md`](DEVELOPMENT.md#function-profiling-and-flame-graphs) for
  profiling interpretation and contention rules;
- the [self-compile measurement
  protocol](../benchmarks/README.md#self-compile-measurement-protocol) for
  frozen inputs, build provenance, and retained results;
- [`ARCHITECTURE.md`](ARCHITECTURE.md) for the lexer, parser, finalization, and
  module-discovery boundaries;
- the parser and lexer results in [`FRONTEND_FACTS_ROADMAP.md`](FRONTEND_FACTS_ROADMAP.md),
  especially the rejected whole-token compatibility view. Do not restore a
  representation that copies a ten-field `Token` on every field read.

## Motivation and current evidence

An [exploratory discovery-only self-compile](../benchmarks/results/source_discovery_profile_2026-09-20.md)
on `4054fe4d` stopped at `--ast`, before typechecking or C emission. Five
uninstrumented samples were stable to about 0.12% in retired instructions:

| metric | current value |
| --- | ---: |
| discovery checkpoint wall time, median | 1.385 s |
| process wall time, median | 1.42 s |
| retired instructions, median | 19.49 billion |
| discovery allocations | 11,873,195 |
| discovery releases | 9,917,329 |
| live objects at the discovery boundary | 1,955,866 |
| allocator-byte delta | 145,881,168 |
| peak RSS | about 188 MiB |

The process-lifetime histogram was a close proxy for discovery in this `--ast`
run and put 97.4% of allocations at 96 bytes or smaller. A delayed native
sample put 86.6% of samples under the language-parser subtree, including 32.2%
under the lexer and 9.6% under source-AST finalization. At least 22.9% of leaf
samples were directly in `blorp_retain` or `blorp_release`; allocation, slow
release, uniqueness, and cleanup work increase that ownership share.

A valid calls profile reported these mechanism counts:

| mechanism | self-compile count |
| --- | ---: |
| `parse_compiler_source_rebased` | 1,986 |
| interpolation expression parses | 1,624 |
| ordinary source parses | 362 |
| `initial_state` | 1,986 |
| `current_tag` | 13,792,257 |
| `current_payload` | 4,077,139 |
| `source_span` | 1,918,516 |
| `source_location_from_offsets` | 1,647,830 |
| `source_span_text` | 781,271 |
| `parser_cursor_at_location_start` | 79,833 |
| `parser_cursor_at_location_end` | 3,772 |
| import resolutions | 1,874 |
| resolutions targeting an already-discovered module | 1,516 |
| source loads | 358 |
| discovered modules | 361 |

Call counts are not elapsed time. They identify repeated mechanisms; the native
sample and the deterministic allocation checkpoint determine whether removing
one matters. The exact-function profiler was not usable for this exploration
because it recorded unmatched exits, so implementations should use calls mode,
the allocation row, and an external sample until that independent tooling bug
is fixed.

## Invariants shared by all six tasks

Every task must preserve:

1. Byte-identical generated C for the frozen self-compile and small program.
2. Byte-identical `--ast` output for valid programs.
3. Exact diagnostic text, source path, line, column, and sibling ordering for
   invalid programs.
4. Formatter output and comment placement.
5. CLI and LSP agreement on module identity, import precedence, and source
   locations.
6. Import edge order, duplicate-import behavior, and the rule that source text
   is loaded at most once per resolved module identity.
7. Bounded parser stack behavior and all ownership/leak invariants.

Do not preserve an old internal API solely for compatibility. Delete the old
path and grep for stragglers in the same cut. Do not combine adjacent grammar,
diagnostic, formatting, or resolver behavior changes with an optimization.

## Common feedback loop

### Freeze one input and capture the parent baseline

Use the parent of the task branch as both the compiler baseline and the frozen
input revision. Keep that input revision fixed while evaluating the candidate.

```bash
base=$(git rev-parse HEAD)
input=$(benchmarks/self_compile_measure freeze --rev "$base")
make
scripts/compiler-build-status                 # must report FRESH

benchmarks/self_compile_measure \
  --label discovery-parent \
  --input-rev "$base" --samples 3 \
  --output /tmp/discovery-parent.json

benchmarks/self_compile_measure --program small \
  --label discovery-parent-small \
  --input-rev "$base" --samples 3 \
  --output /tmp/discovery-parent-small.json
```

For the fastest discovery-only loop, do not compile emitted C and do not enter
typechecking:

```bash
BLORP_COMPILER_MEMORY_PROFILE=1 /usr/bin/time -l \
  bin/blorp compile --ast --no-format \
  --std-dir "$input/standard_library/src" \
  "$input/blorp/src/main.brp" \
  >/tmp/discovery.ast 2>/tmp/discovery.profile
```

Record the `source_discovery_complete` allocation/release/live-object row,
retired instructions, elapsed time, and peak RSS. One warm run is enough while
iterating because the primary allocation counts are deterministic. Use three
or more samples before accepting a speed claim.

The normal self-compile harness remains the final performance and output
identity check:

```bash
benchmarks/self_compile_measure \
  --label discovery-<task> \
  --input-rev "$base" --samples 3 \
  --baseline /tmp/discovery-parent.json \
  --output /tmp/discovery-<task>.json --require-identical

benchmarks/self_compile_measure --program small \
  --label discovery-<task>-small \
  --input-rev "$base" --samples 3 \
  --baseline /tmp/discovery-parent-small.json \
  --output /tmp/discovery-<task>-small.json --require-identical
```

Store accepted raw measurements under `benchmarks/results/`. Report the exact
compiler revision, optimization level, frozen input revision, allocation rows,
minimum retired instructions, median phase time, RSS, and output identity.
Wall time alone is not acceptance evidence.

### Correctness loop

Run the smallest owning suite after each edit, then the manifest-selected and
cross-client gates once the cut is stable:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_02_lex/test_lexer.brp \
  blorp/test/compiler/stage_03_parse/test_parser.brp \
  blorp/test/compiler/stage_03_parse/test_source_ast_finalize.brp

scripts/compiler-check --changed --plan
scripts/compiler-check --changed
scripts/test --serial compiler-blorp compiler-tools lsp
```

Task 6 also runs its Stage 04 suites and the package gate. Build once, confirm
`FRESH`, and use `--no-build` only when the executable is known to match the
sources.

### Acceptance rule

A cut lands when:

- its targeted repeated operation is eliminated or reduced by the amount its
  design predicts;
- discovery allocations decrease and retired instructions do not regress
  beyond run noise, or retired instructions decrease without an allocation
  increase;
- the small program does not materially regress; and
- every applicable invariant and gate above passes.

If the mechanism disappears but both allocations and instructions are neutral,
prefer the simpler implementation. If either primary metric regresses by more
than 0.5% over three matched samples, reject or revise the cut unless a larger
measured downstream win clearly pays for it. Never stack an unaccepted cut
under the next task.

## Work order

| order | task | primary files | dependency |
| --- | --- | --- | --- |
| 1 | Parse interpolation holes as expressions | `stage_03_parse/language_parser.brp`, `source_ast_finalize.brp` | none |
| 2 | Shrink and then fuse parser-column construction | `stage_03_parse/language_parser.brp`, possibly `stage_02_lex/lexer.brp` | task 1 |
| 3 | Read each token tag once per parser decision | `stage_03_parse/language_parser.brp` | task 2 |
| 4 | Keep successful lexer scans scalar | `stage_02_lex/lexer.brp`, `token.brp` | task 2; can be developed apart from task 3 |
| 5 | Carry parser anchors instead of reconstructing cursors | `stage_03_parse/language_parser.brp` | task 3 |
| 6 | Cache typed import lookup results within one discovery | `stage_04_modules/frontend_import_plan.brp`, `pipeline.brp`, `lib/source_graph.brp`, LSP frontend graph | independent of 1-5 |

Only tasks 3 and 4 are safe to develop concurrently, because they own separate
files after task 2. All parser tasks should otherwise land sequentially.

## Task 1: Parse interpolation holes as expressions

### Why

`parse_interpolation_expr` currently wraps every hole in a fake declaration:

```blorp
message: String = "Hello ${user.name}; total=${subtotal + tax}"
```

causes two synthetic programs to be parsed:

```blorp
x=user.name
```

```blorp
x=subtotal + tax
```

The finalizer calls `parse_compiler_source_rebased`, which lexes the wrapper,
builds parser columns, runs top-level declaration dispatch, allocates a
`ParsedProgram`, appends a `VarParsedDecl`, and then discards everything except
the initializer. Interpolation accounts for 1,624 of 1,986 parser
initializations in the current self-compile.

### Target shape

Add one public expression entry at the existing parser boundary:

```blorp
record ParsedExpressionResult {
    value: Option[ParsedExpr],
    diagnostics: List[ParseDiagnostic]
}

pure func parse_compiler_expression_rebased(
    source: SourceFile,
    location_offset_delta: Int,
) -> ParsedExpressionResult:
    lex_result = lex(source)
    state = initial_state(...)
    start = skip_newlines(state, 0)
    step = parse_expression(state, start, lex_result.diagnostics, PREC_LOWEST)
    end = skip_newlines(state, step.index)
    -- Accept only EOF; otherwise report the same interpolation error contract.
```

The intended final call parses the unwrapped text:

```blorp
expression_source = source_file(source.path, module_name, text + "\n")
parsed = parse_compiler_expression_rebased(expression_source, source_start_offset)
```

First land the lower-risk control-flow cut if removing the prefix changes
multiline parsing: lex the existing `x=<expression>\n` wrapper, enter
`parse_expression` immediately after the `=`, require EOF afterward, and skip
`parse_decl`/`ParsedProgram` construction. A second measured edit may remove the
two prefix tokens. It must preserve the parser-control line/column behavior of
multiline holes; offset rebasing alone does not prove that because the prefix
also shifts the first synthetic line by two columns. If necessary, represent
that first-line column origin explicitly rather than retaining a fake
declaration for incidental padding.

The public result type must distinguish a missing expression from a valid
expression; do not use an empty declaration or a sentinel expression.

### Mechanical steps

1. Add failing tests for a direct expression parse: a name, precedence,
   postfix access/call/subscript, a multiline expression, trailing junk, an
   empty expression, and a malformed expression.
2. Extract the lex-and-`initial_state` prefix shared by program and expression
   entry points. Do not duplicate parser setup.
3. Implement the expression-to-EOF path with `parse_expression`, newline
   skipping, and an explicit EOF check.
4. Route `parse_interpolation_expr` through that path while retaining the
   wrapper initially if needed for exact first-line parser coordinates. Delete
   `ParsedProgram`, declaration dispatch, declaration-list append, and
   `VarParsedDecl` unwrapping from this route.
5. In a separate measurement, pass `text + "\n"` directly. Delete
   `INTERPOLATION_WRAPPER_PREFIX` only when AST, multiline parsing, formatter,
   and diagnostics remain identical. Otherwise add an explicit parser origin
   for the synthetic first-line column and then delete the prefix.
6. Preserve rebasing: expression offset zero must map to
   `source_start_offset`. Verify this with multibyte source preceding the hole.
7. Grep for consumers that assume a one-declaration synthetic program; they
   should be gone. The wrapper constant should also be gone after the optional
   second cut succeeds.

### Tests to add before implementation

- nested calls, collections, lambdas, and braces inside a hole;
- strings and escaped braces inside a hole;
- multiple holes with the same text, proving sibling order and locations;
- a hole after tabs and after non-ASCII text;
- malformed first, middle, and last holes, preserving all diagnostic strings
  and authored coordinates;
- a hole containing a newline and a nested interpolated string;
- trailing tokens that previously could not masquerade as another declaration.

The existing location, duplicate-hole, diagnostic-order, source-path, and
deep-spine tests in `test_source_ast_finalize.brp` are the primary oracle.

### Fast measurement and acceptance

Use a calls-profiled compiler for `stage_03_parse/language_parser` and
`source_ast_finalize`. On the same frozen input:

- `parse_compiler_source_rebased` must fall from 1,986 calls to the ordinary
  source count, approximately 362;
- the new expression entry must run once per interpolation hole;
- declaration parsing and `ParsedProgram` construction must not occur beneath
  the expression entry;
- AST, diagnostics, formatter output, and generated C must be identical; and
- discovery allocations must decrease with no instruction regression.

This task deliberately retains one lexer and parser-column setup per hole.
Removing those costs belongs to task 2; do not expand task 1 into lexer modes.

## Task 2: Shrink and then fuse parser-column construction

### Why

`initial_state` projects each inline ten-field `Token` into ten lists. It runs
once per source or interpolation-hole parse and represented 7.2% of leaf
samples in the exploratory native profile. Two projected columns,
`trivia_starts` and `trivia_counts`, are not read anywhere by the parser.
`end_lines` and `end_columns` exist only for the rare end-cursor reconstruction
that task 5 narrows.

The columns themselves are intentional: the rejected alternative copied a
whole ten-field inline token every time the parser wanted one field. This task
must reduce construction without returning to that access pattern.

### Cut 2A: remove dead and cold columns

1. Add a parser-input construction test that compares every retained scalar
   field against the lexer token from which it came.
2. Delete `trivia_starts` and `trivia_counts` from `ParserInput` and
   `initial_state`.
3. Record `end_lines` and `end_columns` as task 5 cleanup; task 2 must retain
   them while cursor reconstruction still reads them.
4. Keep `tags`, `payloads`, start/end offsets, and the line/column columns that
   have hot parser consumers.
5. Measure and land this cut independently before attempting fusion.

Expected intermediate shape:

```blorp
private record ParserInput {
    source: SourceFile,
    file_id: SourceFileId,
    location_offset_delta: Int,
    tags: List[TokenTag],
    payloads: List[Int],
    start_offsets: List[Int],
    start_lines: List[Int],
    start_columns: List[Int],
    end_offsets: List[Int],
    end_lines: List[Int],
    end_columns: List[Int],
    texts: List[String]
}
```

Treat that as a sketch, not permission to delete a column with a live hot-path
consumer.

### Cut 2B: build parser columns during lexing

Proceed only if `initial_state` remains visible after 2A. Introduce a precise
parser-oriented lex product rather than a boolean such as `with_columns`:

```blorp
record ParserLexResult {
    columns: ParserTokenColumns,
    texts: List[String],
    diagnostics: List[ParseDiagnostic]
}
```

Keep the ordinary `LexResult` for formatter/comment and lexer-test clients.
Both public entry points must share one internal lexer builder; do not fork the
scanner. When the lexer publishes a token, the parser route appends that
token's scalar fields directly to unique local columns. It must not first append
the `Token` and later copy it into columns.

If Blorp's ownership behavior makes a dual-output internal builder allocate
more than the existing second pass, stop after 2A. Do not keep both full tokens
and full columns in a parser-only result.

### Correctness and acceptance

- All lexer token/trivia tests remain byte- and value-identical.
- Parser AST and diagnostics remain identical, including EOF and synthetic
  indentation tokens that can share offsets.
- Formatter and typed-source comment JSON remain identical; they continue to
  use ordinary `LexResult`.
- 2A must eliminate exactly two list constructions and two appends per token.
- If 2B lands, `initial_state` must disappear from the calls profile and the
  parser route must publish no intermediate `List[Token]`.
- Discovery allocations and instructions must improve. Reject 2B if its API
  and second lexer product are not paid for by a measurable result.

## Task 3: Read each token tag once per parser decision

### Why

The parser called `current_tag` 13.79 million times, plus 4.08 million
`current_payload` calls. A single decision often asks several questions about
the same token:

```blorp
if current_is_keyword(state, index, IfKeyword):
    ...
else if current_is_keyword(state, index, MatchKeyword):
    ...
else if current_is_keyword(state, index, SelectKeyword):
    ...
```

Each predicate rereads the tag list, and a matching predicate then rereads the
payload list. The change is local caching, not a new parser architecture.

### Target shape

Use a scalar-only view that stays inline:

```blorp
private struct ParserTokenHead {
    tag: TokenTag,
    payload: Int
}

private pure func token_head_at(state: ParserInput, index: Int) -> ParserTokenHead:
    {
        tag = current_tag(state, index),
        payload = current_payload(state, index)
    }

private pure func head_is_keyword(head: ParserTokenHead, expected: Keyword) -> Bool:
    head.tag == KeywordTag and keyword_from_ordinal(head.payload) == expected
```

Do not add source strings, lists, unions, or locations to this struct. Keep the
existing index-based helpers for sites that ask one question; loading an unused
payload everywhere could erase the win.

### Mechanical steps

1. Add a temporary or retained counter test proving that a representative
   dispatch reads one tag and at most one payload.
2. Introduce scalar `head_is_*` helpers beside the existing index helpers.
3. Convert one high-frequency decision family at a time:
   expression/statement dispatch, infix loops, type dispatch, pattern dispatch,
   and declaration dispatch.
4. Bind `head = token_head_at(state, index)` once at the top of each decision.
   Refresh it only after `index` changes.
5. Convert loops such as `*`/`/` and `+`/`-` to one tag/payload match rather
   than two or more `current_is_symbol` calls per iteration.
6. After the final family, grep for adjacent predicates on the same unchanged
   index. Leave single-use helpers intact.

Example loop conversion:

```blorp
while True:
    head = token_head_at(state, st)
    op = match head:
        { tag = SymbolTag, payload = symbol_ordinal(StarSymbol) }:
            Some(MultiplyOp)
        { tag = SymbolTag, payload = symbol_ordinal(SlashSymbol) }:
            Some(DivideOp)
        _:
            None
    match op:
        Some(found):
            ...
        None:
            break
```

Use legal existing Blorp match syntax in the implementation; the sketch shows
the desired one-read control flow, not a required surface form.

### Acceptance

- Convert and measure each grammar family separately; revert any family whose
  generated compiler code becomes more expensive.
- `current_tag` calls should fall by at least 25% from the frozen baseline and
  `current_payload` must not increase.
- No new heap allocation may be attributed to `ParserTokenHead`.
- Parser, formatter, diagnostic, AST, LSP, and generated-C oracles remain
  identical.
- Discovery retired instructions decrease; an allocation reduction is welcome
  but not required for this instruction-oriented task.

## Task 4: Keep successful lexer scans scalar

### Why

Tokens are already inline structs, but successful lexer paths repeatedly build
heap-managed `SourceSpan` and `TokenKind` compatibility values, only to flatten
them into scalar token fields. The self-compile called `source_span` 1.92
million times and `source_span_text` 781 thousand times.

For example, the identifier path currently does this:

```blorp
end_cursor = identifier_end_cursor(source, cursor)
span = source_span(source, cursor, end_cursor)
word = source_span_text(source, span)
kind = IdentifierToken(word)
tagged = tagged_payload_for(kind, id)
token = token_with_trivia_range(tagged.tag, tagged.id, span, ...)
```

The token ultimately retains only tag, payload, cursor scalars, and trivia
indexes.

### Target shape

Add a constructor that accepts cursors directly:

```blorp
pure func token_from_cursors(
    tag: TokenTag,
    payload: Int,
    start: Cursor,
    end: Cursor,
    trivia_start: Int,
    trivia_count: Int,
) -> Token:
    {
        kind = tag,
        payload = payload,
        start_offset = start.offset,
        start_line = start.line,
        start_column = start.column,
        end_offset = end.offset,
        end_line = end.line,
        end_column = end.column,
        trivia_start = trivia_start,
        trivia_count = trivia_count
    }
```

Successful scanner results should return cursors and scalar classification:

```blorp
private record LiteralScan {
    end_cursor: Cursor,
    tag: Option[TokenTag],
    payload_text: Option[String],
    diagnostics: List[ParseDiagnostic]
}
```

That sketch may be split into precise variants if `Option` combinations admit
illegal states. Prefer separate success/error variants or exact scalar fields
over boolean flags. Do not retain a `SourceSpan` merely for token construction.

### Mechanical steps

1. Add token-constructor parity tests for offsets, lines, columns, payload,
   EOF, indent/dedent, and shared-offset synthetic tokens.
2. Introduce `token_from_cursors`; migrate punctuation and underscore first.
   This is the lowest-risk proof and should remove their `source_span` calls.
3. For identifiers and numbers, slice `source.text` from scalar offsets. Build
   a `SourceSpan` only on the numeric-overflow diagnostic path.
4. Change literal and pipe-block scan results to carry their start/end cursors.
   Materialize a span only when producing a diagnostic or retained trivia.
5. Return `TokenTag` and the final scalar payload from scanners where possible;
   do not create a boxed `TokenKind` simply to immediately call
   `tagged_payload_for`.
6. Replace `last_token_kind: Option[TokenKind]` with the scalar fact its sole
   consumer needs, for example `last_token_was_colon: Bool`.
   `can_enter_lambda_body_at` asks only whether the preceding token was
   `SymbolToken(ColonSymbol)`; retaining every complete kind for that question
   would keep one boxed `TokenKind` allocation on every migrated success path.
   Update the Boolean from the tag/payload already computed at token publish.
7. Keep `SourceSpan` for comments/trivia and diagnostics because those values
   escape lexing and require path/line/column rendering.
8. Delete migrated constructors and compatibility calls once their final
   production caller is gone.

### Edge cases and tests

- tabs at token starts and ends;
- CR/LF and EOF without a final newline;
- multibyte UTF-8 before and inside literals;
- escaped Unicode, invalid Unicode, and invalid bytes;
- docstrings, pipe strings, raw strings, nested interpolation, and maximum
  interpolation depth;
- integer overflow diagnostics;
- leading and trailing comments, including comments attached to newline and
  dedent boundaries;
- every multi-character symbol.

### Acceptance

- Token and trivia values are identical for the complete lexer suite.
- `source_span` calls on successful, trivia-free token paths are zero; retained
  calls are attributable to diagnostics or trivia.
- `TokenKind` construction is absent from migrated scalar success paths,
  including previous-token tracking; `last_token_kind` no longer exists.
- `source_discovery_complete` allocations decrease and instructions do not
  regress. Measure punctuation-only, identifier-heavy, literal-heavy, small,
  and self-compile inputs so one token family cannot hide another's regression.

## Task 5: Carry parser anchors instead of reconstructing cursors

### Why

AST nodes retain compact byte-offset locations, which is the correct
cross-stage representation. A few parser-local decisions nevertheless convert
those locations back into cursors by binary-searching token offset columns.
`parser_cursor_at_location_start` ran 79,833 times; most calls recover the
line/column of a block header that the parser had as a token cursor moments
earlier.

Do not put line and column back on every AST node. Preserve parser-local facts
until the last parser consumer instead.

### Target shape

Introduce an inline parser-local anchor:

```blorp
private struct ParserAnchor {
    line: Int,
    column: Int
}

private pure func token_start_anchor(state: ParserInput, index: Int) -> ParserAnchor:
    {
        line = state.start_lines.get_or(index, 1),
        column = state.start_columns.get_or(index, 1)
    }
```

Pass the anchor into block consumers:

```blorp
header = token_start_anchor(state, header_index)
body = parse_statement_list(state, body_index, diagnostics, header)
```

instead of:

```blorp
body = parse_statement_list(state, body_index, diagnostics, header_span)
-- parse_statement_list calls parser_cursor_at_location_start(header_span)
```

The AST continues to receive the compact `SourceLocation`; only the temporary
parse-step/result carries the anchor or originating token index.

### Mechanical steps

1. Add tests for indentation comparisons after tabs, multiline headers,
   nested blocks, same-line headers, recovery after a missing indent, and
   rebased interpolation expressions.
2. Inventory the four static start-cursor call sites and identify the parse
   function that originally owns each header token index.
3. Add `ParserAnchor` or an originating `TokenRange` to the narrowest parse-step
   result that already transports the header span.
4. Thread that value only through the block/list helper chain. Do not add it to
   published AST types.
5. Replace `current_token_is_indented_past(..., SourceLocation)` with an anchor
   overload and delete the location-to-cursor conversion on successful paths.
6. Treat `parser_cursor_at_location_end` separately. Its 3,772 calls support
   leading-dot continuation detection over an already-built expression. First
   carry a scalar end line or the relevant boolean in the parser-local result;
   retain a source-scan fallback only for error/synthetic cases.
7. Delete the binary-search helpers if no production success path remains. If a
   cold diagnostic fallback still requires them, rename and document it as
   such.

### Acceptance

- `parser_cursor_at_location_start` has zero successful-parse calls in the
  self-compile; a retained cold fallback must be unobserved.
- End-cursor calls either disappear or have a documented, measured residual
  count substantially below 3,772.
- No published parsed/typed/Core node gains line, column, cursor, or token-index
  fields.
- Parser columns removed by task 2 are not restored.
- Indentation, formatter, AST, diagnostic, and generated-C results are
  identical; discovery instructions and allocations do not regress.

## Task 6: Cache typed import lookup results within one discovery

### Why

The current graph walk correctly deduplicates loading: 1,874 import edges
produced only 358 source loads for 361 discovered modules. However, every edge
still executes its lookup plan and filesystem/snapshot checks before the graph
can discover that the target identity is already present. In the current
self-compile, 1,516 resolutions, or 80.9%, targeted an already-discovered
module.

A cache keyed only by the source spelling is wrong:

```blorp
-- a/main.brp
import:
    ./helper

-- b/main.brp
import:
    ./helper
```

The two requests resolve relative to different directories. A bare import can
also mean a source-package export, a standard-library module, or a local file,
depending on importer origin and lookup precedence.

### Correct cache boundary

Cache exact `FrontendImportLookup` attempts, not raw requested paths and not
only final module identities. The union already represents the semantic
distinctions:

```blorp
union FrontendImportLookup:
    FrontendNativePackageLookup(String)
    FrontendStandardLibraryLookup(String)
    FrontendRelativePathLookup(String, ModuleOrigin)
    FrontendSourcePackageAliasLookup(String)
    FrontendSourcePackageInternalLookup(String, String)
    FrontendLocalPathLookup(String)
```

Use one cache namespace per variant, with every contextual field in its key.
Cache both hits and misses, since repeated failed package-alias probes followed
by the same standard-library hit are common. Values are locations only—never
source text—so the existing load-once rule remains owned by
`frontend_graph_discover`.

A concrete shape is:

```blorp
record FrontendLookupCache {
    native: Dict[String, Option[FrontendSourceLocation]],
    standard_library: Dict[String, Option[FrontendSourceLocation]],
    relative: Dict[String, Option[FrontendSourceLocation]],
    source_package_alias: Dict[String, Option[FrontendSourceLocation]],
    source_package_internal: Dict[String, Option[FrontendSourceLocation]],
    local: Dict[String, Option[FrontendSourceLocation]]
}
```

For compound keys, use an explicit length-prefixed storage-key helper or a
precise key type if `Dict` supports it. Never concatenate fields with an
ambiguous separator. The variant-specific dictionaries prevent cross-variant
collisions.

### Mechanical steps

1. Add counters around lookup planning, each lookup variant, cache hit/miss,
   `file_exists`, embedded-standard-library lookup, and source load. Capture the
   small and self-compile baselines before changing control flow.
2. Add unit tests showing which requests may share a lookup and which must not:
   two standard-library imports, two package aliases, two different relative
   directories, package-internal imports with different aliases, native
   package roots, and a local file shadowing an absent standard module.
3. Change the discovery resolver boundary so one owner holds a mutable
   `FrontendLookupCache` for exactly one graph discovery. Because Blorp closures
   cannot capture mutable locals, make this state explicit; do not hide it in a
   global or thread-local.
4. Prefer having `frontend_graph_discover` own the local cache while the CLI and
   LSP providers supply typed lookup-plan and single-lookup callbacks. This
   keeps one traversal and one caching policy for both clients.
5. Resolve each plan in order. For each typed lookup, return the cached
   hit/miss when present; otherwise call the provider once and store the
   result. Stop at the first hit exactly as today.
6. Continue recording an import edge for every source import occurrence, even
   when resolution was cached.
7. Leave source loading behind the existing
   `discovered_by_identity` check. Never cache or eagerly read source text in
   the resolver.
8. Apply the same typed contract to the LSP immutable source snapshot. Do not
   let the CLI and LSP grow separate precedence logic.
9. Remove temporary counters unless they are useful, cheap, environment-gated
   diagnostics with a documented schema.

Caching assumes the source provider is stable for the duration of one graph
discovery. The CLI already treats a file disappearing between resolution and
load as an unsupported concurrent filesystem change; the cache does not extend
that assumption beyond the current compile.

### Files and focused tests

Primary production ownership:

- `stage_04_modules/frontend_import_plan.brp`: typed lookup plan and cache key;
- `compiler/pipeline.brp`: discovery traversal, edge order, identity dedup;
- `lib/source_graph.brp`: CLI filesystem/package lookup implementation;
- `lsp/analysis/frontend_graph.brp`: immutable-snapshot lookup implementation.

Focused tests:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_04_modules/test_frontend_import_plan.brp \
  blorp/test/compiler/stage_04_modules/test_frontend_graph_service.brp \
  blorp/test/compiler/stage_04_modules/test_frontend_graph.brp \
  blorp/test/lsp/analysis/test_lsp_frontend_graph.brp

scripts/test --no-build --serial package lsp
```

Add a provider-spy test that asserts exact lookup counts. It should include two
importers sharing a standard-library target, two same-spelling relative imports
from different directories, a repeated miss, an identity conflict, a cycle,
and duplicate import declarations. Compare the complete ordered edge list, not
only the discovered module set.

### Acceptance

- Source loads remain approximately the number of newly discovered identities
  and never increase from the 358 baseline.
- Each distinct typed lookup key invokes its provider at most once per graph
  discovery; repeated hits and repeated misses are served from the cache.
- The retained counter report shows a meaningful fall in provider lookups and
  `file_exists`/snapshot probes. If the frozen self-compile has too few
  duplicate typed keys to move discovery allocations or instructions, reject
  the production cache rather than keeping unearned complexity.
- CLI and LSP resolve every ambiguity fixture identically; paths, origins,
  module names, edge order, diagnostics, AST, and generated C are identical.
- The cache is scoped to one discovery. A new compile or LSP snapshot does not
  reuse stale filesystem or source-snapshot answers.

## Completion criteria for the roadmap

The roadmap is complete when all accepted cuts are on main and a fresh profile
shows the new shape, not merely lower aggregate numbers:

- interpolation holes use the expression entry and create no fake declarations;
- parser setup creates only columns the parser reads, and no parser-only
  intermediate token list if fused construction proved worthwhile;
- high-frequency decisions load one token tag per unchanged index;
- successful token scans do not allocate `SourceSpan` or boxed `TokenKind`
  compatibility values;
- successful block parsing does not reconstruct cursors from AST locations;
- repeated typed import lookups are served once per discovery when the cache
  produces a measurable win;
- the frozen self-compile and small-program results contain byte-identical C,
  and all parser, formatter, compiler, package, and LSP gates pass.

Publish one retained measurement per landed task rather than only a final
cumulative comparison. That makes a neutral or negative idea removable without
losing the evidence that justified the other cuts.
