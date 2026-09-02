# Separate Reusable Module Environments From Typecheck Sessions

**Status:** Blocked on Issue 33

**Dependencies:** Issue 33

**Parallel work:** Catalog-builder work in Issue 36 may proceed independently.

## Objective

Replace the broad `TypecheckState` retained by Issue 33 with a narrow immutable
prepared-module product. Make session-local state structurally impossible to
share between independent body or initializer checks.

## Context

Issue 33 deliberately reuses the state shape that already exists so it can
delete a duplicate construction path with little semantic risk. That is a
useful merge point, but a complete `TypecheckState` has a wider responsibility
than a reusable module environment.

The reusable product lives in shared `TypecheckGraphFacts` and should contain
only facts that are invariant for a given accepted graph, module, environment
kind, and compilation policy. Errors,
diagnostics, current containment, inference variables, refinements, and
body-dependent caches belong to a fresh session.

## Required Design

Introduce one explicit prepared canonical module type. A responsibility sketch
is:

```blorp
struct PreparedCanonicalModuleEnvironment {
	graph_identity: AcceptedGraphIdentity,
	module_identity: ModuleIdentity,
	module_view: ModuleDeclarationView,
	declaration_environment: Env,
	known_type_index: KnownTypeIndex
}
```

The exact fields and names must follow current production types. At this point
`declaration_environment` may still contain copied graph declarations; that is
a documented transitional state removed by Issues 37-42.

Provide narrow constructors for fresh sessions rather than public record
reconstruction:

```blorp
pure func typecheck_session_for_body(
	prepared: PreparedCanonicalModuleEnvironment,
	body: AcceptedBody,
) -> TypecheckState
```

Use separate constructors when initializer sessions need completed-global
inputs or different context. Do not add boolean flags to one generic builder.

## Field Audit

Classify every field in the currently retained state as one of:

- immutable graph/module declaration fact;
- module visibility projection;
- compilation policy that participates in the prepared value's identity;
- completed-global input supplied at session creation;
- fresh inference/session state; or
- deletion.

Document non-obvious retained fields near the product. If a cache is retained,
prove its answer depends only on the prepared product's provenance; otherwise
start it empty in the session.

## Non-Goals

- Do not change declaration lookup authority.
- Do not remove graph declarations from `Env` yet.
- Do not add CTFE prepared environments; Issue 35 owns that distinct kind.
- Do not change body checking or inference behavior.
- Do not introduce general-purpose cache invalidation.

## TDD And Fast Feedback

Add a focused test that derives two sessions from the same prepared module.
Mutate or populate all available session-local dimensions in the first and
prove the second starts with:

- no errors or diagnostics;
- root containment/context;
- no body-local refinements or bindings;
- a fresh observation/counter state; and
- no body-dependent memo answers.

Retain Issue 33's construction counters. Increasing body count must create more
sessions but not more prepared modules or graph declaration installations.

## Acceptance Criteria

- Graph facts retain a narrow prepared module product, not `TypecheckState`.
- Both accepted and recoverable graph wrappers consume that same product;
  recovery failures and the successful completed-global subset remain separate
  graph-completion facts rather than session state.
- No initializer or body session copies a complete prior state merely to reset
  fields.
- Product provenance is explicit and checked.
- Fresh-session tests cover every removed session-local field.
- Existing results and exact diagnostics are unchanged.
- Allocation/release counts for increasing body counts improve or remain flat
  relative to Issue 33.
- No transitional wrapper preserves broad-state reuse.

## Verification

Run the focused prepared-module/session tests, the frontend declaration-catalog
benchmark at several body counts, `scripts/compiler-check --changed`, and the
affected Stage 06 manifest/tests. This is an ownership-boundary refactor, so
also run the relevant leak/sanitizer fixture if the changed types carry managed
fields.
