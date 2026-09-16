# Reuse Unchanged Core Nodes In The Shared Traversal

**Status:** Ready. Coordinator-owned acceptance; execute mechanically.

**Current state:** `map_core_expr_children_with_map_context` in
`blorp/src/compiler/stage_09_core/traverse.brp` (search for that name; it
begins near line 1322) rebuilds every node it visits, including leaves such
as `LiteralExpr` and `VarExpr`, even when the mapper returned every child
unchanged. On the 2026-09-16 self-compile it ran 21.8M times and the read-side
helper `immediate_core_expr_children` ran 22.7M times over a program of
roughly 0.6M to 1.0M nodes; late Core allocated 128.6M objects and early Core
56.6M. Passes that touch few nodes still pay a full-tree reallocation.
Perceus already tracks a hand-rolled `reuses_source` flag (91 mentions in
`perceus.brp`), which is the precedent that returning the original node is a
valid outcome of a Core pass.

**Next action:** Add one compiler-internal allocation-identity primitive, then
make the shared traversal helpers return the original node (or list) when
every mapped child and type is the identical allocation. Do not change any
pass.

**Read first:** `traverse.brp` (the whole `map_core_expr_children_with_map_context`
arm list, `map_context_exprs`, `map_context_type`,
`map_core_logical_tree_with_map_context`, `map_core_sequence_items`,
`map_core_match_results_with_context`, `map_core_optional_expr`,
`map_core_dict_literal_entries`, `map_core_record_cow_fields*`);
`standard_library/src/memory.brp` (`is_unique`, the builtin precedent);
`blorp/src/lib/runtime/native/runtime_decl.c` (`blorp_is_unique`);
`blorp/src/compiler/stage_09_core/backend_projection.brp` near the
`blorp_is_unique` intrinsic selection; `blorp/src/compiler/stage_10_backend/intrinsic_renderer.brp`
near `MemoryIsUniqueHeap`; `blorp/test/compiler/stage_09_core/test_core_traverse.brp`;
[Architecture](../../ARCHITECTURE.md#core-pipeline); the
[measurement protocol](../../../benchmarks/README.md#self-compile-measurement-protocol).

**Fast loop:**

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_traverse.brp
make && scripts/compiler-build-status
benchmarks/self_compile_measure --label issue-147 --input-rev <baseline input_rev> \
  --baseline benchmarks/results/self_compile_baseline_O0_2026-09-16.json \
  --output /tmp/issue-147.json --require-identical
```

**Decision:** Accept when generated C is IDENTICAL for the self and small
programs, total allocations fall by at least 15% (expected: early_core and
late_core each fall materially), retired instructions do not rise, and the
focused Core suites plus `scripts/compiler-check --changed` pass. Ask the
coordinator before touching any pass, any ownership contract, or the
builtin's semantics beyond what is written here.

## Objective

Stop reallocating Core nodes that a pass did not change, so sparse passes allocate only along the spine to changed nodes and the whole pipeline's allocation count falls without editing any pass.

## Step 1: Allocation-Identity Primitive

Add a compiler-internal way to ask whether two managed values are the same
allocation. It exists only so a pass can prove "nothing changed"; it is not a
user-facing equality and must not be documented as one.

1. Runtime: next to `blorp_is_unique` in `runtime_decl.c`, add
   `static inline bool blorp_same_object(const void* left, const void* right)`
   returning pointer equality (both NULL counts as the same object). Add the
   matching forward declaration where `blorp_is_unique` is forward-declared in
   `runtime.c` if the runtime object needs it.
2. Standard library: in `memory.brp`, next to `is_unique`, add
   `pure func same_object` generic over `T`, taking `left: T, right: T` and returning `Bool`, with body
   `builtin("blorp_same_object")`. Document: true only when both values are
   the same managed allocation; stack types (Int, Bool, structs) always
   return False; immortal literals are unspecified. `scripts/check-std-builtins`
   must pass.
3. Backend: mirror the `blorp_is_unique` handling. In `backend_projection.brp`
   select a `memory_same_object_heap` or `memory_same_object_stack` intrinsic
   from the first argument's storage class; in `intrinsic_renderer.brp` render
   the heap form as `blorp_same_object((const void*)a, (const void*)b)` and the
   stack form as `((void)(a), (void)(b), false)`.
4. Bootstrap check: the pinned bootstrap compiler must compile `traverse.brp`
   using the new builtin. Run `make` immediately after Step 1 with a trivial
   use of `same_object` in `traverse.brp`. If the bootstrap rejects the
   builtin name, stop and consult the coordinator; do not work around it with
   a `foreign func`.
5. Tests: add a runtime test under `blorp/test/runtime/memory/` covering
   record same/different, list same/different, and a stack value returning
   False.

## Step 2: Return The Original Node When Nothing Changed

In `traverse.brp`, for every arm of `map_core_expr_children_with_map_context`:

- compute the mapped children and the mapped type exactly as today;
- if every mapped child is `same_object` its original, every mapped child
  list is the original list, and the mapped type is `same_object` the
  original type (always true when `type_mapper` is `None`), return `expr`;
- otherwise construct the node exactly as today.

Apply the same rule to `map_context_exprs` (return the input list when every
element is identical; a list rebuilt from identical elements is a new
allocation and must not count as unchanged), `map_core_optional_expr`,
`map_core_dict_literal_entries`, `map_core_record_cow_fields*`,
`map_core_logical_tree_with_map_context` (rebuild a `LogicalExpr` only when a
side or the type changed), `map_core_sequence_items`, and
`map_core_match_results_with_context`.

Keep the arms mechanical. A small private helper for the common "two
children plus type" shape is fine; a general visitor or a new traversal API
is out of scope.

## Invariants

- Generated C is byte-identical for the self-compile and the small program.
- Every Core pass, `--check-invariants`, `--dump-core-after=<stage>` output,
  diagnostics, and ownership events are unchanged.
- Sharing subtrees between a pass's input and output is safe because Core is
  immutable value data. Search `perceus.brp`, `reuse.brp`, and `closure.brp`
  for `is_unique(` on Core values; if any pass relies on uniqueness of Core
  nodes for in-place mutation, report it to the coordinator before continuing.
- No pass is edited. If the measurement shows less than a 10% total
  allocation drop, list which passes bypass the shared helpers with their own
  traversal (for example Perceus, closure, reuse) and report; do not widen
  scope.

## Measurement

Baseline: `benchmarks/results/self_compile_baseline_O0_2026-09-16.json` and
`self_compile_small_baseline_O0_2026-09-16.json` (the `-O2` pair is used by
the coordinator). Measure after Step 1 (expected neutral) and after Step 2.
Report the harness comparison table verbatim in your handoff, including the
IDENTICAL line, plus the focused-suite counts.

## Acceptance And Rejection

Accept: IDENTICAL C on both programs; total allocations down at least 15%;
retired instructions not up; small program allocations not up more than 1%;
`bin/blorp test` on `test_core_traverse.brp`, `test_core_perceus.brp`,
`test_core_reuse.brp`, `test_core_closure.brp`, the new runtime memory test,
and `benchmarks/self_compile_measure lock -- scripts/compiler-check --changed`
all green. Reject if any pass output changes, if the builtin leaks into
user-facing equality semantics, or if the drop comes from skipping work a
pass actually needed.
