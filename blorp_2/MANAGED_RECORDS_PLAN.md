# One managed String field

Status: proposed next increment, not implementation authorization or a claim of
supported behavior. Complete and review [RECORDS_PLAN.md](RECORDS_PLAN.md)
first. Read both [AGENTS.md](AGENTS.md) and the
[parent AGENTS.md](../AGENTS.md);
[MEMORY_PLAN.md](MEMORY_PLAN.md#dupdrop-arc-and-exhaustive-destruction) owns the
memory contracts. Final carrier names must follow the completed Int-record
implementation rather than this document's illustrative notation.

## Problem and working example

The Int-record increment establishes nominal products, ordered construction
and by-value field reads. It deliberately rejects a String field. The next
small example should prove an aggregate owns a mortal child and a returned
projection survives its parent:

```blorp
fixed record Holder { text: String }
pure func make_holder() -> Holder:
    { text = to_string(42) }
pure func get_text(holder: Holder) -> String:
    holder.text
func main() -> Int:
    text = get_text(make_holder())
    text.length()
```

Proposed fixture: `test/e2e/fixtures/record/string_field.brp`. Its ordinary
`main` exits 2 with empty stdout/stderr. The caller may retire the temporary
Holder after `get_text` returns, while `text` remains usable. No import,
printing, literal String, custom C entrypoint or output rewriting is needed.

After the Int increment lands, register this fixture in the existing e2e
group and retain its initial rejection:

```sh
make -C blorp_2 test-compiler
blorp_2/build/compiler blorp_2/src/prelude_temp.brp \
  blorp_2/test/e2e/fixtures/record/string_field.brp \
  blorp_2/build/record-string-field.c
```

Expected red: declaration checking exits 1, creates no C, and reports the
completed Int increment's exact unsupported-field diagnostic at `String`.
The current draft renderer says `fixed record fields must be Int`; verify
the final diagnostic before recording it. After implementation compilation
succeeds and the existing native harness observes exit 2.

## Scope and dependencies

Keep all supported Int records. Add nongeneric `fixed record` declarations
with exactly one field of type String, such as Holder. A neighboring Int
field is unnecessary for this proof and is deferred, along with multiple
managed fields, nested/recursive records, managed union payloads, ordinary
`record`, field updates/assignment, COW/reuse, collections, closures, FFI,
immortal aggregates and new control-flow forms. Reject other field shapes
at declaration checking even when unused. Existing generic functions may
accept Holder through their current inference/specialization rules; do not
extend those rules or add generic record declarations.

Use the Int increment's syntax and contextual literal rules unchanged.
Allow concrete helper parameters/results, immutable aliases, whole-`var`
reassignment and field projection. Existing restrictions on managed values
outside terminating match-arm blocks remain; this example is straight-line.
Do not solve outer borrow dependencies across control-flow joins here.

Implementation waits for the reviewed Int-record baseline and coordinator
assignment. The separate runtime-test approval dependency below must also be
resolved before claiming exhaustive destruction validated. This spec changes
only this new document while the Int-record worker owns existing files.

## Proposed solution and authorities

Extend the current checking, specialization, lowering, ownership, verification
and emission path. Keep the pipeline pure after reading explicit sources.
Use local builders and immutable published products, with no cache, registry,
general borrow graph or additional compiler pipeline.

| Consumer question | Owner and lifetime |
| --- | --- |
| Which nominal record/field was accepted? | Checker-issued RecordId and owner-qualified FieldId, valid within that checked program; complete field type is published once. |
| Which concrete shape does an operation use? | Specializer-issued RecordInstanceId and FieldInstanceId, with checked declaration-to-instance translation. |
| How is that concrete value stored and destroyed? | A complete canonical runtime plan derived from the concrete shape, valid within that program. A record plan can use its existing RecordInstanceId while each instance has one physical layout. |
| Which value is being projected or transferred? | Existing function-scoped ValueId in one lowered body revision. |
| Which obligation keeps a value alive? | Existing OwnerId or borrowed parameter identity, with an explicit projected-field dependency where needed. |

Checking publishes String field types and complete literal/projection facts;
it does not select ARC layout. Preserve existing structural/type diagnostic
priority and exact source spans, help and declaration notes. Specialization
publishes a complete concrete field shape, without unresolved parameters.
Representation classifies Holder as a managed root, following the parent
language rule for a fixed record containing String. Int-only records stay
inline and unmanaged. These are responsibilities within the existing phases,
not a requirement for another pass, table or opaque layout ID. Introduce a
separate identity domain only if an admitted operation needs to distinguish
multiple physical layouts of one concrete instance; this increment does not.

Build one complete runtime layout from the concrete shape. Every storage
field has an explicit ownership classification; Holder.text owns a String
leaf. Validate exact field identity, owner, count and type against the
specializer's shape at construction. This derived runtime plan is the sole
authority for storage/destruction, not a second semantic field catalogue or
an independently collected list of managed fields. Derive the destructor
from every field in that plan. Unknown layouts, missing/duplicate fields or
unsupported field plans reject; none defaults to unmanaged. Validate layouts
even for pass-through parameter/return values that are never constructed.

## Current code and proposed data

These source excerpts are snapshots of baseline `e553b5c04`, verified while
the Int-record implementation was in progress on 2026-10-10. They identify
existing contracts, not finalized record APIs. Refresh the excerpts and line
positions against the completed Int-record baseline before implementation.
Baseline `src/own.brp:31-33` has:

```blorp
fixed union ValueOwnership:
    NoOwnership
    ManagedStringLeaf
```

Extend the leaf-only managed case with a closed view of the canonical runtime
plan. Illustrative notation, deliberately not a prescribed API:

```text
ValueOwnership = NoOwnership | ManagedStringLeaf
               | ManagedRecordRoot(RecordInstanceId)
FieldOwnership = NoOwnedValue | OwnsStringLeaf

Holder layout:
    root = managed allocation
    text = OwnsStringLeaf
```

Reuse String's existing allocation, retain/release, length and owned-return
contracts. No generic destructor dispatch or general layout solver is needed;
only String leaves and the admitted concrete managed record require runtime
operations. An empty child plan for a leaf is explicit and valid, unlike a
missing plan.

Baseline `src/own.brp:49-57` represents only direct borrows:

```blorp
fixed union BorrowSource:
    ParameterBorrow(ValueId)
    OwnerBorrow(OwnerId)
fixed record BorrowedValue {
    value: ValueId,
    source: BorrowSource
}
```

Baseline `src/verify.brp:202-204` accepts an owner borrow only when that owner
owns the borrowed ValueId itself. A field ValueId differs from its parent,
so weakening this equality would lose provenance. Instead extend the one
borrow-source authority with a narrow projected-field case:

```text
borrowed String value:
    value = projected ValueId
    dependency = record receiver ValueId + FieldInstanceId
                 + receiver's borrowed-parameter or local-owner source
```

Only one record-to-String projection depth is needed. The dependency itself
performs no retain. Uses/liveness keeps the parent source alive through all
dependent borrows; the verifier independently checks the actual projection,
field owner/type, receiver and live parent source. Do not add a parallel
unvalidated dependency table or infer provenance from ValueId proximity.

Baseline `src/own.brp:60-62` call operands are unmanaged values or borrowed
arguments. Calls retain their present borrowing ABI. Record construction is
different: its String operand transfers a named owner into a field. Add the
narrow construction operand carrying field identity, value and transferred
OwnerId; acquire an owner first if the child was borrowed or must survive
elsewhere. Consumption discharges that obligation and never emits a child
release. No extra call convention or fallback is needed.

## Operational examples

Illustrative ownership IR for `make_holder`:

```text
v0: String = to_string(42)                   owns o0
v1: Holder = construct Holder { text <- (v0, o0) } owns o1
return_owned(v1, o1)
```

The root starts with one reference. Construction transfers o0 exactly once;
it does not retain and then forget an additional String owner. For a borrowed
String initializer, acquisition creates the owner transferred to the field.

`get_text` borrows its parameter and returns an owned String:

```text
p0: Holder = borrowed parameter
v1: String = read_field(p0, Holder.text)      borrows field of p0
o0 = acquire(v1, dependency = p0.text)
return_owned(v1, o0)

caller: receive returned String owner; then drop temporary Holder owner
```

Acquisition must precede parent retirement, including when the projection is
returned from a temporary created inside the same function. A direct
`make_holder().text.length()` may keep the parent alive through length instead
of acquiring a child owner. Tests assert lifetime and required ordering,
without pinning redundant retains where either placement is legal.

Retaining Holder's root increments only that root's count. Its child belongs
to the root's lifetime and is not retained once per root alias. Nonfinal root
release destroys nothing. Final release drops the sole owned String child
and then frees the root exactly once. Choose one root-deallocation authority:
the generated concrete release helper owns both final child cleanup and final
root free; emission must not also free it elsewhere. Use String's existing
atomic RC discipline. No destruction recursion is required for this shape.

Whole-variable replacement establishes the RHS owner before retiring the old
root. Test this with existing syntax, including an owned result aliasing its
borrowed argument:

```blorp
pure func identity_holder(value: Holder) -> Holder:
    value
func main() -> Int:
    var current = make_holder()
    original = current
    current = identity_holder(current)
    original.text.length()
```

It exits 2. Make replacement children observably different in a separate
fixture, so accidentally changing the old alias cannot pass:

```blorp
pure func single_digit_holder() -> Holder:
    { text = to_string(7) }
func main() -> Int:
    var current = make_holder()
    original = current
    current = single_digit_holder()
    original.text.length()
```

This exits 2 for the original `42`; a companion returning
`current.text.length()` exits 1 for the replacement `7`. Rebinding and
self-assignment use existing ValueIds; do not introduce runtime mutable cells.

## Failing-first granular tests

Use named Blorp TestSuite callbacks in existing owning phase suites. Prepare
sealed inputs only as far as their authority requires; test later phases
directly rather than compiling every case from source.

| Boundary | Required independent observations |
| --- | --- |
| Checking/rendering | One String field accepted; wrong child type, unsupported shapes and nominal confusion rejected with exact typed kind, span, help and notes; no partial accepted program. |
| Specialization | Complete Holder shape and field-owner translation; same-shaped nominal records remain distinct; existing generic identity can preserve Holder without changing inference. |
| Representation | Int record unmanaged, Holder managed, String leaf explicit; exact child-plan totality; missing/wrong-owner/duplicate/unknown plans reject, including pass-through-only values. |
| Lowering/uses | Construction child and receiver evaluated once; field dependency names the actual parent; dependency extends its source lifetime; old aliases and reassignment retain distinct value versions. |
| Ownership insertion | Fresh child transfer; borrowed child acquired before transfer; unused root dropped; projected borrowed escape acquired before parent drop; root aliases retain root only; RHS owner exists before old root drops. |
| Independent verification | Direct malformed IR: missing acquisition, borrowed field escape, wrong parent/field, parent dropped before projection/use/acquisition, child transferred twice or reused after transfer, leaked root, double drop, wrong layout and incomplete child plan. Assert the exact failed obligation and operation. |
| Emission | Small independently expected C operations preserve transfer/acquire/drop order; root-specific retain/release uses the right layout; final helper drops the field once then frees root; no cleanup invented during emission. |
| Native fixtures | Ordinary-main exit 2 for escaped field, direct field length, unused root, borrowed initializer, root identity and original-alias cases; the replacement-child companion exits 1. Unmodified C, O0 and existing ASan/UBSan checks. |

Feed malformed ownership operations directly to the public raw-program
verifier, using producer-issued IDs. Do not weaken opaque/sealed APIs.
Compare layout completeness against an independently specified accepted
shape, so omission in the planner and destructor cannot make both agree.

Mutation proofs: omit the required field drop and require the destruction
oracle to fail; remove projected-child acquisition or move it after parent
drop and require the precise verifier/native regression to fail. Restore
exact source before final gates. Balanced counts alone are insufficient.

## Runtime-test approval dependency

Existing `test/runtime/test_string_runtime.brp` already runs nine C cases
against the actual emitted String fragment, using real allocator wrappers.
They cover leaf bytes, reference counts, nonfinal release, final free and
independent lifetimes. Keep them; they do not prove record child destruction.

Propose extending that same approved testing pattern to the actual generated
Holder layout/release fragment, driven by Blorp TestSuite. Exact cases:
construction transfers its child; root retain changes no child count;
nonfinal release preserves child; final release frees child then root once;
an independently retained child survives root destruction and frees later.
Use mortal allocations and test-local real allocator wrappers, observing
which allocation was freed. The omitted-child-drop mutation must fail this
oracle, and a supported native leak checker when available.

This requires explicit owner approval: AGENTS.md currently authorizes the
direct C exception for String runtime only. Ordinary-main outcomes plus
sanitizers cannot observe every missed free, especially where leak detection
is unavailable. The proposed extension tests the production-emitted fragment
without modifying it; it does not call generated language-fixture helpers or
add production tracing. Until approved, specify these cases and report
destructor runtime coverage pending. Do not introduce the exception, a test
framework, extraction workaround or second emitter path unilaterally.

## Validation, costs and acceptance

After the focused new callbacks pass, run from the repository root using a
fresh host and the existing validation recorder:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_records.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_own.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_verify.brp
bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit
bin/blorp test --suite --timeout 180 blorp_2/test/runtime
make -C blorp_2 test
git diff --check
```

Add representation tests beside the existing ownership tests unless an
agreed new production module needs its matching unit suite. Runtime commands
exercise record tests only after the approval dependency is resolved.
The existing e2e entrypoint builds the pilot once at O0; it runs with
`--timeout 0` and compiles each fixture once. No persistent compiler cache.

Freeze completed Int-record source/binaries, inputs, flags and C toolchain
before implementation. Use the existing eleven-workload corpus and recipe
linked in [RECORDS_PLAN.md](RECORDS_PLAN.md#feedback-performance-and-stop-rules),
with three quiet serialized baseline/candidate samples per workload. Label
these compilation costs as owned-input proxies, not self-compilation. Retain
all preexisting fixture C byte-identical by emitting managed record helpers
only when those concrete layouts are needed. Investigate repeatable increases
above 10% allocations or 5% minimum retired instructions on old workloads.

Proposed initial new-fixture ceilings: 10,000 compiler allocations and
100,000,000 retired instructions, matching the first record increment. Confirm
headroom from its completed baseline before approval; these are proposed
ceilings, not measured results. Require zero compiler-process leaks under
strict checking. Report target root/child allocations and frees separately;
compiler allocation counters do not measure them. Require zero outstanding
target allocations in the approved destruction cases.

Proposed investigation stop: more than 600 additional formatted physical
production lines over the completed Int-record baseline. Review actual
contract costs with the coordinator before expanding; report production and
test counts separately. Neither limit permits compressed formatting, dropped
coverage or silent threshold increases.

Acceptance requires the fixture's red/green evidence, granular/malformed-IR
tests and mutation failures, old-C identity, matched costs, full pilot gates,
and resolved runtime-test approval plus exact destruction evidence. Update
README/scope diagnostics with implementation; syntax is unchanged, so confirm
EBNF conformance rather than inventing new productions. Get independent
compiler-expert code-reviewer and test-runner approval before landing.

## Handback and stop rules

Return concise changed-file, identity/ownership-contract, exact gate and
mutation summaries, generated-C observations, matched cost/LOC evidence and
unresolved limits. Use `benchmarks/results/` for the retained report and
ignored `build/` with one navigator for raw artifacts.

Stop for the coordinator if the completed Int-record contracts require a
broader representation rewrite, a new mechanism, cross-branch borrow graph,
unchecked emission or an unapproved native test path. Describe the concrete
case, simpler option and proposed split. Do not work around a host compiler
failure or begin recursive/multiple-field/COW work. This task's handback is a
reviewable proposed spec; no code implementation, compiled commands, commit
or push are authorized by the spec-writing assignment.
