# Reuse CTFE Artifact Dependency Environments

**Status:** Blocked on Issue 34

**Dependencies:** Issue 34

**Parallel work:** Logically parallel with Issue 37 after Issues 34 and 36 are
integrated. Both touch graph facts and preparation observations, so integrate
serially and refresh the second branch before review.

## Objective

Construct and retain the narrower CTFE artifact declaration environment once
per eligible dependency module instead of repeating import and local-header
registration for artifact selection/checking.

## Context

The CTFE artifact path is not another spelling of ordinary module checking. It
deliberately sees dependency-only imports and must not inherit target-module
visibility. Reusing canonical prepared modules would be incorrect even when a
module identity matches.

`graph_facts_ctfe_artifact_typecheck_module` and the surrounding CTFE
preparation path currently construct a narrower environment independently.
This issue gives that environment an explicit reusable lifetime.

## Required Design

Represent the environment kind in the type system rather than with a boolean
or paired options:

```blorp
union PreparedModuleEnvironment:
	CanonicalModuleEnvironment(PreparedCanonicalModuleEnvironment)
	CtfeDependencyEnvironment(PreparedCtfeDependencyEnvironment)
```

The names are illustrative. Each data-carrying variant must have a constructor
that records exact graph, module, visibility-policy, and relevant debug-policy
provenance.

- Build at most one CTFE dependency base per eligible graph/module/policy.
- Retain it in shared graph facts beside, not inside, canonical state.
- Provide a CTFE-specific fresh-session constructor.
- Keep artifact selection, evaluation results, diagnostics, and inference
  state session-local.
- Make it impossible to pass the CTFE product to the canonical body constructor
  without an explicit match.
- Delete the repeated CTFE registration path after cutover.

## Non-Goals

- Do not broaden CTFE visibility.
- Do not combine canonical and CTFE module views to save a type.
- Do not cache evaluation outcomes or body inference.
- Do not redesign artifact selection.
- Do not move graph declarations out of `Env`; catalog issues own that work.

## TDD And Fast Feedback

Add counters and a fixture requiring:

```text
ctfe_dependency_environment_builds <= eligible_dependency_module_count
ctfe_artifact_environment_rebuilds == 0
ctfe_sessions_created == selected_artifacts_checked
```

The fixture must vary artifact count and selection order while holding the graph
constant. Environment builds must remain constant.

Add negative visibility coverage proving that target-only imports, aliases,
globals, traits, and implementations do not leak into a dependency module.
Also prove canonical checking still sees its intended wider view.

## Acceptance Criteria

- CTFE dependency environments are built once per exact provenance key.
- CTFE session count may grow with artifacts; environment build count does not.
- Canonical and CTFE prepared values are distinct data-carrying variants.
- Selection order does not affect results or diagnostics.
- If recoverable graph paths can request CTFE preparation, failed modules remain
  excluded and partial completed-global facts do not become accepted artifacts;
  otherwise document and test that CTFE is accepted-graph-only.
- Repeated registration code and fallback construction are deleted.
- Existing CTFE, global initializer, and ordinary body fixtures pass.
- Repeated Phase 01-06 latency shows no material regression.

## Verification

Run focused CTFE and declaration-preparation fixtures, the frontend benchmark's
CTFE observation rows, `scripts/compiler-check --changed`, and affected Stage
06 tests. Build once before merge and record logical counters plus repeated
Phase 01-06 timings.
