# Issue 61B: Establish The Canonical Graph Definition Table

**Status:** Implemented and validated

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependency note:** The repository already used Issue 61 for carrying module
IDs in resolved-call metadata. This document retains the normalized roadmap's
original title while calling the prerequisite 61B to avoid changing either
completed issue's history.

**Blocks:** Issue 68, which needs a category-checked definition foreign key and
an exact source-definition lookup.

## Objective

Make the production `DefinitionIndex` own one immutable canonical table of
graph definitions:

```text
DefinitionTable
  runtime definition Int -> DefinitionId -> DefinitionRow

DefinitionIndex
  ModuleId + source name -> ordered DefinitionId candidates
```

The table stores each definition's module, category, source name, optional
owner name, and span once. Callable and source-name buckets retain only
ordered scalar `DefinitionId` values and validate candidates against canonical
rows. This is the exact lookup boundary required by Issue 68; it does not yet
change typed callable, constructor, type, global, trait, or implementation
identity payloads.

## Production Audit

### Definition allocation

All production `env_mint_def_id` calls were traced.

1. `type_system/builtins.brp` mints builtin functions, resource functions,
   constructors, and builtin implementations before the graph seed is taken.
2. `type_system/env.brp` retains `env_add_func` and constructor fallback
   minting. No Stage 06 production caller uses `env_add_func`; constructor
   fallback is used while installing builtins. Accepted union installation
   supplies reserved constructor IDs.
3. `state.brp` mints a source definition only in an extensible direct-program
   scope. It immediately inserts that exact frontier ID through one of the two
   definition-index insertion functions.

Builtin trait identities also have compiler-owned fixed values. They are not
graph rows and are not classified by comparing their integer with the graph
base. A raw runtime ID becomes a `DefinitionId` only when the issuing table
contains a row at that exact dense offset.

### Graph reservation order

`definition_index_for_loaded_modules` preserves the existing order exactly:

1. start at `definition_index_initial_seed(ENV_EMPTY)`;
2. reserve the target module first;
3. sort dependency modules by canonical path;
4. visit declarations in source order;
5. visit union variants, record fields, foreign functions, implementation
   defaults, and explicit implementation methods in their existing order; and
6. leave repeated exact reservations idempotent.

Each successful reservation increments the frontier by one. No production
graph constructor skips an ID after the seed.

### Direct and replay behavior

Direct source checking mints the current frontier and immediately inserts the
same definition, so direct extension is also dense. Append-only `ModuleTable`
rebasing preserves existing module ordinals, rows, buckets, and definition
IDs. A reordered or otherwise incompatible module table still fails closed.

Accepted graph checking consumes reserved IDs and does not append definitions.
Generated Core IDs continue from the published Stage 06 frontier and remain
outside this source-definition table.

`definition_index_advance_to_env` preserves the established contract that
installing a prepared graph never lowers an already advanced environment
frontier. That frontier can therefore exceed the table's row frontier, but it
does not synthesize rows: raw row admission is bounded by `rows.length()`. Any
later attempt to append a source definition after the two frontiers diverge
fails closed. Normal graph and direct source construction keep them equal.

### Gap policy

The old insertion helpers accepted any ID at or above the frontier. Only two
low-level unit fixtures used that ability to manufacture forward gaps. No
production caller did. Insertion is now append-only:

```text
new definition ID == current allocation frontier
```

Same-key/same-ID insertion remains idempotent. Remapping, below-frontier reuse,
cross-category reuse, and forward gaps all fail without publishing a row or
advancing the frontier.

### AcceptedDeclarationCatalog reachability

`headers/declaration_catalog.brp` had no production importer. Its only readers
were its dedicated TestSuite and `compiler_declaration_catalog_profile`
benchmark. That dormant model, its test, its benchmark source/wrapper, and its
ownership entries were deleted rather than retaining a second declaration
authority.

The similarly named `compiler_frontend_declaration_catalog_profile` remains.
It is the Issue 15 production preparation/semantic inventory harness and never
consumed `AcceptedDeclarationCatalog`.

## Implemented Representation

```blorp
opaque type DefinitionId = Int

record DefinitionRow {
    module_id: ModuleId,
    kind: DefinitionKind,
    name: String,
    owner_name: Option[String],
    span: SourceSpan
}

private record DefinitionTableRep {
    module_table: ModuleTable,
    first_graph_definition_id: Int,
    rows: List[DefinitionRow]
}

opaque type DefinitionTable = DefinitionTableRep
```

`DefinitionId` is an unboxed, table-scoped foreign key. It deliberately does
not retain a graph/table pointer. As with `ModuleId`, an equal integer from an
independent table cannot authenticate itself; phase boundaries must carry the
issuing table and admit IDs through its lookup API.

`DefinitionIndexRep` owns the frozen table and two separate module/name index
families. Separate callable and source indexes avoid cross-category candidate
reads. Their bucket payloads are `List[DefinitionId]`, not key-bearing records.

The graph builder first constructs one module's candidate rows in a standalone,
exclusively owned list. It then derives the module's callable/source ID buckets
from those rows, skips any exact repeated reservation, and concatenates the
accepted rows into the graph accumulator once per module. The two outer bucket
lists are likewise published once per module, and the final table is frozen
once after all modules have been visited.

This row-first shape is required by Blorp's COW ownership lowering. Keeping the
row list inside the per-declaration build record caused the generated C to
retain the record and its row list before every append, which copied the whole
prefix and made graph construction quadratic within a module. A nested
list-of-row-groups alternative was rejected because the focused leak check
proved that its managed row/spans were not released after flattening. The final
shape has neither behavior. Graph-index construction creates neither
`FuncCallableKey` nor `SourceDefinitionKey`; those legacy values remain at
existing direct insertion, exact lookup, and compatibility projection
boundaries.

## Public Boundary

The compact table API provides:

- exact runtime integer projection from `DefinitionId`;
- validated raw-runtime-ID admission;
- row and owner-module lookup;
- access to the issuing `ModuleTable`; and
- callable- and constructor-category checked admission for Issue 68.

There is no public row insertion, table constructor, generic transaction API,
semantic type, typed body, `Env`, or Scope exposure.

## Correctness Tests

Focused tests cover:

- exact rows and dense offsets from the builtin seed;
- all seven categories: callable, type, constructor, field, global, trait, and
  implementation, including implementation methods as callables;
- builtin/below-base and above-frontier misses;
- category-checked callable/constructor admission and wrong-kind rejection;
- exact overload, owner, kind, module, and span discrimination;
- deterministic target/dependency/declaration/member order;
- idempotent repeated bindings and fail-closed remapping/reuse/gaps;
- append-only module-table rebase and incompatible-table rejection; and
- unchanged benchmark checksums, lookup hits, counts, and frontiers.

The ownership manifest maps `definition_index.brp` to all four definition-index
suites and the retained declaration-boundary structural check.

## Measurement

Baseline and candidate were built from the same `927fcfb7` source base and run
through `compiler_definition_index_profile`. Final raw output and its
deterministic summary are retained locally in the ignored
`logs/issue61-definition-table/final3/` directory. Each row below is the median
of three alternating baseline/candidate pairs; allocation counts were
identical across all three samples.

| Workload | Baseline allocations | Candidate allocations | Baseline elapsed (us) | Candidate elapsed (us) |
| --- | ---: | ---: | ---: | ---: |
| 1 module x 256 functions, construct only | 13,210 | 5,640 (-57.3%) | 3,390 | 539 (-84.1%) |
| 64 modules x 8 functions, construct only | 11,772 | 6,978 (-40.7%) | 1,143 | 921 (-19.4%) |
| 10,000 exact source lookups | 40,000 | 40,000 (0%) | 3,020 | 2,849 (-5.7%) |
| 10,000 owner/type lookups | 40,000 | 40,000 (0%) | 2,678 | 2,769 (+3.4%) |
| 2,000 broad compatibility projections, 40,000 results | 56,000 | 96,000 (+71.4%) | 5,949 | 7,967 (+33.9%) |

All 15 pairs reported `workload_valid=True` and equal semantic, query, count,
hit, and allocated-frontier fields. The accepted builder removes 7,570
allocations across ten narrow builds and 4,794 allocations across three wide
builds. Exact canonical lookups add no allocations. The elapsed query samples
are short and are reported as directional evidence; the deterministic
allocation counts are the query regression gate.

The broad row is intentionally retained as a compatibility-boundary warning:
that API promises managed legacy key records, so the canonical implementation
must reconstruct one key for every returned row. It is not the lookup path
Issue 68 will consume, and the declaration-skeleton production caller now uses
`DefinitionId` plus canonical rows directly. Removing remaining compatibility
projection APIs is explicit follow-up work; this issue does not hide their cost
or claim it as a win.

### Direct insertion

The graph benchmark does not exercise the persistent direct-program extension
API. A temporary benchmark therefore inserted unique type rows through the
actual `definition_index_insert_source_definition_id` boundary. Raw output is
retained in the ignored `logs/issue61-definition-table/direct-insert/`
directory. All twelve pairs had identical counts/checksums, completed with zero
retained objects, and reported these three-pair medians:

| Rows per fresh index | Iterations | Baseline allocations | Candidate allocations | Baseline elapsed (us) | Candidate elapsed (us) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,000 | 16,000 | 19,000 (+18.8%) | 2,800 | 3,620 (+29.3%) |
| 16 | 100 | 18,100 | 21,400 (+18.2%) | 3,178 | 3,570 (+12.3%) |
| 64 | 25 | 17,725 | 20,950 (+18.2%) | 3,608 | 5,068 (+40.5%) |
| 256 | 10 | 28,210 | 33,340 (+18.2%) | 9,833 | 13,187 (+34.1%) |

The deterministic delta is two allocations per accepted direct row plus one
per fresh index. The direct path publishes an immutable nested table record and
may copy its row-list prefix; it does not use the graph's row-first builder.
This is a measured regression for large sequences of direct insertions. It is
accepted here because normal loaded-module graph construction, including the
production compiler replay, uses the batched graph builder; changing direct
`TypecheckState` publication would broaden this prerequisite into a separate
transaction/batching design. A follow-up must either batch that extensible
boundary or establish an ownership-safe table transfer before direct checking
is treated as a high-volume path.

The benchmark runtime exposes allocations and live allocated bytes, but not
release or retained-object counts. The focused leak-check suite therefore
provides the ownership evidence: all 10 definition-index tests pass with zero
leaks.

### Production replay

The final replay built baseline and candidate workers sequentially from the
same temporary checkout path, the same bootstrap compiler, and the same
`927fcfb7` source base. The candidate source patch was
`eb3da301eec886ee8ac584db243d0dffe527cd33d452656631eb116d7f18201b`.
The optimized worker hashes were:

- baseline: `8d81d7eb5aa617c114e1b1c2e4d5f63e36d0659fdf1f1349da4bed0e3b9c8967`;
- candidate: `3234612e5364303fdb00d70211b4eaccaec78c67e07259e949ea9e66734c3b30`.

One warmup per worker preceded six serial measured pairs. Pairs 1-3 ran
baseline then candidate; pairs 4 and 6 reversed the order, while pair 5 kept
baseline then candidate. Every run was verified, exited zero, had allocator
stats, and avoided timeout and the 4 GiB sampled-RSS limit. Request hash
`de93c30a153c0e60a75c3fdb548866d08eb76ebab1721266d5b16f8ddb539b4c`
was sliced identically to replay-request hash
`5eabbc7bafad8b070b8d9d2ff13c71bb5b5f4760cb0989c2827c00b0a5843c6b`.
All twelve measured responses were byte-identical: 1,755,080 bytes with hash
`f11d97d6f1cf5ac91ae76d1461ded8ba5a8884f1217504621bf3707d75363851`.

| Production target-only metric | Baseline median | Candidate median | Delta |
| --- | ---: | ---: | ---: |
| Elapsed | 4.0779 s | 4.1645 s | +2.12% |
| Peak sampled RSS | 497,483,776 | 497,991,680 | +507,904 (+0.10%) |
| Allocations | 58,062,289 | 57,993,699 | -68,590 (-0.12%) |
| Releases | 52,840,514 | 52,796,050 | -44,464 (-0.08%) |
| Current objects | 5,232,264 | 5,208,138 | -24,126 (-0.46%) |
| Live allocated bytes | 471,471,840 | 470,896,416 | -575,424 (-0.12%) |

Elapsed ranges overlap: baseline 3.9820-4.3689 seconds and candidate
4.0689-4.6571 seconds. The +2.12% median is therefore reported as below-noise
for this six-pair host sample, not as a speedup. The focused construction
benchmark is the direct latency evidence; the production replay establishes
byte identity and a deterministic allocation/retention improvement.

The trace label `graph_parse_complete` is not a parser-only checkpoint:
`bridge.brp` emits it after `indexed_graph_build`, so it includes definition
index construction. Conversely, `graph_definition_index_complete` is emitted
after the index already exists and cannot isolate construction. The replay
therefore does not attribute index cost to that later 192-311 microsecond
marker. Raw JSON, stderr, worker sources, and summaries are retained in the
ignored `logs/issue61-definition-table/production-replay-v3/` directory.

Generated C in the ignored
`logs/issue61-definition-table/final-generated-c/` inspection shows:

- `DefinitionId` and `ModuleId` arguments and fields lower to scalar `long`;
- name buckets are lists whose payloads are scalar definition IDs;
- `DefinitionTableRep` owns the module table, first graph ID, and row list; and
- row append helpers receive an owned list directly and test uniqueness before
  capacity growth, without retaining an enclosing build record; and
- the graph freeze path contains one final `DefinitionTableRep_make` after all
  module reservation loops.

This prerequisite is accepted as normalized infrastructure with a focused
construction win. It removes duplicate retained key records, establishes the
exact lookup boundary needed by Issue 68, and keeps exact lookup allocations
neutral. Issue 68 may proceed against this boundary without carrying structural
declaration identities into its leaf products.

## Limits

- Builtins and generated Core definitions are outside this table.
- `owner_name` remains descriptive until later category/edge-table work.
- Projection APIs that still promise legacy keys reconstruct those keys from
  canonical rows. Production exact lookup and declaration-skeleton matching
  read IDs/rows directly.
- Repeated direct-program insertion has the measured persistent-publication
  regression above; Issue 68 must not route graph registration through it.
- The production replay does not isolate definition-index wall time because
  the current phase markers bracket larger graph work.
- This change does not claim a compiler-wide latency improvement. Its measured
  wins are focused construction allocations/time and production retained
  objects/bytes; its architectural value is making Issue 68 mechanical.
