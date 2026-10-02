# Exhaustiveness ignores nested patterns and tuples

Status: open.

Principle 6 and the Guide (Exhaustiveness) promise that a missed case is a
compile error. The checker only asks whether each top-level constructor name
appears in some arm, so an arm `Some(Some(n))` counts as covering every `Some`.
These are accepted:

```
func bad_nested(x: Option[Option[Int]]) -> Int:
	match x:
		Some(Some(n)): n
		None: 0                      -- Some(None) is not covered

func bad_tuple(x: (Bool, Bool)) -> Int:
	match x:
		(True, True): 1
		(True, False): 2
		(False, True): 3             -- (False, False) is not covered
```

The same holds for a user union nested in `Option` (`Some(Ok2(n))` without
`Some(Err2(_))`). At run time the missed case aborts: `bad_nested(Some(None))`
prints `blorp: non-exhaustive match` and exits with status 134, a runtime panic
that principle 1 rules out.

## Where to look

`constructor_match_exhaustiveness_error` and `check_match_exhaustiveness` in
`stage_06_typecheck/infer.brp`: coverage is computed from
`match_case_constructor_name_index`, the set of top-level constructor names,
and tuples have no coverage check. A usefulness/coverage matrix over nested
patterns (the OCaml and Rust approach) would cover constructors, literals,
tuples and lists in one place and also report unreachable arms
(see `unreachable-match-arms-accepted.md`).

## Fixtures (3)

Under `blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/`:
`match_nested_union_non_exhaustive`, `nested_pattern_non_exhaustive`,
`tuple_non_exhaustive`.

## Acceptance

Each is rejected with a message naming a missing case (for example
`Some(None)`) and a help line, passes `run_blorp_check_fixtures.py`, and is
marked `-- RUN-BLORP-CHECK`.
