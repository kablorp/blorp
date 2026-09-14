# Make `List.concat` Reuse A Unique Left Allocation

**Status:** Proposed. The public API stays unchanged.

**Current state:** `synthesize_concat` in
`blorp/src/compiler/stage_09_core/synth_list.brp` allocates an exact-sized
third list and copies both operands on every call. It cannot reuse a dead,
unique left list with spare capacity, and concat chains repeatedly copy the
left prefix.

**Next action:** Write an ownership-contract test that fails without a
two-operand COW-consuming intrinsic, plus a runtime aliasing test. Record
allocation counts for unique-left and shared-left controls before changing
synthesis.

**Read first:** `synth_list.brp`, `stage_09_core/ownership.brp`, list COW
helpers in `blorp/src/lib/runtime/native/runtime.c`,
`stage_10_backend/intrinsic_renderer.brp`, and the nearest list/ownership
tests. Use the [Developer Guide](../DEVELOPMENT.md) for current test commands.

## Contract And Scope

Keep `pure func concat[T](left: List[T], right: List[T]) -> List[T]`. Lower it
to one `list_concat_owned(left, right)` runtime intrinsic that consumes one
owned reference to each operand and returns one owned list. Its compiler
contract is **`[CowConsumeArg, CowConsumeArg] -> ReturnOwned`**. Perceus must
retain an operand first if its source value remains live. Do not hide the
second consume behind an emitter-only special case.

| Input | Required result |
| --- | --- |
| Empty left/right | Return the other owned allocation when possible, consuming the empty owner. |
| Unique left with capacity | Append right elements in place; no new allocation or left-prefix copy. |
| Unique left without capacity | Grow geometrically through existing helpers; copy only as required by growth. |
| Shared left | Copy before update; other aliases retain original values. |
| Same list passed twice | Duplicate values without use-after-free, double release, or lost owner. |
| Managed or inline elements | Preserve element stride/layout and exact retain/release behavior. |

Copy/retain right-hand managed elements **before** releasing the consumed
right owner. Handle left/right allocation aliasing explicitly. Reuse existing
list capacity, span-copy, uniqueness, and release helpers; do not infer layout
from type names. Read the generated C to confirm one direct
`blorp_list_concat_owned(...)` call for source concat.

Do not change list `+`, compiler call sites, arbitrary concat-tree fusion,
right-storage stealing, ropes/builders, or the list representation. This issue
does not promise that every concat tree becomes linear.

## Fast Feedback

Use the focused Core synthesis, intrinsic-renderer, ownership/Perceus, list
COW, and managed-element suites first. Add a codegen-audit fixture requiring
the direct intrinsic call; the embedded runtime may legitimately contain
span-copy helpers, so do not assert their absence from the whole C artifact.
Then run the relevant compiler, runtime, leak, sanitizer, and codegen-audit
gates. Inspect generated C for unique/shared and `xs.concat(xs)` cases.

Add one retained allocation benchmark with prebuilt inputs and a printed
checksum. Measure (1) unique left with spare capacity, (2) shared left,
(3) unique left requiring growth, and (4) a chain over prebuilt small chunks.
Exclude setup from the operation window; record allocations, releases,
retained objects/bytes, and paired latency. Expected operation allocations:
zero for spare-capacity unique left and one result allocation for shared left;
growth may allocate one geometrically sized replacement. Compare the exact
same semantic output and save raw results under `benchmarks/results/`.

## Acceptance

The source API and value semantics are unchanged; synthesis no longer emits
the old allocate/copy/set-length tree; both arguments have the explicit COW
consume contract; empty, shared, unique, self-alias, managed, and inline cases
pass runtime/leak/sanitizer tests; generated C calls the intrinsic; and the
reusable case has a measured allocation reduction without a material control
regression. Reject an implementation that leaks an owner, mutates a shared
alias, depends on evaluation order, or requires a new collection framework.
