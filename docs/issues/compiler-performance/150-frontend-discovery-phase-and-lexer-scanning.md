# Expose Frontend Discovery Timing And Cut Lexer Scanning Work

**Status:** Ready. Coordinator-owned acceptance; measurement gap first.

**Current state:** `--time-phases` starts at `typed_frontend`; source
discovery (lexing, parsing, module-graph construction) runs before the first
phase row and is invisible. On the 2026-09-16 self-compile it took about
1.7 seconds and 24.8M allocations for 360 modules. In the instrumented
profile, `stage_02_lex/lexer.brp` plus `blorp/src/lib/source.brp` are about
5.6% of compiler self time: `source_peek` 27.1M calls, `source_advance`
10.7M, `identifier_end_cursor` 665k (1.3 µs each), `peek` 9.3M,
`is_ident_start`/`is_ident_continue` 15.4M, and `string.append_char` 19.6M
(string-literal and interpolation bodies are built one character at a time).
The parser's `current_token` runs 13.5M times.

**Next action:** First add a `source_discovery` phase row and memory
checkpoint so the phase is measurable. Then cut per-character call and
allocation work in the lexer's hot scanners without changing any token.

**Read first:** `blorp/src/compiler/pipeline.brp` (`CompilerPhase`,
`compiler_phase_label`, the checkpoint label helpers);
`blorp/src/lib/compile_plan_execute.brp` (where phase rows are timed and
printed) and `blorp/src/lib/compilation.brp`; `blorp/src/main.brp` and
`blorp/src/lib/source_graph.brp` (`frontend_compilation_graph_for_roots_with_setup`
is the discovery entry on the compile path); `blorp/src/lib/source.brp`;
`blorp/src/compiler/stage_02_lex/lexer.brp` (`identifier_end_cursor`,
`scan_identifier`, `scan_number`, `scan_string_literal`,
`scan_interpolated_string_tail`, `scan_spaces`, `skip_line_spaces_with_indent`,
`peek`, `advance`); `blorp/test/compiler/stage_02_lex/`; `docs/DEVELOPMENT.md`
"Timing Compiler Phases"; the
[measurement protocol](../../../benchmarks/README.md#self-compile-measurement-protocol).

**Fast loop:**

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_02_lex/test_lexer.brp
bin/blorp format --check --diff blorp/src/compiler/stage_02_lex/lexer.brp
make && scripts/compiler-build-status
benchmarks/self_compile_measure --label issue-150-<step> --input-rev <baseline input_rev> \
  --baseline benchmarks/results/self_compile_baseline_O0_2026-09-16.json \
  --output /tmp/issue-150-<step>.json --require-identical
```

**Decision:** Accept when the new phase row exists with a matching memory
checkpoint, generated C is IDENTICAL, tokens and trivia are unchanged for
every lexer and formatter fixture, and instructions attributable to discovery
fall by at least 20% at `-O2` (the coordinator measures `-O2`; report your
`-O0` numbers). Consult the coordinator before changing `Cursor`, `SourceSpan`,
or any token kind.

## Objective

Make source discovery a measurable compiler phase and cut the lexer's per-character call and allocation work without changing any token, span, trivia, or diagnostic.

## Step 1: `source_discovery` Phase Row

Add a `SourceDiscoveryPhase` variant before `TypedFrontendPhase`, label it
`source_discovery`, and time the discovery call on the compile path so the
row appears first in `--time-phases` output and `phase_total` includes it.
Record `source_discovery_start` and `source_discovery_complete` memory
checkpoints through the same helper the other phases use, so
`benchmarks/self_compile_measure` reports its allocations automatically.
Update the phase list in `docs/DEVELOPMENT.md` and any test that asserts the
row order (search `blorp/test` for `typed_frontend`). This step is required
even if Step 2 is later rejected.

## Step 2: Lexer Scanning Cuts

Measure the discovery row after Step 1, then apply these in order, measuring
after each:

1. **Run scanners without per-character helper calls.** In
   `identifier_end_cursor`, `scan_number`, `scan_spaces`, and
   `skip_line_spaces_with_indent`, scan the source text directly by offset in
   a local loop (`text.get_or` or an equivalent bounded read) and compute the
   end cursor once; `source_advance` recomputes line and column per character
   and is unnecessary inside a run that cannot contain a newline.
2. **Slice literal bodies instead of appending characters.** For string and
   interpolated-string scanning, copy the maximal run without escapes as one
   `substring` and only fall back to character appends across an escape.
3. **Keep `peek`/`advance` for the token dispatcher** (`scan_one`) unless the
   after-measurement shows it still dominant; report its count.

Tokens, spans, trivia, indentation levels, and diagnostics must be
byte-for-byte identical. The formatter consumes tokens and trivia, so run the
format fixtures too.

## Invariants And Tests

- `blorp/test/compiler/stage_02_lex/` suites, the parser fixtures under
  `blorp/test/compiler/stage_03_parse/`, and `scripts/test compiler-tools`
  (formatter, purify, lint fixtures) pass unchanged.
- `bin/blorp format --check` over `blorp/src` and `standard_library/src`
  reports no diffs (formatting is a pure function of tokens and trivia).
- Generated C for the self-compile and the small program is IDENTICAL.
- Unicode and tab handling (`COMPILER_SOURCE_TAB_WIDTH`) are unchanged; add a
  lexer test with a tab-indented line, a multibyte identifier, and an
  interpolated string containing an escape, if none exists.

## Measurement

Report the harness tables (self and small) after Step 1 and after each
Step 2 cut. The `source_discovery` allocations and the discovery share of
retired instructions are the primary metrics; whole-compile instructions is
the acceptance number.

## Acceptance And Rejection

Accept: Step 1 landed with docs and tests; IDENTICAL C; all listed suites
and `benchmarks/self_compile_measure lock -- scripts/compiler-check --changed`
plus `benchmarks/self_compile_measure lock -- scripts/test compiler-tools`
green; discovery instructions down at least 20% at `-O2` or a recorded
negative result for Step 2 with Step 1 still accepted. Reject any token,
span, trivia, or formatter difference.
