# Discovery as Normalized Tables

This is the contract of the implemented discovery stage under
[`stage_01_discovery/`](../blorp/src/compiler_new/stage_01_discovery/).
The graph seam in [`lib/source_graph.brp`](../blorp/src/lib/source_graph.brp)
runs it and the legacy adapter by default before typecheck. Source and tests
own the exact schema; this document explains its invariants and boundaries.
The [typed-tree redesign](DISCOVERY_REDESIGN.md) remains an active,
unimplemented proposal. The [acceptance roadmap](DISCOVERY_ACCEPTANCE_ROADMAP.md)
owns parity, hardening and old-front-end retirement work.

## Owners and entry points

Start with [`pipeline.brp`](../blorp/src/compiler_new/stage_01_discovery/pipeline.brp):
it owns the module walk and `load_module` order. The stage imports only its
own modules and `lib`, enforced transitively by `scripts/check-blorp-layout`.

| Boundary | Source of truth |
| --- | --- |
| IDs and locations | [`tables/ids.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/ids.brp), [`tables/span.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/span.brp), [`tables/source_position.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/source_position.brp) |
| Rows and node shape | [`tables/rows.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/rows.brp), [`tables/row_kinds.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/row_kinds.brp) |
| Construction | [`tables/builder.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/builder.brp), [`tables/node_builder.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/node_builder.brp) |
| Sealing and reads | [`tables/frontend_tables.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/frontend_tables.brp), [`tables/discovery_tables.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/discovery_tables.brp), [`tables/invariants.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/invariants.brp) |
| Loading and lookup | [`sources/source_provider.brp`](../blorp/src/compiler_new/stage_01_discovery/sources/source_provider.brp), [`sources/module_graph.brp`](../blorp/src/compiler_new/stage_01_discovery/sources/module_graph.brp), [`sources/source_admission.brp`](../blorp/src/compiler_new/stage_01_discovery/sources/source_admission.brp) |
| Diagnostics | [`tables/diagnostic_code.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/diagnostic_code.brp), [`tables/expected_token.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/expected_token.brp), [`diagnostics/render.brp`](../blorp/src/compiler_new/stage_01_discovery/diagnostics/render.brp) |
| Legacy seam | [`compiler/discovery_front_end.brp`](../blorp/src/compiler/discovery_front_end.brp), [`compiler/discovery_adapter.brp`](../blorp/src/compiler/discovery_adapter.brp) |

`tables/` imports no other stage folder; `sources/` and `lex/` depend on
tables; `parse/` uses those boundaries. Rendering consumes tables and provider
spelling support outside lexing/parsing. Tests mirror the owners under
[`blorp/test/test_compiler_new/test_stage_01_discovery/`](../blorp/test/test_compiler_new/test_stage_01_discovery/).

## Identity and source authority

Each table has a separate opaque ID over `Int`; its value is its row index,
valid only within the issuing compilation. Definition identity is minted in
discovery. The builder owns allocation, but exported `*_id_at_row` converters
mean this is construction discipline, not unforgeability. Callers read the
next ID before append; no intervening append to that table may occur.

A module's canonical path is stored once in its `SourceRow`. Source text is
indexed by `SourceId`; line starts occupy a contiguous range. Origin, package
and reach are loading facts. `ModuleReach` distinguishes root, implicit and
imported modules. Root request spelling is retained separately for display.

`Span` packs source index, start byte offset and byte length into 63
non-negative bits:

| Field | Bits | Admission limit |
| --- | --- | --- |
| Source index | 15 | 32,767 admitted sources; last index reserved for `NO_SOURCE` |
| Start offset | 24 | Source byte length strictly below 16 MiB, including its end offset |
| Length | 24 | Strictly below 16 MiB |

Admission rejects oversized sources/excess source count before parsing, so
packing loses no admitted position. Every stored span names real syntax,
including synthesized rows pointing to their cause. `NO_SPAN` is only a
lookup fallback in the reserved source; storing it in frozen rows fails
`SpanOutsideSources`. Locations count bytes; tabs advance to multiples of four.

## Rows, ranges and construction

The flat `DiscoveryBuilder` owns output and transient state. Source record
spellings accept type parameters; a `fixed record` whose fields are all numbers
(including opaque ids over `Int`) is stored inline, and every other record is
managed. Row construction and storage costs require measurement.
Text lives in the names, paths, source-text and literal tables. Optional
relationships are side rows, at most one per owner; variable-length children occupy
contiguous child-table blocks addressed by `RowRange`.

Module definition/import/node/syntax-diagnostic ranges close after its parse.
Imports, selected items and foreign blocks append at close from typed
openings. Definitions append when their name is read, because members need
the owner ID; close updates their extent. Class-specific openings constrain
which definitions receive bodies, written types, payloads and members.
Closing each opening once remains a caller obligation checked in debug
builds, rather than by linear types.

A definition-type root's role follows its definition kind: return type,
global declared type, alias/opaque target, impl receiver or field type.
Local functions have ordinary definition/signature/body rows and a body node
carrying their definition ID. Qualified bounds/supertraits use optional
qualifier side rows; written-type bounds use qualifier children instead.

Bodies, patterns and written types share a flat post-order node table.
`NodeRow` contains kind, span, integer payload and a range into `node_children`.
Typed appenders constrain payload class. `node_schema` owns each kind's
payload, arity, name-span rule and child order, with no catch-all arm.
Optional children are recognized by kind, not position alone. Children push
onto a transient stack while parsed; a parent consumes its top entries into
one contiguous edge block, then appends once. Recursive children need not be
adjacent in the node table.

Identifier extents narrower than their node have side rows; `node_name_span`
otherwise uses the node span. An `if` with an else branch stores the `else`
keyword separately, since neither branch spans it. These are source facts
the adapter must preserve. Grouping widens expression spans except for
token-exact forms used by reference/rename tooling. Literal and pattern
string kinds preserve written form.

Names/literals use source-slice interning in
[`intern_index.brp`](../blorp/src/compiler_new/stage_01_discovery/tables/intern_index.brp),
so repeated identifiers need no substring allocation. The builder seeds the
old compiler's vocabulary at pinned IDs, plus discovery-only names. Dimension
names store both `N` and legacy `#N`, related by a side row. Sealing drops
interning indexes; frozen readers receive the text tables.

Keeping an old builder live across append can copy its record and affected
tables, making repeated appends quadratic. Current workaround shapes belong
to the `builder.brp` header and its probes. The allocation-budget suite repeats
construct families and pins allowances. The acceptance roadmap requires
re-probing before deleting workarounds after compiler fixes.

## Sealing obligations

`freeze` always checks invariants; there is no trusted mode. Success produces
opaque `FrontendTables`; failure reports every `TableInvariantViolation`.
Sealing moves output lists into `DiscoveryTables` and drops tokens, cursors,
pending headers, interpolation scan data, child-stack state and interning
indexes. The explicit field mapping is tested with distinct text contents.

Checks cover the facts construction types do not state:

- IDs reference existing rows of the correct table; ranges stay in bounds.
- Children precede parents; each node belongs exactly once to a child edge
  or body/type/payload/constraint root. Body roots stay in their module.
- Arity/payload match `node_schema`; local-function nodes name local function
  definitions; codepoints are Unicode scalar values.
- Optional side rows are unique, owner-search tables sorted, and function-like
  definitions have exactly one signature (others none).
- Spans stay in source text; name spans lie inside owners and exist where
  required; else-keyword rows match the correct `if` form.
- Seeded vocabulary, dimension sigil spelling, intern indexes and parallel
  tables agree. Recovery diagnostics belong to their module.

The precise catalogue and negative tests live in
[`tables/invariants/`](../blorp/src/compiler_new/stage_01_discovery/tables/invariants/)
and [`test_invariants.brp`](../blorp/test/test_compiler_new/test_stage_01_discovery/test_tables/test_invariants.brp).
Accessors binary-search owner-sorted side tables. Some supposedly total reads
still use `UNREACHABLE_*` fallback rows in release builds. Adapter reads must
not let invented fallback values reach an AST.

## Diagnostics and recovery

Syntax, import-resolution, root and implicit-request diagnostics have separate
typed unions. Code arguments carry IDs, paths, literals, names or characters;
missing-token codes also carry the parsed construct. Limits come from named
constants. Rendering exhaustively supplies message/help text at the display
boundary. Freeze validates referenced IDs.

The table parser continues after errors and writes recovery nodes. Recovery
appenders report diagnostics too; rejected field assignment records its
diagnostic before parsing its value, so freeze checks that association.
Missing names use seeded `EMPTY_NAME`. The tree proposal would instead return
diagnostics with no tree for a rejected module.

Compilation reports root/implicit failures first, module syntax diagnostics
in module order next, then import failures. Lex/parse errors, case mismatch,
unreadable/unverifiable/oversized sources and missing implicit modules stop
discovery. An import finding no module remains an unresolved graph edge;
commands/later stages report it in their own terms.

Fixtures pin diagnostic code, rendered text and position. Deliberate old-parser
differences are reasoned allow-lists in
[`scripts/compiler-new-parity`](../scripts/compiler-new-parity) and fixtures.
The acceptance roadmap owns remaining differences and coverage gaps.

### Diagnostic text

The fixtures and renderer are the exact difference catalogue. Discovery adds
help where old messages lacked advice. `ReservedKeywordAsName`,
`DiscardedQuestionBind` and `FieldAssignment` move the same advice from the
message to help. `ExpectedIndentedImports`, union-variant `ExpectedIndent`
and `InterpolationHoleNotExpression` replace text naming the wrong construct
or exposing an internal parse step. General block-indent errors name an
indented block, not always a function body. Invisible unexpected characters
are rendered as `U+XXXX`; invalid bytes use hexadecimal. Provider failures
add actionable path/spelling/size detail unavailable from the old diagnostic.
`EXPECT-DISCOVERY-TEXT` and `DISCOVERY-POSITION-DIFFERS` pins must name deliberate
differences and fail once they stop differing. The position exceptions for
`import_constructors_unclosed` and `interpolation_hole_two_expressions` remain
reasoned fixture/parity entries.

## Providers and discovery order

Existence/reads sit behind `SourceProvider`; lookup policy is shared by
filesystem, in-memory and embedded-standard-library providers. Unsaved-buffer
resolution therefore follows build policy. The first existing candidate wins:

- User/native-package modules: source-package aliases (exports only), then
  standard library, then the importer's directory.
- Source-package modules: their own modules, then standard library.
- Standard-library modules: standard library only.
- Relative requests preserve placement; source-package relatives stay under
  their source directory. `pkg/` requests resolve from user/native-package
  modules, not standard-library/source-package modules.

An adjacent bare module found by a native-package module is user code, as in
the old loader. Structured request shape/path parts drive lookup; written
request text is derived. Package catalogues are inputs to the same walk.
The embedded provider answers under `<embedded-std>` and delegates other
paths; composition supplies generated texts via `EmbeddedStandardLibraryTexts`
outside the stage. Consumers derive legacy `<embedded:name>` display paths.
Exact-case verification caches each directory listing once per discovery.

The walk loads roots in caller order, implicit modules in supplied order,
then imports breadth first, module by module in source order. Each canonical
path loads once; its first request determines reach and identity. This avoids
old-loader duplication when bare and relative requests reach the same file.
Implicit `prelude`/`tuple`, plus `test` when testing, load immediately after
roots. They have separate request outcomes, not root rows. An already-loaded
root retains root reach; a missing seed is an error. Parity checks the
restated seeds and module order. Loading resolves, admits, opens, lexes,
parses and closes, then records the outcome; failures do not end the walk.

## Lexer, parser and adapter seam

### Running the stage from the CLI

Lexing fills transient tokens and interns text. `#N` is one dimension-name
token; `# N` is rejected. Interpolation scans decoded text pieces/hole byte
ranges once. Hole tokens append after the module end-of-file token and parse
with the same builder/name table. Final nodes separate text and holes; each
hole has its own span/identity for Core's text-conversion call. Braces outside
holes are text; interpolated patterns are rejected.

Parsing writes rows directly, with no intermediate syntax tree. Interpolation
and compiler-owned forms finalize as encountered. Binary operators have one
token map and total precedence/kind maps. Assignment is a statement;
expression-position assignment, including named call arguments, is a parse
error. The [Guide](GUIDE.md) and [Grammar](GRAMMAR.md) own syntax rules.

Only `discovery_front_end.brp` and `discovery_adapter.brp` may import
`compiler_new` from `compiler`, as
[`source_ownership.json`](../blorp/source_ownership.json) records. The former
composes providers, root placement, package lookup and implicit modules and
renders failures. The adapter transforms tables to `FrontendCompilationGraph`;
it does not parse or resolve modules. Existing finalization, surfaces and
graph validation are services it calls, not duplicated implementations.

The adapter builds owner indexes once. Its body reader scans post-order nodes
once, keeping rebuilt values by node position: local-function roots can
interrupt siblings, so a simple stack would not suffice. Deep left chains do
not recurse. Interpolation crosses in already-parsed form. Name IDs pass
through; definition IDs have no old-AST field; module order needs no mapping.
The first targeting import determines an imported module's legacy name.
`LegacyModuleNaming` supplies caller-selected root/path conventions, including
working-directory spellings later passes use for builtin modules.

Missing rows/malformed shapes are `LegacyAdapterError`s, never placeholders.
Invariant/adapter defects are internal compiler errors; `GraphRejected`
preserves the graph service's program diagnostic.
[`discovery_adapter_differential.brp`](../blorp/test/test_compiler/tools/discovery_adapter_differential.brp)
compares full old-parser/adapted ASTs, spans included, over corpus/root projects.
Generated C must be identical, allowing normalization only for ID-derived names.

As typecheck reads discovery directly, each migration deletes matching adapter
work. Later phases own reference/type/impl facts keyed by discovery IDs and
never write facts into syntax. Legacy-consumer retirement is independent of
whether the tree proposal lands; the acceptance roadmap holds its blockers.

## Cost evidence and remaining representation debt

Use the [Worker Checklist](WORKER_CHECKLIST.md) and
[measurement protocol](../benchmarks/README.md#self-compile-measurement-protocol).
Discovery's workload is the graph from `blorp/src/main.brp`, including implicit
modules. Distinguish stage-only from adapter/finalization cost and require
module/AST and generated-C identity. Historical evidence lives in the
[declaration report](../benchmarks/results/discovery_adapter_declarations_2026-10-01.md),
[body report](../benchmarks/results/discovery_adapter_bodies_2026-10-01.md) and
[default-stage report](../benchmarks/results/discovery_stage_switched_on_2026-10-01.md).
They include the temporary graph memory peak, not a current matched baseline.
The tree proposal owns its future ceiling.

Remaining debt includes predicted IDs/close-once discipline, freeze-only
signature cardinality, last-node-attached name/else spans, legacy dimension
sigil caches, seeded missing names, lexer sentinels (`EMPTY_SLOT`, `NO_ROW`/
`NOT_INTERNED`, `NO_DEDENT`, `NO_PLAIN_STRING_CLOSE`) whose scalar `Option`
replacement needs measurement, and release fallback rows. Constraint end spans
are still read by position rather than returned with parse state. Nesting
output tables under the builder would remove the explicit sealing field map,
but needs fresh append-cost evidence after compiler handoff fixes, rather
than assuming an old compiler blocker persists. Root/implicit handling may
be unified if a third request kind or reader justifies it.

Parallel parsing/incremental rediscovery are outside this implemented design.
Name resolution and types belong to later phases.
