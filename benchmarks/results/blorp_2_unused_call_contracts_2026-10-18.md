# Unused call contracts — 2026-10-18

Status: **accepted for landing** after user reassessment. The code and primary
cost metrics meet the [published plan](https://github.com/kablorp/blorp/blob/b1dd8fda7d5f6c3451f6dd492c54cd8d876fdd2b/blorp_2/UNUSED_CALL_CONTRACTS_PLAN.md).
The user accepted the two measured small-input RSS increases and clarified that
simplification should improve the overall direction; every individual metric
need not decline. No layout tuning or compensating cleanup was attempted.

## Change and scope

Accepted B is `bc6168b483a6680628a2d915ff18f22bd314ab69`; plan commit is
`3e4b8cced`. Remove unread `ArgumentSlot` vectors, `FunctionContract.arguments`,
`paired_arguments` and `ReceiverContract`; preserve the existing target, accepted
signature and span. One numeric arity check replaces pairing at the same producer
points. Signature lookup, arity, purity, receiver synthesis and overload selection
retain their order. No other phase-boundary finding is implemented.

Physical production diff: **32 ADD / 90 DEL, net −58**, three existing modules.
Tests: **42 ADD / 10 DEL, net +32**, two existing owners. Fixtures: **0**.
README: **5 ADD / 4 DEL**. Production plus tests remove 26 net lines.
Plan/results documentation is separate from these counts.
Production patch SHA256:
`c9c1c051ee7f58089b7b391e1bd9be802d7ccbe57fef5351089f6305b08e0d6d`.

## Functional evidence

The strengthened diagnostic tests pass on unchanged B: **50/50**. Candidate
focused suites pass **129/129**. The temporary fault accepting every call to a
zero-parameter function produces **3/16 FAIL**, including the exact zero-UFCS
arity/purity oracle. Restoring the exact file bytes returns **16/16 PASS**.
The production patch hash is unchanged after restoration.

All **494 frozen fixture roots / 988 normal CLI calls** preserve exit status,
stdout, stderr, C presence and successful C bytes exactly. Every measured
fixture also has identical C across B/C and normal/diagnostic runs. This checks
compiler output; the independent native gate checks real main behavior.

Full component gate: **3,514 PASS / 0 FAIL**. Tooling: **7 PASS / 0 FAIL**.
Both exit zero with empty stderr and all 1,006 recorded pins unchanged.
Native: **1,091 PASS / 0 FAIL** (492 fixture/group callbacks, 598 nested native
checks and one umbrella). It exits zero with empty stderr and all 1,006 pins
unchanged. Required instruction counters, strict accounting, native ASan/UBSan
and all 400 existing compiler-cost rows pass without changing caps. These
counts overlap focused runs; do not add them to claim unique coverage.

## Matched resource evidence

All original samples remain in ignored `build/call-contracts-2026-10-18/`.
Allocation counts are deterministic; instructions are the original normal min3
in B1,C1,C2,B2,B3,C3 order; peak RSS is the original normal median3. No original
sample was discarded. Host source construction uses the unique schema-1
`artifact_construction_complete` checkpoint. Pilot fixture compilations use
positive strict totals with equal releases and zero leaked objects/bytes.

| Input | Allocations B → C | Instructions B → C | Median RSS change |
| --- | ---: | ---: | ---: |
| proxy | 25,565,842 → 25,528,448 (-0.146%) | 46,743,985,768 → 46,642,030,540 (-0.218%) | -393,216 B (-0.157%) |
| call/one.brp | 9,378 → 9,374 (-0.043%) | 36,026,486 → 35,955,523 (-0.197%) | +0 B (+0.000%) |
| nested/order.brp | 10,111 → 10,095 (-0.158%) | 36,976,263 → 36,909,738 (-0.180%) | -16,384 B (-0.318%) |
| ufcs/chain_64.brp | 20,454 → 20,059 (-1.931%) | 51,345,233 → 50,965,635 (-0.739%) | +16,384 B (+0.281%) |
| generic/contextual/partial_ufcs.brp | 10,691 → 10,685 (-0.056%) | 37,940,746 → 37,935,272 (-0.014%) | +0 B (+0.000%) |
| generic/named/ordered.brp | 18,162 → 17,993 (-0.931%) | 48,330,490 → 48,266,908 (-0.132%) | +32,768 B (+0.625%) |
| generic/named/managed.brp | 23,108 → 22,918 (-0.822%) | 54,596,492 → 54,469,168 (-0.233%) | -16,384 B (-0.292%) |

All seven allocation/instruction comparisons decrease. The compiler-source proxy
reduces allocations by **37,394 (0.146%)**, min3 instructions by **101,955,228
(0.218%)**, and median RSS by **384 KiB (0.157%)**. These are modest improvements,
not a material speedup claim. The proxy covers the host constructing compiler C;
it omits linking and target self-compilation, which remains blocked before full
source checking.

The one bounded repeat contains fresh diagnostic samples plus three normal
samples per role for each RSS-increasing control. Allocation counts are unchanged
from the first batch and instructions still decrease. RSS medians repeat exactly:

| Input | B median bytes | C median bytes | Increase |
| --- | ---: | ---: | ---: |
| UFCS chain | 5,832,704 | 5,849,088 | 16 KiB |
| Ordered callbacks | 5,242,880 | 5,275,648 | 32 KiB |

The increments are one/two 16-KiB pages. Static Mach-O inspection finds equal
mapped segment capacities, while candidate text is 5,360 bytes smaller and its
executable is 392 bytes smaller. This does not establish the cause of the RSS
increase or make it disappear. Demand paging/layout is a possible explanation,
not a measured conclusion. No third batch or binary-layout tuning is warranted.

The prospective stop rule prompted reassessment. On 2026-10-18 the user accepted
the measured 16-KiB and 32-KiB increases and authorized landing, then clarified:
"We don't have to hit every metric, we just want to be going in the right direction
generally." The overall result supports this bounded cleanup: lower production
LOC, allocations and instructions, with these small RSS costs disclosed. Existing
fixture allocation/instruction caps remain unchanged.

## Provenance and reviews

All 41 B source hashes match the accepted opaque implementation; its paired
pilots are reused only after source/tool/library checks. B normal/diagnostic
SHA256 prefixes are `834d1431` / `90fe6d25`. Candidate normal/diagnostic are
`a197b6a6` / `b3e84543`, both linked once at `-O0` from unmodified C SHA
`0bff8c81`, with `BLORP_MEMORY_DIAGNOSTICS=0/1`, `-lm -lpthread`, Apple clang 21.
The FRESH repository host is `97479b34`; paired source-proxy hosts are
`6852e1c6` / `a362b0df`. Frozen host/target libraries and fixture paths are
identical for each B/C comparison. Candidate link warnings are 90 versus B89:
one additional existing parentheses-equality warning, no new warning class.

`BASELINE.json`, `SOURCE_FREEZE.json`, per-command JSON, raw streams/time files,
`COSTS.json`, `RSS_REPEAT.json`, `IDENTITY.json` and `MUTATION.json` retain the
full hashes, inputs, argv and outcomes. These scripts only orchestrate ordinary
CLIs and compare their public artifacts; no test fixture entrypoint is bypassed.

The plan passed independent architecture/code-reviewer and test-runner review
before its separate commit. Final code review reports zero findings. Independent
test-runner review approves functionality. Both reviewers identified the repeated
RSS changes for reassessment; the user accepted them and authorized landing.
The accepted decision preserves the original samples and resource limitations.
