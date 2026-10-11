# Nested temporary projection ownership repair

The host compiler retained the result of `match make().first.kind` twice and
released it once. The defect was already present at pilot baseline
`1a8c373904d89efa65e3e9cbd06769e28a55b7f0`; it caused five existing pilot unit
callbacks to fail their per-test leak checks. The pilot tests are unchanged by
this repair.

## Ownership boundary

`stage_09_core/perceus/results_and_loops.brp` now materializes the complete
projection before deciding whether its binding needs an alias retain. The
existing `MaterializedBorrowedTemporary` carries both the resulting expression
and its ownership status. An already-owned child needs no second acquisition;
a borrowed child still needs one. Both cases preserve the materialized
expression and its temporary-parent cleanup.

The change is six net formatted production lines. It adds no data model,
backend compensation or pilot workaround. Five Core tests check ordered child
acquisition and parent release at depths one through three, a borrowed-root
control, and unmanaged-leaf cleanup. Eight runtime tests use a mortal String
and check actual allocations, destruction and per-test leak freedom. Test
growth is 342 lines (209 Core and 133 runtime), reported separately from production.

## Behavioral evidence

Artifacts are under ignored `blorp_2/build/host-projection-repair/`.
`implementation.md` links the exact commands, packets, hashes and Core/C
locations. Only stable packets are acceptance evidence.

| Check | Before | After |
| --- | --- | --- |
| New strict runtime suite | 4/8 pass | 8/8 pass |
| New Core callbacks | 3/5 pass | 5/5 pass |
| Existing strict pilot tail suite | Five leaking callbacks | 31/31 pass |
| Frozen strict pilot unit set | 810/815 pass | 815/815 pass |
| Complete owning Core suite | 461/465 pass | 463/465 pass |

Restoring only the old normalization branch makes the new depth-two and
depth-three Core callbacks fail again. The fixed source is restored byte for
byte afterward. The runtime destruction oracle requires active counters, at
least five real parent/union/String allocations, equal releases and zero live
objects after the helper returns. Named and borrowed-root controls also pass.

Generated C and after-Perceus Core show one final-child acquisition followed by
one match release, with each temporary parent destroyed. The old extra outer
acquisition is absent. The C emitter faithfully consumes the corrected Core.

Two unchanged Core assertions fail before and after: `multi owner conditional
call argument is retained once` and `existing drop preserves nested consuming
call retain`. They concern a separate consuming-call normalization path. Their
cause remains unresolved; these results do not establish a fully green host
Core gate or justify treating those assertions as harmless naming drift.

## Matched whole self-compilation

The preset investigation ceiling was 1% growth in whole self-compilation
allocations and retired instructions. Both variants compile the same frozen
compiler/standard-library input at revision `1a8c373904d89efa65e3e9cbd06769e28a55b7f0`.
The standard `benchmarks/build_stage2_compiler` builds each normal/diagnostic
pair from one generated compiler body. `benchmarks/self_compile_measure` runs
one diagnostic allocation sample and three normal instruction samples per
variant. There is no concurrent compiled workload. Apple Clang 21 builds the
compiler body at `-O0` and runtime at `-O2` for both variants.

| Whole compilation | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 289,669,920 | 289,735,399 | +0.0226% |
| Retired instructions, median | 564,437,195,421 | 564,718,738,882 | +0.0499% |
| Emitted C bytes | 86,906,626 | 86,906,422 | -204 |

These measurements pass the ceiling and make no speed-improvement claim.
Normal and diagnostic outputs match within each variant. The cross-variant C
diff contains only two redundant nested String retain wrappers removed by the
repair; see `self-compile.diff`. Raw samples and provenance are in
`baseline/self-compile.json`, `candidate/self-compile.json` and their build logs.
The measurement tool labels externally supplied compilers as stage 1; the
stage-2 builder receipts and `compiled_by: self-*` fingerprints establish their
actual construction. The different `self-*` generator stamps are expected;
both stage-1 generators use the same pinned bootstrap and frozen build inputs
apart from this repair. The baseline generator's `b83ef1d767d8` version stamp
predates its verified content: it was FRESH before freezing. The 529-entry
baseline/candidate host source inventories differ only in the repaired
`results_and_loops.brp`; the other 528 entries match exactly.

Stage-1 generator SHA-256: baseline
`8d9c5a7b33b2fc4203f90d14b671cfead8ba63b5b3b4f645142015645683ad66`, candidate
`8a8af4e853a7835257c8cc0027546ab105c41a917837f2e1d02cc63ab79ea26a`.
Stage-2 normal SHA-256: baseline
`5360709c14bce3233fcbc265520882674788098997d7212dc049844a92bc774a`, candidate
`20a885d5b5a3d067e5773ada5ca3754cdc4477eb12cb9a3753ccce0ca64328e9`.
The frozen excluded-host diff preserves four unrelated drafts unchanged.

## Review and remaining gates

An independent compiler expert reviewed the ownership authority, exact Core/C
transitions, regression oracles, source restoration and stable packets, with no
remaining source/test findings. An independent test runner audited the frozen
815-unit, 31-tail-test and eight-runtime-test receipts and their hashes.

`scripts/compiler-fixpoint` passes: stages 1, 2 and 3 emit identical C, SHA-256
`608685bf1fc25c3ff3259a81ffd87b8a4f4d54816b39dc6be5fcf10300716dc0`.
Its generated inputs are the frozen host source set, including the repair and
the preserved unrelated drafts; concurrent pilot edits are outside that input
set. Full stage logs and outputs are in `fixpoint.log` and `fixpoint/`.

The independent `compiler-core-sanitize` gate compiled successfully and passed
364 callbacks, then its native batch program exceeded the existing 180-second
execution limit. The recorder's 300-second deadline did not expire and its
worktree fingerprint remained unchanged. The runtime sample repeatedly enters
`cancellation_plan.analyze_current_behavior_expr`; source inspection finds
descendant protection lists concatenated at each enclosing Let, implying
quadratic row copying on a binding chain. The likely active callback is the
preexisting depth-4096 backend stress test, inferred from suite order and
completed counts rather than an explicit callback-start event. Its source is
one of the preserved unrelated drafts. No baseline execution reproduction has
yet established attribution. This is a native execution timeout, distinct from
the earlier host backend compilation stack failure; no stack-overflow diagnostic
was observed. The packet and sample are retained in
`independent-core-sanitize/`, with bounded follow-up details in
`cancellation-timeout-diagnosis.md`.

Broad sanitizer acceptance remains unresolved. The leak gate, generated-C audit,
and final expanded pilot gate are pending. Managed-union work proceeds as a
separate pilot change and must receive its own validation and review. No commit
or push is part of this report.
