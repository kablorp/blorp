# Named pure callbacks — validation, 2026-10-18

**Named callback validation passes the approved resource contract.** Named pure
function references and unchanged callback
parameter forwarding now have an implemented path from checking to ordinary
specialized direct calls. Parameters use structural callable types and separate
semantic callable IDs; ordered declaration/type choices belong to specialization
keys. Runtime data bindings stay dense, static arguments disappear, and managed
returns use the existing Lower/Own/Verify/Emit path and ABI. Imports/qualification,
generic substitutions and reference provenance remain explicit. The bounded
scope follows [NAMED_CALLABLES_PLAN.md](../../blorp_2/NAMED_CALLABLES_PLAN.md).

This increment excludes lambdas, captures, function storage/returns/aggregate
payloads and runtime callable values. Callback candidates themselves take only
data parameters/results. Callable parameters invoke directly as `f(value)`;
declared helpers retain ordinary data UFCS. Callable-parameter tail annotations
and an annotated function referencing itself as a callback are rejected early;
ordinary recursive forwarding and references from other functions remain valid.

Current physical diff is **940 production ADD / 200 DEL / +740 net**, separately
from **1,281 test ADD / 63 DEL / +1,218 net**. The reviewed test-only revision at
`d1cae0a0497145a07b6031b11359d7096eacd904` permits 1,350 added test lines and +1,280 net test lines with an
assessment stop at 1,300 added test lines or +1,225 net test lines; production and cost limits are unchanged.
The [complete test manifest](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/worker/test-proposal/SEALED_V2/MANIFEST.json)
retains the historical V2 set of 39 paths and hashes; its patch SHA is
`dce032fe271f512e3f026a855100c4a90657ac2c6fbf8dcb52acf49c054c55f8`.
Current tests span 40 paths after reviewed unary-span, scope-import, ambiguity,
pipe-formatting and namespace-help corrections; V2 is historical, not the final
postimage manifest. The [functional04 packet](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/final-diagnostic-functional04-2026-10-18)
completed with **3,454 component PASS / 0 FAIL**, focused **32 + 3 PASS**,
and **484 fixture/group PASS + 589 nested native PASS + 1 umbrella PASS**.
All commands exited zero with empty stderr, no skips, required instructions,
strict-zero accounting, native caps and sanitizers unchanged. Its
[receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/final-diagnostic-functional04-2026-10-18/RECEIPT.json) SHA is
`e07da5ccc995f57c5695057a3124eba6bfe86318f3ee1dacc0e2565fd63799af`;
all 2,447 pins were stable. It reuses the exact current-source pilot
`437c7a9eef59eb391e4f05b7982f51d20c578a38e8dae4ff4aee190e5b47e057`
and prior generation/link evidence with 89 inherited warnings. The compatible
impurity test was added afterward: current diagnostics has 33 registrations,
with its 33-case owning run and four effective restored mutations now passing
(see below). The full
component/e2e counts above apply to the preceding 1,268/63 test snapshot;
no full-component rerun after that test-only addition is claimed.

Initial M7 B remains **5c3e9f3ddc1a51290d1fb0dbbb7e90eb84039586**. The
[epoch](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/baseline/EPOCH.json) and [baseline receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/baseline/RECEIPT.json)
freeze 41 compiler sources in equal-depth/equal-length B/C paths, shared host
standard-library 91-file set, tools, flags and the normal/diagnostic host pair. Normal measurement SHA
is `6852e1c6c93b6ee913665fbc72ff4413eb9643c1b51f993ce01a24acaebd36f3`;
diagnostic SHA is `a362b0dfd7d744b090008b9be405dc0ee5b1dd9437e5ff19d8cf8c516091d774`.
The signed functional host is separately `97479b34…`; signing-role reproduction
is retained. These are **host source-to-C construction proxies**, not target
self-compilation or native fixture runtime measurements. The CLI uses
`compile --no-format --no-embed-runtime --time-phases --std-dir <pinned standard-library 91-file set>`;
allocation is exactly one schema1 cumulative `artifact_construction_complete`
checkpoint, and instructions are the minimum of 3 original normal-host samples.
Exact cwd/env/argv are in the [diagnostic command](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/baseline/measure/B/10-diagnostic.command.json)
and [normal command](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/baseline/measure/B/11-normal1.command.json); original
outputs and counters accompany each receipt. Execution was serial under the
exclusive compiled lease; `self_compile_measure lock --` is a passthrough.

B measured **24,404,055 allocations / 44,935,473,655 min3 instructions**. Each
candidate originally had to stay independently at or below
**25,136,176 / 46,283,537,864** (103% of that same B). Those observations remain
failures under that original contract. The user-approved resource revision at
`6ab5f0b9711709d0823db521b7be09b600ee98b1` sets independent cumulative hard limits
of **26,356,379 allocations / 48,530,311,547 instructions** (108% of B), with
reassessment at **25,868,299 / 47,631,602,075** (106% of B). Named callbacks and
later lambdas share these limits; no baseline roll, stacked allowance or native-cap
change is authorized.

| Retained historical probe | Construction allocations vs B | Normal min3 instructions vs B | Verdict (original 3%) |
| --- | ---: | ---: | --- |
| [01](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/early-cost-checkpoint01/RECEIPT.json): First native snapshot | 25,162,015 (+3.105877%) | 46,336,890,471 (+3.118732%) | RED / RED |
| [02](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/early-cost-checkpoint02/RECEIPT.json): Correctness fixes + single publication | 25,167,468 (+3.128222%) | 46,360,740,421 (+3.171808%) | RED / RED |
| [03](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/early-cost-checkpoint03/RECEIPT.json): Direct PendingValue publication | 25,158,312 (+3.090704%) | 46,309,751,836 (+3.058337%) | RED / RED |
| [04](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/early-cost-checkpoint04/RECEIPT.json): Flatten sealed callable facts | 25,157,589 (+3.087741%) | 46,316,239,482 (+3.072775%) | RED / RED |

All four historical probes exceed **both original 3%** ceilings. Probe 04 remains 21,413 allocations and
32,701,618 instructions over; normal/diagnostic C agreed for each source variant.
B/C compiler-source C identity is not required because the source changed.
[Phase deltas](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/early-cost-checkpoint01/PHASE_ALLOCATION_COMPARISON.json)
show broad source/Core growth, with ownership the largest allocation increase;
no narrow runtime regression or sufficient cost headroom was demonstrated.
Further optimization stacking stopped. Probe 04 predates the later one-line
FunctionType teaching correction. The final current-source measurement below
is a correctness-source refresh, not a fifth optimization trial.

The [final cost receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/final-current-source-cost-2026-10-18/RECEIPT.json)
SHA `7c51945e60c7aa952ea6e734b270039cdbb93c28a60c9ad777806f2d48b6e9bf`
records **25,157,589 construction allocations (+3.087741%)** and original normal
instruction samples **46,369,865,414; 46,365,696,666; 46,358,229,094**. Their
minimum is **46,358,229,094 (+3.166219%)**. Both original 3% ceilings remain
**RED**, by **21,413 allocations / 74,691,230 instructions**. Under the approved
8% cumulative contract, both metrics **PASS** and remain below the 6% assessment
thresholds. The single
schema-1 construction checkpoint and all three normal outputs agree on C SHA
`e8c9a3156100b8b2124664e93a41a77dafbe1cc41462ead973ccdbaf00d7c722`
(6,917,661 bytes). All 2,732 measurement pins stayed stable; no retry or baseline
roll occurred. These costs are unaffected by the later test-only impurity case.

The retained [resource-budget decision material](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/resource-budget-decision-proposal/README.md)
records the exact two-plan revision approved by the user on 2026-10-18 and
published at `6ab5f0b9711709d0823db521b7be09b600ee98b1`. The packet retains its
original proposal-only labels as historical evidence. No fixture or LOC budget
changed; lambda implementation still requires a separately frozen architecture
and cost plan. The original 3% failure receipts are preserved unchanged.

Precursor evidence is narrow: the original B CLI rejected the first real-main
identity fixture at its full callable annotation without C ([raw RED](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/worker/RED.json));
its shell-wrapper status-capture limitation is separate from the semantic output.
[Rework03](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/worker/rework03/RECEIPT.json) passed 32 focused callbacks, identity
main returning 17, 41/41 source parsing and the unchanged opaque-type frontier. The
[independent identity C inspection](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/native-c-inspection01/RECEIPT.json)
confirmed erased parameters and an ordinary selected direct call; it is a separate
emission from the harness's temporary C. [Early native validation](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/diagnostic-native01/RECEIPT.json)
passed the real ordered and managed fixture mains with exact outputs, required
instructions, strict accounting and unchanged ASan/UBSan. Those use a frozen
precursor pilot and do not establish final current-source acceptance or a
successful B denominator for new syntax.

Two private facts have explicit limits: RequestSource per-choice provenance has
two independent static wiring reviews; opaque-access RED03 was setup failure,
not semantic RED or mutation. The private callable hint-merge branch is unreachable
through accepted result signatures and has static review rather than a fabricated
public-input oracle. No hook, observer or visibility bypass was introduced.

The [restored-mutation receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/restored-mutations-final01-2026-10-18/RECEIPT.json)
SHA `dc0749bf4f38ef012acf190fbf34162d7e7e56926025c799ac3963187f8fef9d`
records four effective semantic kills, applied individually: omitting ordered
callable keys, omitting forwarded parameter remapping, removing named purity
admission, and removing named potential-growth edges. Required callbacks failed
1/2/2/2 respectively; the purity fault breaks both the compatible-impure case
and the existing error-priority case. Controls passed 76 callbacks; exact
restorations passed 97. No setup failure counted as a kill. All source hashes,
modes, 2,745 pins, index and tracked patch were restored after every fault.

The [final CLI/control receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/final-cli-controls-native-C-2026-10-18/RECEIPT.json)
SHA `f5ae2e199dbd94abba6f3b8dd12b1e21d453c1cd393313c9d06661bd1431f7ac`
records byte-identical B/C output for `return/zero.brp`,
`generic/managed/basic.brp`, `option_input/parse_int.brp` and
`conversion/integer.brp`, using the same canonical fixture/library inputs.
The baseline target compiler's 41 source files match initial B; its provenance
and the unchanged current pilot are pinned in the receipt. Existing absolute
limits and real-main outcomes are covered by functional04. These controls do
not substitute a successful B denominator for new callback syntax.

One normal `-O0`, diagnostics-off pilot was linked from the same current compiler
C used for functional04. Its 89 ordered warnings match the inherited warning
set. Three original serial normal compiler samples per new witness all produce
C identical to the retained diagnostic-pilot emission:

| Named witness | Construction allocations in functional04 | Normal min3 compiler instructions |
| --- | ---: | ---: |
| identity | 10,437 | 46,452,931 |
| ordered | 18,165 | 57,071,952 |
| managed | 23,111 | 63,581,598 |

All remain below the existing 150,000-allocation and 600,000,000-instruction
absolute limits. Functional04 separately proves native real-main outputs,
strict memory accounting and ASan/UBSan. The nine normal calls measure compiler
construction, not target program runtime; no extra native executions or retries
are claimed. All final 2,763 input/artifact pins stayed stable.

The [independent root C review](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/final-cli-controls-native-C-2026-10-18/ROOT_C_REVIEW.json)
inspects retained ordinary CLI output: identity has only one Int runtime
parameter and directly calls its selected target; ordered choices produce
separate direct-call chains for double-then-increment and the reverse. Managed
identity retains a borrowed String before returning ownership. The Option
helper calls that identity for Some and retains the fallback for None before
the caller releases inputs; the separately retained original alias survives.
Forwarding, zero/Void and Int-to-String wrappers use ordinary calls and existing
ownership. No runtime callback slot, function pointer or closure is introduced.
These files are separate ordinary CLI emissions, not the harness's deleted
temporary C.

All 41 compiler files parse. The current-source CLI still stops at
`check/check.brp:20:13`, `opaque type CheckedProgram = CheckedFunctions`, with
`opaque types are not supported yet`; [raw stderr](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/named-callables-2026-10-18/current-self-compile-probe/stderr)
is retained. No target self-compilation, linked target-built compiler,
compiler-product destruction margin or A/B/C fixpoint is established.

Named callback code, tests and report received independent code-reviewer and
test-runner approval. The source/test/C snapshot is unchanged from the closed
functional, mutation and cost receipts; the reviewed resource-contract and report
status updates require no repeated compiled gates. The existing measurements
satisfy the user-approved cumulative contract without retrying or relabeling the
original failures. Lambdas, captures, the four callback library helpers and the
final source/import inventory remain outstanding.
