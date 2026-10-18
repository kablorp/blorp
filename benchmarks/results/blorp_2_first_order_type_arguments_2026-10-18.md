# First-order type-argument translation

The three identical specialization callbacks now use one private first-order
`concrete_types` builder. Argument order, terminal substitution, lookup ownership,
the call-site span and first-error propagation are unchanged. Only complete lists
are published. Eight other `translated_list` callbacks remain; this does not
complete the compiler-source migration or retire the function-type dependency.

## Frozen comparison

- Accepted baseline: `70d3c8563e3d36dbd08ff0bddd5090afd662592a`.
- Two-file source/test patch: `159fa1add1349bd4db0c4be5a2566d2c0b25b537f36c64c8c473f077c0ff8ca8`.
- Frozen epoch: `9801aac3df77df798171e43553d39067a25753412fe76073632bca65ccb06e96`.
- Complete baseline inventory: 837 files; target snapshots: 40 compiler modules
  and nine identical target-library files per variant. The corpus contains 489
  shared invocation states, 464 fixture files and 150 generated dependencies.
- Production: 28 added / 18 deleted, net **+10**. Tests: **44 added**; no new
  fixture files or lines. These satisfy the prospective physical-line ceilings.

The supporting SOURCE pair is the original `host-utf8-file-admission` host:
normal SHA256 `34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33`,
diagnostic `be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93`,
with that worktree's original standard library. All 598 frozen host/source/runtime/
library pins passed before and after collection. This library differs from the
root checkout's library; the producer roles were not silently interchanged.

Exactly one source-to-C generation per variant used the normal supporting host,
followed by four `clang -O0` links with `BLORP_MEMORY_DIAGNOSTICS=0` or `1`,
`-lm -lpthread`. Both generations and all links exited zero. Each link's 88
warnings are retained. An earlier relative-path setup preflight failed before
invoking the producer; its failure is retained separately from measurements.

## Correctness and measured costs

The frozen c04 host and root library ran the functional checks: baseline and
candidate focused suites **93/93**, complete component suites **3,191/3,191**,
and normal-entrypoint functional e2e **464/464**. Functional e2e instruction
counters were explicitly disabled; the separate quiet comparison below owns
instruction acceptance. Pilot/native strict memory gates remained enabled.
Reversing the argument builder failed the intended order/phantom callback;
omitting arguments failed six intended specialization callbacks. Exact source
restoration returned both suites green. Defensive first-error propagation is
also reviewed directly; no malformed sealed checked product was invented.

One quiet epoch executed **3,920 calls**, with no retries, refreeze or cap changes:
978 strict pilot calls, 2,934 alternating normal calls, and eight SOURCE proxy
calls. All 489 states met their individual existing absolute ceilings and
independent **+3%** allocation/instruction limits. Every strict pilot observation
had positive balanced counts and zero leaks. Status, diagnostics, generated C
and absent/preserved output states matched. Normal samples use minimum-of-three
in B1/C1/C2/B2/B3/C3 order. All 370 successful baseline C outputs also match the
previous accepted stderr packet, despite the different supporting producer.

| Measure | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Maximum per-input allocation change | — | — | 0% |
| Largest per-input instruction increase (`i0032-absent`) | 40,011,168 | 40,171,631 | +0.401046% |
| Supporting SOURCE checkpoint allocations | 23,474,077 | 23,471,891 | -0.009312% |
| Supporting normal minimum-of-three instructions | 20,888,824,863 | 20,884,658,276 | -0.019946% |

The SOURCE allocation metric is the single schema1
`artifact_construction_complete.total_allocations` checkpoint, with
`BLORP_MEMORY_STATS=1`, leak mode unset, exit zero and exact `Generated` output.
It is **not** FEATURE's full exit TOTAL. Normal proxy calls unset both memory
flags. Each proxy output matches its own variant's setup C. The compiler C
changes as expected with the source; unchanged fixture C does not change.

These are host-based proxies, not pilot self-compilation results. Historical
R0 compliance remains unverified. The known host compilation leak is not repaired
or waived for pilot/native execution; this SOURCE protocol makes no new strict
host-leak pass claim. Neither aggregate improvements nor historical exceptions
offset any per-input limit.

## Retained evidence and review

Raw streams, commands, output C, time observations, setup failures, source/library
snapshots, input/oracle maps and before/after pins are retained outside managed
worktrees at
`build/bootstrap-evidence/first-order-70d3c8563-01/` in the root checkout.
The originating worktree is `bootstrap-first-order-validation`, under
`build/first-order-validation/`. Do not archive either before verifying all
required ignored evidence has an independent retained copy.

Root and an independent compiler reviewer inspected the code, effective
mutations, producer roles and each measured limit. Historical plans and numerical
ceilings remain in `blorp_2/TYPE_ARGUMENT_TRANSLATION_PLAN.md`.
