# Carried bindings at structured joins

Design reviewed by root and two independent compiler experts. Source baseline:
main `e6785c22fb050572d703301eb1435f9cb8fcef4b` (2026-10-16), with the later
argument lifts noted below. Preparation budgets are accepted; the physical probe
and measurement-baseline review precede broad migration. No implementation,
builds, tests or measurements have run. Feature budgets remain unapproved.

## Problem and first input

The retained source needs mutable locals across statement control.
[resolve_assignment](src/check/bodies.brp) (754–779) rejects this assignment
at the `total` name: “reassigning a variable declared outside this match arm is
not supported yet”; help: “bind the match's value with name = match ... instead;
reassignment inside an arm arrives with joins that carry reassigned variables”.

```blorp
pure func choose(flag: Bool) -> Int:
    var total = 1
    match flag:
        True: total = 7
        False: void
    total
```

Expected: `choose(True)` is 7; `choose(False)` is 1. With a fresh pilot, reproduce
the existing [rejection fixture](test/e2e/fixtures/unsupported/join_reassignment.brp) from the repository root:

```sh
blorp_2/build/compiler --library-root blorp_2/standard_library_temp blorp_2/test/e2e/fixtures/unsupported/join_reassignment.brp blorp_2/build/join_reassignment.c
```

The next managed input uses existing target APIs and a supported managed record:

```blorp
fixed record TextPair { old: String, current: String }
pure func choose_text(flag: Bool) -> TextPair:
    var text = 1.to_string()
    old = text
    match flag:
        True: text = 777.to_string()
        False: void
    { old = old, current = text }
```

A real `main` must print both fields: True gives `1\n777\n`, False `1\n1\n`.
Use allocated Strings so immortal literals cannot hide a missing acquisition.

## Chosen boundary and precedent

Adopt structured steps with attached parameter facts (the smaller Option A).
[MLIR SCF if/yield](https://mlir.llvm.org/docs/Dialects/SCFDialect/#scfif-scfifop)
publishes multiple results whose selected region yields matching types.
[Cranelift block parameters](https://docs.rs/cranelift-frontend/latest/cranelift_frontend/struct.FunctionBuilder.html#method.append_block_param)
are explicit typed values; [jump arguments](https://docs.rs/cranelift-codegen/latest/cranelift_codegen/ir/trait.InstBuilder.html#method.jump)
match their destination's arity and types. References checked 2026-10-16.
Adopt their ordered edge contract and fresh immutable outputs within existing
nested arms/numbering/lexical verification; no CFG, variable-SSA algorithm or optimizer.

Current [lower](src/lower/lower.brp):90–102 embeds `JoinValue(LoweredJoin)` in
`ValueDefinition { id, value_type, operation, span }`. Private `BlockEntry` (200)
already separates definitions/pending joins; publish it without projection operations:

```blorp
fixed record ValueParameter { id: ValueId, value_type: TypeRef, span: Span }
fixed union LoweredStep:
    Define(ValueDefinition)
    Join(LoweredJoin)
fixed record LoweredJoin {
    result: ValueParameter,
    carried: List[ValueParameter],
    scrutinee: ValueId,
    owner: UnionInstanceId,
    arms: List[JoinArm],
    reads: List[ValueId]
}
```

Keep ordinary `ValueDefinition`; replace function/block/arm `definitions` lists
with `steps: List[LoweredStep]`.
`JoinArm { label, steps, value: ValueId, carried: List[ValueId] }`
matches the result/carried parameter order. Existing parameter/result/operation
spans own diagnostics; this increment adds no edge-span carrier or note convention.

```text
v0:Bool = parameter(flag); v1:Int = integer(1)
Join(result=v2:Void, carried=[v3:Int], scrutinee=v0):
  True:  v4:Int=integer(7); v5:Void=void; yield(value=v5, carried=[v4])
  False: v6:Void=void;                  yield(value=v6, carried=[v1])
return v3
```

One step introduces v2/v3; `total` has one BindingId with immutable versions v1/v3.

## Complete facts, owners and consumers

| Product/producer | Published change, lifetime and consumers |
| --- | --- |
| Check, `model.brp:254`, `bodies.brp:571–668` | `CheckedJoin { scrutinee, union_type, arms, carried: List[BindingId] }`. Checker alone owns binding scope, mutability and type in the function binding table. Collect direct writes during checking, merge nested joins' carried facts, filter identities absent from the join-entry scope, and freeze unique IDs in ascending binding ordinal. Arm captures/locals never escape. Transient write collection dies at publication; later phases never rediscover assignments. |
| Specialize, `specialize.brp:287,2452` | `ConcreteJoin { scrutinee, owner, arms, carried: List[Checked.BindingId] }`; preserve order/identity verbatim. Concrete binding types remain in `ConcreteFunction.bindings`; do not repeat a carrier type table. Specialization remains the authority for managed/inline storage. |
| Lower, `lower.brp:398,514,704` | Mint `[result] + carried` parameters once, before continuation lowering. The local binding-version map snapshots the pre-join map for every arm and maps continuation carriers to fresh parameters. Add a block-value result returning builder/value/updated bindings at the existing statement, initializer and arm-tail boundary; ordinary expression-child lowering remains unchanged. An arm reads carriers from its final map, including a nested final join's updates. Apply an initializer/reassignment's target binding after its RHS join's map update. Maps die at lowering publication; parameter facts live with lowered/owned products. |
| Lower reads and numbering | Every block's introductions form one dense interval; its deferred join arms follow the complete block, in current join/arm order, recursively. Count explicit introductions, never steps. Publish `reads` bottom-up once: scrutinee plus external operand and outgoing-edge occurrences, including unchanged carriers and repetitions. Ownership uses this summary without rewalking arms. |
| Own, `own.brp:111–156,704–812` | Remove `JoinDefinition` from ordinary value operations. Add `OwnershipOperation.ExecuteJoin(OwnedJoin)`. `OwnedJoin` has result/carried parameters, scrutinee, owner and arms; `OwnedJoinParameter = UnmanagedJoinParameter(ValueParameter) \| ManagedJoinParameter(ValueParameter, OwnerId)`. Borrowed join outputs are unrepresentable. `OwnedJoinArm` has operations, `transfer: ReturnTransfer`, ordered `carried: List[ReturnTransfer]` and its label. All parameter owners are introduced together at the control step; each unused output drops after the complete join. Use/source maps are transient; obligations end at verified transfer/drop. |
| Verify, `verify.brp:112–165,1532,1623,2251` | Continue publishing only sealed `VerifiedProgram = OwnershipProgram`. Independently introduce every parameter into existing local `KnownValue` facts and active owner facts; snapshot state before introduction for all arms. The parameter list is the only output signature. Validate each raw edge's length, exact concrete type/availability, ownership and complete discharge, then seal. Do not trust insertion's last-use decisions. |
| Emit, `emit.brp:1340,1796,2022,2070` | Read verified parameters: declare one fresh C local per output, assign from each selected edge, then establish its owner alias. Never use source BindingIds or infer carriers. Update existing disposable `owner_types`, block traversal and program inventory to enumerate every introduction, including Void/unused outputs. Keep one existing temporary type projection, not a new retained authority. |

For every raw parameter, verify derives ownership through existing
`value_ownership` (specialize:443), independently of insertion and the supplied
Managed/Unmanaged variant: only `NoOwnership` permits Unmanaged. All other
classifications require Managed. Validate type/layout membership, consecutive
distinct ValueIds and consecutive fresh OwnerIds using existing ordinal checks;
one parameter cannot reuse another's owner. This introduces no ownership authority.

Keep last-use row indices as local **value slots**, with `Option[Int]` contents
as **execution-step positions**. An opaque ValueId plus deliberately named Int
cursors (`step_position`, `introduced_count`, `next_value`) suffices here; a new
position identity would add conversion machinery without a cross-product use.
Terminal position is `steps.length()`; `use_slot` gets introduced-count bounds
separately from step position. Per-step drop buckets may serve several outputs.
No ValueId arithmetic may index steps.

Remove these concrete assumptions: [own](src/own/own.brp) `block_uses:278` creates
one use row per definition and compares IDs with position; `terminal_span:252`,
`returned_span:913`, `insert_match:1081` index definitions by value ordinal;
`insert_block:965`/`insert_join_arm:1004,1013` derive intervals from list length.
Update lower's arm interval (719) and own's scalar-tail admission (1168). Find
terminal/scrutinee spans once per block using attached facts; reuse for insertion.
Drop buckets use step spans. Add no global catalogue/type index; stop on repeated scans.

## Edge obligations and diagnostics

OwnerId names a discharge obligation, never pointer or ValueId identity. Bindings
may alias one ValueId without introducing an owner. Each managed outgoing slot,
however, must have an independent obligation, even when result and carrier agree:

```text
outputs: result=v2:String/o1, carried=[v3:String/o2]
arm outgoing values: [v1, v1]                 # same String, two occurrences
acquire o3 from v1; acquire o4 from v1         # both before local retirement
yield [OwnedReturn(v1,o3), OwnedReturn(v1,o4)]
continuation owns o1 for v2 and o2 for v3      # enclosing old alias stays live
```

Insertion dispatches by the ordered output contract: **empty carried** means one
result and retains today's unary `leave_with` transfer, numbering, C and ARC;
**nonempty carried** means multiple outputs and acquires each managed occurrence
before retiring only terminal-live arm-local source owners, then transfers the
batch. Exclude already-retired owners and fresh edge acquisitions from retirement.
Never dispatch by managed-slot count or pointer equality; no move-selection table.
This correctness-first policy follows `store_payloads` (own:462) and needs measured
cost evidence. The general verifier accepts any correct strategy; it neither
reproduces insertion dispatch nor repeatedly runs unary `verify_yield`.
Projected children acquire while their parents remain live. Enclosing owners
remain live on every join edge and retire at their enclosing last use.

Exact edge ARC oracles (retains/source retirements; exclude continuation cleanup):

| Source/output case | Required counts |
| --- | --- |
| Unary fresh local / unary enclosing | 0/0; 1/0 |
| Two occurrences of one local / one enclosing value | 2/1; 2/0 |
| Two distinct local managed values | 2/2 |
| Void result plus one local String carrier | 1/1: conservative extra retain/release pair |

Assert acquisition order before parent/source drop as well as counts. A future
one-local-owner move may remove the Void/String pair only on demonstrated cost
need and separate review; pointer equality never selects that optimization.

Keep target mutability/scope errors before RHS checking, then expected binding
type, source arm order and existing coverage checks.
Remove only `JoinArmReassignment` at feature landing. Assert typed CheckError
kind/expected/actual identities before rendering, plus exact help and half-open
SourceId span; ordinary immutable/type/purity errors must not become IR errors.
Parameter origins are match occurrence for result and declaration for carriers;
these are distinct from the precise RHS spans already owned by frontend checking.
Preserve every unary legacy join-result diagnostic span/text/priority in both
preparation and feature. Raw multi-output slot/type/ownership errors use the
corresponding output parameter's attached origin; arity uses result span, and
operation failures use their existing spans. There is no written yield occurrence
to publish. Require a concrete deficient consumer before adding span metadata.

## Reviewable landings and costs

1. **Design:** this document and roadmap link; coordinator and independent review
   accept preparation shapes/scope/budgets; feature budget approval waits for its diff.
2. **Preparation:** migrate lower/own/verify/emit and all raw-IR test builders in
   one coherent, separately reviewable commit. Publish a single result and empty
   carriers; preserve source rejection, all ValueId/OwnerId numbering, owner
   transfers, every fixture's C and complete diagnostics. Add direct multi-output
   use-analysis inputs so step/value separation is actually tested without new
   source acceptance. Delete replaced join-operation cases in the same slice.
3. **Feature:** checked carried identities through specialization, block maps,
   multiple edge obligations and full acceptance tests together; migrate the
   old unsupported fixture and update README/grammar/GUIDE as their rules require.
   No partially enabled checker, optional authority or feature flag may land.

Before broad `Define(ValueDefinition)` migration, a short-lived Blorp TestSuite
compares ordinary-definition construction/traversal with the exact proposed
wrapper/parameter shapes through the normal host test entrypoint. Inspect
C for managed boxes/copies/releases. Measure N=16/32/64/128, setup excluded,
snapshots retained: record allocation/instruction deltas and projected corpus cost.
Review before proceeding; stop if +3% looks unattainable. No production alternative
or waiver of full matched evidence: source estimates do not prove cheap storage.

Source-based preparation estimate: lower 100–150 added/+20–40 net, own
180–250/+50–80, verify 110–160/+20–50, emit 70–100/+10–30, plus 40–90 added/
+0–20 net caller/analysis adjustments: **500–750 added/+100–220 net production**.
This credits deleting embedded JoinValue/JoinDefinition branches, definition
wrappers around joins and direct definition lookup helpers, not unrelated cleanup.
Preparation hard **800 added/+250 net** is accepted, subject to the probe and costs.
Report separate physical added/deleted/net production/test lines; preserve formatting.
Preparation tests: 50 unit modules reference the affected definitions/operations;
estimate **700–1,100 added/+100–350 net**, accepted hard **1,400 added/+450 net**.
This covers builder migration and new typed negatives; no source fixtures change.
Preserve coverage and readable formatting within the separate test cap.

Preparation ceiling: **+3% allocations/minimum retired instructions per frozen input**,
including host source-to-C/shared pilot proxies, accepted as a hard stop.
Before measuring, explicitly review the current capability baseline and roadmap
cumulative metrics. Intentional UTF-8 C changes need their own reviewed identity
epoch; they waive no old cost cap and authorize no backport or framework.
Feature targets **+5%, hard +10% per shared input**; no average masks a breach.
Proposed minimal scalar/String caps: **30,000 allocations/150,000,000 instructions**
(current bound fixtures cap about 15–17k/78–98M); set stress caps from scaffolding.
These feature numbers are not initially authorized. After preparation, review
its complete producer/consumer diff and all costs separately. Feature production
proposal: **450–750 added/+250–450 net**; unit/runtime/registration tests excluding
fixtures **900–1,400 added/+650–1,100 net**; **6–8 fixtures/140–240 lines**.
Proposed stop caps: production **900 added/+450 net**, tests
**1,600 added/+1,300 net**, fixtures **10/300 lines**. All remain unapproved;
**+350/+450 net** is only the earlier feature estimate. Keep existing cost caps.

## Acceptance, dependencies and stop rules

Use named direct TestSuite callbacks in existing `test_{check,specialize,lower,
own,verify,emit}/test_join.brp` and `test/unit/join_inputs.brp`. Assert scalar
True/False, bound-result-plus-carried, nested and untouched arms, two carriers,
arm-local filtering, exact immutable versions, old aliases, repeated pointers,
projected children, retired temporaries and unused outputs. Insertion/verification are separate:
negatives cover wrong arity/type, sibling/continuation access, duplicate transfer,
borrowed escape, early parent drop and one-path leaks. Break one protected arm's
acquisition/identity/cleanup deliberately, require the exact test to fail, restore.
No subprocess per pure typechecking assertion; extend direct typed input helpers.

Add exact interaction callbacks and deliberate mutants:

- Starting with `var left = 1`, assign `left = match ...`: True writes 7 then
  yields 9; False yields 3; continuation must read 9/3. A target-before-RHS-map
  mutant returns 7 on True and must fail; assert exact target/result/carrier IDs.
- An outer arm ends in an inner join writing outer `total`: TT returns 7,
  TF and outer-False retain 1. Dropping the final inner join's map update fails TT.
- Steps `Define(v0:Bool)`, `Join(v0 -> v1:Void,v2:Int)`, `Define(v3=call(v2))`, return v3:
  assert four value rows, three steps, last-use rows `[Some(1),None,Some(2),Some(3)]`.
  Replacing introduced-count bounds/slots with step indices must fail this test.
- Two Int carriers start 11/22 and become 101/202 on True: assert ordered binding
  IDs, edge values and real-main output `101\n202\n` / `11\n22\n`.
  Swapping same-typed edge arguments must fail the oracle despite type compatibility.

Raw parameter negatives also mark String/List/managed record/owning union unmanaged,
mark a primitive managed, duplicate a ValueId or reuse an OwnerId. Assert exact
verifier message/help and the specified parameter/result/operation SourceId spans.
Raw positives accept legal unary move/acquire and mixed multi-output transfers.

Runtime `test_string.brp`/`test_record.brp` observe real alloc/free and repeated
children using production fragments. Real-main cases go in `test/e2e/fixtures/join/`,
registered by `test/e2e/test_join.brp` through `test_end_to_end.brp`; compile once,
check both branches' exact output/status under native sanitizers, inspect unmodified C.

Runnable lane for the coordinator/runner, from a fresh isolated writer checkout:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_join.brp blorp_2/test/unit/test_specialize/test_join.brp blorp_2/test/unit/test_lower/test_join.brp blorp_2/test/unit/test_own/test_join.brp blorp_2/test/unit/test_verify/test_join.brp blorp_2/test/unit/test_emit/test_join.brp
bin/blorp test --suite --timeout 180 blorp_2/test/runtime/test_string.brp blorp_2/test/runtime/test_record.brp
bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit
make -C blorp_2 test
scripts/blorp2-fixpoint --frontier
git diff --check
```

If host status is not FRESH, coordinator rebuilds and rechecks first. Serialize
compiled work/measurements. Freeze source/binary/toolchain/flags/input hashes;
retain raw samples under build and one report under benchmarks/results.
Measure separate join-count and carrier-count series N=16/32/64/128, nested and
sequential shapes: introduction/record construction, access and traversal work,
allocations/instructions, C bytes/depth, phase and whole compilation. Expected
explicit work is proportional to steps plus output/read/edge occurrences, not a
blanket linear-allocation promise under host COW. Investigate repeated quadratic
doubling separately from inherited growth. Name owned-input proxies honestly;
require real self-compile/fixpoint evidence when possible.
Hold four joins/two carriers fixed; vary binding-table width N=16/32/64/128, retaining
both arm snapshots per join. Measure snapshot creation, first mutation and rebinding;
report bytes copied and allocation/work growth to expose binding-map COW.

Argument lifts are accepted at `c02a9efdc25e358e5620f0ef3c5404765f5b0d38`;
coordinator confirms no IR-shape change. Integrate current main before coding,
coordinate phase writers and obtain two design reviews/budget acceptance, then
code-reviewer/test-runner reviews. Constructor/UTF-8 work adds no carrier authority.
M3 may later reuse ValueParameter for header/backedge/break; no loops, managed TCO,
M7, arbitrary-expression control or inference/workloop relocation here. Preserve
SourceId/name/namespace authority and storage policy.
Restricted `if` can consume the same join later in M2.2; it adds no syntax here.

Stop on incomplete publication, required new global environment authority,
repeated semantic joins, expression-scope expansion or a budget breach. First
try fewer local wrappers/deleted obsolete cases; otherwise retain the rejection
and request a smaller slice or explicitly reviewed budget. Consider a function
value catalogue only with a demonstrated query that attached facts cannot serve.
Hand back source/branch/diff, separate LOC, typed and mutation outcomes, complete
C/diagnostic identity, provenance/raw paths and measured per-input verdicts.
Open preparation decisions: physical probe and baseline epoch/cumulative metrics.
After preparation, review feature transfer costs/fixture caps against its concrete diff.
