# Host-compatible List update names — 2026-10-18

The target library again matches the unchanged host library: `set` returns
`List[T]`, preserving the original value for an invalid index; checked
`set_index` returns `Option[List[T]]`. The checked get/match implementation stays.
Only two declaration names and its internal callee change (3 ADD / 3 DEL,
no production line growth); four fixtures and their owner descriptions change
names without changing expected output (26 ADD / 26 DEL, no test line growth).
Compiler sources, host library, intrinsic labels and every cost limit are unchanged.

The same compiler source is built against both libraries. A target-only rename
breaks its imports and a source-only rename breaks the host build. The desired
checked `set` / no-op `set_or_keep` naming is therefore
[deferred to one coordinated change](https://github.com/kablorp/blorp/blob/2ebbebf83c08b45cdf0c807453f89e12fb4b4ac9/blorp_2/LIBRARY_PARITY.md#deferred-list-update-naming)
across both libraries, callers, tests and docs. No compatibility alias or build
adapter is added. The earlier checked-helper allocation approval remains in
force; this change grants no new allowance.

## Validation

Base is `cf41b4a6f53a39195ab78fd89f4191142b91de2a`. The
[setup receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/SETUP.json)
verifies all 41 compiler source hashes against the accepted producer. Its normal
binary is a197b6a6c16ecbedfa882115099f49f645bdb711e8188ab53d141f73d685a34c;
diagnostic is b3e845439a17fea297d7d9cf1e3fa2f72a9ddebef38473b6e77804711e3ab91b,
from retained C 0bff8c8110267df2c1fcf15eec7c4d7aea0e061f110ff2818dbdef8e9a9fa477.
No compiler rebuild or relink is needed. The root host is FRESH, with its root
host standard library selected explicitly for the native TestSuite.

The updated checked fixture first [fails against the old target names](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/RED.json)
with exact `module list declares no public function or type set_index` and
`help: select a public function or type that list declares` at 2:24; exit 1,
no C. After the implementation change, all four changed fixture inputs compile.
Eight ordinary CLI emissions produce [byte-identical B/C C for every fixture](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/C_IDENTITY.json).
The checked fixture retains C SHA a6b3c48971ffafd5050f3d40f27e20a1ccd99e5d06502f1e4fc000fb77d8f227,
so its previously reviewed ownership and native branch-fault evidence remain
applicable. No C is edited or normalized. This is output identity, not a new
performance measurement.

The [original cf41 native gate](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/independent-full-native01/RECEIPT.json),
SHA e33ecbdac937ee0a226b7a7a195017be401a61914dc1cfe0fc97a53e9987fa3a,
passes once: 493 fixture callbacks, 599 nested native checks and one umbrella
(1,093 PASS / 0 FAIL). All 401 cost rows pass unchanged limits, stderr is empty,
and all 1,626 pins plus Git before/after state agree. Pipe-String uses
12,523 / 13,000 allocations and 64,644,233 / 65,000,000 instructions; the checked
fixture uses 42,827 / 45,000 and 136,981,299 / 200,000,000 diagnostic instructions.
No compiler rebuild, relink or retry was made.

## Historical eb7 composition

Main advanced during validation to `eb7b9fe1bd5dec40a8a2dd8acfae27fd02b53e6e`,
which publishes scalar constants as checked literals. The earlier naming tests
remain evidence against cf41; they are not relabeled as current-main gates.
The [current producer receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/CURRENT_MAIN_PRODUCER.json)
checks retained source pins and exact accepted Git blobs. Its normal binary is
405899c278e49c7ce1b25fe6e498f8a209223e42a801c806c5bddf7223538e23;
diagnostic is e0c2742473f49782b816f6ba8b1db5c636851bf578bdf405cc4689fa9e6c911c,
from C 9dbcc103a638acb32e4dfc9fa5439336d724bcaf324ac77bad06a1e0f07c166f.
The accepted compiler owns its separate 3,516 component, seven tooling and
1,095 native checks. No compiler generation or relink is needed for this
library naming change.

The [composition receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/COMPOSITION.json)
retains the exact feature patch and index tree before fast-forwarding the branch
and reapplying it. All feature postimages agree except README, which preserves
exactly the three accepted scalar-constant lines. All 41 source hashes match the
new accepted producer and no compiler/host source belongs to this feature.
Eight [fresh ordinary CLI emissions](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/C_IDENTITY_CURRENT_MAIN.json)
again produce identical B/C C for all four fixtures using the same new compiler
under both sets of library/fixture names.

The [current-main native gate](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/independent-current-main-full-native02/RECEIPT.json),
SHA c42aad4c2dbb356f4afb38d23b9b5b38c7b24d7f74b0a7f6f49604910eae1e49,
remains **FAIL**: 493 direct callbacks pass and one fails its instruction limit;
all 600 nested native checks pass, and the umbrella fails. Flat totals are
1,093 PASS / 2 FAIL. All 402 allocation rows and 401 instruction rows pass.
Pipe-String uses 12,523 / 13,000 allocations and 66,572,995 / 65,000,000
instructions, exceeding that limit by 1,572,995 (2.419992%). The checked fixture
passes at 42,827 / 45,000 allocations and 136,909,217 / 200,000,000 instructions.
Stderr contains only `compiler retired instructions exceeded limit: 66572995 > 65000000`;
all 1,640 pins and Git before/after state agree. Required
instruction counters, strict zero accounting, real main, C11/O0 and ASan/UBSan
remain enabled. No retry, rebuild, relink, threshold edit or test-policy change
was made.

The accepted scalar gate observed 64,421,970 instructions for this fixture, but
used the primary checkout rather than this worktree; that is not a matched
naming-cost comparison. The [bounded eight-call diagnosis](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/pipe-diagnosis/RECEIPT.json)
uses the same compiler and copied physical input/library/output paths for both
name sets: 12,520 allocations/releases and zero leaks in each diagnostic role;
normal min3 is 41,409,549 before and 41,377,768 after (-0.076748%). All eight C
outputs agree exactly. These samples show no observed naming regression at
that boundary, not a speedup or an absolute gate pass. They time the compiler
directly; the native harness times `/usr/bin/env` as well. This boundary and the
copied paths differ from the gate, so neither the gate's cause nor measurement
variance is established. Investigating that discrepancy is separate work.

The historical [publication proposal](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/PUBLICATION_WAIVER_PROPOSAL.md)
requested an exception for that observation. It received no human approval.
The failed gate and all original limits remain unchanged. The later corrected
measurement gate below supersedes the request without granting a waiver; the
[decision record](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/PUBLICATION_WAIVER.json)
preserves both dispositions.

The ordinary [self-compilation probe](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/list-bootstrap-names-2026-10-18/FRONTIER_CURRENT_MAIN.json)
now advances past `list.set_index` and stops at `verify/verify.brp:8:8`:
`module list declares no public function or type contains`, with the same public
export help; exit 1 and no C. This proves only the new first failure, not complete
source checking or a self-compiled compiler. Adding `list.contains` is outside
this naming correction.

The old [naming report](blorp_2_list_set_names_2026-10-18.md) retains all original
cost samples, failures and approvals, with a superseded-names note. Final
code-reviewer and test-runner approval of the exact staged patch is required
before commit; their records stay with the ignored evidence packet.

## Corrected measurement gate, 2026-10-19

The exact combined tree is accepted `cc46927dd` plus the independently reviewed
[compiler measurement correction](blorp_2_compiler_measurement_2026-10-19.md)
and this naming change. All 41 compiler sources match the accepted F5 producer;
its normal/diagnostic hashes are `0b8fbcdb890322ced79e05abefd1800979868b64df7ad99d03e78203f0abbe95`
and `12cc9cd5a816423acaa714452c1b5a05ea24b0117c3e36e6182a78e6b7477d13`.

The [new gate receipt](/Users/keithphilpott/CLionProjects/blorp/build/bootstrap-evidence/bootstrap-library-land-2026-10-19/test-runner/execute01/RECEIPT.json),
SHA `992cbb964dd1ab4900f644d6c962c20a5cef424f1617a347930350bd59cfe6e4`,
records 47 focused PASS, four fresh byte-identical B/C fixture emissions,
3,528 component/runtime/grammar PASS and 1,095 native PASS / 0 FAIL
(494 direct callbacks, 600 nested native checks, one umbrella). All 402 cost
rows pass unchanged limits, with required instructions, strict zero accounting,
real main and C11/O0 ASan/UBSan. All 1,016 pins and Git state remain identical.
No rebuild, retry, generated-C edit or numerical-cap change occurred.

Pipe-String is 12,523 / 13,000 allocations and 55,889,556 / 65,000,000
instructions; checked-set is 42,827 / 45,000 and 128,202,318 / 200,000,000.
These are a newly declared gate boundary, not a matched speedup or a
retroactive pass for the historical failure. The two changes are separate
commits; this full-gate evidence covers their final combined tree only.
The fresh ordinary source probe still stops at missing `list.contains`,
`verify/verify.brp:8:8`, exit 1 and no C. Self-compilation remains incomplete.
