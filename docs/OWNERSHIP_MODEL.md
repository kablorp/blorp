# Ownership Model

This document defines the compiler/runtime ownership ABI for managed Blorp
values. It is normative for Core lowering, ownership contracts, Perceus, reuse,
closure conversion, resource lowering, backend preparation, C emission, and the
runtime.

The source-level model is described in [MEMORY_MODEL.md](MEMORY_MODEL.md).

## Goals

- Preserve value semantics: assignment copies logical values and mutation never
  becomes visible through another source-level alias.
- Ensure every owned managed value is transferred, consumed, retained, or
  dropped exactly once.
- Make COW and call ownership compiler-visible contracts rather than runtime
  conventions inferred from names.
- Reject missing ownership or representation facts before C emission whenever
  the compiler has enough information.

## Managed Values

Managed values are heap values with runtime reference-counted lifetimes.
Current families include strings, lists, dictionaries, sets, tensors, heap
records, payload unions, captured closures, channels, and other runtime objects
classified by Core representation.

Unmanaged values include primitive scalars, enums, fieldless unions, raw
pointers, and dimension values. `record` and `fixed record` both
denote ordinary managed records; fields may themselves be managed.
Type-header validation rejects mandatory recursive products before Core
lowering, independently of the declaration spelling.

Type declarations enter the environment only through category-specific headers
accepted by a validated `TypeHeaderGraph`. Production and phase-local compiler
tests build that graph before typechecking; there is no environment-backed
parsed-declaration registrar that can bypass graph-wide layout validation.

Source declarations with runtime ABI identities are classified from their exact
canonical module path and declaration name in the frontend language-surface
manifest. Lowering carries that closed identity on the Core declaration, Core
serialization preserves it, and flattening, generic-template collection, and
runtime ABI projection consume it directly. A same-named user declaration does
not acquire builtin ABI behavior.

Unknown concrete named types must not default to unmanaged or `void*`.
Representation-sensitive Core requires an accepted identity and explicit
layout fact.

## Ownership Facts

| Fact | Meaning |
| --- | --- |
| `Owned` | One reference that must eventually transfer, consume, or drop |
| `FreshOwned` | A newly allocated owned value with runtime uniqueness |
| `Borrowed` | A temporary read owned elsewhere; it must not be dropped |
| `Alias(owner)` | A borrowed projection whose lifetime depends on another owner |
| `StaticImmortal` | Artifact-lifetime immutable storage that needs no runtime ownership operation |
| `Retained` | A new owner created by incrementing the source reference count |
| `Consumed` | Ownership transferred into an operation; the caller cannot drop it afterward |
| `Transferred` | Ownership moved into another owner without an extra retain |
| `Place` | A variable, field, collection slot, global, or temporary holding a value |

Ownership is attached to exact local or declaration identity. Source spelling
alone is insufficient because locals can shadow globals and module-local
definition numbers can collide across modules.

## Expression Results

Every managed expression result has one of these source contracts:

- a dynamic allocation produces `FreshOwned`;
- an immutable string literal produces `StaticImmortal`;
- a local or global read is borrowed from its storage place;
- a field or collection projection is an alias of its container owner;
- a caller-preserving operation returns ownership according to its explicit
  result contract; and
- a branch expression joins ownership only after every reachable arm has a
  compatible result fact.

A borrowed value that escapes through return, storage, capture, task transfer,
or another owning boundary must be retained first. A fresh owned value should
not receive an unnecessary retain before direct transfer.

## Match Bindings

Pattern bindings borrow from the scrutinee unless an explicit owned-match
transformation transfers the scrutinee owner into the branch. Payload aliases
must not outlive the scrutinee without a retain.

Releasing constructor matches require special treatment because the backend may
release the scrutinee root after branch evaluation. Ownership insertion and
match projection must agree on which layer owns that release; equivalent event
counts with different placement are not proof of correctness.

## Call ABI

Each managed argument slot has an explicit mode:

| Mode | Caller responsibility | Callee/operation responsibility |
| --- | --- | --- |
| Borrow | Keep an owner live through the call | Read without consuming or dropping |
| Retain | Provide or create an independent owner | Own and eventually release or transfer it |
| Consume | Transfer an existing owner | Own the transferred value |
| COW consume | Transfer a receiver owner | Reuse if unique or copy and release the old owner |

Arguments are evaluated left to right, and the callee runs after the last
one; the emitter materializes arguments in that order whenever one can
execute code. A variable passed directly to a consuming slot is only read
while the arguments are evaluated and is transferred when the callee starts,
so a borrow of it that ends during evaluation (`f(b, g(b))`, with `g`
returning an operator result or an owned value that does not alias `b`)
needs no extra reference. A borrow still held when the callee starts, such
as `b` or `b.field` in a borrowing slot, does: all such borrows share one
reference beside the transferred one.

Each managed result similarly states whether it is newly owned, transferred,
borrowed, or aliases an input. Public read-only operations must not secretly
consume receivers. COW consumption is an internal ABI or an explicitly
consuming source operation.

Direct user calls use exact callable identities and inferred or declared
contracts. Builtins and intrinsics use the typed contract tables in
`ownership.brp`. Foreign calls remain a trust boundary and must receive an
explicit conservative contract rather than a name heuristic. Static string
literals may cross ordinary borrow, retain, or consume slots because their
runtime ARC operations are defined no-ops. A foreign API that can mutate a
string or keep an untracked pointer beyond Blorp's ownership ABI must receive
an explicit mortal copy; arbitrary C must never write pooled storage.

## Source Function Boundary

Managed parameters are borrowed by default for synchronous source calls. The
caller keeps its owner live while the callee runs. A callee that returns,
stores, captures, or transfers a parameter must create the required owner.

Managed return values cross as owned values. Returning an alias of a parameter,
global, capture, field, or collection element therefore requires a retain or
an explicit ownership transfer proven by Core.

Closures and tasks preserve the same rule. A result cannot depend on the
closure environment or completed task object remaining alive after return.

## Storage ABI

Storage places own managed values unless the place is explicitly borrowed.

- Immutable local initialization transfers the expression owner into the local.
- Mutable assignment releases or consumes the previous place owner before
  installing the new owner. A mutable local keeps its owner until the scope
  exits, and a consuming use retains it, except where the local's last use
  ends the scope on every path: returning it, or passing it as the only
  mention in a consuming call in tail position, transfers the place owner.
- Aggregate construction transfers field or element owners into the aggregate.
- Global initialization gives the generated global root ownership until
  shutdown or reassignment.
- Closure environments retain managed captures and release them when destroyed.
- Task environments retain captures until completion cleanup transfers or
  releases them.

An emitter-created managed temporary is still an owner. The backend must close
its lifetime explicitly or reject the unsupported shape.

### Cancellation Cleanup Slots

A managed local that may be live when its task is cancelled gets a cleanup
slot (`blorp_task_cleanup_push`) holding a count of references to release if
cancellation unwinds past it. A `DUP` of the local adds one
(`blorp_task_cleanup_duplicate_slot`), and every place that takes one of the
local's references away pops one (`blorp_task_cleanup_pop_slot`): its `DROP`,
a consuming call argument, a `let` or `var` whose right-hand side is the
local (or `DUP v; v`), an operand that a union or record constructor takes
over, a tuple element or a list, tensor or dictionary literal element stored
without a retain, and the source or a replacement of a record update or
reuse construction. The pop runs before the new owner pushes its own slot, so each
reference is counted by exactly one slot, and it runs even when the new owner
is an untracked `var`: a unit left behind would be released again after the
`var` has consumed or replaced the reference. The planner (`stage_09_core/cancellation_plan.brp`)
gives a local no slot at all when its own reference is handed on before any
cancellation point; a move under a `DUP` of the same local does not count,
because the local keeps its own reference.

A `var` gets a slot like a `let`, with one addition. A frame records the value
it was pushed with, so an assignment pushes the `var`'s frame again for the
value it stores (`blorp_task_cleanup_rearm_with_task`), unlinking it first if
a unit is still counted on it. The assignment pops nothing for the old value,
since whatever consumed it already did, but it pops the source of a `var` or
`x = y` right-hand side, as a `let` does. A `var` assigned in a loop that parks,
or only under a branch, therefore releases its last stored value when the task
is cancelled. A consumption before a park does not end a `var`'s ownership,
because a later assignment can give it a new value; only a direct return does.
Straight-line assignments are lowered to fresh `let` bindings and need none of
this.

Parameters follow the same rule, by how the caller passes them. A caller
lends a borrowed parameter and keeps both the reference and the slot that
counts it, so the callee never pushes, duplicates or pops a slot for it. A
caller hands over an owned parameter (a consuming clone's, or any parameter
ownership inference makes the callee consume) and pops its own slot for the
argument at the call. The callee is then the only owner, so it gives the
parameter a slot at entry under the rule above, with the whole body as the
`let` body: it pushes one when the function can be cancelled, at a park or a
cooperative loop checkpoint, before the parameter's reference is handed on.
The runtime cannot move a frame from the caller's slot to the callee's; no
cancellation point falls between the caller's pop and the callee's push, so
each reference is still counted by one slot throughout. The planner reads
which parameters are handed over from the program's `UserCall` consumed
arguments, the lists the caller's pop is emitted from; a final-Core invariant
(`DisagreeingUserCallContract`, under `--check-invariants`) requires every
call of one function to hand over the same arguments. A function whose body
rebinds its parameters (a self-tail call lowered to a loop) gets no entry
slots, because a frame records the value it was pushed with.

## COW ABI

COW update operations consume one receiver owner and return one result owner:

```text
unique receiver
  -> update compatible storage
  -> return same owner

shared or incompatible receiver
  -> allocate/copy replacement
  -> release consumed receiver owner
  -> return replacement owner
```

The caller must use the returned value. A borrowed field or collection-element
alias cannot be passed directly to a consuming COW slot; it must first become an
independent retained owner.

Reuse is an optimization after ordinary ownership is correct. The reuse pass
may consume a proven post-Perceus drop and upgrade an allocation or producer
handoff only when type, layout, liveness, element ownership, and runtime
uniqueness are compatible.

### Fieldwise Record Updates

A record update evaluates every replacement exactly once, in Core field order,
before consuming or mutating the source record. This ordering applies even when
replacement expressions are impure, read the source, swap fields, or produce
managed owning temporaries. No generated field write may occur while a later
replacement can still observe the pre-update source.

The operation consumes one source owner and one owner of each replacement. If
the source allocation is unique, it keeps that allocation, releases each
overwritten field according to its declared release policy, moves the
replacement into place, and leaves inherited fields untouched. If the source is
shared, it retains only inherited values needed by the result, moves the
replacements into one new record, releases the consumed source owner, and leaves
all other source owners unchanged.

`record_update_ownership` decides which updates take their source's owner:
the target of `x = { x | ... }`, a consuming clone's owned parameter in the
clone's result, and an immutable record binding updated where nothing reads
it afterwards on straight-line control flow within the binding's block (SSA
renaming gives an unconditional `x = { x | ... }` exactly that form). On the
first two paths, which follow branches and match arms, an immutable alias of
the target that the rest of the body never mentions the target beside
(`rows = from_opaque Table(table)`) carries the owner, and a binding of an
update returned by name (`grown = { rows | ... }` then `grown`) is that
update. An update whose base is an expression rather than a variable
(`{ make() | ... }`, `{ p.state | ... }`) takes the owner of the binding that
lowering gives the base, since nothing else names it; for a base read from a
field path, the replacements' reads of that path go through the binding, so
`{ p | state = { p.state | cursor = p.state.cursor + 1 } }` reads the `state`
slot once and the enclosing update can take it. Every other update builds a
fresh record.

Field release must honor `NoReleasePolicy`, `ArcReleasePolicy`,
`ArcReleaseOnlyPolicy`, and `StackResultReleasePolicy`; managed does not imply
ordinary `blorp_release`. Before ownership lowering, `RecordUpdateExpr` contains
every declared field exactly once in declaration order. Its ownership-refined
form must distinguish inherited fields from replacements explicitly rather than
recovering that distinction from expression shape or field names.

A replacement that consumes the field it replaces, such as
`items = s.items.append(x)`, reads the field through Perceus's owned-alias
shape, `BorrowLetExpr(temp, s.items, DupExpr(temp, ...))`. The ordinary
`ArcRetainPolicy` there makes the callee observe a shared value while the
source still holds the field. After Perceus, the reuse pass may replace that
retain policy with `CowFieldTakeRetainPolicy(source, field)` when the update's
source is a bare consumed variable, the field is stored as one heap pointer
under `ArcReleasePolicy` (heap records and the pointer collections; never an
inline managed value such as a stack result), and that alias is the only read
of the source that could observe the field slot across every replacement. A
direct read of a different field does not count; a lambda, closure, assignment,
or ownership event on the source disqualifies.

The owned alias may appear directly inside the replacement or in one preceding
immutable binding whose value transfers exactly once as the matching field's
bare replacement. The latter proof follows only explicit `LetExpr`,
`BorrowLetExpr`, and `SeqExpr` fall-through frames. It does not cross a call,
cooperative checkpoint, conditional, loop, logical short-circuit, lambda, or
nested field path, and it rejects any same-slot or whole-source observation
before writeback.

A record field is updated through its own update the same way, at any
depth: in `{ b | nodes = b.nodes.with_parent(k) }` the replacement passes the
slot it replaces to a user call, so consume specialization retargets the
call to the callee's consuming clone. Perceus then reads the slot through the
owned-alias shape for the consumed argument, the field take moves `nodes` out
of a unique `b`, and the clone receives the only reference and updates the
family in place before the result is written back. Each level is one clone,
so a method chain on the slot, a three-level `{ d | builder =
d.builder.append_parent(k) }` and a loop update `b = { b | nodes = ... }` all
compose. Only a direct read of the replaced slot, through the update's
binding or the variable it binds, in a call argument on the replacement's
straight-line spine qualifies, and only when the update can be in place: the
record is owned there (a clone's owned parameter or an owned local) or is
the target of `x = { x | ... }`. A read under a branch, of another field, of
another record, or in a function that only borrows the record keeps the
original callee.

The policy emits a runtime test on the source: a unique source gives up its
slot (left null) so the alias is the sole owner; a shared source retains as
before. The emptied slot is never observable: the replacement-local form
evaluates every replacement before consuming the source, while the hoisted
form proves that its linear window reaches the matching update without an
intervening observation or cancellation point. Neither form takes a field
when the expression holding the take, or another replacement of the same
update, can leave early (`break`, `continue`, a resource cleanup exit or a
tail-recursion jump): the exit would skip the writeback and leave the slot
empty in a record that outlives the update. The unique path overwrites the
slot, and field release is null-safe on every path including cancellation
cleanup. The rewrite must stay after Perceus and must not descend into any
position that can evaluate more than once or conditionally.

## Producer And Fusion Handoffs

Collection and tensor fusion can transfer an accumulator or source buffer
between generated stages. The handoff must carry:

- source and result ownership;
- logical length and capacity;
- element representation and release behavior;
- read/write ordering;
- fallback allocation behavior; and
- whether reuse consumed a matching source drop.

`BorrowFresh` describes a fresh result that does not consume source storage.
`ConsumeReuse` is valid only after reuse analysis consumes the exact matching
drop. A handoff view, builder, or internal pointer cannot escape its region.

## Compile-Time Constants

Pure immutable global initializers are evaluated before Core lowering. The
backend selects one of three storage classes:

1. Inline C data for values with no runtime ownership.
2. Static immortal storage for immutable string literals and recursively static
   object graphs supported by the backend.
3. Ordinary managed startup values for graphs requiring runtime construction.

Value-position string literals are interned by exact bytes at the
post-specialization Core boundary. Each distinct literal has one statically
initialized, artifact-lifetime `blorp_String` object. Literal values require no
retain, release, cancellation cleanup, allocation accounting, or global
shutdown cleanup. Dynamically constructed strings remain mortal managed
allocations. Aggregate globals containing strings may still require ordinary
managed construction and cleanup for the outer graph, while their literal
children point to the static pool.

Static immortal objects may include literal strings, scalar data, compatible
fixed-width lists, string-free records/tuples/concrete unions, fieldless
constructor singletons, and zero-capture closure descriptors. They must never
contain a pointer to a mortal object. Unsupported static children fail closed
to ordinary managed initialization.

Required invariants:

- every dynamically allocated string remains visible to profiling and leak checking;
- static string literals remain absent from allocation and leak counts;
- static objects contain only recursively static children;
- global reassignment releases the previous managed owner;
- generated global cleanup runs in reverse initialization order; and
- no pass infers global identity from a name prefix or C spelling.

## Ownership Node Producers

`DupExpr` and `DropExpr` are shared protocol nodes. Perceus owns general lexical
ARC balancing, but it is not their only producer.

| Phase | Responsibility |
| --- | --- |
| `synth_hash_collections` | Generated hash-collection accumulator cleanup |
| `collection_pipeline` | Mutable accumulator replacement and handoff boundaries |
| `perceus` | General lexical retains/releases and borrowed-to-owned normalization |
| `closure` | Closure, capture, and task-environment lifetimes |
| `resource` | Resource cleanup paths |

`consume_specialize` produces no ownership nodes. A consuming clone declares
its owned parameter in its `ConsumingClone` origin; ownership inference treats
that parameter as consumed, and Perceus balances the unchanged body. The pass
retargets a call to a clone where an owned record (a clone's owned parameter,
a `let`-bound local, the target of `x = f(x)`, or the result of another user
call passed straight in, as in `b.f().g()`) is passed at its last use;
clones are created transitively as clone bodies hand their parameter on.
`t = f(out, ...); out = g(t, ...)`, with the immutable `t` used only as one
direct argument of that call, the call not reading `out`, and neither call
able to leave early (`break`, `continue`, a cleanup exit or a tail-recursion
jump), is first rewritten to `out = f(out, ...); out = g(out, ...)`, so a
loop variable
updated through a temporary is handed on by the `x = f(x)` rule. A
clone is kept only when the record reaches an in-place update: a record
update of the parameter or an alias in the clone, or a last-use hand-off to
another clone that has one (a least fixpoint over the clones built). Calls to
the other clones go back to the original function. Liveness is conservative
inside loops, lambdas, logical operators and other constructs the pass does
not model. Perceus is the safety net: a retargeted argument that is still
live gets a retain, so imprecision costs a copy, never correctness. Perceus
turns the reference-count retain/release pair of a consumed parameter's or an
immutable managed `let` binding's only alias (`let x = p` or `var x = p`,
with no other use of `p`) into a move, so the alias reaches the next clone
uniquely owned even when its first update sits under a branch or loop.

Only record parameters are candidates. Union parameters used to get clones
for `x = f(x)` over a match source, which let `reuse` rebuild the union in the
source's storage; that was dropped because no self-compile benefit was
measured and the benefit filter has no variant for it (a union tree
`t = bump(t)` over 2,047 nodes now allocates 2,047 times).
Follow-up: readmit union parameters under the benefit filter with a variant
for "owned union reaches a reusable constructor after a match", verified by
counting `union_reuse_construct` nodes in self-compile Core.

Policy rewriters and consumers:

- `match_projection` may turn ownership policies into no-ops for
  representations requiring no runtime action.
- `reuse` consumes proven drops when ownership transfers into reused
  storage.
- `prepare` preserves ownership while selecting final backend forms.

Structural passes may inspect, map, hash, or serialize these nodes but must
preserve variable identity, type, policy, and control-flow placement. The
canonical ownership-event projection in
`blorp/test/test_compiler/test_support_core_ownership_events.brp` is the parity
oracle.

## Phase Responsibilities

| Phase | Ownership responsibility |
| --- | --- |
| Frontend | Reject illegal source escapes and construct exact semantic identities |
| Core lowering | Preserve source semantics; do not insert ad hoc ARC |
| Intrinsics/synthesis | Emit shapes matching the central ownership contracts |
| Ownership ingress | Validate identities, representation, and admitted Core forms |
| Perceus | Insert and balance general lexical ownership |
| Reuse | Consume proven ownership events for compatible allocation reuse |
| Closure/resource | Add protocol-specific capture and cleanup ownership |
| Preparation/invariants | Reject unresolved ownership or representation |
| Emit/runtime | Lower explicit facts and implement the contracted COW behavior |

## Required Invariants

- No owned managed temporary reaches a caller-preserving slot without a later
  drop or transfer.
- No borrowed alias crosses an owning boundary without a retain or proven
  transfer.
- No mutable place overwrites an owned value without consuming or releasing the
  previous owner.
- No consuming call receives an unretained borrowed projection.
- No managed call reaches ownership insertion or emission without a contract.
- No reuse rewrite occurs without consuming the exact ownership event that
  proves the source dead.
- No new child-bearing Core form receives a default zero-use or unmanaged
  interpretation.
- Runtime helpers and compiler contracts agree on receiver and result ownership.

Stable inexpensive checks run at their owning phase boundary. Broader graph and
event checks run under `--check-invariants`, compiler ownership suites, and
sanitizer gates.

## Active Boundaries

Proposed ownership and representation changes are routed through the
[open work index](README.md#open-issues-and-plans). This document changes only
when the resulting ABI becomes authoritative.

## Debugging Ownership Bugs

Classify a failure before editing:

- missing or incorrect call contract;
- borrowed value crossing an owning boundary;
- wrong identity or shadowing resolution;
- incorrect Perceus transfer/drop placement;
- protocol ownership duplicated by two passes;
- unsafe reuse consuming the wrong drop; or
- runtime COW behavior contradicting the compiler contract.

Use focused Core ownership-event tests, generated C, runtime leak checks, and
ASan/UBSan together. Event counts alone are insufficient: the right number of
releases in the wrong branch or on the wrong identity is still incorrect.
