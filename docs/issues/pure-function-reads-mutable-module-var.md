# A `pure func` may read a module-level `var`

Status: open. Purity hole or design gap; the decision is the owner's.

```
var counter: Int = 0

pure func f() -> Int:
    counter

func main(args: List[String]) -> Int:
    print("${f()}")
    0
```

## Evidence

- `check` succeeds and `run` prints `0`. Assigning to `counter` inside the pure
  function is rejected (`Pure function 'f' cannot assign to module-level variable
  'counter'`), and closures may not capture a `var` (GUIDE, Closure Capture Rules),
  but reading one is accepted.
- GUIDE section 4 says a pure function is deterministic given its inputs; a read of
  a mutable global breaks that if anything can assign the global between calls.

## Open question

Reject the read ("a pure function cannot read the mutable global `counter`; pass it
as a parameter"), or document that reads are allowed. Principle 4 favours rejecting.

## Owner

Typecheck purity (old `compiler/stage_06_typecheck/decl.brp`, near line 4401).
