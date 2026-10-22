# Simplifying layout and ownership representation in place

Status: M1, M2 and E1 implemented and qualified, 2026-10-22; see the
[binary ownership report](../benchmarks/results/blorp_2_binary_ownership_2026-10-21.md)
and [flat union reader report](../benchmarks/results/blorp_2_flat_layout_readers_2026-10-21.md).
This simplified roadmap supersedes the uniform heap-catalogue proposal in
commit `7237afb9a`. Design examples below retain their inspection snapshot
`2ebbebf83c08b45cdf0c807453f89e12fb4b4ac9`; M1's matched measurements freeze source
`cdfa1bc6009da61415f26b9f812f1dfbf23a6ebc`. Bootstrap repair and bounded test
integration are qualified separately. Later experiments remain optional.

## Outcome and merge rule

The goal is simpler layout and memory code with less work or retained data.
Adopting a particular recursive ADT is a hypothesis, not the success criterion.
The current model already has ordered fields, finite nominal references, one
published representation choice, constant-time ownership classification and
independent verification. Improve those concrete paths first.

**Every mergeable implementation milestone must earn its own benefit.** Require:

1. Correct behavior, exact diagnostics, preserved coverage and one authority.
2. A real reduction in handwritten production LOC, allocations or retired
   instructions relative to its accepted parent, explained by concrete deletions
   or less work at the owning phase.
3. No material offsetting regression in the other metrics. Fixed-original
   allocation and instruction ceilings are outer guards, not a benefit or an
   allowance to exchange one deleted line for a slower compiler.

A producer-only scaffold, future deletion promise, cleaner diagram or measurement
inside a growth ceiling cannot satisfy (2). Keep an experiment unmerged until
its complete producer-to-consumer path satisfies all three conditions. If it
fails, retain the evidence and accepted earlier improvements; reject or rescope
that experiment. Do not combine independent wins with a losing model to hide it.

Count production, tests/fixtures and documentation ADD/DEL/net separately,
including moved code and mechanical call-site edits. Formatting compression,
removed assertions, disabled coverage and transferred files are not savings.
Necessary tests may grow. There is no arbitrary final -50/-150-line quota or
four-line test-allowance approval cycle; actual simpler code and resource
nonregression decide acceptance.

## What the simpler direction retains and removes

| Keep | Reason |
| --- | --- |
| TypeRef and genuine record/union/field/variant identities | Semantic equality, complete generic keys, selectors and C names |
| Existing concrete record/union tables | Already own complete nominal bodies and finite references |
| PartialType, pending slots, backreferences and settlement | Already resolve supported recursive groups without a new builder |
| Current source storage policy and union owning accumulation | Still select representation once, including counted tuples/captures |
| Independent Verify membership, layout graph and actual ownership checks | Construction and use-specific ownership have different proof obligations |
| Existing List helper inventory and naming | Already selects concrete helper work without registering every List type |

Remove the proposed `HeapId`/`CountedTarget`/`HeapDefinition` catalogue, uniform
reserve/fill queue, global `list_targets` inventory, private ownership-proof
carrier and `AdmissionSource`. They were obligations introduced by the proposed
new catalogue, not demonstrated requirements of the current compiler.
No new pipeline phase, persistent cache/interner, per-value layout wrapper,
runtime layout interpreter, hidden fallback, source feature or library work is
part of this roadmap.

## Milestones and decision boundaries

| Milestone | Complete change | Benefit that must be shown | Dependency |
| --- | --- | --- | --- |
| M0: freeze | Source/tool/binary baseline and exact slice brief | Administrative prerequisite; no implementation commit | CI/bootstrap and bounded tests complete |
| M1: binary ownership query | Remove seven-way ValueOwnership and migrate every actual consumer | Fewer production types/constructors/branches, with nonregressing costs | M0 |
| M2: simpler flat consumers | One demonstrated duplicated physical decision and all its readers | Actual code or measured work reduction; otherwise drop it | M1; independently useful |
| E1: completed record sum | Fuse fields and storage choice through construction, raw verification and emission | Wrapper-allocation or independent code/work win; otherwise reject | Reviewed record-row hypothesis after M1/M2 |
| E2: further adoption | A separately bounded completed-union experiment, only if E1 earned adoption | Its own benefit against accepted parent | Accepted E1; no automatic commitment |

M1 is complete: 32 fewer production lines, 1.016% fewer allocations and
nonregressing instructions. M2 is complete: one private boxed-union predicate
serves all eight physical readers, removing seven duplicate classifications and
three production lines. Allocations are unchanged from its immediate parent;
retired instructions are effectively flat (+0.00303%). E1 is complete: the
completed record sum removes 475 allocations on the fixed workload
(0.001548% of Parent), with effectively flat instructions and net +13 production
lines. See the [record-sum report](../benchmarks/results/blorp_2_record_layout_sum_2026-10-21.md).
E2 remains a separate experiment requiring its own benefit before adoption.
Each implementation brief follows [HANDOFF_SPEC](../docs/HANDOFF_SPEC.md), stays
under its prose limit and references this design rather than duplicating it.

## M1: remove an unused classification

### Problem and current code

`src/specialize/specialize.brp:135–142` publishes:

```blorp
fixed union ValueOwnership:
    NoOwnership
    ManagedStringLeaf
    ManagedCallableEnvironment
    ManagedListRoot
    ManagedRecordRoot(RecordInstanceId)
    InlineOwnedFields(UnionInstanceId)
    ManagedUnionRoot(UnionInstanceId)
```

The actual consumers discard those payload identities and distinguish only
NoOwnership from ownership. For example, `src/own/own.brp:750–753`:

```blorp
ownership_result: Result[ResultOwnership, Diagnostic] = match plan:
    NoOwnership:
        Ok(UnmanagedResult)
    ManagedStringLeaf | ManagedCallableEnvironment | ManagedListRoot | ManagedRecordRoot(_) | InlineOwnedFields(_) | ManagedUnionRoot(_):
        match operation:
```

Replace the classification with a binary query. Keep fallible nominal lookup;
unknown IDs are internal errors, never plain-value defaults. Current query
`specialize.brp:553–592` supplies the exact error messages below.

### Complete replacement query

This proposed code belongs in Specialize and uses its existing imports and
private `ownership_error`; all current TypeRef cases are explicit:

```blorp
pure func value_needs_ownership(
    type_ref: TypeRef,
    unions: List[ConcreteUnion],
    records: List[ConcreteRecord],
) -> Result[Bool, Diagnostic]:
    match type_ref:
        VoidType | IntType | FloatType:
            Ok(False)
        StringType | ListType(_) | CallableType(_, _):
            Ok(True)
        RecordType(id):
            match records.get(record_number(id)):
                None:
                    Err(ownership_error("invalid record identity in ownership representation"))
                Some(declaration):
                    needs_owner: Bool = match declaration.representation:
                        InlineRecord: False
                        ManagedRecord: True
                    Ok(needs_owner)
        UnionType(id):
            match unions.get(union_number(id)):
                None:
                    Err(ownership_error("invalid union identity in ownership representation"))
                Some(declaration):
                    needs_owner: Bool = match declaration.representation:
                        InlineUnmanaged: False
                        InlineOwningPayload | BoxedRecursive: True
                    Ok(needs_owner)
```

There is no new stored Bool, proof token, descriptor construction or child walk.
The existing representation remains the published fact. Preserve exact
message/help/span/note behavior of errors and caller span adaptation.

At Own's existing function-level propagation point (`own.brp:647`):

```blorp
needs_owner ?= value_needs_ownership(definition.value_type, unions, records)
```

At the existing result-construction match, replace only the classification arms:

```blorp
ownership_result: Result[ResultOwnership, Diagnostic] = match needs_owner:
    False:
        Ok(UnmanagedResult)
    True:
        match operation:
```

The existing operation arms follow unchanged. Owner issuance, payload acquisition,
callee liveness, aliases, borrows, transfer and branch discharge are not layout
classification and must remain operation-specific.

A second complete example, replacing `owned_join_parameter` at `own.brp:910`:

```blorp
private pure func owned_join_parameter(
    parameter: ValueParameter,
    next_owner: Int,
    unions: List[ConcreteUnion],
    records: List[ConcreteRecord],
) -> Result[OwnedJoinParameter, Diagnostic]:
    needs_owner ?= value_needs_ownership(parameter.value_type, unions, records)
    match needs_owner:
        False: Ok(UnmanagedJoinParameter(parameter))
        True: Ok(ManagedJoinParameter(parameter, owner_id(next_owner)))
```

### Mechanical consumer/deletion ledger

Search the frozen compiler and tests, then update all real readers in one slice:

| Owner | Change | Preserve |
| --- | --- | --- |
| Specialize `admit_scalar_type` (:3771) | False accepts; True returns the existing managed-tail-recursion diagnostic | Exact diagnostic/help/span and current restriction |
| Own `build_definition`, `owned_join_parameter` | Binary arms as above | Every actual ownership operation and issued identity |
| Verify `verify_type_membership` (:99) | Replace query name; continue ignoring successful Bool | Full List/callable membership recursion and caller span |
| Verify argument/result/join/return checks | NoOwnership becomes False; all ownership cases become True | Existing exact errors and independent owner checks |
| Emit `element_fragments` (:3089) | False emits empty acquire/destroy; True uses existing action helpers | Concrete element type, naming key and nested suffix behavior |
| Tests observing ValueOwnership | Assert the same Bool obligation and genuine IDs elsewhere | Every original semantic assertion and registered callback |

Current examples of the Verify readers are :572, :1396, :1436, :1551,
:1844, :2182 and :2317. Search, not this line list, establishes completion.
Remove ValueOwnership, all seven constructors, matcher imports and the old
query when the final reader migrates. Do not leave a compatibility wrapper.
`payload_owns_children` and private producer choices remain useful and stay.

For `verify_type_membership`, the relevant destination is:

```blorp
match value_needs_ownership(value_type, unions, records):
    Ok(_): Ok(void)
    Err(error): Err({ error | span = span })
```

For `element_fragments`, use the existing two Result-returning matches:

```blorp
acquire_result: Result[String, Diagnostic] = match needs_owner:
    False: Ok("")
    True: append_storage_operation("", layout.element, DuplicateValue, "element", unions, internal_span())

destroy_result: Result[String, Diagnostic] = match needs_owner:
    False: Ok("")
    True: append_storage_operation("", layout.element, DestroyValue, "element", unions, internal_span())
```

Keep them at their existing control boundaries. These excerpts do not authorize
propagation inside unsupported nested match/if/loop positions.

### M1 acceptance and first handoff

Own only `specialize`, `own`, `verify`, `emit` query/import sites and their
existing unit observers. Lower's products/ordered reads, program tables,
representation enums, C ABI and standard library remain unchanged. Before
implementation, give reviewers the proposed removal/addition ledger and tests.

The complete diff must remove the redundant classification and yield negative
production net LOC without formatting tricks. If it unexpectedly grows, stop
and explain why before expanding scope. Run the focused tests below, inspect
query/caller C, and compare matched self-compilation costs. A payload-free Bool
is a hypothesis about less work; it is not a measured allocation/instruction win.
M1 may merge on real code reduction with nonregressing resource results. It
cannot carry an unrelated losing E1 experiment.

## M2: simplify demonstrated flat consumers

The present rows already publish the storage decision:

```blorp
fixed record ConcreteRecord {
    fields: List[TypeRef],
    representation: RecordRepresentation
}

fixed record ConcreteUnion {
    variants: List[List[TypeRef]],
    representation: UnionRepresentation
}
```

Start with actual repeated readers, not a new model. For example,
`emit.brp:270` and `:591` both distinguish a counted union pointer from an inline
union value. If the complete extraction reduces code/work, one direct shared
query can expose that established fact:

```blorp
private pure func union_is_boxed(representation: UnionRepresentation) -> Bool:
    match representation:
        BoxedRecursive: True
        InlineUnmanaged | InlineOwningPayload: False
```

Keep this helper private to Emit when all its readers are there. The caller
passes only the fact read. A possible selector replacement is:

```blorp
private pure func union_member_selector(declaration: ConcreteUnion) -> String:
    match union_is_boxed(declaration.representation):
        True: "->"
        False: "."
```

That selector alone is not a saving. Freeze the complete reader census and
before/after diff first; include helper/import overhead. Reject an extraction
that only moves branches into more layers or loses a distinction another reader
needs. Keep short direct matches when clearer. No general storage-query object,
dispatch framework, cache or per-value annotation is warranted.

Independent Verify checks must not call a producer's policy selector and declare
its output validated. Keep the current raw graph walk and semantic/owner checks.
Source record eligibility is narrower than “unmanaged”: only Int, Float and
eligible inline record children qualify; Void and plain unions do not. A
shared ownership query must not replace that source policy.

M2 implemented the complete eight-reader family above, retaining both distinct
ownership readers and the existing flat loops. Its independent benefit is the
small actual production reduction; it introduces no retained layout carrier.
The linked report records isolated costs and composed fixpoint/component/e2e,
strict leak and sanitizer results. Further work still needs its own concrete
deletion hypothesis; completing M2 does not authorize E1/E2 implementation.

## E1: fuse the completed record row, only if it earns adoption

Status: implemented and qualified, 2026-10-22. See the
[record-sum report](../benchmarks/results/blorp_2_record_layout_sum_2026-10-21.md)
for matched measurements, preserved raw validation, complete component/native
gates, fixpoint and strict/sanitizer results. The implementation is smaller
than the earlier physical-slot
sketch: retain the one ordered TypeRef list and fuse the completed representation
choice into its owner. There is no second physical array or SlotLayout graph.

### Published shape and construction

The old completed row was a managed fixed record containing fields and a
RecordRepresentation. The implementation replaces only that published row:

```blorp
private fixed union RecordRepresentation:
    InlineRecord
    ManagedRecord

fixed union ConcreteRecord:
    InlineFields(List[TypeRef])
    CountedFields(List[TypeRef])

pure func record_fields(layout: ConcreteRecord) -> List[TypeRef]:
    match layout:
        InlineFields(fields): fields
        CountedFields(fields): fields
```

The private enum remains necessary for pending builders. Existing PartialType,
partial slots, backreferences and settlement stay in place. Once known_types
completes the existing fields, settle_record consumes that private choice:

```blorp
layout: ConcreteRecord = match instance.representation:
    InlineRecord: InlineFields(fields)
    ManagedRecord: CountedFields(fields)
Ok(CompleteRecord({
    key = { origin = instance.key.origin, arguments = arguments },
    layout = layout,
}))
```

A completed-slot query projects the constructor back into the private pending
choice when the existing builder needs it. It stores no second completed tag,
Bool, descriptor list or ownership fact. There is no new instance issuance,
all-functions walk, global List discovery, admission carrier or sealing phase.
Declared-record, tuple and capture-environment storage policies are unchanged.

### Complete reader migration

Semantic readers use record_fields; physical readers match the root directly.
For example, the existing ownership query keeps checked nominal lookup:

```blorp
RecordType(id):
    match records.get(record_number(id)):
        None:
            Err(ownership_error("invalid record identity in ownership representation"))
        Some(declaration):
            match declaration:
                InlineFields(_): Ok(False)
                CountedFields(_): Ok(True)
```

Specialize owns construction and pending/completed transitions. Verify and Emit
migrate their entire record reader families in the same experiment. Lower and
Own continue using the published query and need no production change. Checked
records at the earlier semantic boundary still have fields; the new projection
applies only to ConcreteRecord, including test observations.

Emit keeps its actual record declarations, logical member selectors, construction,
cleanup, updates and List helper selection. Where a loop needs semantic fields,
project once for that loop. A root match can bind its payload directly. Existing
TypeRef and ListElementKey remain the authority for signatures, generic keys,
nominal identity and generated helper names. Union rows and their three-way
representation remain unchanged.

### Independent raw verification and semantic obligations

The sum expresses storage choice, not validity. Raw OwnershipProgram rows remain
untrusted. Keep valid_record_layout, valid_union_layout, verify_layout_graph and
operation-specific ownership checks. Adapt their record-root matches without
calling producer logic to validate producer output. Retain these obligations:

- Validate every field and every nominal row, including unused rows and later
  children after an owning field. Preserve missing-ID diagnostics and reject
  empty layouts, invalid signature members and inline cycles.
- Check inline eligibility independently. Only Int, Float and eligible inline
  record children qualify; Void and plain unions do not. A safely counted numeric
  raw row is valid. Do not infer tuple/capture/source origin absent from raw rows.
- Preserve exact genuine record/union IDs, field order, repeated ownership
  occurrences and full callable signatures. Same-shaped nominal rows stay distinct.
- Retain logical Void fields and effects while Emit omits their record members.
  Stored List[Void] and union Void payloads retain their existing unit storage.
- Keep counted tuples/capture environments, including numeric/all-Void cases,
  and the typed callable ops/environment ABI with possibly empty free-entry env.
- Preserve recursive counted cuts and existing union policies: direct Chain
  references use UnionType(chain); inline U through List[U] remains finite via
  the existing List root and nominal UnionType edge. Cross-kind references use
  the current independent graph walk. No recursive query fold is added.

There is no semantic/physical slot correspondence to check because there is no
second slot list. Do not add wrong-descriptor, contextual descriptor-Void or
8/32/128 descriptor-construction tests for a model this experiment does not use.
Existing logical ordinal, membership, identity, effect, ownership and native
oracles remain mandatory. The two added raw cases cover an unused safely counted
numeric row and a later invalid callable member after an owning first field.
Counted eligibility-rescan optimization is separate work and is excluded here.

### Benefit, limits and rejection

The hypothesis is removal of the per-completed-row managed wrapper, not fewer
semantic fields or faster classification. Inspect actual generated compiler C:
row constructors, table element storage, RecordInstance embedding and accessor
ARC. An inline-owning sum can widen tables and its containing records and can
retain/release its fields payload. Do not infer retained-byte savings from fewer
allocations or from source shape. If available, inspect actual C record layouts
without adding an assertion program or rewriting generated C.

Freeze Parent at 6ef8b68296ee70e63fcee18b7cedce23e1720b48 and retain the fixed
cdfa original workload/roles. Require a strict allocation decrease attributable
to wrapper removal, or an independently demonstrated code/instruction benefit
if that hypothesis fails. Production net growth must be at most 40 lines;
normal min3 instructions must satisfy candidate*10000 <= parent*10025. These are
rejection guards, not benefit credit. Investigate repeatable increases even below
the guard, and retain the independent +3% fixed-original guards below.

The first and single prospectively declared confirmation batches reproduced 475
fewer allocations on the frozen workload. Their instruction deltas are tiny and
opposite in direction; no speedup or retained-memory claim follows. The measured
workload has 475 actual record rows; the separate current-parent compiler census
has 477. Do not turn this observation into a general allocation-per-row promise.
Qualification and independent acceptance still decide adoption.

### E2 remains independently optional

Read-only union-row inventory may proceed before E1 adoption; that inventory is
a hypothesis, not implementation approval. Implementation requires accepted E1
and its own reviewed brief. PlainCases, OwningCases and BoxedCases may each carry
the existing ordered List[List[TypeRef]]. Keep existing nominal IDs, private pending choices, union
owning accumulation and independent Verify checks. This is a hypothesis, not an
approved implementation or a commitment to a SlotLayout/List graph. It must show
its own benefit against its accepted parent without material offsetting growth.

## Tests and behavior oracles

Preserve current callbacks and assertions. M1 changes classification observations
mechanically, not the behavior or IDs they assert. Add tests only for an uncovered
new state. Use ordinary TestSuite entrypoints, unmodified emitted C and real main;
no alternate assertion program or generated internal function calls.

| Boundary | Existing owner / protected fact |
| --- | --- |
| M1 nominal membership | `test_verify/test_record.brp:553`: valid inline record gives False; removed real table entry gives exact existing identity error |
| Published obligation | Same owner :527: identical numeric fields, inline pass-through accepted, counted parameter must be borrowed |
| Boxed recursion | `test_specialize/test_recursive_unions.brp`: genuine self ID and boxed choice; `test_verify/test_recursive_unions.brp`: inline self/no self/two self reject |
| Inline recursion through List | `test_specialize/test_recursive_aggregates.brp:98`: inline owning U with genuine U inside List; Verify accepts counted cuts and rejects by-value cycles |
| Nominal identity | `test_verify/test_record.brp`: same-shaped genuine Other record rejects wrong owner/type |
| Callable ownership | Specialize/Own/Verify `test_stored_callables.brp`: environment obligation, acquisition/transfer, borrowed callee and exact signature |
| Void/effects | `test_lower/test_tuples.brp:27`, `test_emit/test_record.brp:114`: definitions/ordinals retained and record Void member omitted |

Unit paths above are under `blorp_2/test/unit/`; folder shorthand names the
existing phase folder. Native fixture paths below are under `blorp_2/`:

| Owning suite | Exact real-main witness |
| --- | --- |
| `test/e2e/test_recursive_unions.brp` | `test/e2e/fixtures/recursive/deep.brp`: exit0, `10000\n`; retain trail/shared checks |
| `test/e2e/test_stored_callables.brp` | `test/e2e/fixtures/callable_values/direct_list_copy.brp`: exit25/empty stdout; forwarded_capture: exit0, `kept!\nkept!\n` |
| `test/e2e/test_tuples.brp` | `test/e2e/fixtures/tuple/void_order.brp`: exit0, the exact eight lines in the suite |
| `test/e2e/test_records.brp`, `test/e2e/test_record_updates.brp` | Existing numeric/managed/projection/update lifetime predicates |

Use the existing suites' complete paths, stdout/accounting assertions and strict/
sanitizer helpers. A C-text check does not replace native lifetime tests.

For M1, freeze one deliberate source fault: report a managed record or callable
as False. Name the exact owning callback and expected failure vector before
execution. The unchanged qualified compiler builds that ordinary TestSuite; its
callbacks exercise the mutated dependency. Setup/compiler failure or zero
callbacks is not a successful fault. Restore source bytes/modes, require the
owning suite green and canonical/restored C identity. E1's source-valid faults
make the counted root report False and bypass the unused-empty-layout gate;
require their exact named failure vectors and exact source/C restoration.
Preserve genuine-ID, logical-Void and later-invalid-member coverage and all
negative raw IR diagnostics; no descriptor-correspondence fault applies.

## Runnable qualification and measurements

Read [AGENTS](AGENTS.md) and the parent's [measurement rules](../AGENTS.md).
The brief binds accepted source/base, complete input and tool manifests, absolute
paths, exact CWD, timeout and compiler roles before execution. A clean checkout
can create its own ignored packet; historical private packets are not inputs.
One serial compiled CPU lane; no parallel compiler or native measurements.

### Build outside measured work and run focused tests

From repository root, after fixing any seed/host freshness problem:

```bash
scripts/compiler-build-status
scripts/blorp2-compiler-bootstrap --print-id
packet="$PWD/build/layout-simplification/M1"
mkdir -p "$packet/artifacts"
make -C blorp_2 test-compiler \
  BLORP2_COMPILER_C="$packet/artifacts/compiler.c" \
  BLORP2_COMPILER="$packet/artifacts/compiler-diagnostic"
make -C blorp_2 link-compiler \
  BLORP2_COMPILER_C="$packet/artifacts/compiler.c" \
  BLORP2_COMPILER="$packet/artifacts/compiler-normal"

bin/blorp test --std-dir standard_library/src --suite --timeout 180 \
  blorp_2/test/unit/test_specialize/test_recursive_unions.brp \
  blorp_2/test/unit/test_own/test_stored_callables.brp \
  blorp_2/test/unit/test_verify/test_record.brp \
  blorp_2/test/unit/test_emit/test_record.brp
```

The normal/diagnostic compiler roles link the same C at -O0, diagnostics macro0/1.
The legacy executable above is only the identified maintained TestSuite observer;
it never replaces pinned B2 compiler generation. Include other actually changed
owners in the frozen brief. Inspect query/caller C for descriptor construction,
retain/drop, child walks and unchanged actual ownership operations.

Use the existing strict/sanitizer real-main helpers for affected native families.
Before landing a stable slice, run maintained components/selected target suites
and the actual self-compiled compiler's full e2e/fixpoint once:

```bash
make -C blorp_2 test-components \
  BLORP2_COMPILER="$packet/artifacts/compiler-diagnostic"
BLORP_2_INSTRUCTION_CHECK=disabled BLORP_2_RESOURCE_POLICY=record-allocation-debt \
  scripts/blorp2-fixpoint --prove
cmp blorp_2/build/fixpoint/a.c blorp_2/build/fixpoint/b.c
cmp blorp_2/build/fixpoint/b.c blorp_2/build/fixpoint/c.c
```

Archive that script's standard ignored output before a later run replaces it.
Preserve original typed allocation FAIL debt records; instructions disabled in
this broad correctness gate are unmeasured, not a cost PASS. Check saved fixture
contracts offline: exit0 requires nonempty C/empty streams; exit1 requires no C,
empty stdout/nonempty diagnostic; any other status blocks even if A/B agree.
The script does not prove whole-source strict/sanitized accounting. For a data
model/codegen change, use its same B compiler C through the ordinary compiler
main (these commands follow the successful fixpoint run):

```bash
fixpoint="$PWD/blorp_2/build/fixpoint"
BLORP_LEAK_CHECK=strict "$fixpoint/stage_b" \
  --library-root blorp_2/standard_library blorp_2/src/main.brp \
  "$packet/artifacts/self-strict.c" \
  > "$packet/artifacts/self-strict.stdout" 2> "$packet/artifacts/self-strict.stderr"
clang -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
  -DBLORP_MEMORY_DIAGNOSTICS=1 -fsanitize=address,undefined \
  -fno-sanitize-recover=all "$fixpoint/a.c" \
  -o "$packet/artifacts/compiler-sanitized" -lm -lpthread
BLORP_LEAK_CHECK=strict "$packet/artifacts/compiler-sanitized" \
  --library-root blorp_2/standard_library blorp_2/src/main.brp \
  "$packet/artifacts/self-sanitized.c" \
  > "$packet/artifacts/self-sanitized.stdout" 2> "$packet/artifacts/self-sanitized.stderr"
cmp "$fixpoint/a.c" "$packet/artifacts/self-strict.c"
cmp "$fixpoint/a.c" "$packet/artifacts/self-sanitized.c"
```

Require empty compiler stdout, exactly one positive balanced zero-leak report,
no sanitizer diagnostic and identical C. No historical receipt qualifies a new
source epoch.

### One frozen-input cost comparison

Freeze the complete accepted original compiler source and target library. Both
parent and candidate compile that same main, library root and CWD. Actual
current-source self-compilation is separate because its input changes.
Record source/binary/tool/flags/mode hashes and a private mode0600 environment
snapshot. Launch roles with that exact environment, not a merge with a later
shell; normal roles remove both BLORP_LEAK_CHECK and BLORP_MEMORY_STATS, strict
roles add only BLORP_LEAK_CHECK=strict. Publish environment digest, not secrets.
Record existing cache policy/state symmetrically; no new cache or unpaired warmup.

All variables below are absolute pinned paths. The administrative collector
saves each literal argv, raw streams/status, output and before/after guards;
it performs no language assertions. Its source is reviewed before sampling.
Use the same physical output path, absent before each invocation. Archive/reset
outside the measured compiler process:

```bash
set -eu
measurement_output="$packet/artifacts/measured.c"
strict_observation() {
  role="$1"
  label="$2"
  rm -f "$measurement_output"
  BLORP_LEAK_CHECK=strict "$role" --library-root "$frozen_library" \
    "$frozen_main" "$measurement_output"
  cp "$measurement_output" "$packet/artifacts/$label.c"
}
normal_observation() {
  role="$1"
  label="$2"
  rm -f "$measurement_output"
  /usr/bin/time -l "$role" --library-root "$frozen_library" \
    "$frozen_main" "$measurement_output"
  cp "$measurement_output" "$packet/artifacts/$label.c"
}
strict_observation "$parent_diagnostic" parent-strict
strict_observation "$candidate_diagnostic" candidate-strict
# Review strict results/guards first; stop on a failure before normal samples.
normal_observation "$parent_normal" p1
normal_observation "$candidate_normal" c1
normal_observation "$candidate_normal" c2
normal_observation "$parent_normal" p2
normal_observation "$parent_normal" p3
normal_observation "$candidate_normal" c3
```

Require empty compiler stdout, valid output and exact frozen-input C identity
for all eight observations. Strict stderr has exactly one positive balanced
zero-leak report; normal stderr has the actual positive retired-instruction
counter and only the expected time report. Use normal min3; missing counters
are unqualified, not zero or an elapsed-time substitute. No failed-slot replay,
sample substitution or baseline reset. Preserve prior failures.

The prospective outer ceiling is **+3% original allocations and +3% original
normal min3 instructions**, checked independently by integer products:
`100*candidate <= 103*original`. Report parent deltas too. Original values retain
frozen role/source/tool/environment/counter provenance. If the epoch changes,
remeasure original and parent prospectively before candidate sampling; a parent
never becomes the new original. These limits do not establish nonregression or
benefit by themselves: investigate repeatable growth and reject a material
tradeoff even when under the ceiling.

For a LOC-benefit slice, the prescribed strict pair and normal batch establish
resource evidence. For a resource-only benefit, predeclare one fresh confirmation
batch after Root reviews the first result, under the same quiet epoch and roles.
The claimed direction must repeat with a phase/C explanation and visible sample
variation. Overlapping noise without mechanism is an unproven benefit. Do not
keep sampling until a favorable result appears.

E1 measures the actual completed-row construction through the matched whole
compilation and inspects its generated row/table/container/accessor C. It adds no
retained descriptor arrays, so the superseded 8/32/128 descriptor probes do not
apply. Peak RSS is supplementary, not proof of retained bytes. Preserve logical
Void/ID/ownership/native tests and the declared resource confirmation protocol;
no production counters/framework or benchmark main. Earlier negative L0 and
owned-fact query results remain historical evidence, not adoption proofs.

## Handback, review and landing

Return the exact base/candidate, owned paths, actual production/test/docs
ADD/DEL/net, removed types/decisions/readers, canonical callback/fault vectors,
strict/sanitizer/native/fixpoint evidence, frozen-input allocation and min3
instruction values, provenance and unqualified boundaries. Keep raw data under
ignored build packets and one concise current decision report under
`benchmarks/results/`. Report inherited debt and authorized TODOs separately.

Two independent code/architecture and test-runner reviews precede each commit.
Root owns integration and publication. Each later experiment begins only after
its own brief and prerequisites close. Do not push a plan-only commit for every
substep.

Stop and return bounded evidence when a proposed slice has no independent
benefit, adds another retained authority, weakens exact verification, requires
new language/library work or a new registry/cache/phase, changes source/C ABI
behavior, fails guards/gates, or materially regresses resources/production size.
Ask the coordinator about a concrete rescope; routine import/annotation fixes
inside the agreed slice do not require another user approval round.
