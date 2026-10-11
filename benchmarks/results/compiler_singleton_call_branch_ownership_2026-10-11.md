# Singleton consuming-call branch ownership repair

Date: 2026-10-11. Checkout: `blorp-2`, based on
`1a8c373904d89efa65e3e9cbd06769e28a55b7f0` with separately preserved local work.
This report records focused correctness evidence, matched whole-self-compile
costs and a passing three-stage compiler fixpoint. Independent compiler and
test-runner reviews accept the bounded repair; separate Core failures remain.

## Defect and owning boundary

This valid program leaked its mortal input String on the append branch:

```blorp
import:
    string as StringOps

pure func append_optional(output: String, name: Option[String]) -> Result[String, Int]:
    Ok(
        match name:
            Some(name):
                StringOps.add(output, name)
            None:
                output
    )

func main(arguments: List[String]) -> Int:
    output = arguments.length().to_string()
    match append_optional(output, Some("suffix")):
        Ok(result): result.length()
        Err(_): 0
```

With no program arguments, the expected exit code is 7. The frozen baseline
instead exits 99 under leak checking: 5 allocations, 4 releases and one leaked
String of 34 bytes. The caller transfers its input obligation to
`append_optional`. `None` transfers that input into the result; `Some` borrows it
for concatenation and must release the original after producing the new String.

The Perceus checkpoint still represents `Ok(...)` as a resolved `UserCall`, not
`UnionConstructExpr`. `contract_for_call` in
`blorp/src/compiler/stage_09_core/perceus/env.brp` obtains the consuming
constructor contract from resolved definition identity. Constructor spelling
does not establish ownership.

Branch-use summaries correctly take a maximum consumed-reference count of one
across these arms. That summary cannot prove both paths discharge the input.
The defect was in `perceus/balance.brp`: neither divergence selection nor actual
nested branch balancing descended through the surrounding call, so the
whole-call maximum incorrectly suppressed the append arm's drop.

## Repair and scope

The production change is confined to
`blorp/src/compiler/stage_09_core/perceus/balance.brp`. Both entrypoints now admit
the sole argument of a call when:

- The argument contains genuinely divergent ownership paths, checked before
  looking up the contract.
- The resolved contract gives that argument a consuming or transfer mode via
  `arg_consumes_caller`.
- Summarizing the callee finds no use of the owner being balanced.

The existing balancer then handles each argument arm. Reconstruction preserves
the original call kind, callee, type and location. Evaluation order is unchanged:
the callee remains before the single argument. Multiple-argument scheduling and
the existing CF-015 name/shadowing issue remain outside this repair.

The final C for the reproduction contains:

```c
/* Some */
blorp_String* result = blorp_string_concat(input, suffix);
blorp_release(input);
/* None transfers input unchanged. */
```

The retained actual C uses these operations at `repro-final.c:47893–47900`.
There is no backend release workaround, runtime change, new data model, cache,
name heuristic or modified pilot input.

Formatted production delta is 59 added / 13 removed, or **46 net lines**,
including two imports and existing import wrapping. The initial 40-line ceiling
was reviewed and revised to 50 after inspecting the two admission sites and
shared guard. The allocation/instruction ceiling remains 1%.

## Focused validation

The runtime regression lives in
`blorp/test/test_runtime/test_memory/test_nested_consuming_call_branch_ownership.brp`.
Its eight callbacks cover append and identity paths through Result, Option,
nested `Some(Ok(...))`, and a locally owned String binding. Runtime-derived
mortal Strings, active counters and actual allocation checks prevent static
lifetime or vacuous success.

Core regressions live in the already registered
`blorp/test/test_compiler/test_stage_09_core/test_core_perceus.brp`. They check
exact owner/type/policy, result-before-drop order, None transfer, preserved call
metadata, resolved identity, borrowing calls, touched callees and multiple
arguments. Guard cases inspect the full balancer as well as selector admission.

| Check | Result |
| --- | --- |
| Frozen generator, runtime regression | Four append paths each leak one 34-byte String; four identity paths pass |
| Repaired host, runtime ASan/UBSan and per-test leak checking | 8/8 pass |
| Initial direct Core red | Three positive cases fail; four guard controls pass |
| Restored direct Core ASan/UBSan and per-test leak checking | 7/7 pass |
| Managed pilot raw verifier and emitter, strict | 44 + 13 = 57/57 pass |
| Full owning Core suite, ASan/UBSan without per-test leak checking | 471/473 pass; unchanged assertions listed below |
| Prior temporary-projection runtime and pilot tail checks, strict | 8 + 31 = 39/39 pass |
| Original program, native ASan/UBSan and leak checking | Exit 7; 5 allocations, 5 releases, zero leaks |

A deliberate mutation disabled only actual call-argument descent, retaining the
divergence selector. Exactly three of eight callbacks failed: single wrapper,
nested wrapper and local owner. The selector and four guard controls passed.
Restoring the exact production bytes restored strict direct Core to 7/7.

The full Core suite still fails these two preexisting assertions:

- `multi owner conditional call argument is retained once`
- `existing drop preserves nested consuming call retain`

They were not weakened or presented as repaired. The source adds a new Core
function block of 231 lines, eight registry entries and two imports, plus a
160-line runtime suite. The whole Core-file diff also includes five prior
temporary-projection tests. Unrelated whole-file formatter changes were removed;
the new block's final isolated formatting changed layout only after its full run.

Representative repeatable commands are:

```sh
make
scripts/compiler-build-status
bin/blorp test --suite --sanitize --leak-check --timeout 180 \
  blorp/test/test_runtime/test_memory/test_nested_consuming_call_branch_ownership.brp
bin/blorp test --suite --sanitize --timeout 180 \
  blorp/test/test_compiler/test_stage_09_core/test_core_perceus.brp
bin/blorp test --suite --sanitize --leak-check --timeout 180 \
  blorp_2/test/unit/test_managed_union_verify.brp \
  blorp_2/test/unit/test_managed_union_emit.brp
```

The full Core command is expected to retain the two failures above until their
separate repair. The seven-case direct runner and controlled mutations were
retained locally under `blorp_2/build/host-branch-balance/dev/`.

## Separate aggregate API lifetime failure

The eighth Core callback exercises public `insert_drops_expr` on a local owner.
Its first oracle incorrectly required source identity and a direct concat RHS
through a normalizer that rebuilds nodes and materializes a suffix literal.
The corrected oracle permits that preparation and checks exact source
acquisition, a String RHS requiring one reference but consuming none and
returning no output alias, result-before-drop of the exact output owner, and
None transfer. It passes its Boolean assertion and the full Core run.

Per-test leak checking still exposes a retained aggregate. With the generator
and all non-balance host inputs fixed, a controlled target-source comparison
gave:

| Target `balance.brp` source | Boolean assertion | Leaked transitive Core objects |
| --- | --- | --- |
| Exact pre-change gitHEAD bytes | False, missing append-arm drop | 58 |
| Final repaired bytes | True | 65 |

This establishes that the aggregate lifetime failure predates this target
repair; it does not establish the missing release's root cause. Counts differ
because the repaired retained graph contains additional nodes. The earlier
comparison of old and new generators against the same current target was
insufficient by itself to establish inheritance; the exact old-target run is
the relevant evidence.

The actual retained root remains unproven. Possible investigation boundaries
include public insertion/catalog lifetime at `perceus.brp:336–346`, mutable
postorder-machine roots at `results_and_loops.brp:3292+`, and owned result
projection at `results_and_loops.brp:4784`. No extra release, API workaround or
third production repair was inferred from object counts.

## Separate 4096-depth cancellation timeout

An earlier broad `compiler-core-sanitize` run completed 364 callbacks and timed
out one native batch harness after 180 seconds. The sampled process was
executing `cancellation_plan.analyze_current_behavior_expr`, not compiling C or
exhausting the host backend's compilation stack. The likely triggering callback
uses depth 4096 in a preexisting excluded emitter-test draft, but no isolated
callback or archived-baseline execution proved that attribution.

Read-only source inspection found growing protection-list reconstruction at
each Let: a chain of 4096 bindings entails 8,390,656 logical row-copy positions
for 4096 final rows. Recursive traversal depth also grows. This is a bounded
complexity hypothesis, not measured allocation/instruction attribution. Removing
False protection rows would violate the current complete-decision contract.
Planner measurement and a preserving local-builder/iterative repair belong to
a separate follow-up; neither the timeout nor its limits were changed here.

## Provenance and retained evidence

The focused repaired host was FRESH after `make`. Its binary SHA-256 is
`4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec`.
Frozen original generator:
`8a8af4e853a7835257c8cc0027546ab105c41a917837f2e1d02cc63ab79ea26a`.

| Source | SHA-256 |
| --- | --- |
| Pre-change `balance.brp` | `2218edf09b374752be5ab11ccf44926a393cbad7e1ec557d3bed051969d1409d` |
| Final `balance.brp` | `17b0585f1a4c71c96a9df3f2b8210e8573132678bb81f22898ddb9bca1b1a42e` |
| Final Core test owner | `80b71d6c1fbc102e8a5bfff1e286edd733a0946376c9fa6f6ee4f38d78fd2cf3` |
| Runtime regression | `0432b813708b2e6403380f1798f8ea589b97ba27d65f21018b099dfadb520624` |

Local raw logs, exact mutation/target bytes, narrow generated C and Core,
restoration hashes and build status are under
`blorp_2/build/host-branch-balance/`. These ignored artifacts supplement this
self-contained tracked summary; they are not published repository files.
The cancellation diagnosis is locally retained at
`blorp_2/build/host-projection-repair/cancellation-timeout-diagnosis.md`.

The excluded drafts in Core IR, backend emission, Core type-policy tests and
Core emitter tests were preserved byte for byte.

## Matched costs and fixpoint

Predeclared acceptance: investigate any repeatable increase exceeding 1% in
matched whole-self-compile allocations or retired instructions. Focused
correctness does not replace these measurements or compiler fixpoint.

The integration owner measured three normal whole-self-compile samples per
compiler and a diagnostic allocation run against the same frozen gitHEAD
workload, `1a8c373904d89efa65e3e9cbd06769e28a55b7f0`. Only `balance.brp`
differed among the 529 builder inputs. Both normal/diagnostic compiler pairs
were built through the same stage2 procedure and toolchain. Their builder
provenance establishes stage2 identity; the measurement tool's generic
external-pair `compiler_stage: 1` label does not describe that construction.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Whole-self-compile allocations | 289,735,399 | 289,742,824 | +0.002563% |
| Median retired instructions | 564,525,894,297 | 564,541,907,679 | +0.002837% |
| Median wall time | 36.45 s | 36.88 s | +1.18% |

Allocations and retired instructions pass the predeclared 1% ceiling. Wall
time is descriptive; this correctness repair makes no speed claim. Emitted C
is byte-identical (`diff` exit 0), with SHA-256
`12af2f51fd676c190f031d618a284e32c89291fc695c1416c2ae65c8b09ae762`.
This identity applies to the frozen self workload; the focused regression
Core/C and runtime evidence above establish the repaired branch behavior.

| Compiler pair | Normal SHA-256 | Diagnostic SHA-256 |
| --- | --- | --- |
| Baseline | `20a885d5b5a3d067e5773ada5ca3754cdc4477eb12cb9a3753ccce0ca64328e9` | `eec544d74310f0d7d58403d31f7537092a282a5860fc20b6ff8a11e14356e210` |
| Candidate | `0de888e771f8ae19125c65db5d7ed7c87d95b47b42a4782dabfa903fc41b473f` | `e11037b3532e75ff2498ea20fe743a0dc4d3bcd9f644ad05ed33758563f50049` |

Raw samples and comparison are retained under
`blorp_2/build/host-branch-balance/{baseline,candidate}/self-compile.json` and
`blorp_2/build/host-branch-balance/comparison.json`.

| Parent-owned result | Status |
| --- | --- |
| Compiler fixpoint | PASS: stages 1, 2 and 3 emit byte-identical C |
| Standard host leak gate | PASS: 1,267/1,267 |
| Codegen audit | PASS: 241/241, serial `--jobs 1` |
| Independent review and final acceptance | PASS: source, runtime/Core regressions, costs, fixpoint and standard host gates reviewed |

The standard `scripts/compiler-fixpoint --work-dir
blorp_2/build/host-branch-balance/fixpoint` passed. All three outputs have SHA-256
`283ed8a9940dfc2d2af2f8fc795432db661d46984548989795a156e5cd81001e`.
The complete log and stage artifacts are retained under that work directory
and `blorp_2/build/host-branch-balance/fixpoint.log`. All 529 candidate host inputs
were rechecked after the run; the four excluded user drafts still match the
preserved original diff byte for byte. Independent review verified the three
outputs, source/manifests and matched samples.

Final standard gates are retained in `independent-leak/` (45.692 seconds) and
`independent-codegen-audit/` (81.874 seconds) under the branch-balance evidence
directory. Both bind the FRESH host above, unchanged sources and zero timeouts.
The leak total includes 1,225 callbacks, 36 isolated programs and six diagnostic
oracle tests. These green workloads do not erase the separately retained public
Core aggregate leak, two Core assertion failures or cancellation timeout.
