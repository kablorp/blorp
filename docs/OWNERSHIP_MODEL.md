# Ownership Model

This document defines the compiler-facing ownership model for managed values,
Perceus reference-count insertion, and copy-on-write (COW). It is the semantic
contract that `core_ownership.ml`, `compiler_core_perceus.brp`,
`compiler_core_reuse.brp`, `core_emit_layout.ml`, Core intrinsics, and the C
runtime must implement. Perceus and reuse are production Blorp stages; the
remaining OCaml modules provide contracts and layout facts before the pre-DCE
handoff.

The user-facing memory model is documented in `docs/MEMORY_MODEL.md`. This file
is lower level: it defines the ownership ABI used by compiler phases.

## Goals

- Preserve source-level value semantics: assignment copies, record update
  creates a new value, and mutable names rebind rather than expose shared
  mutable state.
- Keep managed values deterministic: every owned reference is either consumed,
  transferred, retained, or dropped exactly once.
- Make COW a compiler-visible ABI, not an implicit runtime side effect.
- Make ownership bugs fail before C emission whenever the compiler has enough
  information to detect them.

## Current Enforcement

This model is enforced in layers. When adding an ownership rule, prefer the
earliest layer that has enough information.

| Layer | Currently enforced |
|-------|--------------------|
| Typecheck / inference | Source-level purity, closure capture restrictions, match exhaustiveness, and surface typing for ownership-sensitive operations. |
| Core ownership contracts | Malformed builtin/intrinsic contracts are rejected by `core_ownership.ml` instead of being interpreted ad hoc by callers. |
| Core preparation and invariants | Final Core must make erased `void*` storage crossings explicit with typed box/unbox nodes where required; unresolved fallback representation choices are rejected before emit. |
| Perceus / reuse | Managed values receive explicit `CDup` / `CDrop`, and reuse rewrites are limited to proven post-drop, unique-owner candidates. |
| Runtime | Reference counts, COW uniqueness checks, and reuse helpers preserve the dynamic ownership ABI. |

Some boundaries are intentionally conservative rather than fully general:
closure call arguments, loop / try / detach liveness, and structured-concurrency
task-result handoff use explicit boundaries instead of a complete call ABI model
for every possible control-flow shape.

## Managed Values

A managed value is a heap value with runtime reference-counted lifetime. Current
managed families include strings, lists, dicts, sets, tensors/vectors, records,
unions with payloads, closures, channels, and other runtime objects classified by
`Core_type_layout`.

Unmanaged values include primitives, enums, enum-like unions without payloads,
struct/value records, raw pointers, and dimension values. They do not participate
in Perceus `CDup` / `CDrop`.

Unknown named types must not default to unmanaged. Ownership classification must
be explicit through built-in type metadata, user type declarations, aliases, or
active type parameters.

## Ownership Facts

These terms are normative.

| Term | Meaning |
|------|---------|
| `Owned` | This expression or place owns one reference and must eventually transfer, consume, or drop it. |
| `FreshOwned` | A newly allocated owned value with refcount 1. It is a subtype of `Owned`. |
| `Borrowed` | A temporary read of a value owned elsewhere. It must not be dropped. |
| `Alias(owner)` | A borrowed view into another managed owner, such as `record.field` or `list_get(list, i)`. |
| `Retained` | A new owned reference created by incrementing the source refcount. |
| `Consumed` | An owned reference was moved into a callee or operation. The caller must not drop it afterward. |
| `Transferred` | An owned value was stored into another owner without an extra retain. |
| `Place` | A variable, field, collection slot, or temporary that can hold an owned managed value. |

Source-level bindings and assignment have value semantics. If a new source-level
place is initialized from an alias, the compiler must retain before treating the
new place as independently owned. Internal compiler temporaries may remain
borrowed aliases only when their lifetime is dominated by the owner and they do
not escape, get stored, or cross a source-level function boundary.

## Expression Result Ownership

The compiler must be able to answer what ownership an expression result has:

| Expression shape | Result ownership |
|------------------|------------------|
| Allocation, record literal, list literal | `FreshOwned` |
| Closure creation | `Owned`; captured closures allocate, zero-capture closures may point at immortal static closure objects |
| Managed variable read in a borrowed position | `Borrowed` from that variable's place |
| Managed variable read in a consuming/returning position | Uses or transfers the place's owner according to context |
| Field access on managed owner | `Alias(owner)` |
| Collection element access | `Alias(collection)` unless the operation retains before return |
| Borrowed call result | `Borrowed` or `Alias(arg)` according to the call contract |
| Source-level managed function return | `Owned` |

Managed aliases must not cross a source-level function return boundary as
borrowed values. A function that returns `x`, `record.field`, or an aliasing
intrinsic result must retain before returning, so callers receive `Owned`.

Compiled pattern matches introduce backend temporaries for their scrutinee. If
a non-place scrutinee expression returns an owned managed value, the backend
must release that temporary after the decision tree has finished. Variables and
fields remain under source/Perceus ownership because they may be borrowed
pattern aliases; borrowed or aliasing call results must not be released by the
match emitter.

## Call ABI

Every ownership-sensitive intrinsic, builtin, synthesized helper, and direct
user call has a call contract:

```text
args: arg_mode list
result: result_mode
```

At the current pre-DCE boundary, call-site `consumed_args` remain conservative
compatibility evidence while Blorp derives function consumption with a
monotonic analysis. Inferred consumption may add arguments but must not remove
a projected consume.

Inferred borrowing is not yet authoritative for every managed-return call.
Match-binding ownership modes are still present in the projected body and may
encode an owning destructure even when a function parameter is classified as
borrowed. Perceus therefore retains the conservative fallback until Blorp
derives both function contracts and match-binding modes from one ownership
analysis.

### Argument Modes

| Mode | Callee may do | Caller obligation after call |
|------|---------------|------------------------------|
| `Borrow` | Read only. It may return a borrowed alias tied to this argument. | Caller still owns the value and must drop it later if it was owned. |
| `Retain` | Read and retain/store its own reference. | Caller still owns the value and must drop it later if it was owned. |
| `Consume` | Take ownership and release, store, or return it. | Caller must not drop the consumed owner. |
| `CowConsume` | Take ownership and reuse/mutate when unique, otherwise copy and release the consumed input. | Caller must not drop the consumed owner. |
| `Transfer` | Take ownership of a freshly owned value for storage without retaining. | Caller must not drop the transferred owner. |

`Borrow` and `Retain` preserve caller ownership. `Consume`, `CowConsume`, and
`Transfer` consume caller ownership.

### Result Modes

| Mode | Meaning |
|------|---------|
| `ReturnVoid` | No value result. |
| `ReturnPrimitive` | Unmanaged result. |
| `ReturnOwned` | Caller receives one owned managed reference. |
| `ReturnBorrowed` | Caller receives a borrowed value whose lifetime is tied to preserved arguments. It must not cross a source-level function boundary without retain. |
| `ReturnAliasOfArg i` | Result aliases argument `i`. Argument `i` must be caller-preserved (`Borrow` or `Retain`). |

The compiler must reject or fail invariants for malformed contracts, for example
`ReturnAliasOfArg i` pointing to a consuming argument, or `ReturnBorrowed`
without any caller-preserved argument to anchor its lifetime.

`core_ownership.ml` owns these checks. `validate_contract` reports malformed
ABI entries, and the contract constructor fails fast for declarations that
would let a borrowed result alias an argument the caller no longer owns.

## Source-Level Function Boundary

Function calls preserve source value semantics:

- A caller-owned managed argument remains usable after a read-only call.
- A callee may borrow managed parameters without retaining on entry.
- If a callee stores, returns, or transfers a parameter/alias as owned, it must
  retain or otherwise create ownership first.
- A source-level function returning a managed type returns `Owned`, even if the
  body internally read from a borrowed parameter or field.

Direct user-call contracts may be inferred from Core bodies, but the inference
must produce the same observable ABI: read-only parameters borrow; parameters
whose ownership is actually consumed are consuming; managed returns are owned.

## Storage ABI

Owning containers and records own their managed fields/elements.

When storing a managed value:

- A `FreshOwned` produced value may be transferred into storage.
- A caller-owned input may be stored through `Retain`; the caller keeps its
  original owner.
- A borrowed alias must be retained before storage.
- Replacing an existing managed slot must release the previous stored value
  exactly once.

This rule applies to record fields, tuple fields when RC-tracked, list elements,
dict keys/values, set keys, vector/tensor managed elements, and closure
captures.

Hash-table insertion should make the retain/transfer split visible to Core
when the operation is synthesized instead of delegated to a runtime mutator. For
sets, synthesized builders retain a key for the destination table with
`set_retain_key_for` and then transfer that retained key into a fresh entry with
`set_alloc_entry`. For dicts, synthesized `Dict.set` retains the destination
key/value before slot writes and releases an overwritten managed value through
the dict's value-release callback before replacing it. Runtime COW mutators are
still valid implementation boundaries, but their contracts must describe the
same storage ownership semantics.

## Mutable Places

`var` introduces a mutable place, not a mutable object. For managed values:

- Initializing a mutable place creates or receives ownership for the current
  value.
- Assigning a non-consuming RHS to that place must release the previous owner
  before overwriting the place.
- Assigning a consuming/COW-consuming RHS that consumes the current place must
  not also release the old owner.
- At scope exit, the current value of a managed mutable place must be dropped
  unless it has been returned or transferred.

The compiler should model mutable places directly. Rewriting assignments after
the fact is acceptable only as an implementation step toward this model.

## COW ABI

`CowConsume(receiver)` has one meaning across the compiler and runtime:

1. The callee receives ownership of `receiver`.
2. If the receiver is unique, the callee may mutate it in place and return the
   same owned pointer.
3. If the receiver is shared, the callee copies, mutates the copy, releases the
   consumed receiver, and returns the copy as `Owned`.
4. If the operation is a no-op, it still returns an owned value representing the
   consumed receiver. The caller must treat the original owner as consumed.

If the source program needs both the old value and an updated value, the compiler
must retain before the COW operation:

```text
alias = xs
updated = xs.append(1)
```

The alias must keep a retained reference so COW sees sharing and copies instead
of mutating through a false unique refcount.

Borrow-preserving operations must not secretly consume their receiver. For
example, `map`, `filter`, and `sort_by` should borrow the input and allocate a
fresh result unless their contract explicitly says `CowConsume`.

Compiler-selected collection reuse should put the COW decision at one explicit
boundary, then express subsequent unique-table mutation as normal Core writes.
For example, synthesized set `add` and `combine` call `set_cow` once and then
perform direct retained-entry insertion instead of repeatedly routing each entry
through a runtime COW mutator. Synthesized `Dict.set` follows the same shape:
`dict_cow` establishes the unique table, then Core probes, retains, releases
replaced values, writes slots, and grows the table as needed.

## Producer/Fusion Handoff ABI

Some collection producers need to read an input collection while producing a
same-family output collection. Examples include fused list `map`/`filter`
pipelines: the old list cannot be dropped before the loop, but the output may
reuse its storage after the compiler proves the input owner has no later uses.

This is not the same as changing `map` or `filter` to `CowConsume`. Public
borrow-preserving operations keep their normal fresh-allocation semantics. A
producer handoff is an internal Core boundary with two modes:

| Mode | Meaning |
|------|---------|
| `BorrowFresh` | The source is borrowed for reads and the producer allocates a fresh result. This is the default semantics before reuse optimization. |
| `ConsumeReuse` | The handoff consumes the source owner and may reuse its storage when the runtime proves uniqueness; otherwise it falls back to fresh storage and releases the consumed source. |

The handoff must be explicit in Core. Reuse analysis must not rediscover this
shape from arbitrary loops. The intended post-Perceus rewrite is:

```text
let src = xs in
let result = producer_handoff BorrowFresh(src, ...)
drop src
result
```

to:

```text
let src = xs in
producer_handoff ConsumeReuse(src, ...)
```

The rewrite is legal only when the `drop src` is the ownership fact inserted by
Perceus for the same source owner. If that source owner is used later, crosses a
task boundary, or otherwise lacks that drop, the handoff stays in `BorrowFresh`
mode. Retained aliases created before the handoff are allowed; they make the
runtime uniqueness check fail and force the fresh-storage fallback.

### Handoff Region Rules

A handoff region has a read-only source view and a write-only result builder.
Those internal names are compiler-generated and must not escape the region.

- The source expression is evaluated exactly once and bound to a Core variable.
- The source view may only be used for bounded reads.
- The result builder may only receive writes through declared storage
  operations: retain borrowed source elements, transfer produced elements, or
  overwrite-aware handoff stores.
- The region must declare its collection family, source element type, result
  element type, capacity bound, and write-order policy.
- The region must not move work across callback, closure, or task boundaries.
- The region must lower to the same observable callback order and callback
  count as the unfused program.

The supported write-order policy is forward compacting list construction:
source index `i` increases monotonically and every write index is at or before
the current read index. That covers `map`, `filter`, and `filter_map`-style
loops without allowing order-changing operations such as `sort`, `reverse`, or
general `flat_map` to reuse storage prematurely.

### List Handoff Runtime Boundary

The list runtime boundary should preserve source reads until the loop has
processed them, unlike `list_reuse_alloc`, which clears an already-dead list
before returning an empty allocation. Conceptually, a list handoff has a
begin/body/finish shape:

```text
handoff = list_handoff_begin(src, min_cap, result_elem_release)
old_len = list_handoff_len(handoff)
for i in 0..old_len:
    elem = list_handoff_get(handoff, i)
    ...
    list_handoff_set_owned(handoff.result, out, value)
result = list_handoff_finish(handoff, out_len)
```

`begin` consumes `src` only in `ConsumeReuse` mode. If `src` is unique and the
runtime can reuse its storage, the source view and result builder may share the
same allocation. The list keeps its old length during the producer body so
`list_handoff_set_owned` can distinguish reused slots from fresh writes:

- For fresh builders, `len == 0` during the body, so a handoff store just writes
  the transferred element.
- For reused builders, `len == old_len` during the body, so a handoff store
  releases the overwritten old managed slot before installing the transferred
  element.
- At finish, old tail slots in `out_len..old_len` are released once, then the
  result length is shrunk to `out_len`.

If `src` is shared, capacity-incompatible, has an incompatible element-release
callback, or is otherwise unsafe to reuse, the handoff reads from the consumed
source, writes to fresh storage, then releases the consumed source at finish.

The C backend lowers the boundary through named runtime helpers:

- `blorp_list_handoff_begin_borrow` allocates a fresh builder.
- `blorp_list_handoff_begin_reuse` chooses reuse only when the source is unique,
  has enough capacity, and carries exactly the same element-release callback as
  the result type.
- `blorp_list_handoff_set_owned` performs overwrite-aware transfer stores.
- `blorp_list_handoff_finish` releases discarded tail slots, shrinks the result,
  and releases the consumed source when runtime reuse did not happen.

The exact-match callback guard prevents element-type-changing fusion from
reusing storage with the wrong destructor. Managed in-place reuse depends on
handoff bodies using `list_handoff_set_owned`; generic `list_set_owned` is not
overwrite-aware and must not be used inside producer handoff regions.

This boundary is deliberately stronger than a raw allocation rewrite:

- It supports reading old contents before clearing them.
- It lets source and result element release callbacks differ by falling back to
  fresh result storage instead of reusing with the wrong destructor.
- It gives the runtime one place to enforce uniqueness and fallback behavior.
- It keeps the compiler's optimization explainable from Perceus ownership
  facts rather than source spelling.

## Phase Responsibilities

| Phase | Ownership responsibility |
|-------|--------------------------|
| Lowering | Preserve source semantics in Core. Do not insert retain/release. |
| Core intrinsics/synthesis | Emit Core shapes whose ownership behavior matches `core_ownership.ml`; emit producer handoff regions only in `BorrowFresh` mode. |
| Ownership contracts | Provide the single source of truth for call modes and result modes. |
| Perceus | Convert ownership facts into `CDup` / `CDrop`; do not invent runtime ABI rules locally. |
| Reuse analysis/rewrite | Read post-Perceus `CDrop` facts to identify safe allocation-reuse candidates; upgrade explicit producer handoffs to `ConsumeReuse` only by consuming the matching drop; rewrite only through explicit runtime COW/reuse boundaries after uniqueness and allocation compatibility are proven. |
| Closure conversion | Preserve retained capture ownership and owned return boundaries. |
| Codegen preparation | Make erased storage crossings, final constructors, layout choices, and release policies explicit in Core before emit. |
| Invariants | Reject missing ownership contracts at the Perceus boundary and unresolved representation/closure forms at final Core. |
| Emit/runtime | Lower explicit Core ownership/layout nodes, close backend-created owned temps, and implement COW exactly as contracted. |

## Required Invariants

These invariants define the ownership safety bar. Stable checks belong in
the owning Blorp Core stage and its invariant module; the final Core boundary
always rejects the small set of forms that must never reach emission, and
`--check-invariants` enables broader stage-boundary checks during development.

- No managed owned temporary is passed to a caller-preserving call slot without a
  post-call drop.
- No borrowed alias crosses a source-level managed return boundary without a
  retain.
- No managed mutable assignment overwrites an owned place without consuming or
  releasing the previous owner.
- No COW-consuming call receives a direct borrowed field/element alias unless
  the alias has been retained into an owned temporary.
- No managed call reaches Perceus or emit without an ownership contract.
- No runtime COW function has behavior that contradicts its compiler contract.
- No producer handoff reaches emit in `ConsumeReuse` mode unless reuse analysis
  consumed a matching post-Perceus `CDrop` for the source owner.
- No producer handoff source view or result builder escapes the handoff region.

## Debugging Ownership Bugs

New ownership bugs should be classified as one of:

- missing or wrong call contract
- missing ownership fact
- wrong Perceus transfer/drop rule
- runtime COW ABI mismatch

They should not normally be fixed by adding another isolated syntax-shape patch.
