# Parser API And Blorp Frontend Roadmap

Status: active design roadmap, created 2026-06-25.

This roadmap covers two connected pieces of work:

1. Replacing `std/parser.brp` with a cursor/span based parser utility API.
2. Using that improved foundation while beginning the Blorp-owned compilation
   frontend, starting with file reads, lexing, and parsing.

The near-term compiler pipeline is allowed to be:

```text
Blorp file reads + parser
  -> single compiler bridge boundary
  -> OCaml module loading, inference, typecheck, Core middle
  -> same compiler bridge boundary
  -> Blorp Core tail and C emission
```

The migration must keep one bridge subsystem and one protocol. Different
actions may move through that protocol while ownership is being migrated, but
frontend parser handoff must not grow a second ad hoc bridge path.

## Goals

- Make parsing position based instead of remaining-string based.
- Keep parser input stable and return cursors/spans, not allocated suffixes.
- Return structured errors with line, column, offset, expected labels, and
  commitment state.
- Make parser utilities pure by default.
- Prevent repetition combinators from looping forever when a parser succeeds
  without consuming input.
- Give compiler code a low-level cursor API that avoids closure-heavy
  combinator style in hot paths.
- Keep Blorp source-file I/O in Blorp for the new frontend path.
- Keep the compiler parser itself explicit: scanner plus recursive
  descent/Pratt parser, not a large combinator parser.

## Non-Goals

- Do not preserve the current `ParseResult[T] = Success(T, remaining: String)
  | Failure(message: String, remaining: String)` API.
- Do not force existing format parsers such as JSON onto the new combinators.
  Existing indexed scanners can keep their direct state machines.
- Do not build a parser generator before the first self-hosted parser slice.
- Do not make source parsing depend on file I/O. File reads belong to the Blorp
  frontend shell; parsing remains pure over an explicit source value.
- Do not preserve obsolete syntax with compatibility shims or migration
  diagnostics. Blorp has few users today, so removed spellings should be
  deleted and left to fail through ordinary lexer/parser errors.

## Current Std Parser Audit

`std/parser.brp` is useful as a small teaching/composition helper, but it is not
a good base for compiler parsing.

Problems to fix:

- The core result carries remaining `String`, causing repeated suffix
  allocation in primitives such as `any_char`, `satisfy`, `literal`,
  `skip_whitespace`, and `take_while`.
- Failure values carry only a message and remaining input. They do not carry
  line, column, offset, span, expected labels, or recovery context.
- `many`, `many1`, and `sep_by` do not guard against successful parsers that
  make no progress.
- The `StringSlice` branch is incomplete. It has primitive helpers, but no full
  combinator family and still materializes strings when converted back to
  `ParseResult`.
- `between` is declared impure despite pure callback parameters and a pure
  body.
- The apparent impure `slice_map` overload has no real implementation body
  before the pure overload.
- Tests cover only a small part of the API.

Useful precedent already exists in std:

- `std/json.brp` uses an indexed scanner and adapts to `ParseResult` only at
  the compatibility boundary.
- `std/yaml.brp` uses explicit parser state with `pos`, `line`, and `col`.

Those are closer to the compiler parser shape than the remaining-string
combinators.

## Inspirations

Use these as design references, not as APIs to copy mechanically:

- Go `scanner`, `parser`, and `token.FileSet`: clean source file, position,
  token, AST, and diagnostic boundaries.
- TypeScript parser: practical hand-written scanner plus recursive descent with
  lookahead, recovery, and node spans.
- Megaparsec/Parsec: ergonomic parser labels, expected-token sets, choice, and
  committed failures.
- nom/winnow: stable input plus offsets/slices instead of suffix allocation.
- SwiftSyntax/tree-sitter: later inspiration for lossless syntax, trivia, and
  recovery, not a phase-one requirement.

## Target Std API Shape

The std parser API should have a low-level position core plus ergonomic
combinators on top.

Core data model:

```blorp
record Source {
	text: String,
	path: Option[String]
}

record Cursor {
	offset: Int,
	line: Int,
	column: Int
}

record Span {
	start_offset: Int,
	start_line: Int,
	start_column: Int,
	end_offset: Int,
	end_line: Int,
	end_column: Int
}

record ParseError {
	span: Span,
	message: String,
	expected: List[String],
	committed: Bool
}

union ParseResult[T]:
	Parsed(T, Cursor)
	ParseFailed(ParseError)
```

Low-level primitives:

```blorp
pure func source(text: String) -> Source
pure func source_with_path(text: String, path: String) -> Source
pure func start(source: Source) -> Cursor
pure func cursor_at(source: Source, offset: Int) -> Cursor
pure func at_end(source: Source, cursor: Cursor) -> Bool
pure func peek(source: Source, cursor: Cursor) -> Option[Char]
pure func advance(source: Source, cursor: Cursor) -> Cursor
pure func make_span(start: Cursor, end: Cursor) -> Span
pure func span_start(span: Span) -> Cursor
pure func span_end(span: Span) -> Cursor
pure func span_text(source: Source, span: Span) -> String
pure func format_error(source: Source, error: ParseError) -> String
```

Implementation note: the initial std API uses records for `Cursor` and `Span`.
`Span` stores primitive start/end fields rather than nested `Cursor` records so
spans survive generic parser combinators and list storage without relying on
nested record ownership behavior. If compiler/runtime ownership for structs and
nested records improves later, the internal representation can be revisited
without changing the semantic API.

Parser primitives:

```blorp
pure func any_char(source: Source, cursor: Cursor) -> ParseResult[Char]
pure func satisfy(source: Source, cursor: Cursor, label: String, pred: pure (Char) -> Bool) -> ParseResult[Char]
pure func char(source: Source, cursor: Cursor, expected: Char) -> ParseResult[Char]
pure func literal(source: Source, cursor: Cursor, expected: String) -> ParseResult[Span]
pure func take_while(source: Source, cursor: Cursor, pred: pure (Char) -> Bool) -> ParseResult[Span]
pure func take_while1(source: Source, cursor: Cursor, label: String, pred: pure (Char) -> Bool) -> ParseResult[Span]
```

Ergonomic combinator layer:

```blorp
type alias Parser[T] = pure (Source, Cursor) -> ParseResult[T]

pure func run[T](parser: Parser[T], source: Source) -> Result[T, ParseError]
pure func label[T](parser: Parser[T], expected: String) -> Parser[T]
pure func commit[T](parser: Parser[T]) -> Parser[T]
pure func or_else[T](first: Parser[T], second: Parser[T]) -> Parser[T]
pure func optional[T](parser: Parser[T]) -> Parser[Option[T]]
pure func many[T](parser: Parser[T]) -> Parser[List[T]]
pure func many1[T](parser: Parser[T]) -> Parser[List[T]]
pure func sep_by[T, S](item: Parser[T], sep: Parser[S]) -> Parser[List[T]]
pure func between[T, A, B](open: Parser[A], item: Parser[T], close: Parser[B]) -> Parser[T]
```

The compiler parser should prefer the low-level primitives and direct
source/cursor functions in hot paths. The higher-level `Parser[T]` API is for
small parsers, tests, and user code where ergonomics matter more than closure
allocation.

## Migration Plan

### Slice 1: Strengthen Std Parser Tests

Status: implemented in `tests/test_blorp/text/test_parser_combinators.brp`.

Add tests before replacing the implementation:

- primitive success and failure cases;
- cursor offset and line/column advancement;
- expected labels in errors;
- formatted error output;
- `many` no-progress protection;
- `sep_by` trailing separator behavior;
- `between` callable from pure parser code;
- no public remaining-string API in the new module.

Current tests in `tests/test_blorp/text/test_parser_combinators.brp` should be
rewritten around the new API instead of preserving old names.

### Slice 2: Replace Core Types

Status: implemented in `std/parser.brp`.

Replace `ParseResult`, add `Source`, `Cursor`, `Span`, and `ParseError`, and
delete the remaining-string representation.

Acceptance criteria:

- `std/parser.brp` typechecks.
- New unit/runtime tests pass.
- `docs/GUIDE.md` describes the new API.
- Old constructors `Success` and `Failure` are gone from `std/parser.brp`.

### Slice 3: Implement Cursor Primitives

Status: implemented in `std/parser.brp`.

Implement source/cursor helpers and primitive parsers directly over the stable
source string.

Rules:

- `advance` updates line and column once.
- `literal` returns a `Span`, not a copied string.
- `take_while` returns a `Span`.
- Materialization happens only through `span_text`.

Acceptance criteria:

- Tests prove offsets and line/column values across newlines.
- Tests prove matched text can be materialized from spans.
- No primitive parser returns a source suffix.

### Slice 4: Implement Safe Combinators

Status: implemented in `std/parser.brp`.

Add the ergonomic combinator layer with progress protection.

Rules:

- `many`, `many1`, and `sep_by` return `ParseFailed` if their inner parser
  succeeds without advancing.
- `or_else` should prefer the error that reached farther into the source.
- `label` should replace or augment expected labels without destroying the
  concrete error location.
- `commit` should prevent `or_else` from backtracking after a committed
  failure.

Acceptance criteria:

- No-progress parser tests fail safely instead of hanging.
- Expected labels are deterministic.
- Pure higher-order parsers can be called from pure functions.

### Slice 5: Update Existing Users

Status: implemented for current std/tests/docs users.

Update current references to `parser.ParseResult` and old constructors.

Known users:

- `std/json.brp` compatibility `parse` wrapper;
- `tests/test_blorp/text/test_json_parser.brp`;
- `tests/test_blorp/text/test_codec_bridges.brp`;
- `tests/test_blorp/text/test_parser_combinators.brp`;
- parser docs in `docs/GUIDE.md`;
- any typecheck fixtures that imported old `ParseResult` constructors.

JSON can keep its indexed scanner. Its compatibility wrapper can either return
the new `ParseResult` or be removed in favor of `Result` if that produces a
cleaner current API.

Acceptance criteria:

- `scripts/test runtime doctest compiler --serial` passes, or the narrower
  affected gates pass during the slice and the full gate runs before merge.
- No old remaining-string constructor imports remain.

### Slice 6: Add Compiler Parser Foundation Types

Status: implemented in `compiler/blorp/compiler_source.brp`,
`compiler_parse_diagnostic.brp`, `compiler_token.brp`, and
`compiler_parsed_ast.brp`.

Add compiler-local source/parser modules under `compiler/blorp`, likely:

- `compiler_source.brp`;
- `compiler_token.brp`;
- `compiler_parse_diagnostic.brp`;
- `compiler_parsed_ast.brp`.

These should build on the cursor concepts, but they should not expose std
combinator details as compiler architecture.

Compiler source input should include:

```blorp
record CompilerSourceFile {
	path: String,
	module_name: String,
	text: String
}
```

The Blorp frontend shell owns file reads and constructs `CompilerSourceFile`
values. The parser remains pure over those values.

Current scope: this slice adds source/cursor/span helpers, structured parse
diagnostics, token/trivia representation, a minimal parsed-program envelope, an
initial pure lexer, and a first parser foundation. The lexer covers keywords,
identifiers, numeric literals, ordinary/raw string literals, pipe strings,
string interpolation payloads, char literals with Unicode validation, docstring
tokens, current punctuation/operator tokens, indentation/dedentation, comment
trivia, tab-aware spans, newline suppression inside
grouping tokens, and lambda-body newline handling inside grouping tokens. The
parser currently covers function declarations with type parameters, explicit
named/wildcard/tuple parameter binders, return types, docstrings, purity
metadata, top-level declaration diagnostics, and a precedence expression core
for literals, names, unary/binary/logical
operators, ranges, calls, fields, subscripts, list literals, tuple expressions,
record literals, record updates, dict literals, vector/tensor literals,
char literals, indented block bodies, `if`/`else`, simple `match` cases with
qualified constructor patterns, literal patterns, and `|` pattern alternatives,
tuple patterns, list patterns with optional terminal spreads, lambda expressions
with optional parameter and return annotations, function annotations, qualified
type names, `while`, `for`,
`break`/`continue`, void primaries, local `var`
declarations, typed bindings, assignments, subscript assignments, compound
assignments, `?=` bindings, tuple destructuring assignments, expression
ascriptions, opaque type conversions, builtin
function-body markers, bounded generic parameters, dimension parameters, tensor
array/range/function/tuple types, import blocks, records, structs, unions,
enums, builtin/resource type declarations, ordinary and opaque type aliases,
foreign blocks, trait and impl declarations, and top-level var/const
declarations. It is also now representing private declaration wrappers
explicitly. Structured concurrency coverage includes `concurrent:` blocks,
`for ... concurrently(...)` loops, `detach`, and `select:` blocks. The parser
also represents `with` resource blocks and `debug:` blocks explicitly.
Ordinary `for` loops represent named and tuple destructuring binders. Hoisted
compiler source parsing now uses the Blorp frontend parser by default through
the bridge protocol. Source-preserving callers pass `hoist_nested=false` to
retain parser-level nested function declarations, but this no longer selects a
different frontend parser.

### Slice 7: Blorp Lexer

Build a dedicated compiler lexer that returns tokens with spans and trivia.

Requirements:

- indentation stack with `Indent` and `Dedent`; done for the initial lexer;
- newline suppression inside grouping tokens; done for the initial lexer;
- lambda-body newline behavior; done for the initial lexer;
- comments returned explicitly, not stored globally; line comments and
  docstring tokens are done;
- raw strings, pipe strings, string interpolation raw payloads; done for the
  initial lexer;
- char literal and Unicode validation; done for the initial lexer.

Acceptance criteria:

- Token parity tests against representative current OCaml lexer behavior.
- Fixture tests for indentation, strings, comments, docstrings, and common
  syntax errors.
- No global lexer state.

### Slice 8: Blorp Parser

Status: initial foundation implemented in `compiler/blorp/compiler_parser.brp`.
The current declaration surface includes functions, imports, builtin/resource
types, type aliases, records/structs, unions/enums, traits/impls, top-level
vars/consts, private wrappers, and foreign blocks. Expression coverage includes
structured concurrency blocks, concurrent loops, `detach`, `select:`, and
`with`/`debug:` blocks, expression ascriptions, and tuple destructuring
assignments. Pattern coverage includes
qualified constructors, literal patterns, negative numeric literals, and `|`
alternatives, 2-4 element tuple patterns, and list patterns with optional
terminal name or wildcard spreads. Ordinary `for` loops support named binders,
`_`, and 2-4 element tuple destructuring. Function parameters support named
binders, bare `_` wildcard binders, typed `_` name binders to preserve the
current OCaml AST contract, and 2-4 element tuple binders with optional tuple
type annotations. It also covers leading-dot postfix continuations, multiline
assignment values, multiline function parameter lists, bodyless overload
signatures with or without a trailing colon, subscript assignment statements,
and opaque type aliases with `into Type(expr)` / `from Type(expr)`
conversions. The parser intentionally does not preserve removed syntax or
other-language spellings with migration diagnostics; those forms should fail
through the ordinary parser path. The compiler parser fixtures now run through
the Blorp parser by default, with frontend-specific diagnostic expectations
where the Blorp parser reports a clearer or differently located error.

Build the compiler parser as scanner plus recursive descent/Pratt parser.

Use direct parser functions shaped like:

```blorp
pure func parse_expr(state: ParserState, min_precedence: Int) -> ParseResult[Expr]
pure func parse_decl(state: ParserState) -> ParseResult[Decl]
pure func parse_type_expr(state: ParserState) -> ParseResult[TypeExpr]
pure func parse_pattern(state: ParserState) -> ParseResult[Pattern]
```

Do not build the whole compiler parser as a combinator parser. Use the std
parser utilities for small reusable helpers only where they keep the code
clear.

Acceptance criteria:

- Existing parser fixtures pass through Blorp parser parity:
  `tests/test_compiler/parser/should_pass` and
  `tests/test_compiler/parser/should_fail`.
- AST parity covers the stage parser fixtures in `tests/stages/parser/ast`.
- Error substring and representative line/column assertions match current
  behavior.

### Slice 9: Bridge Into Production

Status: implemented for hoisted compiler parsing. The bridge protocol has a
live `parse_source` action, Blorp can project parsed AST JSON, and OCaml has a
typed decoder for source spans, common expression/type nodes, ordinary
top-level declarations including imports, vars, records, unions,
builtin/resource types, aliases, traits, impls, foreign blocks, data literals,
match cases, lambdas, resource/select/concurrency expression forms, builtin
function-body normalization, expression ascriptions, char literals,
literal/or/tuple/list patterns, ordinary `for` tuple binders,
named/wildcard/tuple function parameter binders, tuple destructuring
assignments, subscript assignments, opaque alias metadata, opaque conversions,
and explicit unsupported-node failures.

The parser dispatcher now imports the Blorp lexer/parser and returns a
`parsed_ast` artifact through the existing bridge response envelope. Bringing
that online exposed two general C-emission issues in the helper cold-build path:
heap record/union forward declarations across recursive AST shapes, and nested
enum payload matches stored in erased union fields. Both fixes are in the shared
emitter paths.

The production bridge keeps one OCaml bridge layer and one protocol envelope,
but it intentionally builds two helper binaries while the compiler is still
bootstrapping itself. Backend/Core requests use the bootstrap-small
`compiler_bridge_cli.brp` helper, which is compiled by the pinned bootstrap by
default in renderer-helper mode with the private
`BLORP_COMPILER_BOOTSTRAP_MENHIR_PARSER=1` marker. Parser requests use
`compiler_parser_bridge_cli.brp`,
which carries the parser-heavy imports and is also compiled by the pinned
bootstrap with the same helper-mode markers. This lets both helpers be built
without recursively requiring either helper to already exist. The
production bridge remains one subsystem and one protocol envelope, not
parser-specific handoff logic. The marker is interpreted once at the fresh
compilation-session boundary and becomes a session-local bootstrap parser mode;
`Modules.parse_source` does not read process environment to choose a frontend.
Until the bootstrap pin advances past the parser-bridge split, the bootstrap
wrapper sets the retired `BLORP_FRONTEND_PARSER=ocaml` knob only for that pinned
external binary while it is in renderer-helper mode; normal current-compiler
source parsing no longer reads it.

OCaml now has a single source parse entry path in `Modules`, and that path uses
the Blorp bridge parser. The `hoist_nested` flag controls only post-parse
nested-function hoisting. Filesystem-backed parses whose supplied source
matches the file on disk request `parse_source` with only path/module metadata;
the Blorp bridge CLI reads the source file and then enters the pure dispatcher.
Synthetic parse calls still send source text in the same payload shape.

Add a frontend parse action to the existing compiler bridge. The Blorp bridge
runner reads source files for the new frontend path, parses them, and returns
parsed AST JSON to OCaml through the same protocol used by the Blorp-owned
backend tail.

The temporary production route becomes:

```text
Blorp read/parse
  -> compiler bridge protocol carrying parsed AST JSON
  -> OCaml module/infer/typecheck/Core
  -> same compiler bridge protocol carrying Core JSON
  -> Blorp backend tail
```

Acceptance criteria:

- There is exactly one compiler bridge subsystem, one protocol envelope, and
  one OCaml bridge call layer. Parser migration must extend those pieces
  rather than adding a parser-specific side channel.
- The bridge protocol, parsed-AST JSON projection, live `parse_source` action,
  and path-only source-file read handoff use the parser helper CLI. Backend/Core
  handoff uses the bootstrap-small backend helper CLI. Tests should keep these
  dispatchers from accidentally growing into each other's action surface.
- Production `check`, `compile`, `run`, `test`, formatter entry points, and LSP
  entry points use the Blorp parser bridge for source parsing.
- Remaining direct legacy Menhir parser/lexer users are bounded helper
  utilities and low-level unit-test fixtures, not frontend fallback selectors.
- The active compiler port roadmap is updated with the new boundary.

## Performance Notes

- Cursor movement should be O(1).
- Source text should be stored once.
- Tokens and AST nodes should store spans.
- Strings should be materialized only when needed for identifiers, string
  literals, diagnostics, or JSON transfer.
- Avoid closure-heavy combinators in compiler hot paths.
- Benchmarks should include source lexing, parsing, AST JSON encoding, and
  complete `Blorp parse -> OCaml middle -> Blorp backend` compile-path timing.

## Open Design Questions

- Should `Span` store two full `Cursor` values, or byte offsets plus a source
  file index, with line/column resolved through a line table? Current std and
  compiler-frontend foundation code uses flattened start/end position fields
  while nested struct/record payload handling is being investigated separately.
- Should `ParseError.expected` be a `List[String]` or a small enum/list of
  token labels for compiler parsers?
- Should std parser expose `StringSlice` at all after spans exist?
- Should JSON keep a `ParseResult` compatibility wrapper, or move fully to
  `Result` now that pre-0.1 compatibility is not required?
- How much trivia should the first Blorp compiler lexer preserve for formatter
  parity?

## Merge Readiness Checklist

For the std parser migration:

- New cursor/span API implemented.
- Old remaining-string constructors deleted.
- Existing users updated.
- Runtime parser tests expanded.
- Doctests and guide updated.

For the compiler parser migration:

- Blorp owns file reads for filesystem-backed hoisted parser inputs whose
  supplied source matches the file on disk.
- Lexer emits explicit tokens, spans, comments, and docstrings.
- Parser builds parsed AST without typed payloads.
- Bridge action returns parsed AST JSON.
- Parser fixture parity is green.
- Legacy Menhir lexer/parser selector paths are deleted; remaining direct
  parser users are explicitly bounded until they can be ported.
