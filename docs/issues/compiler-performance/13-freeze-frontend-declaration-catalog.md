# Freeze Frontend Declarations Once Per Typecheck Graph

**Status:** Umbrella roadmap; execution decomposed into Issues 15-23

## Issue Summary

Build one immutable, identity-keyed declaration catalog for an accepted
typecheck graph and make each module body checker consume a small visibility
projection over that catalog. Stop reinstalling the reachable declaration
closure into a separate persistent `Env` for every module.

This is an architectural performance issue, not a request to rename helpers or
batch one more insertion loop. It is intended to remove repeated graph-wide
work and make the remaining body checker depend on immutable graph facts plus
small body-local state. It is also a prerequisite for safely typechecking
independent bodies in parallel.

The implementation must begin with counters and scaling measurements. Do not
introduce the catalog until the baseline proves which declaration categories
are repeatedly installed and how that work scales with module count, declaration
count, import fan-out, and reachable-closure size.

## Execution Issues

Do not implement this umbrella as one branch. The executable sequence is split
into the following independently reviewable merge points:

| Order | Issue | Resulting merge point |
| ---: | --- | --- |
| 1 | [Measure scope materialization scaling](15-measure-scope-materialization-scaling.md) | Current work and scaling are observable without changing semantics. |
| 2 | [Generalize mixed-symbol batching](16-generalize-mixed-symbol-batching.md) | Existing publication can batch heterogeneous symbols through one checked scope update. |
| 3 | [Batch callable-header publication](17-batch-callable-header-publication.md) | Callable preparation is separated from ordered publication. |
| 4 | [Batch imported-module publication](18-batch-imported-module-publication.md) | Each imported module publishes one checked declaration plan rather than repeated persistent updates. |
| 5 | [Build an accepted declaration catalog](19-build-accepted-declaration-catalog.md) | A checked catalog can be constructed and validated, but is not retained by production. |
| 6 | [Retain the catalog and build module views](20-retain-catalog-and-build-module-views.md) | One graph catalog and compact identity-based views exist alongside the authoritative legacy reads. |
| 7 | [Cut over types and constructors](21-cut-over-types-and-constructors-to-catalog.md) | Graph-owned types and constructors have one catalog authority. |
| 8 | [Cut over values, traits, and implementations](22-cut-over-values-traits-and-implementations.md) | Every accepted graph declaration category has one catalog authority; `Env` is lexical. |
| 9 | [Delete legacy materialization and reprofile](23-delete-legacy-declaration-materialization-and-reprofile.md) | Migration code is gone and production/scaling evidence establishes the final result. |

Issues 15-18 reduce current cost without committing the compiler to the catalog
architecture. Issues 19-20 establish and validate the new representation while
legacy reads remain authoritative. Issues 21-22 move authority one complete
category at a time. Issue 23 is mandatory cleanup and final acceptance, not
optional follow-up work.

The child issues are authoritative for implementation scope and tests. The
remaining sections of this document explain the architectural rationale and
the intended final state.

## Why This Is A High-Leverage Issue

The latest production-shaped self-compilation profile is
[`logs/compiler-self-profile-2026-08-26-aa269938/REPORT.md`](../../../logs/compiler-self-profile-2026-08-26-aa269938/REPORT.md).
It compiled 292 modules and 323,427 lines. The unsampled no-runtime run reported:

| Measurement | Result |
| --- | ---: |
| Frontend | 93.778 s |
| Backend | 33.168 s |
| Compiler total | 126.946 s |
| Peak RSS | 2.228 GB |
| Allocations | 752.131 million |

External sampling attributed about 45% of samples to Stage 05 types/environment
and Stage 06 typechecking. Important current callers were:

| Caller | Sample share |
| --- | ---: |
| `env.scope_add_symbol` | 12.46% |
| `decl.register_callable_header` | 6.75% |
| `env.env_add_accepted_type_with_containment` | 3.52% |
| `env.scope_lookup` | 2.34% |

The inclusive path `typecheck_register_import_modules_from` and its parents
accounted for about 31% of sampled compiler work. Inclusive percentages overlap,
so they are evidence of a large cluster rather than additive savings.

The compiler typecheck capture in
[`benchmarks/results/compiler_typecheck_capture_2026-08-26.md`](../../../benchmarks/results/compiler_typecheck_capture_2026-08-26.md)
provides the production acceptance workload. It contains 337 dependency
modules. A target-only replay took 79.662 seconds, including 40.719 seconds of
CTFE dependency typechecking. It retained 15,177 CTFE declarations and 499,705
CTFE typed-expression nodes while the target itself contained only 1,468 typed
expression nodes.

These results do not prove that every second is declaration installation. They
do prove that isolated target-body benchmarks are not sufficient acceptance
evidence. This issue must measure both construction work and the production
typecheck replay.

## Verified Current Architecture

The implementation must preserve the useful boundaries already present.

`complete_typecheck_graph` in
`blorp/src/compiler/stage_06_typecheck/decl.brp` creates accepted graph facts from:

- `ImplementationHeaderGraph`;
- `ImportableModuleGraph`; and
- `CompletedGlobalHeaderGraph`.

`AcceptedTypecheckModule` already prepares one body base per module. Body-local
inference does **not** reinstall imports once per function. The repeated work is
one level higher:

1. `prepare_accepted_body_module` is invoked for each selected module.
2. It calls `typecheck_register_import_modules_from`.
3. Every visible dependency has its canonical type declarations installed into
   that module's environment.
4. Every direct dependency has callable and implementation declarations
   installed into that module's environment.
5. Local type, global, trait, callable, and implementation headers are then
   installed into the same environment.
6. Each installation updates persistent lists, dictionaries, overload sets,
   containment facts, and other `Env` fields.

The relevant production functions are currently:

- `prepare_accepted_body_module` in `stage_06_typecheck/decl.brp`;
- `typecheck_register_import_modules_from`;
- `typecheck_register_import_module_types`;
- `typecheck_register_direct_import_module_decls`;
- `typecheck_state_after_header_registration`;
- `register_callable_header` and `register_local_callable_headers`;
- `typecheck_install_imported_*_headers` and
  `typecheck_install_local_*_headers`;
- `scope_add_symbol` and `scope_add_type_declaration_symbols` in
  `stage_05_types/env.brp`.

`TypecheckState` currently stores both `Env` and `ModuleView`. `Env` contains
lexical scopes and graph-level declarations in one representation. That is the
coupling this issue must remove incrementally.

## Scaling Problem To Prove First

Let:

- `M` be the number of selected modules;
- `D` be declarations per module;
- `R_i` be declarations reachable from module `i`;
- `B` be checked bodies; and
- `S` be the number of symbols already present in the persistent scope.

The current imported-registration work is approximately:

```text
sum(i in modules) R_i
```

For a broad or dense dependency graph, `R_i` grows with `M`, so the work can
approach `O(M^2 * D)` even though the graph owns only `O(M * D)` unique
declarations. Persistent scope updates may add another size-dependent factor if
list or dictionary copy-on-write work grows with `S`.

Do not assume this model is true merely because the call graph permits it. The
measurement slice must report the exact installation multiplicity and scaling
exponent before production representation changes begin.

## Required End State

The accepted typecheck graph must own one immutable declaration catalog. A
module must carry only the visibility and naming projection needed to interpret
source names in that module. A body session must carry only that immutable
module base plus fresh inference-local state.

Use opaque phase products. The exact names may follow surrounding conventions,
but the model should be equivalent to:

```blorp
opaque type AcceptedDeclarationCatalog = AcceptedDeclarationCatalogRep

opaque type ModuleDeclarationView = ModuleDeclarationViewRep

private record AcceptedBodyModuleBase {
	graph: AcceptedTypecheckGraph,
	catalog: AcceptedDeclarationCatalog,
	declarations: ModuleDeclarationView,
	lexical_env: Env,
	module_facts: InferModuleFacts
}
```

The catalog is graph-scoped. Do not copy it into AST nodes, typed expressions,
headers, or individual body contexts. Body contexts retain the accepted module
base or a small immutable seed that references it.

### Catalog Responsibilities

The catalog must store declaration facts by nominal identity, not source
spelling heuristics. It must support at least these categories before the old
installation path is deleted:

- types and aliases by `TypeId` or the existing exact type identity;
- constructors by `ConstructorId` and owning type identity;
- callables by `CallableId`;
- globals by `GlobalId`;
- traits by `TraitId`;
- implementations and implementation methods by their existing exact identity;
- containment and resource facts owned by accepted headers;
- canonical declaration source/provenance required for diagnostics.

Use separate category indexes or a tagged exact-key index. Do not use a single
`Dict[String, AnyDeclaration]`, C names, source-name prefixes, or module display
names as identity.

### Module View Responsibilities

`ModuleDeclarationView` must represent decisions already validated by
`BoundModule` and `ModuleView`:

- local names;
- selective imports and aliases;
- qualified module aliases;
- directly importable public values;
- canonical transitive type access required by accepted type references;
- private visibility;
- overload and UFCS candidate ordering;
- trait and implementation visibility.

It must store references to catalog entries, not copies of `Symbol`, `TraitDef`,
`ImplInstance`, or `OverloadEntry` when a stable identity is available.

### Body-Local Environment Responsibilities

After final cutover, `Env` scopes used during body inference should own only
facts that are genuinely lexical or body-local:

- function parameters and local bindings;
- nested scopes and shadowing;
- local type parameters and bounds;
- inference-time refinements;
- body-local overload or trait facts if any are proven necessary;
- the definition-ID frontier only until the identity migration removes it.

Graph declarations must not be re-materialized into each module's lexical
scope.

## Non-Goals

- Do not parallelize body checking in this issue. Produce the immutable boundary
  that makes later parallelism safe.
- Do not implement serialized incremental compilation or an on-disk cache.
- Do not replace the complete inference engine.
- Do not infer identity from names, module paths, or generated C symbols.
- Do not retain both a complete catalog and complete per-module declaration
  environments after a category has migrated.
- Do not optimize CTFE evaluation itself. This issue may reduce setup repeated by
  CTFE body materialization, but demand-driven CTFE remains Phase 7 work.
- Do not change declaration visibility, overload precedence, diagnostic order,
  definition-ID assignment, or typed AST output.

## Slice 0: Baseline Instrumentation And Rejection Gate

This slice contains no production representation change.

### Add Exact Work Counters

Add an opt-in diagnostic result around the exact production path used by
`prepare_accepted_body_module`. Do not duplicate the registration algorithm in
the benchmark. The observation must report primitive counts only:

```text
accepted_modules_prepared
unique_graph_declarations
visible_module_edges
direct_module_edges
imported_type_header_installations
imported_constructor_installations
imported_callable_header_installations
imported_global_header_installations
imported_trait_header_installations
imported_implementation_header_installations
local_header_installations
scope_symbol_insertions
scope_batch_insertions
environment_publications
module_view_projection_entries
body_contexts_created
body_checks_started
```

Also report these derived values:

```text
total_graph_declaration_installations
duplicate_installation_factor =
    total_graph_declaration_installations / unique_graph_declarations
installations_per_module
```

Counters must be deterministic and disabled by default. They must not print from
production code. Prefer a metrics-bearing private execution result used by a
benchmark-facing wrapper over global mutable counters.

### Add A Scaling Fixture

Create:

- `compiler/benchmarks/compiler_frontend_declaration_catalog_profile_fixture.brp`;
- `compiler/benchmarks/compiler_frontend_declaration_catalog_profile.brp`;
- `blorp/test/compiler/stage_06_typecheck/test_frontend_declaration_catalog_profile_benchmark.brp`;
- `benchmarks/compiler_frontend_declaration_catalog_profile`; and
- a manifest ownership entry for the focused suite.

The fixture must independently control:

- module count: `8, 16, 32, 64`, extending to `128` only if runs remain short;
- declarations per module: `4, 16, 64`;
- function/type/trait/impl mix;
- direct import fan-out: `1, 4, 16`;
- graph shape: chain, star, layered fan-out, and dense;
- body count per module: `0, 1, 16`;
- CTFE body selection: disabled for the primary construction measurement and a
  separate enabled control.

Every result must include fixture dimensions, output checksum, errors,
allocations, releases, retained objects, allocator bytes, elapsed microseconds,
and all structural counters above.

### Detect Superlinear Growth

For each one-axis scaling series, calculate:

```text
doubling_ratio = work(2N) / work(N)
growth_exponent = log2(doubling_ratio)
```

Use deterministic work counters as the primary algorithmic evidence. Timing is
secondary. Flag a series when either condition holds for two consecutive
doublings:

- a deterministic counter has a doubling ratio greater than `2.20`; or
- elapsed time or allocations have an estimated exponent greater than `1.20`
  after fixture setup is excluded.

The dense module graph is expected to expose repeated declaration installation.
If total installation work remains near-linear in unique declarations on every
graph shape and the production capture shows a low duplicate-installation
factor, stop this issue and record that the proposed catalog is not justified.

### Capture Production Baselines

Use a fresh current-main compiler and one immutable typecheck request:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-catalog.XXXXXX.json")
./blorp check --no-format --capture-typecheck-request "$capture" \
  blorp/src/compiler/stage_12_cli/main.brp

benchmarks/compiler_typecheck_replay "$capture" \
  --target-only --timeout 180 --memory-limit 4G \
  --allocator-stats --no-inventory --json
```

Run one warmup, then at least three alternating baseline/candidate pairs once a
candidate exists. Preserve the capture SHA-256, worker SHA-256, response
SHA-256, response bytes, elapsed time, named checkpoint times, peak RSS, total
allocations/releases, current objects, and allocator bytes.

Also record three current-main self-compilation samples:

```bash
BLORP_COMPILER_MEMORY_PROFILE=1 \
  compiler/_build/blorp-cli/blorp compile \
  --no-format --no-embed-runtime --time-phases \
  -o /tmp/blorp-catalog-baseline.c \
  blorp/src/compiler/stage_12_cli/main.brp
```

Delete generated C after recording its byte count and checksum.

## Slice 1: Introduce A Checked Catalog Product Without Retaining It

Add a new production module under
`blorp/src/compiler/stage_06_typecheck/headers/`, for example
`declaration_catalog.brp`. Update the ownership manifest in the same commit.

The initial builder must consume only accepted products:

```blorp
pure func accepted_declaration_catalog_build(
	implementation_headers: ImplementationHeaderGraph,
	completed_globals: CompletedGlobalHeaderGraph,
) -> Result[AcceptedDeclarationCatalog, List[DeclarationCatalogError]]
```

Requirements:

1. Build each category index with local accumulators and publish each immutable
   dictionary/list once.
2. Reject duplicate nominal identities, category mismatches, missing owners,
   and inconsistent source provenance.
3. Preserve source declaration order separately from identity lookup order.
4. Provide a validation function used in tests and at the acceptance boundary.
5. Add exact equality/projection tests against the accepted header graphs.
6. Do not store the catalog in `TypecheckGraphFacts` yet. Build and discard it
   only in focused tests and the benchmark so this slice cannot increase
   production peak memory.

This is a valid merge point. It establishes the representation and its
invariants without changing lookup behavior.

## Slice 2: Store The Catalog Once In Accepted Graph Facts

After Slice 1 measurements are acceptable:

1. Build the catalog exactly once in `complete_typecheck_graph` after global
   header completion succeeds or yields a recoverable graph.
2. Store it in `TypecheckGraphFacts`.
3. Make accepted and recoverable graph validation confirm that catalog
   provenance matches the same bound/indexed graph.
4. Pass a reference through `AcceptedTypecheckModuleRep` and
   `AcceptedBodyModuleBase`; do not copy it into every `BodyCheckContext`.
5. Add a production counter proving `catalog_builds == 1` per
   `typecheck_graph` execution.

At this merge point, no lookup behavior changes. Measure peak RSS immediately.
If retaining the catalog raises production peak RSS by more than 3% before any
old category is removed, do not proceed until the representation is compacted.

## Slice 3: Cut Over Types And Constructors

Types are the first migration because transitive canonical type installation is
the broadest repeated import category.

### Mechanical Steps

1. Inventory every production call that obtains a type, alias, record, union,
   constructor, type home, or containment fact through `Env`.
2. Classify each call as lexical lookup, unqualified module lookup, qualified
   lookup, or exact identity lookup.
3. Add catalog query APIs for exact identity and a checked
   `ModuleDeclarationView` projection for source-name resolution.
4. Add state-level query functions that apply lexical shadowing first, then the
   module declaration view, then exact catalog lookup.
5. Migrate one lookup family at a time:
   - aliases and opaque aliases;
   - records;
   - unions;
   - constructors;
   - known/resource type facts;
   - type homes and containment summaries.
6. After each family migrates, remove its imported and local installation from
   `prepare_accepted_body_module`.
7. Assert that no migrated category is retained in both catalog and module
   `Env`.

Do not change the public standalone typechecking path until graph-backed tests
pass. Standalone tooling may continue to build an environment directly or may
construct a one-module catalog through a separate explicit adapter.

### Required Tests

- local type shadows imported type;
- selective and qualified type imports;
- transitive canonical types do not become unqualified names;
- two modules export the same type spelling;
- private type rejection;
- constructor/type name collision;
- generic aliases, recursive aliases, resource types, and containment facts;
- deterministic constructor identity and variant order;
- malformed or mismatched catalog provenance fails closed.

Slice 3 is complete only when type/constructor installation counters fall to
zero for graph-backed module preparation.

## Slice 4: Cut Over Callables And Globals

### Mechanical Steps

1. Add exact callable/global indexes and module-view name projections.
2. Preserve overload source order and the current newest/first lookup behavior
   exactly. Encode order explicitly; do not rely on dictionary iteration.
3. Route direct callable-ID queries through the catalog without materializing
   `FuncSymbol` copies in each module.
4. Route bare, selective, qualified, UFCS, and callback lookup through the
   module view.
5. Keep local variables and parameters in lexical `Env`, with lexical shadowing
   taking precedence over graph values.
6. Migrate completed inferred globals without copying their full typed
   initializer into every importing module.
7. Remove migrated callable/global registration paths and their environment
   insertions.

### Required Tests

- pure/impure overload precedence;
- duplicate overload names across modules;
- UFCS import visibility and trait-method collisions;
- qualified and selective calls;
- callable values and callbacks;
- local variable shadowing a function/global;
- debug-only callable policy;
- resource argument policies and dimension constraints;
- annotated and inferred global imports;
- private and ambiguous values;
- exact diagnostic text and source span for rejected lookups.

Slice 4 is complete only when callable/global installation counters fall to zero
for graph-backed module preparation.

## Slice 5: Cut Over Traits And Implementations

Traits and implementations carry more precedence and privacy behavior, so move
them last.

1. Index traits by nominal identity and module-qualified name.
2. Index implementations by trait identity, normalized receiver type, bounds,
   visibility, and source order required by current conflict resolution.
3. Preserve scoped trait functions as a body/module view fact rather than a
   copied environment list where possible.
4. Migrate trait lookup, supertrait traversal, implementation conflict checks,
   method lookup, and UFCS candidate discovery.
5. Keep exact ambiguity and private-implementation diagnostics.
6. Delete imported/local trait and implementation registration after all
   callers use the catalog.

Required coverage includes supertraits, blanket/generic implementations,
private implementations, duplicate methods, default methods, explicit methods,
ambiguous receiver types, and imported trait methods for locally defined types.

## Slice 6: Delete The Compatibility Installation Path

After all declaration categories are catalog-backed:

1. Delete `typecheck_register_import_modules_from`.
2. Delete `typecheck_register_import_module_types`.
3. Delete `typecheck_register_direct_import_module_decls`.
4. Delete local/imported header installers that have no standalone consumer.
5. Reduce `typecheck_state_after_header_registration` to genuinely local/module
   preparation, or delete it if the catalog view replaces it completely.
6. Remove graph declaration fields from `Env` only when all callers have moved.
7. Remove transitional adapters, mirror consistency checks, and counters that
   no longer protect a boundary.
8. Update `docs/ARCHITECTURE.md` and `docs/COMPILER_PRIORITIES.md` with the final
   ownership boundary.

Use `rg` to prove deleted APIs and old registration terms have no production
consumers. Do not leave an eager fallback that silently reconstructs the old
environment when a catalog lookup misses. Missing accepted identities are
internal invariant errors.

## Correctness Invariants

The following behavior is non-negotiable:

- nominal identity is authoritative;
- lexical shadowing is unchanged;
- local, selective, qualified, direct, transitive, public, and private
  visibility remain distinct;
- overload and UFCS candidate order is deterministic and unchanged;
- constructor and callable definition IDs are unchanged;
- type aliases and recursive types resolve against the same owner;
- resource, containment, purity, debug-only, and dimension facts are preserved;
- diagnostics retain exact message order and source spans;
- accepted/recoverable graph provenance remains fail-closed;
- standalone tooling remains explicit and cannot impersonate an accepted graph;
- body sessions remain fresh and cannot leak errors, metas, substitutions, or
  memo entries between bodies.

## Performance Acceptance Criteria

Structural requirements:

- exactly one declaration catalog build per accepted graph;
- graph declarations stored once by nominal identity;
- no complete imported declaration closure installed into each graph-backed
  module `Env`;
- final imported graph declaration installation count is zero;
- module projection work scales with actual import/name bindings, not every
  declaration in the reachable transitive closure;
- dense-graph deterministic work counters have a growth exponent at or below
  1.20 with respect to unique graph declarations after fixture setup.

Production requirements:

- typecheck replay responses are byte-identical for every A/B run;
- no named checkpoint, peak RSS, allocator bytes, or end-to-end elapsed median
  regresses by more than 3%;
- the typecheck checkpoint median improves materially. Treat less than 5% as a
  weak result requiring explicit justification before retaining the full
  architecture;
- total declaration installation and environment-publication counters drop by
  the amount predicted by the baseline multiplicity;
- whole-compiler self-compilation records frontend, backend, total, peak RSS,
  allocations, generated-C bytes, and output checksum.

The issue is not complete based only on a synthetic dense graph. The compiler
typecheck replay is the acceptance authority.

## Fast Feedback And Test Commands

During each slice:

```bash
./blorp format --check \
  blorp/src/compiler/stage_05_types/env.brp \
  blorp/src/compiler/stage_06_typecheck/state.brp \
  blorp/src/compiler/stage_06_typecheck/decl.brp

./blorp test --timeout 180 \
  blorp/test/compiler/stage_05_types/test_env.brp \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp

./blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp

scripts/compiler-check --validate-manifest
git diff --check
```

Before completion:

```bash
make
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Also run the public import, overload, UFCS, trait, global, resource, and CTFE
fixtures selected by `scripts/compiler-check --changed`.

## Expected File Changes

Primary production files:

- `blorp/src/compiler/stage_05_types/env.brp`;
- `blorp/src/compiler/stage_06_typecheck/state.brp`;
- `blorp/src/compiler/stage_06_typecheck/decl.brp`;
- `blorp/src/compiler/stage_06_typecheck/bridge.brp`;
- `blorp/src/compiler/stage_06_typecheck/headers/declaration_catalog.brp` (new);
- relevant header graph and module-view modules only as required by exact
  projection.

Tests and measurements:

- focused Env, state, declaration, bridge, and frontend graph suites;
- new catalog unit tests;
- new catalog scaling benchmark and fixture;
- `blorp/test/compiler/compiler_test_ownership.json`;
- `benchmarks/README.md`;
- a result file under `benchmarks/results/` with raw artifact references.

Documentation:

- this issue;
- `docs/ARCHITECTURE.md`;
- `docs/COMPILER_PRIORITIES.md` if the migration phase status changes.

## Stop Conditions

Stop and report instead of broadening the change when:

- baseline counters do not show repeated or superlinear graph declaration
  installation;
- exact visibility cannot be represented without re-running name resolution;
- the catalog requires retaining complete duplicate declaration records;
- a slice needs name-based identity heuristics;
- production replay peak RSS rises materially before old data is removed;
- standalone and accepted graph paths become implicitly interchangeable;
- a category migration changes overload/trait precedence or diagnostic order;
- a candidate wins the synthetic fixture but regresses production replay, as
  happened with the rejected direct scope lookup index.

## Completion Report Template

The implementing agent must report:

1. commit(s) and exact diff scope;
2. baseline and candidate source/binary/capture hashes;
3. scaling table with dimensions, deterministic work counters, doubling ratios,
   and estimated growth exponents;
4. installation multiplicity before and after by declaration category;
5. production replay A/B rows and medians;
6. whole-compiler phase time, allocations, peak RSS, and generated-C checksum;
7. focused and broad test pass counts;
8. deleted compatibility APIs and proof of no remaining consumers;
9. known limitations and the next parallel-body-checking boundary enabled by
   the final design.
