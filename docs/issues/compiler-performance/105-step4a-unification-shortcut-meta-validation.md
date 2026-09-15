# Step 4A: Validate Metas At Unification Shortcuts

**Status:** Implemented in this worktree; Step 4A remains open. This follows
the binding-graph cut in
[packet 104](104-step4a-meta-binding-graph-invariants.md).

## Context

Binding construction now rejects unissued meta targets and references, and
equal-type unification rejects an unissued meta. Other successful unification
paths could still bypass both checks:

```blorp
unissued = SemanticMetaType(0)  -- no meta has been issued by CONTEXT_EMPTY
variadic = SemanticNamedType("Tensor", [TYPE_INT, SemanticVarDimsType("Ds")])
tail = SemanticNamedType("Tensor", [TYPE_INT, unissued])
dim_left = SemanticDimOpType(SemanticDimAdd, unissued, SemanticConstIntType(1))
dim_right = SemanticDimOpType(SemanticDimAdd, SemanticConstIntType(1), unissued)

unify(CONTEXT_EMPTY, SemanticTypeVar("T"), type_list(unissued))
unify(CONTEXT_EMPTY, variadic, tail)
unify(CONTEXT_EMPTY, dim_left, dim_right)
unify(CONTEXT_EMPTY, TYPE_INT, SemanticRangeType(unissued))
```

The first publishes a type-variable substitution. The second skips a
variadic tail. The third can canonicalize away an invalid meta and report
`DimSolved`. The fourth accepts `Int`/range compatibility without inspecting
the range's inner type. Targeted tests for each failed before implementation;
the variadic test also covers the symmetric direction and a later tail slot.

## Implementation strategy

`meta_references_are_issued` reuses the existing `ValidateIssuedReferences`
graph walk. It follows issued bindings and rejects any negative or unissued
reference. Rather than scan every operand at every recursive `unify_go` call,
the unifier invokes this check only where a success path skips the ordinary
binding or structural descent:

- `unify_try_bind` validates the substituted type before publishing it.
- Variadic matching validates every skipped tail element, in both directions.
- The dimension path validates both operands before `dim_solve`, because
  canonicalization can cancel a bad reference or omit it from a proposed
  binding.
- `Int`/range compatibility validates both operands in named, structural,
  and symmetric paths.

This preserves the existing treatment of valid issued metas and does not add
a full-tree validation pass to every successful recursive unification step.
The common equality path and `bind_meta` continue to enforce their packet 104
checks. Review found no other direct success shortcut in the current unifier.

## Fast feedback and resource guard

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_dim_solver.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The retained selected CTFE workload reports the same checksum 2,538, 72
dependency body checks, three reused bodies, 769,887 allocations, 769,884
releases, and 3 / 192 retained objects/bytes as packet 104. In a short
alternating B-A-A-B direct worker screen, the packet 104 worker
(`e7c0b9230759881df4e9b6830f69ba8cbf70b6576d0edd5bb3ef868bb6a5c186`)
retired 1,568,497,207 / 1,568,943,411 instructions; this cut's worker
(`8eb4c67eb4851e8a5a076a98464c90d927343bc3d4958f0160eab41f4f15985c`)
retired 1,567,090,559 / 1,567,022,855. Peak footprint was
14,975,288 / 14,991,672 B before and 14,958,904 / 14,942,520 B after.
All four direct runs had ten page faults. Worker size stayed 6,391,968 B.
These are local uncommitted snapshots, not git revisions; elapsed samples
are not strong enough for a wall-time claim. The worker preceded a comment-only
source edit; no executable logic changed after the measurement.

On the final source, the independent focused context/dimension/inference
tests pass 342 / 342, the changed-owner check passes four sources and 11
suites, and the focused context ASan/UBSan test passes 26 / 26.

## Acceptance and remaining work

- An unissued meta cannot be accepted by the tested substitution, variadic,
  dimension-cancellation, or `Int`/range shortcuts; valid issued references
  continue to pass.
- Focused owner tests, changed-owner gate, and sanitizer remain green.
- Allocations, retained bytes, peak memory, instructions, and worker size do
  not materially regress in the retained CTFE screen.
- A raw `SemanticMetaType(Int)` from another session can still alias an issued
  local index. This cut checks issuance, not provenance. A session-owned meta
  identity and detached solver lifetime remain Step 4A work, alongside final
  whole-program validation/finalization and its traversal guard.
