# An annotated binding can redeclare a name in the same scope

Status: open.

An unannotated `x = 10` after `x = 5` is rejected (`Cannot assign to immutable
variable 'x'`), and a tuple destructuring, `for` binder or concurrent binding
that reuses a name in the same scope is rejected as a redeclaration (GRAMMAR,
Variable Declaration). An annotated binding is not checked, so this is
accepted:

```
func main(args: List[String]) -> Int:
	x: Int = 5
	x: Int = x + 1                   -- same scope, silently a new binding
	x: String = "hello"              -- and again, with another type
	0
```

This lets an immutable name change value within one scope without `var`,
which principle 5 (immutability by default: "you see at a glance what can
change") rules out. The owner decided on 2026-10-02 that shadowing is
generally disallowed; shadowing across scopes (inner blocks, match arms,
lambdas, parameters, names of functions and globals) is tracked in
`shadowing-is-not-rejected.md`, and the two can share one check.

## Where to look

The annotated declaration path in `stage_06_typecheck/infer.brp` has no
same-scope check corresponding to `check_tuple_destruct_redeclarations` (which
uses `env_lookup_in_current_scope`) or the `for` binder's `Cannot redeclare`
check.

## Fixtures (4)

`blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/mutability_double_declaration.brp`;
under `blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_fail/`:
`resolution_shadowing_rejected`, `shadow_different_type`, `shadow_same_scope`.

## Acceptance

All four are rejected with one consistent redeclaration message and a help line
(`use var and assignment`), pass `run_blorp_check_fixtures.py`, and are marked
`-- RUN-BLORP-CHECK`. The tuple, `for` and concurrent redeclaration messages use
the same wording.
