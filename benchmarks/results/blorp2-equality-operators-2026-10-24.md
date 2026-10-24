# Blorp 2 equality operators: implementation and qualification

Date: 2026-10-24. Status: landing at the user's explicit request based on functional
confidence. Components, direct native behavior, source fixpoint and fixture parity
pass. Matched costs, whole-source sanitizers and deliberate faults remain pending;
no performance or release qualification is claimed.

## Change and hypothesis

The bounded design is [EQUALITY_OPERATORS_PLAN.md](../../blorp_2/EQUALITY_OPERATORS_PLAN.md).
`==` selects canonical `Equatable.equals`; `!=` selects canonical `not_equals`,
including an authored override. Operands evaluate eagerly once, left then right.
The configured prelude selects the trait identity; imports and free names cannot
redirect operators. Equals-only canonical traits remain valid; missing inequality
is diagnosed at its token. Malformed reserved defaults reject during admission,
after ordinary signature and existing canonical-contract errors.

Parse publishes a closed `EqualityExpression` with the operator span. Check stores
one accepted canonical descriptor containing method identities, derives its owner
from equals, and reuses `PlannedCall` through the ordinary accepted receiver call.
No checked operator node, specialization state, lowered operator, ownership rule,
runtime helper or emission case was added. The hypothesis is that this bounded
admission/parser work stays within the plan's current-parent cost ceilings.

## Provenance and reproducibility

Isolated validation base: `a9b1939155aa748d5ccfc1eea85eeb51e771bafa`.
Integration preserves the user's `e94940f6d` UFCS-only edit to `unicode_escape`;
that separate source composition is not relabeled as the frozen validation input.
Implementation source/library manifest: `913291dab27bf1ceee45f6ac237257d65fa642d282cc0170e6f75ada316b2135`.
Production diff: `663c7eaf513df0f8d4d01675b1a7c31f71ce376d814a0583e0229d93b7f37c7e`.
All raw evidence is under [build/equality-operators](../../build/equality-operators/).
[Source freeze](../../build/equality-operators/CANDIDATE_SOURCE_FREEZE.json),
[functional freeze](../../build/equality-operators/FINAL_FUNCTIONAL_INPUT_FREEZE.json)
and [A inputs](../../build/equality-operators/candidate-pair/A_INPUTS.json) pin the inputs.

The pinned B2 seed `de61a35911baf9222ccc470d64ecf815fe519012` produced candidate A;
its binary SHA-256 is `7962bdeb0d1c2b65485fe53fb3d83bfe4cb4d327d4277a68ab095a0b6ae0f1ce`.
Actual A then compiled the frozen current source to B C with strict diagnostics:
32,101,907 allocations/releases, zero leaked objects/bytes. Legacy runs TestSuites only.
Apple clang 21.0.0, arm64-apple-darwin25.6.0; compiler links use `-O0 -lm -lpthread`
and `BLORP_MEMORY_DIAGNOSTICS=0` for normal, `=1` for diagnostic.

| Artifact | SHA-256 |
| --- | --- |
| Candidate A C | `3f00c03bc6de6edfbdcc397a74bf86a11da6255ac890f9cbf8683f82d1e2ca01` |
| Candidate A normal | `de5f134d5bc5f34de7c2145c33bf35166ee363a9208856596599cfa59570c244` |
| Candidate A diagnostic | `b0ea63dfb9a148d72e9f78c1a049440b534cc2e6bc57df71524cd2e3d96d904f` |
| Genuine candidate B C | `34db688fc63f96d6891111720669553c2734e092ee11d8de429b77b0b839e324` |
| Genuine candidate B diagnostic | `2b74705f2c35bfc9b488a5078c5e3dcf3bfb68962d0bf03c22493f93a0fd0d9c` |
| Genuine parent B normal | `765d1b200a227c4b599f0bee894de97687659ff9327c9b22cbfdc5d13b101c66` |
| Genuine parent B diagnostic | `d17aa13cae821141f756e6e6c274e2ed31a3636311f66d0cbb3df624842e7461` |

[Parent lineage](../../build/equality-operators/PARENT_LINEAGE.json) retains all A/B,
seed and C identities. Candidate B normal and final measurement identities remain
pending the matched epoch's final JSON; the diagnostic sample below is not that epoch.

## Red witnesses and functional results

The genuine parent B rejected the initial `match 7 == 7:` witness at 2:13:
``expected `:` after match expression``; help explains that block headers end in `:`.
It rejected the retained initial native operator input at 16:10: `unsupported character`;
help requests ASCII declarations/literals/names/calls and adjacent `->`.
Both exited 1 with no output C. Exact commands and original wording are in
[red operator metadata](../../build/equality-operators/red-operators.json) and
[red native metadata](../../build/equality-operators/red-native-operators.json), with adjacent stderr files.

| Gate | Observed result |
| --- | --- |
| Initial focused lex/parse/Check/Specialize/grammar | 116/116 passed |
| Expanded final Check, including raw Bool-constructor parity | 21/21 passed |
| Earlier full host components, before the last added case | 4,731 passed, zero failed; exit 0 |
| Initial maintained target components | 188 passed, zero failed; exit 0 |
| Source fixpoint | A, B and C emit identical `34db688f...` compiler C |
| Fixture parity | 589/589 identical under A and B |
| Independent final components | 4,732 hosted + 188 genuine-B target = 4,920 passed; zero failed; exit 0 |

[Final component result](../../build/equality-operators/FINAL_COMPONENTS_RESULT.json)
records 27 positive balanced target reports and unchanged frozen guards. Earlier
logs are in `implementation/`; the final run uses the legitimate FRESH local
legacy TestSuite host built at `-O2` and genuine candidate B diagnostic at `-O0`.

Empty-list literals compared with a nonempty literal retain the ordinary call's
inference failure in both operand orders. A Bool result also cannot infer Self
for `True == True` or `True != True`; exact constructor errors match explicit calls.
Native fixtures therefore supply typed Bool and empty-List operands. No inference
algorithm changed. Initial pinned-seed feedback required explicit enum/result
annotations and direct matches where Option `and_then` was unavailable or lambda
context was insufficient; those were bounded source-subset corrections.

## Native behavior and initial new-fixture ceilings

Direct A and actual self-built B produced the same four fixture C hashes and real
main outcomes. Native C was unmodified and built with `-std=c11 -Wall -Wextra
-Werror -pedantic -O0`, diagnostic memory mode 1, default compiler depth limits.
Each native run emitted one positive balanced strict report, zero leaked objects
and bytes. Stdout was empty except order: `left\nright\nleft\nright\n`.

| Fixture | Main | Native allocations/releases | Initial B CLI allocations | Initial B CLI instructions | Caps: allocations / instructions |
| --- | ---: | ---: | ---: | ---: | ---: |
| operators | 23 | 36 / 36 | 236,887 | 1,914,654,836 | 275,000 / 2,250,000,000 |
| dispatch | 23 | 1 / 1 | 129,178 | 1,609,196,282 | 150,000 / 1,900,000,000 |
| order | 23 | 5 / 5 | 126,438 | 1,600,311,068 | 145,000 / 1,850,000,000 |
| nesting | 23 | 1 / 1 | 176,650 | 1,886,750,177 | 205,000 / 2,200,000,000 |

These are single direct diagnostic-B CLI samples from `/usr/bin/time -l`, retained
in [direct B observations](../../build/equality-operators/DIRECT_B_NATIVE_OBSERVATIONS.json),
not normal min-of-three comparisons. Caps leave roughly 15–18% initial headroom;
maintained-harness paths differ and its complete final run remains required.
Initial peak RSS was respectively 10,141,696; 8,650,752; 8,650,752; 10,698,752 bytes.

Generated C inspection confirms separate ordered operand temporaries before each
ordinary method call. Marker equality and inequality select distinct authored
bodies, both returning False. The operator and explicit 64-level Bool counterparts
each emit 64 calls to the same ordinary Bool equality target: maximum parenthesis
depth 1 and nested-brace depth 0 within either generated comparison function.
The C-depth observations are retained in `implementation/native/nesting-c-depth.json`.

## Size, pending cost decision and remaining gates

| Scope | Gross additions | Gross deletions | Net |
| --- | ---: | ---: | ---: |
| Handwritten compiler production, 12 files | 201 | 61 | +140 |
| Tests/fixtures/observers, 18 files | 1,269 | 12 | +1,257 |
| Owning docs/grammar/approved plan, excluding this report, 5 files | 392 | 8 | +384 |

Parent compiler production is 43,203 lines; +140 is approximately 0.324%, below the
+200 investigation point and +300 hard ceiling. This report's own lines are separate.
Coverage was not removed or compressed to meet the production limit.

| Matched measurement | Allocations | Normal retired instructions, min 3 | RSS / C identity | Decision |
| --- | --- | --- | --- | --- |
| Current-source whole self-compile: parent B vs candidate B | Pending | Pending | Pending | Pending |
| Unchanged return-zero control: parent B vs candidate B | Pending | Pending | Pending | Pending |
| Unchanged membership control: parent B vs candidate B | Pending | Pending | Pending | Pending |
| Explicit-call control: parent B vs candidate B | Pending | Pending | Pending | Pending |
| Operator vs explicit-call fixture: candidate B | Pending | Pending | Pending | Pending |
| Original frozen workload: Original / parent / candidate | Pending | Pending | Pending | Pending |

Current whole-source growth above 2% requires investigation; 5% in either metric
requires rejection/rescoping. Original trait-roadmap cumulative 5% ceilings retain
their original workload and separate provenance; percentages are not compounded.
Frozen inputs are retained in `MEASUREMENT_INPUT_FREEZE.json` and
`ORIGINAL_REFERENCE_VERIFIED.json`; verified historical bytes are not fresh samples.
B/C source identity and all 589 fixture pairs pass. Separate strict whole-source B
compilation, ASan/UBSan, dispatch/order faults and matched costs remain pending.
The user explicitly requested landing on reasonable functional confidence rather
than completing those remaining measurements before this commit.
The maintained proof reached source identity and all fixture pairs. Its full
native-B phase was stopped at the user's request during host-suite preparation;
that full native gate is not credited. It used `record-allocation-debt` with
instruction checking disabled; any recorded debt remains a failure disclosed under policy,
and cannot establish a passing cost gate or excuse other failures.
Seed publication, pin rotation and compiler/library operator migration are not done.
