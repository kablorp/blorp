# A runtime size can forge a static tensor dimension

Status: open.

Principle 14 and the Guide (Fixed-Size Arrays, Integer Literals Infer `Int`)
say a static dimension comes from a literal, a `#N` parameter, `length(tensor)`
or dimension arithmetic over those, and that a type annotation cannot turn a
runtime `Int` into one. The checker accepts:

```
func main(args: List[String]) -> Int:
	n: Int = 3
	v: Int[#5] = vector(7, n)        -- three elements, typed as five
	v[4]                             -- proved in bounds against #5
```

The program compiles and runs. The generated C allocates three elements
(`blorp_vector_new_fill_i64(7, 3)`) but folds `length(v)` to `5`; reading index
3 or 4 hits the runtime capacity guard in `blorp_vector_read_i64` and silently
returns `0`. The static dimension is a lie: bounds proofs, `length` and any
code that relies on `#5` describe a value that does not exist. The same holds
for `matrix(7, rows, cols)` with runtime `rows`/`cols`, and
`var v = vector(0.0, n)` is accepted with no annotation at all.

## Where to look

The `vector`/`matrix` size arguments in `stage_06_typecheck/infer.brp` and the
dimension solver (`stage_06_typecheck/type_system/dim_solver.brp`): a size
argument must produce a dimension type from its own expression, and an
expected type may only check it, never supply it.

## Fixtures (3)

Under `blorp/test/test_compiler/test_stage_06_typecheck/infer_fixtures/infer/should_fail/`:
`matrix_expected_type_does_not_forge_runtime_sizes`,
`vector_expected_type_does_not_forge_runtime_size`, `vector_runtime_size`.

## Acceptance

All three are rejected at typecheck with the pinned message (which already
says which forms are allowed), pass `run_blorp_check_fixtures.py`, and are
marked `-- RUN-BLORP-CHECK`.
