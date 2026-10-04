# `Int[]` in a type position silently becomes `Int`

Status: open. Ledger: CF-005 in `docs/DIAGNOSTIC_GAPS.md`.

```
func f(x: Int[]) -> Int:
    1

func main(args: List[String]) -> Int:
    f([1, 2])
```

## Evidence

- `check` accepts the declaration. The call fails with `Argument type mismatch: in
  call to 'f', argument 1 expected Int, got List[Int] at file.brp:6:7`: the `[]`
  was dropped and the parameter is `Int`.
- Rechecked with FRESH main `3f1632c19579ea9b6e1af0cceaedc76e34a671ea`
  on 2026-10-03: `Int[]` is still accepted as `Int`. Unknown signature types
  such as `Strng` are now rejected. Near-name suggestions are a separate
  diagnostic improvement tracked by DG-017, not part of this parser fault.

## Proposed fix

Reject a postfix `[]` after a type with "write `List[Int]`". Pin the message in
a failing discovery parser fixture and preserve old-parser parity while it
still serves the formatter, LSP, test discovery and `compile --ast`.

## Owner

Type parser in the discovery stage (`parse/type_parser.brp`), with the matching
old parser rule under `compiler/stage_03_parse`.
