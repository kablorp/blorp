# Evaluate CTFE Dependency Globals Once per Graph

**Status:** Implemented and validated 2026-09-09

**Roadmap:** [Stage 06 Latency Reduction Roadmap](STAGE06_LATENCY_REDUCTION_ROADMAP.md)

**Dependencies:** Issue 63 made dependency evaluation independent of the
requesting artifact's constructor namespace

**Primary owners:**

- `blorp/src/compiler/stage_07_ctfe/globals.brp`
- `blorp/src/compiler/stage_07_ctfe/context.brp`
- `blorp/src/compiler/stage_06_typecheck/bridge.brp`
- CTFE global-evaluation and typecheck-bridge tests

## Objective

Evaluate each reachable dependency module's compile-time global environment at
most once for one typecheck graph and evaluation policy, then reuse that result
when producing module artifacts.

The result must remain immutable and graph-owned. It must not become a process
global cache, survive across compiler requests, or capture body-local CTFE
state.

## Important Distinction from Rejected Issue 35

[Issue 35](35-reuse-ctfe-artifact-module-environments.md) proposed retaining a
Stage 06 dependency declaration environment. Its audit correctly rejected that
proposal because typed CTFE dependency preparation was already deduplicated.

This issue targets a later and different operation:

```text
typed CTFE dependency programs       already deduplicated
              |
              v
Stage 07 imported-global evaluation  repeated per output artifact
```

Stage 07 consumes the typed dependency programs and rebuilds their evaluated
global environments for each artifact. Retaining another Stage 06 `Env` would
not remove this work. The fix belongs at the Stage 07 evaluation boundary, with
Stage 06 only scheduling and consuming the graph result.

## Current Production Path

For every artifact with CTFE globals, the bridge calls:

```blorp
ctfe_evaluate_program_globals(
	module_table,
	target_module_id,
	program,
	programs,
	ctfe_import_bindings,
)
```

That function constructs a context and evaluates all imported program global
environments before rewriting the target:

```blorp
Some(base_context):
	context ?= ctfe_eval_imported_program_global_envs(base_context, imported_programs)
	ctfe_rewrite_program_globals_with_import_bindings(context, import_bindings, program)
```

For every imported program, `ctfe_eval_imported_program_global_envs`:

1. builds its selective imported-global environment;
2. installs unavailable placeholders for its declarations;
3. evaluates those declarations in source order; and
4. writes the resulting environment into a fresh context.

The evaluated environments are discarded after the target artifact is
rewritten. The next artifact starts over.

## Production Evidence

One compiler self-check produced:

- 157 calls to `ctfe_evaluate_program_globals`;
- 1,748 imported-module global-environment evaluations;
- 156,261 selective imported-global binding attempts;
- 13,744 evaluated global declarations;
- 149,668 module-binding existence checks;
- 164,505 CTFE binding lookups; and
- 263 distinct retained/reused typed CTFE dependency programs.

The optimized profile attributed 10.34% of the complete check to Stage 07 work
requested by Stage 06. In the unoptimized function profile,
`ctfe_eval_imported_program_global_envs` and its callees occupied a larger
13.49% inclusive envelope.

The immediate-parent baseline was refreshed after Issues 63 and 69. On the
same captured compiler self-check request it performed:

- 1,748 imported-module global-environment evaluations;
- 140,921 imported-binding applications; and
- 263 unique planned CTFE dependency modules.

Issue 69 made definition identity graph-owned while this issue was being
integrated. The implementation therefore retains the exact `DefinitionTable`
authority and consumes `CtfeImportedProgramSet`, rather than retaining only a
module table and raw program list.

## Required Semantic Model

Evaluation state must be explicit. A suitable private model is:

```blorp
private union CtfeModuleGlobalEvaluation:
	CtfeModuleGlobalsUnrequested
	CtfeModuleGlobalsEvaluating
	CtfeModuleGlobalsWaiting(ModuleId)
	CtfeModuleGlobalsEvaluated(CtfeEnv)
	CtfeModuleGlobalsRejected(CtfeEvalError)

record CtfeEvaluatedGlobalGraph {
	module_table: ModuleTable,
	modules: List[CtfeModuleGlobalEvaluation]
}
```

The exact public/private placement may differ, but the states may not be
represented by nullable parallel lists or sentinel module IDs. `Evaluating`
distinguishes a started module from an unrequested module. `Waiting` records
the exact pending module whose global was read, while `Rejected` retains the
exact error that every dependent artifact must observe.

Index `modules` with the existing module-table index only after proving the
`ModuleId` belongs to the same compatible table. Do not cache by canonical path
or source name.

## Evaluation Plan

Construct one exact plan from the artifact requests and their already-selected
`PreparedCtfeDependency` programs:

```text
requested output modules
       |
       v
reachable typed CTFE module programs
       |
       v
deterministic dependency order
       |
       v
one CtfeEvaluatedGlobalGraph
       |
       +--> artifact A installs dependency envs, rewrites target A
       +--> artifact B installs dependency envs, rewrites target B
       +--> artifact C installs dependency envs, rewrites target C
```

The plan must not eagerly evaluate all source modules merely because they are
present in the module table. Only modules reachable from an artifact that needs
CTFE globals are eligible.

For each planned module:

1. mark it `Evaluating`;
2. require every imported module environment it actually references;
3. construct its import environment from already evaluated module results;
4. install unavailable declarations in source order;
5. evaluate its declarations into one exported `CtfeEnv`;
6. if evaluation reads a pending dependency, push that exact module onto an
   explicit owner stack and retry only the waiting owner after it completes;
7. store its exported global environment; and
8. mark it `Evaluated`, or store the exact `Rejected` error.

Stage 06 normally constructs the CTFE dependency list dependency-first by a
visited-module traversal of the exact artifact closures. Source-module cycles
are legal, however, so that order alone is not a proof that every global value
is ready. Stage 07 initially marks planned module globals as pending. If an
initializer actually reads a pending imported global, its module enters an
explicit waiting state and is retried only after that exact dependency reaches
a terminal state. Encountering a module already on the explicit owner stack is
therefore a real global-evaluation cycle, not merely a source import cycle. The
lowest module-table index in that cycle owns the deterministic error; upstream
dependents and disjoint cycles preserve their own errors. Type-only and
function-only import edges do not create false global dependencies. The
ordinary dependency-first case still completes in one pass and does not pay
for repeated graph scans or native recursion.

## Artifact Consumption

After graph evaluation, `evaluated_typecheck_artifact` should no longer
reevaluate every imported program. It should construct the artifact's existing
module-specific CTFE context, install the graph-owned dependency environments,
and rewrite the target program exactly once:

```blorp
context ?= ctfe_context_from_program(
	module_table,
	target_module_id,
	program,
	import_bindings,
	imported_programs,
)
context_with_globals ?= ctfe_context_with_evaluated_dependency_globals(
	context,
	evaluated_graph,
	artifact_dependency_module_ids,
)
ctfe_rewrite_program_globals_with_import_bindings(
	context_with_globals,
	import_bindings,
	program,
)
```

The graph product must not retain one rewritten `TypedProgram` per module.
Selective, declaration-only, and complete dependency programs have different
ownership shapes, and retaining them would extend a large typed tree's lifetime
to save work that was not measured as duplicated. Target rewriting already
happens once per artifact and remains artifact-owned.

Install only the evaluated environments in that artifact's exact dependency
closure. An evaluated but unimported sibling module must not become visible
merely because it is present in the graph product.

Prefer a precise result-returning accessor so a rejected or impossible
in-progress dependency state cannot silently become an empty environment.

## Incremental Implementation Plan

### 1. Add production-shaped counters and a regression fixture

Before changing lifetime, add a focused fixture with:

- one shared dependency containing CTFE globals;
- two or more output modules importing that dependency;
- a transitive dependency;
- selective and qualified imports;
- a runtime-initialized imported global; and
- an independent unused CTFE module.

The baseline fixture must prove that the shared dependency is evaluated more
than once today. Record:

```text
artifact_evaluation_requests
planned_unique_modules
module_global_evaluation_starts
duplicate_module_global_evaluations
import_binding_applications
global_declaration_evaluations
rejected_module_evaluations
semantic_checksum
```

### 2. Introduce the graph result without cutting over production

Implement the private state model and an evaluator that returns one graph.
Exercise it directly in Stage 07 tests. Compare its dependency environments
and errors with the existing evaluator for acyclic fixtures, then separately
prove that artifact-local rewriting produces the same target program.

This checkpoint should not add the new graph to long-lived Stage 06 facts yet.

### 3. Cover failure and ordering semantics

Add exact tests for:

- self-reference;
- reference to a later global in the same module;
- imported runtime-initialized global;
- missing imported global;
- import cycle;
- dependency rejection shared by two importers;
- a rejected dependency beside an independent successful root;
- same source name in different modules;
- an evaluated but unimported sibling whose global name collides with an
  imported global;
- private/non-exported globals; and
- debug-only policy differences.

Assert exact messages and source locations, not just failure status.
Rejection must stop only the affected dependency closure: independent modules
continue, and affected consumers reproduce the first rejection in existing
dependency order with the same wrapper, span, and multiplicity. Exercise both
root/artifact orders so enumeration cannot choose the observed error.

### 4. Schedule one evaluation from the bridge

Build the evaluation plan once at the narrowest point that owns all requested
artifacts and their selected typed dependencies. Pass the resulting environment
graph to artifact construction. Do not store it in general-purpose
`TypecheckState`, copy it into every artifact, or flatten all artifacts into one
shared CTFE context.

### 5. Delete the repeated production route

Once every production artifact consumes the graph result, remove the bridge's
per-artifact call to `ctfe_evaluate_program_globals`. Retain a small public
single-program wrapper only if direct Stage 07 API tests or another real caller
need it; it must delegate to the graph evaluator rather than preserve the old
algorithm.

### 6. Remove temporary comparison and counter machinery

Keep only deterministic test/benchmark observations that defend the
evaluate-once invariant. Remove alternate evaluator switches and production
profiling globals.

## Implementation Result

The bridge now constructs one evaluated-global graph while it owns the complete
prepared typecheck graph. The product retains the graph's exact
`DefinitionTable` authority, one explicit evaluation state per module-table
index, and deterministic work metrics; it does not retain typed dependency
programs or rewritten target programs.

Stage 06 supplies its existing dependency-first `CtfeImportedProgramSet`.
Stage 07 evaluates each unique planned module once, records its terminal
environment or exact rejection, and installs only the subset in each artifact's
own imported-program set before rewriting that target once. Repeated entries in
the plan are detected with one temporary dense, module-indexed program catalog;
that catalog is discarded after graph construction and is not retained by the
evaluated result.

The legacy single-program and imported-environment entry points now delegate to
the graph evaluator. Each opaque `CtfeImportedProgram` is branded with the exact
`DefinitionTable` supplied at its construction, and the containing
`CtfeImportedProgramSet` retains the same authority. Context construction checks
both levels by allocation identity, so wrapping a foreign program in a local
set cannot reinterpret its numeric module or definition IDs. Graph construction
errors remain errors; the bridge no longer converts them into permission to
resume the repeated per-artifact route. The normal and traced bridge paths use
the same graph-owned implementation.

Stage 04 permits and terminates source-module import cycles. Stage 07 therefore
does not reinterpret every source import binding as a global initializer
dependency. Instead it observes only pending module-global values actually read
by CTFE execution, waits on that module's state, and propagates its exact
terminal environment or rejection. The ordinary dependency-first plan remains
single-pass; one grow-only work stack with a logical length handles the unusual
legal back-edge without per-root membership tables, prefix-copy pops, quadratic
whole-plan rescans, or native recursion. The stack is scanned only after an
actual back-edge is observed. Mutable globals are marked runtime-initialized
immediately and can never manufacture a pending cycle.

CTFE lambdas retain only local lexical bindings plus their defining module ID.
They resolve immutable globals through the defining module's context when
called. After every planned module reaches a terminal state, Stage 07 rebuilds
each successful module's shallow imported-binding layer once from completed
module environments, using the same first-entry module catalog that drove
evaluation. This refresh is included in `import_binding_applications`. Pending
placeholders therefore cannot escape inside a lambda, while an unused import
cannot become a false lambda dependency. Lambda body translation and nested
evaluation also use the defining module as the active alias-resolution context.

## Fast Feedback Loop

Run the narrow semantic suites first:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/pipeline/test_ctfe_global_eval.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Run the CTFE typecheck benchmark, whose production-shaped request now includes
one shared dependency global consumed by two selected output artifacts, to
ensure dependency body selection has not become eager and dependency globals
are reused:

```bash
bin/blorp run --release \
  blorp/benchmark/compiler/compiler_ctfe_typecheck_profile.brp -- \
  5 24 32 retained
```

For five iterations, 24 modules, and 32 functions, the benchmark asserts three
artifacts per iteration, 120 planned modules, 120 starts, zero duplicate
evaluations, five global-declaration evaluations, 120 dependency body checks,
an evaluated answer of 24, consumer 1 rewritten to 41, consumer 2 rewritten to
42, and a stable identity-sensitive semantic checksum of 4,860. Associating
each value with its module prevents the benchmark from accepting an empty,
stale, or cross-artifact-swapped evaluated-global graph merely because its work
counters look correct. The existing body-materialization metric remains
independent of the new global-evaluation metrics.

During cutover:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
scripts/test leak
```

Finally run alternating optimized compiler self-checks and capture the exact
evaluation counters from baseline and candidate.

## Measurable Acceptance Criteria

- [x] The focused fixture fails its evaluate-once assertion before the fix and
      passes afterward.
- [x] Every planned dependency module has exactly one transition from
      `Unrequested` to `Evaluating` and at most one terminal result.
- [x] `duplicate_module_global_evaluations` is zero for the production plan;
      a focused duplicate-plan test proves the counter is not tautological.
- [x] `module_global_evaluation_starts` is no greater than
      `planned_unique_modules` and does not grow with output artifact count.
- [x] The unused CTFE module is not evaluated.
- [x] Each artifact installs environments only from its exact dependency
      closure; an evaluated but unimported sibling cannot satisfy or shadow a
      global lookup.
- [x] A legal cyclic source-import graph with an acyclic global-value
      dependency succeeds regardless of the Stage 06 discovery back-edge.
- [x] A true cycle between compile-time global values is rejected
      deterministically, while type-only and function-only import cycles do not
      become false value cycles.
- [x] Compatibility entry points preserve the exact definition-table
      provenance carried by `CtfeImportedProgramSet`.
- [x] On the compiler self-check, the former 1,748 imported-module evaluation
      count falls to at most the number of unique planned evaluated modules.
- [x] Selective imported-global binding applications fall by at least 50% from
      the refreshed immediate-parent baseline.
- [x] Dependency body-check counts remain unchanged; this issue must not undo
      demand-driven CTFE body materialization.
- [x] Target-program rewrite count remains exactly one per artifact that needs
      CTFE rewriting.
- [x] A rejected dependency does not abort an independent root, and every
      affected consumer observes the same first rejection, diagnostic wrapper,
      multiplicity, and dependency-order behavior. Exact source spans are
      preserved where represented; the current CTFE bridge does not attach a
      source span to these errors, and adding one is separate diagnostic work.
- [x] Successful programs, exact errors, diagnostic order, and output hashes
      match the baseline.
- [x] Owned Stage 07 work falls substantially: dependency evaluations fall
      84.95% and imported-binding applications, including the terminal refresh,
      fall 67.46%. A separate
      Stage-07-only hardware counter window is not available; the whole-check
      retired-instruction result exceeds its 3% gate.
- [x] Median optimized self-check wall time does not regress and shows a
      directional improvement consistent with the retired-instruction result.
- [x] Leak-check and focused compiler suites pass with no increase in retained
      objects after graph destruction.

## Measured Performance

The following tables are the initial graph cutover measurement against the
immediate parent. The later cyclic-source correction preserves that cutover;
its fresh deterministic verification follows the tables.

The same captured compiler self-check request was used for the immediate-parent
baseline and candidate inventory:

| Work | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Dependency-module global evaluations | 1,748 | 263 | -84.95% |
| Imported-binding applications | 140,921 | 45,854 | -67.46% |
| Planned unique dependency modules | 263 | 263 | unchanged |
| Rejected module evaluations | 0 | 0 | unchanged |

Five alternating optimized compiler self-check pairs produced:

| Measure | Baseline median | Candidate median | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 162,714,070,700 | 141,090,851,562 | -13.29% |
| CPU cycles | 38,230,325,834 | 33,739,260,624 | -11.75% |
| User CPU time | 10.55 s | 9.91 s | -6.07% |
| Wall time | 10.90 s | 10.13 s | -7.06% |
| Peak RSS | — | — | +0.10% |

The successful response hash remained identical. Peak memory is effectively
neutral, while deterministic owned work and whole-check instruction count both
show the intended reduction.

The original candidate counter covered the 22,927 evaluation-time applications
but omitted the equal-sized terminal refresh. The corrected candidate total in
the table includes both passes. After the cyclic-source correction, a fresh
compiler-sized inventory contained 23,049 evaluation-time applications and
the same 23,049 refresh applications: 46,098 honestly reported applications,
263 planned modules, 263 starts, zero duplicates, 895 global-declaration
attempts, and zero rejected modules. That request includes the correction's
additional source and therefore is not used as a direct replacement for the
captured baseline table above; relative to that baseline it would still be a
67.29% reduction.

The final production-shaped 5 x 24 x 32 benchmark reported 1,275,445
allocations, 1,275,440 releases, five retained objects/320 bytes, 120 planned
modules, 120 starts, zero duplicates, 230 honestly counted import-binding
applications, five global declarations, and checksum 4,860. Compared with the
earlier pending-state prototype on the same corrected fixture, tracked
allocations increased by 1,415 (0.111%) while retained objects and bytes
remained identical. This is the bounded cost of exact per-program provenance,
the grow-only owner stack, and the final shallow import refresh; the graph-wide
elimination remains orders of magnitude larger.

## Pitfalls and Gotchas

### Eager graph evaluation

Evaluating every module-table entry would trade repeated work for unnecessary
work and longer object lifetime. The plan must be driven by exact requested
artifacts and reachable typed CTFE programs.

### Context-dependent constructor or function visibility

Do not build one semantically flattened context from every artifact. Issue 63
makes typed constructor decisions authoritative specifically so target-owned
names cannot contaminate dependencies; this issue must not reintroduce a flat
name-resolution pass. Evaluate and rewrite through each module's exact
dependency/import view. Module-specific import bindings and active-module
identity remain part of evaluation.

### Error ownership

A dependency evaluated once may fail for multiple consumers. Reusing the error
must not duplicate or reorder diagnostics incorrectly, and it must not rewrite
the source location as though the failure originated in the importer.

### Runtime globals and partial environments

An environment containing unavailable runtime globals is a valid evaluated
result. Do not confuse it with evaluator failure or an empty environment.

### Cross-request caching

Source overlays, debug policy, and graph identity make process-global reuse a
different problem. It is explicitly out of scope.

## Non-Goals

- Do not retain or rebuild Stage 06 declaration `Env` values.
- Do not retain rewritten `TypedProgram` values in the evaluated-global graph.
- Do not change CTFE language semantics or allow new initializer forms.
- Do not make dependency body typechecking eager.
- Do not add a global mutable cache.
- Do not index `CtfeEnv` in this issue; Issue 67 measures the residual need.
- Do not change generated Core or C beyond the existing CTFE substitutions.

## Expected Result

The cost of dependency-global evaluation should scale with the number of unique
reachable CTFE modules and declarations, not with that number multiplied by
the number of output artifacts.
