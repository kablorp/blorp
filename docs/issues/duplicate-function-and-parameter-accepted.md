# Duplicate function and parameter names are accepted

Status: open. Ledger: CF-007 in `docs/DIAGNOSTIC_GAPS.md`.

```
func f() -> Int:
    1

func f() -> Int:
    2

func main(args: List[String]) -> Int:
    print("${f()}")
    0
```

## Evidence

- `check` prints `Type checking succeeded.` and `run` prints `2`: the later
  definition wins, silently. `func f(a: Int, a: Int) -> Int:` is accepted too.
- Checks that exist for comparison: duplicate union constructor (`duplicate
  constructor 'A' in union 'U'`) and duplicate type parameter
  (`callable_headers.brp:990`, `declares type parameter ... more than once`).
- Overloading by parameter types exists, so the check must key on the full
  signature, not the name.

## Proposed fix

Report `function `f` is already defined at file.brp:1:1` for two declarations with
the same name and parameter types in a module, and `parameter `a` is declared twice`.

## Owner

Typecheck headers (old `compiler/stage_06_typecheck/headers/callable_headers.brp`).
