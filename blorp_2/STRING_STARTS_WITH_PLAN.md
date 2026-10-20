# Ordinary target String.starts_with

Current integration status: the reviewed Starts body, tests and API are ported
with List callback helpers onto Option + Join main `09bdd5fb9db85df3d488ac02264845231770b943`.
Components and the final native gate passed under reviewed measured margins. The standalone
results below remain historical evidence, not a result for this composition.
See the [evidence report](../benchmarks/results/blorp_2_string_starts_with_2026-10-20.md).

## Current composition (2026-10-20)

All 48 Starts allocation definitions overlap fields already changed by published
Join. The initial port retained main values and replayed no old Starts tokens.
The measured follow-up changes only 80 failing fields after Root and peer review.
Join and Option bodies and predicates remain; no allowances are summed or stacked.
The composition gate exposed combined growth against the initial limits;
standalone resource approval does not grant combined-cost acceptance.

The body is byte-identical to the reviewed Starts candidate. Feature tests add
150 lines, including the two fixtures' 50 lines. The API notes preserve the Join
contracts and clarify the existing README's reference to the separate ordinary
List join wrapper. API scope is 13 added / 2 deleted, within 15 gross lines.
The actual vector had 512 outer callbacks, 667 passing semantic children and one
umbrella: 1,180 markers / 421 positive cost rows; components passed all 3,661.
The first gate failed 85 allocation rows and 13 overlapping instruction rows.
The next run failed one instruction field by 40,558; four reviewed margins are applied.
Both failed receipts remain unchanged; final native passed all 1,180 markers / 421 rows.

## Historical proposal and execution stages

The following preview, original thresholds and continuation instructions are
retained history. Their UNRUN and HELD labels describe those earlier stages;
the current results and approved limits are recorded in the final section.

Status: canonical source/test-first preview, UNRUN; root and independent
API/ergonomics, code/data and test review precede plan publication. Implement
only after publication and observed REDs; compiled work needs an exclusive START.
The earlier queue and contract02 packets remain sealed.

## API and source invariants

Add `pure func starts_with(value: String, prefix: String) -> Bool` to target string.
Empty prefix is True; compare counted bytes until prefix end (True), first
mismatch or missing value byte (False). Case, UTF-8 spelling, BOM, NUL and LF are
exact. Named and UFCS calls borrow both inputs; no normalization or reconstruction.
The String-specific helper uses existing byte_at, Int equality/add and match.
Positions stay in 0..length(prefix), inclusive. Increment occurs only for a present
matching prefix byte, hence below length; recursion reaches exactly length, where
byte_at returns None. No negative position or overflowing increment is formed.
The full module and fragment include a permanent note beside prefix_bytes_equal:
linear native-stack use is temporary; replacement needs accepted scalar loops.
No @tail_recursive/TCO/constant-stack claim, hidden clamp or ASCII restriction.
4096 matching bytes is bounded coverage; stop on stack failure without shrinking
that witness or changing stack limits. No per-byte String is built; Option/ARC
may allocate. Hold if temporary stack use is unacceptable. Preserve existing
exports; no new builtin/runtime/Char/Bytes/prelude/framework or Slice dependency.
Keep both source consumers (load:96, utils/text:9) queued for later migration.

## Frozen baseline, complete library and tool roles

B is accepted Numeric `a656f5ce1de963c8e9c162460e181d696b39c1d5` through all repairs.
SOURCE41.json binds all 41 compiler files to B and the retained producer pins.
C changes only string.brp: constructor imports, one IntOps alias and the helper/API.
FULL_LIBRARY_B_C.json freezes all 12 B/C library members; both use B's README.
The 11 compilable B members match retained pins; their historical README differs.
FEATURE_ONLY_LIBRARY.preview.patch adds 18 lines, deletes one, net +17; fragment
19 lines, complete C string module 44. No queued Slice/Path/List API is inserted.
Use the same retained physical normal02ecee8f / diagnosticef9365be pair for B/C;
both were linked from C9ab6dde0. TOOLS_AND_RETAINED_PAIR.json binds full hashes,
root-local paths, modes, generation/link receipts and clang/time identities.
ROOT974 plus explicit HOST_STD91 run host TestSuites; all pins/modes were checked.
Source41 is unchanged: no rebuild, new HOST/construction campaign or cost claim.
Preserve existing HOST caps, metrics and producer/STD roles; transfer no allowance.
All library postimages are ignored review files, not installed production source.

## Four relative cost controls

FOUR_COST_CONTROLS.json binds exactly these fixtures, old caps and native oracles:

| Fixture under test/e2e/fixtures | Allocations cap | Instructions cap |
| --- | ---: | ---: |
| return/zero.brp | 131100 | 440000000 |
| mortal_string/alias.brp | 150000 | 600000000 |
| string_literal/unicode.brp | 134000 | 450000000 |
| string_operations/concat.brp | 205000 | 600000000 |

These cover default imports, live owned aliases, UTF-8 literals and UTF-8/NUL concat.
Use one fixed corpus/library/output slot; install COMPLETE B/C outside measurement
and restore B in finally before classification, without changing root/other trees.
Per fixture: diagnostic B-strict,C-strict require one positive balanced allocation/
release report and zero leaked objects/bytes; normal B1,C1,C2,B2,B3,C3 requires
memory modes unset before timing and one positive retired-instruction counter per
sample. Take min(all three) per variant: 32 compiler calls if later authorized.
Retain all raw streams/status/counters/C; all eight C outputs per input must match.
Link unmodified C with existing strict sanitizer flags; check each real-main oracle.
Targets are +5%, hard ceilings +10%, independently for allocations and normal min3
instructions on EACH input; old absolutes also bind. C*100>B*105 is a target miss,
C*100>B*110 a hard miss. Report each target miss for root review; a miss <=10%
within other guards does not stop remaining authorized controls. No aggregate
win offsets a miss. Hard/absolute breach, drift, invalid/missing counter, unexpected
C/status/semantic/leak/sanitizer result or scope/LOC breach stops immediately.
No retry, filtering, widening, baseline roll, borrowed old samples or allowance.
No original Slice success sample, remaining491 state, HOST or C-only call repeats.

## Existing semantic gates and new feature tests

FULL_CORPUS_IDENTITY.json is source identity for 870 accepted-B test files, not
870 executable cases or a full-corpus min3 claim. TEST_PREVIEW_MAP.json binds
four new files and two additive registry lines; the other 869 files are identical.
Existing full tests/harness own the semantic gate: preserve all old literal
status/stdout/stderr, expected-C, diagnostic/output-state oracles and absolute caps.
Run focused checks then usual unit/runtime/grammar/full-native gates; record actual
coverage/failures. Their existing absolute checks add no relative cost controls.
The two real-main fixtures have 20 argv rows plus one counted-NUL/lifetime row;
EXPECTED_CASES.json and unchanged test previews bind exact bytes and statuses.
Cases cover empty/equal/short/long prefix; first/middle/last mismatch; case;
UTF-8/emoji/decomposed spelling; /library/ containment/siblings; LF; 4096 matching
bytes and late mismatch. NUL is source text, never argv. Aliases survive repeated
calls and a String escapes its producer; named, UFCS and pure calls must admit.
The missing-argument branch remains an optional fixture-contract witness.
Install only the tests first; observe actual missing-export RED via admission and
CLI, retaining full message/help/SourceId/byte spans/status. Do not guess diagnostics.
After GREEN inspect generated C: ordinary byte calls, no per-position extraction/
encoding. Prove source-valid mutants equality->True, increment->2, missing-value
->True: each compiles and fails its named semantic witness. Restore exact bytes
before fresh affected GREEN; compiler/setup failure is not a kill. Use existing
Example/verify_all, strict C11/Wall/Wextra/Werror/pedantic/O0, ASan/UBSan/no-recovery
and real main. No C rewrite, alternate entrypoint, new harness or shared framework.

## Bounds, review and holds

Hard physical limits: production 45 gross/+45 net; tests 180 gross/+180 net with
registry; two fixtures/70 combined lines; README API/temporary notes plus
GUIDE/GRAMMAR pilot API crossrefs share 15 lines; no grammar production change.
Previews: tests 148+2 registry, including 50 fixture lines; API notes seven lines.
Each C-only fixture has proposed 150000 allocations/600000000 normal min3 limits,
no successful absent-feature B denominator. Stop before any bound is breached.
Supporting inventories and execution details remain binding in the packet JSON.
Code and test-runner review precede any later implementation commit. Dirname stays
held behind accepted prerequisites. Normalize stays held: growing List.append
endpoint metadata is O(k^2), a valid negative design, not permission to implement.
No Path engine, source shim/migration, SOURCE gate waiver or old campaign restart.

## Remaining-cost characterization: one bounded continuation

Retained evidence is3 RED and26 initial GREEN calls, then2 strict cost calls.
Return/zero allocations14534->17200 (+18.34%) FAIL the original +10% hard ceiling;
status0, balanced/zero leaks and identical C do not waive that failure. No normal
instruction sample ran. The receipt's false instruction_target_miss is unobserved,
not an instruction PASS. Preserve both strict calls/raws/C and all old identities.

After Root+peer review and publication of this amendment, a separate exclusive
START may select ONLY original COMMANDS.json objects[2:] (indices3..32), once:
6 return/zero normal samples and8 samples for each other original control. Never
repeat indices1..2. Original a656 B/source41,02ecee8f/ef9365be producers,complete12
B/C libraries, literal argv/CWD/env/input/output/report paths and ceilings remain.
Only this30-call characterization may continue after valid allocation/instruction
values breach the unchanged5% targets,10% hard limits or old absolutes. Record
all such failures; this is no cost PASS, acceptance, waiver or permission to widen
caps. The original return/zero allocation hardFAIL remains binding regardless
of later numbers; no aggregate win offsets it. No retry, repair or resampling.

All nonnumerical STOPs still bind: status/stream/C identity, invalid/missing/zero
counter, leak/balance, pin/ownership/scope/LOC or restoration failure. Restore full
B12 and output state BEFORE each classification. Stage only the same3 pinned
fixtures; restore original13 files/6 directories before RETURN or first STOP.
No cost waiver is requested before collecting remaining instruction/control data.
C-only/native/mutant/full-gate/API work stays HELD. Plan publication is not START.

## Allocation exception requiring explicit approval (2026-10-20)

This appendix takes effect only after Root, independent peer and human approval.
All historical plan text, baselines, raw FAILs and producer epochs above remain.
Current-main composition at468b used source-matched0fae/9b22 and host498/STD91:
components3646PASS; two untimed C capturesPASS; full-native exit1 with57 existing
allocation failures,665 semantic-childPASS,419 positive cost rows and no
instruction-ceiling miss. The observed four-command statuses remain0/0/0/1.

For exactly the four original fixed-a656 allocation controls, the proposed hard
exception requires ALL of C<=the absolute final cap below, C-B<=2800 and
100*C<=120*B. B remains its original observed allocation count. The2800 bound
rounds max observed delta2668 plus100 to the next100; it is independent per input,
never a pooled allowance. No previous ceiling increase is added to these caps.

| Original control | Fixed B | Observed C | Absolute final cap | Headroom |
| --- | ---: | ---: | ---: | ---: |
| return/zero | 14534 | 17200 | 17334 | 134 |
| mortal_string/alias | 15882 | 18549 | 18682 | 133 |
| string_literal/unicode | 14981 | 17647 | 17781 | 134 |
| string_operations/concat | 18074 | 20742 | 20874 | 132 |

These allocation5% target misses and original10% hardFAILs remain recorded.
All four original normal-min3 instruction5% target misses,10% hardPASSes and
old absolute limits remain unchanged. This introduces no instruction exception;
Root review of target misses still follows the original rule.

For current-main native allocation ceilings, change only the48 reviewed literal
definitions covering57 failed rows and4 passing shared users. Each final literal
is ceil_to100(max observed allocation among ALL users+100):100..199 allocations
above that definition's measured maximum. This is a final replacement, not an
increment to stack with an earlier allowance. All419 instruction ceilings,
358 other allocation rows and both new Starts150000/600000000 limits remain.
The reviewed unapplied patch and definition/user math must stay with the evidence;
no new lookup, harness rule, runtime mechanism or moving rebaseline is introduced.

Arithmetic against existing observations is not a rerun or a green normal gate.
Separate finite approval is required for any validation after applying caps.
Strict-native accounting remains HELD: propose2 diagnostics1 strict sanitizer
links of the two retained current C files and21 existing real-main cases with
BLORP_LEAK_CHECK=strict, exact stdout/status and one positive balanced zero-leak
report per case. The normal diagnostics0 native links do not satisfy this hold.
No merge before the required reviews, human resource approval and remaining gates.

The same explicit resource approval must include a narrow test gross-addition
exception180->200 for this Starts composition only:150 existing testADD plus48
allocation-literal replacementADD =198ADD/48DEL, net+150. The+180 net test ceiling,
production45gross/+45net, two fixtures/70 combined lines and shared15-line API
ceiling stay unchanged. The200 ceiling is final, not a stackable+20 allowance.

## Current validated status (2026-10-20)

This section records the reviewed standalone Starts worktree at 468b, before
the published Join composition above. Its PASS results do not validate the new
09bdd composition or amend any governing current-main limit.

The current composition at `468b98b863eba89dab762d197c3cd91b0cdf8fe1` passed
all 3,646 component callbacks. Its first full-native run retained exit 1 and
57 allocation-ceiling failures, with 665 semantic children passing and all
419 cost rows present. Receipt `39aca20d` remains FAIL; it was not rewritten.

After explicit human approval, 48 allocation literals were changed exactly.
They cover 57 failing rows and four passing shared users; 358 other allocation
rows and all 419 instruction ceilings remain unchanged. The four original
fixed-a656 allocation exceptions above and test gross-addition ceiling 200
were approved together; the test net ceiling remains 180. The old four
allocation hard failures and all original 5% target misses remain recorded.
The maximum original increases were 18.343195% allocations and 8.140718%
normal-minimum-of-three instructions; no instruction threshold was amended.

The final maintained full-native call passed with exit 0 and empty stderr:
49 groups, 510 outer callbacks, 665 native semantic children and one umbrella,
exactly 1,176 PASS and zero FAIL. All 419 positive cost rows met the exact
approved allocation and unchanged instruction ceilings. Receipt
`b9377c756af1793d89b155dc256ba927d539e9c199d0b61454ca6f5a079e6466`
records that executed gate and its passing source, library, test, tool,
environment, cap and logical-Git closure. The final gate is complete.

Separate strict-native accounting also passed: two diagnostics-enabled
sanitizer links and all 21 existing real-main cases. Each of the 20 argv cases
reported six allocations and six releases; the counted-NUL/lifetime case
reported 21 and 21. Every report had zero leaked objects and bytes, with exact
stdout and exit status and no other stderr. Receipt
`2666171c17a5a37d2c52ee7c1e87770dfbcf3da4382bb91a430336337880f6bf`
closes only that fixture-accounting hold. Three source-valid faults were killed
by their named existing witnesses and followed by three fresh restored greens.

Production remains 17 added / 1 deleted; tests are 198 added / 48 deleted,
net +150, including the two fixtures' 50 lines. Shared API documentation is
12 added / 1 deleted, within 15 lines. This plan and the benchmark evidence
report are separate design/evidence documentation. Coverage and all other
limits are unchanged.

Native stack use remains linear in the matching prefix. The unchanged 4,096-byte
witnesses provide bounded coverage, not a constant-stack or TCO guarantee.
Compiler measurements and whole-native-process counters do not establish the
helper's runtime cost or allocation rate. Source consumers remain queued.
Final documentation and independent code/test review precede Root commit,
merge and publication. Frozen packets and historical raw results stay intact.
