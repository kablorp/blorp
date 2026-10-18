# String concat acceptance matrix

Concatenation is accepted independently before checked slicing. Root-approved
ceilings: <=110 added production (native <=50, shared wiring <=60), <=750 added
test lines, <=30 language-fixture lines, <=25 public-documentation lines.
Plan/report lines are separate. Per-input costs target/cap +5% allocations and
retired instructions; stricter retained fixture caps still bind. No code or
fixture special case may make costs appear smaller.

The initial 400-line test allowance covered 399 prepared lines. Root and the
independent compiler expert approved 750 before completing the missing phase
cases; production, fixture, public-documentation and cost ceilings did not move.

| Test growth after the 399-line preparation | Physical lines added |
| --- | ---: |
| Shared explicit source constant | 8 |
| Checker contract and seven exact declaration rejections | 78 |
| Concrete specialization and parameter order | 42 |
| Lowering operand identities and source span | 48 |
| Reached and unreached emitter behavior | 38 |
| Insertion source assertions and readable definitions | 17 |
| Readable raw verifier inputs and assertions | 42 |
| Existing exact-help oracles and e2e registration | 5 |
| Public reuse of the existing e2e path for retained artifacts | 2 |
| Current tracked total | 679 |

The focused retained-artifact TestSuite under ignored `build/string-concat/`
adds 23 temporary test lines (702 including it), still below the 750 ceiling.
It calls the same Example/verify_all path and unchanged fixture main.

All original coverage remains. The separately accepted read_file EBNF/test
sync from c4ee9b14d is already in the final fixed baseline, excluded from concat LOC.

| Boundary | Published fact | Required positive and negative observations |
| --- | --- | --- |
| Parse | `StringConcatBuiltin`, exact quoted-label span | Real declaration `pure func concatenate(left: String, right: String) -> String: builtin("string.add")` accepts; prefeature parser rejects the quoted label exactly, not a host import. |
| Check | `RuntimeFunction(StringConcat)`; `Pure`, two String operands, String result | Existing runtime contract is sole signature authority. Wrong purity, arity or operand/result type rejects at the declaration with `builtin declaration does not match its runtime contract` and exact help/span from the StringConcat contract. |
| Specialize | `StringConcat` with concrete String parameters/result | Operation meaning survives as a variant. No designation or name lookup is needed; String remains the existing managed leaf. |
| Lower | Ordered `[left ValueId, right ValueId]`, String result, original call span | Both lowered spans equal the independent root-module source and quoted-label occurrence 74..86 from the literal source prefix. A compile-successful mutation making both spans 0..0 must fail. Aliasing arguments may use the same ValueId twice. |
| Ownership insertion | Two borrowed arguments; exactly one fresh String result owner | Borrowing parameters adds no acquire/drop; returning transfers the result owner; an unused result is dropped once. No new ownership policy is added. |
| Independent verifier | Actual call operands, result type, owners and borrow dependencies validated from raw input | Separate callbacks reject unmanaged result, missing/duplicate discharge, missing/extra operands, unmanaged managed argument and incorrect ParameterBorrow source. Rejection checks exact message/help/source/start/end. Verifier fixtures never obtain ownership operations by calling insertion. |
| Runtime | Counted UTF-8 bytes in one fresh managed root | Eight native cases independently observe allocations/free occurrences and exact bytes. INT64_MAX and SIZE_MAX allocation overhead are checked before sum/copy; inputs retain their counts. Result survives input destruction; source survives result destruction; aliases are legal. |
| Emit/real main | `blorp_string_concat(left,right)` uses typed operation facts | The normal fixture prints exact multilingual/NUL doubled bytes, original bytes and an empty line; no alternate entrypoint or C rewriting. |

The initial semantic red uses only existing production imports in
`test/unit/test_parse/test_string_concat.brp`:

```sh
/Users/keithphilpott/CLionProjects/blorp/bin/blorp test --timeout 180 \
  --std-dir /Users/keithphilpott/CLionProjects/blorp/standard_library/src \
  blorp_2/test/unit/test_parse/test_string_concat.brp
```

The host CLI's std flag was confirmed before the assigned execution window.
Before wiring, the failing acceptance callback printed `unknown builtin operation`,
the parser's complete closed-label help string and exact quoted-label source span.
That output is retained; after wiring the same callback succeeds. The semantic
red imports only existing production modules.

Native tests: `test/runtime/test_string_concat.brp` compiles the unmodified
`string_runtime()` and `STRING_CONCAT_RUNTIME` fragments with ASan/UBSan; the
fragment module is `src/runtime/string_concat.brp`. Unit insertion and verifier
suites use small directly constructed typed IR, not full compiler/e2e oracles.
Shared wiring tests cover checked/specialized/lowered contracts and declaration
rejections. All assigned phase and runtime checks pass.

Eight compile-successful mutations fail the intended callbacks, followed by
exact source restoration and green tests. Native helpers and pilot programs
remain strictly leak-free; the old-host own compile-time leak exception does
not waive target memory checks.

## Completed finishing gates

The [acceptance report](../benchmarks/results/blorp_2_string_concat_2026-10-18.md)
records fixed baseline `abd0aa1a01c77fd89768e1bc28c2453695495ce4` plus the
concat-only candidate in managed worktree `finish-concat`. All 3,151 unit,
runtime and grammar PASS observations and 462 e2e cases pass. Complete source,
library and test bytes match the generated pilot used by those tests.

All 3,900 measured calls complete once: 973 strict target, 2,919 normal target,
eight whole-feature host proxy. Every shared input meets +5% allocations and
normal min3 retired instructions; maxima are +2.471655% and +1.164548%.
The proxy meets +5% at +0.121432% TOTAL allocations and +0.043463% instructions.
New concat uses 12,390 allocations / 40,553,537 normal min3 instructions against
unchanged 205,000 / 600,000,000 limits. Host strict remains the documented
exit-99 limitation; all target strict observations have zero leaked objects/bytes.
Final independent review and destination integration remain separate gates.
