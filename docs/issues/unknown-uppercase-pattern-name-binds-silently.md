# An uppercase pattern name that is not a constructor binds silently

Status: open. Ledger: CF-004 in `docs/DIAGNOSTIC_GAPS.md`.

In a `match` arm, a name that is not a constructor of the scrutinee's type is a
variable binding that matches everything, even when it is spelled like a
constructor. Exhaustiveness is satisfied, later arms are unreachable with no
warning, and on a `Result` the backend fails.

## Repro

```
func main(args: List[String]) -> Int:
    o: Option[Int] = None
    n: Int = match o:
        Some(x): x
        Nothing: 7
    print("${n}")
    0
```

`check` succeeds and `run` prints `7`: `Nothing` is a catch-all. A lowercase `red:`
in a match over `union Color: Red / Green` behaves the same, and so does
`_: 0` followed by `1: 1` (an unreachable arm, no warning).

```
func f() -> Result[Int, String]:
    Err("boom")

func main(args: List[String]) -> Int:
    n: Int = match f():
        Ok(x): x
        None: 7
    print("${n}")
    0
```

`check` succeeds (no `Err` arm is required); `run` fails:
`#error "Blorp backend could not emit function body: $blorp$user_main_120"`. The same
with `Nothing: 7`. With a lowercase `other: 7` instead it runs and prints `7`.

## Evidence

- `infer.brp:18767` reports `Unknown constructor pattern` only when the scrutinee type
  has no constructor of that name at all (`Circle(r)` against an `Int`).
- Principle 6 in `AGENTS.md`: the compiler tells you when you have missed a case.

## Proposed fix

An uppercase-initial pattern identifier that is not a constructor in scope for the
scrutinee type is an error ("`Nothing` is not a constructor of `Option[Int]`; its
constructors are `Some` and `None`"). A lowercase name that equals a constructor
ignoring case gets a did-you-mean. An arm after a catch-all gets an unreachable-arm
warning. Fix the backend failure by making the typechecker reject the input first.

## Owner

Typecheck (old `compiler/stage_06_typecheck/infer.brp`, pattern inference near
line 18767). Whether a pattern identifier is a binder or a constructor is also
decided in the discovery parser (`parse/pattern_parser.brp`); the rule needs both
the name and the scrutinee type, so it belongs in typecheck.
