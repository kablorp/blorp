# Memory architecture

Status: scalar bindings, match-arm blocks and straight-line managed Strings
implemented and validated with unit, grammar, native and sanitizer checks,
2026-10-09. Exact per-object runtime observations await approval of the explicit
test mode below. Broader host-compiler gate limitations are recorded in the
[increment evidence](../benchmarks/results/blorp_2_managed_strings_2026-10-09.md).
Read [AGENTS.md](AGENTS.md) and the parent instructions first.
[README.md](README.md) owns the supported scope. Examples below distinguish
the current straight-line ownership boundary from later managed increments.

## Keep the pieces distinct

Value semantics is the source contract: assignment copies a logical value,
`var` rebinds a local, and an update cannot change another live alias. Source
mutability neither promises unique storage nor requires a heap cell. Pure
functions may use local mutation.

Perceus is a compiler transformation that places ownership operations. ARC is
the runtime mechanism those operations use. COW preserves value semantics when
an update could share storage. Allocation reuse is a later optimization using
proven ownership, compatible layouts and uniqueness at the point of reuse.
These pieces cooperate; none substitutes for the others. The
[Perceus paper](https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse-2/)
starts from explicit control flow and separates precise reference counting from
reuse and specialization; that is useful guidance, not a claim that our
implementation inherits its proof.

Knowing a reference's last use does not establish that it is the allocation's
last owner. A `drop` of shared storage decrements its count; the final release
destroys its owned children and frees its root. Where exclusive ownership is
proven, specialization may eliminate retain/release and destroy or reuse the
allocation directly. Such a proof belongs to an operation and program point;
an allocation's original freshness is not a permanent uniqueness guarantee.

Keep all planning/transformation/verification pure after source loading.
Allocation, RC changes and uniqueness checks described here happen in the
compiled target program. The compiler itself continues using local builders,
immutable published results and explicit configuration.

## Proposed boundaries

These are responsibilities, not a requirement for seven new passes or tables.
Introduce a product only when its first working example needs it. Producers may
share a traversal when measured useful, while keeping independently testable
contracts and observable outputs.

| Owner | Complete inputs | Published output and guarantee |
| --- | --- | --- |
| Checking | Parsed bodies, scope and accepted semantic types | Typed bindings, reads, assignments and exact calls; rejects reassignment of immutable bindings and invalid scope/type/purity |
| Value/control-flow lowering | Checked bodies and evaluation order | Ordered value definitions and explicit control flow; source rebinding becomes new value versions |
| Representation | Concrete semantic types and explicit storage contexts | Layout and child-ownership plans; every admitted value/slot has defined construction, copy, projection and destruction behavior |
| Call ABI | Exact callable identities, runtime-operation contracts and supported bodies | Argument transfer/borrow and result ownership contracts; callers and callees agree, without name heuristics |
| Ownership insertion | Lowered function, layout/call facts, use/liveness and alias dependencies | Explicit creation, duplication, transfer and drop operations on exact values and edges |
| Reuse/COW lowering | Ownership-explicit program and compatible layouts | Optional checked reuse or consuming update with a correct copy/allocation fallback |
| Independent verifier and C emission | Actual final program and its layout/call/runtime contracts | Verifier checks obligations and borrow lifetimes; emitter mechanically projects the verified operations to C |

The verifier must not use the inserter's placement decisions as its oracle,
repair the program, or treat unsupported cases as success. Verify the actual
output again after an ownership-changing rewrite. Initially, accepting a
managed program requires full verification of the supported subset; unsupported
shapes are internal rejection, not an unchecked emission path.

When generics arrive, specialization must supply the concrete types and callable
identities before representation-sensitive work. An unsolved semantic type is
not a layout decision.

The emitter must not invent managed owners or cleanup. Materialize ordered
arguments, projections and managed temporaries before ownership insertion.
A scalar C temporary is harmless only when its representation really has no
owned children. Any later transformation that introduces owners must expose
them and invalidate the previous verification result.

## Identity, authority and lifetime

- `BindingId` belongs to a source function and identifies a lexical binding,
  even when another binding uses the same spelling. Mutability is checked here.
- `ValueId` identifies one computed value in one lowered function.
  Reassigning a source variable changes its current value mapping, not that
  value's identity. Two source bindings may refer to the same `ValueId`.
- Future block identities and typed block parameters describe control-flow
  joins. Use SSA as the working direction; straight-line bindings do not need
  general phi construction, loops or dominance infrastructure yet.
- A concrete layout identity belongs to one representation catalog and
  specialization. A source union/declaration ID is insufficient once one
  declaration can have multiple instantiated or boxed layouts. Checked
  translations connect semantic identities to layout identities.
- Call ownership has one ABI authority separate from the semantic signature.
  Arity/type/purity facts are not copied into another competing registry.
- Use/liveness and borrow-owner relations belong to one function-body revision.
  Rewrites invalidate affected analyses; do not cache them by spelling or raw
  numeric ID alone. Verification evidence belongs to the exact final program
  and contracts, and cannot survive arbitrary rewrites.

Int and the current unions have inline storage and no managed children;
String has a managed leaf allocation. Do not generalize that into
`inline means no ownership`: future
inline aggregates could contain managed fields. Root storage and child cleanup
are separate questions. Boxing is an explicit representation transition with
its own owner; it is not guessed from the semantic type at a consuming site.
Static immortal storage is a lifetime contract, not evidence of fresh or unique
storage. The first managed fixture should allocate a mortal value so literals
cannot hide missing retains/drops.

## What bindings should establish first

Start with an immutable binding and return, then straight-line reassignment:

```blorp
func main() -> Int:
    original = 1
    var current = original
    current = 42
    original
```

The observable result is 1. Checking owns the two binding identities and the
permission to reassign `current`. Lowering maps `original` to the first value
and the final `current` to a new value. This requires no allocation, retain,
drop or runtime mutable cell. Test shadowing, initializer order, use before
definition, immutable reassignment and type mismatch. Preserve the source
variable identity for diagnostics while downstream reads use value identity.

Terminating match arms already have independent value blocks; their local
assignments require no join. Before non-tail matches, define typed block
arguments and edge transfers. Before loops, define loop-carried values and
exit edges. Avoid adding ownership logic to compensate for an ambiguous
control-flow representation.

## First managed slice

The approved working example uses concrete functions from the explicit input
prelude, without traits or general imports:

```blorp
func main() -> Int:
    value = 7.to_string()
    value.length()
```

It returns 1. `to_string(Int) -> String` creates mortal storage; `length(String)
-> Int` borrows synchronously. The prelude source is loaded alongside the
program, then parsing/checking resolves its closed builtin operations. Errors
retain their source origin. Checking owns accepted types and callable identities;
lowering owns computed values. Ownership insertion names each obligation with
an `OwnerId`, records the owner dependency of borrowed operands, and inserts
explicit acquisition, release and return transfer. Independent verification
reads those actual operations before emission can receive the program.

Initially String has one managed leaf representation and no owned children.
Parameters borrow and results return owned; owned results may alias arguments.
Straight-line aliases and rebinding are supported by value liveness, including
acquisition before releasing an aliased call argument. Existing unmanaged tail
matches remain supported. Functions combining managed values with a tail match
are rejected until branch ownership is implemented and verified.

Before editing, the baseline was frozen at `49d480ea5`: 4,651 production lines
and 43 existing valid fixtures. The implementation ceiling is 8,000 production
lines; investigate or rescope beyond it. Owned-input compilation is a proxy,
not self-compilation. Investigate repeatable allocation or retired-instruction
growth above 25% on any existing fixture. New managed fixtures initially allow
20,000 compiler allocations and 200 million retired instructions. Native target
allocation/RC observations are separate from these compiler costs.

Exact runtime lifetime observations need an explicit test boundary. The proposed
boundary, awaiting user approval, is a C compile option `-DBLORP_TEST_MEMORY=1`.
It would record allocation, retain, release and final destruction at the operation
point, using a process-local object identity distinct from compiler OwnerIds.
The existing Blorp TestSuite would run the unchanged fixture's normal `main`
and assert exact stderr events. For the first example:

```text
allocate object=0 refs=1
release object=0 refs=0
destroy object=0
```

Normal builds would produce no events. This would add no source-language test
intrinsics, alternate entrypoint, generated-C rewriting or native assertion
driver. Ordinary execution plus sanitizers is the simpler existing path, but
cannot independently observe exact nonfinal/final release behavior.

## First managed example and conservative ABI

Start with one mortal managed type and straight-line lifetimes. Prefer ordinary
synchronous parameters borrowed for the call and results returned owned, matching
the existing language contract. A returned borrowed parameter or projection
must acquire an owner before escape. An owned result does not imply freshness
or uniqueness. Defer inferred consuming clones until a measured example needs
them; runtime consuming operations still need explicit contracts from day one.

The essential reassignment case is:

```blorp
pure func identity(value: String) -> String:
    value
pure func preserve() -> String:
    var current = make_string()
    current = identity(current)
    current
```

`make_string` denotes a future ordinary operation producing mortal storage.
Evaluate the right-hand side with the old owner live; establish the result's
owner before releasing the old one. Releasing first would free a value still
needed by the call or its aliased result. A consuming ABI may instead transfer
that owner, but must never also drop it. Test both aliasing and distinct results,
and deliberately remove the required acquisition/drop to prove the oracle.

Then cover two live aliases and an update: source `var` does not prove uniqueness.
At an internal consuming update, a surviving alias must keep an owner of its old value;
shared storage takes the copy path. Dead input ownership can transfer to an
update, allowing the unique path. Runtime uniqueness is checked at use; a
historic allocation/freshness fact is not a permanent uniqueness flag.

## Keep and improve from the existing compiler

Useful, currently inspected precedents:

- [Ownership model](../docs/OWNERSHIP_MODEL.md): borrowed synchronous parameters,
  owned returns, explicit argument modes, alias lifetimes and storage transfer.
- [ownership.brp](../blorp/src/compiler/stage_09_core/ownership.brp): explicit
  argument/result variants and contract validation. Preserve the concepts;
  use resolved operation identities instead of importing string-keyed lookup.
- [record_representation.brp](../blorp/src/compiler/stage_09_core/record_representation.brp)
  and [managed_record_layout.brp](../blorp/src/compiler/stage_09_core/managed_record_layout.brp):
  decide concrete representation once and share field/storage facts.
- [Pipeline](../blorp/src/compiler/stage_09_core/pipeline.brp): ownership before
  reuse, with inspectable stage boundaries. The fused path already solves user
  contracts once; keep that benefit without coupling every phase to a broad
  mutable environment or empty placeholder authority.
- [prepare.brp](../blorp/src/compiler/stage_09_core/prepare.brp): typed cleanup
  plans and iterative cleanup for recursive unions. Require bounded-stack
  destruction before admitting recursive managed data.
- [Runtime](../blorp/src/lib/runtime/native/runtime.c): atomic retain/release,
  uniqueness and destructor dispatch. Keep a small specified ABI and test its
  implementation separately from compiler insertion.

The current `PerceusEnv` combines representation and call-contract queries;
give the pilot's consumers narrower complete products when they need them.
Also avoid repeated whole-body use scans and ownership rediscovery in emission.
Inspect actual consumers before splitting a product;
file boundaries alone do not establish independent authorities. The retained
runtime `blorp_move_ref` helper describes an older protocol coupling caller
decrements with callee entry retains; no current compiler caller was found.
Any future equivalent must have an explicit, verified ABI transition, not
depend on recognition of an assignment-shaped call.

Retained earlier investigations found missed aggregate-child protection and
expensive COW in compiler builders. Treat them as regression ideas, not claims
that those bugs remain. Tests should cover borrowed child escape, self-aliasing
reassignment, surviving aliases and selected-branch cleanup. Equal total
retain/release counts cannot prove ordering, owner provenance or safety.

## Dup/drop, ARC and exhaustive destruction

The first String slice implements these contracts for a managed leaf; scalar
bindings alone do not implement them. `dup/drop` describes ownership of a
complete value. Its
representation determines the physical work: an unmanaged value needs no RC
operation, an inline aggregate may duplicate/drop owned children, and a managed
root retains/releases its root. Retaining a managed aggregate's root does not
retain every child again; those children belong to the aggregate's lifetime.

An exhaustive compiler-side ownership-plan union can expose these operational
cases without treating Perceus as a storage category:

```text
ValueOwnership = NoOwnership
               | InlineOwnedFields(InlineOwnershipPlan)
               | ManagedRoot(ManagedLayoutId)
```

This is a derived view of the complete representation authority, not a second
field inventory or a tag added to every runtime value. Stack-local storage
can contain owned managed references. Borrowed versus owned describes a use's
obligation and lifetime, separately from whether its representation is managed.

The concrete layout authority must classify every field, not merely list the
ones a separate traversal happened to recognize as managed. An illustrative
field classification is:

```text
FieldOwnership = NoOwnedValue | OwnsValue(LayoutId)

RecordLayout:
    every declared storage field has an explicit FieldOwnership

UnionLayout:
    every variant has a complete field layout
```

Root storage and child ownership are independent. Derive destruction from this
complete layout; do not maintain a second hand-written owned-field inventory.
Validate field/variant identity and totality against the canonical concrete
shape at plan construction. No missing entry, unknown layout or unsupported
field may default to `NoOwnedValue`. An explicit leaf with no children is a
valid plan, distinct from a missing plan. Specialization must resolve generic
fields before this boundary.

For a mortal managed root, final release invokes the active layout's child
cleanup and frees the root exactly once. Specify one authority for root
deallocation in the runtime ABI; child destruction and ARC must not both free
it. Nonfinal release must not destroy children. Union destruction visits only
the active variant's fields. Inline aggregates perform child cleanup without
releasing a nonexistent managed root. Immortal storage, when supported, has an
explicit lifetime contract rather than a fabricated uniqueness/freshness fact.
Require iterative or otherwise bounded-stack destruction before admitting
recursive managed values.

Ownership insertion must account for each owner created, duplicated, consumed,
returned or dropped, including the owner's borrow dependencies. Every supported
exit transfers or discharges each obligation. Reassignment establishes the RHS
owner before retiring the old one. The independent verifier checks the actual
final operations and the complete layout/call contracts, independently of the
inserter's intended edits. A balanced RC total can still hide a leaked child,
wrong owner, wrong branch or invalid order.

Compiler verification relies on explicit runtime contracts; it cannot by itself
prove their C implementation. Separate Blorp-orchestrated runtime tests must
observe mortal per-object lifetime events, nonfinal/final release, each owned
child, each union variant, inline children and supported immortal storage.
Intentionally omit a required child drop and require the destruction oracle
and leak check to fail. Test the planner against declared shape independently
of the destructor generated from that plan, so the same omission cannot make
both producer and oracle agree. ASan/UBSan/leak checks supplement these tests.

## Phase-level test contract

Status: the straight-line String slice has direct representation, ABI, use,
ownership-insertion, verification and emission tests. Native and sanitizer
validation passes; exact per-object runtime observations await approval of the
explicit test mode above. The matrix also contains requirements for future
features, including managed aggregates, branches, COW and reuse. Add those
tests with each supported feature, before its implementation; do not build
unused passes or placeholder suites to fill this matrix. Unmanaged union
tests do not establish managed-value safety.

Every affected boundary needs small Blorp `TestSuite` cases that exercise its
public typed contract directly. Use valid minimal input builders where sealed
products require them. Parsing source is appropriate for syntax/checking and
integration tests; a liveness or ownership test should not need to parse and
compile an entire program. Keep setup outside the operation being tested.
Use one named callback per invariant or failure mode so failures identify the
responsible phase; shared setup and data-driven helpers remain useful.

| Boundary | Granular cases required when supported |
| --- | --- |
| Checking and binding identity | Immutable assignment rejected with exact diagnostic; local mutation allowed in pure functions; shadowed bindings remain distinct; initializer reads the previous binding where permitted; incompatible assignment rejected. |
| Value/control-flow lowering | Rebinding creates a new value version; old aliases still read the old value; RHS and call arguments execute in source order exactly once; joins and loop edges carry the correct typed versions. No ARC or runtime mutable cell for unmanaged bindings. |
| Representation and cleanup plans | Root storage and owned children distinguished; every admitted constructor/field has construction, copy, projection and destruction behavior; inline aggregates with managed children covered; inactive union fields never destroyed; missing layouts and cross-authority identities rejected. |
| Call ownership ABI | Borrowed arguments survive calls; consumed owners transfer once; owned returns may alias inputs; borrowed projections retain their owner relationship; each runtime operation's contract agrees with its implementation. Reject invalid argument/result relationships. |
| Uses, liveness and borrow dependencies | Last use distinguished from last spelling occurrence; branch-local uses stay on their edges; aliases and projected borrows keep owners live; unused results identified; rewrites cannot reuse analysis or verification from an earlier body revision. |
| Ownership insertion | Required duplication before borrowed escape; unused owners dropped; returns/consuming calls transfer without a second drop; reassignment establishes the RHS owner before releasing the old one; selected branches discharge their obligations. |
| Independent ownership verification | Accept valid minimal programs; reject missing acquisition, leaked owner, double drop, use after drop/transfer, borrowed escape, wrong borrow owner, and missing edge transfer. Reject unsupported shapes and stale/mismatched contracts. Equal total dup/drop counts must not hide invalid order or branch provenance. |
| COW and allocation reuse | Shared update preserves all surviving aliases; unique update uses the permitted path; uniqueness checked at use; insufficient capacity and incompatible layouts use a correct fallback; managed children transferred/retained/destroyed correctly. Reuse disabled gives the same observable values and safe cleanup. |
| C emission | Verified operations preserve evaluation and acquire/drop/transfer order; projections occur only in the selected branch; emission introduces no hidden managed owner or cleanup. Native execution independently checks the emitted behavior. |
| Target runtime ARC and destruction | Retain keeps storage alive; releasing a nonfinal owner does not destroy it; final release destroys exactly once; owned children released exactly once; mortal and supported immortal storage handled explicitly; uniqueness changes with owner count. Require bounded-stack destruction before recursive managed data. |

Collections additionally need slot insertion, replacement, removal and storage
growth tests. Loops need zero/one/many iterations, loop-carried owners and every
supported exit. Closures and resources need capture/escape and cleanup tests
when admitted. Concurrency, channels and FFI remain excluded. Each new managed
operation or storage form adds its own contract cases before acceptance; this
matrix is not proof of exhaustive future coverage.

For example, the following are separate proposed tests of different owners,
using illustrative IR notation rather than new Blorp syntax:

```text
insertion: borrowed parameter returned as owned
    input:    return borrowed p0
    expect:   acquire an owner for p0 before transferring the return

verifier: returning a borrowed parameter without acquisition
    input:    return_owned borrowed p0
    expect:   reject borrowed escape at that return

verifier: balanced counts with invalid ordering
    input:    drop v0; v1 = dup v0; return move v1
    expect:   reject use after drop despite balanced ownership totals
```

Verifier negatives must feed deliberately malformed ownership IR directly,
independently of the inserter. Keep any internal test builders separate from
published verified products; never weaken production construction guarantees
to make invalid fixtures convenient. Assert the exact violated obligation and
operation/edge, rather than accepting any error. Source-facing failures also
pin message, help and span.

Compare semantic identities, ownership relationships and safety-critical order.
Avoid whole-program text snapshots or exact retain counts where several legal
placements exist; cost ceilings are separate checks. Runtime probes use mortal
allocations, surviving aliases, and per-object lifetime events to check which
object is destroyed and when. Blorp `TestSuite` suites register the tests and
assert their exact outcomes. Prefer source fixtures compiled by the pilot and
their normal entrypoints. A native probe outside that path needs explicit
approval for a concrete supported ownership behavior, as required by
[AGENTS.md](AGENTS.md#get-approval-before-adding-mechanisms-or-implicit-behavior).
This plan does not authorize C assertion drivers in advance. No Python tests.

Each managed slice also needs a small integration fixture, generated-C
inspection, ASan/UBSan/leak checks and a deliberate mutation that fails the
protected oracle. Where shared/unique paths matter, prove both were exercised.
Keep compiler-process allocations and target-program ownership measurements
separate. Unsupported verification remains rejection; neither sanitizer silence
nor code coverage promotes it to verified support.

## Increment sequence and evidence

After composing bindings with match-arm blocks, the agreed order is value
identity versus ownership obligations, borrow dependencies, then independent
verification. These are ordered responsibilities within small executable
increments, not permission to add three speculative frameworks. Introduce
each distinction only with a supported example that needs it, publish complete
typed facts, and keep one authority for each fact. Granular tests at every
affected phase boundary are mandatory, including exact rejection cases and
deliberate invalid-operation mutations. A managed example must have all three
responsibilities integrated and verified before it is accepted; an intermediate
slice must not create an unchecked managed-emission path.

1. **Scalar bindings:** establish identity, immutable/mutable rules and ordered
   value versions, including branch-local arm blocks. Keep current unmanaged
   layout and native result oracles.
2. **One managed value:** explicit layout/ABI, ownership insertion and independent
   straight-line verification integrated together; fresh allocation, copy,
   return, unused value and reassignment fixtures.
3. **Managed matches and joins:** branch-specific obligations, payload borrowing
   and escapes, typed edge transfers; no speculative execution or blanket
   release after every match.
4. **COW and reuse:** shared/unique paths tested independently. Reuse can be
   disabled without changing behavior; require measurable benefit before
   adding specialization or indexes.
5. **Collections, loops and recursive unions:** separate working examples and
   contracts for each; define slot ownership and bounded destruction before
   expanding storage. Closures/resources remain later features.

Each managed increment needs Blorp unit/grammar/end-to-end tests, exact negative
oracles, ASan/UBSan/leak checks, C inspection and deliberate ownership mutations.
Record allocation/RC traffic and compilation instructions alongside behavior;
freeze workloads/toolchains and separate compiler cost from target-program cost.
The roughly 5× source-to-C goal does not justify skipping correctness, and does
not require every increment to introduce a new analysis or optimization.
