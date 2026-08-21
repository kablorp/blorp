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

Unmanaged values include primitive scalars, enums, fieldless unions, valid
struct values, raw pointers, and dimension values. A struct is unmanaged as a
whole, so every field must also have a valid inline unmanaged representation.
Type-header validation rejects managed struct fields and infinitely recursive
inline products before Core lowering.

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
| `Retained` | A new owner created by incrementing the source reference count |
| `Consumed` | Ownership transferred into an operation; the caller cannot drop it afterward |
| `Transferred` | Ownership moved into another owner without an extra retain |
| `Place` | A variable, field, collection slot, global, or temporary holding a value |

Ownership is attached to exact local or declaration identity. Source spelling
alone is insufficient because locals can shadow globals and module-local
definition numbers can collide across modules.

## Expression Results

Every managed expression result has one of these source contracts:

- a literal or allocation normally produces `FreshOwned`;
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

Each managed result similarly states whether it is newly owned, transferred,
borrowed, or aliases an input. Public read-only operations must not secretly
consume receivers. COW consumption is an internal ABI or an explicitly
consuming source operation.

Direct user calls use exact callable identities and inferred or declared
contracts. Builtins and intrinsics use the typed contract tables in
`ownership.brp`. Foreign calls remain a trust boundary and must receive an
explicit conservative contract rather than a name heuristic.

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
  installing the new owner.
- Aggregate construction transfers field or element owners into the aggregate.
- Global initialization gives the generated global root ownership until
  shutdown or reassignment.
- Closure environments retain managed captures and release them when destroyed.
- Task environments retain captures until completion cleanup transfers or
  releases them.

An emitter-created managed temporary is still an owner. The backend must close
its lifetime explicitly or reject the unsupported shape.

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
2. Static immortal storage for recursively static, string-free object graphs.
3. Ordinary managed startup values for strings or graphs requiring runtime
   construction.

Strings are always mortal managed allocations. String globals and aggregate
globals containing strings are initialized once, owned by generated global
roots, and released in reverse initialization order at shutdown. Reads are
borrowed and are retained before escaping.

Static immortal objects may include scalar data, compatible fixed-width lists,
string-free records/tuples/concrete unions, fieldless constructor singletons,
and zero-capture closure descriptors. They must never contain a pointer to a
mortal object. Unsupported static children fail closed to ordinary managed
initialization.

Required invariants:

- every heap string remains visible to profiling and leak checking;
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
| `consume_specialize` | Drops required by consuming-call protocols |
| `perceus` | General lexical retains/releases and borrowed-to-owned normalization |
| `closure` | Closure, capture, and task-environment lifetimes |
| `resource` | Resource cleanup paths |

Policy rewriters and consumers:

- `match_projection` may turn ownership policies into no-ops for
  representations requiring no runtime action.
- `reuse` consumes proven drops when ownership transfers into reused
  storage.
- `prepare` preserves ownership while selecting final backend forms.

Structural passes may inspect, map, hash, or serialize these nodes but must
preserve variable identity, type, policy, and control-flow placement. The
canonical ownership-event projection in
`compiler/blorp/tests/test_support_core_ownership_events.brp` is the parity
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

The remaining architectural work is to require accepted type headers on every
semantic test path, preserve nominal type identity through representation-
sensitive Core, and give Perceus one exhaustive ownership-ready input. These are
tracked in [COMPILER_PRIORITIES.md](COMPILER_PRIORITIES.md); this document should
change only when the resulting ABI changes.

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
