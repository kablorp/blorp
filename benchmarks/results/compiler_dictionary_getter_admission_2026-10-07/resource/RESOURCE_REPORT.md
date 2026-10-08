# Dictionary getter reader: matched resource acceptance

**PASS within the frozen self/small scope.** Both exact integer 0.5% ceilings
pass with three normal instruction samples per side/workload and paired
diagnostic allocation accounting. Whole generated C is byte-identical. No
speed, wall-time or quiet-host claim is made.

| Workload | Base allocations | Candidate allocations | Allocation delta | Base minimum instructions | Candidate minimum instructions | Instruction delta | C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Self | 245,063,861 | 245,078,157 | +14,296 / +0.005833581% | 229,266,550,292 | 229,384,176,098 | +0.051305263% | Identical |
| Small | 1,689,044 | 1,689,099 | +55 / +0.003256280% | 1,598,242,714 | 1,597,713,063 | -0.033139585% | Identical |

All additional allocations occur in
`pass_tensor_specialize_specialize_fused_complete`: self 1,791,930→1,806,226
(+0.797799021% within that phase), small 5,432→5,487 (+1.012518409% within that
phase). Other phase allocation counts are unchanged. The specified ceilings
apply to whole-compilation total allocations and minimum retired instructions.
No profiling claim attributes the complete phase delta to an individual helper.

## Samples and background context

| Role/workload | Three retired-instruction samples | Range/minimum spread | Observed native-matching PIDs |
| --- | --- | ---: | ---: |
| Base self | 229358443838, 229266550292, 229513175201 | 0.107571257% | 137 |
| Candidate self | 229514439444, 230119776695, 229384176098 | 0.320684979% | 87 |
| Base small | 1628757591, 1598242714, 1610811785 | 1.909276778% | 5 |
| Candidate small | 1601355205, 1597713063, 1598468789 | 0.227959706% | 7 |

PID counts are unique process matches over each window, not simultaneous job
counts. The observer excludes its own ancestry/descendants and retains command
observations in `comparison/resource-commands.json`. Background activity and
sample spread, especially baseline small, limit interpretation. Maintained
`benchmarks/README.md:1893–1900` and `docs/WORKER_CHECKLIST.md:139–142` accept
background work and use minimum-of-runs. This proves the bounded enabling
ceiling under that protocol, without a speed conclusion.

## Source and binary authority

Base revision: `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad`.
Reviewed three-path candidate patch:
`309c7f9089401bdf5b503d6546412893aeee37f5dc21f5312c64d0c3998824db`.
Baseline captured stage1 generator:
`151ef0ac264ffeab97a521c39d02f96a7b627ba0019979ff21c97557db5b2cd8`.
Candidate FRESH stage1 generator:
`a17a6ed3cdfcac11df20e459bea1b7235a57768194d73551a78c0a76964513ab`.

| Actual stage2 pair | SHA256 |
| --- | --- |
| Baseline normal | c528f18fb491099061ca398436c4b0720a7583723ccdbc19067cab03670249e0 |
| Baseline diagnostic | 3ad79116cf014e21a780c116fa68ff34a8d380d583a0f20d59bfd7416ce5186b |
| Candidate normal | 0de63d8215e2600a6c4123fc97b554189f066a64a0918b8e0fe6a2db6d361cd2 |
| Candidate diagnostic | 5950a64a26fd267486193e331445e2704f9c02599104b762b908460aa8fd1a62 |

Pairs report CLI/runtime -O2, Apple clang 21.0.0 (clang-2100.3.34.2),
aarch64-apple-darwin, split 8, `compiled_by: self-2ee201fb5cb7`, and runtime
modes normal=0/diagnostic=1. The baseline pair was constructed before production
edits from the exact committed 636-file production/build/harness archive, with
stage1 FRESH before/after and pinned generated inputs. Its dirty version stamp
reflects checkout status; captured production authority is exact base. The
candidate uses the reviewed patch and passes FRESH before/after comparison.

Both workloads use the exact frozen 2ee input: 3,871 archived files plus the two
expected marker/generated-stdlib extras, inventory SHA256
`b4791d0dda99868f86e18250c58ad572b53695d848a3e8e95588482a39054db2`.
The local small input is pinned before/after. Explicit /tmp pair paths leave raw
harness `compiler_rev=unknown` and incidental `compiler_stage=1`; sealed
construction establishes actual stage2/source authority. Raw fields were not
rewritten. Path comparisons canonicalize both recorded/expected aliases.

Self whole-C identity: 83,981,861 bytes, SHA256
`9f304f4b6c1b0911ff95bc9df3cbc3c6346bb6811b6cf69cae742861bd352e0c`.
Small: 40,512 bytes, SHA256
`8316ceeb6e78c5e7d6431c33d1a22b0b9ff9bb59b2ecd603fbc38b8a5b618abb`.

## Independent source review

**APPROVE: 0 blockers, 0 should-fix findings, 0 nits.** The compiler-expert
reviewer checked the frozen patch and six boxing callers. Private erased-slot
variants carry the existing named ABI indices 1/2; exact generic getter/set/
insert/fold branches retain their prior conditions. Builtin fallback uses the
producer's alias-aware Option selector once behind two-argument admission.
Unknown/mismatched getters no longer inherit boxing. Fresh-key evaluation,
allocation and release code is unchanged. Controls cover fourteen scalar
getters, managed/payload/Option aliases, generic/unspecialized cases, wrong arity,
non-Builtin calls, repeated specialization and borrowing. The ownership test
uses existing `core_var_equal` and matching synthesized vars without claiming
new binder identity. Existing Void selector/runtime-support uncertainty remains
separate. No broader registry, IR schema, storage, kind-carrier or stage change
is included. Independent correctness evidence is owned by the test-runner.

## Controller and post-run proof

Independently reviewed repaired controller SHA256:
`b4af2609415b87f1a39e357c6393f395f199c16d9f6b43dfb30e4e3ae6b8b7bd`.
Post-gate candidate pin SHA256:
`f3e2bd9831420df4f5807eab7fd93bea85b48267cef5c861c8c0f23c0dcbf09d`.
The earlier scratch template's missing late JSON/C drift check was repaired
before any metrics ran. Each validated pair pins exact parsed JSON and saved-C
bytes immediately, checks those pins through later commands, then rereads all
four records/C and recomputes both budgets before the final seal. Independent
repair/config review approved with zero findings; synthetic drift probes passed
2/2. No raw record was modified.

Baseline `CAPTURE_COMPLETE.json` SHA256:
`39d6592b85309ce79101be6ce5082c38d0f920f859b58aeab8183ef818381e61`.
Final `comparison/COMPARISON_COMPLETE.json` SHA256:
`9ceca5793b737e484b4bec628a5211e3b78f6e7c375525a47c739931bb3d6553`.
All 18 sealed baseline payloads and 27 final comparison payloads were rechecked.
Full tracked, untracked test/document, production, generated-input and generator
pins stayed fixed. The archived baseline remains authority after live production
edits; no live baseline source-FRESH demand is imposed.

Exact native invocation was the shared `native_slot_serial.py` wrapper with
600-second maximum lock wait and `compare_resources.py --run-comparison`.
Its child command ledger is `comparison/resource-commands.json`. Verbatim
comparison tables are `comparison-self-verbatim.txt` and
`comparison-small-verbatim.txt`; raw JSON/C and summaries remain in
`comparison/`. Native session 70900 exited 0, the owned slot was released, and no
owned native jobs remain. No rerun, source/controller/pin edit, or threshold
relaxation occurred. Recommend accepting this bounded reader cut with the
separate correctness/source-review approvals; root owns integration and commit.
