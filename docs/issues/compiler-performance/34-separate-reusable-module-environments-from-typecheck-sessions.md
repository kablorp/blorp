# Separate Reusable Module Environments From Typecheck Sessions

**Status:** Implemented

**Dependencies:** Issue 33 (complete)

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

The implementation uses opaque managed phase types rather than the
illustrative struct. Blorp structs cannot contain the managed `Env` and list
values owned by this product. Opaque conversion preserves the already-built
environment without allocating or rebuilding its indexes.

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

The completed audit is:

| Existing state | Classification | Prepared/session handling |
| --- | --- | --- |
| `context.resource_cleanups` | immutable declaration fact | retained as opaque `PreparedInferContextFacts` |
| context metas and inference bindings | fresh inference state | recreated empty for every session |
| context identity/lowering/desugar/SSA counters | fresh or unused session state | recreated from `CONTEXT_EMPTY` |
| declaration root `Env` scope and name/callable indexes | immutable declaration fact | retained by opaque `PreparedModuleDeclarationEnv` |
| traits, implementations, overloads, UFCS methods, and definition-ID frontier | immutable declaration/identity facts | retained exactly in the prepared environment |
| type parameters and bounds | body-session input | canonical product requires empty values; implementation-body seeds retain their explicit initial values |
| nested scopes and containment restoration snapshots | fresh session state | prepared constructors reject them; every session starts at the root |
| accepted containment facts and validity | immutable graph declaration facts | retained exactly |
| module view, prepared scope, private impls, known-type index, scoped trait functions, type homes | module visibility/provenance facts | retained in `InferModuleFacts` |
| debug-call policy | prepared-product identity | retained and checked during narrow scope admission |
| errors and diagnostics | graph-completion/body outcomes | excluded from the environment; declaration-policy findings are retained separately as `PreparedModuleIssues` |
| type-shape memo | body-dependent cache | always starts at `TYPE_SHAPE_MEMO_EMPTY` |

`TypecheckGraphFacts` now retains `PreparedCanonicalModuleEnvironment`, never a
`TypecheckState`. The public accepted/recoverable module constructors take only
the exact `PreparedModuleScope` and debug policy. Initializer and body session
constructors rebuild a fresh state from the opaque facts. Binding and
declaration-policy findings remain graph-owned data and are applied to the
requested body result without contaminating initializer or sibling sessions.

## Non-Goals

- Do not change declaration lookup authority.
- Do not remove graph declarations from `Env` yet.
- Do not add CTFE prepared environments. Issue 35 audited that proposed kind
  after this change and rejected it because production already prepares each
  deduplicated CTFE dependency at most once.
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

## Results

The controlled comparison used Issue 33 commit `4950f82e` as the baseline and
the same optimized C command for both benchmark executables. Chain and dense
graphs used four dependency modules, four declarations per module, import
fanout four, and body counts `0`, `1`, `8`, and `32`. Each baseline/candidate
configuration ran as three alternating pairs. Raw and summarized local output
is under ignored `logs/issue34-module-environments/`.

All 48 semantic rows reported `workload_valid=True`; semantic checksums,
declaration counts, module counts, session counts, error counts, and retained
objects/bytes were identical. The candidate pays 48 additional allocations and
releases for graph preparation, then saves two allocations and releases per
ordinary body. With four modules, the measured delta is therefore
`48 - (8 * bodies_per_module)`: the boundary breaks even after six bodies per
module and improves body-heavy workloads without body-count-dependent retained
memory. Median elapsed differences ranged from -2.5% to +1.6%, which is timing
noise at this scale; no elapsed-time or compiler-wide speedup is claimed.

| Shape | Bodies/module | Issue 33 allocations | Issue 34 allocations | Median elapsed delta |
| --- | ---: | ---: | ---: | ---: |
| chain | 0 | 67,165 | 67,213 | +1.5% |
| chain | 1 | 68,236 | 68,276 | +0.7% |
| chain | 8 | 75,713 | 75,697 | +1.6% |
| chain | 32 | 101,333 | 101,125 | -0.5% |
| dense | 0 | 67,725 | 67,773 | +1.2% |
| dense | 1 | 69,065 | 69,105 | -2.5% |
| dense | 8 | 78,425 | 78,409 | +1.4% |
| dense | 32 | 110,501 | 110,293 | +1.2% |

Validation completed:

- focused ownership tests: context 18/18, Env 36/36, body isolation 19/19;
- declaration semantics 116/116, bridge semantics 109/109, bound graph 15/15,
  global completion 22/22, and declaration-catalog profile 4/4;
- `scripts/compiler-check --changed`: 4 sources, 9 suites, 0 checks;
- `scripts/compiler-check --stage typecheck`: 43 sources, 31 suites, 1 leak check;
- focused ASan/UBSan run: 73/73 tests.

The ownership boundary is now explicit and body-count scaling remains flat.
This change does not generalize the canonical product to CTFE or claim a
compiler-wide speedup. Issue 35 subsequently audited and rejected a distinct
CTFE prepared environment because it would add eager retained state without
removing repeated production construction.
