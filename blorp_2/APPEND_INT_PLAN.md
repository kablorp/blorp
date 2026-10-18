# String integer appending: one ordinary library wrapper

## Problem and boundary

Plan-only base: `89fdc1bb9ac49553443e67deda5956764f6c697e`. Implementation is pending. This is delivery 8 of [BOOTSTRAP_SOURCE_PLAN](BOOTSTRAP_SOURCE_PLAN.md) and bounded [M6](ROADMAP.md#m6-library-and-shell) library parity, not self-compilation acceptance.

The compiler calls `string.append_int(String, Int) -> String`, but the temporary library has no twin. Manual source scanning finds **114 textual occurrences on 109 matching lines**. The earlier `e906b8104` census was 113/108; the landed write_file emitter adds one occurrence. Neither count is a resolved inventory.

Add only this ordinary function in `standard_library/string.brp`, composing accepted `int.to_string` and `string.add`. No compiler production changes, host changes, source migration, new builtin, builder, control mechanism, opaque completion, managed-loop work or path work follows. Coordinator owns integration and serialized compiled slots. Root and independent compiler/ownership expert review this plan patch before its separate commit; implementation follows that commit and explicit slot release.

## Current dependency map

All source anchors below are under `blorp_2/src/`; these are observed gaps, not implementation scope.

| Actual caller/import | Missing temporary twin and boundary |
| --- | --- |
| `emit/emit.brp:102`, `main.brp:58`, `emit/diagnostics.brp:38` | append_int `(String, Int) -> String`; compose existing operations. |
| `utils/text.brp:9`, `load/load.brp:96` | starts_with `(String, String) -> Bool`; counted byte comparison is possible, but recursive String-carrying traversal needs stack/scaling review. |
| Seven substring sites: `lex/lex.brp:497,546,730,1025`; `parse/parse.brp:766,1069`; `emit/float_literal.brp:66` | Reviewed slice `(String, Int, Int) -> Option[String]`; exact bytes, scalar-aligned half-open bounds, explicit caller migration. No scalar re-encoding. |
| Thirteen List joins, including `emit/emit.brp:728,2630`, `parse/parse.brp:1090`, `load/load.brp:341`, `main.brp:126` | join `(List[String], String) -> String`; host capacity-aware append differs from repeated immutable concat. Scaling decision remains separate. |
| `own/own.brp:289`, `lex/lex.brp:310,832`, `utils/source.brp:46`, `parse/parse.brp:857` | Int comparisons, min and extrema constants. not_equals can match existing equals; ordering needs a machine primitive; constants use implemented M5 support. |
| `emit/float_literal.brp:16–43`, `parse/parse.brp:904`, `verify/verify.brp:1185` | Float comparisons, copysign, abs, is_nan/is_finite; preserve IEEE NaN/signed-zero semantics. |
| `check/signatures.brp:433`, `lex/lex.brp:1156,1224`, `load/load.brp:156,167` | List is_empty/contains/take and Option is_some/is_none/get_or/to_result. set_index is imported at `own/own.brp:3`, without a textual call; review removing the import before implementing it. |

Target current-directory/read/write/stderr interfaces now exist; loader still uses getcwd (`load/load.brp:307`). Shell migration remains. M7 owns remaining callbacks (`main.brp:30–35`) and emitter sorting (`emit/emit.brp:2257–2259`). No other gap migrates in this slice.

## Exact change and ownership

Before: `standard_library/string.brp:5–6` imports only _base; its final declaration at 26–27 is from_codepoint. After, add the import selection and function:

```blorp
import:
    _base: Int, Float, String, Bool, Option
    int as IntOps

pure func append_int(self: String, value: Int) -> String:
    add(self, IntOps.to_string(value))
```

The real caller at `src/emit/emit.brp:101–102` remains:

```blorp
private pure func c_parameter(index: Int) -> String:
    "blorp_p_".append_int(index)
```

Host signature: `../standard_library/src/string.brp:71`. Target formatting: `src/runtime/string.brp:61`. Borrow the prefix, own formatted digits, borrow digits during concat, drop digits afterward, transfer the fresh result. Expect **two fresh Strings per call**. Unlike host capacity reuse, this copies the prefix; no performance equivalence is claimed. Valid UTF-8 and embedded NUL survive exactly; decimal digits establish valid UTF-8 by construction.

## Witnesses and focused tests

First proposed fixture, `test/e2e/fixtures/string_operations/append_int.brp`:

```blorp
import:
    io: print
func main() -> Int:
    print("é\0".append_int(-42))
    23
```

Normal main must exit 23 with stdout bytes `c3 a9 00 2d 34 32 0a` and empty stderr. Capture the missing-method semantic red, including exact diagnostic message/help/span, before adding production; it is currently unexecuted evidence.

Second compact fixture, `append_int_edges.brp`, prints `prefix.append_int(-9223372036854775808)`, the retained `prefix = "é\0"`, `"".append_int(0)` and `"x".append_int(9223372036854775807)`, then binds an unused `prefix.append_int(-1)` result and exits 0. Normal source-literal emission already allocates a fresh String root; no extra concat/alias step is needed. Exact stdout is `é\0-9223372036854775808\né\0\n0\nx9223372036854775807\n`; stderr is empty. This covers extrema, empty prefix, zero, alias preservation and unused cleanup through real main.

Add three callbacks to existing TestSuites:

- `test/unit/test_check/test_method_resolution.brp`: `test_append_int_resolves_the_public_string_method`.
- `test/unit/test_lower/test_string_concat.brp`: `test_append_int_formats_then_concatenates_in_argument_order`; assert actual lowered wrapper parameter IDs/types, IntToString then StringConcat operand IDs/types, and the return ID.
- `test/unit/test_own/test_string_concat.brp`: `test_append_int_releases_formatted_digits_and_transfers_fresh_result`.

Reuse existing specialize/lower/emit concat suites and independent malformed ownership IR tests; add neither six phase files nor duplicate verifier coverage. Mutate the formatting sign and temporary cleanup separately; protected oracles must fail, then pass after restoration. Inspect emitted C for call order and releases. Run focused suites, build the compiler once, then existing component/real-main e2e gates. Unchanged controls retain exact C/diagnostics.

Future commands from checkout root, only after coordinator toolchain/slot selection:

```bash
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_check/test_method_resolution.brp \
  blorp_2/test/unit/test_lower/test_string_concat.brp \
  blorp_2/test/unit/test_own/test_string_concat.brp
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
make -C blorp_2 test-compiler
make -C blorp_2 test-e2e
```

## Fixed prospective contract

Subsequent implementation budgets: production **12 gross/+12 net**, permanent tests **300 gross/+300 net**, **two fixtures/60 physical lines**, docs **25 lines**. Count comments/blanks separately by category; never compress or delete coverage to fit.

First fixture: **30,000 allocations/150M instructions**. Compact edge fixture: **40,000/200M**. Published concat observations of 12,390/40,553,537 motivate these prospective caps; they are not append_int measurements or recovered raw evidence. No post-failure increase.

Freeze one accepted then-main B, exact candidate, full target library, corpus and coordinator's existing c04 supporting host with explicit ROOT host-library selection before samples. This is a **FEATURE proxy using full exit-time TOTAL allocations**, not the SOURCE construction checkpoint. Every unchanged input and proxy must satisfy **+5% allocations and normal min3 retired instructions**; strict target zero leaks. Preserve the host-only strict-leak limitation explicitly. This grants no waiver of original source-refactor **+3%** contracts or historical failures.

Stop for any cap breach, semantic mismatch, unexplained C change or new mechanism. Never roll B, refreeze after failure or silently expand scope. M8 remains the unchanged eventual real-source fixpoint proof.
