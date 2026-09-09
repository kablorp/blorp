# Evaluate CTFE Dependency Globals Once per Graph

**Status:** Ready after Issue 63

**Roadmap:** [Stage 06 Latency Reduction Roadmap](STAGE06_LATENCY_REDUCTION_ROADMAP.md)

**Dependencies:** Issue 63 must first make dependency evaluation independent of
the requesting artifact's constructor namespace

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

The exact ratios will change after Issue 63. Refresh them before implementation.

## Required Semantic Model

Evaluation state must be explicit. A suitable private model is:

```blorp
private union CtfeModuleGlobalEvaluation:
	CtfeModuleGlobalsUnrequested
	CtfeModuleGlobalsEvaluating
	CtfeModuleGlobalsEvaluated(CtfeEnv)
	CtfeModuleGlobalsRejected(CtfeEvalError)

record CtfeEvaluatedGlobalGraph {
	module_table: ModuleTable,
	modules: List[CtfeModuleGlobalEvaluation]
}
```

The exact public/private placement may differ, but the states may not be
represented by nullable parallel lists or sentinel module IDs. `Evaluating` is
needed to distinguish a cycle from an unrequested module. `Rejected` retains
the exact error that every dependent artifact must observe.

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
5. evaluate its declarations into one exported `CtfeEnv` once;
6. store its exported global environment; and
7. mark it `Evaluated`, or store the exact `Rejected` error.

If the existing dependency list is already a verified topological order, reuse
that fact rather than adding a second graph sort. Still retain explicit state
validation: an invalid order or cycle must fail closed instead of reading an
empty environment.

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

## Fast Feedback Loop

Run the narrow semantic suites first:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/pipeline/test_ctfe_global_eval.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Run the existing CTFE typecheck benchmark to ensure dependency body selection
has not become eager:

```bash
bin/blorp run --release \
  blorp/benchmark/compiler/compiler_ctfe_typecheck_profile.brp -- \
  5 24 32 retained
```

The benchmark must retain the same `ctfe_dependency_body_checks`, artifact
count, evaluated answer, and checksum. Add a separate narrow global-evaluation
benchmark if needed; do not redefine the existing body-materialization metric.

During cutover:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
scripts/test leak
```

Finally run alternating optimized compiler self-checks and capture the exact
evaluation counters from baseline and candidate.

## Measurable Acceptance Criteria

- [ ] The focused fixture fails its evaluate-once assertion before the fix and
      passes afterward.
- [ ] Every planned dependency module has exactly one transition from
      `Unrequested` to `Evaluating` and at most one terminal result.
- [ ] `duplicate_module_global_evaluations` is zero.
- [ ] `module_global_evaluation_starts` is no greater than
      `planned_unique_modules` and does not grow with output artifact count.
- [ ] The unused CTFE module is not evaluated.
- [ ] Each artifact installs environments only from its exact dependency
      closure; an evaluated but unimported sibling cannot satisfy or shadow a
      global lookup.
- [ ] On the compiler self-check, the former 1,748 imported-module evaluation
      count falls to at most the number of unique planned evaluated modules.
- [ ] Selective imported-global binding applications fall by at least 50% from
      the refreshed immediate-parent baseline.
- [ ] Dependency body-check counts remain unchanged; this issue must not undo
      demand-driven CTFE body materialization.
- [ ] Target-program rewrite count remains exactly one per artifact that needs
      CTFE rewriting.
- [ ] A rejected dependency does not abort an independent root, and every
      affected consumer observes the same first rejection, diagnostic wrapper,
      source span, multiplicity, and dependency-order behavior in both artifact
      orders.
- [ ] Successful programs, exact errors, diagnostic order, and output hashes
      match the baseline.
- [ ] Stage 07 retired instructions in the measured window improve by at least
      30%, and whole Stage 01-06 self-check retired instructions improve by at
      least 3%; otherwise simplify or reject the retained graph design.
- [ ] Median optimized self-check wall time does not regress and should show a
      directional improvement consistent with the retired-instruction result.
- [ ] Leak-check and focused compiler suites pass with no increase in retained
      objects after graph destruction.

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
