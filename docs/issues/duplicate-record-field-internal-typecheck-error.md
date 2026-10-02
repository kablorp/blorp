# A duplicate record field prints an internal typecheck error

Status: open. Ledger: CF-003 in `docs/DIAGNOSTIC_GAPS.md`.

```
record P { x: Int, x: Int }

func main(args: List[String]) -> Int:
    0
```

## Evidence

`bin/blorp check --no-format`:

```
error: internal typecheck error: accepted record graph rejected accepted headers: accepted record table rejected duplicate or mismatched identities
```

The text comes from `Err(["accepted record table rejected duplicate or mismatched
identities"])` in `blorp/src/compiler/stage_06_typecheck/headers/accepted_record_graph.brp:343`:
a table invariant failing is the first place the mistake is noticed. A duplicate
union constructor already has a user-facing check
(`duplicate constructor 'A' in union 'U'`).

## Proposed fix

Report `duplicate field `x` in record `P`` with the position of the second
declaration before the record table is built, as the union-constructor check does.

## Owner

Typecheck headers (old `compiler/stage_06_typecheck/headers`). A duplicate-name check
over a declaration's own fields is also a candidate for the discovery stage, which
sees the declaration first.
