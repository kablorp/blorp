# Discovery Acceptance Roadmap

This is the path from today's `compiler_new/stage_01_discovery` to the point
where we are happy to connect it to the compilation pipeline: the compiler
runs the new stage, a legacy adapter feeds the existing typecheck, and the
old lexer, parser and module loader stop being part of a compile. The design
lives in `docs/DISCOVERY_TABLES_DESIGN.md`; this document only orders the
work and says what "accepted" means.

## Where we are (2026-10-01)

- **Landed:** the stage itself (tables, builder, invariants, lexer, module
  graph, declaration, type, pattern and body parsers) organized as
  `pipeline.brp` plus `tables/`, `sources/`, `lex/` and `parse/`; the
  `compiler-new` gate; the corpus parity gate (premerge) with curated and
  per-code fixtures; and the syntax rules both parsers now share (`?=` and
  `break`/`continue` placement, concurrency parameters, no `as` ascription,
  exact-case import paths, no string patterns with holes); rendered
  diagnostics with first-diagnostic parity (item 6); and the implicit
  modules (`prelude`, `tuple`, and `test` when testing), loaded after the
  roots so the self-compile's module list equals the existing graph's in
  count and order (item 1); the embedded standard-library provider and
  the source-package lookup rules, with the module-order differential
  also run on the embedded library and on source-package and native-package
  fixture projects, identical in modules, order and origins (item 5); and the
  legacy adapter, `legacy_frontend_graph` in
  `blorp/src/compiler/discovery_adapter.brp`, which rebuilds every module's
  declarations, bodies, imports, docstrings and surface from the tables and
  equals the existing parser's, spans included, over the corpus under a
  full-AST differential (items 3 and 4).
- **Measured on the self-compile inputs:** 0.22 s user CPU against 0.51 s for
  the existing discovery; 4.0 G instructions against 10.1 G; about 520 k
  allocations against 8.5 M. With the whole adapter and typecheck's
  finalization the stage costs 8.7 G instructions, 14% under the existing
  discovery (`benchmarks/results/discovery_adapter_bodies_2026-10-01.md`).
- **Verified:** token parity and accept/reject parity with the existing front
  end over every tracked file, about 45 constructs compared by hand, and one
  pinned fixture per diagnostic code.
- **Verified:** that the trees are the same, bodies included. The full-AST
  differential (items 3 and 4) finds every module both parsers accept equal,
  spans included, over 3,174 corpus modules and the root runs; targeted
  programs, one per construct group, check the corners the corpus does not
  reach. It found interpolated-string inputs the existing lexer reads wrongly.
  Two were fixed in the existing lexer (a `\u{...}` escape after the first hole,
  and braces or backslashes before it). Two remain, listed in
  `ADAPTER_DIFFERENCES` and in
  `docs/issues/interpolation_nesting_in_the_existing_lexer.md`: interpolation
  nested three levels deep and braces in an interpolated pipe string. The stage
  reads them as `docs/GUIDE.md` and `docs/GRAMMAR.md` say; no corpus source but
  one fixture holds them.
- **Connected behind a switch (item 7):** `BLORP_FRONT_END=stage` runs the
  stage and the adapter for every command that builds the graph, through one
  seam in `lib/source_graph.brp`. The self-compile with it on emits the same C
  as the existing discovery.
- **Switched on (item 8, first half):** every default and premerge gate passes
  with `BLORP_FRONT_END=stage` and without it, the self-compile C is identical,
  and the stage costs 11% fewer instructions than the existing discovery with
  the whole adapter (`benchmarks/results/discovery_stage_switched_on_2026-10-01.md`).
  The `front-end-stage` gate kept that path green in the premerge set.
- **Default flipped (item 8, second half):** the discovery stage is the default
  front end; `BLORP_FRONT_END=existing` reaches the old path. The
  `front-end-existing` gate (the renamed `front-end-stage` gate) keeps the old
  path green in the premerge set, and the self-compile C from the default equals
  the existing front end's. What remains: the old path is deleted after the
  next bootstrap rotation has run on the new default (see "Removing the old
  front end"). Criteria 1 and 6 hold for everything except the listed
  interpolation differences, which are now the language's behavior.
- **Not verified:** that diagnostics after the first, and the constructs the
  corpus and the targeted programs do not use, agree (a probe found the old
  parser accepting `./a/../a/b` imports that the grammar forbids).

## What "accepted" means

We connect the stage by default when all of these hold:

1. **Same program.** For every corpus file, the adapter's rebuilt parsed AST
   equals the existing parser's, compared through the existing parsed-AST
   JSON encoder, with every deliberate difference listed and justified.
   **Open for two listed differences** (item 4): the corpus is equal except
   two fixtures under `fixtures/known_differences/`. The difference in
   `interpolation_nesting.brp` is in `ADAPTER_DIFFERENCES`, and the existing
   parser rejects `interpolation_pipe_braces.brp`, which is in
   `KNOWN_DIVERGENCES`; both are tracked in
   `docs/issues/interpolation_nesting_in_the_existing_lexer.md`. It is met
   when that issue is closed or the old front end is deleted.
2. **Same compiler output. Met** (item 8): with the new stage switched on, every
   default and premerge gate passes, and the self-compile produces the same C,
   from `bin/blorp` and from a stage-2 `-O2` compiler (cmp equal, 76,956,462
   bytes). Ids are
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
   at the end: the stage's margin (about 6 G instructions) is what the adapter
   may spend. Met with the whole adapter: 8.74 G against 10.13 G, with 23% of
   the margin left.
6. **One syntax.** Every rule that can be decided from syntax alone is in the
   parser, and the two parsers agree on it for as long as both exist. **Open
   for the same issue:** the existing lexer does not nest interpolation past two
   levels or keep braces in interpolated pipe strings, which the stage does.

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
2. **Qualified trait bounds (S). Done for bounds and supertraits.**
   `T: module.Trait` is legal in both parsers and the grammar; the alias is a
   side-table row (`BoundQualifierRow`, `SupertraitQualifierRow`). Not done:
   `implements module.Trait for X`, which needs typecheck to carry the
   implemented trait's identity instead of its name.
3. **Adapter, declarations (M). Landed.** `legacy_frontend_graph` rebuilds each
   module's declarations, signatures, types, imports and surfaces, with
   bodies left empty, plus the source table that spans render through and
   the docstrings declarations carry; the differential compares
   declaration-level AST JSON over the corpus. The first cost measurement
   (criterion 5) happens here.
   The differential (`blorp/test/compiler/tools/discovery_adapter_differential.brp`,
   run by `compiler-new-parity` over every module-order root, with the standard
   library on disk and embedded and on the native-package and source-package
   fixtures, and over every corpus file as a root) finds no difference over 3,170
   modules and 46,731 declarations in the corpus run, and the existing graph's
   module names, origins and paths equal the adapter's on every root, so
   `ADAPTER_DIFFERENCES` is empty. Making it so closed these stage gaps: the
   name spans of type parameters, bounds, supertraits, imports, aliases and
   foreign arguments; a name span side table for written types; the `#N`
   spelling beside `N`; the end of an import and of an import block; and the
   vocabulary, which seeded 158 of the existing compiler's 236 names so every
   later id differed from its `NAME_ID_*` constant. The stage plus the adapter
   costs 5.68 G instructions against the existing discovery's 10.20 G
   (`benchmarks/results/discovery_adapter_declarations_2026-10-01.md`); the
   declaration half is 26% of the margin, and the body half is not in that
   number.
4. **Adapter, bodies (L). Landed.** `legacy_module_bodies` rebuilds every
   function, method and global body from the post-order node table in one
   forward pass per module, with no recursion over a body, and the differential
   (`discovery_adapter_differential.brp`, run by `compiler-new-parity`) compares
   the full AST JSON, spans included, with the existing side's interpolation
   holes parsed: no difference over 3,174 corpus modules (47,027 declarations)
   and over the 396, 62, 39 and 41 modules of the root runs, with the standard
   library on disk and embedded, except the two listed in
   `ADAPTER_DIFFERENCES` for one fixture (criterion 1 is open for them, see
   above). The placeholder body and the declaration-only comparison
   are deleted. Closing it took these stage gaps: the span of a name inside a
   wider body node (a field, a binding or assignment target, a binder, a
   pattern's constructor or spread), the span of an `else` keyword (and the JSON
   encoder printing it), the form a string pattern was written in, a
   parenthesized name keeping its own span, and an unknown escape after a hole
   keeping its pair as text. The stage plus the adapter and typecheck's
   finalization costs 8.74 G instructions against the existing discovery's
   10.13 G, 14% under it, with 4.69 G of the 6.08 G margin spent
   (`benchmarks/results/discovery_adapter_bodies_2026-10-01.md`).
5. **Embedded standard library and source packages (M). Landed.** A provider that
   answers for the standard-library root from the compiler's embedded texts,
   and `blorp.toml` aliases as candidate rules in the lookup policy; the
   differential also runs under both (criterion 4).
6. **Rendered diagnostics and first-diagnostic parity (M). Landed.** One rendering
   table from the diagnostic unions (a code with its typed arguments) to message and
   help, owned by the stage, so the old parser's teaching messages survive.
   The corpus parity gate then compares, for every file both front ends
   reject, the first diagnostic's position and rendered text (criterion 3).
   `diagnostics/render.brp` renders every code from its
   arguments (which `freeze` checks), with the per-construct messages of the
   existing parser; the parser fixtures pin the existing text and position
   and the stage's text must equal them. The corpus gate compares the first
   diagnostic of every file both front ends reject. Every difference is
   listed in the design document ("Diagnostic text"): 52 codes add a help
   line, 6 word a message differently on purpose, and two positions differ
   (see Decisions).
7. **One switch point (M). Landed.** Every command that builds the graph
   (`main.brp` for check, compile, run and lint, `test/plan.brp`,
   `purify/command.brp`, `package/check.brp`) gets it from
   `frontend_compilation_graph_for_root_paths` in `lib/source_graph.brp`, which
   takes the sources the command read and parses them itself (except test roots
   that test discovery already parsed), and switches on
   `BLORP_FRONT_END` (`stage`, the default since item 8, or `existing`; read once per
   setup; an unknown value is an error). The superseded entry points
   (`frontend_compilation_graph_for_roots` and its `_with_setup` and
   `_with_setup_and_test_runtime` forms) are deleted. `test/discovery.brp` and
   `test/doctest.brp` stay on the existing parser as tools: they parse each
   candidate to decide which files are test roots and to generate the doctest
   roots, before any graph exists. With the stage on, `check`, `compile`, `test`,
   `purify` and `package check` work, the `cli` and `package` gates pass apart
   from the three parse-diagnostic fixtures that pin the absence of the help
   line, and the self-compile emits byte-identical C. What a user can see
   differently is in the design document ("Running the stage from the CLI").
8. **Switch on, then flip the default (M).**
   - **Switch on. Done.** With the switch on, every default and premerge gate
     passes and the self-compile C matches (criterion 2), and the cost
     measurement holds (criterion 5, 11% fewer instructions than the existing
     discovery with the whole adapter). Fixes the gates needed: the CLI
     wrapper tests and parse-failure fixtures hold under both front ends, the
     check runner compares a fixture's pinned stage text and position when the
     stage is on, a module reached by an absolute path is named from the working
     directory as the existing front end names it (the backend keys builtin
     modules on that spelling), and a graph the validation refuses is reported
     as the user's error, not as a defect of the tables.
   - **Flip the default. Done.** Unset or blank `BLORP_FRONT_END` selects the
     stage (`DEFAULT_FRONT_END` in `lib/source_graph.brp`); the old path stays
     behind `existing` until the next bootstrap rotation has run on the new
     default. The `front-end-existing` gate runs the cli smoke, package, parser
     fixtures, seam suites and the self-compile identity with `existing` in
     every premerge run. The default fixtures now pin the stage's output: parse
     errors carry a `help:` line, a case-mismatched import carries
     `path:line:col:`, a missing implicit module is an error, and one report
     lists the stop-worthy diagnostics. Criteria 1 and 6 hold except for the two
     interpolation differences, which are the language's behavior now.

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

The default is flipped; the rules below hold until the old path is removed.

- **Syntax is frozen until the switch.** Non-urgent syntax and diagnostic
  changes wait until the new stage is the default, so they are made once and
  the differential compares against a fixed target. An urgent one lands in
  both parsers, with the parity gate and pinned fixtures proving they agree.
- **Rules decidable from syntax go into the parsers**, not typecheck.
- **Fixtures are run or deleted.** No fixture exists that no gate runs.

## Removing the old front end

After the next bootstrap rotation has run on the new default, in this order:

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
   corpus parity gate and the two-parser rule end with it.

## Decisions

- **Qualified trait bounds are legal** (item 2).
- **Two first-diagnostic positions stay different from the old parser**
  (criterion 3). `import_constructors_unclosed`: the old parser reports the
  unclosed constructor list at its last constructor, the stage at the token
  after the list. `interpolation_hole_two_expressions`: the old parser
  re-parses the hole on its own and reports a position inside it, the stage
  the second expression. Both are named with their reasons in
  `scripts/compiler-new-parity` and in the fixtures; every other corpus file
  and fixture agrees with the old position.
- **Freeze keeps the full invariant check** in release builds too.
- **Ids are internal identity**, not stable across compiles or between the old
  and new front ends; nothing imitates the old numbering.

## Open decision

- **The other users of the old front end after acceptance.** The formatter
  needs comments, which the stage drops by design, so it keeps its own parser
  or the stage gains an optional trivia table. The linter and the LSP move to
  the stage (the LSP with an in-memory provider for unsaved buffers, and off
  its direct calls to the old discovery).
