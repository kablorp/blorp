# Memory architecture before bindings

Status: proposed responsibilities and increment sequence, 2026-10-09.
This document adds no input-language support or runtime machinery. Read
[AGENTS.md](AGENTS.md) and the parent instructions first. The current pilot
has only unmanaged Int and union values; [README.md](README.md) owns its scope.
Examples below describe future increments using existing Blorp syntax.

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
- A future `ValueId` identifies one computed value in one lowered function.
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

Initially all current target values have inline storage and no managed
children. Do not generalize that into `inline means no ownership`: future
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

Before branch-local assignments or non-tail matches, define typed block
arguments and edge transfers. Before loops, define loop-carried values and
exit edges. Avoid adding ownership logic to compensate for an ambiguous
control-flow representation.

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

## Increment sequence and evidence

1. **Scalar bindings:** establish identity, immutable/mutable rules and ordered
   value versions. Keep current unmanaged layout and native result oracles.
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
