# Parser API And Frontend Parser Status

Status checked against code on 2026-07-02.

This document now records the parser utility and frontend parser state. It is no
longer the active OCaml-to-Blorp migration roadmap; the active compiler
migration plan lives in
[BLORP_COMPILER_PORT_ROADMAP.md](BLORP_COMPILER_PORT_ROADMAP.md).

## Current State

The original parser utility migration is complete:

- `std/parser.brp` uses stable `Source`, `Cursor`, `Span`, and
  `ParseError` values instead of returning remaining-string suffixes.
- `ParseResult[T]` is now `Parsed(T, Cursor) | ParseFailed(ParseError)`.
- Primitive parsers return spans/cursors and materialize text only through
  explicit helpers such as `span_text`.
- Repetition combinators protect against no-progress parsers.
- Current std/tests/docs users have moved off the old `Success`/`Failure`
  remaining-string API.

The compiler source parser is also production-active:

- `compiler/blorp/compiler_source.brp`,
  `compiler_parse_diagnostic.brp`, `compiler_token.brp`,
  `compiler_lexer.brp`, `compiler_parser.brp`, and
  `compiler_parsed_ast.brp` define the Blorp-owned source model, diagnostics,
  lexer, parser, and parsed AST projection.
- The lexer emits explicit tokens, spans, comments, and docstrings without a
  global comment store.
- The parser bridge supports `parse_source` and `parse_sources` through the
  existing compiler bridge envelope.
- Filesystem-backed parse requests can pass path/module metadata and let the
  Blorp parser helper read the file before parsing.
- Synthetic parse requests still send source text explicitly.
- `check`, `compile`, and `run` can enter the OCaml middle with
  `frontend_module_graph` artifacts produced by Blorp CLI/source-graph code.
- The old frontend parser selector/fallback model is gone for normal compiler
  sessions.

The parser intentionally does not preserve removed syntax with compatibility
shims. Blorp is pre-0.1, so obsolete forms should fail through ordinary
lexer/parser diagnostics unless a targeted diagnostic is clearly better for
first-time users.

## API Shape

The std parser API should stay small and position based:

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

The compiler parser should continue using explicit scanner plus
recursive-descent/Pratt parser code in hot paths. Parser combinators are useful
for small parsers, tests, and user code, not for the whole compiler grammar.

## Current Status

The parser/lexer phase and parser-adjacent source-AST finalization now live on
the Blorp side of the bridge. Raw parser consumers request raw parse output;
compile/check/run request the `typecheck_source` phase, which finalizes string
interpolation, nested functions, and subscript reads before the OCaml middle.

Remaining work:

1. Keep comments and source spans flowing as data through parser, formatter,
   LSP, and diagnostics. Do not reintroduce process-global parser state.
2. Expand parser fixture coverage only where it protects current syntax or a
   known regression. Avoid rebuilding retired stage-golden systems.
5. Add focused parser performance measurements for lexing, parsing, AST JSON
   projection, and complete `Blorp parse -> OCaml middle -> Blorp backend`
   compile timing.
6. Revisit the `Span` representation only if measurements or ownership fixes
   justify it. The current flattened start/end fields are acceptable and avoid
   nested record ownership issues.

## Validation

Use focused parser checks for parser work:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_parser.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_lexer.brp
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Parser
scripts/test compiler
scripts/test cli
git diff --check
```

When syntax changes, update [GRAMMAR.md](GRAMMAR.md), [GUIDE.md](GUIDE.md), and
formatter expectations in the same change.
