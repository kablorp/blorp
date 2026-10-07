# Discovery Acceptance Roadmap

The discovery stage (`blorp/src/compiler_new/stage_01_discovery`) is the
default front end. A legacy adapter, `legacy_frontend_graph` in
`blorp/src/compiler/discovery_adapter.brp`, rebuilds the existing typecheck's
input from the stage's tables, and the self-compile emits the same C as the
old front end. The design lives in
[`DISCOVERY_TABLES_DESIGN.md`](DISCOVERY_TABLES_DESIGN.md) and
[`DISCOVERY_REDESIGN.md`](DISCOVERY_REDESIGN.md) (an unimplemented tree proposal).
Historical acceptance evidence lives in the
[declaration](../benchmarks/results/discovery_adapter_declarations_2026-10-01.md),
[body](../benchmarks/results/discovery_adapter_bodies_2026-10-01.md) and
[default-stage](../benchmarks/results/discovery_stage_switched_on_2026-10-01.md)
reports. This document holds only what is
still open: removing the old front end, hardening the comparison, and the
adapter's shrinkage. There is no front-end switch: the seam in
`lib/source_graph.brp` always runs the stage and the adapter.

## Open acceptance gaps

- **Two interpolated-string inputs the old lexer reads wrongly** (nesting three
  levels deep, and braces in an interpolated pipe string). The stage reads them
  as `GUIDE.md` and `GRAMMAR.md` say; they are the two entries in
  `ADAPTER_DIFFERENCES` and `KNOWN_DIVERGENCES` and the two fixtures under
  `fixtures/known_differences/`. The existing lexer
  pairs quotes in a hole with one flag, so it mis-pairs strings nested three
  levels deep, and it reads every brace of an interpolated pipe string as a
  hole. Everything else holds both acceptance criteria that these two inputs
  break: *same program* (the adapter's rebuilt parsed AST equals the old
  parser's) and *one syntax* (the two parsers agree on every rule decidable from
  syntax alone). The gap closes when the existing lexer reads both inputs as the language does or
  the old front end is deleted.
- **Not verified:** that diagnostics after the first, and the constructs the
  corpus and the targeted programs do not use, agree between the two parsers
  (a probe found the old parser accepting `./a/../a/b` imports the grammar
  forbids).
- **`implements module.Trait for X`** is not supported (`GUIDE.md` says so);
  it needs typecheck to carry the implemented trait's identity instead of its
  name. Qualified bounds and supertraits (`T: module.Trait`) work in both
  parsers.

Hardening, alongside but not on the critical path:

- **Mutation differential (M).** Mutate corpus files (delete a token,
  duplicate or swap lines, change indentation, insert `..`) and compare
  accept/reject and the first diagnostic between the two front ends. This is
  the check that would have caught the `..` divergence.
- **Targeted fixtures (S)** for the corners the corpus barely exercises:
  docstring attachment, interpolation escapes and nested strings, `Int`
  minimum literals, brace disambiguation (`{}`, `{x}`, `{x = 1}`,
  `{"a" => 1}`, `{r | x = 1}`), layout corners (leading-dot chains after
  lambdas, anchored `if`/`match` as arguments, comments between `if` and
  `else`).
- **Builder workarounds out (S).** The owned-record hand-off fixes have
  landed in the compiler; re-run the builder probe and remove the
  builder-threading workarounds the fixes made unnecessary (direct returns
  instead of `out = f(out); out`, chains instead of named locals). Proof:
  identical dump and allocation count. Not re-verified since the fixes landed.

## The adapter shrinks as typecheck is rewritten

The adapter is a plain transformation from the stage's frozen tables to the
shapes the existing typecheck reads: no parsing, no resolution, no checks of
its own, and anything it finds missing from the tables is a gap to fix in the
stage. The adapter and `compiler/discovery_front_end.brp`, which runs the
stage, are the two `compiler` modules permitted to import `compiler_new`
(`temporary_cross_owner_imports` in `blorp/source_ownership.json`). Each
typecheck rewrite step reads some part of the tables directly (definitions,
then signatures and types, then bodies) and deletes the matching part of the
adapter, until typecheck accepts `FrontendTables` as its
input and the adapter is gone. Its size is the measure of how much of
typecheck still reads the old shapes. Ids are internal identity: the adapter
does not imitate the old front end's numbering, and if generated C differs
only in names derived from ids it is compared after normalizing them.

## Rules for the interim

These hold until the old path is removed.

- **A syntax change lands in both parsers**, with the parity gate and pinned
  fixtures proving they agree (`scripts/README.md` describes the
  `compiler-new-parity` gate that shows the two breaking). Non-urgent syntax and diagnostic changes may wait so they are made
  once.
- **Rules decidable from syntax go into the parsers**, not typecheck.
- **Fixtures are run or deleted.** No fixture exists that no gate runs.

## Removing the old front end

The old lexer, parser and module loader (`stage_02_lex`, `stage_03_parse`,
`stage_04_modules`) remain for these consumers. Retire each dependency before
deleting its owner; this work does not require the typed-tree redesign:

- `compile --ast` (`compiler/command.brp`);
- `blorp test` discovery, doctest extraction and the test plan
  (`test/discovery.brp`, `test/doctest.brp`, `test/plan.brp`), and the
  generated harness root in `lib/source_graph.brp`;
- the formatter (`blorp/src/format`), which keeps its own parser because it
  needs the comments the stage drops;
- the LSP, which calls old discovery directly (`lsp/analysis/diagnostic.brp`,
  `lsp/analysis/frontend_graph.brp` through `frontend_graph_discover`); its
  replacement needs an in-memory provider for unsaved buffers;
- the finalizer (`source_ast_finalize.brp`) and the typecheck bridge fallback
  (`stage_06_typecheck/bridge.brp`).

They are deleted once none of these use them; the corpus parity gate and the
two-parser rule end with them. `GRAMMAR.md` and the GUIDE already record the
grammar the stage implements, including its deliberate differences (for example
`# N` with a space is rejected).

The formatter needs a separate decision about lossless syntax or trivia:
the discovery stage drops comments. `lint` already uses the stage through
the adapter and reads the rebuilt typechecked graph until typecheck consumes
discovery directly. Adapter retirement and old-parser retirement are separate
dependencies; neither requires waiting for the other by default.
