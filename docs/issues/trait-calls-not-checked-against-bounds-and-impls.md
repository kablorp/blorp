# Trait method calls are not checked against bounds and implementations

Status: open.

The Guide (Using Trait Bounds) requires a bound such as `T: Stringable` before
calling `to_string` on a `T`, and a type is Stringable or Equatable only through
an implementation (the Guide lists which built-in types have them). The checker
accepts trait-method calls whose argument has neither:

```
func stringify[T](x: T) -> String:
	to_string(x)                 -- no `T: Stringable`

func check_eq[T](x: T, y: T) -> Bool:
	equals(x, y)                 -- no `T: Equatable`

func my_to_int[T](x: T) -> Int:
	to_int(x)

record Pair {a: Int, b: Int}

func show(p: Pair) -> String:
	to_string(p)                 -- Pair has no Stringable implementation
```

A conditional implementation is not checked either: with
`implements Stringable for Wrap[T:Stringable]`, `to_string(W(NS(42)))` is
accepted although `NS`'s union implements nothing. `to_string(p)` on the
record reaches C as `blorp_to_string(<record pointer>)`, which clang rejects
(`incompatible pointer to integer conversion`); `check_eq` and `my_to_int` run
only because their one instantiation is `Int`. The operator forms are checked (`x == y` on an
unbounded `T` reports `Type parameter 'T' requires Equatable bound for == and !=
operators. Add 'T: Equatable' to the function signature`, and `==` on a union
without an implementation reports `Equality requires an implementation of
Equatable`), so only the named-function forms skip the check.

## Where to look

Trait-method call resolution in `stage_06_typecheck/infer.brp`: the operator
path checks the argument type's implementations and bounds; the call path for
`to_string`, `equals`, `to_int`, `to_float` and similar trait functions does
not, including the `T:Stringable` condition on a generic implementation.

## Fixtures (7)

Under `blorp/test/test_compiler/test_stage_06_typecheck/fixtures/typecheck/should_fail/`:
`traits_eq_no_bound`, `traits_to_float_no_bound`, `traits_to_int_no_bound`,
`traits_to_string_no_bound`, `to_string_no_impl`. Under
`blorp/test/test_compiler/test_stage_06_typecheck/infer_fixtures/infer/should_fail/`:
`option_nested_non_stringable`, `option_to_string_non_stringable`.

## Acceptance

Each is rejected at typecheck naming the missing bound or implementation, with
a help line that says what to add; each passes `run_blorp_check_fixtures.py`
and is marked `-- RUN-BLORP-CHECK`.
