# A function with no body is accepted and fails in Core when it is called

Status: open. Ledger: CF-002 in `docs/DIAGNOSTIC_GAPS.md`.

A function header followed by no indented body parses and typechecks, even with a
non-`Void` return type. Nothing fails until the function is called.

```
func f() -> Int:

func main(args: List[String]) -> Int:
    f()
```

## Evidence

- `bin/blorp check --no-format` prints `Type checking succeeded.`
- `bin/blorp compile -o out file.brp` prints `selected direct call survived Core
  call resolution` with the help `Core call resolution must classify selected
  function identity `119` before specialization`.
- Precondition: the failure needs a call. The same `f` never called, with a
  trivial `main`, passes `check` and compiles to a binary.
- Every other block header (`if`, `for`, `while`, `match`, `else`) reports
  `expected an indented block` when the body is missing.

## Proposed fix

Report `expected an indented block` for a function header with no body, as the
other headers do. This is a parser rule, so the check lives in the discovery
parser, not in Core.

## Owner

Discovery parser: `blorp/src/compiler_new/stage_01_discovery/parse/body_parser.brp`
(function body, near line 385) and `parse/block_layout.brp` (the missing-indent
report at about line 74). The default front end is the discovery stage.
