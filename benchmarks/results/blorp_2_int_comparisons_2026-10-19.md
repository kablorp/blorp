# Signed Int ordering and helpers, 2026-10-19

The target Int module now supplies one signed64 `less_than` primitive, six
ordinary helpers (`greater_than`, both inclusive relations, `not_equals`, `min`,
`max`) and the scalar literals `INT_MIN`/`INT_MAX`. The primitive carries the
existing designated Bool contract through checking and specialization; emission
uses signed `<` and the actual true/false constructors. Lower, ownership and
verification production remain unchanged. There is no source-call migration.

Current functional validation passes under the human-approved finite resource
amendment. Original measurements and failed original thresholds remain recorded
with their original verdicts. This is a FEATURE acceptance packet; it establishes
neither target self-compilation nor current-main SOURCE frontier/+3% acceptance.
The [canonical plan](../../blorp_2/INT_COMPARISON_PLAN.md#current-approved-status-and-bounded-resource-limits)
owns the exact cap tables and scope.

## Current composition and functional evidence

The validated worktree is `codex/int-main-composition`, HEAD/base
`cd823cc4c9583b3dadbf8142073a01895a90bb18`, plus reviewed feature port `201df63f…`
and approved cap patch `984bc4e8…`. The current-main publication patch composes
that payload with `3fc132726af74c1fe71b18f8b8124aefce2c416d`; only documentation
changed on main since cd823. The three overlapping docs are merged while retaining
the newer Float, List and library-accounting notes. All 41 compiler modules,
11 target-language library files and every validated test/fixture byte remain identical
to the final current functional input. Final status/report docs are uncompiled.

ROOT `bin/blorp` SHA256
`97479b34bcfbf49dfeb269e8cb4e35d4e2757d0b1924ca30ac9c2d95b2db51d9`
was FRESH before and after the gates, with explicit ROOT `standard_library/src`
and all 91 files pinned. The first four commands run the complete unit/runtime/
grammar selection, generate one C file, then link that unchanged C once in each
O0 mode. All **3,598 callbacks passed**, including 302 suites and all 27 numeric
phase/library callbacks. Both links succeeded with the same 90 inherited
warnings: three discarded qualifiers, 59 equality-parentheses and 28 pointer/
integer comparisons. No warning policy was weakened.

| Current artifact | SHA256 |
| --- | --- |
| Generated C | 9ab6dde06d7d10ea61703b863fa74b3c76a0b40db59f8835f057fe7f7fac9f69 |
| O0 normal | 02ecee8f9d46f0eef680b207316650c15a903ab7a8d90584f58895a866570260 |
| O0 diagnostic | ef9365be6d735face891f197f7fa33d1e6a36c319431f6b341567a64414b8466 |

Final native command 5 ran exactly once, using the maintained complete e2e
entrypoint, this diagnostic compiler, `/usr/bin/clang`, explicit host stdlib,
and required instruction counters. It exited **0 with empty stderr**:
**633 named native checks + four direct real-main checks passed**, including
all 30 numeric cases. Across 47 owners, 497 outer callbacks and 402 nested
native suites, all **1,131 printed callbacks passed**. All **406 ordered cost
rows** had positive counters and successful strict allocation parsing; there
were **zero allocation misses and zero instruction misses**. The harness links
unmodified output with its existing strict C11/O0 ASan/UBSan flags and checks
real main, status and both streams. No selective runner or generated-C edit
was introduced. Native child artifacts follow normal temporary cleanup.

All 1,027 effective hashes/modes, logical index, branch and HEAD closed unchanged;
the 1,002 original and 999 earlier EA cohort pins also remained unchanged. No
first-four repeat, rebuild, retry or paired sample followed call 5. Root's later
publication checks are recorded below.

## Original matched costs and approved finite exception

The original fixed B remains `e706b393d51038ba49af720999d308fd95ce4ea9`.
Original complete C is feature patch
`ff5f64559c82cb7e0287a327573a9bb434310dfb9cd065c1eacb4bc959f497de`.
B and C use their complete 12-file target libraries at one physical path and
the same unchanged input/output/cwd per role. All nine unchanged controls have
within-role normal/diagnostic emitted-C identity and exact B/C emitted-C
identity. Strict diagnostic allocations and normal min3 instructions remain
separate; the frozen normal order is B1,C1,C2,B2,B3,C3. There was no resampling.

| Unchanged input | Original allocations B → C | Original normal min3 instructions B → C |
| --- | ---: | ---: |
| call/one | 10,677 → 14,792 | 38,385,285 → 43,812,465 |
| ufcs/chain_64 | 21,362 → 25,477 | 53,449,209 → 58,919,891 |
| generic/named/managed | 24,221 → 28,263 | 56,673,135 → 61,911,733 |
| option_input/parse_int | 12,219 → 16,334 | 40,917,780 → 46,329,046 |
| file_read/ownership | 16,723 → 20,766 | 47,787,091 → 53,034,951 |
| file_write/ownership | 22,492 → 26,534 | 56,439,187 → 61,715,867 |
| calculator/integer | 43,672 → 47,714 | 82,191,982 → 87,532,933 |
| constant/integer | 10,432 → 14,544 | 38,054,165 → 43,422,390 |
| int/equals | 20,315 → 24,357 | 51,171,586 → 56,522,610 |

All nine exceed the old +5% assessment targets; eight allocation and six
instruction results breach the original +10% ceilings. Worst allocation growth
is **39.417178%**, worst instruction growth **14.138699%**. A single equality
crossover using C's compiler and B's complete library matches B's 20,315
allocations. On that input, the 4,042 extra allocations follow library adoption;
this observation does not isolate individual compiler phases or excuse growth.

The human explicitly approved only these nine frozen controls under
`min(floor(1.40*B), B+4200)` allocations and
`min(floor(1.15*B), B+5600000)` original normal-min3 instructions. Every retained
C value fits its exact new ceiling. This neither rolls B nor changes other
FEATURE/SOURCE policies. Separately, 45 native allocation fields and the sole
syntax instruction field were approved and applied exactly: allocation caps
use `ceil((frozen_max+100)/100)*100`; syntax rises 65,000,000 → 66,500,000.
These definitions affect 58 allocation rows and five syntax instruction rows.
The shared join factory and its ten passing call sites remain unchanged; the
new numeric fixture retains 45,000 allocations and 150,000,000 instructions.
The original 55 allocation misses and overlapping instruction miss remain FAIL
in their historical receipts; the fresh current gate passes the amended caps.

The original supporting HOST construction proxy uses frozen normal/diagnostic
executables `6852e1c6…` / `a362b0df…`, 41 B/C source files at one active path and
the frozen 91-file host library, with `--no-embed-runtime --time-phases`.
Allocations use the unique schema1 `artifact_construction_complete` checkpoint:
**25,605,658 → 25,641,090 (+0.138376%)**. Normal min3 retired instructions are
**47,355,761,797 → 47,407,031,343 (+0.108265%)**. Both pass the unchanged HOST
+5% review/+10% hard limits. Output C matches normal/diagnostic within each role;
B/C compiler-program C differs, as permitted. This excludes linking and target
self-compilation and is not a ROOT974 build-total measurement.

The original FEATURE proxy and identity checks do not establish current-main
SOURCE acceptance: accepted checker/source contexts differ from original e706.
The current-main functional port and exact source pins establish compatibility
with accepted main, not a new paired cost result. No current target-source
frontier, SOURCE +3% matched proxy or M8 A/B/C fixpoint was executed in that
validation packet. Root's separate publication probe is recorded below. Any
required cross-slice/source-integration gate needs a separately named frozen
packet and root lane grant; no remaining compiled call is authorized by this
report. There is no performance-improvement claim.

## Correctness proofs, size and reviews

Actual parser/missing-export REDs precede production. Focused validation passed
164 events. The original 19-call fault/restoration protocol completed without
repetition: six independent phase mutant/restored pairs, unsigned-wrapping
native backend witness, ordinary minimum witness and restored owning/final
gates. The unsigned fault fails exactly eight numeric cases; the minimum fault
fails exactly 22; each leaves 600 unaffected native cases passing. Every fault
was restored byte-for-byte before classification. The stdout mismatch proves
child exit zero and exact wrong stdout; short-circuit checking does not prove
empty fault-child stderr. Restored positive cases enforce all channels.

The publication packet records physical readable lines by category. Production
remains **79 added / 23 deleted / +56** across seven files; nonfixture tests
**603 / 49 / +554** across 25; one new fixture is **34 lines**. The 46 test
literal replacements are 46 additions and 46 deletions, with no assertion or
fixture change. Public API docs are counted independently of the canonical plan
and this evidence report, under the unchanged 45-added-line ceiling.

Independent code reviewer `approved_numeric_budget_review` and test-readiness
reviewer `numeric_final_native_readiness` both returned **APPROVE0**, with zero
P0/P1/P2/P3 findings, before final call 5. Their reviewed payload was unchanged
during execution. Root also inspected the publication patch independently;
no worker commit or push occurred.

## Root publication checks

All 43 applied publication postimages matched the reviewed packet. The 41 compiler
modules, 11 target library modules and 870 test/fixture files match the validated
worktree byte-for-byte. One additional normal-compiler command retained the target
comparison fixture's C for manual inspection: exit 0, empty streams, unchanged
inputs, SHA256 `b792879be53145c5f4eef9c71648f763d7f3f91b95cae9c40781a165d5d6b02b`.
Both operands are `int64_t`; direct signed `<` selects the actual Bool constructors.
Bounds use `INT64_MIN` and `INT64_C(9223372036854775807)` without subtraction.

One separate current-source probe used the same validated normal compiler and
applied library. It exited 1 with the exact existing missing-`list.contains`
diagnostic at `src/verify/verify.brp:8:8`, empty stdout and no C. All input guards
closed. This establishes the current frontier only; SOURCE +3% measurements,
source migration and the M8 fixpoint remain unclaimed. The two small receipts
are retained under root ignored `build/bootstrap-evidence/` in
`int-ordering-fixture-c-review-2026-10-19-01/` and
`int-ordering-destination-frontier-2026-10-19-01/`.

## Retained evidence

Raw original cost samples, roles, sources, libraries, exact argv/environment,
pins and producer hashes are preserved under root ignored
`build/bootstrap-evidence/int-ordering-final-acceptance-2026-10-19-01/`.
`PUBLICATION_RECEIPT.json` binds the current-main patch, postimages, LOC and
checks. The original-data copies are under `original-cost-evidence/`.

The first-four receipt is under root
`build/bootstrap-evidence/int-ordering-current-cd823-first-four-2026-10-19-01/execution-first-four/FIRST_FOUR_RECEIPT.json`,
SHA256 `cdbae8db015893e91cefb909f3516a0e90e101d7c15ef562d168f6e0639420ea`.
Final receipt is under
`build/bootstrap-evidence/int-ordering-current-cd823-final-native-2026-10-19-01/final-native-execution/RECEIPT.json`,
SHA256 `ff99a62d22933018ed529437938e50236b302adc8309b86465f83fc930e9529e`.
Original correctness completion is under
`build/bootstrap-evidence/int-ordering-native-complete-2026-10-19-01/CORRECTNESS_PROTOCOL_COMPLETE.json`,
SHA256 `e93fe577cef09caf3bc2ca3ff65852084ba5ba715fea8bcc2f19e617f01c0d03`.
Approved proposal SHA256 is
`50e270dbe3e3c97eabd106f1f59f2360126771768b33464601ad9f061c45ba45`;
clarified authorization is `e0f074f0ade180d54a4e9624cf27346fdd5a75796dcc3e9c4ec2a5776f6937db`.
Both are retained in root `build/bootstrap-evidence/int-ordering-approved-budget-2026-10-19-01/`.
