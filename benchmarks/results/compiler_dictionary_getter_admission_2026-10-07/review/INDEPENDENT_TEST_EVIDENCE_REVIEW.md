# Independent dictionary test-evidence review

Scope: my exact-base TDD and frozen candidate gate runs, plus read-only evidence verification. This is a test-runner review, not a replacement for independent implementation/controller code review.

Verdict: correctness, selected sanitizer, focused emitted-C identity and scanner evidence PASS. Outstanding test-evidence findings: 0 within this scope. Resource acceptance was pending at the gate run; independent read-only verification of the completed comparison now passes within self/small scope, as recorded below.

| Observed boundary | Finding |
| --- | --- |
| Base2ee + corrected new tests | 35 total; 32 PASS / exactly3 intended FAIL: unknown suffix, incompatible/non-Option result, wrong arity |
| Initial positive-control failure | Incorrect FloatBox premise; nonallocating per specialize_layout473–478. Corrected tests-only to Int128Box; original31/4 packet preserved, no compiler bug claimed |
| Candidate frozen309 patch | Owning35/35; selected suite + Core sanitizer2500/2500; program23/23; broad6775/6775; codegen232/232 |
| Stronger binder comparisons | Four name checks changed to core_var_equal after TDD; actual native candidate suite and broad log confirm the stronger test passes |
| Output identity | Three pre-production/candidate C pairs byte-identical; get-or/opaque-key/layout controls. Direct runtime execution of the scratch oracle was not separately run |
| Enforcement | Actual separate --strict:504 allowlisted,0new/0stale; identity3446rows/budgets PASS; diff check PASS. Combined --strict --report would be census-only |
| Construction/provenance | FRESH O2 candidatea17a6ed3… unchanged; full309 patch, tracked9f017569… and untracked architecture draft pinned; all8packets source_changed=false; batchfalse |
| Process lifetime | Foreground session33531 exited0; owned native slot explicitly released. No runner-native jobs left; no quiet-host claim |

Exact base `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad`; installed baseline151ef0ac… and candidatea17a6ed3… were independently checked FRESH before/after their respective commands. Parent remained dirty with known candidate/docs; clean-checkout status is not claimed. Correctness source/binary hashes and all command vectors are retained in [the runner report](../correctness/TEST_RUNNER_REPORT.md), [provenance](../correctness/provenance.json), [commands](../correctness/commands.json) and [C comparisons](../correctness/c-oracles.json).

The original bad-premise source sidecar is an exact inverse reconstruction verified to the original file hash, not a pre-edit copy; [its manifest](../tdd/FIRST_ATTEMPT_PRESERVATION.json) states that method. The successful TDD test snapshot and candidate's stronger snapshot have different hashes and are not conflated.

Implementation/controller approval is independently recorded by other roles. This review does not claim nominal/binder/carrier/registry/stage migration, full native coverage of selector outputs, or proof of preexisting Void runtime reachability. Matched stage2 self/small allocation/instruction acceptance is a separate authority and is independently reconciled below.

No new gates, source/test/baseline/doc edits, measurements, commits or repo copies were performed for this review. Raw evidence remains unchanged.

## Read-only resource reconciliation after completion

After root confirmed session70900 exit0/native-slot release, I independently matched all four raw JSON hashes to the sealed postrun/measurement pins, verified exactly3 normal samples/minima and both unchanged integer +0.5% ceilings, and rehashed all four saved C outputs. Self: allocations245,063,861→245,078,157 (+0.005833581%), minimum instructions229,266,550,292→229,384,176,098 (+0.051305263%). Small: allocations1,689,044→1,689,099 (+0.003256280%), minimum instructions1,598,242,714→1,597,713,063 (-0.033139585%). Whole C is identical for both workloads.

[Readback](FINAL_RESOURCE_READBACK.json) records exact values/JSON/C hashes; the final proof is SHA256 `9ceca5793b737e484b4bec628a5211e3b78f6e7c375525a47c739931bb3d6553`. This check used no compiler/native execution, copied no large payload, and did not alter raw records. Actual stage2 pairs and construction prove identity; raw outside-repository stage1/unknown revision/freshness metadata stays unchanged. Background activity follows repository min-of-runs policy; no speed/wall-time or quiet-host claim.

Independent implementation/controller review and another role's independent resource review remain distinct. The earlier pre-resource version is preserved byte-for-byte in owned scratch (`INDEPENDENT_TEST_EVIDENCE_REVIEW.pre-resource.md`, SHA421a5fe95319eea606ee9e71579514289724ab2019841b993b8705ffef969b68); this appended reconciliation supersedes its pending resource status without rewriting raw evidence.
