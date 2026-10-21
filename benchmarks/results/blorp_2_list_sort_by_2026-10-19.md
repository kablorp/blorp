# Held stable Int-key List.sort_by candidate

The candidate implements the [reviewed ordinary source contract](https://github.com/kablorp/blorp/blob/2ebbebf83c08b45cdf0c807453f89e12fb4b4ac9/blorp_2/LIST_SORT_BY_PLAN.md)
in the isolated `codex/list-sort-by` worktree. It is held and unmerged: native
behavior passed, but the first shared-input instruction checkpoint exceeded its
10% hard ceiling. No resource waiver or further compiled calls are authorized.

## Source and producer boundary

Fixed B is `a656f5ce1de963c8e9c162460e181d696b39c1d5`, including accepted Numeric Int.
C changes only `blorp_2/standard_library/list.brp`: 110 additions/1 deletion.
All 41 compiler source modules are unchanged. Both sides use complete 12-file
libraries at one physical input/library/output/CWD; only `list.brp` differs.
The candidate lives at `/Users/keithphilpott/.codex/worktrees/list-sort-by/blorp`.
Its test additions are 144 nonfixture lines plus the 73-line real-main fixture.

Retained Numeric normal `02ecee8f9d46f0eef680b207316650c15a903ab7a8d90584f58895a866570260`
and diagnostic `ef9365be6d735face891f197f7fa33d1e6a36c319431f6b341567a64414b8466`
come from the same C `9ab6dde06d7d10ea61703b863fa74b3c76a0b40db59f8835f057fe7f7fac9f69`.
Source/producers are pinned in the [early-cost packet](../../build/bootstrap-evidence/list-sort-by-2026-10-19/early-return-zero-eight01/PRODUCER_ROLES.json).
No compiler build or HOST measurement is claimed by this library-only increment.

## Correctness and the new fixture limit

The minimal missing-export RED passed its intended failure; the checked API owner
then passed all three callbacks. The first strict fixture compilation completed
with balanced 157,753 allocations/releases, zero leaks/bytes and 407,265,929 retired
instructions. It **failed** its original 150,000 allocation ceiling; 600M instructions
passed. [Original FAIL](../../build/bootstrap-evidence/list-sort-by-2026-10-19/first-green-proposal01/native-execution01/RECEIPT.json)
`51fde45f6ea0618931be1e402db22ec2e28e96af8df90f6a532546ef2ae591e2` remains unchanged.

The user explicitly approved dedicated `SORT_LIMITS` of 160,000 allocations/600M
instructions for this new fixture only. Shared generic 150,000 and all existing
limits remain unchanged. This does not relabel the original sample as PASS.
The [approved exact patch](../../build/bootstrap-evidence/list-sort-by-2026-10-19/new-fixture-budget-proposal02/PROPOSED.patch)
is `34f4f300fb9b8c7ed0c639c03b96b1c040a7e19a5aa90a10206d94b591adc5a9`.

Without recompiling, the same unmodified fixture C
`bfa3781ebe5ba746f440679c1ed3b6e2041d0b2cda9ca2016c3a7a8f42f94a2e`
linked C11/O0/Wall/Wextra/Werror/pedantic with ASan/UBSan and executed actual main.
Both calls exited 0; link streams and main stderr were empty. Main stdout matched
all 66 bytes, including UTF-8/NUL, SHA256
`fd9b2bbbae895f3764a303f54ee94fbf638b412efc94115f50c1ad3a71e13aae`.
[Native receipt](../../build/bootstrap-evidence/list-sort-by-2026-10-19/remaining-native-two01/execution01/RECEIPT.json):
`ecc68821278ed68f5894ecf62e1d2ad5191c098090c50cc9e0389b19f67d5ecf`.

## Shared-input STOP

Unchanged `return/zero.brp` ran normal B1,C1,B2,C2,B3,C3 once. Instructions were
B: 51,830,206 / 43,171,047 / 43,186,915;
C: 63,404,560 / 63,353,517 / 63,416,363.
Normal min3 rose **43,171,047 → 63,353,517 (+46.750012804%)**: both the independent
5% target and 10% hard ceiling **FAIL**. Each sample passed its old 440M absolute cap.
The run stopped immediately when the paired min3 verdict became available.
Strict B/C calls 7–8 remain **UNRUN**; there is no shared-input allocation result.

All six statuses were 0 with empty ordinary streams, positive counters and exact
C identity `aab5f23db26441ca0d76afc990b35019c232682760050150db31bb4b97a20790`.
All 209 pins, Git/environment/FRESH guards passed; the full candidate library was
restored and the active output removed. [STOP receipt](../../build/bootstrap-evidence/list-sort-by-2026-10-19/early-return-zero-eight01/execution01/RECEIPT.json):
`519386321ac49aa925d09e7a9890fcf15a22a0ae111453e2a52d6ea34b8e12a0`.
These are complete compiler-invocation costs; phase attribution and runtime sort
cost were not isolated. No averaging, budget offsets, retries or baseline roll apply.

Remaining controls, fixture normal min3, three semantic fault/restoration pairs,
full component/native gates, CLI identity closure and final feature reviews are
unrun. Actual self-compilation clients also require accepted M7 noncapture.
This report publishes evidence and the approved fixture limit, not implementation
acceptance or permission to continue through the shared-input hard failure.
