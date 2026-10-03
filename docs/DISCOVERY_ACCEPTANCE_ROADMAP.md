# Discovery Acceptance Roadmap

The discovery stage (`blorp/src/compiler_new/stage_01_discovery`) is the
default front end. A legacy adapter, `legacy_frontend_graph` in
`blorp/src/compiler/discovery_adapter.brp`, rebuilds the existing typecheck's
input from the stage's tables, and the self-compile emits the same C as the
old front end. The design lives in
[`DISCOVERY_TABLES_DESIGN.md`](DISCOVERY_TABLES_DESIGN.md) and
[`DISCOVERY_REDESIGN.md`](DISCOVERY_REDESIGN.md); the acceptance measurements
are in `benchmarks/results/discovery_adapter_declarations_2026-10-01.md`,
`discovery_adapter_bodies_2026-10-01.md` and
`discovery_stage_switched_on_2026-10-01.md`. This document holds only what is
still open: removing the old front end, hardening the comparison, and the
adapter's shrinkage. There is no front-end switch: the seam in
`lib/source_graph.brp` always runs the stage and the adapter.

## Open acceptance gaps

- **Two interpolated-string inputs the old lexer reads wrongly** (nesting three
  levels deep, and braces in an interpolated pipe string). The stage reads them
  as `GUIDE.md` and `GRAMMAR.md` say; they are the two entries in
  `ADAPTER_DIFFERENCES` and `KNOWN_DIVERGENCES` and the two fixtures under
  `fixtures/known_differences/`. They are tracked in
  [`issues/interpolation_nesting_in_the_existing_lexer.md`](issues/interpolation_nesting_in_the_existing_lexer.md),
  and everything else holds both acceptance criteria that these two inputs
  break: *same program* (the adapter's rebuilt parsed AST equals the old
  parser's) and *one syntax* (the two parsers agree on every rule decidable from
  syntax alone). The gap closes when that issue is closed or the old front end is deleted.
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

Done: the switch (`BLORP_FRONT_END`, `FrontEnd`, `FrontEndSelection`), the
`ExistingDiscovery` arm of the seam and the functions only it reached, and the
`front-end-existing` gate with its `scripts/test` and `scripts/premerge-gate`
entries and the `existing` comparisons in `test_cli.sh` and `test_package.sh`.

The old lexer, parser and module loader (`stage_02_lex`, `stage_03_parse`,
`stage_04_modules`) remain only for these users:

- `compile --ast` (`compiler/command.brp`);
- `blorp test` discovery, doctest extraction and the test plan
  (`test/discovery.brp`, `test/doctest.brp`, `test/plan.brp`), and the
  generated harness root in `lib/source_graph.brp`;
- the formatter (`blorp/src/format`), which keeps its own parser because it
  needs the comments the stage drops;
- the LSP, which calls the old discovery directly (`lsp/analysis/diagnostic.brp`,
  `lsp/analysis/frontend_graph.brp` through `frontend_graph_discover`);
- the finalizer (`source_ast_finalize.brp`) and the typecheck bridge fallback
  (`stage_06_typecheck/bridge.brp`).

They are deleted once none of these use them; the corpus parity gate and the
two-parser rule end with them. `GRAMMAR.md` and the GUIDE already record the
grammar the stage implements, including its deliberate differences (for example
`# N` with a space is rejected).

## Open decision

- **The other users of the old front end.** The LSP moves to the stage with
  an in-memory provider for unsaved buffers, off its direct calls to the old
  discovery. Test discovery and doctest generation move off the old parser too
  (`test/discovery.brp`, `test/doctest.brp`). `lint` already runs the stage
  through the legacy adapter; it reads the rebuilt typechecked graph until
  typecheck consumes the tables directly.
