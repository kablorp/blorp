# Narrow loop emission context

Status: reviewed implementation and explicit-artifact assessment complete.
Component tests and maintained CI-policy e2e pass; strict resource failures match
the fresh base. The base and candidate default pinned-seed builds fail identically.
**Landing requested after disclosure of the inherited default producer failure;
no default-generation PASS is claimed.**

## Result and boundary

Nested control emission now receives only its loop-exit destinations and target:

```blorp
private fixed record LoopEmissionContext {
    break_parameters: List[Own.OwnedJoinParameter],
    recur_parameters: List[Own.OwnedJoinParameter],
    target: Lower.LoopTarget
}
```

`append_loop` constructs the context once for that loop's emission. It shares
its already-prepared ordered output list and projects header destinations once.
Nested blocks, tails, selections and ordinary joins consume it directly; a nested
`ExecuteLoop` constructs its own context and immutable caller arguments preserve
the outer context afterward. They no longer receive the loop body, entry actions
or initial transfers. Selection roots and arm paths remain separate from loop
labels, including terminal selectors inside abrupt ordinary joins.

Verify has already checked that an abrupt transfer targets the nearest loop;
Emit accepts its opaque `VerifiedProgram`. The successful path therefore uses
`context.target` instead of passing the same target independently. The existing
absent-context diagnostic retains the original raw transfer target. Own and
Verify retain their independent checks. No IR or language rule changes.

All outgoing values are still captured before any destination assignment.
Entry acquisitions precede header initialization; output owner aliases follow
the break label. Existing `append_input_declarations` and `append_input_owners`
replace equivalent loops inside `append_loop`: same order, types, Void-use
markers, owner aliases, spans and first-error behavior. No cache, framework,
layout/runtime change, new guard or fixture-cap change is included.

## Lines and prospective limits

Production: **46 added / 56 deleted, net -10 physical lines**, in
`src/emit/emit.brp` only (3,424 to 3,414). Tests: **55 added / 1 deleted,
net +54 lines**, across two existing suites. One mixed-Break callback is added;
the existing nested-loop callback is strengthened. No existing callback is
removed. Documentation is separate, not counted as a production saving.

Before production edits, the retained `PROSPECTIVE_PLAN.md` requires a complete
net production reduction; rejection/rescoping for repeatable actual-self-built
allocation or instruction growth above **0.5%**; and bounded investigation for
peak RSS growth above **2%**. RSS is an investigation trigger, not a hard cap.
Context-only growth was rejected in design review; the direct helper reuse pays
for the narrower model without compressed formatting or unrelated cleanup.

## Exact base and default build blocker

Base: `09d8227bb4039c3e3d923551d0fd6129817f8d21`. The fresh unchanged
`make -C blorp_2 test` exits **2 during compiler generation**, before components:
pinned `blorp2-seed-5d0d4cc89240` rejects the stored callback field in
`ExpressionSite.BodyExpression` at `check/expressions.brp:142:36`:

- Message: `callable types are only supported as function parameters`.
- Help: `write pure function types only on function parameters; use ordinary data types inside them`.

That field arrived in `48bc6aa493`, after the stored-callable/tuple reports'
historical successful seed builds. This is an inherited producer compatibility
failure, not resource debt. The ordinary CI allocation-debt policy cannot
accept it. No seed, pin or policy is changed here; explicit-artifact evidence
does not replace default producer qualification.

For this bounded assessment, the fresh repository legacy host explicitly builds
exact-base A, which emits target compiler C. Actual-self-built B reproduces it
on current and frozen base source. Candidate A is then built by exact-base B;
candidate A and self-built B reproduce the same candidate C. These explicit
builder routes are recorded, not substituted silently for Makefile generation.

The repository host is FRESH from immutable `dev-07bc7629a132`, commit
`09d8227bb403`, CLI O0/runtime O2, split 8, Apple Clang 21. Actual target normal
and diagnostic links both use **-O0**, `BLORP_MEMORY_DIAGNOSTICS=0/1` and
`-lm -lpthread`, matching Blorp2's maintained link policy. Complete hashes,
commands, flags and streams are retained in the packet.

## Frozen inputs and actual-target costs

There are **635 frozen inputs**: 634 compiler/library/fixture files verified
against exact-base Git blobs plus the prospectively selected break-only guard.
All 57 source/library producer files and candidate images are pinned. Baseline
and candidate use the same physical source, library, CWD and output for each
pair; input hashes are checked before and after every sample.

Each of five fixed workloads has one strict diagnostic pair and three normal
pairs: **40 processes**, all retained. Normal order is B1,C1,C2,B2,B3,C3. Strict
diagnostic counters supply allocations; normal `/usr/bin/time -l` supplies
minimum-of-three retired instructions and median-of-three peak RSS. All our
compiled calls are serialized; background machine activity is uncontrolled.
There is no latency or speedup claim.

| Frozen compiler source | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 31,028,500 | 31,026,982 | -1,518 (-0.00489%) |
| Minimum instructions, 3 normal runs | 901,516,135,472 | 901,702,179,805 | +0.02064% |
| Median peak RSS, 3 normal runs | 298,696,704 B | 303,267,840 B | +4,571,136 B (+1.53036%) |

Instructions are effectively flat; the deterministic allocation saving is small.
Full-source RSS rises **4.36 MiB**, below the prospective investigation trigger;
there is no footprint improvement claim or established cause. Baseline RSS
samples are 298,696,704, 298,287,104 and 303,415,296 B; candidate samples are
280,018,944, 303,267,840 and 304,562,176 B. All samples are retained; range
overlap does not prove noise, and the lowest candidate RSS is not the summary.

| Fixed guard | Baseline allocations | Candidate allocations | Instruction change | Median RSS change |
| --- | ---: | ---: | ---: | ---: |
| No loop: `return/zero.brp` | 104,756 | 104,756 | -0.01080% | -557,056 B (-6.24%) |
| Break only: frozen `guards/break_only.brp` | 105,911 | 105,909 | +0.03969% | -376,832 B (-4.14%) |
| Multiple/nested exits: `source_loops/control.brp` | 147,274 | 147,259 | -0.03752% | -753,664 B (-7.73%) |
| 32 loops: `source_loops/nesting.brp` | 170,311 | 170,279 | -0.03413% | -983,040 B (-8.77%) |

All prospective matched-cost allocation/instruction ceilings are met. Each strict sample
balances allocations/releases with zero tracked leaks and bytes. Every emitted
C file is byte-identical to its paired reference. Frozen compiler source emits
18,878,296 bytes, SHA-256
`ba6393c4d54bf8ba9f7afa858ef747e10825b118c63d471905c50f5e2e95f3b9`.
These are compilation costs, not fixture native-runtime speed claims.

Candidate A/current self/fixed-point C is 18,856,386 bytes, SHA-256
`f8309136d4a0f53625d2ca4062579874b314adf1e2f649f82074f4fe2b80785a`,
a **21,910-byte** compiler-image reduction. Own changed-source strict runs
balance 30,998,069 allocations/releases with zero leaks/bytes. Those changed-input
counts are separate from the matched frozen-input comparison above.

## Representation and owning-phase evidence

Target C confirms a real **managed context allocation per emitted loop**:
record r225 owns two List[u128] references and an int64 target; its constructor
allocates and its destructor releases both lists then the record. Option u255
is an inline owning tagged union, adding no separate Option box. The eager
header map also allocates its empty result. OwnedJoinParameter u128 is an inline
sum in list slots, preserving the ValueParameter pointer and optional OwnerId.
The exact source-to-C mapping and hash-bound excerpts are retained in
`reviews/loop-context-representation.json`.

This trades per-loop preparation/carrier allocations against removed per-exit
collections. Neither representation fact alone explains the net saving or RSS.
The enclosing function/program still retains its body; no earlier body-retirement
claim is made. A host-only public `emit` probe prepares and verifies the same
frozen program before resetting memory counters, emits ten times and keeps the
verified input alive past counter read. The ten-emission epoch balances
**41,380,810 to 41,365,810 allocations/releases**,
**-15,000 (-0.03625%)**. Both complete ten successful emissions with active
counters and a 188,782,960-byte total extent, while the verified 2,523-function
input remains alive after the read. This length checksum guards output extent,
not independent proxy byte identity; actual-target byte identity is established
separately by the 40 matched runs. The probe is a legacy host representation
proxy, not the target allocator. Whole-process instruction counters include
setup and are not phase-only measurements. No causal attribution of the full
self-compile delta follows from the proxy.

## Oracles and qualification

The baseline-compatible tests pass before production changes. The mixed-Break
oracle uses distinct Int sources for result and final carried value, with a
managed String between them. It pins exact declarations, complete snapshot
batch before assignments, destination order, target, output aliases and release.
The nested-loop oracle requires the outer header jump after the inner break,
excluding the initial outer-entry jump. Existing swap, managed-header and
selection-label/path tests remain. Candidate focused feedback passes **58 tests
across seven owning suites**. Initial test-construction mistakes were corrected
before the green baseline and are not claimed as semantic RED evidence.

Five deliberate mutants produce exactly their intended semantic callback
failures: reversed Break destinations (1), reversed Recur destinations (1), lost
nearest context across a Join (1), raw-source assignment bypassing snapshots (3),
and an inner loop replacing its enclosing block's tail target (1). The fifth
mutation exercises the nested callback's existing label counts and strengthened
resume interval jointly; it does not isolate a single assertion. Each exact
restoration replays both suites green, **30 restored PASS / 0 FAIL**. All 57
source/library and two test pins match afterward; the measured
production image remains unchanged. Tests retain their normal TestSuite entries.

The independent runner captured a fresh exact-base strict explicit-artifact e2e
reference: **101 native callbacks PASS / 479 resource FAIL**, **786 nested PASS**
and a failing umbrella (raw 887 PASS / 480 FAIL). The errors are **117 allocation
and 362 instruction overruns**, with no other stderr errors. The immutable host
harness was retained before the approved emitter edit; all other 1,125 input
pins and the base target binary stayed fixed. Candidate components pass
**4,474 callbacks / 0 FAIL**: 4,329 hosted and 145 target callbacks across all
16 explicit target suites. Their 16 strict accounting reports are balanced,
with zero tracked leaks and bytes; no other stderr appears. All 1,133 component
input pins remain unchanged. Candidate default generation has exactly the same
stdout and stderr as the unchanged base, including its diagnostic and help.
Candidate strict e2e has the same **101 native PASS / 479 resource FAIL**,
**786 nested PASS** and failing umbrella. Every ordered failed callback, category
and cap matches the fresh base exactly: 117 allocation and 362 instruction
overruns, no other errors beyond the Make summary. All 1,133 pins remain
unchanged.

The maintained CI-policy run uses the same candidate diagnostic image with
`BLORP_2_INSTRUCTION_CHECK=disabled` and
`BLORP_2_RESOURCE_POLICY=record-allocation-debt`. It exits **0**, with
**580 native + 786 nested + 1 umbrella = 1,367 PASS / 0 FAIL**, empty stderr,
and all 1,133 pins unchanged. Its **117 allocation FAIL debt records** remain
explicit in stdout; instructions are **UNMEASURED**, not passing measured limits.
No budgets or policies changed. This is explicit-artifact functional acceptance,
not qualification of default compiler generation. No resource/M8 or
seed-publication acceptance is claimed.

Two independent actual code/test, cost-direction and completed-gate reviews
approve their respective evidence with zero findings. They accept this bounded cleanup's tiny allocation decrease and net
code reduction, while retaining near-flat instructions and the adverse full RSS
result. This is not a compelling optimization or a footprint improvement. The
independent test runner accepts explicit-artifact validation while retaining the
default producer failure. Initial review retained the change on local
`codex/loop-emission-context`. The user subsequently explicitly requested
commit, merge to main and push after disclosure of that failure; this authorizes
landing with the inherited failure recorded. It does not turn default generation
into a passing gate or change resource policy.

Raw evidence is retained under ignored `build/loop-emission-context/` in the
implementation worktree and copied, with every file hash-verified, to
`/Users/keithphilpott/CLionProjects/blorp/build/loop-emission-context-2026-10-21/`.
It includes the prospective plan, frozen inputs, source/image manifests,
builder and measurement commands, all samples, mutation/proxy logs, target
component C/images, gate streams, ordered failure comparison and review receipts.
`PRESERVATION.json` records the retained inventory; final staged-review and commit
receipts supplement it. No raw samples or binaries are committed. The worktree
stays available for a separate default-build repair and requalification.


## Integration onto current main

The landing candidate integrates `2ebbebf83c08b45cdf0c807453f89e12fb4b4ac9`
with the reviewed cleanup checkpoint `7be6ac19ed170fa137211678dc115bc596cebef3`.
Upstream changes only the Makefile, README and two lexer component suites; it
adds runtime-text and trivia suites to the target selection (18 total). The
cleanup's production and test postimages stay unchanged. No compiler source,
standard library, e2e fixture, budget, bootstrap pin or resource policy changes
in this integration.

Fresh integrated default generation exits **2 before any callbacks**, with
stdout and stderr byte-identical to both the unchanged base and checkpoint,
including message, help and span. The expanded explicit-artifact component gate
passes **4,490 callbacks / 0 FAIL**: **4,329 hosted + 161 target across 18 suites**.
All 18 strict target reports balance with zero tracked leaks and bytes; the
36 target C files/images are retained. All **1,127 integration input pins** remain
unchanged across the commands.

The runner independently verifies the complete **639-file e2e inventory**, all
**57 producer/library files**, and the exact candidate diagnostic binary and C
image against the prior accepted runs, with no additions/removals. The Makefile
change only expands target-component selection; generation, linking and e2e
recipes and flags stay unchanged. Prior strict and CI-policy e2e results are
therefore reused with explicit input/image equivalence, rather than rerun or
relabeled as fresh integration runs. Cost and mutation evidence also retains
its original epoch and unchanged producer/test postimages.

The original 1,133-pin gate statements above describe those original runs. In
that original pin set, integration deliberately changes exactly three paths:
the Makefile and the two migrated lexer tests; the README was outside that set.
The fresh integration inventory records its own pins and results separately.
No failed default or strict resource gate is presented as passing. The user
requested publication after these inherited limitations were disclosed.

Integration reviews, manifests and raw streams are recorded separately under
`integration/` in both retained evidence packets, preserving historical receipts.
The reviewed tree is prepared for squash integration onto main; publication
records verify the actual local and remote destination after the requested push.
