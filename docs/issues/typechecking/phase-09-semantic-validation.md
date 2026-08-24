# Phase 9: Make Semantic Body Validation Explicit

## Issue Summary

Introduce an explicit solved-to-validated body boundary, preserve lexical safety
checks at their earliest sound point, and consolidate final-type validation
without redundant or stringly typed whole-tree scans.

This issue implements
[Phase 9 of the typechecking migration](../../COMPILER_PRIORITIES.md#phase-9-semantic-body-validation).

## Context

Blorp typechecking currently performs semantic checks in several places:

- declaration/header validation;
- expression inference while lexical scope is available;
- body-level checks after inference/finalization; and
- a final complete-`TypedProgram` invariant walk.

That distribution is not inherently wrong. Some rules must remain early to
preserve scope/resource/capture facts. The problem is that there is no explicit
product distinguishing a solved body that still needs semantic acceptance from
a body that is safe for CTFE and Core.

Current production behavior, verified on 2026-08-23:

- `typecheck_validate_typed_program` recursively validates every declaration
  after whole-program body materialization.
- `typecheck_validate_typed_expr` and related declaration validators check
  nested typed-type invariants.
- purity is collected by a complete `typed_expr_purity_requirements` traversal
  and checked from declaration body logic.
- `typed_expr_has_non_tail_recursive_call` performs another complete recursive
  traversal for `@tail_recursive` functions.
- match exhaustiveness runs inside expression inference after cases are typed.
- mutable and scoped-resource capture restrictions run while lexical `Env`
  information is available.
- resource escape from `with` blocks and concurrent/detach capture restrictions
  are checked during inference.
- debug-only calls are checked at resolution/inference sites.

The future validation boundary must preserve the good early placements while
making final acceptance explicit.

## Relationship To Other Issues

### Prerequisites

- [Phase 6: Independent Body Checking](phase-06-independent-body-checking.md)
  provides the stable complete body facade and body-local diagnostics.
- [Phase 8: Solver And Finalization](phase-08-solver-finalization.md) provides
  opaque, meta-free `SolvedBody` input.

### Consumers

- [Phase 7: Demand-Driven CTFE](phase-07-demand-driven-ctfe.md) continues to
  consume the complete Phase 6 artifact; after this issue that artifact can be
  constructed only from a validated body.
- [Phase 10: Checked And Codegen-Ready Graphs](phase-10-checked-codegen-graphs.md)
  stores accepted/rejected validation outcomes and prevents rejected bodies
  from reaching Core.

## Problem Statement

Semantic acceptance is currently encoded by control flow and diagnostic lists
rather than an explicit type. Whole-tree rules are implemented independently,
some stable semantic facts are rediscovered from names or tree shapes, and the
final program validator operates only after all declarations are assembled.

This creates:

1. no type-level barrier between solved and accepted bodies;
2. risk that CTFE/Core consumes a body with unresolved validation errors;
3. repeated typed-tree traversals for purity, tail position, invariants, and
   other rules;
4. difficult-to-audit rule placement and diagnostic ordering; and
5. pressure to move all checks late, which would lose lexical facts and worsen
   diagnostics.

## What This Solves

- Accepted and rejected semantic body outcomes are distinct.
- Core and CTFE cannot receive a rejected body.
- Every validation rule has a documented owner and required facts.
- Lexical checks remain early when that is necessary for correctness.
- Post-solve rules operate on final types and exact identities.
- Whole-tree scans are measured and consolidated only when ownership remains
  coherent.
- Diagnostic text, locations, and deterministic order are explicit contracts.

## Expected Performance And Cleanup Impact

This issue currently has a structural performance hypothesis rather than a
current traversal-count baseline. Several rules independently walk complete
typed expression trees, including purity collection, tail-recursion checking,
and final typed-tree validation. If `r` rules each visit a body with `n` typed
nodes, validation work trends toward `r * n` even when rules consume overlapping
facts.

The goal is not to force one universal traversal. It is to:

- retain lexical facts once when they would otherwise be rediscovered;
- use solved call/pattern/resource identities rather than rescanning names;
- delete duplicate walkers when compatible rules can consume one structured
  fact pass; and
- move body validation before complete graph assembly so accepted artifacts can
  be cached and reused.

Expected impact is **moderate for large, deeply nested bodies with several
enabled validation rules** and probably modest for overall compilation until
measurements show validation is a dominant share. Retaining too many facts on
every node could increase memory, so fact counts and retained bytes must be
measured alongside traversal reduction.

This phase enables:

- caching validation outcomes by solved body identity/content;
- parallel validation of independent bodies;
- exact rule-level profiling and diagnostics; and
- graph assembly that checks acceptance status without rescanning body trees.

Expected cleanup includes recursive helper clusters for superseded purity,
tail-position, invariant, and other validation walks; complete-program body
validation; broad-state diagnostic mutation; and string-based identity checks.
Success requires per-rule and total node-visit counts, unchanged exact
diagnostics, no increase in retained validation facts without justification,
and measured time/RSS on a representative nested-body fixture.

## Proposed Architecture

```text
BodyValidationOutcome =
    BodyAccepted(ValidatedBody)
    BodyRejected(RejectedBody, diagnostics)

validate_body(SolvedBody, ValidationContext) -> BodyValidationOutcome
```

`ValidatedBody` is opaque. `CheckedBodyArtifact` from Phase 6 may be constructed
only from `ValidatedBody`. `RejectedBody` may retain source-faithful solved or
recovery information for diagnostics/LSP, but it cannot satisfy CTFE or Core
interfaces.

Use precise fact types where they replace repeated traversal or string
identity, for example:

```text
CallEffectFact
ResolvedAssignmentFact
PatternCoverageFact
TailPositionFact
ResourceDerivationFact
CaptureFact
```

Do not create one miscellaneous validation-flags record.

## Rule Placement Contract

### Keep During Binding Or Inference

These checks require lexical or expected-type context and should not be moved
merely for centralization:

- local binding, redeclaration, and assignment legality;
- expected-type constraint generation;
- pattern binding and pattern/type constraints;
- scoped resource availability and derivation;
- resource use within `with` scopes;
- closure, concurrent, and detach capture restrictions;
- loop/select/with control-context legality; and
- diagnostics whose quality depends on the exact failing inference operation.

They may emit structured facts for later confirmation, but Phase 9 must not
reconstruct their lexical state from the final tree.

### Validate After Solving

These checks depend on stable final types/call identities or currently require
whole-tree traversal and are candidates for the explicit validation boundary:

- declared function and callback purity;
- debug-only restrictions where exact resolved-call facts are sufficient;
- match exhaustiveness after pattern and scrutinee types are resolved;
- `@tail_recursive` tail-position validation using exact callable identity;
- final resource non-escape confirmation;
- stable assignment/module-boundary restrictions; and
- final typed-body/meta-free/invariant auditing.

Moving a rule requires evidence that its diagnostic text/location/order and
recovery behavior remain unchanged or are intentionally improved with updated
public fixtures.

## Implementation Plan

The numbered sections are ordered work, not necessarily one commit each. Form
mergepoints from vertical slices that include a focused test, a production
consumer, and deletion of the replaced path. Do not merge a dormant parallel
model.

### 1. Build A Validation Inventory

Before moving code, record every semantic validation rule with:

- current function and file;
- current execution phase;
- required lexical, inferred, and solved facts;
- whether it performs a typed-tree traversal;
- diagnostic text, span, and relative ordering;
- recovery behavior;
- source-language tests; and
- whether the rule blocks CTFE/Core today.

At minimum inventory the current validators and walkers in
`stage_06_typecheck/decl.brp` and `infer.brp`, including purity, tail recursion,
exhaustiveness, debug-only calls, captures, resource escape, and final typed
program validation.

The inventory should live in tests or issue implementation notes during the
change; do not add a permanently duplicated reference table after ownership is
clear in code.

### 2. Write Failing Product-Boundary Tests

Add `compiler/blorp/tests/test_compiler_body_validation.brp` proving:

- `SolvedBody` cannot be used as `ValidatedBody`;
- one failed rule produces `BodyRejected`;
- rejected bodies cannot construct `CheckedBodyArtifact`;
- multiple diagnostics aggregate in stable documented order; and
- accepted bodies retain exact identities and source metadata unchanged.

Add source fixtures for every moved rule that assert exact diagnostics and
locations before implementation changes.

### 3. Add Structured Facts Selectively

Introduce a fact only when it provides at least one of:

- an exact identity instead of a name/string search;
- reuse by multiple validation rules;
- elimination of a complete typed-tree traversal; or
- preservation of lexical information unavailable after inference.

Examples:

- exact callable identity and purity on call facts;
- exact recursive target and tail-position facts;
- normalized pattern coverage facts after solving;
- resource source/derived identities and escape positions; and
- capture facts retaining binding identity and mutability/resource capability.

Do not append facts indiscriminately to every typed node. Measure retained data
and lifetime impact.

### 4. Introduce `ValidationContext` And Outcome

The context should contain only immutable facts needed across rules:

- accepted header/module queries;
- exact current body identity/signature;
- source policy such as debug-only permission; and
- deterministic diagnostic ordering policy.

Each rule returns structured acceptance/failure rather than mutating broad
`TypecheckState`. Aggregate outcomes in a stable order and construct
`ValidatedBody` only when all mandatory rules accept.

### 5. Move Rule Families Mechanically

Recommended order:

1. final meta-free/typed-body invariant checks;
2. tail recursion, replacing function-name recursion detection with exact
   callable identity;
3. purity, reusing resolved call facts;
4. exhaustiveness after solved pattern types;
5. debug-only stable-call validation where lexical suppression semantics can be
   preserved;
6. final resource non-escape confirmation; and
7. remaining final-type-dependent rules from the inventory.

For each family:

1. add/confirm exact diagnostic tests;
2. move the rule without changing behavior;
3. cut its production caller over;
4. delete its previous traversal/helper cluster; and
5. record node-visit counts before considering consolidation.

Do not move early lexical checks unless the inventory proves all required facts
are retained explicitly.

### 6. Replace Complete-Program Validation

Move body invariants to per-body validation. Keep declaration/header/graph
invariants at their owning construction boundaries. The final graph assembler
may verify completeness and accepted status, but it should not recursively
rediscover body semantics.

Delete `typecheck_validate_typed_program` only after all of its current checks
are owned by accepted constructors or per-body validation.

### 7. Consolidate Traversals Only With Evidence

Instrument node visits by rule. Combine compatible rules when:

- they traverse the same body lifetime;
- they consume the same solved facts;
- their diagnostic ordering can remain explicit; and
- the combined result still has coherent ownership.

Keep separate traversals when merging would create a large flags bag, couple
unrelated safety rules, or obscure error ordering. Document every retained
complete-body traversal and its reason.

### 8. Cut Over The Complete Body Facade

Make `CheckedBodyArtifact` constructible only from `ValidatedBody`. Update CTFE,
ordinary module materialization, and graph assembly through the existing Phase
6 facade. Delete any API that accepts a raw typed/solved body as semantically
accepted.

## Likely Files To Touch

- Phase 6 body context/session/artifact modules
- Phase 8 solved-body modules
- `compiler/blorp/src/stage_06_typecheck/decl.brp`
- `compiler/blorp/src/stage_06_typecheck/infer.brp`
- `compiler/blorp/src/stage_06_typecheck/foreign_validation.brp`
- `compiler/blorp/src/stage_06_typecheck/graph/typed_expr_children.brp`
- `compiler/blorp/src/stage_06_typecheck/state.brp`
- `compiler/blorp/tests/test_compiler_infer.brp`
- `compiler/blorp/tests/test_compiler_typecheck_decl.brp`
- resource, concurrency, match, trait, and tail-recursion focused suites
- public `tests/test_compiler/typecheck/should_fail/` fixtures
- compiler-test ownership manifest entries for new modules and suites

Suggested ownership if it remains acyclic:

```text
stage_06_typecheck/body/validation/outcome.brp
stage_06_typecheck/body/validation/facts.brp
stage_06_typecheck/body/validation/tail_recursion.brp
stage_06_typecheck/body/validation/purity.brp
stage_06_typecheck/body/validation/exhaustiveness.brp
stage_06_typecheck/body/validation/resource.brp
```

Prefer fewer cohesive modules over wrapper-only files.

## How To Test

### Focused Validation Tests

```bash
make
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_body_validation.brp
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_infer.brp
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_typecheck_decl.brp
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_typecheck_resource_decl.brp
./blorp test --timeout 180 compiler/blorp/tests/test_compiler_typecheck_impl_decl.brp
```

Run focused public fixtures for purity, debug-only calls, match exhaustiveness,
tail recursion, captures, resources, concurrency, and assignment restrictions.
Every should-fail fixture must assert exact diagnostics.

### Diagnostic Parity

Capture baseline and candidate diagnostics for bodies that fail multiple rules.
Compare:

- exact text;
- source path, line, and column;
- help text;
- relative order; and
- whether later rules continue after an earlier rejection.

Any intentional change requires updating the public contract and explaining why
the new diagnostic is better.

### Traversal Measurements

Use a large nested body containing calls, lambdas, matches, records,
collections, resources, `with`, concurrency, loops, and control flow. Record:

- typed nodes visited by each rule;
- total whole-body passes;
- facts retained per node/body;
- validation wall time; and
- peak memory.

The target is not one universal traversal. The target is no redundant traversal
without measured justification.

### Ownership And Sanitizers

```bash
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Cover rejected bodies carrying recovery metadata and multiple diagnostics.

### Gates

```bash
scripts/compiler-check --stage typecheck
make quality
git diff --check
```

## Acceptance Criteria

- `ValidatedBody` and `RejectedBody` are explicit, distinct products.
- Only `ValidatedBody` can construct the accepted Phase 6 artifact.
- Core and CTFE cannot consume rejected/merely solved bodies.
- Lexical safety checks remain at their earliest sound phase.
- Post-solve rules use final types and exact identities.
- Diagnostic text, locations, recovery, and deterministic order are preserved or
  intentionally updated in public fixtures.
- Complete-program body validation and replaced tree walkers are deleted.
- Every retained whole-body traversal has measured justification.
- Focused tests, sanitizer/leak checks, measurements, stage checks, and quality
  pass.

## Pitfalls And Non-Goals

- Do not move every check late for conceptual neatness.
- Do not reconstruct lexical scopes, captures, or resource derivation from
  strings after inference.
- Do not use function names to identify recursive calls when callable identity
  exists.
- Do not combine unrelated rules into a generic flags structure.
- Do not silently reorder diagnostics through map/worklist iteration.
- Do not make validation repair unresolved types; Phase 8 owns solving.
- Do not preserve old walkers after the new rule owner is authoritative.

## Handoff Checklist

- [ ] Verify Phase 8 produces opaque meta-free `SolvedBody`.
- [ ] Complete the rule/diagnostic/traversal inventory before moving code.
- [ ] Add accepted/rejected product tests first.
- [ ] Baseline exact multi-error diagnostics and node visits.
- [ ] Move one rule family at a time with its tests.
- [ ] Keep lexical checks early unless all required facts are explicit.
- [ ] Cut over `CheckedBodyArtifact` construction.
- [ ] Delete complete-program body validation and superseded walkers.
- [ ] Store performance evidence for any traversal consolidation.
