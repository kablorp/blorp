# Blorp 2 completed record layout sum

Status: resource experiment and integrated qualification complete, 2026-10-22;
final landing reviews are retained with the integration evidence. Parent is
`6ef8b68296ee70e63fcee18b7cedce23e1720b48`. The fixed original remains
`cdfa1bc6009da61415f26b9f812f1dfbf23a6ebc`; it was not reset to Parent.

ConcreteRecord now owns its one ordered TypeRef list through InlineFields or
CountedFields. This removes the separate completed managed record wrapper;
the existing private pending representation choice is consumed at settlement.
There is no second slot array, global layout catalogue or change to record,
tuple, capture, union, callable, Void or nominal-ID policy. Verify retains
independent raw membership, graph, inline eligibility and ownership checks.
Counted eligibility-rescan optimization is excluded from this change.

Handwritten production is 81 ADD / 68 DEL, net +13 across Specialize, Verify and
Emit. Lower and Own production are unchanged. Mechanical test observations use
record_fields only for ConcreteRecord; CheckedRecord fields remain unchanged.
Tests are 195 ADD / 192 DEL, net +3 across 37 files. Documentation is counted
separately in the final landing packet; no assertions or registered callbacks
were removed to obtain the production result.

## Matched measurements

All roles compile the same original frozen source/library from the same CWD,
private environment and physical output pathname. Strict Original/Parent/Candidate
runs precede fixed normal O1 P1 C1 C2 P2 O2 O3 P3 C3. A single fresh confirmation
was declared after the first batch review; there are no retries, replacements,
warmups or third batch. Every one of the 24 actual outputs is byte-identical C
`f8309136d4a0f53625d2ca4062579874b314adf1e2f649f82074f4fe2b80785a`.
All persisted input/tool/role guards match; normal stdout/stderr are empty.

| Metric | Original | Parent | Candidate | Parent delta |
| --- | ---: | ---: | ---: | ---: |
| Strict allocations, both batches | 30,998,075 | 30,689,853 | 30,689,378 | −475 (−0.001548%) |
| First normal min3 instructions | 899,545,649,469 | 899,470,324,849 | 899,430,227,864 | −0.004458% |
| Confirmation normal min3 instructions | 899,453,029,639 | 899,381,640,203 | 899,414,745,212 | +0.003681% |

Strict releases equal allocations with zero leaks in every role/batch. Normal
ranges overlap and the deltas change direction: no speedup claim. Both batches
pass the prospective +0.25% Parent instruction guard and independent +3% fixed
Original allocation/instruction guards. Those guards are not benefit credit.
The demonstrated benefit is the repeated small allocation reduction; production
grows by 13 lines within the predeclared maximum 40.

Actual generated C stores the completed row as an inline-owning tagged union
containing the field-list pointer. It has no row allocation constructor; table
elements and RecordInstance embed the carrier instead of a row pointer. Its
record_fields accessor performs branch-local List retain operations. This widens
some containers: the actual completed carrier changes from a 24-byte managed
row to a 16-byte inline owning sum; RecordInstance grows from 24 to 32 bytes,
and table elements grow from an 8-byte pointer to 16 bytes. Existing Clang
record-layout dumps establish these ABI sizes, not an aggregate retained-byte
reduction. The measured
workload contains 475 actual record definitions; the separate current-Parent
compiler census has 477. These observations explain this workload's reduction,
not a general allocation-per-row guarantee.

## Behavior and limitations

Parent focused selection: 31 owners / 281 PASS. Two new raw cases passed against
the old model before migration: unused counted numeric layout and later invalid
callable member after an owning first field. Candidate focused selection passed
283 callbacks with original order/predicates preserved. Seven further owners,
including the five omitted field-only observers, passed 63 callbacks. Full
hosted unit/runtime/grammar passed 4,349 callbacks with empty stderr and guards
unchanged. Initial setup failures are retained and receive no behavioral credit.

Source-valid counted-root False fault produced exactly 19 PASS / 1 FAIL in the
complete record Verify owner: `published representation decides record parameter
ownership`. Bypassing the nonempty raw-layout gate produced exactly 19 PASS /
1 FAIL: `unused empty layout`. Both restored owners passed all 20 callbacks.
Source bytes/modes/guards restored exactly; actual pinned Make regeneration
reproduced canonical Candidate compiler C
`2188ad20ab2e60fbceedeb7cf968e79883900f0873477d12b74c9e17e0a718c3`.
This is compiler-C identity, not ephemeral TestSuite-C identity.

The Candidate uses the existing pinned B2 seed and unchanged target library;
normal/diagnostic links use the same generated C at -O0. No legacy production
build, alternate main, generated-C rewrite or foreign assertion program is used.
Root integrated qualification passed 4,537 component callbacks (4,349 hosted
and 188 target), with 27 positive balanced strict target reports. A further
target-only run under the actual self-built stage B passed all 188 callbacks
and the same 27 strict reports. The unchanged fixpoint proof produced identical
seed/A/B/C compiler C and passed all 581 fixture contracts: 486 accepted with
identical C, and 95 located rejections with help. Stage B passed all 584 native
cases (1,371 raw PASS rows, zero behavioral FAIL rows).

Whole-current-source compilation through the ordinary self-built main and then
its ASan/UBSan image each reported 31,129,371 allocations and releases, zero
leaks, empty stdout and no other diagnostics. Both emitted canonical C above.
This current-source workload is separate from the frozen-original cost batches.
All integration input guards matched. Broad inherited allocation debt remains
explicit: 117 structured FAIL markers under record-allocation-debt, with every
limit unchanged. Disabled broad instruction checks are unmeasured; they are not
a cost PASS. Two independent final reviews cover the complete landing packet.

Raw evidence and exact manifests: ignored
`build/layout-e1-record-sum-2026-10-21/worker/`, including source02 through
source05, BUILD_RESULT.json, C_REVIEW.json, COMMON_WORKLOAD_C_CENSUS.json, both
measurement SUMMARY.json files, the fault-proof directories and RESTORATION_C.json.
The complete copied inventory is bound by PRESERVATION_MANIFEST.json. Root
resource audits are under `build/layout-e1-prototype-2026-10-21/`; final integrated
commands, streams, guards, contract audits, preserved fixpoint artifacts and
reviews are under `build/layout-e1-integration-2026-10-22/`.
