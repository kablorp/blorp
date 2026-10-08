# Tuples through record storage

Status: typed tuple storage and native boundaries are implemented, and ordinary
tuple emitter paths are removed. Rebased onto main `5e6ef4bcf`, the final fresh
O2/O2 compiler passes 4,831 runtime cases, 7,116 selected compiler checks and
11,973 broad compiler, discovery and parity cases. The three-stage worktree
fixpoint emits identical C and builds both later compilers.

Three bounded queue repairs preserve generated C. The full branch, including the
[construction prerequisite](../benchmarks/results/tuple-record-construction.md),
costs +15.23% retired instructions and +13.20% allocations against matching main.
Independent review accepts this measured overhead; the
[storage report](../benchmarks/results/tuple-record-storage.md) records exact
validation, accounting and bounded follow-ups without claiming every residual
cost is attributed. Bootstrap release/rotation remains separate work.

Tuples become compiler-generated records for storage. Tuple syntax, structural
typing, destructuring, indexing and trait behavior stay in typecheck. Once
element types are concrete, tuples use the same construction, typed field
layout, ownership and destruction machinery as ordinary records.

This roadmap owns the implementation order for shared storage. It brings typed
tuple storage ahead of scalar replacement and multi-value calls in
[Product Unification](PRODUCT_UNIFICATION.md). That document retains the
detailed product-operation and optimization designs. Read
[Worker Checklist](WORKER_CHECKLIST.md), [Code Shape](CODE_STYLE.md) and
[Handoff Spec](HANDOFF_SPEC.md) before implementing a slice.

## Destination and scope

Conceptually, a concrete `(Int, String)` has an internal record layout with
two fields, in tuple element order. This is the storage counterpart of:

```blorp
record PairStorage {
    first: Int,
    second: String
}
```

The internal row is generated once for the concrete tuple type. It is not a
nominal declaration in the source language. Two modules using the same tuple
type obtain the same structural storage identity; a user-declared record
retains its distinct nominal identity. Field ordinals are authoritative;
generated member names are an emission/debugging detail.

For equivalent managed tuples and managed records, one layout implementation
decides headers, field offsets, element storage and ownership rules. In
particular, an inline aggregate element is stored as that aggregate, rather
than boxed merely to fit a `void*` tuple slot. Existing tuples remain managed
initially. Automatic inline scalar tuples are a separate policy decision.

Keep current arities 2, 3 and 4, tuple formatting, equality, ordering and hashing.
This implementation introduces no public `Tup2` family, new indexing syntax,
tuple update syntax or foreign by-value ABI. Scalar replacement, multi-value
calls and reuse optimization follow shared storage independently.

## Starting boundary

The shared `ProductFieldExpr` read was already implemented. In
`stage_09_core/ir.brp`, record construction now uses a checked product build.
Tuple construction was still separate:

```text
TupleExpr(List[CoreExpr], CoreType, CoreSourceLoc)
TupleConstructExpr(CoreTupleConstruct, CoreType, CoreSourceLoc)
ProductExpr(CoreProductBuild, CoreType, CoreSourceLoc)
```

Before this slice, `prepare.brp` prepared tuple storage classes and
retain/release masks separately. The legacy native runtime tuple box has an
object header, arity, release mask and flexible array of `void*` slots. Record
emission already had typed fields, constructors, destruction and reuse helpers.
Native and generated intrinsic code also constructed and consumed generic
tuple boxes; changing emission alone would have broken those boundaries.

The record prerequisite removes the late field-reordering pass. Evaluate
nonliteral product fields into immutable Core bindings before ownership
analysis, in written order, while retaining checked storage ordinals for
ordinary, reused and static records. The retained allocation
regression fails on the baseline: two `(Int, Option[Int])` values in a list
allocate five objects, versus three for equivalent managed records.

The record prerequisite can change emitted ownership contracts: a named
field owner makes a borrowed-to-owned handoff explicit. For example, a
record-building helper may borrow a String parameter and retain it into the
field owner, while its caller keeps responsibility for the original reference.
Byte-identical C is therefore not the prerequisite's acceptance oracle.
Review caller transfers, callee retains and destruction together, and measure
the cost of those changes. Written-order temporaries also change; layouts,
evaluation order and result values must stay equivalent.
Field results must have cancellation cleanup protection across later field
evaluation until construction takes ownership. Use the ordinary binding
ownership boundary for conditional results; an emitter must not guess that
an arbitrary expression has an independent reference. The retained
cancelled-sleep regressions cover fresh results, retained globals, local
duplicates, borrowed closure captures and conditional field evaluation.

List construction has the same evaluation boundary: bind nonliteral elements
in written order before allocating the container. Otherwise cancellation in
a later element can orphan the List and any completed earlier element. Keep
the element storage and transfer metadata intact when replacing values with
these owners; static literal trees retain their initializer form.

Record-field normalization can introduce bindings inside a tensor element.
Project tensor literal storage through the existing shared shape issuer before
ownership analysis, then name every nonliteral scalar element with the same
binder supply. Preserve ranked flattening and the explicit raw, packed,
inline-record and boxed variants. Evaluate all elements before allocating the
tensor; this keeps earlier owners protected across a later cancellation and
lets the existing simple slot writers consume named values.

## 1. Retain behavioral and ownership oracles

Extend the existing tuple runtime, Core prepare/Perceus, and leak suites with
paired tuple/record cases. Cover generic and cross-module types, nested tuples,
inline aggregates, borrowed/owned managed elements, repeated elements,
temporary projections, closure captures, static values and cancellation.
Pin construction and projection evaluation order.

Use a retained non-flattened `List[(Int, Option[Int])]` and equivalent record
case to expose generic-slot element boxing. Measure the actual baseline rather
than importing historical allocation counts. Record generated C, allocation,
retain/release and final live-object evidence.

Done when: the smallest repeatable tests distinguish correct values and
ownership from plausible wrong implementations, and the baseline exposes the
tuple-only aggregate boxing that the storage slice must remove.

## 2. Share construction and element ownership

Finish the record construction slice already developed on
`products/slice2-record-construction`, reviewing its prerequisites and adapting
it to current main. Keep unrelated refactors independent. Extend the checked
ordinal-carrying `CoreProductBuild` and `ProductExpr` construction to tuples.
Evaluate values in source order and store them at their declared ordinals.
Keep Unit projections as checked product reads through Perceus: their managed
receiver may be borrowed. Shared layout emission evaluates the receiver and
omits the absent member; discarding the receiver before ownership analysis
would consume a reference that the projection never owned.
Normalize nonliteral field evaluation into immutable Core bindings before
ownership-contract discovery and Perceus. Mint identities through the shared
binder supply with an explicit product-evaluation temporary origin. Preserve
the static initializer boundary and reject unevaluated operands after this
normalization, allowing the explicit ownership operations Perceus introduces.
A reuse source keeps its original consuming reference when it is a declared
local and no field reassigns it; otherwise bind a snapshot before the fields.
Do not introduce a retained source alias that defeats unique reuse.

Move tuple element ownership into the explicit Perceus operations used for
record fields. The prepared tuple `retain_mask` must no longer be a second
ownership authority. Preserve current storage while changing this boundary.
Replace tuple-specific traversal and construction cases as their common form
becomes available; preserve existing local tuple flattening behavior.

Done when: one Core construction operation serves both products, focused Core
and runtime tests pass, and ownership oracles establish balanced element
transfers. Record behavior and layouts stay equivalent; intentional ownership
contract and tuple emission differences are explained and reviewed.

## 3. Migrate runtime producers and consumers

Audit runtime C and compiler-generated intrinsic emission together. Migrate
dictionary entries, zip, enumerate, unfold, and process interfaces one at a
time. Use Blorp library implementations where the existing primitive boundary
suffices, or explicit typed record adapters at native interfaces.

An adapter must account for ownership as well as fields. The legacy bootstrap
unfold path reads tuple slots and changes release metadata while transferring
state and value; ordinary adapters now read typed fields. Process inputs and
results likewise require explicit native records rather than assumptions about
tuple slot positions. Preserve existing primitive signatures where needed for
the pinned bootstrap.

Done when: all ordinary tuple-facing interfaces have a typed producer/consumer
contract and no longer inspect or construct the generic slot representation.
Their behavioral, leak and allocation controls pass independently.

## 4. Emit generated tuple records

At the concrete representation boundary after monomorphization, issue a
compilation-local storage row keyed by the concrete structural tuple type.
Represent its generated origin explicitly. Validate arity, element types and
ordinals when issuing the row. Do not manufacture source `TypeId`/`FieldId`
values, identify tuples by name prefixes, or add a spelling-based identity
authority.

Adapt the record layout view to accept source record rows and generated tuple
rows. Route tuple fields, constructors, destructors and ownership metadata
through the record emitter. Keep structural tuple identity and tuple trait
dispatch at the semantic boundary. A full nominal type-identity redesign is
not a prerequisite for this bounded generated-layout authority.

Done when: equivalent managed product shapes use the same layout rules, normal
tuple emission uses typed fields, and aggregate elements incur no slot-only
boxing. The retained allocation oracle improves as predicted, value/ownership
gates pass, and every generated-C difference is attributable.

## 5. Delete duplicate storage paths and rotate the bootstrap

Remove obsolete tuple construction, preparation, rendering and ownership
forms. Add a phase invariant rejecting legacy tuple storage forms after
representation selection. Source tuple semantics may remain before that
boundary; backend consumers see only the shared storage authority.

Track these deletions alongside the new shared implementation:

- `CoreTupleConstruct`, `TupleConstructExpr`, tuple-only `CoreTupleElement`
  wrappers and their traversal/JSON cases.
- Tuple construction preparation and its separate element retain/release masks.
- Tuple-specific dynamic and static constructors and slot access in the
  backend, including `prepared_tuple_renderer`.
- Tuple-only element ownership decisions superseded by explicit product field
  ownership in Core.

Keep structural tuple typing, trait dispatch and local tuple flattening where
they still express source semantics or optimizations. Those are not duplicate
storage implementations. Report added and removed production lines separately
from tests, documentation and validation tools for each slice. Intermediate
growth does not establish simplification: the storage slice must remove the
ordinary duplicate paths before it is complete.

The ordinary compiler tuple storage paths are removed. A follow-up deletion
also removes the unused static tuple hex/float codecs and native tuple producers
for dictionary entries, vector zip, stream unfold/enumerate and simple process
run/shell. These operations now use typed product factories exclusively.

The pinned bootstrap still emits calls to `blorp_tuple_new`,
`blorp_tuple_set_rc`, `blorp_process_run_command_raw` and
`blorp_process_session_start_raw` for the compiler itself. Keep the tuple
layout/destructor and raw process option/result codecs required by those calls
until a compiler using typed tuple storage has completed release validation and
a bootstrap rotation. Then remove that remaining ABI and its declarations.
No permanent compatibility path remains.

Done when: one ordinary product storage implementation remains, all current
compiler sources self-host, and the new pin needs no legacy tuple runtime ABI.
Publishing a bootstrap release is a separate release action; do not fabricate
a pin or commit host-local compiler paths to make this milestone appear done.

## Validation and integration

Each slice is independently reviewed and committed. First run the owning
focused suite, then the checks selected by
`scripts/compiler-check --changed --base origin/main`. Construction and
storage changes also run:

```bash
make hygiene-check
scripts/test --no-build compiler-blorp compiler-new compiler-new-parity
scripts/test --no-build --serial compiler-core-sanitize leak runtime
scripts/compiler-fixpoint
```

Build the intended sources first and require `scripts/compiler-build-status`
to report `FRESH`; `--no-build` does not replace that check. Pass `--no-format`
to compile/run/check, serialize compiled executables, and retain full gate and
C artifacts outside tracked source. Stage 2 and stage 3 must emit identical C.

Measure a matched current-main baseline and candidate at the same optimization
level and toolchain, with frozen workload/source provenance. Report allocations
and retired instructions, not a wall-time speed claim. Pause to reassess if the
bounded storage work requires a new source typing rule, an unreviewed ABI
change, unresolved ownership behavior, or a broader identity project.

Update this document's status after each accepted slice. A handback names the
commits, representation boundary, removed paths, C changes, measured effects,
gate results and any remaining release dependency.
