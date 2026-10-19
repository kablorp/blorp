# Ordinary opaque types with erasure after checking

## Status and scope

Current proposal, before implementation, on accepted main
`dcd8beb0af83f156ad0c482b2fd3235ba72bb8dc`. Root, architecture and test reviewers
agree with the user's 2026-10-18 correction: opaque identity matters during
checking; equal representations may share specialized instances afterward.
Publish this reviewed revision separately before production edits.

The earlier P+F candidate is recovered from Git snapshot
`2ae6555e8960adef4ad8a27ddd0403ca29d6edfd`, parent `fec864e1`. Its 40 paths
and historical functional evidence are reference material, not current acceptance.
The recovered patch is not byte-identical to historical patch `66d59353`;
no exact historical-postimage equivalence is claimed. Primary-checkout ignored
receipts live under `build/bootstrap-evidence/opaque-current-recovery-2026-10-18/`.
Old preparation cost failures and unmeasured FEATURE work remain historical.

The old SemanticRef/key-preparation requirement is withdrawn, not implemented
or declared accepted. No current executable counterexample requires opaque
identity after checking: generic bodies use rigid types, call/runtime operations
and named callback targets are already resolved, and there is no later
opaque-sensitive dispatch. InstanceKey, RecordKey, UnionKey, partial keys and
KnownCallable argument types remain unchanged. Ordinary declaration identities
and ordered callable choices remain authoritative; unrelated record, union or
function declarations must not be structurally merged.

Admit nongeneric ordinary opaques over already supported representations,
including scalar/Void, String, List, fixed records and independently recursive
aggregates. The current 41-module source contains 36 opaque declarations.
No generic opaques, opaque constants, inherited representation methods, new
recursive families, runtime wrappers/ABI, lambda/capture support, source-body
migration, caches, registries, new pipeline or benchmark framework is included.

## First path and the erasure boundary

Recovered two-file witness `fixtures/opaque/int/id.brp`:

```blorp
opaque type Id = Int
pure func make(value: Int) -> Id:
    into_opaque Id(value)
pure func number(value: Id) -> Int:
    from_opaque Id(value)
```

Its `main.brp` imports Id/make/number and returns `number(make(7))`: exit 7,
empty stdout/stderr through the existing real-main harness. Current source-matched
pilot `437c7a9e...` rejects id.brp at 1:13, Id bytes [12,14), with no C:
`opaque types are not supported yet`; help `declare a fixed record with one
field; opaque types arrive with the recursive-types milestone`.
Root's `baseline-red/RECEIPT.json` preserves this CLI RED; the owning TestSuite
must independently establish its preimplementation failure.

Keep OpaqueId in Checked.TypeRef and explicit checked wrap/unwrap nodes.
Checking rejects A where B or Int is required even inside their defining module.
After those checks, specialize the existing runtime representation. For example:

```blorp
opaque type A = Int
opaque type B = Int
pure func identity[T](value: T) -> T:
    value
```

`identity(make_a(7))`, `identity(make_b(9))` and `identity(11)` may reuse the
same Int instance. Box[A], Box[B] and Box[Int] may share the layout of the
same Box declaration. Two different resolved callback FunctionIds still select
their different behavior through existing KnownCallable keys. No semantic
specialization key or duplicate semantic/runtime argument vector is needed.

Current `src/specialize/specialize.brp:1737` starts preparation as follows:

```blorp
private pure func prepare_type(
    value: Checked.TypeRef,
    substitution: List[TypeSubstitution[PartialType]],
    checked: Checked.CheckedFunctions,
    unions: List[UnionSlot],
    span: Span,
    records: List[RecordSlot],
    in_progress: List[InProgressLayout],
) -> Result[PreparedType, Diagnostic]:
    match value:
        Checked.PureCallableType(_, _):
            Err(invalid(span, "callable type reached a data layout"))
        Checked.VoidType:
            Ok({ value_type = KnownType(VoidType), unions = unions, records = records, in_progress = in_progress })
```

Add the direct projection case, using the accepted OpaqueId-indexed table:

```blorp
        Checked.OpaqueType(id):
            match opaque_underlying_type(id, checked.opaques, span):
                Err(error): Err(error)
                Ok(underlying):
                    prepare_type(underlying, [], checked, unions, span, records, in_progress)
```

The nongeneric representation is closed; it must not inherit the caller's type
substitution. `concrete_type` similarly projects using sealed opaque rows threaded
through its existing translation callers. Do not add an erase pipeline or a
context carrier merely to hide parameter changes. Existing layout demands,
reservation/sealing order, backreferences and concrete representation remain.
Translate wrap/unwrap's child exactly once and erase the node. Preserve its outer
occurrence span independently of inner call-callee spans. Concrete types/forms
contain no opaque case; Lower/Own/Verify/Emit production stays unchanged.

## Facts and checking

Assembly issues OpaqueId through the existing DeclarationInventory and source-order
nominal merge; remove the duplicate unnumbered ParsedContents.opaques vector.
Namespace publishes OpaqueHead and existing visibility/import facts. Checker
rows publish the accepted underlying TypeUse, once per OpaqueId.

Conversion lookup resolves the name and opaque kind, then checks permission
against the original defining ModuleId, before inspecting the operand. Importing
an opaque grants no wrap/unwrap permission. Underlying private types are legal
inside a public opaque; public signatures still cannot expose private opaque
names. Bare conversion type names suffice; qualified ordinary type references
retain existing namespace behavior. Give wrap operands their checked underlying
expectation, including contextual record/constructor expressions.

Update checked type equality, inference, type-head and ordinary type observers
nominally. OpaqueType is an atomic, nongeneric type; it neither equals its
representation nor introduces caller type-parameter dependencies. Call, value
and recursion observers visit conversion operands once, including nested calls.
Recursive-instantiation checking still runs before specialization and consumes
resolved identities. Conversions cannot hide forbidden recursion or create a
new tail-call allowance.

Reuse the candidate's bounded representation-cycle validation: follow each fixed
opaque target through representation fields, Lists and substituted aggregate
arguments with fresh target-local visits. Reject opaque reentry before completing
it, including phantom argument demand; preserve independently recursive aggregates.
Do not widen current recursive admission or introduce generic opaque resolution.
All declarations, unused included, are validated in existing phase order.

| Rejection | Exact message / help | Primary span |
| --- | --- | --- |
| Missing name | `unknown opaque type` / `import or declare an opaque type before converting it` | conversion type name |
| Nonopaque name | `type is not opaque` / `use into_opaque or from_opaque only with a declared opaque type` | type name |
| Foreign wrap | `opaque values can be constructed only in their declaring module` / `call a public constructor from the declaring module` | type name |
| Foreign unwrap | `opaque values can be projected only in their declaring module` / `call a public accessor from the declaring module` | type name |
| Wrong wrap operand | `opaque construction value has the wrong type` / `pass the declared underlying type to into_opaque` | full operand |
| Wrong unwrap operand | `opaque projection value has the wrong type` / `pass a value of the named opaque type to from_opaque` | full operand |
| Representation cycle | `recursive opaque representations are not supported yet` / `wrap an independently recursive aggregate instead of referring back to the opaque type` | first closing written type use |

Assert error kind, message, help, SourceId, full start/end and no note. Operand
name/field errors precede outer mismatch; denied access precedes operand errors.

## Delivery, tests and bounded acceptance

Reuse front-end candidate/tests selectively; do not port SemanticRef preparation,
its private phase benchmark or tests demanding distinct erased opaque instances.
The old pure-Void distinction is superseded by current pure-Void acceptance.
Retain ordinary nominal/generic/recursive tests wherever declaration identity
still matters. All new embedded programs use aligned multiline literals.

1. Establish owning check/specialize TestSuite RED and real-main CLI RED first.
2. Issue nominal rows, check access/types/conversions, project directly and obtain
   the two-file Int witness. Freeze this complete path for early review/cost.
3. Cover scalar/Void, numeric fixed records, private managed String records, List
   and independently recursive products; read generated C for erasure and normal
   acquisition/retirement. Test alias escape, ignored results, replacement, repeated
   children, final/nonfinal drops and constrained-stack destruction controls.
4. Add checker rejection for equal-representation A/B mixing; specialization
   assertions for lawful A/B/Int function and same-declaration aggregate reuse;
   two different named callback targets must remain observably different.
   Inspect checked conversion spans/children and inner call type arguments.
5. Kill and restore bounded faults: missing nominal check, missing module access,
   dropped/duplicated operand evaluation, lost managed acquire and wrong/duplicate
   child release. Use existing public phase/runtime boundaries, no test hooks.
6. Run owning phase/runtime suites, full components and full normal native gate
   with required instruction checks, strict zero accounting, O0 ASan/UBSan and
   existing caps. Build the candidate pilot once, not per fixture. Reprobe actual
   compiler source and retain its next diagnostic; do not claim self-compilation.

Freeze every current fixture `.brp` for exhaustive B/C normal CLI identity, two
calls per input, comparing status, stdout, stderr, C presence and successful C
bytes. Preserve all inputs, including support modules run as roots. Exactly five
existing inputs under fixtures/unsupported change intentionally, without byte edits:
opaque_type.brp and opaque_import/main.brp become exit-0 ordinary C; into_opaque.brp
and from_opaque.brp reject unknown opaque name at 3:14 with the table's help;
opaque_import/m.brp as a root reaches existing MissingMain instead of unsupported
opaque. Pin its exact existing end-span/message/help before accepting comparison.
All other differences stop acceptance; never normalize C or diagnostics.

## Physical budget and resource contract

Point production forecast is 633 ADD / 201 DEL / +432 net across 16 existing
modules: ids80/20, syntax2/2, assemble5/8, namespace25/8, declarations160/60,
errors20/8, model30/5, inference20/5, expressions100/20, constructors5/2,
callables8/3, bodies10/3, check8/8, recursion10/2, render40/12, specialize110/35.
Hard limits are 750 production ADD and +500 net; assessment stop at 650 ADD
or +450 net. No preparation budget stacks on top. Tests forecast 1,600–1,750
ADD, hard 1,900, assessment at 1,750; fixtures separately forecast 203 lines,
hard 250. Stop before a breach; do not compress formatting or remove necessary
coverage. User-facing README/GUIDE/GRAMMAR update with implementation.

Fixed accepted B is dcd8beb0af83f156ad0c482b2fd3235ba72bb8dc; C is this complete
direct feature plus all tests. Before setup, root freezes source/library/corpus,
physical paths, toolchain and roles. Available functional host is root FRESH
97479b34..., normal/diagnostic measurement pair6852e1c6.../a362b0df..., explicit
root standard_library/src (91 files). Verify actual identities, never just labels.
The frozen-host source-to-C construction proxy must pass independently +3%
allocations and normal min3 instructions against B. Allocation means one schema-1
artifact_construction_complete checkpoint; strict totals are not a substitute.
This prospectively tighter direct-F epoch accepts no old P hold or failed sample.
The named/lambda cumulative 8% exception does not apply to opaque.

FEATURE controls, paths relative to test/e2e/fixtures, are exactly:
call/one.brp; nested/order.brp; generic/identity.brp; generic/phantom.brp;
record/generic/same_reader_twice.brp; generic/union_identity.brp;
generic/named/identity.brp; generic/named/ordered.brp; generic/named/managed.brp;
generic/managed/shared_box.brp; recursive/tree.brp; recursive/shared.brp.
Each gets matched B/C allocations and three original serial alternating normal
pairs, using the same physical input/library path and frozen producer variants.
Each must meet +5% target/+10% hard for both metrics independently, all tighter
existing absolute caps, strict zero leaks and exact output identity. Report a
missed target even below hard. No per-input baseline roll or retry selection.

New opaque Int/key/scalar roots retain 35k allocations/140M normal instructions;
inline record45k/180M, managed String55k/220M, List60k/240M, recursive product75k/300M.
The two newly accepted old roots use35k/140M each. New/changed inputs have no
successful B denominator; use prospective absolutes and exact outcomes. Match
strict/compiler accounting separately from normal instruction samples, retaining
existing harness diagnostic bounds; no instruction disabling or fixture-cap change.
No new phase/scaling runner is needed because the removed preparation mechanism
is absent. Preserve historical evidence and report all current measured costs.

Stop on changed old demand/order, source-parse regression, unresolved identity or
access, new runtime wrapper/ABI, host defect, counter/identity failure, resource
breach or insufficient destruction margin. Root plus independent architecture/code
and test-runner review precede commit. Root alone integrates/pushes; no green
functional gate waives a resource failure. Preserve all raw evidence under ignored
build/, return exact source/test/fixture counts, hashes, RED/GREEN, mutations,
C review, resource/identity receipts and honest limits.
