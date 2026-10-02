# Generic type parameters are wildcards in some body checks

Status: open.

The Guide (Generics) says type parameters are opaque inside the body: a
concrete value does not satisfy `T` unless it came from a value already typed
`T`. Lambda bodies and record fields respect this (`Lambda body type mismatch:
expected T, got Int`), but a function's return value, a local annotation and
list/Option payloads do not. These are accepted:

```
func first_of[T](xs: List[T]) -> T:
	"always a string"

func swap[T, U](x: T, y: U) -> (U, T):
	(x, y)

func bad[T](arg: T) -> Int:
	x: T = 42
	0

func main(args: List[String]) -> Int:
	result: Int = first_of([1, 2, 3])
	result
```

`bin/blorp run` on this program emits C that returns a `blorp_String*` from a
function typed `long`; clang rejects it (`incompatible pointer to integer
conversion`), but a C compiler that only warns would hand the caller a pointer
as an `Int`. The type error belongs in the checker.

## Where to look

`stage_06_typecheck/infer.brp` near line 20648, the assignability fallback
after `unify_symmetric_with_rigid_vars`: when the rigid unify fails it falls
back to `types_compatible_with_params` (`type_system/semantic_type.brp`), which,
as the comment there says, "accepts anything in a type-parameter slot". The fallback exists to
keep metas beside a mismatched parameter unbound; it must not let a concrete
type satisfy an enclosing rigid parameter.

## Fixtures (6)

Under `blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/`:
`generic_local_annotation_rejects_concrete`,
`generic_option_return_rejects_concrete_payload`,
`generics_body_returns_list_wrong_type`, `generics_body_wrong_concrete_type`,
`generics_swapped_type_params`, `generics_wrong_return_type_param`.

## Acceptance

All six are rejected at typecheck with a message naming the rigid parameter
(as `Lambda body type mismatch: expected T, got Int` does), pass
`run_blorp_check_fixtures.py`, and are marked `-- RUN-BLORP-CHECK`; the
compiler and standard library still build.
