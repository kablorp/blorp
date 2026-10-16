# M4.2b: finite values with union-only recursive storage

**Bootstrap scope update.** The [source plan](BOOTSTRAP_SOURCE_PLAN.md#retained-recursive-types)
finds no current compiler-source witness requiring M4.2b or M4.2c. Preserve this
design and its held candidate, but keep them off the bootstrap critical path.
Reopen only on an exact substituted stored-payload witness after refreshing the
inventory over migrated source and the actual temporary library. Existing unary
and mixed record/union/List recursion remain required.

Root and an independent compiler expert approved this bounded plan before
implementation. A separate durable plan commit precedes production changes;
approval establishes no executed behavior or cost result.
Source HEAD read: `0ea0a4adc96d2c62f58d300a41c33a1a636a018a`; its source/library
diff against published `c4ec843d622b3c9a60d86cf559494faced565438` is empty.
The ignored planning packet's `inputs.sha256` freezes the actual
reference/producer/consumer bytes read; the accepted source commit identifies
the durable baseline independently of that packet.
Abbreviated production anchors below are relative to `blorp_2/src/`.

### Reviewed checker amendment

The first executed red has fourteen callbacks: three new semantic failures and
eleven passing controls. The baseline CLI also rejects both new real-main
fixtures with the expected diagnostics and no output C. That evidence does not
validate the first implementation, which has not been compiled.

Source review of that implementation found that admitting only empty-argument
backedges is insufficient: `Wrap[T] → Node → Wrap[Int] → Node` can close at
Node without rejecting the deferred generic recursion. Conversely, entering
`Node → Option[Node] → Node` through Option can encounter a nonempty backedge
and reject a supported wrapper. These are source-derived counterexamples,
not additional executed reproductions. Root and two compiler experts agree on
the fixed-target policy below. This amendment must be committed before the
checker revision; new paired ordering tests must demonstrate actual red first.

## Problem and first executable example

`check/declarations.brp:1167–1168` rejects a repeated union instance on the
current path, even when indirection can represent finite values. This proposal
starts with the following **unmodified real main**, expected exit7, empty
streams; nested patterns, imports and arithmetic are unnecessary:

```blorp
fixed union Left:
    Done(Int)
    IntoRight(Right)
fixed union Right:
    Back(Left)

pure func left_value(value: Left) -> Int:
    match value:
        Done(number): number
        IntoRight(other): right_value(other)

pure func right_value(value: Right) -> Int:
    match value:
        Back(other): left_value(other)

func main() -> Int:
    left_value(IntoRight(Back(Done(7))))
```

The source-derived current failure is RecursiveAggregateType(Left), at the
closing written `Left` in Back, message `recursive aggregate types are not
supported yet`, current help at `check/render.brp:514`. Establish that exact
typed/full-source-span behavioral red with the frozen host/pilot before edits;
this planning session did not execute it. Also admit:

```blorp
fixed union Tree:
    Leaf(String)
    Fork(Tree, Tree)
```

Tree's repeated direct slot currently fails at `repeated_self_payload`
(`declarations.brp:995/1185`). Node→Option[Node] belongs here: Option's body is
not itself recursively parameterized. A declaration using its own generic
parameters recursively remains M4.2c, including growing/nested substitutions.

## Established practice and current inventory

Verified primary references, 2026-10-16: [Rust recursive layouts](https://doc.rust-lang.org/book/ch15-01-box.html)
motivate pointer indirection for finite size; [rustc collector](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_monomorphize/collector/index.html)
motivates complete instance identity when discovering dependencies.
[OCaml representation](https://ocaml.org/docs/memory-representation) illustrates
tagged payload blocks; [OCaml recursive values](https://ocaml.org/manual/5.5/letrecvalues.html)
shows that immutable constructors alone do not prevent cycles when recursive
bindings exist. Our ARC/DAG/cleanup design is our own choice and needs its own
proof, not a consequence of those implementations. No Rust collector or OCaml
GC/recursive-binding mechanism is copied.

Relevant current source families, manually traced (not a complete parser census):

| Family | Actual edges and current route |
| --- | --- |
| checked TypeRef, model:65–75 | ListType(Self), applied arguments List[Self]; unary/pointer cases already supported |
| syntax ExpressionBase/ValueExpression, syntax:279–338 | expression→record→expression/list; existing record/List path |
| CheckedForm/CheckedExpr, model:184–206 | union→record→union and List[CheckedExpr]; existing path |
| PendingBase/PendingValue, inference:42–101 | record/List edges; PendingOperations has one direct self plus PendingStep record |
| PartialType/PartialUnionKey/PartialRecordKey, specialize:809–825 | one direct List wrapper; record/list keys; existing path |

This slice extends storage admission, not the source parser frontier. Historical
step2a's “30 types in8 groups” and release depths are retained evidence, not a
fresh current-source census or measured safety margin.

## Identity, owner and lifetime before representation

| Fact | Producer/owner | Lifetime and consumers |
| --- | --- | --- |
| UnionId, VariantId, TypeParameterId | existing inventory/namespace + checked declaration admission | immutable checked program; never spellings or raw IDs across domains |
| complete declared payload TypeUse | checker; generic-cycle validation runs first | all declarations, unused included; full written/application spans retained |
| storage-walk completion | checker, local full-instance-key builders | shared across IndependentStorage roots; fresh and private to each GenericDeclarationRoot query, never translated between these questions |
| concrete key (declaration, ordered complete/partial arguments) | existing specializer reservation builder | key reserved in InProgressLayout before children; numeric instance IDs still issued postorder at slot publication |
| PendingUnionType/UnionSlot | same builder, one slot/key | local only; references resolved by existing completion; sealing rejects all placeholders |
| union storage/ownership | specializer, ConcreteUnion.representation | frozen complete catalog; value_ownership projects ManagedUnionRoot or InlineOwnedFields |
| ValueId/OwnerId/borrow source | lower / ownership insertion | distinct value and slot obligations; verifier independently validates raw owned IR |
| C destruction strategy | emitter, once per complete layout/helper | transient emission decision from typed fields; no semantic lookup or new published graph |

No LayoutGroupId, second catalog, checked boxing table, cache or evaluation
stage. A cycle entry may be boxed while siblings remain inline: deterministic
reservation order selects the entry. Different entry orders must both produce
valid behavior/ownership; identical cross-program numbering or all-member
boxing is unnecessary. Sibling Wrap[Int]/Wrap[Left] instances must stay distinct
while repeated equal keys produce one complete row.

## Smallest producer-to-consumer change

**Checker.** Preserve validate_generic_cycles first (`declarations:972/1025`):
it rejects own-parameter reinstantiation/growth before this finite traversal.
Keep the existing instance walker and root/field scheduling. Remove the
repeated-self rejection and its now-unnecessary VisitVariantPayload bypass.
One private policy distinguishes the question for the active root:

```blorp
-- Proposed private local-query policy, not a published semantic authority.
private fixed union StorageWalkPolicy:
    IndependentStorage
    GenericDeclarationRoot(UnionId)
```

IndependentStorage admits **every exact active-instance backedge**, including
an applied nonempty wrapper key. Close the edge without a second finish frame
or early completion. A generic declaration root G instead asks whether its
rigid-parameter body reaches G again. Reject a child entry to declaration G at
**any arguments, before active/completed lookup**. The existing VisitUnionRoot
seed is structurally exempt; no seed flag is needed. ParameterType is a leaf,
so Option[T] itself stops at T, while a concrete Option[Node] query follows
the substituted stored Node. This admits ordinary wrappers but rejects both
Wrap[T]→Node→Wrap[Int] and Wrap[T]→Option[Node]→Node→Wrap[Int].

Use two direct local completion builders with full ordered instance keys:
the existing shared IndependentStorage builder and a fresh builder per fixed
generic target. A completion row means its outgoing edges were expanded in
**this query**, not that this node independently cannot reach every target.
Accept the query only after its pending work drains. Never reuse independent
or another generic target's completion facts. Select the active builder at
the existing lookup/finish sites; do not thread growing tables through a shared
record. The policy lasts from root activation through pending-stack exhaustion.
List and record pointer cuts schedule fresh IndependentStorage roots rather
than inheriting G. Traverse stored fields, never phantom key arguments alone.
No new graph, traversal, SCC authority or ancestor-result cache is required.

Preserve ApplicationSpan/PayloadSpan reporting and own-parameter validation
priority. Selecting the first child reentry can change the rejected TypeRef
from a later repeated wrapper to G; enumerate and review such typed diagnostic
changes with exact source/span/help/note tests. Do not claim blanket first-error
identity without checking competing errors and both declaration orders.

**Specializer.** Current `prepare_union:1473–1498` boxes only an own direct
PendingUnionType. Merely lifting checker rejection would seal an invalid
all-inline Left→Right→Left cycle. Keep the cheap direct-self result; only an
otherwise referenced-back union needs a narrow stored-payload reachability
query over its **existing local partial slots**:

```blorp
-- Proposed sketch at prepare_union's completion, existing inputs/products:
left ?= leave_layout(layouts, span)
stored_cycle ?= if self_referencing:
    Ok(True)
else:
    match left.back_reference:
        NotReferencedBack: Ok(False)
        ReferencedBack: storage_reaches_pending_union(key, variants, dependencies, span)
representation = if stored_cycle:
    BoxedRecursive
else if owning:
    InlineOwningPayload
else:
    InlineUnmanaged
-- Existing postorder ID, settle_union, resolve_*_slots and seal remain owners.
```

The query follows actual fields through known inline union slots (complete or
pending); matching PendingUnionType(key) is the witness. Other pending ancestor
keys are not this witness. Stop at boxed unions, Lists, Strings and records;
never traverse key arguments. Keep a query-local frontier and visited existing
slot IDs using the existing IntMap, freeze nothing. This is needed to answer
the new indirect-storage question, not a parallel graph authority. Frontier
work is O(reached fields+slots) amortized, memory O(reached fields+slots), plus
structural partial-key comparisons: same_partial_union_key recursively compares
arguments. Across R queried roots, frontier work sums their reachable closures,
worst O(R(V+E)); report key-comparison work separately. Shared branches must be visited once per query. Profile repeatable
near-quadratic scaling; do not silently add an index/optimizer.

**Record boundary proof:** `inline_record_field:1532–1547` admits only numbers
and already-inline records; pending fields, unions, Lists and managed children
force ManagedRecord (`1588–1619`). A record on a cycle is therefore managed;
an inline record cannot hide a union path. Independent verification enforces
the same restricted inline fields (`verify:969–1009`). After that complete
validation, the raw-layout witness may stop at every RecordType: managed
records are pointer boundaries and verified inline records have no union
edge. No record frontier or second identity domain is needed. Test direct and
transitive forged inline-record summaries; their existing summary error must
precede missing boxed witness. If inline-record eligibility later admits
unions, the producer proof and independent witness must change together.

Alternative: add pointer/argument-boundary states to the in-progress stack.
It spreads through prepare_type/prepare_arguments and terminal substitutions:
phantom key arguments are not stored edges, and List currently has no frame.
Reject that broader recut unless the bounded query demonstrably fails costs.
Also reject boxing every union, a new SCC catalog or replacing the builder.

**Verifier.** Independently generalize the boxed witness from direct self
(`verify:649–709`) to a path through stored inline fields back to that boxed
root. Use the existing raw catalog/layout-walk vocabulary and local visited
IDs; no access to private partial slots or producer witness. The current verify
entrypoint runs valid_union_layout before verify_layout_graph; a witness query
at that earlier site would trust record summaries before they are proved.
Keep existing basic membership/shape checks first, then the existing complete
layout-graph/record-summary validation, then the boxed-root witness check.
This uses the existing verifier sequence, not a new accepted authority.
Preserve all-inline cycle rejection (`785/913–923`). Multiple
self slots are legal only with boxed storage. Proposed exact new invariant
message: `ownership verification failed: boxed union representation requires a recursive stored-payload path`,
existing help `report this compiler error with the input program`, compiler
SourceId/span and absent note. Unknown IDs and all-inline cycle messages retain
their existing priority. No VerifiedProgram construction bypass.

**Lower, uses, own:** no forms change. `lower:374–376` creates fresh values from
ordered child values; `own:302/478–501/572–578` preserves every occurrence and
issues one slot OwnerId per managed borrow. Repeated ValueId is not permission
to deduplicate ownership. Existing borrow lifetime/last-use/drop machinery reads
the published representation; add granular tests before considering edits.

**Emit.** Storage boxing and direct-chain cleanup are different questions.
Current `append_boxed_union_release:1587–1591` overwrites child for every self
slot; accepting Fork unchanged would leak a subtree. Keep that helper only
where there is at most one direct self slot per variant and at least one in
the layout. Emit ordinary recursive final-release helpers for multiple-self
or purely indirect boxed roots, reusing the existing typed field action loop
where directly possible; no second runtime. The indirect mutual root must not
enter the direct-self helper. A mixed direct-chain helper may recurse through
its other owning children: no whole-graph constant-stack claim. Nat and Trail's
existing iterative100k guarantee remains exactly protected.

```c
/* Proposed shape, illustrative names; emitted catalog IDs remain authoritative. */
void drop_left(struct left *node) {
    if (atomic_fetch_sub(&node->references, 1) != 1) return;
    switch (node->tag) {
    case done: break;
    case into_right: drop_right(node->right); break;
    }
    free(node);
}
/* Right can stay inline; its helper can call the forward-declared drop_left. */
```

## TDD and ownership evidence

First red: exact mutual checker failure + normal main rejection, then granular
specialization/verification expectations; only then implementation. One coherent
feature slice; a separately reviewed semantics-preserving emitter loop extraction
is allowed only if needed and counted in the same caps. Preserve all existing
unary/mixed tests. Existing reject_mutual and union_mutual_unused inputs become
accepted unchanged (exit0, no reachable layouts); update their callers/names
explicitly, never replace them with another rejection. Generic rejection cases
and the no-C failure contract remain; review the explicit first-reentry
diagnostic changes described above. Proposed help becomes
`use non-generic recursive declarations or a non-recursive generic wrapper; recursive generic declarations are not supported yet`.

| Boundary | Required independent named oracles |
| --- | --- |
| check | mutual/unused/three-member cycles, Fork, Node→Option[Node]; complete ID/type edges; unused bad/growing/constant-argument generic cycles still reject; two different generic instances; exact source/span/help/note |
| specialize/layout | enter Left or Right first; one dense row/key; no pending output; storage cycle broken, acyclic numbering/C unchanged; phantom Marker[Node] stays inline; Lists/managed-record boundaries preserve existing layouts |
| lower | fresh parent ValueIds and occurrence spans, ordered/repeated children, single evaluation; nested matches stay single level in source |
| uses | each repeated operand has correct last-use position, retained alias outlives first parent, terminal/live borrowed projection accounted for |
| own | two distinct stored owners for Fork(child,child), correct parent/child ownership classes, fresh-root reassignment retains old snapshot, exact balanced acquisitions/drops |
| raw verify | accepted indirect/multiple boxed layouts; independently malformed all-inline cycle, fake boxed/no-cycle, unknown IDs, wrong summary, reused/missing owner and missing/double/wrong drop; competing unknown-ID/by-value-cycle/record-summary errors take priority over missing boxed witness; full diagnostics |
| emit | forward prototypes precede definitions; finite by-value ordering; correct pointer access; every active field dropped; indirect/multiple helpers recurse, unary loop remains; no parent freed before fields read |
| runtime | production aggregate_runtime fragments through existing Blorp RuntimeCase/TestSuite; per-allocation ledger from aggregate_runtime_test.h for small cases; final/nonfinal, all variants, String+inline-owning child, diamond/shared tail, same child in two slots, retained tail; exact per-object frees without reading freed objects |

Before revising the checker, add paired declaration-order tests for entry
through Node and Option[Node]; direct and Option-mediated constant-argument
generic recursion; a generic root reaching an unrelated non-generic cycle;
List/record cuts; and phantom versus actual stored fields. Include distinct
applied keys, fresh generic-query completion, unused declarations and a
competing function-body error. Kill mutants that reuse shared completion for
a generic query, inherit a target across a pointer cut, omit the child-target
check, or reject every nonempty backedge. Preserve the initial fourteen
callbacks and their recorded red rather than replacing their evidence.

Use count-only wrappers for large depth runs, separately from small per-object
oracles. Construct iteratively from completed children in the approved runtime
helper C exception. No generated language functions, rewritten C, alternate
fixture main or production tracing. Build/traversal/destruction timings and
failures remain separate. Mutants must kill: ignored indirect path, phantom
argument treated as storage, unboxed Fork, one repeated slot dropped, wrong
child dropped, double drop, and recursive replacement of the unary100k loop.
The latter still fails the constrained-stack oracle for the intended reason.

## Costs, scaling, release and scope

Initial physical estimates (not permission to compress):

| Production owner | Added | Removed | Net |
| --- | ---: | ---: | ---: |
| checker/render | 15 | 48 | -33 |
| specialization | 100 | 18 | 82 |
| independent verifier | 100 | 28 | 72 |
| emission | 85 | 15 | 70 |
| Total | 300 | 109 | 191 |

Goal<=200 net; hard<=260 net and<=420 added, including any preparation.
The first source packet is +200/-84 (net116). The amended checker is estimated
at a further +45–70/-30–45, giving +245–270 added/net116–156 overall;
these are estimates, not measured acceptance or permission to raise a ceiling.
Tests excluding fixture files estimate900–1200 added; Blorp/C fixtures300–450,
reported separately, never shortened to hit a cap. No new source module expected.
Old accepted inputs and canonical host proxy: target+5%, hard+10% allocations
and normal retired instructions **per input**, existing fixture limits unchanged.
New fixture limits fixed now: mutual35k allocations/140M instructions;
Fork/shared String55k/220M; optional-wrapper40k/180M; unused-cycle20k/90M.
Cap breach stops for review; no after-measurement “plus15%” adjustment.

Freeze complete fresh baseline/toolchain/library/inputs. Three serial alternating
normal pairs, leak/stats unset outside time; strict counts/leaks separately.
All old accepted C must remain identical unless an individually reviewed
representation change is necessary; every intentional rejection flip enumerated.
At16/32/64/128 measure independent mutual groups, one N-member ring, shared
inline diamonds, literal depth and Fork arity. Report allocations/instructions
by owning phase when possible, complete compile, generated size/nesting and
default-Clang results. Expect linear local reached-query work, while existing
instance lookups and overlapping root closures may add superlinear total work;
attribute rather than assert a blanket linear bound. No cap/toolchain flag waiver.
For G generic targets, report the sum of their reached instance closures and
the O(GU) setup from fresh dense completion tables (U declarations). Existing
active/completed key scans and structural comparisons remain real costs.
Do not share facts across different query questions to conceal those costs.

Release table: mutual and branching/skewed shapes at16/32/64/128, then
1k/4k/16k/64k until the first failure, plain-O0 and ASan separately on default
and512KiB stacks. Define depth and physical allocation counts separately;
large Fork cases are skewed or share completed children, not exponentially
large fresh full binary trees. Small asymmetric trees prove both slots are
destroyed. Retain last success/first failure, object counts and exact
release stack; stop expansion on failure. Source build/walk depth is a separate
table. A failing depth is not a universal supported-language bound or a reason
to quietly add a worklist. Unary100k/512KiB remains mandatory. Match the pilot's
actual deepest shapes against measured margins before claiming readiness.

Out: own-parameter generic recursion2c, opaque types, M3 managed loops/tail calls,
new patterns, COW/in-place updates, letrec/backpatching and cyclic data. Fresh
roots only take completed children; each new parent is newer than every stored
child, so runtime sharing forms a finite DAG. Runtime mutation does not become
safe merely because RC==1. No deep source-stack claim follows from boxed data.

Reviewed wording-only corrections when this plan lands:
ROADMAP M4's managed-call paragraph should assign removal of historical call-stack
limits/shared-loop representation to **M3**, not data layout/destruction. QUALITY_ROADMAP:1035
should say M2.3 needs no **join-arm** early-return form for ?=; permitted
function-top-level propagation still needs a genuine function return plus cleanup.
Neither clarification authorizes M3/M2.3 implementation here.

After reviewed plan commit: focused owning suites via frozen host, runtime
TestSuite, one pilot build then real-main e2e atO0+sanitizers, full corpus/costs,
dynamic frontier and actual-destination `make -C blorp_2 test`. Root owns compiled
slots/integration; require root and separate expert source reviews plus independent
test runner. Hand back complete patch/hashes, production/test/fixture deltas,
red→green/mutant receipts, depth/scaling/cost tables and exact unverified limits.
Stop for broader design review on cap breach, new authority/phase/framework,
unexpected generic admission, lost error priority, cycle/placeholder leak, host
fault or inadequate measured release margin. UFCS/Boolean/constants assets stay untouched.

Concrete first feedback, after test preparation and exclusive grant (proposed
new suite/fixture paths; do not execute a nonexistent test and call that red):

```bash
m4_host=/Users/keithphilpott/.codex/worktrees/blorp-2-compiler-comparison/blorp/bin/blorp
"$m4_host" test --suite --timeout 180 \
  blorp_2/test/unit/test_check/test_recursive_union_cycles.brp \
  blorp_2/test/unit/test_specialize/test_recursive_union_cycles.brp \
  blorp_2/test/unit/test_verify/test_recursive_union_cycles.brp

# After the focused production fixes, expand to lower/uses/own/emit/runtime.
"$m4_host" test --suite --timeout 180 \
  blorp_2/test/unit/test_lower/test_recursive_union_cycles.brp \
  blorp_2/test/unit/test_own/test_recursive_union_cycles.brp \
  blorp_2/test/unit/test_emit/test_recursive_union_cycles.brp \
  blorp_2/test/runtime/test_recursive_union_cycles.brp

# Build once; e2e receives this exact binary, never builds per fixture.
"$m4_host" compile --no-format blorp_2/src/main.brp \
  -o blorp_2/build/roadmap-union-cycles/compiler.c
clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 \
  blorp_2/build/roadmap-union-cycles/compiler.c \
  -o blorp_2/build/roadmap-union-cycles/compiler -lm -lpthread
BLORP2_COMPILER=blorp_2/build/roadmap-union-cycles/compiler \
  "$m4_host" test --suite --timeout 0 blorp_2/test/e2e
```

First real-main input will be `test/e2e/fixtures/recursive/union_cycles/mutual.brp`.
Its baseline CLI is the frozen baseline pilot followed by
`--library-root blorp_2/standard_library_temp INPUT.brp OUTPUT.c`; require the
specific closing-Left failure/no C before changes and exact exit7 after native
compilation. Each suite runs callbacks and checks typed products; a parser or
host setup error is never an expected failing assertion. Final literal Make
uses the accepted destination's own verified FRESH host; the frozen host above
does not silently substitute for that destination gate.
