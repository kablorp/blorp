# A bare `print` statement passes `check` and emits C that does not compile

Status: open. Ledger: CF-001 in `docs/DIAGNOSTIC_GAPS.md`.

A function name used as a whole expression statement is accepted by the
typechecker, and `bin/blorp run` then fails inside the C compiler with a name the
user never wrote. The Python 2 habit `print "hello"` is read as the statement
`print` followed by the statement `"hello"`, so it reaches this path.

```
func main(args: List[String]) -> Int:
    print
    0
```

## Evidence

- `bin/blorp check --no-format` prints `Type checking succeeded.`
- `bin/blorp run` prints:
  ```
  C compiler exited with status 1: <stdin>:230:19: error: use of undeclared identifier '__ufcs_io__print'
    230 |     blorp_release(__ufcs_io__print);
  ```
- `print "hello"` and `print` followed by `"hello"` on its own line fail the same way.
- `bin/blorp compile -o out file.brp` reports `Generated out` for the same file, so
  the failure shows only when the C is built by `run`.
- `__ufcs_<module>__<name>` is the spelling of an imported callee wrapper
  (`blorp/src/compiler/stage_08_core_lower/lower.brp:871`,
  `stage_08_core_lower/identity.brp:12`); the release of the discarded function
  value refers to a wrapper that is never declared.

## Proposed fix

Decide the rule first: either an expression statement of function type is a
typecheck error ("this names a function but does not call it; write `print(x)`"),
or Core must declare the wrapper it releases. The first is the friendlier
diagnostic and also catches the Python 2 form.

## Owner

Typecheck (old `compiler/stage_06_typecheck`) for the diagnostic; Core lowering
(`compiler/stage_08_core_lower`) for the undeclared wrapper.
