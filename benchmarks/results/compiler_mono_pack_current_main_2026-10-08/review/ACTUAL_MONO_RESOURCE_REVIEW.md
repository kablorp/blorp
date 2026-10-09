# Actual combined Mono resource review

**APPROVE — 0 blockers / 0 should-fix / 0 nits** for completed cost batch13709. Full host/Linux landing acceptance remains separate.

I independently rehashed 4,040 retained artifact pins, 6,052 current tracked/untracked source-file pins, the exact 3,952-file frozen5b input, both archived compiler pairs, construction/runtime receipts, command logs, source/index/draft freeze, final FRESH and consumed-session release. All 11 commands exited zero. Both new normal/diagnostic binaries match their builder hashes and relocation receipts. The complete toolchain dictionaries differ from the accepted common-fix baseline only at the declared exact5b→c0b7 commit/self-compiled-by fields and corresponding version lines. All flags, target, split, compiler version facts and diagnostic modes remain matched. Raw `compiler_stage: 1` remains convenience metadata; standard construction proves actual stage2.

| Workload | Allocations, common fix → Mono | Minimum instructions, common fix → Mono |
| --- | --- | --- |
| self | 284,099,387 → 284,099,388 (**+1**) | 270,826,570,677 → 270,935,055,987; **+0.040057115%** |
| small | 1,753,167 → 1,753,168 (**+1**) | 1,654,994,443 → 1,653,708,413; **−0.077706001%** |

All four exact integer `candidate × 200 ≤ common-fix baseline × 201` ceilings pass. Three positive normal instruction samples per side/workload reproduce the recorded minima; paired diagnostic checkpoint totals reproduce allocation counts. Whole C matches on both workloads: self86,893,248 bytes/SHA `e43a2a11…`; small40,499 bytes/SHA `2033e266…`. Raw instruction spreads are self163,258,240→241,967,220 and small939,250→1,062,290. The repository min-of-runs protocol permits background work; these figures establish budget acceptance, with no quiet-host, wall-time or speed claim. The fix's separate 1% budget was not reused as the Mono ceiling.

Exact authority: cost FINAL SHA `c6bc39a425391acfce344903a5a45816d6c1a863c9a01b63fbaad08e4034ab00`; comparison `0fb399a9693edd2e942af90873daf7a10ecf1c60d7c65379ec094c65d0717b86`; release `f3b5bb39adac6b92cb1bf9f9b6b8a121f72bbee7ae9ce9eb0fd501ed3487abce`. Raw recomputation is retained in [ACTUAL_MONO_COST_RECOMPUTATION.json](ACTUAL_MONO_COST_RECOMPUTATION.json). No native job, repository mutation or raw record edit performed by this reviewer.
