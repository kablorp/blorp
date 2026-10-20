# Ordinary target String.starts_with, 2026-10-20

## Current-main composition: validated under reviewed measured limits

The reviewed standalone evidence below is preserved from the Starts worktree at
468b. Starts and List callback helpers are composed onto published Option + Join main
`09bdd5fb9db85df3d488ac02264845231770b943`; its first composition gate failed costs.
Source41 still matches retained CWD producers. The library retains the published
Join body byte-for-byte and adds the reviewed Starts body. All 48 overlapping
allocation definitions initially retained main values; none of Starts' standalone
cap replacements is replayed. No previous allowances are summed or stacked.
Components passed all 3,661; native semantics passed all 667. Native failed 85
allocation rows and 13 overlapping instruction rows, with 421 positive cost rows.
Standalone approvals and PASS results are not combined-cost acceptance.

Relative to this main, production is 17 added / 1 deleted, tests 150 added / 0
deleted with two fixtures totaling 50 lines, and API docs 13 added / 2 deleted
(15 gross lines). The extra API replacement clarifies the separate ordinary
List join wrapper while preserving its published contract. All following
measurements, gate counts, size ledgers and call history describe the original
reviewed standalone slice unless explicitly labeled as composition evidence.
The failed run is retained as receipt 45cd57e8; no cost resample or baseline roll.
Root and peer approved only 71 allocation/nine instruction composition governors:
shared-user maxima + 200 rounded up to 1,000; maxima + 1M rounded up to 1M. Other 208
metric fields initially remained unchanged. The next run failed one by 40,558.
Receipt 6546d564 preserves that FAIL; four reviewed current-run near-limit instruction
fields now use both-run maxima with the same +1M, rounded up to 1M rule. Final native
passed all 1,180 ordered markers/421 positive cost rows within limits, CLI0/stderr0
(receipt d4891b9f). Components3,661 was retained; no source/test predicate changed.
Token-table offsets count decoded Unicode text characters, not UTF-8 bytes.

Implementation and validation are complete under the human-approved finite
allocation and test-size exception. Root owns final independent review, commit,
merge and publication. The [plan](../../blorp_2/STRING_STARTS_WITH_PLAN.md#current-validated-status-2026-10-20)
records current status and preserves the historical proposal and failed thresholds.

The pure helper compares counted bytes: empty prefix is true; a mismatch or
missing value byte is false. Named and UFCS calls borrow both Strings. UTF-8
spelling, embedded NUL, LF and aliases are covered without normalization.
The input fixtures are `blorp_2/test/e2e/fixtures/string_starts_with/arguments.brp`
and `counted_aliases.brp`; their 20 argv rows and one counted-NUL/lifetime row
retain exact status/stdout/stderr oracles.
Native stack use is temporarily linear in the matching prefix; the unchanged
4,096-byte cases establish bounded coverage, not TCO or constant stack. Compiler
work and whole-native-process accounting below do not measure helper runtime
cost or its allocation rate. No source consumer, compiler or runtime was changed.

## Executed validation

The worktree base is `468b98b863eba89dab762d197c3cd91b0cdf8fe1`. Its current
source41 matches accepted CWD source `785669396dd7c7747145f8156c9e10262e48e076`.
Root later advanced through the docs-only commit
`9b5348a6bcdb23b2fce58c0bae807e06dbeeeb36`; only `LAMBDAS_PLAN.md` changed.
Source41, Main `4829132a…` and Root's original cap sources stayed unchanged.
The approved observer binds that HEAD, plan and clean index separately from
executable provenance. No compiler was rebuilt for this feature or final gate.

| Gate | Observed result |
| --- | --- |
| Complete unit/runtime/grammar | 3,646 PASS, 0 FAIL; exact ordered vector and empty stderr |
| Current functional C captures | Two untimed captures passed; retained unmodified output |
| Before cap amendment | Four calls exited 0/0/0/1; native retained 57 allocation failures, 665 semantic PASS and 419 positive cost rows |
| Final maintained native registry | One call, exit 0, empty stderr; 49 groups, 510 outer + 665 semantic + 1 umbrella = 1,176 PASS, 0 FAIL |
| Final native metrics | All 419 positive rows met their exact allocation and instruction ceilings; zero misses |
| Separate diagnostics1 native accounting | Two strict sanitizer links + 21 real-main cases passed; each argv case 6 allocs/6 releases, counted NUL/lifetime 21/21; all zero leaked objects/bytes |
| Fault sensitivity | Three source-valid semantic kills and three fresh restored greens in 18 calls; all source/restoration guards passed |

The equality fault compares the actual byte with itself; the other faults advance
by two or accept a missing value byte. Existing first-mismatch, middle-mismatch
and empty-value witnesses produce exactly `1\n1\n` under their faults instead
of restored `0\n0\n`. Each compile/link/main triplet has a fresh restored
triplet. The earlier contextual-constructor compile failure is retained as a
setup failure with zero kills, not credited as semantic evidence.

Native links use `/usr/bin/clang -std=c11 -Wall -Wextra -Werror -pedantic -O0
-fsanitize=address,undefined -fno-sanitize-recover=all`, unchanged C and `-lm`.
The separate accounting links also use `-DBLORP_MEMORY_DIAGNOSTICS=1` and real
mains under `BLORP_LEAK_CHECK=strict`. Every status and literal stdout must match;
stderr is exactly one positive balanced zero-leak report, with no sanitizer
output. Normal harness diagnostics0 links are not the accounting proof.

## Frozen costs and approved exception

The original matched baseline remains accepted Numeric
`a656f5ce1de963c8e9c162460e181d696b39c1d5`, not current main. Both variants use
that same source41 and their complete 12-member target libraries; C changes only
String by 18 additions/1 deletion. The current composition reuses the existing
IntOps import and preserves accepted append_int, giving 17 additions/1 deletion;
the helper body is byte-identical. Original B/C sample libraries are installed
outside measurement at one canonical CWD/library/input/output boundary, then B
is restored before classification. No baseline was rolled or sample replayed.

The table names resolve under `blorp_2/test/e2e/fixtures/<control>.brp`. The
shared physical CWD is Root
`build/bootstrap-evidence/string-starts-with-2026-10-19/return-zero-cost-proposal-01/canonical`;
both variants use `blorp_2/standard_library` and `same-output.c` there.

Each original control has B/C strict diagnostic counts and normal order
B1,C1,C2,B2,B3,C3, retaining all three per variant and comparing minima. Normal
memory/leak controls are unset before `/usr/bin/time -l`; strict requires positive
balanced counts and zero leaked objects/bytes. The initial hard stop after two
strict calls remains recorded; an explicitly approved numerical characterization
ran only the remaining 30 calls. All eight C outputs per control agree.

| Original control | Allocations B → C | Normal min3 instructions B → C | Approved final allocation cap |
| --- | ---: | ---: | ---: |
| return/zero | 14,534 → 17,200 (+18.343195%) | 43,172,157 → 46,680,048 (+8.125355%) | 17,334 |
| mortal_string/alias | 15,882 → 18,549 (+16.792595%) | 45,178,101 → 48,736,155 (+7.875617%) | 18,682 |
| string_literal/unicode | 14,981 → 17,647 (+17.795875%) | 43,981,563 → 47,561,978 (+8.140718%) | 17,781 |
| string_operations/concat | 18,074 → 20,742 (+14.761536%) | 48,396,996 → 51,909,101 (+7.256866%) | 20,874 |

Maximum allocation growth is **18.343195%**; maximum normal-min3 instruction
growth is **8.140718%**. All four allocation results fail the original 10% hard
ceiling and all four instruction results pass it. Both metrics miss the original
5% targets on every input. Those verdicts remain unchanged.

The human-approved allocation exception requires, independently on each listed
input, `C <= listed absolute cap`, `C - fixed_B <= 2800`, and
`100*C <= 120*fixed_B`, plus the unchanged old absolute ceiling. The 2,800 bound
rounds the observed maximum delta 2,668 plus 100 to the next hundred; it leaves
132–134 allocations above these observations. It is a final per-input bound,
not pooled credit or a stackable allowance. No instruction amendment was made.

Separately, exactly 48 current native allocation literals were approved and
applied: `ceil_to100(max_observed_of_all_users + 100)`, with 100–199 headroom at
each definition's maximum. They affect 57 formerly failing rows plus four passing
shared users. The other 358 allocation rows and all 419 instruction caps remain
fixed. Both Starts fixtures keep 150,000 allocations / 600,000,000 instructions.
The old current run remains FAIL; the fresh post-amendment native gate is PASS.
The approved test gross-addition ceiling is 200; its net ceiling stays 180.

| Starts fixture in final gate | Compiler allocations | Maintained-gate retired instructions |
| --- | ---: | ---: |
| arguments | 31,183 / 150,000 | 68,739,005 / 600,000,000 |
| counted_aliases | 33,271 / 150,000 | 71,689,961 / 600,000,000 |

These are maintained diagnostic-producer gate fields, not new normal-min3 or
relative current-main measurements. C-only fixtures have no absent-feature B
denominator. Earlier C-only normal minima are 60,427,228
and 63,038,192 under the old producer; they remain a separate six-call role.
The two public-phase diagnostic observations likewise supply no cost acceptance
or causal decomposition. This FEATURE evidence establishes neither target
self-compilation nor a SOURCE frontier or whole-compiler performance improvement.

## Exact executable and source roles

| Role | SHA256 |
| --- | --- |
| Original normal O0/diagnostics0 | `02ecee8f9d46f0eef680b207316650c15a903ab7a8d90584f58895a866570260` |
| Original diagnostic O0/diagnostics1 | `ef9365be6d735face891f197f7fa33d1e6a36c319431f6b341567a64414b8466` |
| Original producer C | `9ab6dde06d7d10ea61703b863fa74b3c76a0b40db59f8835f057fe7f7fac9f69` |
| Current functional-only normal | `0fae26733a3247c75fc13cf6a583e99ff2613256a59c3d159fe63365cabc2db6` |
| Current native-gate diagnostic | `9b22b4ac32cf271e506653697b29884be7cf738bc0b39c03c9c6060209641303` |
| Current producer C | `6dca397d3aa269d961508ad0849ec78af7ff89654d7ba1b0eb320644351d449e` |
| Current host TestSuites | `4980336e41f95e931206559b41669fc3ca40067a2a8452ab79935b477205be2d` |
| Current String source | `132148e32b1d9685c93fee5429c13f489c714528d32b757d54799b1584b7f4bb` |
| arguments retained C, 19,265 bytes | `113d1f8da0934580be444675b1fcc2d76f4be52ac9127daa8ea2b3bfe4e1676a` |
| counted_aliases retained C, 20,989 bytes | `91923d59102b698003fba306e4b997ddb4d7ce6dc2d83356be303ad456c384e3` |
| arguments diagnostics1 native, mode 0755 | `67358581a000e08ac9632dca252dc12fd1778f9ac0fffb76876ade3f2feb32b9` |
| counted_aliases diagnostics1 native, mode 0755 | `6c3e124939a419d3c56d083fbbef2d725536ef17c2f721fcbcd2c557cfb1eb36` |
| /usr/bin/clang | `5b1ddb7e9c11b87a034fc88b212e8ac243cfe2b4db696d767aa44c79595fc09a` |
| /usr/bin/time | `0ebe053d95315476e7e9dbfa78f75f2e72e2c772b9dc850d1a3811b01871db1c` |

Original tools reside in Root's
`build/bootstrap-evidence/int-ordering-current-cd823-first-four-2026-10-19-01/execution-first-four/`.
Current target producers reside in
`build/bootstrap-evidence/self-compile-leader-2026-10-19/source-current-directory-cost01/`;
host498 and its exact 91-member `host-std` reside in `boolean-source-cost01/`.
The source41, complete library12, test883, STD91 and producer construction/link
records are bound in current `readiness01/COMPOSITION_FREEZE.json` and
`PRODUCER_AND_ENVIRONMENT_BINDING.json`. Old source41/library B/C and the physical
canonical paths are frozen in original `starts-with-cost32-static-2026-10-20-01/ORIGINAL_ROLES_AND_PROVENANCE.json`.

Current calls use the exact private environment mapping SHA256
`01b8f2c9723eb8c6a87316071491678da927fbaedf86cd78ce972e553d2de952`, explicit worktree
PWD, original control unsets and `BLORP_CC=/usr/bin/clang`; native gates keep
`BLORP2_COMPILER=diagnostic9b22` and `BLORP_2_INSTRUCTION_CHECK=required`.
Fault successor calls use their separate private map `6d8d6d64…`; no cross-epoch
identity or ambient-environment equivalence is inferred. The original initial
GREEN did not retain its complete ambient map. No private values are published.
Tool hashes, exact argv, flags, cwd, stdin, input bytes, output-state oracles and
raw locations are retained in each packet's COMMANDS/receipt and guard records.

## Raw evidence and call history

Current evidence root: `/Users/keithphilpott/.codex/worktrees/starts-with-current/blorp/build/starts-with-current/`.
Original evidence root: `/Users/keithphilpott/.codex/worktrees/string-starts-with/blorp/build/bootstrap-evidence/`.
Initial RED/GREEN root: `/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/string-starts-with-2026-10-19/`.
All counts below are top-level lease calls, not the maintained harness's internal
compiler/link/main invocations. Every raw failure remains intact.

| Root / receipt directory | Calls | Result / receipt prefix |
| --- | ---: | --- |
| Initial / red-run-01 | 3 | Expected missing-export RED, `94aa3ff0` |
| Initial / green-run-01 | 26 | Initial semantic GREEN, `872d5738` |
| Original / starts-with-cost32-execution-2026-10-20-01 | 2 | Original hard stop FAIL, `1aca7ba9` |
| Original / starts-with-cost30-characterization-execution-2026-10-20-01 | 30 | Data complete; original cost FAILs retained, `a716f45b` |
| Original / starts-with-c-only-six-execution-2026-10-20-01 | 6 | Separate C-only normal observations, `34f154e6` |
| Original / starts-with-three-faults-execution-2026-10-20-01 | 1 | Setup failure, zero kills, `52c696a9` |
| Original / starts-with-three-faults-successor-execution-2026-10-20-01 | 18 | Three semantic kills + fresh restores, `09f6a14f` |
| Original / starts-with-public-phase-two-execution-2026-10-20-01 | 2 | Diagnostic observations only, `72e70b73` |
| Current / execution01 | 4 | Original current 0/0/0/1 FAIL, `39aca20d` |
| Current / strict-native-execution01 | 23 | Two links + 21 native accounting cases PASS, `2666171c` |
| Current / postapproval-normal-execution01 | 1 | Fresh amended full-native PASS, `b9377c75` |

The final receipt SHA256 is
`b9377c756af1793d89b155dc256ba927d539e9c199d0b61454ca6f5a079e6466`;
its manifest is `8dd2090e0335a37f02e0b54b3d2ed1f076c52493d04dd2e767bc75ffe9578a79`.
Strict-native receipt SHA256 is
`2666171c17a5a37d2c52ee7c1e87770dfbcf3da4382bb91a430336337880f6bf`.
`postapproval-normal-execution01/ACTUAL_NATIVE_FIELDS.json` retains all 1,176
ordered markers, 419 numeric rows and terminal summaries; raw stdout/stderr/status
are under `01-full-native/`. Strict cases retain individual CHECK/stream/status
files and executable bindings. Resource proposal02's manifest is
`b246ac6e73242e5c738852e2d81ca16683f0f29ba0adb594fd51542a0a646c24`;
its field/user tables preserve the four passing shared users and every unchanged
numeric field. Full closure guards passed before each CPU return.

## Physical scope and publication

Production String is 17 added / 1 deleted, preserving append_int. Tests are
198 added / 48 deleted, net +150: the original 150 additions plus 48 literal
replacements. Two fixtures total 50 lines. API docs are 12 added / 1 deleted
(13 gross lines), within the unchanged shared 15-line ceiling. The plan and this
benchmark report are separately counted evidence/design docs. No coverage was
removed or compressed. Only publication docs change after the final gate;
source41, library12, all test/fixture bytes and executed artifacts stay fixed.
Root and independent reviewers must approve the complete patch before commit,
merge or publication. No worker commit or push has occurred.
