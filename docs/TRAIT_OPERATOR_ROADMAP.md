# Trait Operator Authorization Roadmap

**Status:** Restored and rebased on the current compiler architecture. The
numeric-scalar `Addable`, `Subtractable`, and `Multipliable` Core targets and
std builtin bodies are implemented on `traits-correct`; the typechecking
cutover plus `String`, `Fixed`, and tensor coverage remain before those phases
are complete. The historical
implementation remains on `codex/trait-system`, but it was not merged into
current `main`. Its design and tests are useful references; its completion
claims and paths are stale.

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

Current `main` still has the split model:

- `blorp/src/compiler/stage_06_typecheck/infer.brp` directly authorizes
  primitive arithmetic, comparison, equality, and negation through type-shape
  predicates.
- `blorp/src/compiler/stage_09_core/trait_resolve.brp` contains
  `has_native_operator_fast_path`, primitive self-call handling, and a
  missing-implementation exception.
- `CoreTraitImplTarget` only stores a mangled function name; it cannot represent
  a native unary or binary implementation explicitly.
- Scalar modules under `standard_library/src/` still contain circular-looking
  implementations such as `add(a, b): a + b`.
- The accepted semantic catalog now assigns exact `TraitId`, `TraitMethodId`,
  `ImplId`, and `CallableId` identities. This machinery postdates the historical
  roadmap and should decide whether a visible implementation authorizes an
  operation. It must not import or contain Core operator kinds.

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
| `Divisible` | signed and unsigned integer families; float family | division by zero returns zero; `Fixed`, tensors |
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
3. `Divisible`
4. `Modulable`

For each trait, add per-type std builtin markers, the marker-to-operation
mapping, tests, native lowering, explicit-call coverage, generic coverage,
source-dispatch coverage, and old-body cleanup in one independently reviewable
slice. Preserve wrapping overflow and zero-divisor semantics in both runtime
tests and generated C.

Once all five arithmetic traits are migrated, delete the superseded general
arithmetic primitive authorization path. Retain operand and result-shape checks.

### 4. Migrate `Negatable`

1. Add `NativeUnaryTraitTarget` if it was not introduced by the preparatory
   representation slice.
2. Add exact targets for signed integers and floats, then `Fixed` and tensors.
3. Verify that unsigned negation still fails in typechecking with an actionable
   diagnostic.
4. Remove the old primitive negation bypass and redundant scalar std bodies.

### 5. Migrate `Equatable`

Equality is a separate slice because structural equality is not equivalent to
native scalar equality.

1. Replace native scalar implementation bodies with exact per-type builtin
   markers and map them to equality operations.
2. Give every intended structural category (enums, unions, tuples, tensors,
   ranges, and standard collections) an explicit compiler-provided or source
   `Equatable` implementation. Do not retain a generic structural fallback.
3. Make unsupported concrete equality fail during typechecking rather than
   passing broadly and failing in Core.
4. Verify generic `T: Equatable`, explicit `equals` and `not_equals`, both
   equality operators, and source-defined equality.
5. Delete the primitive equality predicate only after every intentional
   structural category has an explicit replacement.

### 6. Migrate `Orderable`

1. Replace ordered scalar implementation bodies with exact per-type builtin
   markers and map them to comparison operations.
2. Verify all four comparison operators and explicit calls to `less_than`,
   `greater_than`, `less_than_or_equal`, and `greater_than_or_equal`.
   Cover both native overrides and source implementations that inherit the
   default methods from `Orderable`.
3. Preserve intended `String`, `Char`, and `Fixed` behavior.
4. Keep unsupported `Bool`, tensor, and structural comparisons rejected unless
   the language contract is deliberately changed in a separate task.
5. Delete the primitive ordering predicate and its Core bypasses.

### 7. Delete the Split Model

After every capability class is represented and tested, delete:

- `has_native_operator_fast_path`;
- integer/native operator type-name lists used only for authorization;
- primitive self-call exceptions;
- missing-implementation diagnostic exceptions;
- `core_trait_method_builtin_fallback_name` and equivalent trait-method
  builtin fallback routing once every caller has an explicit target;
- superseded primitive predicates in inference;
- string-keyed Core authorization indexes that are no longer needed;
- circular scalar operator implementation bodies;
- obsolete imports, helpers, comments, and tests.

Run exact-reference searches and the unused-Blorp-code analyzer for every
deleted helper. Do not leave compatibility shims; Blorp is pre-0.1.

### 8. Documentation and Final Verification

1. Update `docs/GUIDE.md` to explain compiler-provided trait implementations for
   builtin types.
2. Update standard-library comments to describe native trait markers or
   intrinsic bodies accurately.
3. Regenerate embedded standard-library artifacts using repository build
   commands; do not hand-edit generated output.
4. Inspect final Core and generated C for representative native, explicit-call,
   generic-native, and source-defined cases.
5. Confirm the final production diff is a net architectural simplification.

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

The historical `scripts/test-trait-operators` no longer exists. Recreate its
useful behavior against current paths before changing implementation. The loop
should include:

```bash
make
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_trait_resolve.brp \
  blorp/test/compiler/stage_09_core/test_core_trait_resolve_diagnostics.brp \
  blorp/test/compiler/stage_09_core/test_core_pipeline.brp
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp
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
