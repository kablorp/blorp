# Cut Over Source Callable Candidates And Overloads

**Status:** Implemented

**Dependencies:** Issue 39 (complete)

**Baseline:** `8b507154` (`Remove obsolete callable identity index`)

**Parallel work:** Trait and implementation inventories may proceed, but their
production cutovers remain Issue 41. Trait- and implementation-method UFCS
remains Issue 42. This issue must include ordinary source-function UFCS because
those candidates currently come from the same graph-owned `FuncSymbol` values
that this issue removes from `Env`.

## Objective

Make one category-specific accepted-callable table the sole authority for the
complete semantic metadata of accepted source and foreign callables. Make each
module's prepared facts own compact, deterministically ordered callable IDs for
the source names and qualification paths visible in that module.

Remove graph-owned source callables from `Env` while preserving lexical
precedence, import visibility, candidate order, overload selection, diagnostics,
and ordinary source-function UFCS behavior.

This is a vertical cutover, not a cache. The accepted-callable table is built
once from accepted headers, is immutable, requires no invalidation, and must be
introduced only in the same production increment that deletes the superseded
graph callable publication and lookup paths.

## Current State And Opportunity

`register_callable_header` currently repeats work while preparing module
environments. For every local callable and every callable from a compatible
direct import it:

1. converts parameter and return shapes to `SemanticType`;
2. converts dimension constraints;
3. reconstructs generic bound parameters and parameter names;
4. validates resource-result and resource-boundary policy;
5. claims and verifies the callable definition ID;
6. derives purity, loop-producer, foreign, and debug-only metadata; and
7. appends a full `FuncSymbol` to the persistent `Env` scope and name index.

Issues 33-39 removed per-body environment rebuilding and post-resolution exact
callable scans, but module preparation still materializes these complete graph
callable records once per owning or importing module. Lookup then scans graph
functions mixed with lexical symbols, and ordinary free-function UFCS converts
matching `FuncSymbol` values into temporary `OverloadEntry` values.

The standalone `Env.overloads` channel is different from those real source
candidate lists. It has production readers but no production writer; only tests
and a representation benchmark populate it. Treat it as obsolete compatibility
code. Delete its storage and bare-overload-only inference branches rather than
projecting it into the new authority. Keep shared overload applicability and
selection helpers only where the real candidate and UFCS paths use them.

## Required Inventory

Before production edits, map every callable lookup to one of these owners:

| Lookup or value | Owner after this issue |
| --- | --- |
| Function declared in a nested lexical scope | `Env` |
| Compiler builtin callable | `Env` |
| Accepted local module function | accepted-callable table + module view |
| Accepted imported source or foreign function | accepted-callable table + module view |
| Bare, selectively aliased, or qualified source call | accepted-callable table + module view |
| Ordinary source-function UFCS candidate | accepted-callable table + module view |
| Trait, implementation, or implementation-method candidate | existing `Env` path pending Issues 41-42 |
| Selected call's exact metadata | `ResolvedCallInfo` retained by Issue 39 |
| Standalone `Env.overloads` entry | deletion |

The inventory must cover:

- unqualified, selective, aliased, and qualified callable lookup;
- local-module, imported, builtin, and nested-lexical precedence;
- same-name candidate order and overload tie-breaking;
- pure/impure filtering and callback-purity selection;
- generic bounds, inferred type arguments, and dimension constraints;
- source versus foreign origin and resource policy;
- loop-producer and debug-only metadata;
- constructor/callable coexistence;
- ambiguity and duplicate-import diagnostic order;
- ordinary source-function UFCS, including qualified calls; and
- rejected or partial headers and recoverable graph behavior.

Do not infer lexical ownership from `module_path == None`: accepted local-module
functions currently also use that representation. Establish the distinction at
the construction boundary using explicit accepted callable IDs and module
views.

## Required Design

### Category-specific table

Introduce an immutable `AcceptedCallableTable` or equivalently narrow callable
authority. Follow the category-specific pattern established by accepted alias,
record, union, and global authorities; do not retain or route hot lookups
through the generic `AcceptedDeclarationCatalog`.

The table stores one complete, ready-to-use semantic entry per accepted
`CallableId`, including only metadata actually consumed by resolution and
checking:

```blorp
record AcceptedCallableEntry {
	id: CallableId,
	func_type: SemanticType,
	type_params: List[BoundTypeParam],
	param_names: List[Option[String]],
	purity: Purity,
	origin: FuncOrigin,
	resource_args: ResourceArgPolicy,
	dim_constraints: List[(SemanticType, SemanticType)],
	loop_producer: Option[LoopProducer],
	debug_only: Bool
}
```

This is a shape sketch, not permission to duplicate `FuncSymbol` mechanically.
Prefer a callable-specific type whose fields make graph ownership explicit.
Store source names, owners, visibility, or qualification facts once at the
narrowest layer that needs them. Exact lookup validates the complete
`CallableId`; it must not use a synthesized string key or scan all entries.

Convert resolved header shapes and validate source/foreign policies once while
building the accepted table. Accepted and recoverable graphs must retain the
same table lineage. Provisional header construction may keep its current `Env`
path because those declarations are not yet accepted graph facts.

### Compact module views

For every prepared module, retain ordered callable IDs for:

- owner-local source names;
- explicitly selective or aliased imports;
- qualified module-path and original-name lookup; and
- ordinary source-function UFCS names.

Views contain identities and scalar visibility metadata, never copied callable
records, signatures, parameter lists, or constraints. Preserve source and
import order explicitly rather than relying on dictionary iteration.

### Lookup precedence

Lookup must proceed in this order:

1. nested lexical callable or other lexical value from `Env`;
2. accepted owner-local module callable from the module view;
3. explicitly imported callable according to the existing selective/alias
   rules;
4. accepted global or constructor according to the existing value-lookup
   precedence; and
5. compiler builtin fallback where currently permitted.

Use the actual existing behavior and tests as the source of truth where this
outline is incomplete. Do not change overload semantics or diagnostics as part
of the cutover.

### Free-function UFCS boundary

Ordinary source-function UFCS currently discovers graph functions by scanning
`Env.scopes`. Move that discovery to the accepted callable view in this issue,
otherwise graph-owned `FuncSymbol` values could not be deleted without either
breaking UFCS or retaining dual authority.

Lexical-function UFCS may continue to inspect lexical `Env` scopes. Existing
trait and implementation method candidates remain in their current authority
until Issues 41-42; do not migrate or redesign them here.

### Deletion in the same increment

After the new table and views serve every source-callable reader, delete:

- accepted local and imported callable registration into `Env`;
- graph-function reads through `env_lookup`, `env_symbols_named`, and
  `env_get_module_func_symbol`;
- graph-function conversion to temporary UFCS `OverloadEntry` values;
- exact name-plus-definition lookup left over from function body signature
  recovery when the accepted table supplies that entry;
- `Env.overloads` and its bare-overload-only readers, writers, inference
  branches, and tests; and
- adapters that reconstruct `Symbol` or `FuncSymbol` solely for legacy APIs.

Do not retain old/new comparison fallbacks or a shadow `Env` publication.

## Performance Model And Expected Result

The principal savings are construction-side:

```text
before:
  accepted callable -> convert and validate for owner module
                    -> convert and validate again for importing modules
                    -> append full FuncSymbol to each prepared Env

after:
  accepted callable -> convert and validate once into AcceptedCallableTable
  visible edge      -> append compact CallableId to one module view
```

Lookup also avoids scanning graph functions interleaved with lexical symbols
and removes the `FuncSymbol`-to-`OverloadEntry` adapter formerly used by
ordinary source-function UFCS. The table retains canonical types; an owner's
query localizes that one payload on demand because owner bodies still use
owner-local nominal type spellings. Module views retain no full callable
records. Prepared environments therefore retain fewer managed values and do
less ARC/COW work without duplicating authority.

An earlier profile attributed about 4.1% of whole-compiler time directly to
`register_callable_header`, but that predates Issues 33-39 and is an upper
bound, not a promised gain. The realistic current expectation is a low-single-
digit whole-compiler instruction reduction, approximately 1-3%, with larger
benefits on dense multi-module import graphs. Do not claim a 10% improvement.

The accepted implementation must reduce median retired instructions against
baseline `8b507154` and avoid a clear wall-time regression. If the table or
view representation increases whole-compiler instructions, redesign it rather
than adding compensating caches.

## TDD And Structural Proof

Write the counter and behavior assertions before the production cutover.

Test:

- lexical function/value shadowing of accepted module callables;
- local module functions and compiler builtin fallback;
- direct, selective, aliased, and qualified imports;
- same-name candidate order and deterministic selection;
- pure and impure overload behavior, including callback purity;
- generic bounds, inferred type arguments, and dimension constraints;
- source, foreign, debug-only, resource-policy, and loop-producer metadata;
- callable versus global and constructor precedence;
- ordinary and qualified source-function UFCS;
- duplicate imports and exact diagnostic order;
- rejected/partial headers never entering the table or views;
- recoverable graphs excluding failed-module callables; and
- stable candidate order and lookup work when unrelated modules are added.

Require deterministic logical counters equivalent to:

```text
accepted_callable_table_entries == unique_accepted_callables
accepted_callable_semantic_conversions == unique_accepted_callables
module_view_callable_candidate_entries == visible_graph_callable_edges
legacy_graph_callable_env_installs == 0
legacy_graph_overload_installs == 0
module_view_callable_full_record_copies == 0
exact_callable_query_graph_scans == 0
```

The dense fixture must vary module count, callable count, direct-import fanout,
same-name candidate count, and bodies per module independently. Increasing
body count must not increase table builds, semantic conversions, or view
entries.

## Fast Feedback Loop

Use the existing callable-header profiling fixture and declaration-preparation
observation rather than creating a second benchmark framework.

During implementation:

```bash
make
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_callable_headers.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_frontend_declaration_catalog_profile_benchmark.brp
scripts/compiler-check --changed --base main
```

Run the callable-header benchmark with a small matrix that exposes repeat work:

```text
modules: 1, 8, 32
headers/module: 32, 128
parameters/header: 0, 4
dimension constraints/header: 0, 2
direct-import fanout: sparse and dense
```

Report table entries, semantic conversions, visible candidate edges, legacy
installs, errors, checksum, allocations, bytes allocated, elapsed time, and
retired instructions. Fixture setup must remain outside the measurement window.

Before acceptance, build control and candidate once, warm each once, then run
three alternating Phase 01-06 self-check pairs:

```bash
/usr/bin/time -lp bin/blorp check --no-format blorp/src/main.brp
```

No compiler, Clang, test, or benchmark process may run concurrently. Record
all measurements and compare medians. Use a 1 ms `sample` profile only to
diagnose a failed instruction or latency gate.

## Non-Goals

- Do not migrate traits, implementations, trait methods, or implementation
  methods.
- Do not redesign trait dispatch or trait/implementation UFCS.
- Do not change overload resolution semantics or improve diagnostics.
- Do not combine candidate lookup with applicability inference in a cache.
- Do not introduce cache invalidation or store payload-bearing module views.
- Do not route hot lookup through a heterogeneous generic catalog entry.
- Do not move lexical functions or compiler builtins out of `Env`.
- Do not retain legacy candidate reads for comparison.

## Acceptance Criteria

- One category-specific accepted-callable table stores each complete accepted
  source or foreign callable exactly once.
- Module views contain ordered graph callable IDs and scalar visibility facts,
  not copied callable records.
- Lexical lookup runs before graph lookup and preserves current shadowing.
- Bare, selective, aliased, qualified, and ordinary source-function UFCS
  behavior is unchanged.
- Overload choice, purity, generic behavior, resource policy, debug behavior,
  and diagnostics are unchanged.
- `Env` retains only lexical functions, compiler builtins, and declaration
  families explicitly deferred to Issues 41-42.
- The obsolete standalone `Env.overloads` channel is deleted.
- No candidate fallback, dual authority, generic metadata bag, or invalidating
  cache remains.
- Logical construction work scales with unique accepted callables plus visible
  callable edges, not full callable records per importing module or body.
- The focused fixture performs fewer semantic conversions, allocations, and
  retired instructions.
- The Phase 01-06 self-check has lower median retired instructions than
  `8b507154` and no clear wall-time regression.
- Focused suites and `scripts/compiler-check --changed` pass.
- Recoverable graph behavior and failed-module exclusion remain unchanged.
- `docs/ARCHITECTURE.md` describes callable-table/module-view ownership in this
  same merge.

## Stop Conditions

Stop and redesign if any candidate:

- retains graph callables in both `Env` and the new table after the cutover;
- requires invalidation or a mutable cache;
- stores full callable entries in each module view;
- guesses lexical versus module ownership from nullable module paths;
- changes candidate or diagnostic order;
- pulls trait/implementation authority into this issue; or
- fails to reduce whole-compiler median retired instructions.

## Implementation Result

Accepted source and foreign callables now enter one immutable
`AcceptedCallableTable` directly from their accepted headers. Prepared module
views retain ordered table indices for bare, imported, qualified, and ordinary
source-function UFCS lookup. Prepared `Env` values no longer receive graph
callables, and the dormant `Env.overloads` storage and inference path are
deleted. Lexical functions, compiler builtins, traits, implementations, and
their deferred UFCS candidates remain in `Env` for Issues 41-42.

Against baseline `8b507154`, three alternating warmed, uncontended Phase 01-06
self-checks of the same current `blorp/src/main.brp` source produced:

| Metric | Baseline median | Candidate median | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 437,744,783,050 | 316,289,075,209 | -27.75% |
| Wall time | 24.86 s | 17.34 s | -30.25% |
| Peak memory footprint | 1,083,360,360 bytes | 868,762,584 bytes | -19.81% |

Wall times varied with host scheduling, while retired-instruction counts for
each binary remained within 0.2% across all three pairs. The stable instruction
result therefore supplies the primary performance evidence.
