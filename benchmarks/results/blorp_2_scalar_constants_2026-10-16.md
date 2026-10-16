# Scalar and String constants

**M5a.1 accepted:** focused tests, six mutations, costs and actual-main unit/e2e
pass. Full M5/self-compilation remain incomplete.

## Accepted facts and scope

One inventory `ConstantId` survives imports, checking and body reads. All
annotations precede closed Int/Float/String initializer checks, including unused
declarations. Specialization projects ordinary literals at each use span;
existing lowering/ownership handles fresh values and Strings. No evaluator,
global owner, concrete constant table or runtime change is introduced.
Record initializers, initializer references/cycles and ordinary opaque constants
remain subsequent slices in [the plan](../../blorp_2/CONSTANTS_PLAN.md).

Against the accepted keyword/UFCS source `225c8f764`: production **351 added /
92 deleted, net +259**; tests excluding fixtures **1041/11, net +1030**;
fixtures **60/12, net +48**, including the unchanged provider-file rename.
Production stays within 440 added / +360 net. Root/independent expert reviewed;
a separate runner validated.

## Current-base evidence

The current-base focused gate passes **300 callbacks/26 suites**: constants,
namespace, keyword lifetime and UFCS. Historical standalone evidence stays separate.
Six unchanged source mutations produce **nine named semantic failures in 24
callbacks**, then all 24 restored callbacks pass. They protect constant identity,
annotation errors, use spans, fresh values, separate drops and emitted bytes.
Source and semantic Git index are unchanged; a raw index stat-cache refresh is
retained explicitly, not misreported as byte identity.

Matched cost acceptance contains **3604 calls**: 902 strict, 2652 normal,
42 candidate-only scaling and eight frozen-host build proxies. A Bash 3.2
empty-array setup failure preceded all native builds. Its three samples remain
excluded; one reviewed fresh 42-sample repeat makes **3607 actual attempts**.
No failed measurement or adaptive minimum was discarded.

| Unchanged inputs | Allocations B → C | Sum of per-input min-three normal instructions B → C |
| --- | ---: | ---: |
| 349 accepted | 4658417 → 4658417 | 14849141529 → 14904395620 (+0.372103%) |
| 93 rejected | 704480 → 704480 | 3049161371 → 3062663534 (+0.442816%) |

Each input has identical allocations; worst normal increase is **0.665716%**.
Full diagnostics/outcomes/shared accepted C match. Three old rejections change:
two real mains now exit 7; the provider reports the exact missing-main error.
All strict reports are positive, balanced and have zero leaked objects/bytes.
Per-input 5% target/10% hard limits remain unchanged.

The host source-to-C proxy grows **1.235086% instructions / 1.184819% allocations**,
within 8%/10% caps. Normal measurement unsets both memory variables outside
`time`; strict allocation runs are separate. This omits pilot self-compilation.

| Dimension N | Unused Int declarations: allocations / normal instructions | One String, N reads | N Strings, N reads |
| ---: | ---: | ---: | ---: |
| 16 | 9615 / 37114741 | 11174 / 39957458 | 12150 / 41439858 |
| 32 | 10649 / 38762633 | 13675 / 44137792 | 15681 / 47403412 |
| 64 | 12707 / 42138454 | 18656 / 53142481 | 22851 / 60176427 |
| 128 | 16948 / 49140844 | 28732 / 73247237 | 37158 / 87428822 |

Twelve phase callbacks prove counts/fresh lower IDs. Unused declarations emit
identical 181-byte C; String families agree at each N
(5882/10426/19514/37917 bytes), lexical depth two. All 14 programs pass plain and
ASan/UBSan builds/runs (28 each) at default limits. This establishes no general
asymptotic bound. Per-use String allocation is deliberate; sharing waits for the
separate CTFE/immortal-storage contract.

## Actual-main acceptance

`make -C blorp_2 test` passes **2894 component checks** (2728 host callbacks,
166 nested runtime C checks) and **452 e2e checks**: 358 unmodified-C links,
529 real-main executions and 358 positive strict cost rows within ceilings.
One O0 pilot build emits the measured candidate's exact C. Its 83 host-generated
warnings remain in the same three categories; target C uses strict warnings and
ASan/UBSan. This is not a LeakSanitizer claim. Frontier is **36/38**:
lex at byte 7471 needs Char; specialize at byte 11650 needs function types.
Make/frontier take 261.23/20.74 seconds, bookkeeping rather than matched latency.
The distinct FRESH destination host `390bdd0d…` is unchanged; the separate O2
frontier pilot is linked from the same C emitted by that host. All 4667 input/
metadata pins and prior artifacts remain stable. Receipt: primary checkout
`blorp_2/build/constants-landing/`.

## Reproduction and retained evidence

Frozen host SHA `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`;
CLI-O0/runtime-O2/split8, bootstrap `dev-0e1598ed616e`, Apple Clang 21/macOS arm64.
Baseline pilot SHA `825cde56b9bde4a312fa6390d7468d0a81cbd2ea6262a1ff20566059948ad883`;
candidate SHA `45571a514cd1f12bb1491d918dffbce1255797862fd6b8eb0af3d1b2b7282512`;
candidate C `ca8248dd7cceea9860c4a53e1f9769bac4356fc68fbd14f00ba1ca08ca30b433`.

Raw receipts, commands, source/toolchain pins and samples are retained under
`/Users/keithphilpott/.codex/worktrees/roadmap-constants-current/blorp/blorp_2/build/roadmap-constants-current/`:
`EXECUTION_BRIEF.md`, `quality-integration/focused-gates/`, `quality-integration/cost-v2/` (original
failure retained), `quality-integration/cost-v2-scaling-repair/` (complete receipt
and arithmetic), and `quality-integration/mutant-rerun/`. Cost endpoints prove
unchanged sources, candidate, host/FRESH status, raw index and inputs. No host rebuild, fixture rewrite,
generated-function entrypoint, cache, counter bypass or ceiling change occurred.
