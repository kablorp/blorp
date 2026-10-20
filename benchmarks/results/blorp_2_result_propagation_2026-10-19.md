# Function-prefix Result propagation — 2026-10-19

Result-only `?=` now checks and desugars through existing Result-valued joins.
For source `Result[V,E]` and returned `Result[R,E]`, Ok binds V and continues;
Err constructs the returned Result's Err. A private immutable RHS initializer
preserves once evaluation and mutable versions carried by an RHS match. There
are no new Lower, Own, Verify, Emit or runtime products. Option, nested statement
contexts and annotated TCO remain rejected. See the [contract](../../blorp_2/RESTRICTED_CONTROL_PLAN.md#b-frontend-result-propagation-checkpoint-2026-10-19).

Fixed accepted B is `2aaedc28967f16d9d640256f264e731cf9922d48`; C is B plus
four Check leaves, production patch `d26f859540359c29d0ace337c96d037182a7cc9c376faaf1cba53ad07d1780a0`.
Production is **345 ADD/66 DEL/+279**, within 430/+330. The initial 160–250/+110–180
forecast was exceeded and recorded before final validation. Tests are **1,021
ADD/8 DEL**, within the separately reviewed 1,025 limit, including one 29-line
managed fixture (40-line limit). API/reference docs and this report are separate.

The [genuine RED](../../build/bootstrap-evidence/result-propagation-2026-10-19/first-red01/RECEIPT.json)
was a normally executed checker assertion, not a setup failure. Final focused
Check 21/Spec 2/Lower 2 all passed. [Two production faults](../../build/bootstrap-evidence/result-propagation-2026-10-19/oracle-fault-proposal01/execution01/RECEIPT.json)
were killed by the exact source/return Result-identity and RHS-carrier assertions;
restored Check 21 and Lower 2 passed with exact source/mode/semantic-index closure.
These are phase-unit oracle proofs, not independent native mutation claims.

The [final execution receipt](../../build/bootstrap-evidence/result-propagation-2026-10-19/final345/execution/RECEIPT.json)
records **3,625 component PASS/0 FAIL** and native **506 outer cases/0 FAIL**
(1,149 total PASS markers including nested cases and the umbrella). All **415**
positive compiler-cost rows passed unchanged absolute limits. Both commands
exited 0 with empty stderr. The seven new cases used strict compiler accounting,
unmodified generated C with C11/O0/Werror, ASan/UBSan and each real main. The
managed UTF-8/NUL/alias fixture printed its exact 41 bytes; RHS mutation printed
`7\n1\n`. All 1,025 guarded file contents/modes, Git status and index were stable.

The host `bin/blorp` (`fbb6af121e82…`) with explicit host std built TestSuites and
generated the compiler C once using the maintained compile/link recipe. Native
fixtures were compiled by explicit **Blorp2 diagnostic `05266301bc33…`**, not the
host compiler. Normal Blorp2 is `a0ee7632d50c…`; both use the same unmodified
compiler C `98939c7bc991…`, O0 and diagnostic modes 0/1. Both compiler links retained
90 existing warnings (3 qualifier/59 parentheses/28 pointer-integer), no errors.

One host TestSuite materialized the seven existing fixture producers. The
[21 normal samples](../../build/bootstrap-evidence/result-propagation-2026-10-19/final345/execution/NORMALS.json)
time the normal Blorp2 compiler directly; memory/leak statistics are unset.
Each input used one physical source/library/output/CWD boundary and three
byte-identical C outputs. These are C-only inputs, with no relative B claim.

| Input | Strict allocations /45k | Strict instructions /200M | Normal min3 /200M | Lexical C depth |
| --- | ---: | ---: | ---: | ---: |
| Managed | 26,301 | 88,578,353 | 58,729,542 | 5 |
| Chain 1 | 20,493 | 74,824,692 | 51,289,957 | 5 |
| Chain 2 | 21,476 | 77,143,377 | 52,670,234 | 7 |
| Chain 5 | 24,417 | 84,840,345 | 57,070,733 | 13 |
| Chain 9 | 28,343 | 96,604,092 | 64,581,473 | 21 |
| Chain 16 | 35,218 | 120,627,834 | 81,267,359 | 35 |
| RHS carriers | 22,439 | 79,487,122 | 53,878,761 | 5 |

[C review and depth data](../../build/bootstrap-evidence/result-propagation-2026-10-19/final345/execution/C_REVIEW.md)
show source String/String and returned Int/String instances remain distinct,
the Err payload is retained before prefix/source cleanup, and the RHS carried
version reaches the continuation. Depth excludes quoted text/comments; it is
lexical, not preprocessed/AST depth. Default-limit native compilation passed for
all five chains. Only the artificial 128-chain screen was waived by the user.

The separate [supporting-host construction proxy](../../build/bootstrap-evidence/result-propagation-2026-10-19/cost-preflight01/refresh345/PROXY.json)
passed: allocations 25,634,590→25,864,275 (**+0.895996%**), normal-min3 instructions
47,302,696,400→47,730,704,900 (**+0.904829%**). Original normal/schema1 diagnostic
roles and construction checkpoint were retained; each variant's C was stable.
This proxy omits a successful compiler self-compile.

[Twelve unchanged target controls, 96 calls](../../build/bootstrap-evidence/result-propagation-2026-10-19/cost-preflight01/controls345/RESULT.json)
passed the independent **+3%** allocation/instruction limits and all old absolute
limits, including timed diagnostic invocations. Allocations were identical on
every input; normal-min3 instruction deltas ranged **−2.238740% to −1.586001%**.
Each role's C and B/C C were byte-identical. Strict accounting was balanced-zero.
These are matched serial compiler-input proxies against the same B, not a reset.

A 329-ADD precursor had seven native successes and supporting-host proxy PASS;
its raw setup/observer failures remain retained. Bootstrap-subset pattern and
constructor-context corrections produced the final 345 source, rebuilt once and
validated above. The precursor is historical evidence, not current acceptance.

The [fresh actual source probe](../../build/bootstrap-evidence/result-propagation-2026-10-19/source-overlay02/execution01/RESULT.json)
used candidate02 to compile input containing the reviewed namespace/source-import
cohort plus these Check changes, separately from the fixed-role cost C. This
probe composition passed the prior function-prefix propagation and stopped at
`blorp_2/src/main.brp:48:2`: `` `while` is not supported yet ``.
It exited 1, stdout 0/stderr 135, no C, with all 53 inputs unchanged. This is farther
compilation progress; self-compilation and the fixpoint proof remain incomplete.
