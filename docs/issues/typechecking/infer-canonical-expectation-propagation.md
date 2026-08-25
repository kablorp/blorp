# Propagate Canonical Expected Types Through Inference

## Issue Summary

Stop repeatedly canonicalizing expected types as they are propagated through
expression inference. Canonicalize types once when they enter inference from
source syntax, then pass the resulting semantic type through calls, collection
elements, record fields, match cases, assignments, and function bodies without
repeating qualified-name resolution, alias resolution, and type-parameter
instantiation.

This is a behavior-preserving performance change. It must not change type
compatibility, inference results, source-facing type metadata, diagnostics,
typed AST output, or Core output.

## Why This Work Is Worth Doing

`InferContext` carries an optional expected `SemanticType`. Expected types are
used throughout `infer.brp` to check expressions in context: arguments against
parameters, list elements against an element type, record values against field
types, match cases against a common result type, and function bodies against a
declared return type.

Today both expectation constructors canonicalize every type they receive:

```blorp
pure func infer_with_expected(
	context: InferContext,
	expected_type: SemanticType,
) -> InferContext:
	{
		context |
		expected_type = Some(infer_canonical_expected_type(context, expected_type)),
		expected_slot = None
	}


pure func infer_with_expected_value_slot(
	context: InferContext,
	expected_type: SemanticType,
	expected_slot: ExpectedValueSlotContext,
) -> InferContext:
	{
		context |
		expected_type = Some(infer_canonical_expected_type(context, expected_type)),
		expected_slot = Some(expected_slot)
	}
```

Canonicalization performs three recursive transformations:

```blorp
qualified = resolve_qualified_type_names(module_aliases, expected_type)
resolved = env_resolve_alias(env, qualified)
type_instantiate_type_params(type_params, resolved)
```

That work is required when a parsed annotation first enters semantic inference.
It is redundant when the expected type was already obtained from a canonical
function signature, canonical record field, environment binding, builtin type,
or the parent `InferContext`. Most propagation sites are in the latter category.

A focused profile run on 2026-08-25 used:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 1 1 1 256 retained
```

The function-heavy fixture produced:

| Function | Calls | Cumulative time |
| --- | ---: | ---: |
| `infer_expr` | 1,026 | 224.628 ms |
| `infer_expected_slot` | 769 | 22.355 ms |
| `infer_canonical_expected_type` | 769 | 12.202 ms |
| `finalize_infer_result` | 257 | 12.121 ms |
| `env_resolve_alias` | 1,282 | 9.146 ms |
| `infer_with_expected_value_slot` | 513 | 9.098 ms |

The profile is instrumented and overlapping, so these values are attribution
evidence rather than an end-to-end speed claim. The important structural fact
is the call count: approximately 513 expectation-propagation calls repeat work
that should happen only at the roughly 256 source/body boundaries in this
fixture. Removing those calls should eliminate about two thirds of this
fixture's expected-type canonicalizations and reduce downstream alias and type
tree rebuilding.

## Relationship To Other Work

This is a bounded optimization within the current inference architecture.

- It does not replace [Phase 8: Separate Solving And Type Finalization](phase-08-solver-finalization.md).
  Phase 8 owns metavariable storage, solving, and final typed-tree zonking.
- It does not add a second finalization path or skip the current meta-freedom
  checks.
- It complements the broader goal of making canonical semantic products the
  inputs to later typechecking phases.
- It should land before more invasive `InferContext` or solver representation
  changes because it removes measurable work without changing those models.

## Problem Statement

The current API does not distinguish two different operations:

1. accepting a source-derived type that still requires semantic
   canonicalization; and
2. propagating a semantic type that is already canonical in the current
   typechecking environment.

Both operations call `infer_with_expected_value_slot`, so both pay for
canonicalization. This causes repeated recursive traversal and reconstruction
of the same type trees in high-fanout inference paths.

Examples of obvious duplicate work include:

- an ascription canonicalizes its parsed type explicitly and immediately gives
  that result to a constructor that canonicalizes it again;
- a variable declaration does the same for its annotation;
- a global declaration calls `canonical_annotation_type` and then
  canonicalizes the result again;
- every match arm canonicalizes the same expected result type;
- every argument canonicalizes its already resolved parameter type; and
- every list, vector, tuple, and record element canonicalizes its already
  canonical element or field type.

## Goals

1. Canonicalize each source-derived expected type once.
2. Make propagation of an already canonical expected type cheap and explicit.
3. Preserve source spelling separately wherever it is retained for diagnostics
   or typed AST output.
4. Preserve metavariables and type variables exactly during propagation.
5. Reduce `infer_canonical_expected_type` and `env_resolve_alias` call counts on
   the existing profile fixture.
6. Keep the implementation small enough to review by call-site provenance.

## Non-Goals

- Do not change unification, assignability, overload selection, or trait
  resolution.
- Do not change `zonk_typed_expr` or `finalize_infer_result`.
- Do not add a speculative `typed_expr_contains_meta` fast path.
- Do not redesign `InferContext` as a new union or merge `expected_type` and
  `expected_slot` in this issue.
- Do not introduce a boolean such as `is_canonical`.
- Do not detect canonical types by scanning their shape.
- Do not cache canonicalization globally.
- Do not claim an end-to-end speedup without before/after measurements.

## Required Design

### Keep One Canonicalization Boundary

Keep `infer_canonical_expected_type` as the single implementation of source
type canonicalization:

```blorp
private pure func infer_canonical_expected_type(
	context: InferContext,
	source_type: SemanticType,
) -> SemanticType:
	qualified = resolve_qualified_type_names(
		module_view_module_aliases(context.state.module_view),
		source_type,
	)
	type_instantiate_type_params(
		env_get_type_params(context.state.env),
		env_resolve_alias(context.state.env, qualified),
	)
```

The parameter should be called `source_type`, not `expected_type`, to make the
boundary's purpose clear.

### Add Explicit Canonical Expectation Constructors

Add constructors that store an already canonical semantic type without
resolving it again:

```blorp
pure func infer_with_canonical_expected(
	context: InferContext,
	expected_type: SemanticType,
) -> InferContext:
	{
		context |
		expected_type = Some(expected_type),
		expected_slot = None
	}


pure func infer_with_canonical_expected_value_slot(
	context: InferContext,
	expected_type: SemanticType,
	expected_slot: ExpectedValueSlotContext,
) -> InferContext:
	{
		context |
		expected_type = Some(expected_type),
		expected_slot = Some(expected_slot)
	}
```

These are context constructors, not aliases for the canonicalizer. Their
contract is that `expected_type` has already crossed a checked source-to-
semantic boundary or was produced by a semantic compiler API.

Do not retain both old and new names indefinitely. Migrate production and test
callers, then delete `infer_with_expected` and
`infer_with_expected_value_slot`. The explicit `canonical` name is intentional:
it makes an incorrect raw-source call visible during review.

### Canonicalize Explicitly At Source Boundaries

A parsed type must be converted and canonicalized before it reaches the new
constructor:

```blorp
source_type = type_from_parsed_type_expr(type_expr)
semantic_type = infer_canonical_expected_type(context, source_type)
value_context = infer_with_canonical_expected_value_slot(
	context,
	semantic_type,
	ExpectedArgumentSlot,
)
```

Do not hide this in another general-purpose wrapper. The explicit two-step code
is useful because source metadata often needs both values:

```blorp
source_type: Option[SemanticType]
semantic_type: SemanticType
```

The source form is for diagnostics and typed metadata. The semantic form is for
inference and compatibility checks. Never replace the source form with the
canonical form merely to avoid storing both.

### Why Not Introduce `CanonicalType` In This Issue

A nominal `CanonicalType` could eventually make this contract statically
enforceable. It is not a small local change: canonical semantic types are
currently produced by environments, signatures, field declarations, meta
resolution, substitutions, and many Stage 05 utilities. Wrapping only this one
path would create unchecked conversion escape hatches and a false guarantee.

For this issue, explicit function names plus a complete provenance audit are the
narrow coherent boundary. A true nominal canonical-type model belongs in a
separate type-model migration that updates all producers and consumers.

## TDD Sequence

Write or isolate the tests before changing the constructors. The implementation
must then make those tests pass without updating expected diagnostics.

### 1. Add Focused Expectation-Boundary Tests

Prefer a focused suite named:

```text
compiler/blorp/tests/test_compiler_infer_expected_type.brp
```

Register it in
`compiler/blorp/tests/compiler_test_ownership.json`, and add it to the suites
owned by `stage_06_typecheck/infer.brp`.

The suite must prove:

1. A source alias is resolved once and the context stores the alias target.
2. A module-qualified source type resolves through the current module aliases.
3. A source type parameter becomes the correct `SemanticTypeVar`.
4. A canonical `SemanticMetaType` is preserved exactly by the canonical
   constructor; it is not resolved, replaced, or discarded.
5. A canonical `SemanticTypeVar` is preserved exactly.
6. The no-slot constructor sets `expected_slot = None`.
7. The value-slot constructor stores the supplied slot.
8. `infer_without_expected` clears both fields after either constructor.

The first three tests exercise `infer_canonical_expected_type` through a real
source-boundary helper or expression. The remaining tests directly exercise the
canonical context constructors.

### 2. Add Behavior Regressions Before Migrating Call Sites

Use `test_compiler_infer.brp` for existing expression-level behavior. Add only
missing cases. At minimum cover:

- an ascription using an imported or local alias;
- a variable annotation using a generic type parameter;
- a function call whose parameter type contains a substituted generic;
- a lambda whose explicit return annotation uses an alias;
- a list or record expectation containing a metavariable;
- multiple match arms sharing one expected type;
- a top-level global whose source annotation is retained while its initializer
  receives the canonical type; and
- a concurrent binding whose `Result` annotation uses an alias.

For tests that inspect typed metadata, assert both:

- the source type retains the original annotation form; and
- the semantic/binding/expected type is canonical.

Do not weaken exact diagnostic assertions. If a diagnostic changes, treat that
as a regression unless the issue is explicitly expanded and reviewed.

### 3. Establish A Profiling Baseline

Before implementation, run the existing focused profiler and save stdout and
stderr outside the repository:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 1 1 1 256 retained \
  >/tmp/infer-expected-baseline.out \
  2>/tmp/infer-expected-baseline.profile

rg 'infer_canonical_expected_type|infer_with_expected_value_slot|env_resolve_alias|type_instantiate_type_params' \
  /tmp/infer-expected-baseline.profile
```

Record the workload checksum, declaration counts, error count, relevant call
counts, elapsed time, and peak memory if exposed. Do not compare a profiled run
to an unprofiled run.

## Mechanical Implementation Plan

### Step 1: Introduce The Canonical Constructors

In `compiler/blorp/src/stage_06_typecheck/infer.brp`:

1. Rename the canonicalizer parameter to `source_type`.
2. Add `infer_with_canonical_expected`.
3. Add `infer_with_canonical_expected_value_slot`.
4. Confirm both constructors only update `expected_type` and `expected_slot` and
   preserve every other `InferContext` field.
5. Add direct tests for their exact stored values.

At this point, leave old constructors temporarily so the tree compiles. Remove
them after all callers move in Step 5.

### Step 2: Migrate Obvious Already-Canonical Callers

Start with sites whose local code already proves canonicalization:

| Location | Why the value is canonical |
| --- | --- |
| `infer_ascription_expr` | It just called `infer_canonical_expected_type`. |
| `infer_var_decl_expr` | `semantic_declared_type` was just canonicalized. |
| `typecheck_materialize_global_var_body_with_identity` in `decl.brp` | `DeclaredGlobalType` was built with `canonical_annotation_type`. |
| `body_check_context_with_expected_type` in `decl.brp` | The function body signature stores its semantic return type. |
| integer index/range/slice sites | `TYPE_INT` is a canonical builtin. |
| while condition | `TYPE_BOOL` is a canonical builtin. |

Replace only the constructor call. Do not add another canonicalizer.

Run the focused expectation suite and `test_compiler_infer.brp` after this
group.

### Step 3: Migrate Canonical Semantic Products

Migrate the following groups one at a time. For every call, inspect the producer
of the expected type before changing it.

#### Calls And Lambdas

- `infer_call_args_with_subst`: parameter types come from the resolved callable
  signature after type substitution.
- `infer_lambda_expr`: `declared_return_type` is either explicitly canonicalized
  or taken from the canonical contextual function type.

Required regressions: generic arguments, generic lambda expectations, aliases,
and an unresolved meta in a contextual function type.

#### Tuples, Lists, And Vectors

- `infer_tuple_items_with_expected`: tuple item types are projected from the
  canonical expected tuple.
- `infer_list_tail_items`: element types come from the canonical expected list
  or a previously inferred semantic value type.
- `infer_vector_tail_items`: same rule for vectors.

Required regressions: nested aliases, empty/tail collection behavior, and
meta-containing element types.

#### Records And Record Updates

- `infer_record_fields`: field expectations come from registered semantic field
  declarations.
- `infer_record_update_fields`: field expectations come from the resolved base
  record declaration.

Required regressions: generic record fields, imported record aliases, omitted
fields, and record updates.

#### Subscripts, Assignment, And Ranges

- `infer_subscript_indices`, `infer_assert_shape_call`, and
  `infer_checked_slice_call`: integer expectations use `TYPE_INT`.
- `infer_subscript_assignment_value`: the element type is projected from the
  canonical receiver type.
- `infer_range_expr`: integer bounds use `TYPE_INT`.
- `infer_mutable_assign_expr`: the current variable type comes from the
  environment and meta resolution.

Required regressions: generic collection elements, mutable bindings with metas,
and existing index/range diagnostics.

#### Match And Control Flow

- `match_body_context` and `infer_match_cases`: the expected result type is
  inherited from the canonical parent context. This is a high-fanout case; do
  not canonicalize once per arm.
- `infer_while_expr`: the condition uses `TYPE_BOOL`.

Required regressions: several match arms, nested matches, aliases in the parent
expectation, and an expectation containing a meta.

#### Opaque Conversion And Error Mapping

- `infer_opaque_conversion_expr`: `resolve_opaque_conversion_type` already
  returns canonical source/opaque/target semantic types.
- `infer_with_error_mapper`: the mapper error expectation is projected from the
  resolved `Result` carrier.

Required regressions: both opaque conversion directions, generic opaque types,
and aliased `Result` error types.

### Step 4: Handle Concurrent Binding Annotations Carefully

This is the only call site in the current inventory that should not be changed
by simple constructor replacement.

Current code converts the parsed annotation to a semantic shape, then helper
functions partially resolve aliases before extracting the `Result` success
type. The expectation constructor currently performs the remaining
canonicalization accidentally.

Refactor this flow to keep two explicit values:

```blorp
source_annotation_type: Option[SemanticType]
canonical_annotation_type: Option[SemanticType]
```

Compute the canonical value once:

```blorp
canonical_annotation_type = source_annotation_type.map(
	func(source_type): infer_canonical_expected_type(context, source_type),
)
```

Then:

- use `canonical_annotation_type` for `Result` carrier extraction;
- use it for annotation compatibility checks;
- pass its success type through
  `infer_with_canonical_expected_value_slot`; and
- continue storing `source_annotation_type` in `TypedConcurrentBinding` if that
  is the current typed-AST contract.

Remove redundant `env_resolve_alias` calls from
`concurrent_annotation_task_value_type` and
`concurrent_binding_annotation_context` only after their parameters are
documented and tested as canonical.

Required regressions:

- `Result` through a local alias;
- `Result` through a module-qualified alias;
- generic success/error types;
- a mismatched annotation with the exact existing diagnostic; and
- typed metadata retaining the source annotation.

### Step 5: Delete The Ambiguous Constructors

After production callers have migrated:

1. Update direct tests that used `infer_with_expected` as a convenient raw
   source boundary. Tests should explicitly canonicalize source types or call
   the canonical constructor with a genuinely canonical type.
2. Delete `infer_with_expected`.
3. Delete `infer_with_expected_value_slot`.
4. Confirm there are no references:

```bash
rg -n 'infer_with_expected\(|infer_with_expected_value_slot\(' \
  compiler/blorp/src compiler/blorp/tests
```

The command must return no matches. Do not leave compatibility aliases.

### Step 6: Audit Every Remaining Canonicalization

Run:

```bash
rg -n 'infer_canonical_expected_type\(' \
  compiler/blorp/src/stage_06_typecheck/infer.brp \
  compiler/blorp/src/stage_06_typecheck/decl.brp
```

Every remaining call must be explainable as one of:

- a parsed type annotation entering semantic inference;
- an imported/module-qualified source type entering the current module;
- a type parameter from source syntax entering the current type-parameter
  environment; or
- a specifically documented compatibility boundary that cannot yet provide a
  canonical semantic type.

If a call receives a value from `InferContext`, `Env`, a semantic declaration,
a resolved signature, field metadata, or a builtin `TYPE_*` constant, it is
almost certainly still redundant. Verify the producer rather than relying on
this rule as a heuristic.

## Current Production Call-Site Inventory

The following inventory was cross-checked on 2026-08-25. Line numbers are
intentionally omitted because the file is changing; use the function names.

| Function containing propagation | Expected-type origin | Action |
| --- | --- | --- |
| `infer_opaque_conversion_expr` | canonical opaque-conversion result | canonical constructor |
| `infer_ascription_expr` | explicitly canonicalized annotation | canonical constructor |
| `infer_call_args_with_subst` | resolved signature plus substitution | canonical constructor after regression |
| `infer_lambda_expr` | canonical annotation/contextual function | canonical constructor |
| `infer_tuple_items_with_expected` | canonical parent expectation | canonical constructor |
| `infer_list_tail_items` | canonical/inferred element type | canonical constructor |
| `infer_vector_tail_items` | canonical/inferred element type | canonical constructor |
| `infer_record_fields` | semantic field declaration | canonical constructor |
| `infer_record_update_fields` | semantic field declaration | canonical constructor |
| `infer_subscript_indices` | `TYPE_INT` | canonical constructor |
| `infer_assert_shape_call` | `TYPE_INT` | canonical constructor |
| `infer_checked_slice_call` | `TYPE_INT` | canonical constructor |
| `infer_subscript_assignment_value` | canonical receiver element type | canonical constructor |
| `infer_range_expr` | `TYPE_INT` | canonical constructor |
| `match_body_context` | canonical parent expectation | canonical constructor |
| `infer_match_cases` | canonical parent expectation | canonical constructor |
| `infer_while_expr` | `TYPE_BOOL` | canonical constructor |
| `infer_mutable_assign_expr` | environment/meta-resolved variable type | canonical constructor |
| `infer_var_decl_expr` | explicitly canonicalized annotation | canonical constructor |
| `infer_concurrent_params` | builtin parameter types | canonical constructor |
| `infer_concurrent_binding_value_context` | partially resolved source annotation | refactor per Step 4 |
| `infer_with_error_mapper` | resolved `Result` error type | canonical constructor |
| `body_check_context_with_expected_type` (`decl.brp`) | semantic function signature | canonical constructor |
| `typecheck_materialize_global_var_body_with_identity` (`decl.brp`) | `canonical_annotation_type` result | canonical constructor |

Also inspect any new calls introduced after this inventory. Do not mechanically
replace a new caller until its expected-type provenance is known.

## Fast Feedback Loop

Use the smallest applicable checks after each migration group:

```bash
./blorp format --check \
  compiler/blorp/src/stage_06_typecheck/infer.brp \
  compiler/blorp/src/stage_06_typecheck/decl.brp \
  compiler/blorp/tests/test_compiler_infer_expected_type.brp \
  compiler/blorp/tests/test_compiler_infer.brp

./blorp test --timeout 180 \
  compiler/blorp/tests/test_compiler_infer_expected_type.brp

./blorp test --timeout 180 \
  compiler/blorp/tests/test_compiler_infer.brp

scripts/compiler-check --stage typecheck
```

If the new focused suite is not added, use `test_compiler_infer.brp` as the
minimum behavioral loop, but prefer the smaller suite because it gives this
boundary a clear ownership contract.

Re-run the profile after each migration group:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 1 1 1 256 retained \
  >/tmp/infer-expected-candidate.out \
  2>/tmp/infer-expected-candidate.profile

rg 'infer_canonical_expected_type|infer_with_canonical_expected|env_resolve_alias|type_instantiate_type_params' \
  /tmp/infer-expected-candidate.profile
```

The profile must retain the same workload checksum (`518` in the recorded
baseline), declaration counts, and zero-error result. If those change, stop and
diagnose behavior before interpreting performance.

## Performance Verification

The primary mechanical success criterion is less work, not one noisy timing:

- `infer_canonical_expected_type` calls should fall from 769 toward roughly 256
  on the recorded fixture;
- approximately 513 propagation-time canonicalizations should disappear;
- `env_resolve_alias` and `type_instantiate_type_params` calls should fall
  materially; and
- the new canonical constructors should show only context-construction cost.

Exact counts may differ after unrelated compiler changes. Explain the delta
rather than forcing these historical numbers into a brittle test.

For an end-to-end claim:

1. rebuild the candidate compiler;
2. run alternating baseline/candidate samples on the same machine;
3. include at least the retained profile fixture and compilation of the compiler
   frontend or complete compiler;
4. compare median wall time and peak memory; and
5. retain raw commands and results under `benchmarks/results/` if the change is
   described as a performance improvement.

Do not claim improvement from cumulative profiler time alone because nested
instrumented calls overlap.

## Correctness And Ownership Risks

### Raw Aliases Accidentally Enter The Canonical Path

This would skip alias or module-qualified-name resolution and could produce
false type errors. Prevent it by auditing the producer of every migrated value
and retaining regressions for aliases and type parameters.

### Source Metadata Is Replaced With Canonical Metadata

Diagnostics and typed AST output may intentionally preserve the user's source
spelling. Keep `source_type` and `semantic_type` separate where both exist.

### Metavariables Are Resolved Too Early

Canonical propagation must preserve `SemanticMetaType` values exactly. It must
not call `resolve_type_metas`, zonk, or finalization merely to establish this
boundary.

### A Context Uses A Type Canonicalized Under Another Environment

Canonical types containing module aliases or type parameters are environment-
sensitive at their source boundary. Only pass them into contexts derived from
the same semantic function/body session. Do not cache or share canonicalized
source annotations across modules or body sessions in this issue.

### A Mechanical Search-Replacement Hides The Concurrent Annotation Case

The concurrent binding flow currently relies on the old constructor to finish
canonicalization. Follow Step 4; a direct replacement there is incorrect.

### Context Fields Are Lost During Reconstruction

Use record update syntax or copy every field exactly. Tests must cover
`in_loop`, `in_debug`, and `suppress_debug_only_reference` preservation if the
constructor implementation changes beyond the shown record update.

## Final Validation

After all call sites and tests are migrated, run:

```bash
make
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
make quality
```

Because this change affects compiler-owned values and may change allocation
behavior, also run the focused sanitizer gate if any ownership failure, leak,
or generated-C warning appears:

```bash
scripts/test compiler-blorp-sanitize
```

Read the generated profile output and confirm there is no new recursive hot
path or allocation-heavy replacement structure.

## Acceptance Criteria

- [ ] Source-derived expected types are canonicalized exactly at explicit
      source-to-semantic boundaries.
- [ ] Already canonical semantic expected types are stored without another
      qualified-name, alias, or type-parameter traversal.
- [ ] The old ambiguous expectation constructors are deleted.
- [ ] Every production propagation call is classified by type provenance.
- [ ] Concurrent binding annotations preserve source metadata while using one
      canonical semantic value for extraction, checking, and propagation.
- [ ] Aliases, module-qualified types, generics, metas, match arms, function
      calls, records, collections, globals, lambdas, and concurrency have
      focused regression coverage.
- [ ] Exact existing diagnostics remain unchanged.
- [ ] Typed AST and Core behavior remain unchanged.
- [ ] The focused profile preserves checksum and workload counts.
- [ ] Canonicalization and alias-resolution call counts decrease materially.
- [ ] Formatter, focused typechecking tests, changed ownership checks, compiler
      tests, build, and quality gates pass.

## Stop Conditions

Stop and request review rather than expanding the issue if any of the following
is required:

- changing `SemanticType` representation;
- introducing a nominal canonical-type wrapper across Stage 05;
- changing solver/meta resolution or finalization;
- changing source metadata or diagnostic output;
- changing assignability or unification behavior;
- caching canonical types across modules or bodies;
- redesigning `InferContext`; or
- adding runtime inspection to decide whether a type is canonical.

Those may be useful separate projects, but they are not necessary to remove the
duplicate work identified here.
