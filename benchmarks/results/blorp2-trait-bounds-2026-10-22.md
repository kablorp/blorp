# Static trait bounds, defaults and method values

T3 implements function/receiver bounds, trait defaults and contextual method
references against T1 `93f15c05d5fe9fd6ec1f2e05d420d4c9559440c8`, integrated on
main `29b198178b52c07a3ef28301e6172107c5ba20f9`. Full qualification passes with
explicit allocation debt retained. No speed improvement is claimed.

## Change

Function type parameters and full implementation families may declare trait bounds.
A generic body proves calls from its declared requirements, even when unused or
called only with a satisfying concrete type. Bounds never choose between two
implementations with the same trait and receiver head. An authored family has
one resolved head and ordered located bounds; each actual body normalizes its
binders into its own genuine function identity.

Trait defaults are ordinary checked bodies with genuine function IDs and a
body-owned implicit Self. The trait contract is accepted once before function
signatures; the default signature borrows and normalizes that accepted contract.
Default-only implementations need no colon or invented body. Contextual unbound
method references use an expected callable type to solve Self. Check retains
the symbolic method and semantic receiver in MethodCallable until Specialize
selects an ordinary body through the existing function-request graph. No trait
representation reaches
Lower, Own, Verify or Emit; physical layout sharing and semantic instance keys
remain as established by T2.

The existing transient generic dependency graph now records signed constructor
depth changes and rejects positive abstract cycles. This is a sufficient proof,
not complete finite-program admission. Finite Box/Wrap relays and generic fields
containing three nested Lists remain explicitly rejected proof limitations.
Deep generic record/union equality is a T4 completion blocker, not a finished
automatic equality contract. There are no runtime dictionaries, receiver-bound
partial applications, independently generic trait methods or trait parameters.

## Local evidence

- Full hosted unit/runtime/grammar selection: **4,458 PASS, 0 FAIL**, 409 closed
  suites, 85.329 seconds, empty stderr and unchanged source/tool guards.
- Maintained target selection: **188 PASS, 0 FAIL**, 27 closed suites and 27
  positive, balanced strict reports; no leaks or other diagnostics.
- Four native/CLI cases pass through the ordinary harness. Three actual mains
  return 23 in normal and ASan/UBSan builds, with positive balanced target
  accounting. Opaque dispatch, defaults, lexical scope, stored/returned method
  values, finite recursion and exact `left\nright\n` effects remain observable.
  An uncalled missing-bound body rejects at its exact diagnostic and preserves
  both an absent output and an existing sentinel.
- Four ordinary-input mutations each produce exactly one named native failure
  (actual main returns 0 instead of 23) with three positive controls passing.
  Disabling the rigid missing-bound rejection produces exactly three named
  failures and two positive controls in the complete owning unit suite.
  Only ignored copies were mutated; live production bytes remained unchanged.

First direct diagnostic CLI samples established the new fixture budgets:

| Input | Allocations | Retired instructions | Initial allocation / instruction limits |
| --- | ---: | ---: | ---: |
| Dispatch | 44,225 | 147,810,120 | 49,000 / 170,000,000 |
| Defaults | 27,515 | 77,330,450 | 31,000 / 90,000,000 |
| Finite | 71,635 | 185,566,452 | 80,000 / 210,000,000 |

All counts were positive and balanced with zero leaks. Limits were frozen before
maintained harness runs; those runs passed without raising a limit. These small
fixture budgets are separate from the cumulative **+5%** allocation/instruction
ceilings against the preserved pre-T0 `02b13d25d` workload.

## Integrated qualification

The maintained fixpoint proof completed in 839.071 seconds. Actual A, B and C
emit identical compiler C:
`027cd81a0cd6e058804ca9e8bd8d284c73ccec9eaa9d9ef3bc32d5c77e989045`
(20,786,925 bytes). All **582** ordinary A/B fixture comparisons agree, and
**592** outer native callbacks pass under the actual self-compiled B.

The complete B component gate passes **4,646** checks: 4,458 hosted rows
(including 334 nested runtime checks) and 188 maintained target callbacks.
All 436 suite frames close; all 27 target strict reports have positive balanced
allocation/release counts and zero leaked bytes. The legacy executable hosts
untranslated TestSuites only; Blorp 2 compiles every target/e2e input.

Whole-current-source compilation under B passes strict leak checking with
**33,760,097 allocations and releases, zero leaked objects/bytes**. Linking the
same actual A-emitted C at `-O0`, diagnostics=1, ASan+UBSan and no sanitizer
recovery produces the same strict counts and identical C, with no other
stderr. The sanitized compile completes in 311.396 seconds.

Eighteen additional ordinary CLI calls use actual A/B roles and the identical
isolated libraries: five accepted inputs and four rejected-output cases per
role. Accepted C, status and streams agree. Rejections retain exact diagnostics
at 4:15 and 5:5; absent output stays absent and existing sentinels survive.
No fixture main, generated C, host stamp or runner was rewritten.

The broad gate retains **119 allocation-debt FAIL cases**, compared with 118
in T1. Only `nested generic deep` is newly over its unchanged 180,000 cap:
180,581 versus T1's 179,722 (+859, +0.478%; 581 over cap). This modest debt is
accepted under the existing policy. Every existing cap and FAIL remains visible.
Broad fixture instruction checks are disabled/unmeasured; their behavior PASS
is not resource approval. Matched costs below are separate measured evidence.

## Matched cumulative costs

Both compiler roles compile the unchanged 57-file frozen pre-T0 input from
`02b13d25d04b7c5670cb94052ea9675cc9ba3428`, with the same CWD/output path,
private environment, pinned toolchain and ordinary entrypoint. The candidate
roles were genuinely built from the complete source11 producer (44 compiler
modules plus 14 library modules), byte-identical to integrated production.
One positive balanced strict pair and the predetermined normal schedule
P1/C1/C2/P2/P3/C3 were collected serially, without resampling.

| Metric | Original | T3 | Change | Ceiling |
| --- | ---: | ---: | ---: | ---: |
| Strict allocations/releases | 30,981,091 | 31,181,079 | +0.646% | +5% |
| Normal minimum-of-three retired instructions | 911,690,615,038 | 914,709,447,068 | +0.331% | +5% |

All eight calls succeed, counters are positive, strict leaks are zero and
per-call/global guards are unchanged. Each role emits its fixed expected C:
Original `276cdc4811404c6949da747a6099acbd124fc54da7b5c582348027709864dbc0`,
candidate `38374a2178e4b5016f8cf6d18015700993eb8c32fc7749bb1f79cc87921b122d`.
These differ under the approved role-specific output policy; A/B/C parity above
compares the current compiler against itself. Costs are cumulative against the
original, not a compounded parent allowance.
Original detailed paired-link stdout was not separately retained; original
C/binary/flags and the frozen coordinator provenance remain available.

## Provenance and limits

The unchanged pinned-seed Make recipe generated current-source C
`595bf32fe5c4ea78d12e668ed92f61f52170467e53b286cbbcad3c3cac6f08c1`:
20,763,559 bytes and 2,816 dense function definitions. Ordinary Make links use
`-O0` with diagnostics macros 0 and 1 from that same C. This is seed-generated
C, not a claim about a later current-source or frozen-Original self-compile.
The actual seed loop retained six source-subset failures before success;
explicit type annotations, one local rename and one import fixed those causes.
Hosted setup failures and the numeric-pattern fixture correction also remain
retained. None receives behavioral or resource acceptance credit.

T3 production changes are 1,277 added / 470 deleted / **+807** lines. Cumulative
production growth is +2,158 against the +2,000 review envelope; Root accepted
that 158-line variance without changing the measured +5% ceilings. Tests and
fixture-library growth are separate: tests 1,685 added / 163 deleted / +1,522;
isolated fixture library 41 added / 0 deleted / +41.
No formatting compression, coverage deletion or cosmetic refactor offsets it.

Immutable worker packets, native samples and fault vectors are under
`build/traits-T3/`. Actual guarded RUN logs are under
`build/traits-implementation-2026-10-22/T0-qualification/`, including
`T3-final-current-full-hosted41`, `T3-maintained-target-components38`,
`T3-native-maintained-four37` and the five `T3-fault-…39` directories.
Root closed qualification, frozen costs, actual-role pins and independent
reviews are under `build/traits-implementation-2026-10-22/T3-qualification/`.
Full proof/component/strict/sanitizer and 18 CLI raw calls retain complete
commands, streams, guards and results under the common `T0-qualification/`
artifact root; that directory name is historical, not a T0-only result claim.
The final publication manifest binds the exact code/tests/docs and reviews.
