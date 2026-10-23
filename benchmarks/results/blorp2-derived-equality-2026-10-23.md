# Nongeneric automatic equality

T4a supplies canonical Equatable for nongeneric named records and unions through
ordinary checked templates and the existing specialization request graph.
Written implementations take precedence. Actual fields and logical payloads,
including erased Void positions, determine availability; unavailable declarations
remain legal until equality is used. Automatic capability introduces no operation
names: method families still require ordinary imports. Generic automatic equality
remains T4b; production-library rollout remains T5 and requires a capable seed.

The candidate is based on published T3 `42eb544f361dcdf6bdcf1691ba0c3dd382c1a762`.
No trait-specific product reaches lowering, ownership, verification or emission.
The implementation normalizes the accepted canonical contract into a genuine
aggregate body owner, closes recursive eligibility before publishing supported
rows, and selects ordinary reachable bodies. A closed receiver's default maps
Self to its actual ground type; generic receiver families retain symbolic Self.

| Changed lines | ADD | DEL | Net |
| --- | ---: | ---: | ---: |
| Production | 677 | 86 | +591 |
| Tests | 1,497 | 19 | +1,478 |
| Isolated fixture library | 96 | 0 | +96 |

Cumulative production growth is +2,749 lines. T4a exceeds its +500 investigation
trigger and remains within its reviewed +750 slice ceiling (+2,908 cumulative).
The lines own aggregate identity, ordinary templates, conditional availability,
precise use-site errors and consumer migration; coverage was not removed or
compressed to meet the envelope.

Current qualification passes the full hosted selection: 4,481 checks, followed by
three late UFCS publication controls. The target-only selection passes 188 checks
in 27 closed suite frames, with 27 positive balanced strict reports and no other
diagnostics. The same-version full proof produces identical A/B/C compiler C,
compares all 582 fixtures byte-for-byte under A/B, and passes 601 native behaviors.
It retains 119 inherited allocation-debt rows; all four new derived fixture caps
pass. Recorded inherited debt is not a complete resource PASS.

Phase controls cover genuine owners, nested authored False dispatch, canonical
absence/distinct identity, generic deferred use, recursive poison in both member
orders, defaults/callables, logical Void positions and request reuse. The
three-field template assertion checks declaration order, False termination and
True continuation. An unused callable payload poisons union equality even when
only a payloadless variant is compared. Record templates with 4/16 fields have
12/48 decision nodes; union (variant,payload) counts (2,2), (8,9), (1,2) give
15,66,8 nodes. Repetition at 1/16/64 uses one derived request and four reachable
bodies. These are structural controls, not timing claims.

The fresh current proof passes all nine maintained isolated callbacks. Four real mains cover
NaN self-inequality, tag discrimination, authored Void False in record/union
positions, conditional families, recursive ground List/Tree/mutual values and
callable paths. Written List equality uses one length/get index walk. Five
ordinary-input mutations each caused the named wrong-main failure under the
historical candidate02. Source06 compiler-copy faults broke the short-circuit
and unused-variant assertions. These faults were not rerun against candidate03:
the protected template, eligibility, test and native boundaries were audited
unchanged. Fresh current proof/native qualification is separate. Native tag
vectors are covered but were not independently mutated. Raw setup failures and
their zero-credit classification remain in ignored evidence.

Matched costs use the frozen Original `02b13d25d04b7c5670cb94052ea9675cc9ba3428`
source/library and preserved Original and candidate03 roles, O0, diagnostics
macros 0/1, one strict pair, then normal P1 C1 C2 P2 P3 C3. Both roles use the
same physical workload/output paths, toolchain and private environment. All eight
calls passed with stable guards and exact role-specific C outputs.

| Metric on frozen Original input | Original | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations, balanced with zero leaks | 30,981,091 | 31,181,082 | +0.645526% |
| Retired instructions, minimum of three | 911,675,429,035 | 915,149,192,354 | +0.381031% |

Both measured changes are within the unchanged cumulative +5% ceilings. This is
process-local retired-instruction evidence, not a controlled elapsed-time claim.
The frozen-input C differs intentionally: Original `276cdc48…`, candidate
`38374a21…`. Candidate03's seed-generated C is `49fb3102…`; the separate current
source fixpoint is `0d12c2441150582ff78e40e762d923493f781bf9d019946cb81b5eb9aba54830`
(21,182,525 bytes). Normal and diagnostic candidate03 roles link the same
seed-generated C; that producer C is not the current-source fixpoint output.

Whole current-source execution passes both ordinary strict and ASan/UBSan strict
runs with exactly 34,397,816 allocations/releases, zero leaks, no other diagnostics
and identical current-source C. The sanitizer link is quiet. Isolated ordinary
CLI parity passes all 46 calls: each of A/B has nine accepted and 14 rejected
cases; accepted C bytes agree, and rejections have exact status/streams and
preserve the required output absence or sentinel. These cover the retained
concrete/bounds fixtures as well as derived cases outside the normal fixture scan.

T4a's local qualification is complete, with independent source and matched-cost
reviews. T4b's deep generic-field admission and T5's production foundation/library
adoption remain separate open work; the default library still uses its existing
seed-compatible APIs.

Raw source/reviews, Make provenance, phase controls, native samples and mutations
are retained in the implementation worktree's ignored `build/traits-T4a/`.
Fresh proof/components/hosted results are under Root's
`build/traits-implementation-2026-10-22/T0-qualification/`; matched inputs,
collector, samples and `COST_RESULT.json` are under its
`T4a-publication-qualification/`, including `COST_RESULT.json`,
`FINAL_COST_INDEPENDENT_REVIEW.json` and `isolated-cli-parity/RESULT.json`.
Current-source memory evidence is in `T0-qualification/T4a-publication-self-strict-v1/`
and `T4a-publication-self-sanitized-v1/`. Earlier source06 results are historical
and do not replace these fresh publication-corrected results.
