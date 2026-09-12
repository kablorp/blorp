# Trait Operator Authorization Roadmap

**Status:** The operator authorization architecture is implemented and passes
the pinned-bootstrap build, self-hosted compiler, and focused operator gates.
All arithmetic, negation, equality, and ordering operators use trait
authorization. Native scalar operations, structural equality, and tensor
lifting have exact Core targets; source implementations remain ordinary calls.
Operator syntax, explicit trait calls, and specialized generic calls share the
same dispatch path. The broad Core native-operator fast path, primitive
self-call exception, and missing-implementation exceptions have been deleted.
Generic tensor elements remain rejected because open numeric-family traits do
not prove native storage.

Equality and ordering retain their exact legacy operator bodies for one
bootstrap generation. A narrow bridge recognizes only an exact operator body
with the canonical scalar module, trait method, type, and signature as a native
target. After a release containing this compiler is pinned, replace those
bodies with their existing per-type builtin markers and delete
`has_legacy_native_binary_body` and `binary_operators_equal`.

The historical implementation remains on `codex/trait-system`, but it was not
merged into current `main`. Its design and tests are useful references; its
completion claims and paths are stale.

## Objective

Replace Blorp's split operator model with one coherent rule:

> Every overloadable operator is authorized by a trait implementation.

Builtin types use exact compiler-provided native implementations. Source types
use ordinary source-defined implementation functions. Operator syntax and
explicit trait-method calls select the same implementation, while builtin
operations remain direct Core operators and direct generated C.

The final production change must remove more special-case policy than it adds.
Implement and verify one trait at a time.

## Current State

The branch has migrated all five arithmetic traits plus `Negatable`,
`Equatable`, and `Orderable`, including compiler-provided structural equality
categories and native tensor lifting. The accepted semantic catalog assigns
exact `TraitId`, `TraitMethodId`, `ImplId`, and `CallableId` identities and
decides whether a visible implementation authorizes an operation. Core maps an
already-authorized implementation to either an exact native operation or an
ordinary source function target; it does not contain a broad primitive-type
authorization predicate.

The historical branch had working slices for arithmetic, negation, equality,
and ordering, plus focused tests. Do not cherry-pick those commits wholesale:
the repository layout, test ownership, compiler composition, and trait identity
model have changed substantially since their merge base.

## Design Constraints

1. Trait satisfaction is decided in typechecking from ordinary standard-library
   or user implementations, using exact accepted semantic identities. Core must
   not re-decide language-level authorization from broad primitive predicates.
2. Native implementations are exact capabilities. `String`, `Bool`, integers,
   floats, `Fixed`, tensors, ranges, enums, and structural values do not share
   one blanket "builtin" capability.
3. Operator syntax and explicit calls such as `add(a, b)` resolve through the
   same implementation selection.
4. Generic operators remain deferred until their dispatch type is concrete.
5. Native targets lower to existing `BinaryExpr` or `UnaryExpr` nodes. Do not
   rely on the C optimizer to erase wrapper calls.
6. Source implementations remain ordinary function targets and preserve normal
   recursion semantics inside their own bodies.
7. Operand compatibility, mixed-width rejection, tensor dimensions, result
   shape, wrapping overflow, and zero-divisor behavior remain explicit rules.
   Trait authorization does not replace these type and runtime semantics.
8. Standard-library implementation declarations are the capability inventory.
   The compiler separately owns only a narrow mapping from trusted builtin
   marker names to native Core operations. Inference and Core must not grow
   duplicate type-name capability lists.
9. The final diff must simplify the compiler. Stop and reassess a slice if its
   permanent machinery is larger or less precise than the special cases it is
   intended to remove.

Tensor-scalar arithmetic is not expressible as an `Addable`-style
`(Self, Self) -> Self` implementation. Treat it as an explicit compiler-provided
lifting of the scalar element implementation over a tensor shape, not as a
homogeneous tensor implementation and not as a broad tensor fast path. The
builtin lifting is available only when the element type has the corresponding
accepted native scalar implementation. Tensor-tensor operations remain
homogeneous and must have matching element types and dimensions. This is a
deliberately named builtin rule; source types cannot overload the heterogeneous
lifting.

## Target Representation

Core trait resolution needs an explicit execution target:

```text
FunctionTraitTarget(mangled Core function name)
NativeBinaryTraitTarget(CoreBinaryOp)
NativeUnaryTraitTarget(CoreUnaryOp)
```

Conceptually:

```text
(Int16, Addable, add)       -> NativeBinaryTraitTarget(AddOp)
(Int16, Equatable, equals)  -> NativeBinaryTraitTarget(EqualOp)
(Int16, Negatable, negate)  -> NativeUnaryTraitTarget(NegateOp)
(Vec2, Addable, add)        -> FunctionTraitTarget(Vec2 add Core function)
```

The standard-library declaration for a native implementation remains an
ordinary implementation with a per-type builtin body:

```blorp
implements Addable for Int16:
	pure func add(a: Int16, b: Int16) -> Int16:
		builtin("int16.add")
```

The accepted semantic catalog sees this as an ordinary exact implementation and
uses it to authorize both operator syntax and explicit calls. Lowering validates
the builtin marker against the owning module and method name, then records the
existing unresolved-builtin state. A narrow Core scalar-operator synthesizer
maps the exact module, method, type, and signature to `AddOp`, and Core trait
resolution records a `NativeBinaryTraitTarget(AddOp)` instead of a wrapper
function target.

This keeps phase ownership clear: semantic identities decide authorization;
Core builtin metadata decides execution. The typechecker does not depend on
`CoreBinaryOp`, and Core does not infer trait availability from a type name.

## Capability Matrix

| Trait | Native builtin coverage | Special behavior to preserve |
|---|---|---|
| `Addable` | signed and unsigned integer families; float family | `String`, `Fixed`, tensors; source collections remain function targets |
| `Subtractable` | signed and unsigned integer families; float family | `Fixed`, tensors |
| `Multipliable` | signed and unsigned integer families; float family | `Fixed`, tensors |
| `Divisible` | signed and unsigned integer families; float family | integer division by zero returns zero; floats retain IEEE 754 behavior; `Fixed`, tensors |
| `Modulable` | signed and unsigned integer families; float family | integer zero-divisor and floating remainder semantics |
| `Negatable` | signed integer and float families | `Fixed`, tensors; unsigned integers remain rejected |
| `Equatable` | exact native scalar set | enums, unions, tuples, tensors, ranges, and collections retain structural behavior |
| `Orderable` | exact ordered scalar set | preserve intended `String`, `Char`, and `Fixed` behavior; keep `Bool` and tensors unsupported unless separately specified |

`Int64` is an alias of `Int`, not an additional native capability.

## Ordered Implementation

### 0. Re-establish the Baseline

1. Inventory current operator authorization in inference, accepted semantic
   trait resolution, Core trait dispatch, Core trait resolution, synthesis, and
   the standard library.
2. Replace the current Core assertion that primitive operators keep the old
   fast path with failing assertions for explicit native targets.
3. Port only the still-relevant focused cases from the historical branch into
   current test owners. Register every TestSuite in
   `blorp/test/compiler/compiler_test_ownership.json`; mark standalone compiler
   fixtures with the appropriate `RUN-BLORP-CHECK` directive. A fixture that no
   gate executes is not coverage.
4. Add a retained fast feedback command or script that runs the focused
   typecheck, Core, runtime, and generated-C cases without rebuilding unrelated
   gates.
5. Add codegen-audit fixtures with `EXPECT-C` and `EXPECT-NOT-CALLABLE`
   assertions for direct native lowering and source implementation dispatch.
6. Record current source-line counts for the authorization paths and circular
   standard-library implementations. This gives the simplification criterion a
   concrete baseline.

### 1. Introduce Core Implementation Targets

1. Change `CoreTraitImplTarget` into a small target-kind union containing
   function, native-binary, and native-unary targets.
2. Keep every existing source implementation as a function target.
3. Add a narrow builtin-marker-to-Core-operator projection in scalar operator
   synthesis. Reject unknown or signature-incompatible markers.
4. Keep existing operator behavior unchanged in this preparatory slice.
5. Verify accepted trait identity, namesake-trait, visibility, import-alias, and
   generic implementation tests before proceeding.

This slice must remain small. It establishes representation, not native
operator policy.

### 2. Migrate `Addable`

1. Replace each builtin numeric `Addable.add` body with a distinct trusted
   builtin marker such as `int16.add`.
2. Map those markers to exact native `AddOp` targets in Core synthesis.
3. Route `+` and explicit `add(a, b)` through the same selected target.
4. Keep a native target as `BinaryExpr(AddOp)` and a source target as a function
   call.
5. Verify generic `T: Addable` specialization for one native scalar and one
   source-defined record.
6. Add `String`, `Fixed`, and tensor support only after scalar behavior is green;
   do not turn source collection implementations into native targets.
7. Remove only the `Addable` inference/Core bypasses and scalar std bodies made
   redundant by this slice.
8. Measure net production lines and generated C before starting the next trait.

### 3. Migrate Binary Arithmetic One Trait at a Time

Use this order:

1. `Subtractable` (numeric-scalar slice implemented)
2. `Multipliable` (numeric-scalar slice implemented)
3. `Divisible` (numeric-scalar slice implemented)
4. `Modulable` (numeric-scalar slice implemented)

For each trait, add per-type std builtin markers, the marker-to-operation
mapping, tests, native lowering, explicit-call coverage, generic coverage,
source-dispatch coverage, and old-body cleanup in one independently reviewable
slice. Preserve wrapping overflow and zero-divisor semantics in both runtime
tests and generated C.

Once all five arithmetic traits are migrated, delete the superseded general
arithmetic primitive authorization path. Retain operand and result-shape checks.

### 4. Migrate `Negatable`

1. Add `NativeUnaryTraitTarget` if it was not introduced by the preparatory
   representation slice. (Implemented.)
2. Add exact targets for signed integers and floats. (Implemented.)
3. Verify that unsigned negation still fails in typechecking with an actionable
   diagnostic. (Implemented.)
4. Remove the old primitive scalar negation bypass and redundant scalar std
   bodies. (Implemented.)
5. Migrate tensor negation as a separate native lifting slice. (Implemented.)
   Native lifting remains limited to concrete builtin element types because
   open family traits do not prove a compatible runtime representation.
   `Fixed` does not currently implement `Negatable` or support unary negation;
   adding that behavior remains a separate language decision rather than part
   of this migration.

### 5. Migrate `Equatable`

Equality is a separate slice because structural equality is not equivalent to
native scalar equality.

1. Replace native scalar implementation bodies with exact per-type builtin
   markers and map them to equality operations. (Core targets are implemented;
   the source marker swap is staged until the next bootstrap pin.)
2. Give every intended structural category (enums, unions, tuples, tensors,
   ranges, and standard collections) an explicit compiler-provided or source
   `Equatable` implementation. Do not retain a generic structural fallback.
   (Implemented with an exact compiler inventory.)
3. Make unsupported concrete equality fail during typechecking rather than
   passing broadly and failing in Core. (Implemented; records without an
   `Equatable` implementation are rejected.)
4. Verify generic `T: Equatable`, explicit `equals` and `not_equals`, both
   equality operators, and source-defined equality. (Implemented.)
5. Delete the primitive equality predicate only after every intentional
   structural category has an explicit replacement. (Implemented.)

### 6. Migrate `Orderable`

1. Replace ordered scalar implementation bodies with exact per-type builtin
   markers and map them to comparison operations. (Core targets are implemented
   for signed and unsigned integers, floating-point scalars, `Char`, `String`,
   and `Fixed`; the source marker swap is staged until the next bootstrap pin.)
2. Verify all four comparison operators and explicit calls to `less_than`,
   `greater_than`, `less_than_or_equal`, and `greater_than_or_equal`.
   Cover both native overrides and source implementations that inherit the
   default methods from `Orderable`. (Implemented.)
3. Preserve intended `String`, `Char`, and `Fixed` behavior. (Implemented.)
4. Keep unsupported `Bool`, tensor, and structural comparisons rejected unless
   the language contract is deliberately changed in a separate task.
   (Implemented and covered in inference tests.)
5. Delete the primitive ordering predicate and its Core bypasses. (Implemented.)

### 7. Delete the Split Model

After every capability class is represented and tested, delete:

- `has_native_operator_fast_path`; (Implemented.)
- integer/native operator type-name lists used only for authorization;
  (Implemented; the remaining integer-name helper serves non-operator
  `Stringable` fallback.)
- primitive self-call exceptions; (Implemented.)
- missing-implementation diagnostic exceptions; (Implemented.)
- `core_trait_method_builtin_fallback_name` and equivalent operator fallback
  routing; (Implemented. Non-operator prelude builtin routing remains.)
- superseded primitive predicates in inference; (Implemented.)
- string-keyed Core authorization indexes that are no longer needed;
  (Implemented. The remaining method index only supplies diagnostic
  candidates.)
- circular scalar operator implementation bodies; (Arithmetic and negation are
  implemented. Equality and ordering are staged for the next bootstrap pin.)
- obsolete imports, helpers, comments, and tests. (Implemented; the dead-code
  analyzer found and prompted removal of the orphaned `in_function` context
  field.)

Run exact-reference searches and the unused-Blorp-code analyzer for every
deleted helper. Do not leave compatibility shims; Blorp is pre-0.1.

### 8. Documentation and Final Verification

1. Update `docs/GUIDE.md` to explain compiler-provided trait implementations for
   builtin types. (Implemented.)
2. Update standard-library comments to describe native trait markers or
   intrinsic bodies accurately. (Implemented.)
3. Regenerate embedded standard-library artifacts using repository build
   commands; do not hand-edit generated output. (Implemented by the self-hosted
   build.)
4. Inspect final Core and generated C for representative native, explicit-call,
   generic-native, and source-defined cases. (Implemented in the retained
   `scripts/test-trait-operators` audit.)
5. Confirm the final production diff is a net architectural simplification.
   (Implemented: the Core authorization path removes more production code than
   it adds, with exact target and structural-type metadata replacing broad
   exceptions.)

## Required Behavior Coverage

Before implementation, ensure focused tests cover:

1. `Int16` arithmetic, comparison, equality, negation, and modulo.
2. Explicit `add`, `equals`, and `less_than` calls.
3. Generic `T: Addable` specialized to `Int16`.
4. Generic operator code specialized to a source-defined record.
5. A concrete type without the required trait fails during typechecking and the
   expected diagnostic text is asserted.
6. Mixed integer widths remain rejected.
7. User-defined operators resolve to implementation functions.
8. A same-type operator inside a user implementation retains ordinary recursive
   call semantics.
9. Native operators remain direct in final Core and generated C.
10. Integer overflow wraps.
11. Division and modulo by zero return zero.
12. `String + String`, structural equality, tensors, ranges, and enums retain
    their intended behavior.
13. Namesake traits in different modules cannot authorize one another.
14. Private or out-of-scope implementations remain unavailable.

## Fast Feedback Loop

The retained `scripts/test-trait-operators` covers the focused typechecker,
Core lowering, synthesis, trait resolution, runtime, and generated-C cases:

```bash
scripts/test-trait-operators bin/blorp
```

Add focused runtime and codegen-audit fixtures to the retained script as they
are introduced. Keep the narrow loop under source control so every trait slice
uses the same evidence. Run `scripts/compiler-check --stage typecheck` as the
slice-completion gate, not in the inner iteration loop.

## Broad Verification

Run at minimum before final integration:

```bash
make
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test compiler-blorp-sanitize
scripts/test std-check
scripts/test runtime
scripts/test leak
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp
make quality
scripts/test
```

For generated-code verification, inspect these representative cases:

- direct `Int16` operator syntax;
- explicit `add(Int16, Int16)`;
- generic `T: Addable` specialized to `Int16`;
- source-defined `Vec2` addition.

The first three must contain direct native arithmetic without an avoidable trait
wrapper call. The source-defined case must call the selected implementation.

## Historical Reference

The deleted roadmap and implementation history can be inspected without
switching branches:

```bash
git show codex/trait-system:docs/TRAIT_OPERATOR_ROADMAP.md
git log --oneline b4309c82..codex/trait-system -- \
  docs/TRAIT_OPERATOR_ROADMAP.md \
  compiler/blorp/src/stage_09_core/core_trait_resolve.brp \
  scripts/test-trait-operators
```

Useful historical checkpoints are `0c8ade06` (`Addable`), `0d5dd66c`
(`Subtractable`), `12f416e4` (`Multipliable`), `57e2bea2` (division/modulo),
`45f24d9a` (negation), `50d510f2` (equality), and `de76f45f` (ordering). Treat
them as behavioral references, not merge-ready patches.

## Completion Criteria

- Trait implementations are the only authorization source for overloadable
  operators.
- Accepted semantic identities determine which implementation is selected.
- Standard-library implementation declarations, not compiler type-name
  predicates, declare builtin capabilities.
- Builtin capabilities are exact native targets with direct generated C.
- Source-defined capabilities dispatch to implementation functions.
- Operator syntax and explicit method calls select the same implementation.
- Generic dispatch remains deferred until the dispatch type is concrete.
- Circular-looking primitive operator implementations are gone.
- Frontend and Core cannot disagree through duplicate capability inventories.
- Legacy primitive fast paths and diagnostic exceptions are deleted.
- Safe arithmetic and structural equality semantics are unchanged.
- The final production diff contains less authorization complexity than current
  `main`.
