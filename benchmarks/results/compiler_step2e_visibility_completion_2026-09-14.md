# Step 2e Visibility Completion Screen — 2026-09-14

## Decision

Step 2e is complete. Graph `ModuleView` now owns one scope-issued visibility
product containing current occupancy, source-ordered candidate decisions, and
the accepted import payload column. Accepted alias and union construction join
that column through exact `ModuleId` and `DefinitionId` values. The former
graph successful-only inventory and the accepted alias/union path-and-name
regrouping scans are deleted.

The combined production checkpoint improves retired instructions, executable
size, and the bound-stage allocation count. Accepted-stage peak footprint and
RSS remain effectively flat. The accepted checkpoint has a 0.95%
allocation-call cost while retained bytes stay effectively flat. The
concentrated direct-width probe allocates more short-lived objects because it
now constructs the required candidate history; its retired instructions
improve by 2.69% and all objects are released.
That allocation increase is an explicitly recorded capability cost, not an
unbounded scaling failure. A rejected experiment that appended the accepted
column through each immutable API call reduced only 1,400 allocations at 320
rows while increasing retired instructions by about 14%; the retained
newest-first construction log is the better trade.

## Product shape and deleted work

Construction uses a newest-first import log so each admission is O(1). At the
single publication boundary it compacts that transient log into:

- an ordered accepted `BoundImportRequest` semantic-payload column and its
  parallel scalar candidate-row-ID column;
- sparse rejected-import rows and their payloads;
- sparse rejected-local rows; and
- one candidate count whose gaps give accepted rows their issued order.

Accepted local candidates are projected from the occupancy row IDs instead of
being retained in a second list. Retaining accepted import row IDs avoids the
former repeated sparse-gap reconstruction in alias and constructor joins, and
qualified-only derived views preserve those issued IDs rather than reminting
them across filtered gaps. The
published `BoundVisibility` embeds these columns directly, avoiding one
heap-backed nested table per module. The admission owner also embeds its
construction columns directly, avoiding one nested builder record per
candidate.

`module_view_import_bindings` remains a named compatibility boundary. For graph
views it projects source-facing `ImportBinding` values from catalog indexes and
semantic IDs; there is no retained graph-side string-bearing `import_bindings`
copy. Standalone source-mode bindings keep a separate
`standalone_import_bindings` field because they do not share graph ID
provenance.

Accepted alias and union visibility reject a `BoundModule` whose issuing scope
does not belong to the exact header graph. They no longer regroup bindings by module path
and source spelling or rescan module headers to rediscover targets. They use
the binding's exact module/definition IDs. Explicit constructor selections use
an exact constructor-definition-to-parent-header index and do not rescan the
parent's variants. Strings remain only in source-facing diagnostics,
display rows, standalone adapters, and compatibility projections.

## Correctness and fast feedback

The narrow loop is:

```bash
/Users/keithphilpott/CLionProjects/blorp/bin/blorp check --no-format \
  blorp/src/compiler/stage_06_typecheck/modules/module_view.brp
/Users/keithphilpott/CLionProjects/blorp/bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_module_view.brp
/Users/keithphilpott/CLionProjects/blorp/bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
/Users/keithphilpott/CLionProjects/blorp/bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
```

The focused results are 26/26 module-view tests, 23/23 state tests, 165/165
declaration tests, and 67/67 structural boundary tests. The rebuilt compiler
also passes the 26/26 module-view suite under AddressSanitizer. Candidate fixtures
assert exact issued order for accepted locals, accepted imports, idempotent
aliases, conflicts, invalid source catalogs, and invalid targets. They also
assert the winning row ID carried by each conflict, preservation of sparse row
IDs in qualified-only views, and unchanged occupancy on rejection. Constructor
fixtures assert exact definition IDs and verify that qualified-only views
discard selective constructor visibility. Equal-layout tests cover both a
foreign accepted table with a local module and a foreign module with local
tables.

Final validation used a clean serial self-host rebuild. The changed-source
gate passed seven production sources, 16 focused suites, the structural check,
and its leak owner. The broader no-build guard passed 4,613 compiler, 4,474
runtime, and 892 leak tests (9,979/9,979); the LSP protocol gate passed 36/36.

## Resource evidence

One cached sample per guard is sufficient here; wall time is not a claim.
Checksums and result cardinalities matched their baselines.

### Real 64-module selective-import pipeline

The accepted-stage command shape is:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  BLORP_COMPILER_BENCHMARK_COMPILER=/Users/keithphilpott/CLionProjects/blorp/bin/blorp \
  benchmarks/compiler_blorp_benchmark_runner selective-accepted \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp plain \
  accepted 1 64 1 1 4 memory 100 selective
```

| Accepted-stage signal | Pre-candidate baseline | Completed Step 2e | Delta |
| --- | ---: | ---: | ---: |
| allocations / releases | 350,170 / 233,680 | 353,513 / 236,893 | allocations +0.95% |
| retained objects | 116,490 | 116,620 | +0.11% |
| allocated bytes | 8,194,224 | 8,196,368 | +0.03% |
| retired instructions | 1,700,145,863 | 1,666,289,355 | -1.99% |
| peak footprint bytes | 37,126,456 | 37,142,864 | +0.04% |
| peak RSS bytes | 41,107,456 | 41,107,456 | unchanged |

Both sides produced `primary_outputs=1161`, `secondary_outputs=129`,
`accepted_constructor_rows=264`, `accepted_field_rows=321`, semantic checksum
`9051196322135327782`, and constructor checksum `-1538987862295765844`.

The isolated bound stage preserved checksum `-2147185015783105813`:

| Bound-stage signal | Pre-candidate baseline | Completed Step 2e | Delta |
| --- | ---: | ---: | ---: |
| allocations / releases | 181,513 / 180,241 | 179,776 / 177,344 | allocations -0.96% |
| retained objects | 1,272 | 2,432 | Cut A occupancy plus candidate capability |
| allocated bytes | 123,352 | 244,088 | +67,536 bytes over the immediate Cut A owner |
| retired instructions | 1,257,212,038 | 1,217,757,816 | -3.14% |
| peak footprint bytes | — | 17,695,008 | context only |

The immediate pre-candidate Cut A owner retained 2,304 objects and 176,552
bytes. The completed candidate relation adds 128 objects and 67,536 bytes at
this bound-only checkpoint for semantic request payloads and exact accepted row
IDs. That payload remains small in absolute terms, is released with the bound
graph, and avoids keeping source strings in normal accepted requests. Step 7
still owns earlier graph release.

### Concentrated immutable-snapshot width guard

The wide command is:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  BLORP_COMPILER_BENCHMARK_COMPILER=/Users/keithphilpott/CLionProjects/blorp/bin/blorp \
  benchmarks/compiler_visibility_width_profile \
  100 16 128 128 64 64 512 0 1 1
```

It produced 320 bound rows, 256 accepted bindings, 64 exact rejected outcomes,
512 final query hits, checksum `341900`, and one retained result object/96 bytes.
The completed owner used 249,601 allocations and 249,600 releases; a strict
leak-check run released all 161 measured objects and reported zero leaked
bytes. It retired 825,817,022 instructions. The immediate pre-candidate builder
used 179,901 allocations and retired 848,627,329 instructions.

The allocation increase is large (+38.74%) in this deliberately concentrated
probe, but bounded and linear: each newly required candidate becomes a
transient log node and accepted or sparse rejected publication row, and every
one is released. Retired instructions improve by 2.69%. The probe retains
its initial immutable view across all iterations, preventing in-place mutation
that production could otherwise exploit. A single-call buffered admission API
could clone occupancy once, but preserving source-ordered private/missing
diagnostics and parent-before-constructor outcomes would require a second
request/outcome replay subsystem. That complexity and buffering are not
justified by the real-pipeline result.

One process sample reported 1,900,832 bytes peak footprint versus 1,917,216
before (-0.85%); short process peaks and elapsed time are context only. The
accepted/bound benchmark executable decreased from 5,987,992 to 5,956,512
bytes (-0.53%).

## Acceptance

- One issuer-scoped occupancy/candidate owner replaces the graph dictionaries
  and successful-only binding inventory.
- Accepted, idempotent, rejected, invalid-source, and invalid-target decisions
  preserve source order and exact winner references.
- Ordinary accepted alias, union, and constructor construction uses exact IDs;
  displaced path/name regrouping and header rescans are removed. Graph import
  registration runs with `AcceptedAliasAuthority` already attached, so header
  installation consumes that exact-ID authority directly. The legacy alias
  projection now reads only standalone bindings and cannot materialize the
  graph compatibility list per header.
- Accepted authorities remain attached to the same `ModuleView` and do not
  copy the bound candidate rows.
- The real accepted-stage checkpoint improves instructions and code size;
  peak footprint and RSS stay within 0.04%, allocation calls rise 0.95%, and
  retained bytes remain within 0.11%. The real bound stage improves allocations
  and instructions; its exact candidate payload adds 67,536 retained bytes over
  Cut A.
- Remaining source strings have named diagnostic, display, standalone, or
  compatibility consumers. No LSP visibility consumer is invented; genuine
  analysis migration remains Step 8.
