# Dimension types in signatures and annotations are not validated

Status: open.

`validate_array_dims` in
`blorp/src/compiler/stage_06_typecheck/type_system/semantic_type.brp` rejects
dimension arithmetic that normalizes to zero or below and misplaced variadic
dimensions, but nothing calls it. So these are accepted:

```
pure func shrink(v: Int[#5]) -> Int[#5 - #8]:     -- dimension -3
	builtin

func zero_dim[T, #N](v: T[#N - #N]) -> Int:      -- dimension 0
	0

pure func drop_three[T, #N](v: T[#N]) -> T[#N - #3]:
	builtin

func main(args: List[String]) -> Int:
	v: Int[#2] = {1, 2}
	drop_three(v)                                   -- #2 - #3 at the call site
	x: Float[#Ds...] = {1.0}                        -- variadic dims in a local annotation
	0
```

A non-positive dimension has no runtime representation, and `#Ds...` denotes
caller-supplied concrete dimensions, which a local annotation has no caller to
supply (AGENTS.md, Language And Repository Boundaries).

## Where to look

Call `validate_array_dims` (and its variadic check) where signature and
annotation types are resolved, and check the substituted result type at each
generic call site in the dimension solver
(`stage_06_typecheck/type_system/dim_solver.brp`).

## Fixtures (6)

Under `blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_fail/`:
`dim_nested_negative`, `dim_sub_negative`, `dim_sub_negative_generic`,
`dim_sub_zero`, `vardims_in_let_binding`, `vardims_in_var_decl`.

## Acceptance

Each is rejected at typecheck with the pinned message or an equally specific
one with a help line, passes `run_blorp_check_fixtures.py`, and is marked
`-- RUN-BLORP-CHECK`.
