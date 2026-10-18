# Ordinary target Option/Result helpers — 2026-10-18

## Scope and frozen boundary

B is `6eb6886c76a4e6cc0427defe690b6ebb288bb9b6`. The candidate adds only
Option `is_some`, `is_none`, `get_or`, `to_result` and Result `is_ok` as ordinary
pure generic functions. The compiler's 41 source files, foundation and prelude
are byte-identical to B. Named operation imports are explicit. No callbacks,
traits, builtins, native helpers or compiler-source import migration are added.

Production: **29 ADD / 0 DEL**. Tests: **293 ADD / 4 DEL**, including one
43-line native fixture. Prospective bounds were 50 production additions,
300 test additions and 60 fixture lines. Documentation is counted separately.
The historical five-helper candidate and its failed/unverified epochs remain
preserved; none supplies a current acceptance denominator or waiver.

The [frozen epoch](../../build/bootstrap-evidence/option-result-ordinary-2026-10-18/FROZEN_EPOCH.json)
was reviewed before setup. The [independent packet](../../build/bootstrap-evidence/option-result-ordinary-2026-10-18/independent/)
retains commands, input pins, raw reports, emitted C and verdicts. Both variants
use the same source-matched pilot pair because compiler source is unchanged:

- Retained compiler C: `ddb3454d46eeb75559a3d24278dd6bcc12c98bbbb31209bebc3467e632118041`.
- Strict diagnostic pilot: `7b2f277de84169e08a947ad398eeb266f7168ce70e0c79ee467aba8b4b5d30b4`.
- Normal pilot: `1b07c314b6348e05b3303441197bc463243aa51db74f9252a64b07300679b690`,
  linked once from that C at `-O0`, `BLORP_MEMORY_DIAGNOSTICS=0`.

The retained diagnostic pilot uses `-O0` and diagnostics=1. Link warnings match
all 89 inherited messages in order. Functional host `c04f68ba…` remains FRESH
with explicit root STD91. These are target-input compilation measurements,
not target self-compilation or host-construction allocation measurements.

## Matched costs

B's nine and C's eleven library sources are frozen under equal-depth,
equal-length `inputs/B/standard_library` and `inputs/C/standard_library` roots.
Each control uses one frozen fixture path. Serial normal-mode samples use
`/usr/bin/time -l`, ordered B1, C1, C2, B2, B3, C3; the minimum of each three
is reported. Separate strict diagnostic runs require balanced positive
allocations/releases and zero leaks. No output is rewritten or normalized.

| Fixture under `test/e2e/fixtures/` | B allocations | C allocations | B normal min3 instructions | C normal min3 instructions | Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| `return/zero.brp` | 9,003 | 9,003 | 44,221,119 | 44,151,285 | -0.158% |
| `generic/managed/basic.brp` | 12,212 | 12,212 | 48,978,666 | 49,068,013 | +0.182% |
| `option_input/parse_int.brp` | 10,871 | 10,871 | 47,177,341 | 47,138,374 | -0.083% |
| `conversion/integer.brp` | 18,163 | 18,163 | 57,460,933 | 57,451,232 | -0.017% |

Every control has byte-identical B/C emitted C and meets the prospectively
frozen independent +3% allocation/instruction limits and existing absolute
limits. The small instruction differences do not establish a speed improvement.

The new API fixture has **35,720 balanced allocations**, **80,276,015 normal
min3 instructions**, and **118,913,506 diagnostic instructions**. Its prospective
limits are the unchanged generic owner limits: 150,000 allocations and 600M
diagnostic instructions, plus a separate 600M normal-min3 ceiling. All pass.
B actually rejects that input at its Option import with `could not read module`
for missing `option.brp`, teaching import-path help, exit 1 and no C. There is
no successful B denominator for this new input.

## Behavior, faults and acceptance

The ordinary main prints exact eager-default/error observations, managed String
payloads including UTF-8/NUL, and alias survivors; it also exercises Int and Void
instances. Phase tests check demand loading, foundation identities, rigid type
parameters, all five Pure signatures, concrete constructor layouts and selected
ownership acquisitions. Existing Verify/runtime suites retain their independent
contracts.

The [worker packet](../../build/bootstrap-evidence/option-result-ordinary-2026-10-18/worker/)
retains the genuine missing-module RED and four effective/restored faults:
removing purity fails the signature oracle; changing get_or's selected branch
and changing to_result's Some branch to Err each fail the exact Own oracle;
changing a predicate result fails the native stdout oracle. The to_result fault
changes the selected ownership source; it is not a literal acquisition-removal
experiment. Every restored focused/native control passes with empty stderr.
Introduced fixture/adapter setup errors are retained separately from semantic
REDs. The independent cost collector's initial wording assertion was corrected
to the actual retained read diagnostic without rerunning compiled observations.

Independent full components pass **3,397 callbacks**. Full e2e passes
**481 fixture callbacks + 586 nested native callbacks + one umbrella callback**
(1,068 total), with no failures/skips and empty stderr. The full harness observes
35,726 allocations and 120,292,137 diagnostic instructions for the new fixture,
under the same limits; this run uses the actual checkout library path rather
than the equal-length frozen cost roots. All 1,016 executable/input pins remain
stable. Tooling reuses its prior seven-pass gate with unchanged relevant hashes.

The actual compiler-source probe now exits 1 without C at
`src/check/check.brp:20:13`: `opaque types are not supported yet`, with the
existing fixed-record teaching suggestion. This is a frontier observation, not
a self-compilation claim; opaque support and callback support remain separate
increments. The [independent receipt](../../build/bootstrap-evidence/option-result-ordinary-2026-10-18/independent/RECEIPT.json)
records the final provenance and acceptance.
