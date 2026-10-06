# Trait default methods are missing for generic impls; operators fall back to pointer comparison

Status: open. Ledger: CF-010 in `docs/DIAGNOSTIC_GAPS.md`.

A generic implementation that defines only `equals` does not get the trait's
default `not_equals`, and some comparisons of generic containers do not reach
the element implementation. Trait resolution then falls back to a native C
comparison, which compares box pointers for managed values. The result is
wrong, silently.

## Reproductions

```
record Wrap[T] {
    value: T
}


implements Equatable for Wrap[T:Equatable]:
    pure func equals(a: Wrap[T], b: Wrap[T]) -> Bool:
        a.value == b.value


func main(args: List[String]):
    a: Wrap[Int] = {value = args.length()}
    b: Wrap[Int] = {value = 1}
    print(a != b)                       -- prints True, expected False
    xs: List[(Int, Int)] = [(args.length(), 2)]
    ys: List[(Int, Int)] = [(1, 2)]
    print(xs == ys)                     -- prints False, expected True
    p: (Int, Int) = (args.length(), 2)
    print(p != (1, 2))                  -- prints True, expected False
```

Run with `bin/blorp run --no-format`. For the tuple, the generated C is a
pointer comparison of the two `blorp_Tuple*` values.

## Cause

`target_for_dispatch` in `blorp/src/compiler/stage_09_core/trait_resolve.brp`
looks up a registered implementation first. The standard library's tuple
implementations (`standard_library/src/tuple.brp`) and the `Wrap` example
define only `equals`; the trait's default `not_equals` body is not registered
for the generic implementation's instances. The call then falls through to
`compiler_native_target`, and `has_native_structural_equality` maps
`Equatable` on `TupleType` (and other listed types) to a native
`EqualOp`/`NotEqualOp`. Typecheck accepted the program because the
implementation exists, so the fallback is never reported.

## Change that closes it

Register trait default methods for every instance of a generic
implementation, so `not_equals` and other defaults resolve to Blorp code.
Remove `TupleType` from `has_native_structural_equality`, and make the native
fallback an internal error for any managed type rather than a pointer
comparison. Check the remaining fallback types (enums, refinement indexes,
tensors, named structural types) for the same fall-through.

Tests: `==` and `!=` on equal and unequal tuples, a generic record with only
`equals`, and `List` of tuples, with runtime-built strings among the
elements. Each test also checks the resolved Core target after
`trait_resolve` (a call to the implementation or the default body, never a
native pointer comparison), not only the printed value.
