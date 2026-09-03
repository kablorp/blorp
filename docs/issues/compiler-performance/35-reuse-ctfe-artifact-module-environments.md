# Reuse CTFE Artifact Dependency Environments

**Status:** Rejected after production-path audit

**Dependencies:** Issue 34 (complete)

## Original Objective

The proposed change would have retained a distinct dependency-only CTFE
declaration environment in shared graph facts, then created fresh CTFE sessions
from that product for artifact selection and checking.

The proposal assumed that one compilation rebuilt the same dependency-only
environment for multiple artifacts. That assumption does not match the current
production pipeline after Issues 33 and 34.

## Production-Path Audit

The eager production path is:

```text
prepare_typecheck_graph
  -> complete_typecheck_graph
  -> prepare_typecheck_graph_from_completed_headers
  -> prepare_ctfe_dependencies_from_bound_graph
  -> prepare_ctfe_dependencies
  -> prepare_ctfe_dependency_program
  -> ctfe_imported_program_from_prepared
  -> body_graph_ctfe_artifact_typecheck_module
  -> graph_facts_ctfe_artifact_typecheck_module
```

The traced path reaches the same per-dependency boundary through
`prepare_ctfe_dependencies_from_bound_graph_with_trace`. Accepted selective
CTFE preparation does not construct the dependency-only environment at all; it
uses canonical prepared-module registries. Recoverable preparation performs
one eager dependency pass. A failed reusable-artifact attempt falls back to
the canonical bound-module path rather than constructing a second
dependency-only environment.

`ctfe_dependencies_for_graph` and `append_ctfe_dependency_tree` deduplicate the
dependency plan by canonical module path. Consequently, one graph preparation
can call the dependency-only constructor at most once for a given
graph/module/visibility/debug-policy key.

The resulting typed `PreparedCtfeDependency` values are already retained in
`PreparedTypecheckContext`. Artifact selection filters and reuses that list; it
does not reconstruct the Stage 06 dependency environment. Initializer checking
uses canonical prepared-module state and does not enter this path.

## Measurement

The audit used commit `1f69c16395b945b5351de95477de8849588d6962`.
The CLI workloads used a compiler built with exact function instrumentation
from that tree; its SHA-256 was
`42d12c88e17c79ce101dc1ce5f567400a34b643ca727ffebc9065d9eec024303`.
The bridge suite used the repository's `bin/blorp test --profile` path, which
creates a separate transient instrumented test worker; that worker was not
retained or hashed. Raw ignored output is under
`logs/issue35-production-audit/`.

Three production-shaped checks were inspected:

| Workload | Result | CTFE planning evidence | Dependency-only environment calls |
| --- | --- | --- | ---: |
| compiler self-check of `blorp/src/main.brp` | succeeded | one graph CTFE dependency plan | 0 |
| minimal imported-module checks | both succeeded | normal CLI graph preparation | 0 |
| profiled Stage 06 typecheck bridge suite | 109/109 passed | 85 dependency preparations, 129 artifact checks, 148 CTFE global evaluations | 0 |

The bridge command was:

```text
bin/blorp test --profile --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

The exact zero applies to
`graph_facts_ctfe_artifact_typecheck_module`,
`body_graph_ctfe_artifact_typecheck_module`, and
`ctfe_imported_program_from_prepared` in these workloads. The static
multiplicity proof remains important because a zero-call workload alone would
not establish the absence of duplication when the path is exercised.

The frontend declaration-catalog observation deliberately invokes the narrow
constructor once per dependency. That benchmark-only observation is semantic
coverage, not evidence of repeated production construction.

## Rejection Decision

Retaining this environment in `TypecheckGraphFacts` would:

- eagerly build it for dependencies handled by selective CTFE preparation;
- build it without the request-specific reusable-artifact eligibility known in
  `PreparedTypecheckContext`;
- retain declaration environments and indexes for the graph lifetime; and
- remove no demonstrated duplicate construction within one compilation.

Stage 07 consumes typed CTFE programs, not the Stage 06 `Env`, so the proposed
product would not remove Stage 07 evaluation or imported-global work either.
Reuse across separate compiler requests would require caching and is outside
this roadmap's within-pipeline reuse scope.

Issue 35 is therefore rejected with no production change. The old acceptance
counters would have passed vacuously or measured diagnostic-only construction;
they must not be added as evidence of an optimization.

## Roadmap Consequences

- Issue 37 must preserve the existing CTFE dependency-only visibility when it
  applies catalog authority, but it must not assume a retained CTFE prepared
  environment exists.
- Issue 38 depends on Issue 37, not Issue 35.
- The next controlled roadmap latency checkpoint moves to Issue 37. Issue 43
  remains the final architecture-wide reprofile.
- Issue 43 may delete a dependency-only constructor only if catalog cutovers
  leave it with no production caller. It must not require a synthetic
  `ctfe_artifact_environment_rebuilds` counter.
- The observed `duplicates_retained_ctfe` case concerns typed artifact output,
  not repeated dependency-environment construction. Any attempt to remove that
  work requires a separate measured issue with its own semantic and lifetime
  audit.

## Reconsideration Gate

Reopen this direction only if exact production instrumentation demonstrates
more than one dependency-only environment construction for the same
graph/module/visibility/debug-policy key within one compilation. The new issue
must identify the duplicate consumer and compare eliminated work against the
additional retained lifetime before changing graph facts.
