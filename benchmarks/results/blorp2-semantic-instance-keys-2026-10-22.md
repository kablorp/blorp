# Semantic specialization identity pilot

Qualification: matched cost gates, full fixpoint/native proof, complete
components, original-fixture CLI parity and whole-source strict/sanitizer checks
passed. This report describes isolated T2 on published
T0 `0371282326638ad83e01bccd6c6f81095e119fdd`. It includes no T1 traits.

`KnownCallable.arguments` and `InstanceKey.arguments` now retain fully substituted
checked types. Behavior instances distinguish opaque A, opaque B and Int, while
repeated identical requests reuse the existing function-request graph. Record,
union and callable capture layouts retain their physical sharing keys. Semantic
substitution uses the existing declaration-owned substitution, then projects to
physical layouts only where needed; there is no second callable registry.

The original policy produced 2 passes and 4 intended failures in the six-case
opaque-type owner. The candidate passes all six and the complete prepared
specialization/source-tree selection: 316 callbacks, including parsing all 43
compiler source files. The cases cover direct opaque calls, repeated requests,
physical aggregate sharing, stored generic named functions, and a shared lambda
site with opaque captures and forwarded callable choices.

## Matched cost result

The reference remains the original pre-T0 compiler/source
`02b13d25d04b7c5670cb94052ea9675cc9ba3428`, preserved under
`build/traits-implementation-2026-10-22/baseline/`. These are cumulative T0+T2
comparisons against that reference, not isolated marginal T2 costs.

Both roles compile the identical frozen original source/library at `-O0`, using
ordinary Make-linked binaries with memory diagnostics 0/1. They share the same
physical Root working directory, private environment digest, resolved Xcode
clang, closed stdin and physical output path
`build/traits-implementation-2026-10-22/T0-qualification/measured.c`.
Every sample begins with that path absent and retains its output separately.

| Metric | Original | T0 + T2 candidate | Change |
| --- | ---: | ---: | ---: |
| Strict allocations/releases | 30,981,091 | 31,165,401 | +0.594911% |
| Minimum of three retired instructions | 911,693,098,533 | 913,502,700,198 | +0.198488% |

Both strict calls report positive balanced allocations/releases and zero leaks.
Normal calls ran once in the fixed order P1 C1 C2 P2 P3 C3. All eight calls
preserved their guards and exact prospectively frozen role-specific C outputs.
Both costs remain below the T2 +2% investigation trigger and the unchanged whole
feature +5% ceiling. No additional batch or elapsed-speed claim is made.

Original output C is `276cdc4811404c6949da747a6099acbd124fc54da7b5c582348027709864dbc0`;
candidate output C is `38374a2178e4b5016f8cf6d18015700993eb8c32fc7749bb1f79cc87921b122d`.
The latter was frozen in one separate unmeasured correctness preflight before
sampling. On this old input, dense language function definitions increase from
2,574 to 2,605 (+31), and C increases from 19,169,976 to 19,191,000 bytes
(+21,024). These are not counts of retained specialization rows or live memory.

The pinned seed generated current-source compiler C
`819dfab001752ef679af90076d6967c5ee84eedd4d4980832ad92f768ada4ed0`
(19,311,482 bytes, 2,586 dense definitions). That separate seed-produced artifact
supplied the measured candidate binaries; it is not the candidate's emitted
frozen-input output. Root's subsequent official current-version proof passes with
A/B/C source C all
`54afe80092e184732488915fba4fee0daa9f35e21e3fd95f2f76824ad850b554`.
All 582 fixture C/diagnostic contracts agree under A and B, and the stage-B native
suite passes 585 cases with zero failures. The guarded proof exits 0 in 799.6 s.
These are same-version results, separate from original-versus-candidate parity.
Complete components pass 4,376 hosted and 188 target callbacks. All 27 target
strict reports balance with zero leaks. The actual B and an ASan/UBSan build of
the unchanged source C each compile the whole current source with 31,416,068
balanced allocations/releases, zero leaks/bytes and identical C, without sanitizer
diagnostics.

The broad native gate retains its allocation-debt policy and disables fixture
instruction checks; those instructions are unmeasured. There are 118 explicit
allocation FAIL/debt rows: 117 preexisting rows and one new row for the 20-level
`generic/managed/deep.brp` fixture. Its compiler uses 188,186 allocations versus
the unchanged 180,000 cap (original 170,097; T0 170,396). Original, T0 and T2
emit identical 51,808-byte C with 43 function definitions for that fixture.
This localizes the extra cost to processing nested generic types, rather than
increased emitted instances; semantic substitution and physical projection are
the next profiling boundary. The coordinator accepts this bounded debt under
the owner's standing allocation-debt direction, preserving the cap and FAIL.
It does not replace the separate measured whole-feature cost gates above.

Original-versus-candidate CLI comparison covers all 581 fixture paths from
`02b13d25`: 486 accepted and 95 rejected, with identical exit/stdout/stderr.
Every fixture and all 14 target-library files match the original Git blobs.
The retained original proof has actual compiler C `276cdc...`, 581 same-version
fixture contracts and 584 passing native checks. Its recorded HEAD differs
from `02b13d25`; actual C identity to the frozen baseline is the authority.
The 584 original native contracts are unchanged; the current 585-case gate adds
T0's sibling-inference case. This is unchanged-contract native qualification
plus explicit paired CLI comparison, not a fresh paired native execution.

## Scope

Handwritten production changes are 172 additions / 162 deletions, net +10.
Tests are 166 additions / 20 deletions, net +146. The policy deliberately trades
some function sharing for semantic identity; it is a prerequisite pilot, not a
claim of an existing-language miscompile or a performance optimization.

Independent code-reviewer and test-runner approvals of the exact final packet
are required before committing. No trait bounds, defaults, derivation, dispatch,
or below-Specialize machinery is
introduced by this slice.

Raw authority: `build/traits-implementation-2026-10-22/T2-qualification/`
contains `COST_INPUTS.json`, `MEASURE.py`, `STRICT_PAIR_REVIEW.json`,
`COST_RESULT.json`, independent collector/result reviews and all cost samples.
The isolated worktree's `build/traits-T2/` retains `source03/`, genuine red/setup/
green evidence, `PINNED_SEED_RESULT.json`, `BUILD_AND_PREFLIGHT_RESULT.json`
and `SOURCE03_COUNT_AMENDMENT.json`. Root's full-proof result and streams are in
`build/traits-implementation-2026-10-22/T0-qualification/T2-full-fixpoint-v1/`;
its stage images/provenance/fixture contracts are under `blorp_2/build/fixpoint/`.
The same T0 qualification directory retains `T2-components-v1`,
`T2-self-strict-v1`, `T2-sanitizer-link-v1`, `T2-self-sanitized-v1` and
`T2-original-cli-parity-v1`. Original proof artifacts remain under
`T0-qualification/preserved-prior-fixpoint/`; the T2 qualification directory's
`old-input-parity/` retains the exact Git input inventory and CLI outputs.
Original detailed paired-link stdout was
not separately retained; its original role hashes, flags and coordinator witness
are recorded. Candidate paired Make links have retained commands and streams.
