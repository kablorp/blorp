# Discarded results acquire ordinary lexical owners

Non-final expressions and wildcard assignments now give every non-Void result
an ordinary immutable local owner before Perceus. The owner's body is Void;
the continuation stays outside it. Existing ownership contracts and Perceus
alone decide acquisition and destruction. No backend ownership classifier,
runtime rule or separate traversal was added. The preceding
[mixed-Drop repair](compiler_drop_mixed_alias_2026-10-16.md) is a prerequisite.

## Scope and regression oracles

The incremental feature changes two production files: 66 added / 36 deleted,
**net +30**. Tests add **448 net lines**, within the reviewed 450-line ceiling.
Including the prerequisite, totals are **+39 production / +612 tests**. Test
growth includes adapting the existing pass API callers; no baseline coverage
was removed to meet the ceiling.

The existing product-evaluation pass now consumes and returns CorePassState.
It reserves binder identities once and carries the existing node allocator and
origin authority. New Void nodes have fresh identities, not copied RHS source
locations. Tests preserve existing allocator state and cover repeated locations,
literals, Void, wrappers, and N16/32/64/128 constant-body discard spines.
These spine tests establish shape and identity, not allocation scaling.

Granular emitter tests check exactly one producer evaluation, the owned result's
single release, borrowed-result acquisition, and ordering. Omitting disposal,
omitting borrowed acquisition, and duplicating disposal each fail their intended
callbacks; exact source restoration passes. Separate Float/Float32 SIMD
callbacks reject omitted and duplicate disposal. The generated-C audit retains
frontend kernel-dispatch checks and now expects a named result binding rather
than the obsolete nested call/release spelling.

The native regression covers inline and called Option/String results, wildcard
discards, returned and parameter aliases, tensor projections, both mixed branch
selections, static values, scalars, Void and both SIMD widths. Each callback
requires active memory counters, expected producer calls, real heap allocation
where applicable, balanced allocation/release counts and zero live objects.
The producer counter does not count SIMD execution; the audit and emitter tests
provide those dispatch and call-count facts.

| Correctness receipt | Passed | Failed |
| --- | ---: | ---: |
| Six owning suites | 1,004 | 0 |
| Core ASan/UBSan before the final two SIMD callbacks | 2,661 | 0 |
| Final emitter suite under ASan/UBSan | 411 | 0 |
| Final native regression under ASan/UBSan and leak checking | 14 | 0 |
| Generated-C audit | 241 | 0 |
| Leak gate | 1,284 | 0 |
| Compiler Blorp suites | 7,235 | 0 |

Counts overlap; these are separate receipts, not a unique-test sum. Production
is identical across them. The final emitter and native runs include the added
SIMD controls. The audit subsequently changed only its explanatory comment.
The earlier audit failure is retained: its obsolete nested-call spelling was
replaced only after the precise phase tests rejected both disposal mutants.

The fresh O2 fixpoint passes: all three stages emit identical C, SHA256
`fd7ae44f1770d53a48212d4d6058da1f4b74e14213b9b276a0ba2dc100e7df7d`.

## Cumulative matched O2 costs

The baseline remains `4f2bd4bc77410aac3422ae5f4d2bc10ce6ddc234`, before both
ownership repairs. Candidate source was `8ead9965f0f8839cc846d476b3ea3634976f6588`
plus the reviewed discarded-result production patch. Later plan and test-only
changes preserve the measured production bytes. Frozen workload revision:
`6211caf3b88cc6fa8439c1c3943f9c5893649dba`.

Both checkouts used bootstrap pin `dev-0e1598ed616e`, Apple Clang 21.0.0
(`clang-2100.3.34.2`), arm64, CLI/runtime O2 and matching normal/diagnostic
stage-2 compilers. Each workload has one diagnostic allocation run and three
normal instruction samples. Normal and diagnostic C agree within each pair.

| Workload | Baseline allocations | Candidate allocations | Baseline minimum instructions | Candidate minimum instructions |
| --- | ---: | ---: | ---: | ---: |
| Frozen self-compile | 289,858,552 | 289,897,635 | 271,348,249,113 | 271,404,528,591 |
| Small program | 1,755,591 | 1,755,630 | 1,652,586,215 | 1,654,020,072 |

Self-compile allocations increase 0.013483% and instructions 0.020741%.
Small-program allocations increase 0.002221% and instructions 0.086764%.
Both independently satisfy the unrounded integer ceilings:
`C_alloc * 1000 <= B_alloc * 1001` and
`C_instructions * 200 <= B_instructions * 201` (+0.1% / +0.5%).

All normal instruction samples are retained, in execution order:

| Workload | Baseline | Candidate |
| --- | --- | --- |
| Self | 271348249113, 271599576861, 271615145588 | 271404528591, 271590427472, 271542294746 |
| Small | 1687916827, 1653065383, 1652586215 | 1687233092, 1654020072, 1656329559 |

Small-program C remains identical, SHA256
`2033e2664146c6d016466cdcada9d1f3e07724743d656f770b7656aeeecb3f96`.
Self-compile C grows by 834 bytes (86,734,542 to 86,735,376).
Reserving new shared binder identities renumbers temporaries across the program;
the complete 405,157-line raw diff is retained. It was not normalized, and is
not claimed to contain only name changes. Review inspected the natural-main
reproduction and relevant alias/cleanup regions. Behavioral gates and fixpoint
are separate evidence from that inspection.

Carrying CorePassState through origin appends could impose COW costs. The
whole-workload measurements are within budget; neither they nor the shape tests
prove asymptotic origin-construction costs. No speculative allocator or cache
was added.

## Provenance and reproduction

The unchanged candidate stage-1 normal binary is
`c01a2d84b30aa1e8fb204d35e28c455b2ba92ebaefcad632975fe1c3109dd4e7`.
The stage-2 normal / diagnostic pair used for both candidate workloads is
`eb61cc59edc33049516cb75372ab5c847d5bace08e4d3309761ca7b583d17374` /
`32b13cb7a9bbe65758f19fdaa31ee0a7d7ed8ab93bb4f7ae55e7b35307106551`.
The baseline stage-2 pair is
`ea13e7ef8a0b326ddca54ef80bee1db43a631c9ea5d67a186114e0990dbe2e05` /
`3ce1515fa2c3775e83fcafdcf0767780bf4579b77743a5c90b23c936e82d22b1`.

Export `BLORP_CLI_C_OPTIMIZATION=-O2` for the entire sequence. Build each source
with `make`, require FRESH status, and run
`benchmarks/self_compile_measure --stage2 --samples 3 --input-rev
6211caf3b88cc6fa8439c1c3943f9c5893649dba` for both `--program self` and
`--program small`, saving JSON and full C. Compare the exact integer caps above;
the harness does not enforce these task-specific caps. Keep compiled work serial.

Raw candidate costs, complete output and archived binary pairs live under
`/Users/keithphilpott/.codex/worktrees/8d2a/blorp/build/host-discarded-combined-costs-6211caf3/`.
Baseline receipts remain in
`/Users/keithphilpott/.codex/worktrees/bootstrap-scope-reset/blorp/build/host-mixed-drop-costs-6211caf3/`.
Correctness, mutation and source receipts are under the worker's
`build/host-discarded-option-leak/combined-focused/`, `combined-mutations/`,
`combined-simd-adaptation/`, `combined-simd-native/` and
`combined-acceptance-final/`.
The final seven-file source/test patch SHA256 is
`1288f921cf09e94e22d336ee5a577245170ea97cd5f582bb46f120aa44a3f39f`.

These are measurements and self-compilation of the existing compiler. They do
not establish the Blorp 2 M8 A/B/C self-compilation milestone.
