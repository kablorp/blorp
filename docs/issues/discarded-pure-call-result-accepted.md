# A discarded pure call result is accepted

Status: open.

Blorp has value semantics (principle 2): `xs.append(1)` returns a new list and
leaves `xs` unchanged. Written as a statement, the result is discarded and the
line does nothing. A programmer coming from Python, where `append` mutates in
place, writes exactly this and gets no diagnostic:

```
func main(args: List[String]) -> Int:
	xs: List[Int] = []
	xs.append(1)                     -- result discarded; xs is still []
	0
```

The same happens inside a statement-position `if`. Principle 7 (make what a
Python or JS programmer tries first either work or produce a helpful message)
calls for an error such as `pure function call result is discarded` with a
help line suggesting `xs = xs.append(1)` on a `var`, or `_ = ...` to discard on
purpose.

## Where to look

Expression statements in block inference in `stage_06_typecheck/infer.brp`:
a non-final statement whose expression is a call to a pure function with a
non-Void result is discarded. `_ = expr` stays the explicit way to discard.

## Fixtures (2)

Under `blorp/test/test_compiler/test_stage_06_typecheck/fixtures/typecheck/should_fail/`:
`discarded_pure_call`, `discarded_pure_call_in_statement_if`.

## Acceptance

Both are rejected with the pinned message and a help line, pass
`run_blorp_check_fixtures.py`, and are marked `-- RUN-BLORP-CHECK`; the
compiler, standard library and tests are updated where they discard pure
results today.
