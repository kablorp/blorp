# Discovery Acceptance Roadmap

This is the path from today's `compiler_new/stage_01_discovery` to the point
where we are happy to connect it to the compilation pipeline: the compiler
runs the new stage, a legacy adapter feeds the existing typecheck, and the
old lexer, parser and module loader stop being part of a compile. The design
lives in `docs/DISCOVERY_TABLES_DESIGN.md`; this document only orders the
work and says what "accepted" means.

## Where we are (2026-09-30)

- **Landed:** the stage itself (tables, builder, invariants, lexer, module
  graph, declaration, type, pattern and body parsers) organized as
  `pipeline.brp` plus `tables/`, `sources/`, `lex/` and `parse/`; the
  `compiler-new` gate; the corpus parity gate (premerge) with curated and
  per-code fixtures; and the syntax rules both parsers now share (`?=` and
  `break`/`continue` placement, concurrency parameters, no `as` ascription,
  exact-case import paths, no string patterns with holes); and the implicit
  modules (`prelude`, `tuple`, and `test` when testing), loaded after the
  roots so the self-compile's module list equals the existing graph's in
  count and order (item 1).
- **Measured on the self-compile inputs:** 0.65 s user CPU against 1.3 s for
  the existing discovery; 4.3 G instructions against 8.6 G; about 500 k
  allocations against 7.9 M.
- **Verified:** token parity and accept/reject parity with the existing front
  end over every tracked file, about 45 constructs compared by hand, and one
  pinned fixture per diagnostic code.
- **Not verified:** that the trees are the same. Accept/reject agreement says
  nothing about precedence, attachment, spans or diagnostics after the first,
  and it only covers constructs the corpus happens to use (a probe found the
  old parser accepting `./a/../a/b` imports that the grammar forbids).

## What "accepted" means

We connect the stage by default when all of these hold:

1. **Same program.** For every corpus file, the adapter's rebuilt parsed AST
   equals the existing parser's, compared through the existing parsed-AST
   JSON encoder, with every deliberate difference listed and justified.
2. **Same compiler output.** With the new stage switched on, every default and
   premerge gate passes, and the self-compile produces the same C. Ids are
   internal identity, not stable across compiles or front ends; if the C
   differs only in names derived from ids, it is compared after normalizing
   them.
3. **Same or better diagnostics.** For every rejected corpus file and every
   curated and per-code fixture, the first diagnostic renders at the same
   position as today, and rendered messages and help are diffed against the
   existing compiler's; every wording change is listed and deliberate.
4. **Complete inputs.** The prelude, the test runtime, the embedded standard
   library and source packages resolve exactly as they do today: the
   differential runs with the embedded-library provider and a source-package
   project, not just files on disk.
5. **Faster.** New discovery plus the adapter costs fewer instructions than
   the existing discovery on the self-compile, and the stage's allocation
   budget test holds. Measured from the first adapter increment on, not only
   at the end: the stage's margin (about 0.65 s) is what the adapter may
   spend.
6. **One syntax.** Every rule that can be decided from syntax alone is in the
   parser, and the two parsers agree on it for as long as both exist.

Other users of the old front end (the formatter, which needs comments, the
linter, and the LSP's per-keystroke analysis) are out of scope for
acceptance; see the end.

## The adapter

The minimum viable connection is an adapter: a plain transformation from the
new stage's frozen tables to the output the existing typecheck already reads.
It belongs to neither side. The new stage keeps knowing nothing about the old
compiler, and typecheck keeps its current input; the adapter sits between
them, in the compiler's top-level pipeline (`blorp/src/compiler/pipeline.brp`
or a module beside it such as `blorp/src/compiler/discovery_adapter.brp`):
```
---
Rebuilds the existing typecheck's input from the new discovery stage's tables.
This is the only place that knows both shapes. It shrinks as typecheck is
rewritten to read the tables, and it is deleted when typecheck takes
`FrontendTables` directly.
---
pure func legacy_frontend_graph(tables: FrontendTables) -> FrontendCompilationGraph:
	...

-- in the pipeline, behind the switch:
tables: FrontendTables = discover(provider, lookup_roots, root_paths).tables_or_diagnostics()
graph: FrontendCompilationGraph = legacy_frontend_graph(tables)
typecheck_compiler_frontend_graph(graph, ...)          -- unchanged
```
- **A transformation only:** no parsing, no resolution, no checks of its own.
  Anything it finds missing from the tables is a gap to fix in the stage.
- **Layout exception:** this one module may import both `compiler_new` and
  the existing compiler's AST types; nothing else in `compiler` may import
  `compiler_new`.
- **Ids pass through, not imitated.** Ids are internal identity, so the
  adapter does not reproduce the old front end's numbering:
  - **Modules** match the old graph's order without a mapping once the stage
    loads the implicit modules as seeds right after the roots, as the old
    discovery does (roots, then seeds, then imports breadth first).
  - **Definitions:** the old parsed AST carries no definition ids (typecheck
    mints its own), so the stage's `DefinitionId`s are not passed on.
  - **Names:** the adapter hands over the stage's name table. The same
    spelling may get a different `NameId` than the old front end gave it;
    acceptance criterion 2 says how the C is compared if that shows.
- **The tree differential is the adapter's own test.** The old compiler
  already encodes a parsed program as JSON (`parsed_program_to_json` in
  `parsed_ast_json.brp`): its declarations and bodies with spans, and also
  the source file and the parse diagnostics. The adapter rebuilds the whole
  parsed program, so the differential compares that JSON per corpus module.
  Spans render through a source table, so the adapter supplies one with the
  same paths and line starts. A mismatch names the module, the declaration
  and the field. There is no separate renderer.

**After acceptance, the adapter shrinks as typecheck is rewritten.** Each
typecheck rewrite step reads some part of the tables directly (definitions,
then signatures and types, then bodies) and deletes the matching part of the
adapter, until typecheck accepts `FrontendTables` as its input and the adapter
is gone. The adapter's size is the measure of how much of typecheck still
reads the old shapes.

## The work, in order

Sizes are rough: S is under a day of worker time, M a few days, L a week or
more. Each numbered item is one change.

1. **Implicit modules and untested codes (M). Landed.** The stage loads the implicit
   modules the old discovery seeds after the roots: the prelude set, and for
   `blorp test` the test runtime. It also gains tests for
   `UnreadableSourceDiagnostic` and `TooManySourcesDiagnostic`, now covered
   in `test_pipeline`. The parity gate also compares the old graph's module
   sequence with the stage's for the self-compile root and a `blorp test`
   root (identical order), so the stage's restated seed
   names cannot drift from the old constants.
2. **Qualified trait bounds (S).** `T: module.Trait` is legal: `BoundRow`
   records a path, not a single name. Both parsers and the grammar agree.
3. **Adapter, declarations (M).** `legacy_frontend_graph` rebuilds each
   module's declarations, signatures, types, imports and surfaces, with
   bodies left empty, plus the source table that spans render through and
   the docstrings declarations carry; the differential compares
   declaration-level AST JSON over the corpus. The first cost measurement
   (criterion 5) happens here.
4. **Adapter, bodies (L).** Expressions, statements and patterns, with spans;
   the differential compares the full AST JSON for every corpus module
   (criterion 1).
5. **Embedded standard library and source packages (M).** A provider that
   answers for the standard-library root from the compiler's embedded texts,
   and `blorp.toml` aliases as candidate rules in the lookup policy; the
   differential also runs under both (criterion 4).
6. **Rendered diagnostics and first-diagnostic parity (M).** One rendering
   table from `DiscoveryDiagnosticCode` and its arguments to message and
   help, owned by the stage, so the old parser's teaching messages survive.
   The corpus parity gate then compares, for every file both front ends
   reject, the first diagnostic's position and rendered text (criterion 3).
7. **One switch point (M).** The CLI entry points that parse today reach the
   old front end through `lib/source_graph.brp` (`main.brp`, `test/plan.brp`,
   `purify/command.brp`, `package/check.brp`) or call `parse_compiler_source`
   directly (`test/doctest.brp`, `test/discovery.brp`). Route them all
   through one seam in `lib/source_graph.brp` and put the switch there, with
   the existing discovery as default. The CLI parses the root file before
   discovery today; the new stage replaces that too.
8. **Switch on, then flip the default (M).** With the switch on, every gate
   passes and the self-compile C matches (criterion 2), and the cost
   measurement holds (criterion 5). Then flip the default, keeping the old
   path behind the switch until the next bootstrap rotation has run on the
   new default.

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
  identical dump and allocation count.

After acceptance: **retire the old front end from compilation.** Remove the
old lexer, parser and module loader from the compile path. They are deleted
outright only once the formatter, linter and LSP no longer use them (the LSP
also calls the old discovery directly); until then they remain for those
tools only. The corpus parity gate and the two-parser rule end when the old
parser is deleted. `docs/GRAMMAR.md` and the GUIDE record the grammar the new
stage implements, including its deliberate differences (for example `# N`
with a space is rejected).

## Order and parallelism

Items 1 and 2 come first; 3 needs 1 (module order). 5 and 6 run in parallel
with 3 and 4 (different files). 7 needs 4, 5 and 6; 8 needs 7. The hardening
items run whenever a worker is free.

## Rules for the interim

- **Syntax is frozen until the switch.** Non-urgent syntax and diagnostic
  changes wait until the new stage is the default, so they are made once and
  the differential compares against a fixed target. An urgent one lands in
  both parsers, with the parity gate and pinned fixtures proving they agree.
- **Rules decidable from syntax go into the parsers**, not typecheck.
- **Fixtures are run or deleted.** No fixture exists that no gate runs.

## Decisions

- **Qualified trait bounds are legal** (item 2).
- **Freeze keeps the full invariant check** in release builds too.
- **Ids are internal identity**, not stable across compiles or between the old
  and new front ends; nothing imitates the old numbering.

## Open decision

- **The other users of the old front end after acceptance.** The formatter
  needs comments, which the stage drops by design, so it keeps its own parser
  or the stage gains an optional trivia table. The linter and the LSP move to
  the stage (the LSP with an in-memory provider for unsaved buffers, and off
  its direct calls to the old discovery).
