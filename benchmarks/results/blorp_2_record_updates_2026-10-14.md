# Fresh record updates: complete fields and independent ownership

The pilot accepts `{ base | field = expression }` for currently supported finite
records. It evaluates the base once, evaluates replacements in written order,
projects omitted fields in declaration order and constructs a complete result.
Managed results have fresh roots; inline numeric records need no runtime root.
Existing aliases retain their values. COW/reuse and recursive data remain later
increments in [the roadmap](../../blorp_2/ROADMAP.md).

## Published facts and construction

Checking publishes the checked base, its parser-owned complete expression span,
typed replacements in written order and typed inherited fields in declaration
order. It establishes one exact partition of the nominal record's fields.
Generic arguments may remain temporary until replacement constraints settle;
only complete TypeRefs escape checking. Specialization translates every issued
field identity and child type against the complete concrete owner. The update's
record head remains distinct from the type of any following postfix expression.

Lowering uses the existing projection and complete-construction operations.
After lowering replacements into a local ordinal table, one declaration-order
completion walk projects the published inherited rows and appends complete
fields. No new ownership operation, runtime path, semantic catalogue or cache
was introduced. Existing insertion acquires projection temporaries and every
stored managed occurrence separately, then retires each obligation at last use.
Independent verification consumes the published ownership facts.

Review found that the first inherited-field setter retained the previous table
root across each call, causing O(fields × omitted-fields) COW copying. The
completion walk removes those redundant writes. Generated host C proves that
the replacement setter and both completed-field append sites move their local
roots before mutation/capacity expansion. The final table retain supports only
read-only iteration. Existing expression-definition COW, field-name lookup and
aggregate-emission prefix threading remain separate debts; this is not a claim
that the whole compiler is linear.

## Granular tests and normal entrypoints

There are 43 new checking, syntax, specialization, lowering and grammar
callbacks, 15 ownership callbacks, 12 native runtime cases driven by one Blorp
callback, and two additional callbacks in existing lexer/grammar suites.
Checking negatives pin exact kinds, messages, help, source identities, spans
and notes. They cover nominal owner mismatch, name/duplicate priority before
bad RHSs, generic growth in both base and replacement, and purity/tail rules.
Lowering tests distinguish evaluation order from storage order and assert
projection owners and independently expected result types.

Raw verifier cases assemble fresh-copy ownership IR independently of insertion.
Native tests use production aggregate helpers and actual allocation-occurrence
observers, never generated language functions or freed-object reads. They cover
old aliases, child escape, duplicate stored pointers, Void/unmanaged-union roots,
mixed record/List/union children, inactive payloads and inline numeric records.

Three lowering source mutations fail their protected callbacks: duplicated base
evaluation (3 failures), reversed RHS order (1), and wrong replacement slot (5).
Three production emitter mutations fail native cases: omitted field destruction
(9), destruction on nonfinal root drop (4), and inactive payload visitation (1).
Two explicit native-protocol mutations omit projection/escape acquisition and
fail 4/1 cases; these do not establish compiler-IR coverage. Every source was
restored exactly and the protected suites passed again.

The first behavior test failed before the feature. Retained setup failures are
reported separately: a missing newline in a nominal-check test and a lexer test
observer missing the new closed Symbol variant. Separately, the old grammar
diagnostic oracle executed and failed (2,280 passes, one failure) before its
explicit migration. The original `{ first : 7 }` input remains unchanged and now
pins the missing-bar
diagnostic dictated by `name =` disambiguation. A new established-literal case
pins its second field's missing `=`. No compatibility heuristic was added.

| Normal-main fixture | Exact stdout | Allocation/instruction ceilings |
| --- | --- | --- |
| `record/update/aliases.brp` | `42\n7\n` | 25,000 / 150,000,000 |
| `record/update/order.brp` | `base\ntext\nnumber\n7\n7\n` | 35,000 / 180,000,000 |
| `record/update/escaped_children.brp` | `42\n2\n7\n` | 30,000 / 150,000,000 |

All three exit 0 with empty stderr and pass strict C11/O0/Wall/Wextra/Werror/
pedantic/ASan/UBSan smoke checks. Existing fixture ceilings are unchanged.
The required-instruction gate, `env BLORP_2_INSTRUCTION_CHECK=required make -C
blorp_2 test`, exits zero with empty stderr: **2,282 unit/runtime/grammar checks
and 334 e2e cases pass**, with zero failures. This includes nested
native runtime assertions; nested e2e `[PASS]` lines are not extra e2e cases.
The e2e count includes compiler-output assertions; the three new fixtures each
execute their normal main with the exact outcomes above.
The harness builds the pilot exactly once.

## Matched whole-compiler costs

Baseline sources are committed `54e12e842`, including the separately reviewed
generic-parameter rename. Baseline and candidate were built at the same source
paths with the same FRESH host, Apple clang 21 and
`-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`. Temporary baseline source
projection was restored byte-for-byte before candidate validation.

| Artifact | SHA256 |
| --- | --- |
| FRESH host | `c2991129d1bbfc344b90ee466e37517bd41ef2d3f35801b6283e157ec24e13fe` |
| Baseline pilot | `0f2bc339780fc0ab8a93b2547f0907b64756f43be8b60dbae52f3a9404716c98` |
| Baseline generated host C | `ebaba0c8c684cd9d6b57eac96ef85b3d773330d4d2b31e2834e414fe179e98b2` |
| Corrected candidate pilot | `30f2a86a1ea7b3ecf7f3786aa4de21a66bf27e978ca64b533bf76608e63222f2` |
| Corrected generated host C | `ff0f34c65aa06792df55a2ec202ee77f689f9ec10b4ba1bdbdd00ed344f6bdbe` |
| Full-gate rebuilt pilot | `a7d6d5a0d114baf3a63f2a71bc246d242d1e09b08a5490ae423cd815e521fe7f` |

The full gate emits identical host C with the same flags. Its native binary hash
differs from the frozen measurement binary; both actual hashes are retained.

Three alternating pairs on 36 frozen shared inputs produce 216 samples. Every
allocation count is stable; releases balance with no reported leaked objects or
bytes. Target C is byte-identical for every shared input. Maximum allocation
increase is **0.841350%**; maximum minimum-retired-instruction increase is
**0.878681%**, both below the 5% working target and 10% per-input hard ceiling.
These are owned-input proxies, not self-compilation measurements.

## Owning-phase and structural scaling

The matched lowering probe prepares source/checking/specialization and its
expected definition count outside the interval. Each interval includes lowering,
metadata count access and destruction of the lowered result. Three alternating
R0/R64 pairs use the same runner/input paths; instructions are
`(minimum R64 − minimum R0) / 64`. All 144 samples have balanced process and
interval counts, zero live-object delta, stable counters and unchanged definition
counts. Raw-buffer counters report zero; they do not count all managed allocator
backing allocations.

| Numeric fields, one replacement | Before allocations | After allocations | Before instructions | After instructions |
| --- | ---: | ---: | ---: | ---: |
| 16 | 315 | 299 | 664,010 | 630,602 |
| 32 | 512 | 480 | 1,137,032 | 1,071,218 |
| 64 | 901 | 837 | 2,261,210 | 2,100,942 |
| 128 | 1,674 | 1,546 | 5,096,548 | 4,724,116 |

The correction reduces allocations **7.646356%** and instructions **7.307528%**
at width 128. Both signals improve on all 12 fixed-replacement, full-replacement
and repeated-statement shapes; this compares the initial and corrected feature,
not the restricted baseline.

Whole-CLI scaling separately retains 108 samples covering those three axes at
16/32/64/128. Its explicit-construction controls and update programs are distinct
benchmark inputs, not rewritten e2e fixtures. All 36 generated outputs compile
under strict C/default nesting limits and ASan/UBSan; their normal mains return
the expected Int 1 with no output. Shared explicit controls emit identical C.
Maximum structural brace depth, excluding comments/literals, is two.

## Size and retained evidence

The feature adds **248 production lines** and **2,659 test lines**, including new
files and the two existing-observer migrations, without removing coverage.
README/EBNF and the roadmap describe the syntax and corrected construction.
Two independent compiler experts approve source, tests and targeted evidence
with zero open findings. The complete gate passes; final report review precedes
the coordinator's commit.

Raw artifacts, source hashes, exact commands, setup/behavior distinctions,
mutation receipts, generated C and both reviewer reports are under the ignored
`build/next-increments-20261014/record-update/`. The shared comparison is under
`build/authority-fixes/record-update-corrected-costs/`. These measurements do not
cover self-compilation, recursive layouts, COW/reuse, or later List update APIs.
