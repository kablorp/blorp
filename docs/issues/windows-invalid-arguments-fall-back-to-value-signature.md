# `windows` with invalid arguments falls back to its value signature

Status: open.

`for w in windows(v, 3):` is rewritten into a loop view whose `w` is a
`T[#3]` window. `windows_loop_view` in `stage_06_typecheck/infer.brp` builds
that view only for a one-dimensional tensor and a positive integer literal
size; otherwise it returns `None`, and the loop silently uses the ordinary
signature `windows(vec: T[#Ds...], size: Int) -> List[T]`, iterating elements
instead of windows. So:

```
import:
	tensor: windows

pure func zero(v: Int[#10]) -> Int:
	var sum: Int = 0
	for w in windows(v, 0):          -- accepted; `w` is an Int
		sum += 1
	sum

pure func two_d(m: Int[#3, #4]) -> Int:
	var sum: Int = 0
	for w in windows(m, 2):          -- accepted; `w` is an Int
		sum += 1
	sum
```

`bin/blorp compile` on the first then fails inside Core with
`selected direct call survived Core call resolution` (an internal error).
A non-literal size (`windows(v, k)`) is rejected only because `w[0]` on an
`Int` fails (`checked_get requires an array type, got Int`).

## Where to look

`windows_loop_view` and `typed_loop_view` in `stage_06_typecheck/infer.brp`:
when the producer is `windows` but the arguments do not form a valid view,
report why (size must be a positive literal; the tensor must be 1-D) instead of
returning `None`.

## Fixtures (3)

Under `blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/`:
`windows_2d_tensor`, `windows_zero_size` (accepted), and `windows_non_literal`
(rejected only for the incidental `checked_get` error).

## Acceptance

All three are rejected at typecheck with the pinned messages (they already
show the valid form), pass `run_blorp_check_fixtures.py`, and are marked
`-- RUN-BLORP-CHECK`.
