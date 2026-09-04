# Share Match Continuations Instead Of Cloning Semantic-Match Fallback Trees

**Status:** Proposed

## Objective

Represent lowered pattern matching as an explicitly shared decision graph so a
source arm body or fallback is emitted once, even when several failed tests can
reach it. Preserve source-order matching, bindings, ownership, cancellation,
tail recursion, diagnostics, and single evaluation of the scrutinee.

This issue targets generated-C size first. Compile-time improvement is expected
because every late Core pass and the C emitter will also traverse less material,
but it is a secondary result that must be measured rather than assumed.

## Current problem

`blorp/src/compiler/stage_09_core/match_lowering.brp` currently builds a recursive
`CoreSemanticMatchTree`. When compiling tuple and list-pattern columns it
constructs an arm with `SemanticMatchFail` leaves, then replaces every failure
with the already-built continuation:

```blorp
private pure func replace_semantic_match_fail(
	tree: CoreSemanticMatchTree,
	fallback: CoreSemanticMatchTree,
) -> CoreSemanticMatchTree:
	match tree:
		SemanticMatchFail:
			fallback
		SemanticConstructorMatch(accessor, cases, existing_fallback):
			SemanticConstructorMatch(
				accessor,
				cases.map(func(match_case): {
					match_case |
					body = replace_semantic_match_fail(match_case.body, fallback)
				}),
				...
			)
```

The important operation is not the recursion itself; it is substitution of a
tree-shaped value. Each insertion copies the fallback into every failing leaf.
Subsequent arms can copy the result again. Nested list/tuple patterns therefore
turn a small source match into a very large late-Core tree and C function.

The current self-host artifact at `3d8ec393b04d` demonstrates the scale:

| Measurement | Current value |
| --- | ---: |
| Generated compiler C, excluding embedded runtime | 1,416,117 lines / 100,448,633 bytes |
| Source `parse_package_args` body | about 60 lines |
| Generated `parse_package_args` body | 66,874 lines |
| Occurrences of `"Error: unknown package command: "` in that generated body | 2,049 |

`parse_package_args` in `blorp/src/lib/cli_args.brp` is an ordinary ordered match
over list shapes. Its final catch-all error expression should exist once. Its
2,049 copies are a concrete continuation-sharing failure, not useful source
specialization.

Do not solve this by pooling the repeated string, deduplicating C text, or
recognizing this function. Those may reduce a symptom while leaving all cloned
control flow, ARC, cancellation cleanup, and late-pass work intact.

## Required representation

The distinction between a decision and a continuation must be explicit before
passes that currently traverse `CoreSemanticMatchTree`. A graph/CFG encoded as
an acyclic list of blocks and stable IDs is preferred because Blorp values
cannot contain cycles:

```blorp
opaque type CoreMatchBlockId = Int

record CoreSemanticMatchGraph {
	entry: CoreMatchBlockId,
	blocks: List[CoreSemanticMatchBlock]
}

record CoreSemanticMatchBlock {
	id: CoreMatchBlockId,
	bindings: List[CoreSemanticMatchBinding],
	terminator: CoreSemanticMatchTerminator
}

union CoreSemanticMatchTerminator:
	SemanticMatchConstructorTest(
		CoreSemanticMatchAccessor,
		List[CoreSemanticConstructorEdge],
		CoreMatchBlockId,
	)
	SemanticMatchLiteralTest(
		CoreSemanticMatchAccessor,
		List[CoreSemanticLiteralEdge],
		CoreMatchBlockId,
	)
	SemanticMatchLengthTest(
		CoreSemanticMatchAccessor,
		List[CoreSemanticLengthEdge],
		Option[CoreSemanticLengthGeqEdge],
		CoreMatchBlockId,
	)
	SemanticMatchLeaf(CoreExpr)
	SemanticMatchFail
```

The exact names may change. The represented facts may not:

- block identity is explicit and scoped to one match;
- test outcomes reference block IDs rather than embedding continuation trees;
- bindings belong to a precise incoming block/edge and cannot be inferred from
  C variable names;
- each source arm body has one leaf block;
- a fallback has one block regardless of its predecessor count; and
- the representation is deterministic and validatable.

If edge-specific bindings are necessary, introduce explicit edge arguments or
a binding record there. Do not move correctness into emitter-local string
maps, pointer identity, structural hashing, or name-prefix heuristics.

## Intended generated C

Equivalent structured C is acceptable, but shared blocks should produce one
body plus jumps rather than nested textual duplication:

```c
goto __match_0;

__match_0:
  if (__scrutinee->len == 0) goto __match_arm_0;
  goto __match_1;

__match_1:
  if (__scrutinee->len == 1 && /* element tests */) goto __match_arm_1;
  goto __match_fallback;

__match_arm_0:
  __match_result = /* arm 0, emitted once */;
  goto __match_done;

__match_arm_1:
  __match_result = /* arm 1, emitted once */;
  goto __match_done;

__match_fallback:
  __match_result = /* fallback, emitted once */;
  goto __match_done;

__match_done:
  /* continue */
```

Void matches may omit the result slot. An existing return, break, continue,
tail-recursive jump, or non-exhaustive failure may terminate a leaf directly.
Do not add an unreachable `goto done` merely to satisfy one rendering template.

## Implementation guidance

1. **Write a failing growth regression first.** Extend
   `blorp/test/compiler/stage_09_core/test_core_match.brp` with a generated
   ordered list-pattern match whose last fallback contains a unique marker.
   Assert graph/block counts are linear and the fallback is referenced by ID,
   not copied. Include at least 12 arms so an exponential/tree-shaped
   implementation fails decisively.
2. **Introduce block construction in match lowering.** Replace
   `replace_semantic_match_fail(tree, fallback)` with a builder operation that
   redirects unresolved failure edges to one `CoreMatchBlockId`. Build arms in
   reverse source order as today, but prepend blocks and connect IDs instead of
   embedding `result` into every fail leaf.
3. **Validate the graph at its construction boundary.** Check unique/dense IDs,
   a valid entry, valid edge targets, no duplicate block IDs, and no reachable
   unresolved `SemanticMatchFail` for exhaustive matches. Keep source locations
   on blocks/edges when diagnostics need them.
4. **Update every semantic-match consumer mechanically.** Search by variants,
   not only by the `CoreSemanticMatchTree` type name, because several passes
   destructure `SemanticMatchExpr` without naming its field type:

   ```bash
   rg -l \
     'SemanticMatchExpr|CoreSemanticMatchTree|Semantic(Constructor|Literal|Length)Match' \
     blorp/src/compiler/stage_09_core blorp/src/compiler/stage_10_backend | sort
   ```

   At `3d8ec393b04d`, the exhaustive result is `closure.brp`,
   `collection_pipeline.brp`, `dce.brp`, `fairness.brp`, `ir.brp`,
   `late_invariants.brp`, `match_lowering.brp`, `match_projection.brp`,
   `prepare.brp`, `resource_management.brp`, `reuse.brp`, `specialize.brp`,
   `ssa.brp`, `std_inline.brp`, `tailrec.brp`, `traverse.brp`,
   `tuple_sroa.brp`, `work_profile.brp`, and Stage 10 `emit.brp`. Rerun the
   search after each migration so new consumers cannot escape the inventory.
   Each applicable pass must traverse a graph block exactly once; use a
   worklist plus visited block IDs instead of recursively expanding successors.
5. **Keep match projection sharing-preserving.** Projection of accessors,
   ownership, length tests, and constructors must rewrite a block in place and
   retain its successor IDs. It must never turn the graph back into a tree.
6. **Emit each reachable block once.** Assign deterministic labels from block
   IDs. Emit result storage once, branch to one done label where needed, and
   preserve existing branch-local cleanup. Reuse the same block emitter for
   ordinary and tail-recursive match paths.
7. **Delete obsolete tree substitution.** Once all producers and consumers use
   the graph, remove `replace_semantic_match_fail` and the tree-only helpers;
   do not leave parallel representations or a compatibility conversion that
   re-expands the graph.
8. **Inspect the real outlier.** Rebuild once and confirm that generated
   `parse_package_args` contains one copy of each source arm/fallback body.

This change should land before relying on string-literal pooling to hide the
2,049 duplicated error literals. Pooling and match sharing are complementary;
only this issue removes the duplicated control flow.

## Semantic requirements

- Evaluate the scrutinee exactly once, before any decision tests.
- Preserve first-match-wins ordering, including overlapping list spreads,
  tuples, constructors, literals, catchalls, and or-patterns.
- Evaluate guards and impure arm bodies no more than once and only for the
  selected arm.
- Preserve binding identity, accessor order, borrow/own mode, list-spread
  slicing, and shadowing behavior.
- Preserve exhaustive and non-exhaustive match behavior and source locations.
- Preserve Core ownership: `DupExpr`, `DropExpr`, transfers, result aliases,
  branch-local destruction, and COW uniqueness must not change accidentally.
- Preserve cancellation cleanup and resource cleanup on every jump edge.
- Preserve ordinary returns, `break`, `continue`, and tail-recursive loops.
- Deterministic source must produce deterministic block IDs and C labels.
- Graph size and emitted C must grow linearly with decisions plus unique arm
  bodies, not with the number of paths through the graph.

## Tests to add or extend

### Stage 09 match lowering

In `blorp/test/compiler/stage_09_core/test_core_match.brp` cover:

- 12+ fixed-length list arms followed by a catchall;
- list spreads before and after fixed-length patterns;
- nested tuple-in-list and list-in-constructor patterns;
- overlapping patterns that prove first-match ordering;
- bindings used in a shared continuation;
- a fallback containing a unique marker, present in one leaf block; and
- a block-count assertion bounded by `decisions + unique arms + small constant`.

### Match projection and backend

Extend `blorp/test/compiler/stage_09_core/test_core_match_projection.brp` and
`blorp/test/compiler/stage_10_backend/test_core_emit.brp` to prove:

- every block is projected/emitted once even with multiple predecessors;
- ordinary and tail-recursive matches share the same policy;
- value, void, return, break, and continue leaves are well formed;
- shared fallbacks do not duplicate cleanup or release statements; and
- C labels and edge order are deterministic.

### Integrated behavior

Use existing lifetime coverage, especially:

- `blorp/test/compiler/pipeline/test_match_binding_lifetime.brp`;
- `blorp/test/compiler/pipeline/test_match_owner_alias_liveness.brp`;
- `blorp/test/runtime/memory/leak_check_baselines/literal_match_borrow_or_transfer_string.brp`;
- `blorp/test/runtime/memory/leak_check_baselines/option_match_borrow_or_transfer_record.brp`; and
- `blorp/test/lib/test_cli_args.brp` for the real `parse_package_args` behavior.

Add a codegen-audit fixture with repeated list-pattern arms and unique comments
or literal markers so the audit can assert one emitted copy of every arm and
fallback.

## Detailed fast feedback loop

### 1. Red: exercise working-tree match lowering without rebuilding

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/match_lowering.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_match.brp
```

The new block-count/fallback-identity test must fail on current main. Keep this
loop under a minute by running only this file while building the graph.

### 2. Green the nearest consumers

Run each direct source test as its owner is migrated:

```bash
bin/blorp test blorp/test/compiler/stage_09_core/test_core_match_projection.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_fairness.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

These tests import working-tree compiler modules, so they give feedback before
an integrated bootstrap build. If another Core pass lacks a focused test, add a
small graph-sharing assertion to its existing owner rather than using `make` as
the development loop.

### 3. Inspect a dedicated emitted-C probe

Add
`blorp/test/compiler/pipeline/codegen_audit/should_pass/semantic_match_shared_continuations.brp`
with 12+ list-pattern arms. After one successful `make`, compile just that
fixture without the runtime body:

```bash
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-match-sharing.XXXXXX")
probe_c="$probe_dir/probe.c"
bin/blorp compile --no-format --no-embed-runtime \
  -o "$probe_c" \
  blorp/test/compiler/pipeline/codegen_audit/should_pass/semantic_match_shared_continuations.brp
wc -l -c "$probe_c"
rg -n '__match_|UNIQUE_ARM_|UNIQUE_FALLBACK' "$probe_c"
rm -f "$probe_c"
rmdir "$probe_dir"
```

Record baseline/candidate line and byte counts. Each marker must appear once.
Increase the fixture from 12 to 24 arms locally and verify emitted lines grow by
approximately 2x, not 4x or worse.

### 4. Recheck behavior and ownership

```bash
bin/blorp test blorp/test/lib/test_cli_args.brp
bin/blorp test blorp/test/compiler/pipeline/test_match_binding_lifetime.brp
bin/blorp test blorp/test/compiler/pipeline/test_match_owner_alias_liveness.brp
bin/blorp test --leak-check --suite --timeout 30 \
  blorp/test/runtime/memory/leak_check_baselines/literal_match_borrow_or_transfer_string.brp
scripts/compiler-check --changed
```

If cleanup or ownership C changes, also run the matching sanitizer gate before
the full self-host measurement.

### 5. Measure the real compiler artifact

After the candidate compiler is rebuilt:

```bash
self_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-self-c.XXXXXX")
self_c="$self_dir/blorp.c"
bin/blorp compile --no-format --no-embed-runtime -o "$self_c" blorp/src/main.brp
wc -l -c "$self_c"
rg -n 'Error: unknown package command:' "$self_c" | wc -l
rm -f "$self_c"
rmdir "$self_dir"
```

Use the same compiler flags and source revision for baseline and candidate.
Also report match lowering, match projection, Perceus, and C-emission profile
times so a size win is not purchased with a compile-time regression.

## Acceptance criteria

1. Semantic match control flow uses explicit shared block/edge identity; no
   tree substitution or emitter-text deduplication is the source of sharing.
2. `replace_semantic_match_fail` and any graph-to-tree compatibility expansion
   are removed.
3. A 12/24-arm focused regression demonstrates linear block and C growth.
4. Every unique arm and fallback body is emitted once, including when it has
   multiple predecessors.
5. `parse_package_args` generated body falls from 66,874 lines to at most 13,375
   lines (an 80% reduction) under the controlled self-host measurement.
6. The duplicated `"Error: unknown package command: "` body in
   `parse_package_args` is emitted once; any remaining occurrence outside that
   function is separately attributed.
7. Scrutinee evaluation, source order, bindings, ownership, cancellation,
   resources, tail recursion, exits, and diagnostics are covered and unchanged.
8. Focused Stage 09/10 tests, integrated match lifetime tests,
   `scripts/compiler-check --changed`, and the relevant leak/sanitizer checks
   pass.
9. Before/after Core block count, generated C lines/bytes, largest function
   size, and relevant compiler phase timings are included in the PR.
10. The implementation contains no function-name, source-shape, C-text, or
    pointer-identity heuristic.

## Out of scope

- string-literal pooling or general constant interning;
- hand-written dispatch for `parse_package_args` or the lexer;
- changing pattern-match source semantics or exhaustiveness rules;
- optimizing the order of source tests beyond semantics-preserving grouping
  already owned by match projection; and
- arbitrary whole-program CFG conversion outside semantic matches.
