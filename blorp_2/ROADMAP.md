# Blorp 2 roadmap

Updated 2026-10-14. This is the single plan for aggregate composition, ownership,
generics and recursion. It replaces MEMORY_PLAN, MANAGED_RECORDS_PLAN,
GENERICS_PLAN and RECURSION_PLAN; their completed evidence remains in Git and
[benchmarks/results](../benchmarks/results/). Read both [AGENTS.md](AGENTS.md)
and the [parent AGENTS.md](../AGENTS.md).

[README.md](README.md) and [grammar.ebnf](grammar.ebnf) describe implemented
behavior. The [imports/prelude reference](IMPORTS_AND_PRELUDE_PLAN.md) describes
that implemented subsystem. Examples and unchecked milestones here are planned
capabilities, not claims that the current compiler accepts them.

The immediate goal is correctness and useful composition, not memory
optimization. Extra retains, copies and fresh allocations are acceptable.
Unique-root COW, allocation reuse, retain elimination and consuming-ABI inference
are deferred. Existing test cost guards remain; adjust them deliberately with
evidence rather than distorting the design to avoid a host-compiler cost.

## Status and order

The validated feature milestone is checkpointed as `14fc4b9c9`; reconciliation
onto the newer structural frontend, split checker and import policy is tracked
in the [integration report](../benchmarks/results/blorp_2_milestone_integration_2026-10-13.md).
The historical counts below describe their frozen feature-branch snapshots.
They do not establish that the combined branch passes until integration is
validated independently.

Already delivered: scalar bindings and local var, function recursion,
nongeneric unmanaged direct-self tail loops, bidirectional checking entrypoints
and typed errors, ordered multiple generic parameters and nested applications,
finite inline owning unions, managed Strings, Int-only fixed records, imports,
Unicode calculator operations, and borrowed argv List[String] access. The working
tree also implements mixed finite records, approved by two independent compiler
reviewers. The accepted pre-generic integration snapshot passes 1,800 strict unit/runtime/grammar
checks across 115 suites and 275 normal-main end-to-end cases, with no source
drift. This includes 20 per-object aggregate runtime cases with five verified
mutation oracles. See the
[implementation report](../benchmarks/results/blorp_2_mixed_records_2026-10-13.md).

Contextual generic-call inference/unification is accepted: one local work
loop owns temporary variables, with nested calls and uniquely resolved UFCS
context supported. Focused and frozen unit gates pass; matched costs and identical
C output establish the bounded type-reuse repairs. Two independent compiler
reviewers approve the final source and evidence; the combined live gate passes.
See the [inference report](../benchmarks/results/blorp_2_contextual_inference_2026-10-13.md).
Generic records and contextual record literals are implemented and approved by
two independent compiler experts. The final production snapshot passes 1,856
strict checks across 118 suites and 299 normal-main e2e cases, with no source
drift. Independently reviewed quiet matched allocations/instructions pass both
unchanged cost ceilings. This increment is accepted; see the
[generic-record report](../benchmarks/results/blorp_2_generic_records_2026-10-13.md).
Direct unary union payload annotations are accepted: ordinary type syntax now
resolves through the shared annotation path, with all union declarations covered
by the finite-cycle guard. Two expert reviews, mutation oracles, quiet matched
costs and final integration pass: 1,917 sanitized checks across 120 suites and
310 normal-main e2e cases. See the
[direct-payload report](../benchmarks/results/blorp_2_direct_union_payloads_2026-10-13.md).
Multiple union fields are accepted: ordered children and captures, complete
concrete layouts and independent per-slot ownership/destruction checks pass.
Two compiler experts approve the final source and evidence: 1,975 sanitized
checks across 124 suites and 321 normal-main e2e cases, plus mutation oracles,
runtime-helper checks and unchanged matched cost ceilings. See the
[multiple-field report](../benchmarks/results/blorp_2_multiple_union_fields_2026-10-13.md).
Review identified inherited repeated copying in use-vector updates and lowering
definition accumulation. The use-vector preparation is now accepted: local
updates replace per-read copies, with one possible initial terminal snapshot
copy. Two independent experts approve 1,985 sanitized checks, 321 e2e cases and
quiet matched costs with identical target C; see the
[builder report](../benchmarks/results/blorp_2_ownership_builders_2026-10-13.md).
Block-local lowering preparation is now accepted, including fresh main-rebase
validation. Recursive expression-local copying remains documented debt. The
earlier integration round stopped at its validated milestone; the next approved
implementation sequence is described below.
No whole-compiler linearity is claimed. General List construction, length and
owned lookup are accepted after the final full gate and independent evidence
reviews. Still absent: record/List updates, recursive data, and
generic/managed tail loops.
Locally owned match-prefix values are implemented for ordinary terminating
matches, with independent per-arm verification. Matched cost checks, two expert
reviews and combined integration pass; see the
[owned-prefix report](../benchmarks/results/blorp_2_owned_match_prefix_2026-10-13.md).
General non-tail joins remain restricted.
The pilot cannot self-compile yet.

The combined milestone through declaration inventory is validated for main:
2,090 sanitized unit/runtime/grammar checks and 325 normal-main e2e cases pass,
with independent component and integration reviews. Declaration IDs are issued
once in assembly; ownership classification belongs to concrete specialization;
known concrete nominal requirements reject during checking. The
[authority repair report](../benchmarks/results/blorp_2_authority_fixes_2026-10-13.md)
records the matched costs and remaining limits. Validated namespace publication
now rejects incomplete scopes before checking and removes downstream visibility
rechecks, with separately reviewed producer/provenance tests and mutation oracles;
see the [namespace report](../benchmarks/results/blorp_2_namespace_publication_2026-10-14.md).

| Order | Working increment | Dependency and verdict |
| --- | --- | --- |
| 1 | [Mixed finite records and safe field projections](#first-increment-mixed-finite-records) | Accepted: independent reviews, per-object runtime oracles, matched costs and combined strict/native gates pass. |
| 2 | [Generic records, direct full union payload types, then multiple payload fields](#finite-aggregate-frontend-increments) | All three increments, use-vector and block-lowering preparations accepted with independent reviews, strict/native gates, mutation oracles and matched costs. |
| 3 | [General List[T] construction, length and owned lookup](#general-lists-and-functional-updates) | Accepted: two expert reviews, 2,209 strict checks, 331 e2e cases, mutation oracles and unchanged matched cost ceilings. |
| 4 | [Functional record/List updates](#general-lists-and-functional-updates) | Start with fresh results and borrowed-input/owned-result contracts; old aliases stay unchanged. |
| 5 | [Unary recursive union, then mutual/regular-generic and branching mixed data](#recursive-data) | Each shape needs finite representation, acyclic values and bounded-stack destruction. |
| 6 | [Other collections and broader control flow](#broader-control-flow-and-later-scope) | Set/Dict key semantics, typed joins/edges and managed loops enter through separate examples. |

Contextual inference is a separate frontend track, not a prerequisite for mixed
records. Tail-loop follow-ups have their own dependencies below. A unary recursive
proof may proceed once its payload/type and ownership prerequisites are green;
it need not wait for every collection update API. Parallel work is appropriate
only where contracts and owned files do not overlap; each dependent slice must
be independently accepted before the next relies on it.

Every increment starts with a small real-main fixture, failing granular tests,
exact acceptance criteria and a bounded handoff under
[HANDOFF_SPEC](../docs/HANDOFF_SPEC.md). Complete one producer-to-consumer path
and remove its replaced representation in that slice. Do not introduce a cache,
registry, extra pipeline or test driver for hypothetical future needs.
The agreed excluded features and numeric-width limits remain in AGENTS.md.

### Current implementation sequence

The approved next round started at `e59346426`, incorporating main `4dcb0d20a`.
Its historical baseline passed 2,090 sanitized callbacks in 137 suites and 325
e2e cases. Namespace and block-lowering preparation are now rebased onto main
`d411c7bb0`: fresh required-instruction gates pass 2,120 unit/runtime/grammar
callbacks in 138 suites and 325 normal-main e2e cases. Incoming main changes and
all reviewed source/test hashes are preserved; both preparations pass the
unchanged matched cost ceiling. See the
[rebase receipt](../benchmarks/results/blorp_2_main_rebase_2026-10-14.md).
Each slice is independently reviewed and accepted before a dependent slice uses
it. Namespace and lowering preparation have disjoint frontend/Core ownership;
implementation and design may proceed in parallel, but compiled validation and
measurements remain serialized. The coordinator owns integration and this plan.

1. **Validated namespace publication.** Complete authority-repair part B:
   `build_namespace` publishes either complete valid scope facts or a nonempty
   typed failure. Expand implicit prelude exposures before validating visibility.
   Remove the replaced checker uniqueness/direct-visibility authorities in the
   same slice. Keep accepted signatures, receiver compatibility and expected-type
   constructor selection in checking; distinct union owners may share a spelling.
   Accepted with fresh current-main validation; see the
   [namespace publication report](../benchmarks/results/blorp_2_namespace_publication_2026-10-14.md).
2. **Bounded lowering preparation.** Keep the growing block definition vector,
   binding map and cursor in their local block owner. Lower each expression into
   its own completed chunk and merge it once at the block boundary, preserving
   exact evaluation order, ValueIds, binding versions, branch isolation and public
   lowered IR. Keep expression traversal unchanged in this slice: its existing
   wide/deep construction costs remain explicit follow-up work. The measured
   expression-task prototypes increased work and source complexity and were
   rejected. Prove unique block accumulation in generated C and measure statement
   width separately from expression width/depth. No general IR rewrite or
   speculative traversal framework is authorized.
   Accepted with fresh current-main validation; see the
   [block lowering report](../benchmarks/results/blorp_2_block_lowering_2026-10-14.md).
3. **General List construction and access.** Start with the standard library's
   `repeat[T](elem: T, n: Int) -> List[T]`, plus generic length and owned
   `Option[T]` lookup. A list containing the same mixed record twice exercises
   per-occurrence ownership; returning an element and then its String field
   exercises survival after parent retirement. The intrinsic signatures and
   accepted element facts need an explicit reviewed contract: this is broader
   than the previous nongeneric String-only builtins. Nonpositive counts produce
   empty lists. Add no list-literal syntax or update API to this first example.
   Implemented with typed concrete slots, per-occurrence acquisition/destruction,
   granular phase tests and 24 native runtime cases. The final required-instruction
   gate passes 2,209 unit/runtime/grammar callbacks and 331 e2e cases. Final source
   and evidence reviews approve; this increment is accepted. See the
   [general List report](../benchmarks/results/blorp_2_general_lists_2026-10-14.md).
4. **Fresh-result updates.** Add record update, then List append, replacement
   and removal through separate fixtures. Borrow inputs, acquire each surviving
   or replacement stored occurrence, allocate a new result and preserve every
   old alias. Keep unique-root mutation, COW/reuse and consuming-ABI inference
   deferred.
   Record updates are implemented with complete typed field partitions and
   existing ownership/runtime operations. The required gate passes 2,282
   unit/runtime/grammar checks and 334 e2e cases. See the
   [record update report](../benchmarks/results/blorp_2_record_updates_2026-10-14.md).
   List append, replacement and removal remain separate following increments.
5. **Recursive data.** Begin with the existing unary Nat example and iterative
   final release; then separately admit mutual, regular-generic and branching
   mixed shapes. Reserve instance identities locally and publish only complete
   layouts. Constructors accept completed children, so values remain finite
   DAGs. Every newly admitted release graph must have bounded C-stack use;
   mutually recursive release helpers alone do not meet that requirement.

For each preparatory refactor, freeze a matched same-toolchain baseline and
require identical existing target C and at most +3% allocations/minimum retired
instructions per frozen input. Namespace part B targets a production reduction;
lowering preparation stops for design review above +50 production lines or a
wider algorithmic change. Feature increments may change emitted C and increase
costs: set their numerical fixture limits before implementation, measure scaling
on 16/32/64/128-size examples, and report new-feature work separately from the
shared existing corpus. Until self-compilation works, these are owned-input CLI
proxies, not self-compile evidence. Existing fixture ceilings stay unchanged
unless a measured adjustment is reviewed explicitly.

Every affected phase gets granular typed-input/output tests. Insertion and raw
verification have independent tests; runtime-helper tests observe individual
objects and stored occurrences; mutations prove the protected failure is caught.
Real-main e2e, sanitizers and balanced totals supplement those oracles. A worker
reports an ambiguous boundary, unexpected cost or scope expansion before adding
a mechanism. The next slice starts only after independent code and test review.

## Identity and immutable facts

These are responsibilities within the existing pure pipeline, not a demand for
new passes or tables. Local builders may be mutable and incomplete; published
results are complete, typed and immutable. After explicit source loading, all
compilation and diagnostic rendering remains pure.

| Consumer question | Authority and lifetime |
| --- | --- |
| Which source binding is this? | Function-owned BindingId; rebinding changes its current value mapping, not the identity of a computed value. |
| Which declaration/field/variant was accepted? | CheckedProgram, with declaration-owned IDs, exact accepted types and owner-qualified field/variant identities. |
| Which concrete instance is used? | SpecializedProgram, keyed by declaration identity and complete ordered concrete arguments, never spelling or physical ABI equality. |
| How is it stored and what does it own? | A complete representation derived from the concrete shape and storage policy; every stored slot appears, even if cleanup is trivial. |
| Which computed value is used? | Function-local ValueId in one lowered body revision; aliases may share it. |
| Which lifetime obligation is used? | OwnerId, or a borrow backed by a live owner/parameter; distinct storage occurrences need distinct obligations. |
| How do callers/callees agree? | Explicit argument/result ownership contracts, separate from the sole semantic call signature. |
| Which control-flow edge transfers values? | Typed block/edge parameters when joins/loops need them; do not compensate for ambiguous control flow in ownership insertion. |

Resolve calls once; lowering must not repeat name resolution or signature checks.
Keep names for diagnostics and ABI projection. Use checked translations between
identity domains. Rewrites invalidate affected use/liveness and verification
facts; reverify actual ownership-changing output before emission.

While one concrete instance has one representation, its existing instance ID
can identify that layout. Introduce another identity domain only when an actual
consumer must distinguish multiple layouts. No second semantic field catalogue,
hand-maintained managed-field inventory or missing-layout-as-unmanaged fallback.

IDs are interpreted within their owning published program. Raw verification
checks membership, nominal owners and layout consistency against that program;
it cannot infer historical provenance when an equal integer was copied from
another compilation. Negative tests must exercise distinguishable wrong owners
or incompatible layouts, rather than claim equal-ordinal foreign IDs are rejected.

## Ownership and destruction

Value semantics is the source contract: assignment copies a logical value and
var rebinds a local. Source mutability promises neither unique storage nor a
runtime mutable cell. Pure functions may mutate locals.

Perceus describes compiler placement of ownership operations; ARC is their
runtime mechanism. COW/reuse are optional implementation techniques for updates.
A last use of one reference is not proof that the allocation has no other owners.

Storage and child ownership are independent:

- Int, Float and Void require no ownership operations.
- Inline aggregates can own managed children; dup/drop visits their active
  owned fields without releasing a nonexistent root.
- Managed values retain/release their root. Nonfinal release touches no children;
  final release destroys each owned stored occurrence and frees the root once.

Preserve the parent storage rule: ordinary record is always managed. Fixed record
is inline only for recursively eligible numeric/Char fixed-record fields;
otherwise it is managed. Char is not yet in the pilot. Thus a record containing
Option[Int] or Void can have a managed root without owning child allocations.
Phantom generic arguments are not stored children. Mortal, immortal and boxed
storage must have explicit lifetime contracts, never inferred freshness flags.

### Required ownership invariants

Use these Swift-inspired verification rules in the existing IR, without importing
SIL's entire ownership lattice or adding a general borrow-checking framework:

1. Every locally created/acquired obligation has exactly one terminal action on
   each reachable return path: drop or transfer into storage, a consuming call
   or the result. Ordinary borrowed calls do not consume it. No use follows its
   consumption. Future loops/joins must explicitly carry obligations on edges.
2. A borrow is backed by a live owner/parameter for its entire use. A projected
   borrow depends on its immediate parent; selector identity stays in the typed
   projection operation. Acquisition validates that dependency while it is live.
3. After acquisition, later uses can depend on the new owner independently of
   the old parent. Do not leave source selection pointing only to a dead parent.
4. Each owning storage slot receives one obligation, including repeated pointers.
   One OwnerId cannot be consumed into two fields. Each active slot is destroyed
   once; inactive variants and uninitialized storage are never destroyed.
5. Reassignment/update establishes all replacement obligations before retiring
   old storage. Returning an alias/projection acquires an owner before escape.
6. Verification reads actual operations and complete layout/call contracts,
   independently of insertion's intended edits. Unknown shapes reject; emission
   neither repairs ownership nor invents cleanup. Reverify after changing it.

Compiler verification relies on runtime contracts; it cannot prove their C
implementation. One generated release authority owns final child cleanup and
root deallocation. Test layout completeness against accepted declarations
independently of cleanup generated from that layout. Balanced retain/release
totals can conceal wrong-object releases, leaks and invalid ordering.

Keep ordinary synchronous parameters borrowed and results owned initially. An
owned result may alias its argument and need not be fresh. Runtime consuming
operations, if introduced later, must carry explicit contracts across callers
and callees. Conservative acquisition and copy are correct defaults.

## First increment: mixed finite records

Working fixture [mixed.brp](test/e2e/fixtures/record/mixed.brp):

```blorp
fixed record Entry { count: Int, ratio: Float, text: String }

pure func make_entry() -> Entry:
    { count = 7, ratio = 2.5, text = 42.to_string() }

pure func escaped_text(value: Entry) -> String:
    value.text

func main() -> Int:
    escaped_text(make_entry()).length()
```

Expected exit 2, empty stdout/stderr. The escaped String survives retirement of
the temporary Entry. Companion fixtures must observe count and ratio, store one
mortal String in two fields, and compose nested records with finite unions.

Admit all currently supported finite concrete field types: Int, Float, String,
Void, List[String], existing fixed records and instantiated finite unions.
Void uses the existing canonical zero-ownership C carrier. Keep nongeneric
fixed-record syntax; generic records, updates and recursive types come later.

Before recursion support, reject self/mutual type references before recursively
expanding child layouts. Cover unused/pass-through declarations and
record -> instantiated union -> record cycles with exact typed diagnostics.
Phantom-only recursive references may conservatively remain deferred; diagnose
unsupported recursive types, not cyclic runtime values. Ordinary phantom
String/record arguments must not introduce child obligations.

### Complete source path

The working-tree implementation carries these facts through the existing phases;
validation and final integration status are tracked above.

| Boundary | Published fact and responsibility |
| --- | --- |
| [Checked facts](src/check/check_model.brp), [declaration checking](src/check/check_types.brp) and [expression checking](src/check/check_values.brp) | Declaration-owned field identities and complete accepted field types; contextual literal and projection checking. |
| [Specialization](src/specialize/specialize.brp) | Concrete field types and InlineRecord/ManagedRecord representation derived from the complete shape. |
| [Ownership insertion](src/own/own.brp) | Independent stored-slot obligations and explicit projection acquisitions. |
| [Verification](src/verify/verify.brp) | Independent layout, receiver-lifetime and sequential transfer validation. |
| [Emission](src/emit/emit.brp) | Typed storage, mixed dependency order and root/field destruction from verified facts. |

Each accepted field retains its concrete type and identity:

```text
Entry: managed root
    count -> IntType,    no child cleanup
    ratio -> FloatType,  no child cleanup
    text  -> StringType, owns one String obligation
```

[Lowering](src/lower/lower.brp) evaluates field initializers once in written order,
separately from storage order. Mixed inline record/union dependencies use one typed
C definition order. Existing Box[T] instantiated with Entry becomes an owning
inline union and duplicates/drops Entry's root. Unused/pass-through layouts need
coverage as well as constructed ones at each affected boundary.

### Conservative construction and projection

Acquire independently for each owning slot; direct last-use transfer is optional
where already sound. This handles duplicate children without move heuristics:

```text
text = to_string(42)                           owns o0
left_owner  = acquire(text, o0)
right_owner = acquire(text, o0)
pair = construct { left <- left_owner,
                   right <- right_owner }     owns o3
drop o0
```

Ordered per-slot acquisitions/consumptions replace the former single optional
acquisition. StoredPayload is the common stored-slot contract for records and
unions; Lists must reuse it when construction is admitted. A definition-position
last-use test cannot authorize transferring one obligation twice. Sequential raw
transfer verification uses a local owner vector and publishes once, so validating
each field does not repeatedly copy the whole vector.

Prefer immediate acquisition for managed projections:

```text
parent = make_entry()                          owns o0
child = project(parent, Entry.text)            borrows parent
o1 = acquire(child, projected-parent = parent)
drop o0
use child backed by o1                         parent is no longer needed
return_owned child, o1
```

Subsequent uses must select the acquired owner as their backing lifetime. Test
a call after parent drop, a nested projection after intermediate-parent drop,
and returned/stored child escape. Unmanaged fields are copied while the parent
is live. The independent verifier must also validate a managed receiver's live
backing when the projected result is unmanaged: reading a numeric field through
an acquired child after grandparent retirement is valid, but reading it after
the child's acquired owner drops is invalid. Rebasing insertion's private source
list alone does not establish this; verified operands must expose or independently
resolve their current backing. Keeping a projected value borrowed instead is a later option requiring
complete transitive ancestor liveness and independent verification.

Initial red/green path, after creating the fixture:

```sh
make -C blorp_2 test-compiler
blorp_2/build/compiler --library-root blorp_2/standard_library_temp \
  blorp_2/test/e2e/fixtures/record/mixed.brp blorp_2/build/record-mixed.c
```

Pin the current non-Int declaration rejection, help and span before changing it;
then require successful native exit 2 through the normal e2e harness.

## Typechecking and specialization

Generic bodies are checked once with rigid declaration-owned parameters,
including unused bodies. Calls record complete checked substitutions.
Specialization translates signatures, bindings, calls, constructors and patterns
into concrete identities before lowering. All ordered type arguments belong in
the instance key, including phantom arguments, even when layouts coincide.
Substitution is simultaneous; supplied caller-owned parameters are not treated
as fresh callee parameters.

The publication boundary remains `Result[CheckedProgram, CheckFailure]`:
a complete checked program or an opaque failure with a nonempty typed error
collection and its sealed parsed authority. Render semantic error variants,
identities, expected/actual types, argument positions and spans separately.
No temporary inference variable, tentative substitution or mutable builder escapes.
A checked generic body may contain its rigid parameters; concrete specialization
must eliminate them. Checking currently stops at the first error; collecting
independent failures needs an explicit recovery policy, not partial acceptance.

### Finite aggregate frontend increments

1. Generic records reuse ordered parameter identities and complete substitutions.
   Test distinct instances, parameter positions, nominal separation and phantom
   arguments independently of memory behavior.
2. Completed: union payloads use ordinary TypeSyntax, admitting direct
   record/String/Float/application payloads through shared annotation resolution.
   Users no longer need a generic wrapper to express a concrete payload.
3. Add multiple constructor fields separately, with ordered evaluation and the
   same stored-slot obligations as records and Lists.

Each syntax increment needs parser/ergonomics input, updated EBNF conformance and
documenter review. Broadening accepted payloads must not bypass ownership checks.
The pilot's fixed-union synonym already permits managed payloads; any stricter
checked-fixed semantics is a separate language decision.

### Contextual inference

The checker uses private expression-local structural unification, accepted with
the evidence tracked above. It solves argument constraints
before declared expected results, keeping caller-owned parameters rigid.

The first working example is:

```blorp
fixed union Choice[T]:
    Empty
    Value(T)

pure func empty[T]() -> Choice[T]:
    Empty

pure func make_choice() -> Choice[Int]:
    empty()
```

The declared result constrains the call's type argument without a default type.
Private fresh call variables and an occurs check establish complete substitutions.
Nested pending calls may use later sibling evidence. Known nominal heads and
uniquely resolved UFCS contracts supply constructor hints; variant spelling and
overload result types do not select owners. Sticky readiness distinguishes closed
nested errors from descendants whose ambiguity must wait for enclosing evidence.
Preserve child-first completion, source-order conflicts and diagnostic origins
independently of union-find representatives. New bindings and match scrutinees
synthesize without containing-function result context; discarded Void tails do
not constrain their expressions.

Test rigid versus solvable variables, independent calls, substitution chains,
nominal mismatch, occurs failures, nested calls, expected-result/argument
conflicts and unresolved phantom parameters. Typed errors retain stable facts
and constraint origins without pointing into mutable inference state. Explicit
call type arguments, implicit let polymorphism, traits/bounds, higher-kinded types
and polymorphic function values remain deferred.

## General Lists and functional updates

List[T] storage and operations consume the complete concrete element layout;
no String/numeric whitelist or universal Any carrier. Start with construction,
length, owned Option[T] lookup and exhaustive release. Successful lookup copies
an unmanaged element or gives an owning element an independent obligation;
absent lookup owns no child. Preserve argv
List[String] and normal entrypoint conventions.

### First List contract and acceptance

Start with `repeat`, generic `length` and owned `get`, without adding expression
syntax or update APIs. The first real-main fixture uses pure helpers:

```blorp
import:
    list: repeat, length, get
    int: subtract, to_string
    io: print

fixed record Entry { number: Int, text: String }

pure func make_entry(text: String, number: Int) -> Entry:
    { number = number, text = text }

pure func selected_entry() -> Option[Entry]:
    values = repeat(make_entry("kept", 7), 2)
    values.get(values.length().subtract(1))

pure func number(value: Option[Entry]) -> Int:
    match value:
        Some(entry): entry.number
        None: -1

pure func text(value: Option[Entry]) -> String:
    match value:
        Some(entry): entry.text
        None: "missing"

func main() -> Void:
    selected = selected_entry()
    print(to_string(number(selected)))
    print(text(selected))
```

Expected stdout is `7\nkept\n`, exit 0 and empty stderr. A separate fixture
uses a String produced by `Int.to_string`, alongside literal-byte Strings.
Both have allocated roots today; static literal bytes are copied into a root.
Normal-main output alone cannot prove destruction. Phase tests prove parent
retirement before escaped child use, while direct helper tests independently
observe actual allocation/free.

The sole phase-neutral runtime contract gains an element parameter. Accepted
List operations carry E: `ListRepeat(E)`, `ListLength(E)` and
`ListGet(E, roles)`. Checking extracts E from the resolved header and validates
all parameter/result positions against that contract before publishing it.
Valid concrete and generic wrappers, including structured E such as `List[T]`
or `Pair[T,U]`, use ordinary declaration-owned parameters and substitution.
Some/None roles are compile-time constructor identities from the declared
result union, not callbacks or runtime arguments. Other runtime intrinsics
retain their nongeneric restriction. Malformed headers retain their parsed
operation for diagnostics rather than inventing an E.

Source calls remain ordinary user-function wrappers; their checked builtin
bodies carry the accepted runtime operation. Specialization prepares nested E
and its nominal instances, substitutes it and translates result roles once.
Remove String-only admissibility summaries and their threading in the same
slice. Preserve simultaneous substitution, pure-Void rules, finite/increasing
type-cycle checks and the entrypoint's exact `List[String]` restriction.
Every currently supported finite concrete E is valid, including Void, numeric
values, inline and owning unions, records, Strings and nested Lists. Independent
raw-IR verification validates nested nominal membership even for unused or
pass-through List values; root ownership cannot conceal a missing child layout.

Runtime storage has concrete typed slots. Successful get returns presence
separately from the copied/acquired E; zero, Void and empty values remain valid
present payloads. Repeat clamps nonpositive counts before unsigned conversion,
checks allocation size without negating INT_MIN, acquires each stored occurrence
and publishes only initialized logical length. Nonfinal root release drops no
children; final release drops each initialized occurrence exactly once.
Construction's internal early length assignment followed by complete infallible
initialization is observationally equivalent today: inspect publication order
in C and mutate an advertised length exceeding initialized slots for the native
failure oracle. Add no tracing hook to manufacture that observation.

A disposable emitter-local inventory derives needed List element types from
aggregate fields, signatures, all definitions/arms and runtime-operation E.
It owns no layouts or identities. Current concrete types have unary List nesting
over primitive or nominal instance identities, so depth plus typed terminal
kind/identity is a complete key. Derive suffix keys in one walk, use existing
stable host sorting from terminal identity through kind to depth, then dedup
complete keys. Test equivalence with semantic type equality, including equal
raw ordinals in different domains and phantom nominal instances. Project C names
directly from semantic types/keys; no per-value linear inventory lookup, ABI
string keys or preprocessor dedup. This temporary host sorting dependency does
not establish bootstrap readiness. Emit root declarations before aggregate
ownership helpers and complete typed List bodies after aggregate layouts.

Before propagating the new carrier, inspect its generated host C and measure
construction/access/destruction, including scalar variants carrying no E.
The feature's working target is **at most 5%** additional allocations and
minimum retired instructions on each frozen shared input; **10% per input** is
the hard investigation/rejection ceiling. This is a feature budget, not a change
to the preparations' 3% ceiling or existing e2e ceilings. No average may conceal
an individual breach. Shared-input native behavior and ownership must agree;
target C may legitimately change with the generalized helper ABI. Bootstrap
identity checks apply where the compiler can perform them; the pilot still
cannot self-compile.

Measure runtime slot counts 16/32/64/128 separately from source call-site counts,
distinct E counts and nested List depth. Runtime count must not grow helper C
size: one root allocation and exactly n applications of E's stored-occurrence
duplication/drop contract. Owning E acquires/releases each active child obligation;
unmanaged E copies without child ownership operations.
Avoid new depth quadratics when gathering suffixes or projecting child names.
Record actual production/test line changes separately; forecast net production
growth is 250–500 lines after removing obsolete admission work. Widening beyond
that forecast calls for scope review, not compressed code or deleted tests.
Granular contract, checking, preparation, lowering, ownership, verifier,
emission and per-object runtime callbacks follow the phase matrix below, with
genuine failing tests and specific mutation oracles before independent review.

The Go slice lesson translates to these ARC invariants:

- Logical length and initialized owned slots are explicit, separate from capacity.
- Publish a constructed root only after its admitted slots are initialized.
  Never read or destroy uninitialized spare capacity.
- Removal/replacement/growth accounts for each old element obligation exactly
  once and each new stored occurrence independently, including duplicate pointers.
- Vacated/moved-from slots no longer own elements. ARC does not require copying
  Go's GC-oriented zeroing rule; it requires correct initialized-slot boundaries
  and no later access/drop of a retired obligation.

### Fresh record updates preserve existing aliases

#### Problem

The pilot constructs and reads records, but cannot express a fresh update. Its
lexer does not recognize `|` (`blorp_2/src/lex/lex.brp:446–509`); the parser only
accepts literals after `{` (`parse.brp:765`, `1599–1608`). This program should
print exactly `42\n7\n`, exit 0, and write no stderr:

```blorp
import:
    list: repeat
    int: to_string
    io: print
fixed record Entry { number: Int, text: String, values: List[Int] }
pure func make_entry(number: Int) -> Entry:
    { number = number, text = number.to_string(), values = repeat(number, 2) }
pure func replace_text(value: Entry) -> Entry:
    { value | text = 7.to_string() }
func main() -> Void:
    old = make_entry(42)
    alias = old
    fresh = replace_text(old)
    print(alias.text)
    print(fresh.text)
```

After implementation, run it through the normal e2e harness, not a C driver
calling generated language symbols. Before implementation, root captures a
behavioral red: a TestSuite callback expects this input to check successfully.
The source-derived baseline failure is `unsupported character` at `|`, with
help `use ASCII function declarations and numeric literals, parameter names,
or calls; keep -> adjacent`. This spec has not executed that reproduction.

A separate fixture uses the same imports, Entry and make_entry, with a reverse
replacement order and actual IO (expected `base\ntext\nnumber\n7\n7\n`):

```blorp
func traced_base() -> Entry:
    print("base")
    make_entry(42)
func traced_text() -> String:
    print("text")
    7.to_string()
func traced_number() -> Int:
    print("number")
    7
func main() -> Void:
    fresh = { traced_base() | text = traced_text(), number = traced_number() }
    print(fresh.number.to_string())
    print(fresh.text)
```

#### Background and dependencies

General List[T] is accepted in `85834e15f`. This is the next bounded design;
production implementation starts after this plan is reviewed and committed. Root
retains a source-matched native baseline, owns FRESH-host checks and serializes
compiled validation. All current finite field classes are in scope.

Parent `docs/GUIDE.md:1273–1279` and `docs/GRAMMAR.md:1128–1154` already specify
base once, replacements in written order, then field writes. Pilot rules remain
narrower: one-line braces, at least one replacement, no trailing comma, no field
assignment, no recursive/empty record declarations, and only `fixed record`.
Record updates preserve the base's nominal type and type arguments; replacement
names never infer an owner. All currently supported finite field types work,
including Void, numeric values, String, inline/owning unions, records and List[E].

#### Proposed solution

Use ordinary projections and complete construction, always fresh for managed
records. No uniqueness test, COW/reuse branch, or new runtime operation.

1. Parser publishes `RecordUpdateExpression(base, replacements)` with existing
   `ParsedRecordField` rows in written order. Add a named `RecordUpdateBar` symbol.
   After `{`, a name followed by `=` selects the existing literal path; otherwise
   parse one ordinary value, require `|`, then require nonempty replacement fields.
   Existing empty-literal, postfix, whitespace/comment and brace-span rules stay.
2. Checking elaborates the base first, using the ordinary expected result type
   when available. Its nominal record head must be established before resolving
   fields; ordinary inference may still solve generic arguments from replacements.
   Keep the base pending until those constraints are solved; elaboration is not
   an early freeze. Preserve its parsed `ValueExpression.span` explicitly. Resolve each
   replacement once to its declaration-owned FieldId and instantiated expected
   type. Validate duplicate ordinals before RHS elaboration. Build the disjoint
   complement in one declaration-field pass, then freeze complete typed data.
3. Specialization translates the base, replacements and inherited projection
   types/FieldIds once to the same concrete record instance. Include their
   children in all existing preparation and call/recursion traversals.
4. Lower the base once; lower all replacement RHSs in written order; project
   inherited fields in declaration order. Append the replacement values, then
   the inherited reads, into one `RecordFieldValue` vector for the existing
   `ConstructRecordValue`. Emission names each field, so storage order is
   evaluation order. No field spelling or type lookup occurs here.
5. Existing ownership insertion, independent verification and emission consume
   those ordinary operations without a new update opcode or semantic authority.

#### Code and fact ownership

Checked construction is one expression node, `CheckedExpr { form, value_type,
span }`, whose `CheckedForm` includes:

```blorp
fixed record CheckedRecordField { field: FieldId, value: CheckedExpr, span: Span }
fixed union CheckedForm:
    ConstructRecord(RecordId, List[CheckedRecordField])
    UpdateRecord(RecordId, CheckedRecordUpdate)
    -- other existing forms
```

The update product is:

```blorp
fixed record RetainedRecordField { field: FieldId, value_type: TypeRef }
fixed record CheckedRecordUpdate {
    base: CheckedExpr,
    base_expression_span: Span,
    replacements: List[CheckedRecordField],
    inherited: List[RetainedRecordField]
}
```

`replacements` contains only written/evaluated RHSs in source order; `inherited`
contains only omitted fields in declaration order. These are disjoint rows,
not parallel arrays. Construction verifies one exact partition of the base
record's fields: owner, bounds, uniqueness and coverage. The inherited TypeRef
is an occurrence projection type, analogous to a field read's `value_type`, not a
second layout catalogue. The `UpdateRecord` node owns the update's result
record type in its `value_type` and carries its declaration as the form's
`RecordId`, as `ConstructRecord` does; an outer postfix is a separate node
whose type may differ. The node's `span` is the update's own occurrence, carried
through unchanged to the concrete `UpdateRecord` node (`ConcreteExpr`,
`specialize.brp`). Copy the parser-owned complete
base-expression span (`syntax.brp:196–201`) to `base_expression_span`, including
the base's own postfixes, while publishing the checked update. No reconstruction,
expression-ID domain, optional published
type or insertion-policy flag is needed. These IDs live in one compilation.
Only the existing checked-program producer publishes this product.

The concrete counterpart, `UpdateRecord(RecordInstanceId, ConcreteRecordUpdate)`,
substitutes `ConcreteExpr`, `ConcreteRecordField`,
FieldInstanceId and concrete TypeRef and carries the unchanged
`base_expression_span`. Its complete partition survives translation;
phantom arguments remain part of nominal instance identity. Projected omitted
fields and update-base errors use that full base-expression span because omitted
fields have no written names. Existing child node spans remain unchanged.

Current lowering (`lower_record_fields`, `lower.brp:228–255`) evaluates written
fields; the construction arm then emits:

```blorp
Ok(define_value(current, ConstructRecordValue(owner, values), value_type, span))
```

The update consumer reuses this final operation; its algorithm is:

```text
base = lower_value(builder, bindings, update.base)       // exactly once
fields = lowered replacements                          // written order
for retained in update.inherited:                      // declaration order
    child = define_value(current,
        ReadRecordFieldValue(retained.field, base.value),
        retained.value_type, update.base_expression_span)
    fields.append({ retained.field, child.value })
define_value(current, ConstructRecordValue(owner, fields), result_type, span)
```

Checking guarantees that `replacements` and `inherited` partition the record's
declared fields, so lowering needs no ordinal table and no completeness check.
Own, verify and emit identify each stored value by its FieldInstanceId; emission
writes designated initializers, so the field vector's order is not a layout.
Ownership insertion acquires stored children and numbers their owners in the
field vector's order, so for an update that order is the replacements as
written, then the inherited fields; behaviour does not depend on it
(`record/update/managed_reorder.brp` covers two managed fields out of order).

The sketch describes local construction, not a new public freeze API or helper
framework. Carry the full existing FieldInstanceId in each field value; never
manufacture it from an ordinal. Publication preserves all ValueIds/types,
exact base/RHS/projection spans, and the function's existing allocator.
Lowering a call base once produces its normal argument definitions and one call
definition. A binding base reuses its existing ValueId (`lower_value`, `lower.brp:296–298`),
without an extra alias definition; pin both cases independently.

Current `own.brp:434–464` acquires a stored child obligation for **every** owning
record field, then transfers it into `OwnedPayload`; `558–698` first acquires
an independent temporary for a managed field projection. Changed RHS owners are
also copied for storage and subsequently dropped at last use. Preserve this
acquire-then-drop protocol: there is no `CopyStoredPayload` variant and no direct
changed-owner transfer optimization in this slice. A retained managed child can
outlive its base because its projection obligation is acquired before the base
can retire; stored acquisition precedes constructing the fresh root.

All-replaced updates may retire an otherwise unused base earlier, after its true
last use. Do not force it live until construction when no dependency remains.
For unmanaged inline numeric records there is no root/child RC. Managed records
(including Void/unmanaged-union records) allocate exactly one fresh result root.
`emit.brp:717–747` already implements that constructor with malloc/refcount 1;
`754–806` emits ordinary field-designated construction/projection. It does not
evaluate language RHSs in C initializers: their ValueIds are already defined.

#### Scope and ownership

Implementation owns `syntax`, `lex`, `parse`, `check_model`, `check_values`,
`check_errors`, `check_render`, `check_recursion`, `specialize`, and `lower` in
`blorp_2/src/`, plus matching tests and README/EBNF/conformance updates. Required
closed-tree consumers include `check_model:448`, `check_recursion:68`,
`specialize:1158,1569`; omitting an update child would hide calls or layouts.
Existing own/verify/emit/runtime production is expected unchanged; a discovered
required production change there stops for a separately reviewed correction.
Raw ownership and native-helper tests may be delegated to a separate expert
after the checked/concrete product is sealed. Root owns roadmap/report/Git,
serialized compilation, measurements and final integration.

No List update API, record spelling change, generic constraint solver, general
expression-tree rewrite, CPS/SSA redesign, cache/index/registry, new layout
catalogue, host change, consuming ABI, COW/reuse or production tracing.

#### Risks, costs and stop rules

Base evaluation must precede RHSs, even with all fields replaced. Distinguish
immediate base-elaboration errors (unknown value, impurity, nonrecord head) from
delayed freeze errors (unsettled generic arguments). Extend existing inference
work actions and child-first freeze, rather than recursively invoking a second
checker, prematurely freezing the base, or discarding inference slots. Preserve
priority: immediate base errors; then all replacement name/duplicate errors in
written order; then RHS/constraint errors and delayed ordinary freeze errors.
Expected types cannot make
an incompatible base a different nominal record. No source spelling survives
into specialized/lowered update data.

This **unit-only** accepted input proves that the base head can be known while its
type argument is unsettled, with no outer hint on the update initializer:

```blorp
fixed record Box[T] { value: T }
pure func seed[T]() -> Box[T]:
    seed()
pure func inferred() -> Int:
    updated = { seed() | value = 1 }
    updated.value
func main() -> Int:
    0
```

The typed update must be Box[Int], and its base's accepted call must instantiate
seed with Int through the replacement constraint. The seed implementation is
nonterminating; this is checking/phase-test input only, never an executed fixture.
A sibling input replacing `value` with unknown `missing` must produce
UnknownRecordField at `missing` before CannotInfer/UninferableTypeParameter.
Keep seed's forwarding body so ordinary return-context inference is exercised.
Normal-main fixtures above remain terminating.

After one name resolution per replacement, new partition and lowering work is
O(F+R), with F fields and R replacements. Current `resolve_record_field` calls
linear `find_field` (`check_values:110–121`), so total existing lookup work is
O(F×R); disclose that inherited mechanism. Use direct ordinal marks/slots for
duplicate/complement/construction work, never a per-field replacement scan.
Inherited expression-builder COW and aggregate emitter prefix copying remain
debts; do not claim whole-compiler linearity. Measure fixed-R field width,
R=F, and many independent update statements at 16/32/64/128; stop if the feature
adds quadratic work beyond the equivalent explicit projection/construction path.
Do not add an unmeasured lookup index to conceal that result.

Root-approved feature policy: unchanged shared36 inputs target ≤+5%, hard +10%
**each input** for allocations and minimum retired instructions, matched
fresh-host/O0 runs. New fixtures initially propose 25k allocations/150M instructions for
the small Entry case and 35k/180M for the traced case; confirm from retained
first-smoke evidence before registration, keeping all old ceilings unchanged.
Forecast +220–320 handwritten production lines and +450–800 tests; stop above
+350 production for design review, or for widened files/model, unexplained cost,
missing ownership proof or a host defect. The line threshold is never pressure
to compress formatting, delete tests or weaken handling. Report physical counts.

#### Testing and acceptance

Start with the small valid-input TestSuite behavioral red, not missing-API
compilation failure. Then phase callbacks test complete published values:

| Boundary | Exact oracle and deliberate mutant |
| --- | --- |
| Lexer/parser/EBNF | Bar span; base and RHS syntax/order; update postfixes/nesting; reject missing base/bar/field/equals/brace, empty update, duplicate separator and multiline braces. Replace update parsing with literal path: valid callback fails. |
| Checking | Base supplies owner without an outer annotation; known context supports a literal base; nonrecord base gets new UpdateRequiresRecord error at complete base_expression_span; UnknownRecordField and RecordFieldTypeMismatch retain messages/help/declaration notes; new DuplicateUpdateField reports second name plus PreviousField(first span). Tests pin exact typed kinds and rendered message/help/span/note. Pin seed replacement inference and UnknownRecordField before delayed CannotInfer. Cover wrong nominal owner, generic/phantom identity, contextual RHS, purity, Void fields, all finite child classes and hidden growing recursion in base/RHS. |
| Specialization | Base/result/replacement/inherited fields all belong to the same actual concrete layout; Int/String instances differ when required; unused phantom arguments remain key identity. Calls reachable only inside base/RHS and nominal children appearing only under inherited List are prepared. Omit a child traversal: its precise instance/call oracle fails. |
| Lowering | Call base evaluated once (one call plus its ordinary argument definitions); binding base reuses an existing ValueId with no new alias operation. All RHSs in written order, then inherited projections and one construction in declaration order; exact IDs/types/spans/field owners/exit. Full base postfix span and outer update postfix returning another type. All-replaced, same-field RHS, nested update, reverse written order, aliases and branch isolation. Reorder RHSs, duplicate the call base, or omit a projection: specific callback fails. |
| Ownership + raw verification | Borrowed record parameter; numeric inline case; managed zero-child root; owning String/record/union/List children; duplicate pointer occurrences; retained child escapes after base retirement. Pin acquisitions, per-field OwnedPayload transfers and scheduled drops. From proven valid insertion output remove stored/projection acquisition, duplicate an owner transfer, or drop a base before a live projection; verifier rejects exact malformed-IR diagnostics. Keep all existing raw type/layout/borrow checks. |
| Runtime helpers | Use only aggregate_runtime production fragments plus actual allocator/free wrappers. Compare old/fresh pointers only while the old alias/root is live, including equal replacements. If an all-replaced base retires before fresh allocation, compare distinct allocation occurrence IDs and exact frees; malloc may reuse the address (aggregate_runtime_test.h:36–46). Never inspect a freed base or force unnecessary liveness. Each repeated child slot owns separately; unchanged root/list aliases survive nonfinal drop; final destruction accounts for every occurrence, including active owning-union payloads. Actual mortal Strings, nested Lists and Void/unmanaged-union roots. No generated language-symbol calls. |
| Real main | Entry prints `42\n7\n`. A second fixture declares number before text but writes `{ traced_base() | text = traced_text(), number = traced_number() }`; actual IO prints `base\ntext\nnumber\n7\n7\n`. Add surviving old child and returned updated-child cases. Exact stdout/exit/empty stderr and strict sanitizer evidence; stdout alone never proves destruction. |

Commands are root-only from the assigned integration worktree, with a FRESH host:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_record_updates.brp
# Expand to affected phase suites, then strict owning/runtime/grammar packet.
BLORP_MEMORY_STATS=1 BLORP_LEAK_CHECK=strict bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
env BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test
git diff --check
```

Require passing named callbacks and behavior mutations/restoration, all existing
e2e plus normal new mains, one compiler build per e2e run, ASan/UBSan and exact
allocator balances, generated-C ordering/fresh-root proof, current cost ceilings,
and two independent expert approvals. Shared frozen programs must emit identical
target C; unrelated layout/ABI changes are not authorized. Inspect default-limit
C compilation for moderate width/depth; report depth separately from byte size.
Phase/runtime/source-width measurements have separate workloads. The pilot cannot
selfcompile: the shared whole-CLI workload is explicitly a proxy excluding host
bootstrap work and unsupported language features.

#### Release strategy and handback

Review and commit this bounded plan before production. Land one
complete frontend→construction slice only after every gate; no partially accepted
update representation or compatibility shim. Revert the slice if a main failure
cannot be promptly isolated; preserve receipts. Hand back exact changed files,
source/binary/host/input hashes, independent severity counts/verdicts, red/green
and mutation receipts, C proof, raw measurements, separate production/test LOC,
and remaining debts. Ask root before broadening or working around a defect.

### List updates after record updates

Add record update, append, replacement and removal through separate fixtures.
Initially always allocate fresh results: copy unmanaged slots and acquire
surviving owned slots, then retire old storage as normal liveness permits.
Borrowed-input/owned-result functions suffice. Test empty/singleton/many elements,
absent/boundary lookup, mixed nested elements, changed length/capacity, repeated
children, replacement from an existing child, and surviving old aliases.

Set/Dict may reuse these slot/destruction contracts, but key equality/hash
semantics need a separate design. Storing a type does not automatically define
its suitability as a key.

## Recursive data

Function recursion is already supported. Declared signatures precede bodies;
concrete function requests reuse exact instance keys. The existing checking rule
rejects recursive parameter-dependency cycles that increase type depth, including
unused computations and unselected arms. Bare parameter cycles, permutations and
concrete resets remain allowed. This conservative first-order termination rule
can reject finite programs; richer type computation requires fresh review.
Deduplicating equal keys alone cannot stop infinitely many different keys.

### Unary recursive union

The first planned data-recursion example is deliberately small:

```blorp
fixed union Nat:
    Zero
    Next(Nat)

pure func make() -> Nat:
    Next(Next(Zero))

pure func walk(value: Nat) -> Int:
    match value:
        Zero: 7
        Next(child): walk(child)

func main() -> Int:
    walk(make())
```

Expected exit 7. Resolve self-reference to UnionId; reserve the concrete instance
in a local builder before expanding children; publish only complete immutable
rows after resolution. Box every variant of this recursive union, including
leaves, while preserving existing finite inline unions. Forward C declarations
and pointer fields produce finite storage. Cross-union, generic-recursive and
multi-field recursive shapes remain rejected until their increments.

Constructors take completed children, acquiring independent obligations as needed.
Projections and escapes use the same parent/acquisition contracts as records.
Carry owned match-prefix obligations into the selected terminating arm and
transfer/discharge them there; no general join representation is needed. Keeping
prefix owners until the selected arm returns is a correct first policy, without
claiming earliest-death cleanup. Reuse the accepted per-arm prefix obligations;
managed annotated tail-loop restrictions remain until their separate increment.

Final release iterates: decrement root, stop if shared, otherwise save the active
child, free root once and continue with the child. A leaf ends the walk. Root
retention does not retain children again. Test every variant, nonfinal/final
release, escaped child, shared tail, reassignment snapshots and deep destruction.
This unary release needs no general worklist or function trampoline.

Isolate deep destruction from construction/traversal call depth. In an approved
runtime-helper test, build a long chain iteratively from completed children,
retain a middle/shared tail, release the prefix, then release the tail and check
exact per-object frees. Establish construction completion before the destructor
mutation runs; a deliberately recursive release must fail the constrained-stack
case. Keep the initial real-main unary example small. Deep source construction
and traversal need the later managed tail-loop builder, so an earlier build/walk
stack overflow must not be reported as destructor evidence.

### Mutual, generic and branching shapes

Add mutual references and regular generic recursive instances through separate
examples. Reserve canonical declaration/argument keys before following children;
reject type-changing recursion with an unbounded instance graph. Distinguish
by-value size dependencies, stored pointer edges and phantom type arguments.
List[Tree] already provides indirection; not every semantic type cycle requires
boxing every participant. Do not merely relax child-before-parent ordinal checks.

A useful union-based List needs both head and tail, through multiple constructor
fields or a record payload. Compose arbitrary supported elements using the same
slot contracts. Before admitting branching/mutual mixed shapes, prove bounded
C stack across the entire release graph, including record -> List -> union ->
record. Iterative helpers that recursively call one another are insufficient.
Select any needed local worklist with its working example under AGENTS.md;
no speculative destructor registry. Test shared-tail diamonds, repeated slots,
mixed inline owning children, all variants and deep branching teardown.

### Acyclic values and future COW

Recursive type graphs may have cycles; runtime values must remain finite DAGs.
Construct roots from completed children. No recursive value bindings,
backpatching, lazy knot tying or shared mutable references are available.

```blorp
var value = make_zero()
snapshot = value
value = wrap(value)
```

This future example preserves the old root under the new one. Reassignment
changes a binding, not snapshot. Raw verification rejects forward/self child
value uses and invalid or reused obligations. No cycle detector/collector is
required by the admitted value shapes.

Always-fresh updates preserve that construction argument. Later unique-storage
COW/reuse would require a consumed root obligation, no conflicting live projection,
and independently secured replacement children before testing uniqueness.
RC == 1 alone cannot authorize mutation of a borrowed input. The illustrative
update `value = { value | child = Some(value) }` must produce a new root pointing
to the old snapshot, never install the root into itself. Reuse is deferred.

## Tail-recursion follow-ups

Unmanaged nongeneric direct-self loops are implemented. The regular accumulator
fixture checks exact output through one million iterations; the separate
billion-iteration run is retained in the
[argument report](../benchmarks/results/blorp_2_arguments_2026-10-12.md).
Ordinary calls still use the C stack; recursion is not automatically constant-stack.

1. **Same-instance generics.** Accept an annotated self edge only when substitution
   preserves every enclosing rigid parameter in order. Equal C layouts are not
   equal concrete instances. Define managed-instantiation rejection/support before
   enabling the annotation and retain growing-instantiation checking separately.
2. **Managed values.** Start with one String carrier and a terminating match after
   prefix handling is supported. Keep the external borrowed ABI; internal carried
   obligations are explicit. Entry acquires internal loop owners from borrowed
   parameters; it must never retire the caller's obligation. Each managed parameter
   occurrence carries its own obligation, including duplicate aliases. Evaluate
   next arguments, acquire/transfer next owners,
   retire old obligations, then rebind and jump. No pending cleanup follows the
   backedge. Base returns transfer the result and discharge remaining owners.
3. **Recursive managed data.** Compose the proven transition with unary recursive
   data. Acquire the next projected child before retiring its parent, then add
   deep traversal and destruction oracles.

Test entry acquisition and caller survival, unchanged/fresh carriers, aliasing,
duplicate/swap arguments, unused
intermediates, projected children and every return/edge directly at each affected
phase. Mutual tail-call guarantees and tail-modulo-constructor are separate future
designs. Stack safety for traversal and stack safety for destruction are separate
acceptance criteria.

## Broader control flow and later scope

Before non-tail matches, introduce typed block arguments and explicit edge
transfers; before loops, define carried values and all exits. Use SSA as the
working direction, without adding general phi/dominance machinery to straight-line
bindings. Only the selected branch executes; no blanket cleanup after a match.
Ordinary record syntax can reuse managed-root machinery with the same value
semantics. Closures need capture/escape and final capture destruction tests when
admitted. They do not justify adding closure infrastructure now.

## Phase-level test contract

Use named Blorp TestSuite callbacks; no subprocess per phase assertion and no
Python tests. Small typed inputs exercise each boundary directly. Obtain sealed
identities through their authority, but keep malformed raw ownership input
separate from verified products. Do not weaken production APIs for tests.

| Boundary | Required observations as each feature enters scope |
| --- | --- |
| Checking and typed errors | Exact accepted field/payload types; binding mutability/scope/purity; deferred recursion rejection; diagnostic kind, expected/actual identities, span/help and nonempty failure. |
| Inference/specialization | Rigid/local variable distinction, ordered complete substitutions, owner/position identity, nominal keys and phantom arguments; unused/pass-through instances; recursive reservation with no published placeholders. |
| Representation | Root versus child ownership, every declared slot, nested record/union dependencies, active variant, Void and phantom fields; reject missing, wrong-owner or incompatible layouts within the supplied program. |
| Value/control-flow lowering | Source order exactly once; immutable value versions, old aliases, captures only in selected arms, no sibling visibility; later joins/loop edges carry exact types. |
| Call ownership ABI | Borrowed inputs remain live; independent owned results may alias; consuming operands transfer once where supported; malformed runtime-operation contracts reject. |
| Uses/borrow dependencies | Exact last uses, unused values and function-local identity bounds; acquired child survives parent drop, nested acquisition survives intermediate-parent drop; delayed borrows keep ancestors live when supported. |
| Ownership insertion | Per-slot multiplicity, repeated child values, borrowed acquisition, unused-root cleanup, returned/stored escape, RHS-before-old-drop, selected-path owner discharge. |
| Independent raw verifier | Missing/double consume on one path, early owner drop, borrowed escape, wrong parent/field/type, use after transfer, leaked roots, sibling facts and invalid match coverage; inspect actual operations, not insertion decisions. |
| C emission | Independently expected small typed operation sequences, correct helpers/operands, acquire-before-retire, active-field cleanup, no invented owners; inspect layout order and structural depth. |
| Target runtime | Nonfinal release preserves children; final release destroys each occurrence/root once; repeated pointers and independent owners; mixed inline children; recursive shared tails and bounded destruction. |
| General collections | Initialized length distinct from capacity; empty/boundary/absent access; insert/replace/remove/grow cleanup, no stale owned tail slots, old snapshots unchanged. |
| Real-main e2e | Mixed numeric/managed fields observed, temporary-parent escape, duplicate child fields, nested/generic elements, old aliases, recursive snapshots and deep destruction. |
| Future COW/reuse only | Shared aliases preserved; unique update has consumed permission and no conflicting borrow; replacement acquisition precedes uniqueness; safe capacity/layout fallback. |

When reuse is introduced, its enabled and always-fresh paths must agree on
observable values and safe destruction. This future equivalence oracle is not a
requirement to implement reuse now.

Existing direct stage suites include [test_lower.brp](test/unit/test_lower/test_lower.brp),
[test_own.brp](test/unit/test_own/test_own.brp), [test_verify.brp](test/unit/test_verify/test_verify.brp)
and [test_emit.brp](test/unit/test_emit/test_emit.brp). The
[String-runtime suite](test/runtime/test_string_runtime.brp) independently checks
bytes/length, retain, nonfinal release, final free and independent lifetimes.
These do not establish future aggregate runtime coverage.

### Required negative and mutation oracles

For each admitted shape, use direct raw-verifier negatives for missing acquisition,
one-path leak, duplicate transfer, wrong field/parent, early drop and invalid
escape. Assert the exact violated obligation and operation/edge, not any error.
Test complete layouts independently against declarations, including unused rows.

Deliberately omit one child drop, target a different child, remove required
acquisition, or free a root twice and require its protected test to fail. Where
branching exists, defect only one arm. Collection tests must detect a forgotten
removed child and a double-dropped shifted child. Later update tests must fail if
an old alias changes; later recursion tests must detect recursive C teardown.
Restore exact sources before final gates. These are bounded oracle checks, not
permission for a mutation framework.

Balanced totals, line coverage and sanitizer silence do not prove exhaustive
release. Runtime evidence must distinguish actual object lifetimes from compiler
allocation counters. ASan/UBSan and a supported native leak checker supplement
phase and runtime tests; prove the leak oracle detects omitted cleanup before
relying on it.

The user approved extending the existing String direct-C runtime-test pattern
to concrete aggregate helpers on 2026-10-13. Blorp TestSuite compiles the same
pure production fragments with test-local real allocation/free observations,
starting with the reviewed finite-record cases. Each new shape still needs its
own independent cases; permission for the method is not evidence of coverage.
Use actual emitted fragments with no production tracing or alternate emitter;
keep real-main fixtures unmodified. Missing aggregate destruction evidence is an
implementation acceptance dependency to report, not permission for an implicit
test driver or a claim that compiler leak checks prove target cleanup.

## Validation and acceptance

Each slice must provide red/green fixtures, granular positive/error/malformed-IR
tests, complete immutable facts, independent ownership verification, generated-C
inspection and runtime lifetime/destruction evidence for its admitted shapes.
Compiler-expert code-reviewer and test-runner review both design and final change.
Do not mark a milestone complete while required evidence is missing.

### Complexity and compiler-cost tracking

Allocations and retired instructions may increase as capabilities grow. Record
both on frozen baseline/candidate inputs with the same toolchain, serially and
separately from target lifetime evidence. Before changing a major carrier,
freeze its input corpus and numerical fixture guards; explain any deliberate
guard adjustment from measured behavior.

For new traversals/builders, state their input-size dimensions and expected
work. Exercise a small scaling series, such as 16/32/64/128 stored fields or
concrete shapes, and inspect work/allocation/instruction growth. Investigate
repeatable near-quadratic doubling and repeated whole-body/layout scans or
copies; avoid introducing superlinear algorithms where a direct bounded
traversal suffices. Existing linear instance-key scans are not a claim of total
linear compilation. Report inherited scaling separately and add an index only
when a measured query justifies its key, authority and lifetime.

This tracking does not require allocation reduction, minimal ARC traffic or
optimization passes as feature acceptance. Keep local uniquely owned builders
and one published row/slot per concrete fact; measure rather than hiding the
host compiler's physical storage costs.

From the repository root, check host freshness and use focused suites first:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_records.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_own/test_own.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_verify/test_verify.brp
bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit
make -C blorp_2 test
git diff --check
```

If not FRESH, run make then recheck before direct tests. Add owning frontend,
grammar/runtime suites as appropriate. E2e builds the pilot once at O0, compiles
unmodified fixture C at O0 and uses timeout 0. No persistent compiler cache.

Keep source/binary/toolchain/input provenance and gates in one retained report,
with raw artifacts under ignored build/. Existing test ceilings and repository
measurement rules still apply to performance claims and compiler data-model
refactors. Report production/test LOC separately; owned-input costs are proxies,
not self-compilation. Old slice-specific thresholds/counts are historical evidence,
not current budgets. No feature requires fewer allocations, minimal retains,
unique reuse or a new optimization benchmark.

Hand back exact supported shapes/contracts, red/green and mutation outcomes,
C observations, gate verdicts and remaining limits. Stop and report host defects,
unapproved mechanisms, missing destruction oracles and incomplete representation.
Never work around them with partial publication or unchecked emission.

## Established references and local choices

These references support specific decisions, not a transfer of another compiler's
proof or runtime model. Swift/Go/Rust ownership references were checked on
2026-10-12. Adopt their correctness lessons within the current typed pipeline;
no full borrow checker, GC, ownership lattice or optimization pass is implied.

| Reference | Lesson and Blorp application |
| --- | --- |
| [Swift Ownership SSA](https://github.com/swiftlang/swift/blob/main/docs/SIL/Ownership.md) | Owned values have one consuming end per path; dependent borrows require a live base. Apply the explicit obligation/use rules and independent verifier above. |
| [Rust destruction](https://doc.rust-lang.org/reference/destructors.html) and [drop elaboration](https://rustc-dev-guide.rust-lang.org/mir/drop-elaboration.html) | Cleanup follows complete field/active-variant structure. Generate it from canonical layouts. Partial-move flags and user destructors are unnecessary for the first whole-value constructors. |
| [Go generic slice lifetimes](https://go.dev/blog/generic-slice-functions) | Obsolete backing-array references can keep removed objects alive. Translate this into explicit initialized ARC slots and exact removal/growth obligations, not Go's shared-mutable slice semantics. |
| [Koka/Perceus](https://www.microsoft.com/en-us/research/uploads/prod/2021/06/perceus-pldi21.pdf) | Explicit dup/drop and reuse are distinct concerns. Use explicit ownership operations; postpone reuse and minimal-memory goals. |
| [Lean: Counting Immutable Beans](https://arxiv.org/pdf/1908.05647) and [RC documentation](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/) | Borrowed references depend on owners; storing one value twice consumes two obligations. Take those contracts without requiring borrow inference or unique updates. |
| [Rust recursive layouts](https://doc.rust-lang.org/book/ch15-01-box.html) and [LinkedList teardown](https://doc.rust-lang.org/src/alloc/collections/linked_list.rs.html#1177-1195) | Indirection gives finite recursive size; iterative destruction avoids chain-depth C stack use. ARC shared tails/mixed graphs need our own proof and tests. |
| [Rust concrete-instance collector](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_monomorphize/collector/index.html) and [Instance identity](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_middle/ty/struct.Instance.html) | Discover dependencies using complete nominal instance keys; keep local construction and immutable publication rather than copying Rust's entire pipeline. |
| [OCaml representation](https://ocaml.org/docs/memory-representation) and [recursive values](https://ocaml.org/manual/5.5/letrecvalues.html) | Tagged payload blocks are a useful model; immutable values alone do not rule out cycles. Our completed-child construction rules must establish acyclicity. |
| [Bidirectional Typing](https://arxiv.org/abs/1908.05839) and [rustc inference](https://rustc-dev-guide.rust-lang.org/type-inference.html) | Separate synthesis/checking, rigid parameters and local solvable variables; preserve origins and publish only complete accepted facts. |
| [OCaml tail-modulo-constructor](https://ocaml.org/manual/5.5/tail_mod_cons.html) | Constant-stack traversal needs an explicit qualifying transformation. Our direct-self guarantee does not imply mutual or constructor-tail guarantees. |

The first compiler remains a source of bounded precedents:
[ownership contracts](../docs/OWNERSHIP_MODEL.md),
[concrete record representation](../blorp/src/compiler/stage_09_core/record_representation.brp),
[managed record layouts](../blorp/src/compiler/stage_09_core/managed_record_layout.brp)
and [cleanup preparation](../blorp/src/compiler/stage_09_core/prepare.brp).
Carry useful contracts forward, not broad mutable environments or string-keyed
semantic rediscovery. Historical aggregate-child protection and builder-COW
failures supply regression ideas, not claims about current bugs.

## Retained evidence and history

Current plans live here; completed experiments, counts, historical budgets and
host-compiler limitations live in their reports:

- [Bindings](../benchmarks/results/blorp_2_bindings_2026-10-09.md),
  [arm blocks](../benchmarks/results/blorp_2_arm_bindings_2026-10-09.md),
  [managed Strings](../benchmarks/results/blorp_2_managed_strings_2026-10-09.md)
  and [tail-arm ownership](../benchmarks/results/blorp_2_tail_strings_2026-10-09.md).
- [Typed errors](../benchmarks/results/blorp_2_typed_checker_errors_2026-10-09.md),
  [checking/synthesis](../benchmarks/results/blorp_2_synthesis_checking_2026-10-09.md),
  [function parameters](../benchmarks/results/blorp_2_function_type_parameters_2026-10-09.md),
  [union parameters](../benchmarks/results/blorp_2_union_type_parameters_2026-10-10.md),
  [nested applications](../benchmarks/results/blorp_2_generic_nested_2026-10-10.md)
  and [managed union payloads](../benchmarks/results/blorp_2_managed_union_payloads_2026-10-11.md).
- [Fixed records](../benchmarks/results/blorp_2_fixed_records_2026-10-10.md),
  [function recursion](../benchmarks/results/blorp_2_function_recursion_2026-10-10.md),
  [tail loops](../benchmarks/results/blorp_2_tail_recursion_2026-10-10.md),
  [argv](../benchmarks/results/blorp_2_arguments_2026-10-12.md)
  and [ownership reconciliation](../benchmarks/results/blorp_2_argv_reconciliation_2026-10-12.md).
- [Host temporary-projection repair](../benchmarks/results/compiler_nested_temporary_projection_2026-10-11.md).
  Passing pilot checks do not imply an incomplete broader host gate passed.

For the superseded wording and historical thresholds, use the Git snapshots of
[memory](https://github.com/kablorp/blorp/blob/79deebd455856e5955d215ff2ec36f17860feb14/blorp_2/MEMORY_PLAN.md),
[generics](https://github.com/kablorp/blorp/blob/79deebd455856e5955d215ff2ec36f17860feb14/blorp_2/GENERICS_PLAN.md),
[recursion](https://github.com/kablorp/blorp/blob/79deebd455856e5955d215ff2ec36f17860feb14/blorp_2/RECURSION_PLAN.md)
and the [older one-String-field proposal](https://github.com/kablorp/blorp/blob/79deebd455856e5955d215ff2ec36f17860feb14/blorp_2/MANAGED_RECORDS_PLAN.md).
They are historical evidence; this consolidated roadmap supersedes their plans.
