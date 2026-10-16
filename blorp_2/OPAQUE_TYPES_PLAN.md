# Ordinary opaque types without runtime wrappers

## Problem, authority and scope

Design-reviewed; implementation unstarted. Source baseline:
`c02a9efdc25e358e5620f0ef3c5404765f5b0d38`. Root and independent OS/API and
compiler reviewers approved the staged design. Plan publication must precede
root authorization for key preparation alone; feature work remains unauthorized.
[M4](ROADMAP.md#m4-recursive-types) and the [source plan](BOOTSTRAP_SOURCE_PLAN.md#retained-recursive-types) own scope.
Parsing exists (`src/parse/parse.brp:1279,3478`); assembly retains unnumbered syntax
(`src/parse/assemble.brp:56`); `src/check/declarations.brp:376` rejects opaques before
namespace construction; conversion checking also rejects. Later anchors are src-relative.

Current source has 34 nongeneric opaques: 14 over Int, five over numeric fixed
records, fourteen over other fixed records, and `Namespace = List[ModuleScope]`.
The Int group is ModuleId/SourceId/NameId, FunctionId/UnionId/RecordId/ConstantId,
InferenceVariableId/BindingId/ValueId/OwnerId and the three *InstanceId ordinals.
The inline-record group is FieldId/VariantId/FieldInstanceId/VariantInstanceId/
VariantFieldInstanceId. Other records are TypeParameterId, LocalBinding,
LibraryLayout, ListElementKey, NameTable, DeclarationInventory, ParsedAssembly,
ParsedProgram, ParsedModule, CheckedProgram, CheckFailure, SpecializedProgram,
LoweredProgram and VerifiedProgram. Confirm inline/managed classification in C.
LibraryLayout/NameTable hold Strings; program wrappers hold recursive products.
Private String/Char wrappers remain deferred to the separate UTF-8 work.

Out: opaque constants, generic opaque declarations, new recursion families,
FFI, inherited representation methods, runtime wrapper objects, new ownership
operations, caches/catalogues and the separately owned carried-binding/UTF-8 work.

## First executable path and negative examples

Proposed `test/e2e/fixtures/opaque/int/id.brp`:

```blorp
opaque type Id = Int
pure func make(value: Int) -> Id:
    into_opaque Id(value)
pure func number(value: Id) -> Int:
    from_opaque Id(value)
```

Companion `main.brp`, expected exit 7 and empty stdout/stderr:

```blorp
import:
    ./id: Id, make, number
func main() -> Int:
    number(make(7))
```

Baseline rejection is in id.brp at `Id`, bytes [12,14), line1:13:
`opaque types are not supported yet`; help `declare a fixed record with one
field; opaque types arrive with the recursive-types milestone`. Establish the
red through the normal e2e harness before implementation.
In separate callers importing Id, `into_opaque Id(7)` and
`from_opaque Id(make(7))` must fail access checks. `number(7)` must remain a
nominal type error. Public signatures and passing/storing Id remain legal.
Inference uses supported calls: `identity(make(7))`, where
`pure func identity[T](value: T) -> T: value`; never `identity[Id](...)`.

## Chosen semantic-key boundary

Current InstanceKey (`specialize/specialize.brp:405`) stores FunctionId and
List[TypeRef] runtime arguments. `prepare_function:1912` projects arguments
through prepare_type/known_type before keying; RecordKey, UnionKey and partial
keys share the coupling (:62,790,814). Adding only OpaqueType-to-IntType would
merge distinct semantic instances.

| Candidate | Decision |
| --- | --- |
| Fully substituted Checked.TypeUse | Spans describe occurrences, not identity; its TypeRef still permits rigid ParameterType. Strip spans and establish closedness rather than making every comparison rediscover it. |
| Small private closed SemanticRef | Choose this: the existing nominal declaration IDs plus ordered closed arguments; no ParameterType constructor, no new identity table. |
| Checked-semantic/runtime argument row | Different facts, but retaining both per argument adds coupling and retained data before repeated projection justifies it. Do not introduce this cache by default. |

Proposed private specialization data (OpaqueRef joins only in the feature):

```blorp
private fixed union SemanticRef:
    PrimitiveRef(Builtins.PrimitiveType)
    ListRef(SemanticRef)
    RecordRef(Declaration.RecordId, List[SemanticRef])
    UnionRef(Declaration.UnionId, List[SemanticRef])
    OpaqueRef(Declaration.OpaqueId)
-- InstanceKey, RecordKey, UnionKey: arguments: List[SemanticRef]
-- PendingUnionType/PendingRecordType refer to those same nominal keys.
```

Close checked references with TypeSubstitution[SemanticRef]: simultaneous, terminal
replacement of rigid parameters. Compare complete structural refs, including phantom
and empty arguments. Never expand representations for equality or add a catalogue/ID.

Preserve order: close the key, request argument layouts left-to-right at existing
demand sites, enter/reserve the parent at its existing point, then expand stored
children in existing order. Key construction reserves no layout; existing local
builders, backreferences, postorder IDs and complete sealing remain authoritative.
PartialType remains a runtime-field construction state; pending fields name
semantic keys. Remove replaced partial-key arguments/comparisons in preparation.

Runtime projection consumes SemanticRef and accepted declarations using existing
union/record tables. OpaqueRef projects its checked underlying type only after its
enclosing key is constructed; it may demand layouts but never replaces key arguments.
During translation, specialize expressions/signatures/bindings and erase checked
wrap/unwrap forms to their one projected operand. Keep occurrence spans and
call-callee spans distinct. Concrete TypeRef/forms contain no opaque case.
The lower/own/verifier/backend products and runtime ownership ABI remain unchanged.

## Facts, access and construction

| Fact | Producer/owner, lifetime | Consumers |
| --- | --- | --- |
| OpaqueId and defining module/visibility | Assembly's existing DeclarationInventory; one compilation | Namespace and checking; no second raw opaque vector in sealed ParsedContents |
| OpaqueHead(OpaqueId), visible names | Existing namespace entries/import rules; parsed program lifetime | Type resolution, receiver selection and conversion name lookup |
| Checked underlying TypeUse | Declaration checker, complete OpaqueId-indexed rows | Contextual conversion typing, finite validation and specialization |
| Wrap/unwrap permission and operand type | Checker, checked conversion forms carrying OpaqueId and child | Specialization consumes the established fact; no later name/access lookup |
| Closed semantic arguments | Specializer's local keys; reservation through translation | Equality, requests, substitutions, existing instance lookup |
| Concrete storage and ownership | Existing complete layout products | Lower/own/independent raw verifier/emit |

Add OpaqueRow issuance to utils/ids.brp's existing inventory and source-order
nominal merge; remove ParsedContents.opaques after migration. Namespace extends
TypeHead/same_head/selection/privacy, never spelling-based identity. Conversion
permission compares ResolutionContext.module with the original row's module,
not import Origin or a module alias's spelling. Opaque types are public when
declared public; importing one grants neither wrap nor unwrap permission.
The inventory owns module authority; checked rows own accepted underlying types.

Add Checked.TypeRef.OpaqueType(OpaqueId) to equality/inference/type-head handling.
It is nominal even inside the defining module. No implicit Int conversion or
inherited Int UFCS. A public opaque may hide a private representation: check its
underlying annotation in defining-module/private-type access, while public
signatures mentioning a private opaque still obey existing privacy rejection.
Keep bare conversion names; functions on opaque receivers retain ordinary UFCS.

For `into_opaque FieldId({ owner = owner, position = 0 })`, give the expression
workloop the checked underlying record as child expectation. Publish explicit checked
wrap/unwrap forms; resolve name/permission once before scheduling the operand.
`from_opaque FieldId(id).position` uses normal field projection; `id.position` cannot
pierce the boundary. Evaluate once. Erasing a managed borrow preserves ordinary
acquire-on-escape; disappearing opaque syntax grants no owned result.

Check all declarations, unused included, before bodies. Extend finite validation
with fixed-target opaque reachability: fresh local visits/completions per target,
keyed by nominal ID plus ordered substituted arguments. Follow fields, Lists,
representations and all argument-layout demands. Terminate ordinary aggregate
revisits; reject target reentry before completion reuse. `opaque type A = Phantom[A]`
may have finite stored layout, but this increment rejects its recursive projection
demand. Defer opaque-mediated/alias-only cycles; allow wrappers around independently
recursive aggregates. Never share facts between opaque targets.

## Diagnostics and priority

Preserve check_program's phase/error order, including finite declarations,
constants, signatures, receiver clashes, bodies and recursive instantiation.
Within a conversion: resolve name/kind, check defining-module permission, then
check its operand; a forbidden conversion must not expose representation typing.
Typed errors carry identity and expected/actual types; use the owning SourceId, no note.

| Case | Exact message / help | Span |
| --- | --- | --- |
| Missing name | `unknown opaque type` / `import or declare an opaque type before converting it` | conversion's type-name token |
| Existing nonopaque head | `type is not opaque` / `use into_opaque or from_opaque only with a declared opaque type` | same token |
| Foreign wrap | `opaque values can be constructed only in their declaring module` / `call a public constructor from the declaring module` | same token |
| Foreign unwrap | `opaque values can be projected only in their declaring module` / `call a public accessor from the declaring module` | same token |
| Wrap operand mismatch | `opaque construction value has the wrong type` / `pass the declared underlying type to into_opaque` | complete operand expression |
| Unwrap operand mismatch | `opaque projection value has the wrong type` / `pass a value of the named opaque type to from_opaque` | complete operand expression |
| Representation cycle | `recursive opaque representations are not supported yet` / `wrap an independently recursive aggregate instead of referring back to the opaque type` | first closing written type use in source-root/field order |

Operand name/record-field errors precede outer mismatch; new expected-type sites
select it after child checking. Keep existing nominal/privacy diagnostics intact.

## Delivery, tests and acceptance

1. **Key preparation alone:** four SemanticRef variants, no opaque admission.
   Existing accepted/rejected outcomes, diagnostics, C, demand order and IDs are
   identical. Direct specialize tests cover function/record/union/phantom keys,
   simultaneous substitution and pending reservation/sealing in both entry orders.
2. **Two-file Int path:** introduce issuance/access/checked forms and OpaqueRef;
   establish the red above, then exit 7. Test two Int-backed opaques through
   inferred identity calls and typed phantom-union consumers: distinct semantic
   instances despite identical runtime fields; equal keys reuse one complete row.
3. **Witnessed representations:** private numeric record; managed record holding
   String; Namespace-like List; program record holding an existing recursive tree.
   Test contextual construction, explicit projections, aliases, stored/returned
   escape, repeated children, final/nonfinal releases and fresh-root snapshots.

Inside the declaring module, test `into_opaque Id(identity(7))` and
`from_opaque Id(identity(make(7)))`. For new checked conversion forms, call/type/
recursion observers traverse the operand exactly once and preserve every inner
generic call's type arguments and recursion facts. Assert the outer conversion's
occurrence span separately from each inner call's callee span; neither replaces
the other. Include nested calls so observing only the immediate child fails.

Add named direct TestSuite callbacks under test/unit/test_{parse,namespace,check,
specialize,lower,own,verify,emit}/test_opaque_types.brp as appropriate; use sealed
IDs from their issuer, with separate malformed raw ownership inputs. Test every
diagnostic's kind/message/help/SourceId/start/end/note, competing errors, unused
bad declarations, privacy, qualified type references and opaque/underlying UFCS.
Runtime tests use production fragments and actual lifetimes under the approved
C-helper exception; e2e executes only unmodified C's real main.
Kill bounded mutants: representation-based key equality, missing access check,
lost operand evaluation, omitted acquire, wrong/duplicate child drop. No framework.

After creating these suites, the narrow loop and gates (FRESH host) are:
```bash
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_opaque_types.brp blorp_2/test/unit/test_specialize/test_opaque_types.brp
make -C blorp_2 test-compiler
make -C blorp_2 test-e2e
make -C blorp_2 test
scripts/blorp2-fixpoint --frontier
```
Run remaining phase/runtime suites before e2e; retain O0 sanitizers/leak checks
and constrained-stack release controls for admitted recursive shapes.
Migrate unsupported/opaque_type and opaque_import inputs unchanged to acceptance
(exit 0); into_opaque/from_opaque fixtures retain their bytes and become exact
unknown-opaque-name rejections. Enumerate these four outcome/diagnostic changes;
do not compare old rejection costs with new successful compilation costs.

## Cost boundaries, risks and handback

Physical estimates before code: preparation 450–750 added/+120–240 net production,
300–500 test lines; Int feature 400–650 added/+180–300 net, 450–700 tests;
managed witnesses 200–350 added/+100–200 net, 500–800 tests. Hard per-slice
production limits: 800/+250, 700/+350, 400/+250; independent cumulative hard cap
1,900 added/+800 net (the +850 slice sum cannot stack). Tests: cumulative hard 2,200;
fixtures separately estimate 180–300 lines, hard 400.
Do not compress, delete coverage or stack allowances; review breaches first.

Matched per-input allocation/instruction ceiling: preparation +3%; features +5%
target/+10% hard, existing fixture limits unchanged. New accepted absolute limits
(allocations/normal retired instructions): each Int/key fixture 35k/140M;
inline-record 45k/180M; managed-String 55k/220M; List 60k/240M;
recursive-product 75k/300M. These are proposed caps, not measurements.
Limit fixtures to small, explicit observations.
Freeze source/binary/library/toolchain, three serial alternating normal pairs,
strict counters/leaks separately, one physical input path; retain raw samples.
Report phase/whole costs plus host source-to-C as a self-compile proxy;
compare unchanged fixture C/diagnostics. No speedup is claimed.
Semantic closure and projection can add walks/allocations; compare structural
key depth and repeated projection at N=16/32/64/128. Existing linear key scans
cost requests × candidate keys × compared structure, not constant-time lookup.
Reuse existing aggregate IDs/tables for representation queries and opaque row
ordinals for underlying lookup; no retained projection cache is authorized.

Stop for cap breach, changed old demand order, unresolved key closedness,
representation used as identity, hidden scope growth/new recursive admission,
runtime wrapper, host defect or insufficient measured release margin. Report
the smallest failing case to root; never add a fallback or waive an oracle.
Hand back source/test/fixture counts, exact hashes, per-boundary red/green and
mutation receipts, unchanged corpus identity, costs and unverified limits.
Independent code/test review precedes integration. Review: is closed SemanticRef
worth its measured cost; does fixed-target cycle rejection bound the witnessed
scope; do caps leave examples meaningful? Reopen decisions before widening.

## Primary references

[OCaml abstract module types](https://ocaml.org/manual/5.3/moduleexamples.html)
hide representations behind typed operations; functors/generativity are outside scope.
[Rust newtypes](https://doc.rust-lang.org/book/ch20-03-advanced-types.html#type-safety-and-abstraction-with-the-newtype-pattern)
motivate nominal separation; [private fields](https://doc.rust-lang.org/book/ch07-03-paths-for-referring-to-an-item-in-the-module-tree.html#making-structs-and-enums-public) illustrate controlled construction.
Blorp's exact declaring-module rule and ARC erasure are our choices, tested above.
