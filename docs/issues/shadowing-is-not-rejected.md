# Shadowing is not rejected

Status: open.

## Decision

Owner, 2026-10-02: shadowing is generally disallowed, to prevent confusion. A
binding may not reuse a name that is already visible: an outer function,
builtin, imported name, global, or local.

## Current behaviour

`bin/blorp check` today:

```
LIMIT: Int = 10

func foo() -> Int:
	42

func bar(foo: Int) -> Int:           -- accepted: parameter shadows a function
	foo

func main(args: List[String]) -> Int:
	foo = 42                         -- accepted: a new local shadows the function
	length: Int = 10                 -- accepted: annotated local shadows a builtin
	LIMIT: Int = 5                   -- accepted: annotated local shadows a global
	x: Int = 1
	if x > 0:
		x: Int = 2                   -- accepted: inner block shadows a local
		print(to_string(x))
	match Some(5):
		Some(x): x                   -- accepted: pattern binder shadows a local
		None: x
```

Also accepted: a lambda parameter that reuses an outer local
(`func(x: Int): x + 1` beside `x`), and a parameter named like a global.

Already rejected:

- unannotated `LIMIT = 5` on an outer immutable global or variable (`Cannot
  assign to immutable variable 'LIMIT'`);
- a `for` binder that reuses a local (``Cannot redeclare `i` in for loop``);
- a tuple destructuring that reuses a current-scope name, or an enclosing `var`
  (GRAMMAR, Variable Declaration).

The unannotated form is the most confusing case: `foo = 42` reads as an
assignment, and is one for an outer variable, but over a function it silently
declares a local. Same-scope redeclaration with an annotation
(`x: Int = 5` then `x: Int = 6`) is tracked in
`same-scope-redeclaration-accepted.md`.

## Where to look

- `infer_assign_expr` in `stage_06_typecheck/infer.brp` (near line 20884): for a
  non-variable symbol outside the current scope it calls
  `infer_implicit_assign_or_type_error` and declares a local instead of
  reporting `Cannot assign to function`.
- Annotated declarations, parameters, lambda parameters and pattern binders
  bind through the environment without a visibility check; the `for` binder
  and `check_tuple_destruct_redeclarations` show the existing redeclaration
  checks to generalize.

## Fixtures

Unmarked should_fail fixtures that expect the rule:

- `blorp/test/test_compiler/test_stage_06_typecheck/fixtures/typecheck/should_fail/`:
  `mutability_assign_to_builtin`, `mutability_assign_to_func`,
  `mutability_assign_to_import`, `mutability_assign_to_main`,
  `mutability_assign_to_trait_method`;
- `blorp/test/test_compiler/test_stage_06_typecheck/infer_fixtures/infer/should_fail/`:
  `shadow_var_func`.

Several current should_pass fixtures encode shadowing and will flip when the
rule is implemented; they are left unchanged until then. Examples:
`infer_fixtures/infer/should_pass/local_var_builtin_name.brp`,
`param_shadows_builtin.brp`, `shadow_cross_scope.brp`, and under
`fixtures/typecheck/should_pass/`: `prelude_input_param_shadow.brp`,
`constructor_pattern_respects_lexical_shadowing.brp`,
`mutability_closure_pattern_shadow_outer.brp`,
`mutability_concurrently_loop_pattern_shadow_outer.brp`,
`mutability_detach_pattern_shadow_outer.brp`. The compiler and standard
library may also rely on shadowing; measure that before choosing how strict the
first step is.

## Acceptance

Shadowing is rejected at typecheck with one message naming the name and what it
shadows, plus a help line suggesting a different name. The six fixtures above
pass `run_blorp_check_fixtures.py` with that message and are marked
`-- RUN-BLORP-CHECK`; the should_pass fixtures that encode shadowing move to
should_fail or are rewritten; the compiler, standard library and tests build.
