# `"""hello"""` is silently the empty string

Status: open. Ledger: CF-006 in `docs/DIAGNOSTIC_GAPS.md`.

```
func main(args: List[String]) -> Int:
    s: String = """hello"""
    print("[${s}]")
    0
```

## Evidence

`check` succeeds and `run` prints `[]`: the text is lost, with no diagnostic. The
empty result suggests the literal is read as adjacent string literals (`""`, then
`"hello"`, then `""`) of which only the first is kept; the cause was not traced. A multiline string in Blorp uses aligned `|` markers
(GUIDE, Multiline Strings).

## Proposed fix

Reject a string literal that is immediately followed by another string literal
(`""` then `"hello"`) with "Blorp has no triple-quoted strings; use `|` aligned
multiline strings".

## Owner

Discovery lexer/parser: `blorp/src/compiler_new/stage_01_discovery/lex/string_literals.brp`
and the statement parser (`parse/body_parser.brp`), which should not accept two
expressions on one line.
