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
adapter's shrinkage. The old path remains reachable as
`BLORP_FRONT_END=existing` until it is removed.

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
stage. It is the one module that may import both `compiler_new` and the
existing compiler's AST types; nothing else in `compiler` may import
`compiler_new`. Each typecheck rewrite step reads some part of the tables
directly (definitions, then signatures and types, then bodies) and deletes the
matching part of the adapter, until typecheck accepts `FrontendTables` as its
input and the adapter is gone. Its size is the measure of how much of
typecheck still reads the old shapes. Ids are internal identity: the adapter
does not imitate the old front end's numbering, and if generated C differs
only in names derived from ids it is compared after normalizing them.

## Rules for the interim

These hold until the old path is removed.

- **A syntax change lands in both parsers**, with the parity gate and pinned
  fixtures proving they agree (`scripts/README.md` describes the
  `front-end-existing` and `compiler-new-parity` gates that show either path
  breaking). Non-urgent syntax and diagnostic changes may wait so they are made
  once.
- **Rules decidable from syntax go into the parsers**, not typecheck.
- **Fixtures are run or deleted.** No fixture exists that no gate runs.

## Removing the old front end

After the next bootstrap rotation has run on the default, in this order:

1. Delete the switch: `BLORP_FRONT_END`, `FrontEnd`, `FrontEndSelection` and
   `front_end_selection*` in `lib/source_graph.brp` and `lib/cli_plan.brp`; the
   seam always builds the graph from the stage and the adapter.
2. Remove the existing discovery (lexer, parser and module loader) from the
   compile path, and the `ExistingDiscovery` arm of the seam.
3. Delete the `front-end-existing` gate: `scripts/front-end-existing-check`, its
   entries in `scripts/test` and `scripts/premerge-gate`, and the `existing`
   comparisons in `test_cli.sh` and `test_package.sh`.
4. Delete the old parser itself only once the formatter, test discovery,
   doctest generation and the LSP no longer use it (see "Open decision"); the
   corpus parity gate and the two-parser rule end with it. `GRAMMAR.md` and the
   GUIDE already record the grammar the stage implements, including its
   deliberate differences (for example `# N` with a space is rejected).

## Open decision

- **The other users of the old front end.** The formatter needs comments,
  which the stage drops by design, so it keeps its own parser or the stage
  gains an optional trivia table. The linter and the LSP move to the stage (the
  LSP with an in-memory provider for unsaved buffers, and off its direct calls
  to the old discovery). Test discovery and doctest generation also still use
  the old parser (`test/discovery.brp`, `test/doctest.brp`).
