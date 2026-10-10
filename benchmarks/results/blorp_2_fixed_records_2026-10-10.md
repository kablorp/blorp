# Blorp 2 fixed records (2026-10-10)

Implementation, independent review and required validation components are
complete. This increment adds nominal, nongeneric fixed records with
nonempty Int-only fields through the existing pipeline. Managed records remain
a separate proposal. No runtime, driver, seal bypass, cache, registry or pipeline
layer was added.

The evidence navigator is `blorp_2/build/records/README.md`. Ignored raw packets,
source snapshots, generated C, hashes and sample commands are retained below
that directory. These measurements include compiler process startup and are
owned-input compilation proxies, not phase timings, self-compilation or a
whole-pipeline speedup.

## Reproduction and contracts

At baseline `e553b5c0493080a968cfcfe45367d1b2358a66c0`, the new ordinary
`test/e2e/fixtures/record/basic.brp` regression rejects `{` at line 1 column 19
(bytes 18..19), exit 1, with the existing unsupported-character diagnostic and no
C publication (`validation/record-red`, prior `red-reproduction.log`). The same
fixture now compiles to strict C11/O0 with ASan/UBSan and its unchanged real main
exits 7 with empty stdout/stderr (`record-basic-compile`,
`record-basic-native-build`, `record-basic-native-run`; recorder exit 7 is the
expected program result).

Parser postfixes are one closed call-or-field representation. Checking resolves
record owners and field positions, concrete expected contexts and complete
field sets; children retain written evaluation order. Source-order declaration
conflicts and literal error priority are explicit. Specialization translates
checked declaration identities through an explicit local instance map. Lowering
uses ordinary function-owned ValueIds and flat ordered definitions. Ownership
classifies admitted layouts as unmanaged. The independent verifier validates
public layouts, field membership, complete sets, type/availability and ownership
obligations, including pass-through parameters. Emission consumes the verified
program and emits identity-derived by-value C structs.

The checker-private call-operation preparation passed 106 existing tests and
all 78 old C comparisons independently before syntax implementation. The final
focused 78 callbacks pass in `validation/records-mutations-restored`:

| Boundary | New callbacks and evidence |
| --- | --- |
| Lex/parse/EBNF | 2 syntax +15 grammar: exact braces/literal/name/child/projection spans, mixed postfix, malformed braces/commas, contextual words and deferred layout/generics |
| Checker/rendering | 31: nominal identities, concrete and generic hints, var copies, source-order conflicts, error priority, exact kind/span/help/notes and record-child call-cycle rejection |
| Specialization | 5: concrete owner/position, generic identity and nested call requests, Int64 extrema, existing rejection of record payloads in generic unions |
| Lower/ownership insertion | 5: written order/exactly-once calls and receiver, unused initializer, aliases, precise Int64 values, last uses, unmanaged operations without acquire/drop |
| Independent verifier | 18: handwritten public OwnershipProgram using real producer-issued IDs; wrong owners/set/type/availability/result obligations, removed/empty/non-Int public layouts and pass-through classification |
| Emission | 2: nominal declaration-order layout, written-order designated initializer, by-value signatures/projection, portable extrema and no record heap/RC calls |

Eight ordinary native fixtures cover basic/reordered/second nominal owner,
alias/reassignment, generic function/mixed postfix with neighboring String
obligations, nested concrete literal contexts, unused extrema, and a flat
32-field record. Their normal TestSuite callbacks and one exact CLI diagnostic
plus output-preservation callback run in the final full-pilot gate. The wide
record grows a flat initializer, without accumulating structural nesting.

## Mutation proofs and host rough edge

Four temporary implementation mutations failed the intended callback(s): pin
concrete field owners to record 0; swap field positions; reverse literal lowering
order; omit record children from call-cycle observation. Exact patches,
original bytes and before/restored SHA256 maps are in `mutations/`; commands and
failures are in `validation/mutation-record-{owner,position,order,cycle}`.
All three source file hashes were restored exactly before the focused 78 passed.

The first lower last-use assertion used a nested tuple/list literal pattern.
A standalone host TestSuite reproduction prints bound values 2, 2, 3, 1, 2 but that
exact matching pattern fails (`host-pattern-reproduction.brp` and its recorder
packet). Binding the lists and comparing explicit expected values passes.
Integer assertions likewise bind/compare actual values. This isolated host
pattern issue is deferred; no host implementation fix belongs to this increment.
Initial test syntax/discovery/annotation-span failures and a measurement-reader
whitespace mismatch remain in their original packets; corrected runs are named
separately, with no erased gate results.

## Matched costs and identity

Original host SHA256 `f6d946861a5a07faa506cb598e0e64d8af0f89289551737b5e0dc42443554a8c`
built both the frozen baseline and measured candidate. The separately rebuilt
current host SHA256 is `494413b6febc7121aa8beeed10af0c16cf2acbaf6b692edbef960fae0e72ba05`.
Their generated final candidate C is byte-identical, SHA256
`03d05c4496aef8bae72f930543c9c3e6ea92cc6b1ae44789fca3d305b9ae05c2`.
Measured candidate binary SHA256 is
`695ab986527646278ed140926aaf0d4c4d5035646a04252b0b156fed9fbf2897`.
Both pilots link with `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`, Apple
clang 21. Snapshot/provenance are in `baseline/` and `candidate/`.

Three serialized samples per baseline/candidate old-workload pair plus three
per new fixture produce 90 rows in `costs/samples.tsv`. Direct shell loops,
`/usr/bin/time`, strict diagnostics and `cmp` provide the acceptance receipts;
awk produces `costs/summary.tsv`. Each same compilation
supplies both counters and C. Exact commands, time reports, empty stdout and
strict zero-leak diagnostics are adjacent. All78 old valid fixture C pairs are
byte-identical, recompiled in the final shell comparison with strict zero compiler leaks
(`candidate/identity/baseline-paths.txt`, `validation/records-old-c-identity-shell`).

| Old workload | Allocations baseline → candidate | Minimum retired instructions baseline → candidate |
| --- | ---: | ---: |
| return/zero | 690 → 692 | 30871699 → 30944101 |
| nested/calls | 1341 → 1343 | 32758059 → 32769716 |
| mortal_string/basic | 1039 → 1047 | 31900919 → 31947613 |
| generic/box | 2208 → 2214 | 35185921 → 35238144 |
| union/values | 3661 → 3668 | 39210111 → 39359584 |
| match/constructor_spine | 8738 → 8806 | 52927325 → 53146432 |
| generic/union_parameters/ok | 2268 → 2277 | 35437179 → 35475842 |
| generic/union_parameters/err | 2269 → 2278 | 35422180 → 35531865 |
| generic/union_parameters/third | 2306 → 2315 | 35656139 → 35700925 |
| generic/union_parameters/unwrap_or | 3257 → 3271 | 38106221 → 38195872 |
| generic/union_parameters/phantom_keys | 3755 → 3764 | 39611134 → 39724705 |

Maximum allocation growth is 0.778%; maximum minimum-instruction growth is 0.414%,
below the unchanged 10%/5% investigation stops. No performance exception is
needed. All new samples are below 10,000 allocations/100M retired instructions:

| New record fixture | Allocations | Minimum retired instructions |
| --- | ---: | ---: |
| record/aliases | 2076 | 34880457 |
| record/basic | 2035 | 34817900 |
| record/context | 2019 | 34775395 |
| record/extrema | 1585 | 33556639 |
| record/generic | 2629 | 36267396 |
| record/reassigned | 2169 | 35168763 |
| record/reordered | 2088 | 35090109 |
| record/wide | 6603 | 49009853 |

The maximum individual new-fixture sample is 49,095,360 retired instructions
and 6603 allocations, both below their unchanged ceilings. Minima above serve
comparison only. Earlier Python-orchestrated validation packets and raw folders
are preserved intact under `costs-superseded-python/` and
`candidate/identity-superseded-python/`; they are not acceptance evidence. The
final shell receipts rerun every sample and all 78 old C comparisons.

Target record operations need no heap allocation or reference counting; the
basic and nominal-layout C plus emitter assertions establish that separate
claim. The generic mixed-postfix fixture intentionally uses the existing String
runtime after projecting an Int.

## Size and final gates

Formatted physical delta relative to e553b5c04 is **+1402 production lines** and
**+2580 test/fixture lines**. Per-module counts are retained in `line-counts.json`:

| Production module | Net lines |
| --- | ---: |
| check.brp | +499 |
| check_render.brp | +104 |
| emit.brp | +76 |
| lex.brp | +5 |
| lower.brp | +53 |
| main.brp | +22 |
| own.brp | +85 |
| parse.brp | +174 |
| specialize.brp | +187 |
| syntax.brp | +23 |
| verify.brp | +174 |

The original +900 stop was invoked at the parser/checker checkpoint. Coordinator
and independent review approved +1250, then +1350, then final +1450 after inspecting
the required typed carriers/diagnostics, source/error order, Result loops and
independent public-layout checks. The downstream forecast underestimated that
growth. No scope, performance, formatting or coverage waiver was taken. The
verifier now directly classifies validated record definitions once, preserving
its diagnostic spans and the standalone classifier's independent validation.

The independent strict run passes 657 unit/grammar callbacks with ASan/UBSan
and leak checks. The first full `make -C blorp_2 test` passes 667
unit/runtime/grammar callbacks and 101 end-to-end leaves, with two end-to-end
leaf failures plus the outer wrapper (`validation/final-independent-full`).
All nine new record callbacks pass. The frontend floating-zero oracle still
expected the old call-only diagnostic; it now checks exactly
`expected a field or function name after '.'` at the same span.

The other full-gate failure is the historical `union_values` 40M ceiling:
40,111,881 instructions with 3668/4000 allocations. Cleanup baseline/final
measurements were already 40,031,543/40,052,080; an unchanged earlier gate failed
at 40,004,573 then passed at 39,920,129. Current matched minima are
39,210,111 → 39,359,584 (+0.381%), candidate maximum 39,382,264. Coordinator and
independent review explicitly approve only that fixture's instruction budget
40M → 45M. Its allocation cap 4000, all other fixture limits and the independent
10% allocation/5% minimum-instruction stops stay unchanged. This addresses
process-startup headroom; it is not a waiver for measured source regression.
The original failed gate remains retained. After these two reviewed e2e-only
corrections, the independent runner's
[final end-to-end packet](../../blorp_2/build/records/validation/final-independent-e2e-corrected/metadata.json)
passes **104/104** (103 leaves plus wrapper), exit 0 in 48.191 seconds, with empty
stderr and no ASan/UBSan or leak failures. All nine record callbacks pass;
union_values uses 39,990,981/45M instructions and 3668/4000 allocations.
Source stayed unchanged during the run; generated compiler C remains
`03d05c4496aef8bae72f930543c9c3e6ea92cc6b1ae44789fca3d305b9ae05c2`.
The [strict657/657 packet](../../blorp_2/build/records/validation/final-independent-strict2/metadata.json)
and normal 667/667 unit/runtime/grammar portion of the first Makefile gate are
reused unchanged, since only e2e tests and docs changed afterward. This is
component-wise completion; the first Makefile invocation's overall failure is
preserved, not relabeled as a passing run. All required components now pass.

The separate host timeout-zero fix has independent 25/25 tests, a fresh
integrated host and its own navigator `build/records/timeout-integration.md`.

The first independent strict run failed before callbacks because the existing
lexer trace observer omitted the new LeftBrace/RightBrace variants
(`validation/final-independent-strict`). Adding those two trace arms and a
direct exact brace-token/span callback is a test-only correction; its narrow
suite passes 21/21 (`validation/records-lexer-observer-green`). This adds ten
test lines after the retained build-time snapshot. Final hashes for the lexer
observer and the two later e2e-only corrections are in
`final-test-observer.sha256`; all compiled production inputs are unchanged.
Later plan/report status updates are documentation-only. The original snapshot
and provenance remain intact.

Recommendation: accept this bounded feature. The pilot now has an explicitly
typed unmanaged product type, independent identity/order/verifier oracles,
unchanged old C, strict leak/sanitizer coverage and measured costs within its
investigation thresholds. Independent compiler/code review approves the final
source, tests and documentation with no remaining findings. Scoped formatter
checks pass for all 31 changed host modules
(`validation/final-scoped-format`); raw pilot fixtures are excluded.
No commits or pushes were made.
