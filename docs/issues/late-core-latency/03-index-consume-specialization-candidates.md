# Finish The Consume-Specialization Candidate Index Gate

**Status:** An ordered pass-local index is implemented on `main` and improved
direct-pass latency. The 512-candidate allocation increase was 11.2%, above
the original 2% guard; the 1,024-candidate/1,024-call, peak-memory, and
allocation-reduction gates remain open. Combined compiler-self improvement
also contained an independent typechecking change, so it is not attribution
to this pass. See the [retained pairs](../../../benchmarks/results/compiler_optimization_round2_2026-09-13.md).

**Current state:** `stage_09_core/consume_specialize.brp` discovers candidate
parameters in declaration/parameter order, reserves a clone definition ID
for **every** candidate, rewrites eligible calls, discovers used clones, and
emits only used clones immediately after their originals. The implemented
index removes repeated broad scans; the remaining question is whether its
index-build and retained-storage cost can be reduced without losing that win.

**Next action:** Reproduce current-main allocation and peak-memory results on
the retained direct-pass fixture, including zero candidates and
1,024 candidates/1,024 calls. Attribute the extra allocations before editing
production code. Make one bounded change only if it reduces the measured
cost without restoring candidate scans.

**Read first:** `blorp/src/compiler/stage_09_core/consume_specialize.brp`,
`blorp/test/compiler/stage_09_core/test_core_consume_specialize.brp`,
`benchmarks/compiler_consume_candidate_index_profile`, and the retained
benchmark result.

## Objective

Close the remaining consume-specialization candidate-index gate by reproducing
and reducing the accepted implementation's allocation and peak-memory costs
without restoring repeated candidate scans or changing clone semantics.

## Invariants

`CloneKey` includes original name, original definition ID, and argument
index. Candidate type equality also matters. Synthetic fixtures allow equal
numeric IDs on differently named originals; an ID-only scalar map is not an
equivalent key. Original-ID collision buckets must preserve remaining
name/type predicates and the existing last-exact-target rule. Clone-call
recognition retains its first exact clone-name/ID rule. Generated clone IDs
are allocated monotonically and validated as unique.

Discovery, clone-ID allocation, retargeted calls, used-key deduplication,
clone placement, terminal drops, recursive transfer, and diagnostics must be
unchanged. Unused candidates still consume reserved clone IDs; do not compact
them after usage discovery or order output by a dictionary.

## Fast Loop And Acceptance

Run the direct production-pass benchmark with zero/sparse/dense usage, one
and many cloneable parameters, collisions, and independently scaled candidate
and user-call counts. Every timed iteration rewrites the **original** Core
input, not its prior output. Compare candidate ordinals inspected, index
builds, allocations/releases, retained objects/bytes, peak RSS,
instructions, elapsed time, and exact semantic checksums. Keep output order,
clone IDs, Core JSON, generated C, and ownership/drop shape byte-equivalent.

Accept a follow-up only if unrelated candidate count does not raise inspected
ordinals **per lookup** after index construction, and the 1,024-candidate /
1,024-call case has at least 90% fewer candidate inspections and 20% lower
median latency than the scan baseline. Retain at least a 5% median direct-pass
gain on the production-shaped fixture and a fast zero-candidate control.
Focused allocations and peak RSS must meet the original guards (at most 2%
and 1% regression, respectively). Run focused Core, compiler-owned, sanitizer,
and leak gates. If reducing index allocation sacrifices the latency win or
semantic precision, keep the accepted implementation and document the measured
trade rather than broadening this issue.
