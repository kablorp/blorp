# Cancellation plan published-list storage pilot

Base: `6020e4d34588e89612f06a48186d18b3bf0e1750`, clean detached checkout.
Candidate: `codex/pilot-cancellation-plan-storage` in the `2ccd` worktree.
Compiler: `BLORP_CLI_C_OPTIMIZATION=-O2 make`, Apple clang 21.0.0,
bootstrap `dev-35040738956f`. Base binary SHA-256:
`6f38bb62080c534499fc293225fdd24124e6d62aa94dda75d9d8403da4389037`;
candidate binary SHA-256:
`f34883d0015d64a5d9120d17fbc2700492000d561784b0258fdb144bdeeffd49`.

## Hypothesis and boundary

`CancellationPlanAnalysis.let_protections` is needed while building a plan,
but production consumers of `CancellationProtectionPlan` use only
`let_protections_by_name` and exact `CoreVar` identity. Generated C confirmed
the published record retained an additional pointer-storage `blorp_List*`
with protection-record pointers. Removing that published field should release
its list container and pointer slots after analysis, without copying or
removing the protection records or their string bytes. The analysis list,
bucket construction, lookup identity, and cancellation behavior are unchanged.

## Matched measurement

Both binaries compiled the frozen base input revision above. Commands used
`python3 /tmp/blorp-memory-pilot-run-20260927.py` to serialize compiled work,
then `benchmarks/self_compile_measure --compiler bin/blorp --input-rev
6020e4d34588e89612f06a48186d18b3bf0e1750 --samples 1` with labels
`cancellation-plan-base` and `cancellation-plan-candidate`. The candidate
also used `--baseline /tmp/cancellation-plan-base.json --require-identical`.
Full raw records are the adjacent JSON files. Full generated C remains at
`/tmp/cancellation-plan-base.c` and `/tmp/cancellation-plan-candidate.c`.

| Signal | Base | Candidate | Difference |
| --- | ---: | ---: | ---: |
| `cancellation_plan_complete` allocations | 9,224,319 | 9,224,319 | 0 |
| `cancellation_plan_complete` current objects | 20,611,059 | 20,600,152 | -10,907 |
| `cancellation_plan_complete` allocator bytes | 1,764,208,416 | 1,763,327,776 | -880,640 |
| `backend_emission_complete` current objects | 20,611,071 | 20,600,164 | -10,907 |
| `backend_emission_complete` allocator bytes | 1,870,996,560 | 1,869,755,472 | -1,241,088 |
| Total allocations | 191,834,689 | 191,834,689 | 0 |
| Retired instructions, one sample | 149,350,287,746 | 149,250,344,183 | -0.07% |
| Whole-process peak RSS bytes, one sample | 2,084,241,408 | 2,089,385,984 | +0.25% |

Generated C was byte-identical, 78,694,485 bytes and SHA-256
`0c1e831426470b62a3cef2bd916d7bf5b5c21c11f67eab5f839797b02a33e198`.
The live-byte reduction is a plan-boundary result, not a lower whole-process
peak. Allocation churn did not improve. One instruction and RSS sample is
insufficient to claim a speed or peak-memory change.

## Correctness and formatting

The focused cancellation suite passed 44/44 on the base and candidate before
the final fixture-only formatting edit. `scripts/compiler-check --changed
--base 6020e4d34588e89612f06a48186d18b3bf0e1750` passed 2,616/2,616,
including three selected suites, Core sanitizer, and generated-C audit.
The distinct leak gate passed 977/977. Raw logs are
`/tmp/cancellation-plan-gates-compiler-check.log` and
`/tmp/cancellation-plan-gates-leak.log`. These gates rebuilt a fresh compiler
at `cli=-O0`; the measured binaries above were both fresh `cli=-O2` builds.

Whole-file `bin/blorp format --check --diff` remains nonzero for the three
touched files. Running the same formatter on base and candidate copies showed
the production-file hunks predated this patch; the new fixture's formatting
was corrected without adding whole-file import sorting. The final focused
rerun after that formatting edit is recorded in
`/tmp/cancellation-plan-focused-final.log`.

This is a small retained-storage simplification, not a material compiler
memory reduction. The measured result does not justify a broader cancellation
planner rewrite or claims about allocation churn.
