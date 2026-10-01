# Discovery Acceptance Roadmap

Preliminary. This is the path from today's `compiler_new/stage_01_discovery`
to the point where we are happy to connect it to the compilation pipeline:
the compiler runs the new stage, a legacy adapter feeds the existing
typecheck, and the old lexer, parser and module loader stop being part of a
compile. The design lives in `docs/DISCOVERY_TABLES_DESIGN.md`; this
document only orders the work and says what "accepted" means.

## Where we are (2026-09-30)

- **Landed:** the stage itself (tables, builder, invariants, lexer, module
  walker, declaration, type, pattern and body parsers), UFCS style, and the
  `compiler-new` gate.
- **Measured on the self-compile inputs:** 0.65 s user CPU against 1.3 s for
  the existing discovery; 4.3 G instructions against 8.6 G; 435 k
  allocations against 7.9 M.
- **Verified:** token parity and accept/reject parity with the existing front
  end over every tracked file (the corpus parity gate, landing with the
  fixture branch), about 45 constructs compared by hand, and one pinned
  fixture per diagnostic code.
- **Not verified:** that the trees are the same. Accept/reject agreement says
  nothing about precedence, attachment, spans or diagnostics after the first,
  and it only covers constructs the corpus happens to use (a probe found the
  old parser accepting `./a/../a/b` imports that the grammar forbids).

## What "accepted" means

We connect the stage by default when all of these hold:

1. **Same program.** For every corpus file, the adapter's rebuilt legacy
   output equals the existing discovery output structurally, with every
   deliberate difference listed and justified (section 10's differential
   check of the design doc).
2. **Same compiler output.** With the new stage switched on, the self-compile
   produces byte-identical C, and every default and premerge gate passes.
3. **Same or better diagnostics.** For the curated and per-code fixtures,
   every parse diagnostic renders at the same position as today, and its
   rendered message and help are diffed against the existing compiler's;
   every wording change is listed and deliberate.
4. **Complete inputs.** The prelude, the embedded standard library and
   source packages resolve exactly as they do today: the adapter
   differential (F2) runs with the embedded-library provider and a
   source-package project, not just files on disk.
5. **Faster.** New discovery plus the adapter costs fewer instructions than
   the existing discovery on the self-compile, and the stage's allocation
   budget test holds.
6. **One syntax.** Every rule that can be decided from syntax alone is in the
   parser (for example `?=` placement, concurrency parameters), and the two
   parsers agree on it for as long as both exist.

Other users of the old front end (the formatter, which needs comments, the
linter, and the LSP's per-keystroke analysis) are out of scope for
acceptance; see the end.

## The work, in order

Sizes are rough: S is under a day of worker time, M a few days, L a week or
more.

### A. Finish what is in flight (S each)

- **A1.** Land fixture parity (corpus parity gate, curated fixtures, per-code
  fixtures), `as` removal, the concurrency parameter rules, `?=` and
  `break`/`continue` placement in the parser, exact-case import paths, and
  `..` only at the start of import paths.
- **A2.** After A1, reorganize the stage into `pipeline.brp`, `tables/`, `sources/`, `lex/` and
  `parse/`, proved by an identical discovery dump and allocation count.

### B. Prove the trees, not just the verdicts (M–L)

B1 and B2 are the adapter's differential check built early, so the rendering
of the old AST they need becomes the adapter's differential oracle, not throwaway code.

- **B1. Declaration differential.** For each corpus file, render the old
  parser's declarations and the new tables into one normalized text form
  (fields in a fixed order, one line per item) and fail on any line that
  differs, except differences named with a reason in the tool's known
  divergence list
  (definition kind, name and visibility; type parameters and bounds;
  supertraits; fields; variants with payloads; signatures; impl receivers;
  every type expression, including dimensions, ranges, function and tuple
  types) and diff per file. Priority, because types, generics, dimensions and
  impls are covered today only by ten declaration tests.
- **B2. Body differential.** The same for expressions, statements and
  patterns, including spans.
- **B3. First-diagnostic position parity.** Extend the corpus gate: when both
  reject a file, the first diagnostic's position must agree.
- **B4. Mutation differential.** Mutate corpus files (delete a token,
  duplicate or swap lines, change indentation, insert `..`) and compare
  accept/reject and the first diagnostic between the two front ends. This is
  the check that would have caught the `..` divergence.
- **B5. Targeted fixtures** for the corners the brainstorm listed: docstring
  attachment, interpolation escapes and nested strings, `Int` minimum
  literals, brace disambiguation (`{}`, `{x}`, `{x = 1}`, `{"a" => 1}`,
  `{r | x = 1}`), layout corners (leading-dot chains after lambdas, anchored
  `if`/`match` as arguments, comments between `if` and `else`).

### C. Complete the inputs (M)

- **C1. Prelude.** Load the 16 implicit prelude modules as the existing
  compiler does.
- **C2. Embedded standard library provider.** The production compiler reads
  the standard library from embedded text; add a provider that answers for
  the standard-library root from those texts.
- **C3. Source packages.** `blorp.toml` aliases through the package catalog,
  as candidate rules in the lookup policy.
- **C4. Qualified trait bounds.** Decide whether `T: module.Trait` is legal;
  if so, give `BoundRow` a path, not a single name.
- **C5. Untested codes.** Tests for `UnreadableSourceDiagnostic` and
  `TooManySourcesDiagnostic`.

### D. Diagnostics users can read (M)

The stage reports coded rows; users need text. Add one rendering table from
`DiscoveryDiagnosticCode` (plus its arguments) to message and help, owned by
the stage, so the old parser's teaching messages survive the switch. The
curated and per-code fixtures then assert rendered text for both front ends.

### E. Ownership workarounds out (S, after the compiler gap fixes land)

When the owned-record hand-off gaps are fixed in the compiler, remove the
builder-threading workarounds (rules 1, 2, 4, 5 and 6 in the builder header)
in one mechanical pass: direct returns instead of `out = f(out); out`, chains
instead of named locals. Proof: identical dump and allocation count.

### F. The legacy adapter (L)

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

-- in the pipeline, behind the switch (F3):
tables: FrontendTables = discover(provider, lookup_roots, root_paths).tables_or_diagnostics()
graph: FrontendCompilationGraph = legacy_frontend_graph(tables)
typecheck_compiler_frontend_graph(graph, ...)          -- unchanged
```
- **F1.** Settle how ids line up: map the stage's breadth-first module and
  definition ids to the order the old graph uses, or show that typecheck does
  not depend on the order (open decision 3). Then write the adapter. Keep it a transformation: no parsing, no
  resolution, no checks of its own; anything it finds missing from the tables
  is a table gap to fix in the stage. The layout check gains one named
  exception: this module may import both `compiler_new` and the existing
  compiler's AST types, and nothing else in `compiler` may import
  `compiler_new`.
- **F2.** Differential: the adapter's output against the existing discovery
  output for every corpus file (acceptance criterion 1). Starts as B1/B2's
  oracle.
- **F3.** A switch in the pipeline, with the existing discovery as default.
  The CLI entry points that parse today reach the old front end through
  `lib/source_graph.brp` (`main.brp`, `test/plan.brp`, `purify/command.brp`,
  `package/check.brp`) or call `parse_compiler_source` directly
  (`test/doctest.brp`, `test/discovery.brp`). First route them all through
  one seam in `lib/source_graph.brp`, then put the switch there. The CLI
  currently parses the root file before discovery; the new stage replaces
  that too.
- **F4.** With the switch on: byte-identical self-compile C and every gate
  green (criterion 2), and the cost measurement (criterion 5).
- **F5.** Flip the default. Keep the old path behind the switch until the
  next bootstrap rotation has run on the new default, then remove it (G).

**After acceptance, the adapter shrinks as typecheck is rewritten.** Each
typecheck rewrite step reads some part of the tables directly (definitions,
then signatures and types, then bodies) and deletes the matching part of the
adapter, until typecheck accepts `FrontendTables` as its input and the adapter
is gone. The adapter's size is the measure of how much of typecheck still
reads the old shapes.

### G. Retire the old front end from compilation (M)

Remove the old lexer, parser and module loader from the compile path. They
are deleted outright only once the formatter, linter and LSP no longer use
them (open decision 4); until then they remain for those tools only. The
corpus parity gate and the rule that every syntax change lands in both
parsers end when the old parser is deleted. `docs/GRAMMAR.md` and the GUIDE record
the grammar the new stage implements, including its deliberate differences
(for example `# N` with a space is rejected).

## Order and parallelism

A1 must finish before A2, and A2 before B–F touch the stage. After that, B, C and D run in parallel (different files);
E waits on the compiler; F starts with F1/F2 as soon as B1's rendering
exists, and F3 onwards waits for C and D. G follows F5.

## Rules for the interim

- **Every syntax change lands in both parsers**, with the corpus parity gate
  and pinned fixtures proving they agree, until G.
- **Rules decidable from syntax go into the parsers**, not typecheck.
- **Fixtures are run or deleted.** No fixture exists that no gate runs.

## Open decisions

1. Qualified trait bounds (C4).
2. Whether release builds keep the full invariant check at freeze (about 8%
   of the stage) or only debug and gate builds do.
3. Module and definition ids: the adapter maps the new stage's
   breadth-first ids to whatever order the old graph uses, or typecheck is
   shown not to depend on the order.
4. The other users of the old front end after acceptance: the formatter
   needs comments, which the stage drops by design, so it keeps its own
   parser or the stage gains an optional trivia table; the linter and the LSP
   move to the stage (the LSP with an in-memory provider for unsaved
   buffers).
