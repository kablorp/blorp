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
- Related: an unknown capitalised name in a signature is auto-generalised into a
  type parameter (GUIDE, Generics), so `func f(x: Strng) -> Int:` is accepted. The
  owner decided on 2026-10-02 to remove unbounded auto-generalisation (branch
  `syntax/reject-typecheck-only-forms`), after which `Strng` is an unknown name. In a binding,
  `x: Integer = 1` says only ``declared as `Integer` but initializer has type `Int` ``.

## Proposed fix

Reject a postfix `[]` after a type with "write `List[Int]`". Once auto-generalisation
is removed, report an unknown type name as an error that suggests the nearest known
type (`Strng` -> `String`).

## Owner

Type parser in the discovery stage (`parse/type_parser.brp`) for `[]`; the typecheck
header graph (old `compiler/stage_06_typecheck/headers/type_header_graph.brp`) for
unknown names.
