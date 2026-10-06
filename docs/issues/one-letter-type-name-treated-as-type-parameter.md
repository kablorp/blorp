# A defined type with a one-letter name is treated as a type parameter

Status: open.

The Guide (Generics, Auto-generalization) says a name already defined as a type
is not auto-generalized, even when declared later in the file, and gives this
example. The checker treats `T` as a type parameter anyway and accepts a
`String` argument:

```
union T:
	Wrap(Int)

func test(x: T) -> Int:
	match x:
		Wrap(n): n

func main(args: List[String]) -> Int:
	test("hello")
```

Any one-letter name behaves the same (`union U`, `union K`, `record T`), and so
does a declaration after the function. The same program with `union Elem` is
rejected correctly (`argument 1 expected Elem, got String`), so header
discovery is right: implicit type-parameter admission in
`stage_06_typecheck/headers/callable_headers.brp` already skips names for which
`type_header_graph_has_unqualified_type_name` holds.

## Where to look

`is_legacy_single_letter_type_param` in
`stage_06_typecheck/type_system/semantic_type.brp` decides from the spelling
alone that a one-letter capital is a type variable. Its callers
(`is_type_param_name` in the same file, the zero-argument named-type case near
its line 1741, and `infer.brp` near the comment "legacy single-letter named type
parameters") must ask the enclosing declaration's parameter list instead of
guessing from the name, as AGENTS.md requires ("Do not rely on flimsy
heuristics").

## Fixtures (2)

`blorp/test/test_compiler/test_stage_06_typecheck/infer_fixtures/infer/should_fail/concrete_type_named_T.brp`
and `concrete_type_named_T_forward.brp` in the same directory.

## Acceptance

Both are rejected with an argument mismatch naming the union `T`, pass
`run_blorp_check_fixtures.py`, and are marked `-- RUN-BLORP-CHECK`; the
compiler and standard library still build.
