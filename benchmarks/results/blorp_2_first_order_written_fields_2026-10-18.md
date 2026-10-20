# First-order written record fields

One private typed `translate_record_fields` loop replaces the callbacks for
literal fields and written update replacements. It calls the unchanged child
in authored order, appends successes, stops at the first error and publishes
only a complete list. Field-ID lookup still precedes child translation; updates
retain owner/base/replacements/inherited-field order and checked spans.
Six `translated_list` callers and its function-typed parameter remain.

Production is **29 added / 12 deleted / +17 net**; tests are
**47 added / 1 deleted / +46 net**; fixtures are unchanged. This consumes the
existing 50/+40/60 slice reservation inside the combined SOURCE ceiling;
neither allowance is renewed. No context bag, cache or new public API was added.

## Frozen comparison and correctness

Fixed accepted B is `47c008b8df15d0b19f3498a32b1a5f06e9e6016e`.
C adds only production patch
`2589b3e57e71463c51a24cd6be82efec4873664a9dbc451472ca4e241ece83b8`
and test patch
`455f6bcf31a508f4204a7eff77b7e2cc294e827121b52da2f3dfa660f3974312`.
Current functional base `54151a623` and destination `543e1d5fd` differ from B
only in documentation. Both complete variants contain 41 compiler modules and
10 identical target-library files, including README. The frozen corpus has
503 shared invocation states, 478 physical fixtures and 150 generated dependencies.

Original characterization belongs to actual `6e6c3fb` composition: baseline and
candidate passed all 13 owning callbacks. Reversing written order produced three
semantic failures; omitting a field produced six; shifting a span produced one.
Every exact byte/mode restoration returned 13 green. The added Triple update
checks replacement ordinals [2,0], inherited middle ordinal 1, full-width MAX/MIN
values, concrete owners/types and exact authored/value spans. All old callbacks
remain. Historical per-call standard-library pins covered 83 of 91 modules;
the retained recursive correction establishes later correspondence without
claiming retroactive nested-module checks. First-error propagation is directly
reviewed, with no public-boundary mutation oracle or forged sealed input.

Independent current-host acceptance uses the fresh repository c04 binary and
explicit recursive 91-member root standard library. Owning focus passed 13/13;
full unit/runtime/grammar produced 3,376 named PASS lines, no failures and 283
suite summaries. Full e2e passed 478 fixture/group callbacks across 45 groups,
581 nested native callbacks and one umbrella callback. Both full test gates exited
zero with empty stderr; instruction checks, strict zero-leak checks, existing caps
and ASan/UBSan real-main execution stayed enabled. All 976 input/tool pins and
the generated compiler C/binary remained unchanged.

Current-host generation and the diagnostics-enabled O0 link also passed.
Its 89 warnings equal the older SOURCE setup's 90-warning sequence with exactly
one old-library Char-scan parentheses warning removed, with no additions or
replacements. This compares different producer/library pairs and supplies no
candidate warning-improvement claim. All raw warnings are retained.

## Matched SOURCE costs

The original SOURCE producers remain normal `34ac1a91` and diagnostic `be31a5a3`,
with explicit original 91-member standard-library tree `090ed68c`. Their removed
worktree was recovered to a different physical prefix from exact retained
payloads: all 598 hashes were independently verified, including reconstructed
embedded-standard-library bytes. Recovery ran no compiler/generator or host
rebuild; the generated file's recovered 0644 mode is not historical mode proof.
The missing-path failure and original receipts remain intact. Functional c04
and SOURCE producer roles were never substituted.

Exactly one candidate generation and two clang O0 links preceded **4,032**
quiet cost calls: eight SOURCE proxy, 1,006 strict pilot and 3,018 normal pilot
calls. B reuses artifacts whose complete source/library inputs equal fixed B;
old measurements were not relabeled. There were no retries, refreezes, baseline
rolls, reduced inputs or changed caps/collectors.

| Measure | B | C | Change |
| --- | ---: | ---: | ---: |
| SOURCE construction-checkpoint allocations | 24,251,287 | 24,252,850 | +0.006445% |
| SOURCE normal min3 retired instructions | 21,573,859,757 | 21,578,006,457 | +0.019221% |
| Maximum per-input allocation change | — | — | 0% |
| Largest input instruction increase (`m2-carried_swap-absent`) | 45,888,012 | 46,708,233 | +1.787441% |

All 503 states separately pass the independent +3% allocation and normal min3
instruction limits and every applicable absolute ceiling. All 1,006 strict
observations have positive balanced allocations/releases and zero leaked objects
or bytes. Status, stdout, complete diagnostics, raw fixture C and absent/preserved
output states match B/C exactly. Normal order is B1/C1/C2/B2/B3/C3; each sample
matches its own strict oracle. Every proxy output matches its own setup C.

SOURCE allocation counts come from the unique schema1
`artifact_construction_complete.total_allocations` checkpoint with memory stats
enabled and leak mode unset, not FEATURE's exit TOTAL. These are host-based
self-compile proxies. The original host leak limitation grants no pilot/native
exception and this work proves no self-compilation or universal speedup.

Historical sorter R0 9,634 → 10,166 exceeded 9,923 and remains **FAILED**;
its local 10,178 → 10,166 observation is separate. The published fixed-B policy
governs this slice. No fresh cumulative R0 compliance was measured or inferred.

## Evidence and reviews

Complete setup, fixed inputs, commands, streams, raw samples, source/library
snapshots and original characterization are preserved under root-checkout
`build/bootstrap-evidence/written-fields-fixedB47-2026-10-18/`, with an explicit
original-path correspondence manifest, SHA256
`5055f132b179ea9bc4d362221c888360f5143cb9170180fb5220ed2feb42bc36`.
Root independently re-read all 26,037 original/archive payload pairs and verified
their hashes, modes and sizes. Exact SOURCE host recovery lives beside it in
`source-host545-recovered-2026-10-18/`.

Independent current full-functional and closing cost review is retained in
`written-fields-current-full-acceptance-2026-10-18/RECEIPT.json`, SHA256
`82d08022c0048dd240ab1ba2dcd55dcb1c7477216462062df5cd3d48b019b65b`.
The separate current focus receipt is in
`written-fields-current-focused-2026-10-18/`.
Root and an independent compiler reviewer approved source semantics, generated
C, characterization limits, producer roles and all individual cost bounds.
The [historical plan](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/FIRST_ORDER_WRITTEN_FIELDS_PLAN.md) retains
the prospective design and ceilings; the
[callback ledger](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/REMAINING_CALLBACK_LEDGER.md) charges actual spend.
