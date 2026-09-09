# Make CTFE Constructor Resolution Typed and Module-Stable

**Status:** Implemented 2026-09-08

**Roadmap:** [Stage 06 Latency Reduction Roadmap](STAGE06_LATENCY_REDUCTION_ROADMAP.md)

**Dependencies:** Issue 62 for serial measurement

**Blocks:** Issue 64 graph-owned dependency-global evaluation

**Primary owners:**

- `blorp/src/compiler/stage_06_typecheck/infer.brp`
- `blorp/src/compiler/stage_07_ctfe/ir.brp`
- `blorp/src/compiler/stage_07_ctfe/pattern.brp`
- `blorp/src/compiler/stage_07_ctfe/context.brp`
- CTFE context, pattern, IR, and global-evaluation tests

## Objective

Make Stage 07 consume the constructor-or-binding decision already made by
Stage 06 instead of reclassifying typed names through a target-dependent,
name-only constructor list.

This is both a correctness prerequisite for evaluate-once dependency globals
and a measured lookup cleanup. After it lands, evaluating a dependency module
must not depend on unrelated constructors declared by the output artifact that
happened to request that dependency.

## Current Typed Information

Stage 06 already distinguishes constructor patterns from binding patterns:

```blorp
union TypedPattern:
	TypedNamePattern(ParsedIdentifier, SemanticType)
	TypedConstructorPattern(ParsedIdentifier, List[TypedPattern], SourceSpan, String, Int)
	TypedQualifiedConstructorPattern(
		ParsedIdentifier,
		ParsedIdentifier,
		List[TypedPattern],
		SourceSpan,
		String,
		Int,
	)
	-- other patterns
```

The final `Int` on the constructor variants is the resolved constructor
definition ID. During inference:

```blorp
ParsedNamePattern(name):
	match find_bare_constructor_for_type(context, env, name.text, scrutinee_type):
		Some(_):
			infer_constructor_pattern(...)
		None:
			TypedNamePattern(name, scrutinee_type)
```

Therefore a `TypedNamePattern` is already known to introduce a binding. It is
not an unresolved “constructor or binding” surface node.

Typed constructor expressions likewise carry a `ResolvedDirectCall` with a
constructor callable ID and parent type when Stage 06 resolves them:

```blorp
ResolvedDirectCall(callable_id, CallableConstructor(parent_type))
```

## Current Stage 07 Problem

`ctfe_pattern_bind` ignores the Stage 06 decision for `TypedNamePattern`:

```blorp
TypedNamePattern(name, _):
	is_nullary_constructor = match ctfe_context_constructor_info(context, name.text):
		Some(info):
			info.arity == 0
		None:
			False

	if is_nullary_constructor:
		-- match as a constructor
	else:
		-- bind the name
```

`CtfeContext` builds one flat constructor list by appending:

1. constructors from the current output target; then
2. constructors from every imported CTFE program.

`ctfe_context_constructor_info` returns the first constructor with a matching
source name. When evaluating an imported dependency, the evaluator changes
`active_module_id` but does not change or scope this constructor list.

Consequently, the same dependency's typed `TypedNamePattern` can be treated as
a binding for one output target and as a nullary constructor for another target
that declares an unrelated same-named constructor. That target contamination
also means Issue 64 cannot safely cache a dependency environment by `ModuleId`
until this issue is resolved.

`ctfe_ir_reference_kind` and qualified-field translation contain similar
name-only fallbacks when typed resolved-call information is absent.

## Required Semantic Rule

Stage 06 is authoritative:

- `TypedNamePattern` always binds a name.
- `TypedConstructorPattern` and `TypedQualifiedConstructorPattern` always match
  the exact resolved constructor definition carried by the typed node.
- A typed expression with `ResolvedDirectCall(_, CallableConstructor(_))` is a
  constructor reference/call.
- A typed expression without constructor resolution must not become a
  constructor merely because an unrelated name appears in `CtfeContext`.

This issue intentionally corrects the contaminated behavior. The old result in
the collision regression is not a compatibility requirement; it contradicts
the typed AST.

## Mandatory Constructor Identity-Domain Gate

`TypedConstructorPattern` and `TypedQualifiedConstructorPattern` currently
carry raw `Int` definition IDs. `CtfeConstructorInfo.callable_id` is also an
`Option[Int]`. Current construction appears to issue both from the same
graph-wide `DefinitionIndex`, but raw integer equality does not encode that
provenance.

Before production code compares those integers, trace and test both creation
paths. The implementation must establish one of these outcomes:

1. a validated helper proves both IDs were issued by the context's compatible
   module table and graph-wide definition index; or
2. replace the raw CTFE comparison boundary with a phase-specific exact value,
   for example:

```blorp
struct CtfeResolvedConstructorId {
	module_id: ModuleId,
	definition_id: Int
}
```

The exact type may instead carry a graph/domain token already present in Stage
06. The requirement is explicit provenance, not this particular record shape.

Add a negative test using two independently built module tables whose raw
definition IDs happen to have the same integer value. They must not compare as
the same constructor. If no such values can cross the API by construction,
make that restriction explicit in the API type and test its construction
boundary.

This gate is required before the exact pattern comparison step. It is not a
follow-up hardening task.

## Desired Stage 07 Shape

Pattern binding should be structural:

```blorp
match pattern:
	TypedNamePattern(name, _):
		Ok(Some([(name.text, value)]))
	TypedConstructorPattern(name, patterns, _, definition_id):
		ctfe_pattern_bind_constructor(
			name.text,
			definition_id,
			patterns,
			value,
		)
	TypedQualifiedConstructorPattern(_, name, patterns, _, definition_id):
		ctfe_pattern_bind_constructor(
			name.text,
			definition_id,
			patterns,
			value,
		)
```

`ctfe_pattern_bind_constructor` should prefer exact callable/definition
identity when both the typed pattern and value carry it. `CtfeConstructorValue`
already retains `constructor_info.callable_id: Option[Int]`.

For compiler-created values where callable identity is deliberately absent,
such as CTFE helper values for built-in `Option`/`Result`, use an explicit
fallback based on the expected parent/type and constructor name. Do not silently
fall back from two present but unequal IDs to a name match.

If the typed pattern does not currently retain the expected parent type needed
for this fallback, obtain it from an exact definition-ID-indexed constructor
catalog or add a phase-specific resolved constructor reference. Do not recover
it from the displayed constructor name.

Typed expression translation should receive and inspect the current
`TypedExprInfo`/resolved call at every constructor-sensitive branch. For
example, the no-call branch of `ctfe_ir_reference_kind` becomes a value
reference rather than consulting a flat name list:

```blorp
match resolved_call:
	Some(call):
		-- existing exact ResolvedDirectCall handling
	None:
		CtfeIrValueReference
```

For qualified field expressions, pass the field expression's resolved
definition/call information into the helper instead of deciding between an
imported global and nullary constructor from `field.text` alone.

## What May Remain in `CtfeContext`

After every typed pattern and expression reader uses exact typed information,
re-run production search for:

```text
ctfe_context_constructor_info
ctfe_context_nullary_constructor_reference
constructors: List[(String, CtfeConstructorInfo)]
ctfe_collect_program_constructors
```

Delete the flat catalog if it has no real consumer. If a recovery-only or
direct Stage 07 API still needs a catalog, replace it with an exact
module-and-definition-indexed product and keep it out of normal typed
translation. Do not preserve the target-first name list as a fallback.

## Incremental Implementation Plan

### 1. Write the target-contamination regression first

Construct:

- dependency `dep`, whose CTFE global uses a `TypedNamePattern` binding named
  `Ready`;
- target `a`, which imports `dep` and declares no `Ready` constructor; and
- target `b`, which imports `dep` and declares an unrelated nullary `Ready`
  constructor.

Evaluate `dep` through both target artifact contexts. Its value and evaluation
status must be identical. The regression should expose the current
target-dependent behavior before the implementation change.

Add the reverse target order to prove the result does not depend on artifact
enumeration.

### 2. Pin typed-pattern authority

Add direct pattern tests proving:

- `TypedNamePattern` binds even when the context contains a same-named nullary
  constructor;
- exact constructor patterns match the same definition ID;
- same-named constructors with different IDs do not match;
- qualified constructors use their resolved ID;
- nested and `or` patterns preserve the same behavior; and
- helper-created built-in constructor values use only the explicit absent-ID
  fallback.

Also trace where both sides of each comparison obtain their identity. The
checkpoint is not complete until tests prove that the pattern identity and the
value identity belong to the same graph-wide definition domain. Include a
negative test built from two independently constructed module tables whose raw
integer IDs collide. If compatibility cannot be proven at construction time,
replace the raw comparison with the phase-specific exact identity described in
the mandatory identity-domain gate above.

### 3. Remove `TypedNamePattern` reclassification

Make the typed name branch unconditional binding. Run pattern and global CTFE
tests before touching expression translation. This checkpoint is independently
reviewable and should remove `ctfe_context_constructor_info` calls from
`pattern.brp`.

### 4. Use exact identity for typed constructor patterns

Thread the existing definition ID through constructor matching. Add whatever
small exact resolved-constructor descriptor is necessary for absent-ID helper
values; keep it phase-specific and explicit.

### 5. Remove expression name fallbacks

Audit `ctfe_ir_reference_kind` and `ctfe_ir_qualified_field_expr`. Use
`ResolvedDirectCall`/typed definition information for constructors and preserve
the typechecker's imported-global decision. Add exact IR translation tests for
same-named global and constructor definitions in different modules.

Before making the `None` branch unconditionally mean a value reference, prove
with direct IR tests that every typed bare and qualified nullary constructor
arrives with `ResolvedDirectCall(_, CallableConstructor(_))`. Cover the
compiler-created `Option`/`Result` values whose callable identity may be absent:
either prove that those materialized values cannot re-enter typed expression
translation or represent them with an explicit synthesized-constructor variant.

### 6. Delete or isolate the flat constructor catalog

Remove every production name-only constructor query that no longer has a typed
semantic purpose. If a narrow recovery API remains, ensure dependency-global
evaluation never consults a target-owned constructor set.

### 7. Prove module stability

Repeat the contamination fixture through the real bridge with both output
artifact orders and with a transitive dependency. Record module evaluation
checksums; the same dependency/module pair must produce the same result in all
contexts.

## Fast Feedback Loop

Start with direct Stage 07 suites:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_07_ctfe/test_ctfe_context.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_07_ctfe/test_ctfe_pattern.brp
```

If the pattern test is currently owned by a broader evaluator suite, add the
regression to that manifest-owned Stage 07 suite rather than creating an
unregistered standalone file.

Then run IR/global/bridge coverage:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/pipeline/test_ctfe_global_eval.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp

scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
```

Use focused observation counters:

```text
typed_name_pattern_binds
typed_name_pattern_constructor_queries
typed_constructor_pattern_exact_matches
typed_constructor_pattern_id_mismatches
typed_constructor_absent_id_fallbacks
typed_expr_constructor_name_fallbacks
flat_constructor_candidates_visited
dependency_context_checksums
```

Finally run five alternating optimized compiler self-check pairs. This issue is
primarily a correctness prerequisite, so semantic counters and output identity
take precedence over a wall-time claim.

## Measurable Acceptance Criteria

- [x] The target-contamination regression fails before the fix and passes
      afterward in both artifact orders.
- [x] A `TypedNamePattern` performs zero constructor queries and always binds.
- [x] Typed constructor patterns compare exact definition/callable identity
      whenever both sides carry it.
- [x] Exact constructor comparison is permitted only after graph/index-domain
      compatibility has been validated; equal raw integers from incompatible
      definition domains do not match.
- [x] Two present but unequal constructor IDs never fall back to name equality.
- [x] Absent-ID fallback is limited to explicitly tested compiler-created
      values and validates parent/type plus name.
- [x] Typed expression translation performs zero name-only constructor
      fallbacks.
- [x] Direct IR tests prove that all typed bare and qualified nullary
      constructors carry resolved constructor calls before the `None` branch is
      treated as an ordinary value reference.
- [x] Materialized built-in `Option`/`Result` constructor values with absent
      callable IDs either cannot re-enter typed expression translation or use
      an explicit, tested synthesized-constructor representation.
- [x] `flat_constructor_candidates_visited` is zero on the compiler self-check;
      delete the flat constructor catalog if no narrow non-production consumer
      remains.
- [x] The same dependency `ModuleId` has the same CTFE evaluation checksum in
      every requesting artifact context.
- [x] Existing non-collision compiler output and diagnostics are identical.
- [x] The collision fixture adopts the typed-AST-authoritative result documented
      by this issue.
- [x] Stage 07 constructor/pattern lookup retired instructions do not increase;
      whole-check wall time may vary within 2% because correctness, not a large
      isolated speedup, is the admission reason.
- [x] Focused CTFE, bridge, typecheck-stage, and leak checks pass.

## Pitfalls and Gotchas

### Treating definition IDs as globally valid without provenance

Confirm the ID domain used by typed constructor patterns and CTFE constructor
values. If identity is module-scoped, carry the issuing `ModuleId` as part of an
exact constructor reference. Do not assume integer equality across unrelated
module tables.

### Losing built-in helper values

Some CTFE helper constructors intentionally carry `None` callable IDs. Their
fallback must remain explicit and narrow; forcing a fabricated ID would be as
incorrect as name-only matching.

### Changing imported-global precedence

Qualified field translation currently checks module globals before its
constructor fallback. Use typed resolution to preserve which declaration Stage
06 selected; do not reverse precedence globally.

### Keeping a hidden compatibility fallback

Once a typed node says “binding,” Stage 07 may not second-guess it. Retaining
the old name lookup after an exact lookup miss would preserve the contamination
bug.

## Non-Goals

- Do not cache dependency global environments in this issue.
- Do not redesign all typed expression identity.
- Do not change source-language constructor syntax or name resolution.
- Do not infer constructor identity from module paths or formatted names.
- Do not index `CtfeEnv`; Issue 67 owns that separately.

## Expected Result

CTFE constructor behavior becomes a projection of the typed AST rather than a
second name-resolution pass. That removes the target-dependent semantic input
which otherwise makes safe `ModuleId`-keyed dependency-global reuse impossible.

## Implementation Result

Implemented on 2026-09-08 against parent `21de2e85` (the bootstrap-pin
successor to roadmap commit `95917f7c`).

Stage 06 remains authoritative and now retains the resolved constructor's
parent type beside its definition ID in typed constructor patterns. Stage 07
uses that parent only for the explicit synthesized-value fallback;
`TypedNamePattern` always binds.

Resolved CTFE constructors now carry an opaque `CtfeResolvedConstructorId`.
The representation pairs the graph-issued definition ID with the issuing
`ModuleTable` allocation, and equality requires both the same table allocation
and the same definition ID. CTFE context admission was tightened accordingly:
an imported typed program must carry the context's actual module table, not an
independently rebuilt table with merely identical rows. Direct tests prove that
equal raw integers from two independently allocated tables do not match.

Compiler-created `Option` and `Result` values carry the explicit
`SynthesizedCtfeConstructor` variant. That narrow fallback verifies constructor
name and parent type. Two resolved identities never fall back to those strings.

IR translation now recognizes bare and qualified nullary constructors only
from `ResolvedDirectCall(_, CallableConstructor(_))`. An unresolved bare name
is a value reference, and an unresolved qualified field remains an imported
global. The former target-first constructor catalog, its construction walks,
and all name-only query helpers were deleted. Production source changed by
217 additions and 233 deletions, a net reduction of 16 lines despite adding the
identity boundary.

The bridge regression uses a transitive CTFE dependency whose typed `Ready`
pattern is a binding. One requested artifact declares an unrelated nullary
`Ready` constructor and another does not. Both artifact orders evaluate
successfully, and the dependency's emitted typed-program JSON is byte-identical
between orders.

Validation completed with:

- 123 focused CTFE/context/global tests;
- 304 inference tests, including bare and qualified nullary resolved-call
  assertions;
- 111 bridge tests, including the transitive artifact-order regression;
- 128 Core-lowering tests;
- `scripts/compiler-check --changed` (15 suites and 2 checks); and
- `scripts/compiler-check --stage typecheck` (34 suites and 2 checks,
  including the leak gate).

No wall-time speedup is claimed for this correctness prerequisite. The hot
name-only constructor scans and temporary catalog construction are absent from
production code, so their retired work is structurally zero; the next roadmap
issue should remeasure after adding graph-owned dependency-global reuse.
