# Blorp 2 expression-local nominal context

2026-10-22. Original source: `02b13d25d04b7c5670cb94052ea9675cc9ba3428`.
This completes T0 of the [trait roadmap](../../blorp_2/TRAITS_PLAN.md).
Traits remain unsupported; this change improves ordinary call inference.

## Change

A typed sibling supplies the expected record or union of a literal in either
operand order, including nested generic calls. One expression-local worklist
resumes deferred fields/payloads once, retaining variant identity and lexical
scope. Runtime operands still execute once in written order. Field names do
not select nominal types, and later statements or unknown field projections
do not supply context. No phase after Check or library source changes.

Closed construction validation publishes its actual type as argument evidence.
Placeholder self-equations cannot own generic conflict notes; typed Lists,
records and variants retain the earlier authoritative argument instead.
The exact structured error, source span, help and note tests cover both paths.

| Handwritten scope | Added | Deleted | Net |
| --- | ---: | ---: | ---: |
| Production, three checker files | 303 | 99 | +204 |
| Tests, including native fixture | 781 | 65 | +716 |
| Standard library | 0 | 0 | 0 |

## Matched original-input measurements

Both compiler roles compile the same preserved original source and library,
from one CWD to one initially absent output pathname, under the same private
environment. Apple clang 21 links each normal/diagnostic pair at `-O0` from
one physical compiler C file, with memory diagnostics respectively 0/1.
The actual Xcode clang executable and its Apple launcher are both pinned.
Original compiler C SHA256 is
`276cdc4811404c6949da747a6099acbd124fc54da7b5c582348027709864dbc0`;
candidate compiler C SHA256 is
`02264bd70948e19ec9d0b51756da7ee5ce9d2591821bc63fa13a10d4eaf1f32e`.

| Metric | Original | Candidate | Change |
| --- | ---: | ---: | ---: |
| Strict allocations and matching releases | 30,981,091 | 31,026,621 | +0.14696% |
| Normal minimum-of-three retired instructions | 911,699,045,229 | 911,834,590,197 | +0.01487% |

Both prospective +1% ceilings pass without amendment. One strict original /
candidate pair preceded the fixed normal sequence below; no sample was replaced.
All eight invocations exited 0, preserved every guard, and emitted the exact
original C above. Strict runs had zero leaked objects/bytes; normal streams
were empty. Actual instruction counters came from `/usr/bin/time -l`.

| Normal schedule | Retired instructions |
| --- | ---: |
| P1 | 911,699,045,229 |
| C1 | 911,887,049,188 |
| C2 | 911,834,590,197 |
| P2 | 911,701,161,683 |
| P3 | 911,706,863,705 |
| C3 | 911,876,491,344 |

The current larger source separately self-compiles with 31,282,038 balanced
allocations/releases. That descriptive result is not the matched comparison.
No speed or peak-memory improvement is claimed. Original paired-link flags and
hashes were recorded and their successful commands witnessed; detailed original
link stdout was not separately retained. Candidate link receipts are retained.

## Qualification and retained failures

- Seed/A/B/C emit identical current-source C. A and B agree on all 582 fixture
  contracts: 487 accepted and 95 rejected.
- B passes 585 native checks; complete components pass 4,374 hosted and 188
  target checks. All 27 target suite memory reports balance with zero leaks.
- The actual B main and an ASan/UBSan build both compile the whole current
  source with strict balanced accounting and identical C; no sanitizer reports.
- The new real-main fixture emits exactly 15 lines and balances 15 target
  allocations/releases. Doubling its ten label effects deliberately fails only
  the exact stdout oracle, preserving its five result lines.
- Independent code-reviewer and test-runner audits bind the exact frozen source,
  tests, native oracles, measurement inputs and raw results.

The first actual seed builds found nested `?=`, a private published payload
type and a shadowed local; each failure and correction remains recorded.
The first full component run found seven failures. Three exposed the genuine
List argument-origin regression, also reduced for records/variants and covered
by new red-first tests. Two expected rejections now intentionally accepted;
two pinned earlier context diagnostics. Their replacements check actual checked
identities or precise remaining no-context/postfix rejections, rather than
dropping cases.

The native proof uses the already approved allocation-debt policy: 117 existing
allocation FAIL rows remain explicit, and broad fixture instruction checks are
disabled. Neither is counted as resource acceptance; the separate matched T0
comparison above supplies that evidence. No existing resource limit changed.

Raw sources, compiler roles, hashes, private-environment pin, finite commands,
all samples, failed attempts, native C and independent audit receipts live under
the ignored `build/traits-implementation-2026-10-22/` directory. The original
archive and compiler roles remain the fixed comparison baseline for T1–T5.
The maintained broad commands are `scripts/blorp2-fixpoint --prove` with the
explicit debt/instruction policy above, followed by `make -C blorp_2
test-components BLORP2_COMPILER="$PWD/blorp_2/build/fixpoint/stage_b"`.
