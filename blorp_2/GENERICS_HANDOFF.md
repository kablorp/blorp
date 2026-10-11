# Own finite generic union payloads explicitly

This is the approved and implemented step-6 handoff. Strict phase/full pilot,
native, mutation, matched-cost and independent source/evidence reviews pass.
The [increment report](../benchmarks/results/blorp_2_managed_union_payloads_2026-10-11.md)
records the supported subset, final evidence and separate host limitations.
The previous handoff is preserved under ignored
`build/managed-union/baseline/GENERICS_HANDOFF.md`; the coordinator froze the
immediate baseline pilot sources under `build/managed-union/baseline/src/`.
Read both applicable AGENTS files, [GENERICS_PLAN.md](GENERICS_PLAN.md), and
the relevant contracts in [MEMORY_PLAN.md](MEMORY_PLAN.md).

## Problem

The preserved step-5 baseline admits finite unmanaged nested union payloads but
rejects a String child. Start with this real source fixture:

```blorp
fixed union Box[T]:
    Box(T)
pure func box[T](value: T) -> Box[T]:
    Box(value)
pure func unbox[T](value: Box[T]) -> T:
    match value:
        Box(payload): payload
func main() -> Int:
    unbox(box(42.to_string())).length()
```

After building the pilot once, the direct reproduction is:

```sh
blorp_2/build/compiler blorp_2/src/prelude_temp.brp \
  blorp_2/test/e2e/fixtures/generic/managed/basic.brp \
  blorp_2/build/managed-union/basic.c
```

The recorded first red reports `specialized union payload must be unmanaged`,
help `use Int, an inline record, or an unmanaged union; String payloads are not
supported`, span 183..186 and payload-declaration note 25..26. Its stable receipt
is `build/managed-union/first-red/`; no tracked test retains String rejection.
Afterward,
unmodified emitted C must run its real `main`, exit 2, and print nothing.

The next fixture keeps the declarations and replaces main with:

```blorp
func main() -> Int:
    var current = box(42.to_string())
    saved = unbox(current)
    current = box(7.to_string())
    saved.length()
```

It exits 2. A companion returns `unbox(current).length()` and exits 1. Finite
nested String-bearing unions must compose through the same representation;
recursive declarations remain excluded.

## Background: identity, authority and lifetime

| Boundary | Authority and lifetime | Consumer guarantee |
| --- | --- | --- |
| Checking | Declaration-owned rigid types, constructor/pattern identities, function-local BindingIds and complete call substitutions; checked compilation lifetime | No ownership inference or spelling recovery downstream |
| Specialization | Declaration plus all ordered concrete arguments; complete ConcreteUnion variant payload inventory; concrete compilation lifetime | No unresolved parameters; child inline layouts precede parents |
| Lowering | Function-local ValueId and exact PayloadValue(VariantInstanceId, ValueId); lowered body revision | Source rebinding changes the current mapping, never an existing value identity |
| Ownership | Function-local OwnerId obligations and definition-local ResultOwnership; owned body revision | Creation, borrow, acquisition, child transfer, return and drop are explicit |
| Verification | Accepted per-value provenance and active owner state, private to one verification run | Actual final operations and all layouts checked independently |
| Emission/runtime | VerifiedProgram seal; concrete layout identities projected into C | Emission adds no ownership decision; String runtime alone frees String roots |

Equal ordinals across authorities are not identity. All catalog IDs belong to
this compilation. No shared cache, hidden input or new pipeline layer is needed.
Builders stay local; published products are immutable. Pipeline work stays pure
after source/configuration loading.

The design uses the root/child distinction and Perceus guidance already recorded
in MEMORY_PLAN: ownership placement, runtime ARC and allocation reuse are separate.
The existing synchronous ABI borrows parameters and returns owned managed values.

## Proposed solution

Keep tagged union storage inline, including Box[String]. The inline value owns
its active child obligations and has no separately allocated or counted root.
String remains the existing managed leaf. Copying an owning inline value dupes
only its active child; dropping it drops only that child. No helper frees inline
aggregate storage.

An InlineOwningPayload layout gives every constructed value one aggregate
obligation, including a nullary or unmanaged active variant. Its helpers do no
child work for that tag. Handle and directly test VariantDefinition explicitly;
do not classify the whole layout from the currently selected variant.

Specialization derives one typed representation summary from every variant and
already-published child layout. ConcreteUnion remains the sole complete payload
inventory. No per-value managed flag or parallel owned-field inventory is added.
The verifier independently recomputes the summary and rejects disagreement,
missing layouts, invalid identities and forward/self layout references.

Projection borrowing names one immediate immutable parent ValueId. The parent's
accepted ResultOwnership supplies the next ancestry edge. Do not embed copied
parent BorrowedValue/source trees. Validate each dependency against the exact
PayloadDefinition source and selected arm, then validate ancestry. Definition
before use prevents forward and cyclic dependency graphs; malformed raw graphs
must reject. A saved extracted result acquires an independent owner before return
and therefore survives discharge of the caller's original Box obligation.

Permit verified borrowed or unmanaged prefix definitions before a tail match.
Do not gate this on ParameterDefinition syntax: the accepted obligation is the
relevant fact. Keep selected-arm projection validation and the owned-prefix
restriction, including an owned prefix value already dropped. Nested borrowed
paths may compose only within currently supported/verified control-flow shapes;
this is not permission for nested or non-tail matches or joins.

Do not admit source owned-parent projections without transitive borrow-use
scheduling: direct last-use rows do not extend parent lifetime through children.
The raw verifier may validate an owned parent while its exact obligation remains
active and must reject the dependency after discharge. It must not impose an
arbitrary parameter-only ancestry rule on otherwise valid raw operations.

## Code

Preserved baseline layout (`baseline/src/specialize.brp`):

```blorp
fixed record ConcreteUnion {
    variants: List[Option[TypeRef]]
}
```

Implemented replacement (`src/specialize.brp:54`):

```blorp
fixed union UnionRepresentation:
    InlineUnmanaged
    InlineOwningPayload

fixed record ConcreteUnion {
    variants: List[Option[TypeRef]],
    representation: UnionRepresentation
}
```

`ensure_union` publishes the summary once, bottom-up. Root storage is always
inline for this family; the variant distinguishes its child obligation. The
ownership query becomes an O(1) view referring back to this layout:

```blorp
fixed union ValueOwnership:
    NoOwnership
    ManagedStringLeaf
    InlineOwnedFields(UnionInstanceId)
```

Preserved baseline borrowing and construction (`baseline/src/own.brp`):

```blorp
fixed union BorrowSource:
    ParameterBorrow(ValueId)
    OwnerBorrow(OwnerId)
fixed union ResultOwnership:
    UnmanagedResult
    BorrowedResult
    OwnedResult(OwnerId)
-- OwnedValueOperation contains:
ConstructDefinition(VariantInstanceId, ValueId)
```

Implemented replacements (`src/own.brp:59,76,82`), preserving the borrowed call ABI:

```blorp
fixed union BorrowSource:
    ParameterBorrow(ValueId)
    OwnerBorrow(OwnerId)
    PayloadBorrow(ValueId)
fixed union ResultOwnership:
    UnmanagedResult
    BorrowedResult(BorrowSource)
    OwnedResult(OwnerId)
fixed union StoredPayload:
    UnmanagedPayload(ValueId)
    OwnedPayload(ValueId, OwnerId)
-- Revised OwnedValueOperation member:
ConstructDefinition(VariantInstanceId, StoredPayload)
```

The inserter's private per-value sources reuse ResultOwnership directly; no
isomorphic source union or duplicate BuiltDefinition source field remains.
The verifier's existing per-value state retains accepted ResultOwnership only
after independent operation/type/provenance validation. Neither builds a second
borrow registry. PayloadDefinition already carries selected variant and source;
lower's PayloadValue at `src/lower.brp:58` needs no parallel carrier.

Definition classification (`src/own.brp:474`) now handles borrowed parameters,
owned calls/constructors/variants and borrowed projections.
A borrowed child follows this explicit sequence:

```text
define v0: borrowed String parameter
acquire o0 from v0
define v1 = Box(OwnedPayload(v0,o0)), result OwnedResult(o1)
return v1, transferring o1
```

Construction discharges o0 into the aggregate's lifetime and introduces o1.
Missing or repeated child transfer rejects independently. For an owned child at
its final use, reuse its owner directly. Existing last-use rows
(`src/own.brp:412`) already answer that question. Decide transfer versus acquire
while building the current constructor. When draining the current position's
local drop bucket, omit precisely the owner that this constructor consumes.
Do not patch prior operations or rewrite previously published analysis rows.
If the child has later uses, acquire a separate child obligation and preserve
the original scheduled discharge. Calls keep their existing transfer model.

The baseline aliases/drop emission hardcodes String pointers and String
retain/release. A disposable function-local owner-type projection now selects
typed aliases and physical dup/drop. Its value-type builder remains private and
only owner types escape to emission. It traverses all accepted blocks once in
global value order, then is discarded. This is no published ownership analysis.
Child-first layouts emit their helpers immediately, without a second helper loop.

Generate dependency-first per-layout helpers from the complete variant inventory:

```c
struct blorp_u_0 {
    enum blorp_tag_0 tag;
    union { struct blorp_string *blorp_up_0; } payload;
};
void blorp_union_drop_0(struct blorp_u_0 value) {
    switch (value.tag) {
    case blorp_v_0_0:
        blorp_string_release(value.payload.blorp_up_0);
        break;
    }
}
```

Dup uses retain. Nested owning children call their earlier helpers; unmanaged
and empty variants perform no ownership work. Acquiring a returned payload
occurs inside the selected arm before its return transfer.

## Scope and non-goals

Own pilot specialization, ownership, verification, emission and matching unit,
runtime and real-main e2e tests; lower should need little production change.
Update README and both plans with the final supported ownership rules. Keep one
representation path. No recursive declarations, heap aggregate roots, managed
record fields, COW, contextual inference, general SSA/joins, diagnostics framework,
test controller, cache, production tracing or generated-helper native drivers.

## Dependencies, risks and stop conditions

The coordinator separately repaired the host Perceus temporary-projection defect.
A second bounded host defect was reproduced: the valid `Ok(match ... Some:
concat(output,name); None: output)` shape loses the consumed input's Some-arm
drop. The minimal real-main reproduction leaks one mortal String in strict mode;
anchors and hashes are retained under `build/managed-union/host-string-branch/`.
The host expert repaired it; FRESH host SHA starts `4dd4a29a428d7fa8`, and the
82 managed phase callbacks pass strict development validation. Keep the valid
pilot form rather than flattening it. Pilot gates use the coordinator's compiled
lane; baseline and candidate must be rebuilt with this same repaired FRESH host.

Finite child traversal composes without a depth heuristic. Runtime helper depth
is bounded by the finite concrete layout; recursive data still needs a separate
bounded-stack destruction design. Report any host defect instead of changing
pilot tests to mask it. Stop for a broader control-flow requirement, hidden
ownership work or the agreed cost/LOC investigation threshold.

## Testing

Use named Blorp TestSuite callbacks with direct typed inputs, not whole-pipeline
tests for every phase. Start with the failing source example, then:

1. Specialization: String/nested/heterogeneous layouts; phantom String stays
   unmanaged; nominal distinction; child-first complete classification.
2. Lowering: exact selected variant, source and type; old/replacement ValueIds;
   evaluation once in source order.
3. Uses/insertion: constructor child last use; final-use transfer without drop;
   later reuse acquires independently; borrowed projection ancestry; independent
   returned-child owner; copy/unused/drop; selected-arm acquisition and transfer.
   Nullary and unmanaged active variants of an owning layout retain the uniform
   obligation; VariantDefinition has its own named direct callback.
4. Independent raw verifier: missing acquisition/child transfer; duplicate child
   transfer; wrong owner/value/type; discharged parent; wrong projection parent
   or variant; inactive projection/acquisition; missing return acquisition; leak,
   double drop, sibling escape; wrong representation and invalid unused layouts;
   managed self-tail-loop signatures/intermediates; forward/cyclic borrow edges.
5. Emission: independently expected small complete C bodies for typed aliases,
   construction, extraction, active-only dup/drop, nested helper order and
   empty/unmanaged variants. Planner tests start from declared shape separately.
6. Existing direct String-runtime exception: independent child obligations,
   nonfinal release preserving usable bytes, each mortal root freed exactly once.
   No C test may call generated aggregate helpers or bypass fixture main.
7. Real-main fixtures: basic, saved/current, surviving shared Box, both managed
   variants, String/Int branches, unused aggregate, nested returned child and
   depth-20 nesting. Run unmodified emitted C under existing sanitizer gates.

Deliberately omit child transfer, substitute a sibling projection, mark a String
layout unmanaged, omit active child drop, and touch an inactive payload. Each
mutation must fail its owning unit/native oracle; restore and rerun. Exact raw
verifier failures pin obligation, message and span; source rejections also pin help.

After the repaired host is FRESH, the narrow loop starts with proposed new suites:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_managed_union_specialize.brp \
  blorp_2/test/unit/test_managed_union_lower.brp \
  blorp_2/test/unit/test_managed_union_own.brp \
  blorp_2/test/unit/test_managed_union_verify.brp \
  blorp_2/test/unit/test_managed_union_emit.brp
bin/blorp test --suite --sanitize --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
make -C blorp_2 test
git diff --check
```

The e2e wrapper builds the pilot once at -O0, passes its executable explicitly,
and runs each source fixture's real main. No existing fixture limits increase.

## Acceptance criteria and costs

- First regression fails before implementation and passes afterward; basic/saved
  exit 2 and replacement exits 1, with empty stdout/stderr.
- All affected direct phase, raw verifier, runtime, grammar, e2e and strict full
  unit gates pass; prior host failures are not silently waived.
- Existing fixture costs grow at most 10% aggregate and 15% individually on
  allocations and retired instructions. These are coordinator-approved
  investigation/stop thresholds, not permission to lift existing test limits.
- Ordinary new fixtures use 20,000 allocations/200 million instructions; depth
  20 uses 50,000/200 million. The original 400 net formatted production-line
  investigation threshold stopped expansion at +511. Independent review removed
  the published emission value types, separate helper loop and isomorphic private
  source carrier, converging to the reviewed +474 milestone. The current source
  census is +477: specialization +19, ownership +75, verification +162, emission
  +221 after formatting. Review found the remaining typed transfer,
  independent checks and active-child emission necessary, with no duplicate
  authority/framework. The coordinator explicitly reassessed to at most +500,
  conditional on semantic, strict-leak, mutation and matched-cost gates. Cost caps
  remain unchanged. Report production and test changes separately.
- Freeze source/toolchain/binary/input provenance. Measure three serial matched
  baseline/candidate pairs with the same repaired host. Reuse established
  measurement entrypoints; add no controller. Retain raw samples and C hashes.
- Preserve existing generated C byte-for-byte unless a narrow reviewed emission
  change is necessary. Inspect all changed ownership C and default-toolchain depth.
- Box introduces zero Box heap allocations. Dup/drop traverses only the active
  child path; finite nesting uses helpers rather than expanding all descendants
  at every use. No compilation-speed improvement is claimed without measurement.

Compilation costs remain owned-input proxies, not pilot self-compilation or
target runtime measurements. Target lifetime evidence is reported separately.

## Release strategy and handback

No commit/push is authorized. The coordinator approved implementation after
independent compiler-expert review and arranges final reviewer/test-runner gates.
Keep evidence under ignored build/managed-union/ and
retain a concise results document after validation. Preserve the existing stage-5
baseline and the concurrent host repair.

Return carrier/API changes, phase pass/fail counts, exact commands and receipts,
restored mutation evidence, matched costs/provenance, production/test LOC,
generated-C paths and unresolved limitations. Release the compiled lane before
independent validation. Stop and ask the coordinator if the premise fails, a
broader mechanism becomes necessary, or measurements cross the thresholds.
