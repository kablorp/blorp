# The unused-import error is documented and has fixtures, but is not emitted

Status: open. Ledger: CF-008 in `docs/DIAGNOSTIC_GAPS.md`.

GUIDE section 8 says the compiler rejects an import that is not used in the file
being checked. `bin/blorp check` accepts it.

```
import:
    list: map

func main(args: List[String]) -> Int:
    0
```

## Evidence

- `check` prints `Type checking succeeded.`; `bin/blorp lint` reports nothing.
- Four fixtures under `blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/`
  expect the error and fail the same way when run by hand:
  `unused_selective_import_error.brp` (`-- EXPECT: error: unused import 'sum' from
  module 'vector'`), `unused_qualified_import_error.brp`
  (`unused module import 'D' from module 'dict'`),
  `unused_multiple_import_errors.brp` and `unused_import_error_in_helper.brp`.
- A search of `blorp/src` finds no emitter for `unused import`. The Guide is right
  and the check regressed, or the fixtures are orphaned and no runner executes them;
  the search did not establish which.

## Proposed fix

Restore the check (selective import, qualified `as` import, and an import used only
by an imported module), then confirm the four fixtures run in
`compiler_test_ownership.json`. Only if the owner decides it should be a lint instead,
change the Guide and move the fixtures.

## Owner

Module binding in the old typecheck (`compiler/stage_06_typecheck/modules/`).
